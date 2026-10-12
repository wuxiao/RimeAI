"""Aggregate long-input sentence suggestion evaluation."""

from collections import defaultdict
from math import ceil
from typing import Any, DefaultDict, Dict, List, Optional, Sequence

from .command_sentence_decoder import (
    CommandSentenceDecoder,
    SentenceDecoderProtocolError,
)
from rimeai_runtime.pinyin_guard import PinyinGuard


def _ratio(numerator: int, denominator: int) -> float:
    return round(numerator / denominator, 6) if denominator else 0.0


def _percentile(values: Sequence[float], percentile: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    index = max(0, ceil(percentile * len(ordered)) - 1)
    return round(ordered[index], 6)


def _slice_metrics(rows: Sequence[Dict[str, Any]]) -> Dict[str, Any]:
    samples = len(rows)
    baseline_hits = sum(row["baseline_hit"] for row in rows)
    applied_hits = sum(row["applied_hit"] for row in rows)
    baseline_accuracy = _ratio(baseline_hits, samples)
    accuracy = _ratio(applied_hits, samples)
    relative_lift: Optional[float] = None
    if baseline_accuracy > 0:
        relative_lift = round(
            (accuracy - baseline_accuracy) / baseline_accuracy,
            6,
        )
    return {
        "samples": samples,
        "baseline_sentence_accuracy": baseline_accuracy,
        "sentence_accuracy": accuracy,
        "relative_lift": relative_lift,
    }


def evaluate_sentence_dataset(
    samples: Sequence[Dict[str, Any]],
    decoder: CommandSentenceDecoder,
    guard: PinyinGuard,
    *,
    split: str,
    min_confidence: float = 0.0,
    details: Optional[List[Dict[str, Any]]] = None,
) -> Dict[str, Any]:
    rows: List[Dict[str, Any]] = []
    by_domain: DefaultDict[str, List[Dict[str, Any]]] = defaultdict(list)
    by_tag: DefaultDict[str, List[Dict[str, Any]]] = defaultdict(list)
    errors = 0
    valid_suggestions = 0
    pinyin_rejections = 0
    empty_suggestions = 0
    low_confidence = 0

    for sample in samples:
        baseline = sample["candidates"][0]
        raw_suggestion = ""
        confidence = 0.0
        decoder_error: Optional[str] = None
        try:
            suggestion = decoder.suggest(sample)
            raw_suggestion = suggestion.text
            confidence = suggestion.confidence
        except SentenceDecoderProtocolError as error:
            errors += 1
            decoder_error = type(error).__name__

        applied = baseline
        status = "fallback-error" if decoder_error else "fallback-empty"
        if decoder_error is None:
            if not raw_suggestion:
                empty_suggestions += 1
            elif confidence < min_confidence:
                low_confidence += 1
                status = "fallback-low-confidence"
            elif not guard.matches(raw_suggestion, sample["pinyin"]):
                pinyin_rejections += 1
                status = "fallback-pinyin"
            else:
                valid_suggestions += 1
                applied = raw_suggestion
                status = "applied"

        row = {
            "domain": sample["domain"],
            "tags": sample.get("tags", []),
            "baseline_hit": baseline == sample["gold_text"],
            "applied_hit": applied == sample["gold_text"],
        }
        rows.append(row)
        by_domain[sample["domain"]].append(row)
        for tag in sample.get("tags", []):
            by_tag[tag].append(row)
        if details is not None:
            details.append(
                {
                    "schema_version": 1,
                    "id": sample["id"],
                    "split": sample["split"],
                    "domain": sample["domain"],
                    "tags": sample.get("tags", []),
                    "context": sample["context"],
                    "pinyin": sample["pinyin"],
                    "baseline_candidate": baseline,
                    "raw_suggestion": raw_suggestion,
                    "applied_text": applied,
                    "gold_text": sample["gold_text"],
                    "confidence": round(confidence, 6),
                    "status": status,
                    "decoder_error": decoder_error,
                }
            )

    decoder_report: Dict[str, Any] = {
        "name": decoder.name,
        "errors": errors,
        "attempted_samples": decoder.attempted_samples,
        "successful_samples": decoder.successful_samples,
        "valid_suggestions": valid_suggestions,
        "pinyin_rejections": pinyin_rejections,
        "empty_suggestions": empty_suggestions,
        "low_confidence": low_confidence,
        "min_confidence": min_confidence,
    }
    if decoder.model_artifact_id is not None:
        decoder_report["model_artifact_id"] = decoder.model_artifact_id
    if decoder.cold_start_ms is not None:
        decoder_report["cold_start_ms"] = round(decoder.cold_start_ms, 6)
    if decoder.peak_rss_bytes is not None:
        decoder_report["resource"] = {
            "peak_rss_bytes": decoder.peak_rss_bytes
        }

    return {
        "schema_version": 1,
        "dataset": {
            "split": split,
            "samples": len(samples),
        },
        "decoder": decoder_report,
        "metrics": {
            key: value
            for key, value in _slice_metrics(rows).items()
            if key != "samples"
        },
        "latency_ms": {
            "samples": len(decoder.attempt_latencies_ms),
            "p50": _percentile(decoder.attempt_latencies_ms, 0.5),
            "p95": _percentile(decoder.attempt_latencies_ms, 0.95),
        },
        "slices": {
            "domain": {
                key: _slice_metrics(value)
                for key, value in sorted(by_domain.items())
            },
            "tag": {
                key: _slice_metrics(value)
                for key, value in sorted(by_tag.items())
            },
        },
    }
