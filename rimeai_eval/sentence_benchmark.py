"""Sentence-level benchmark: Rime baseline vs the beam sentence decoder."""

from math import ceil
from time import perf_counter
from typing import Any, Callable, Dict, List, Optional, Sequence

from rimeai_daemon.fused_lm import FusedCharLM
from rimeai_daemon.user_lm import UserLanguageModel
from rimeai_runtime.beam_decoder import BeamSentenceDecoder, SegmentDecodeInput
from rimeai_runtime.lm_fusion import CharLMScorer, StaticCharLM

ScorerFactory = Callable[[Dict[str, Any]], Optional[CharLMScorer]]


def levenshtein(a: str, b: str) -> int:
    if a == b:
        return 0
    if not a:
        return len(b)
    if not b:
        return len(a)
    previous = list(range(len(b) + 1))
    for row, char_a in enumerate(a, start=1):
        current = [row]
        for column, char_b in enumerate(b, start=1):
            current.append(
                min(
                    previous[column] + 1,
                    current[column - 1] + 1,
                    previous[column - 1] + (char_a != char_b),
                )
            )
        previous = current
    return previous[-1]


def _ratio(numerator: float, denominator: int) -> float:
    return round(numerator / denominator, 6) if denominator else 0.0


def _percentile(values: Sequence[float], percentile: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    index = max(0, ceil(percentile * len(ordered)) - 1)
    return round(ordered[index], 6)


def _char_accuracy(prediction: str, gold: str) -> float:
    return 1.0 - levenshtein(prediction, gold) / max(len(gold), 1)


def _decode_sample(
    decoder: BeamSentenceDecoder,
    sample: Dict[str, Any],
    scorer: Optional[CharLMScorer],
):
    segments = sample.get("segments")
    if segments and len(segments) > 1:
        return decoder.suggest_segments(
            context=sample["context"],
            segments=[
                SegmentDecodeInput(
                    pinyin=segment["pinyin"],
                    separator=segment["separator"],
                    committed_text=segment.get("committed_text") or "",
                )
                for segment in segments
            ],
            active_candidates=sample["candidates"],
            scorer=scorer,
        )
    return decoder.suggest(
        context=sample["context"],
        pinyin=sample["pinyin"],
        candidates=sample["candidates"],
        scorer=scorer,
    )


def benchmark_sentence_decoder(
    samples: Sequence[Dict[str, Any]],
    decoder: BeamSentenceDecoder,
    *,
    min_confidence: float = 0.0,
    scorer_factory: Optional[ScorerFactory] = None,
) -> Dict[str, Any]:
    """Benchmark one decode arm over `samples`.

    The decoder prediction is the gated suggestion: `suggestion.text` when
    the decoder reports reason "suggestion" at or above `min_confidence`,
    otherwise the Rime first candidate. Every sample's decoder reason is
    counted in `decision_counts`, including fallback reasons.
    """
    baseline_hits = 0
    decoder_hits = 0
    coverage_hits = 0
    baseline_char_total = 0.0
    decoder_char_total = 0.0
    edit_distance_total = 0.0
    decision_counts: Dict[str, int] = {}
    latencies: List[float] = []

    for sample in samples:
        candidates = sample["candidates"]
        baseline = candidates[0]
        gold = sample["gold_text"]
        coverage_hits += gold in candidates[:10]
        baseline_hits += baseline == gold
        baseline_char_total += _char_accuracy(baseline, gold)
        scorer = (
            scorer_factory(sample) if scorer_factory is not None else None
        )
        started_at = perf_counter()
        suggestion = _decode_sample(decoder, sample, scorer)
        latencies.append((perf_counter() - started_at) * 1000.0)
        decision_counts[suggestion.reason] = (
            decision_counts.get(suggestion.reason, 0) + 1
        )
        applied = (
            suggestion.text
            if suggestion.reason == "suggestion"
            and suggestion.text
            and suggestion.confidence >= min_confidence
            else baseline
        )
        decoder_hits += applied == gold
        decoder_char_total += _char_accuracy(applied, gold)
        edit_distance_total += levenshtein(applied, gold)

    total = len(samples)
    return {
        "schema_version": 1,
        "benchmark_type": "sentence-benchmark",
        "samples": total,
        "metrics": {
            "baseline_sentence_accuracy": _ratio(baseline_hits, total),
            "decoder_sentence_accuracy": _ratio(decoder_hits, total),
            "baseline_char_accuracy": _ratio(baseline_char_total, total),
            "decoder_char_accuracy": _ratio(decoder_char_total, total),
            "gold_in_top10_coverage": _ratio(coverage_hits, total),
            "mean_edit_distance": _ratio(edit_distance_total, total),
            "decoder_latency_ms": {
                "p50": _percentile(latencies, 0.5),
                "p95": _percentile(latencies, 0.95),
            },
        },
        "decision_counts": dict(sorted(decision_counts.items())),
        "hyperparameters": {"min_confidence": min_confidence},
    }


def run_sentence_benchmark(
    samples: Sequence[Dict[str, Any]],
    decoder: BeamSentenceDecoder,
    *,
    min_confidence: float = 0.0,
    user_lm: Optional[UserLanguageModel] = None,
    command_decoder: Optional[Any] = None,
) -> Dict[str, Any]:
    """Assemble the full benchmark report with optional fused and neural arms.

    `user_lm` adds `fused_`-prefixed twin metrics by re-decoding every
    sample with a per-domain `FusedCharLM` scorer. `command_decoder` (a
    `CommandSentenceDecoder`) adds side-by-side neural metrics where an
    abstention is an empty suggestion; a `SentenceDecoderProtocolError`
    propagates so the caller can abort instead of miscounting failures as
    abstentions.
    """
    report = benchmark_sentence_decoder(
        samples,
        decoder,
        min_confidence=min_confidence,
    )
    if user_lm is not None:
        base_scorer = StaticCharLM(decoder.language_model)
        fused = benchmark_sentence_decoder(
            samples,
            decoder,
            min_confidence=min_confidence,
            scorer_factory=lambda sample: FusedCharLM(
                base_scorer,
                user_lm,
                sample.get("domain"),
            ),
        )
        report["metrics"]["fused_sentence_accuracy"] = fused["metrics"][
            "decoder_sentence_accuracy"
        ]
        report["metrics"]["fused_char_accuracy"] = fused["metrics"][
            "decoder_char_accuracy"
        ]
        report["metrics"]["fused_decoder_latency_ms"] = fused["metrics"][
            "decoder_latency_ms"
        ]
        report["fused_decision_counts"] = fused["decision_counts"]
    if command_decoder is not None:
        neural_hits = 0
        abstains = 0
        for sample in samples:
            suggestion = command_decoder.suggest(sample)
            abstains += not suggestion.text
            neural_hits += suggestion.text == sample["gold_text"]
        report["metrics"]["neural_sentence_accuracy"] = _ratio(
            neural_hits,
            len(samples),
        )
        report["metrics"]["neural_abstain_rate"] = _ratio(
            abstains,
            len(samples),
        )
    return report
