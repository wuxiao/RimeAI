from collections import defaultdict
from dataclasses import dataclass
from math import ceil
from time import perf_counter_ns
from typing import (
    Any,
    DefaultDict,
    Dict,
    List,
    Optional,
    Protocol,
    Sequence,
    Tuple,
)

from rimeai_runtime.ranking import Ranking, RankerError


class Ranker(Protocol):
    name: str

    def rank(self, sample: Dict[str, Any]) -> Ranking:
        ...


class BaselineRanker:
    name = "baseline"

    def rank(self, sample: Dict[str, Any]) -> Ranking:
        return Ranking(tuple(sample["candidates"]), 1.0)


class ContextRepeatRanker:
    name = "context-repeat"

    def rank(self, sample: Dict[str, Any]) -> Ranking:
        context = sample["context"]
        indexed_candidates = list(enumerate(sample["candidates"]))
        indexed_candidates.sort(
            key=lambda item: (-context.count(item[1]), item[0])
        )
        return Ranking(
            tuple(candidate for _, candidate in indexed_candidates), 1.0
        )


@dataclass(frozen=True)
class _Observation:
    domain: str
    tags: Tuple[str, ...]
    covered: bool
    top1_hit: bool
    reciprocal_rank: float
    character_errors: int
    gold_characters: int
    latency_ms: float


def _rounded_ratio(numerator: float, denominator: int) -> float:
    if denominator == 0:
        return 0.0
    return round(numerator / denominator, 6)


def _percentile(values: List[float], percentile: float) -> float:
    ordered = sorted(values)
    index = max(0, ceil(percentile * len(ordered)) - 1)
    return round(ordered[index], 6)


def _aggregate(observations: Sequence[_Observation]) -> Dict[str, Any]:
    sample_count = len(observations)
    covered = [observation for observation in observations if observation.covered]
    covered_count = len(covered)
    top1_hits = sum(observation.top1_hit for observation in observations)
    conditional_top1_hits = sum(observation.top1_hit for observation in covered)
    reciprocal_rank_sum = sum(
        observation.reciprocal_rank for observation in observations
    )
    conditional_reciprocal_rank_sum = sum(
        observation.reciprocal_rank for observation in covered
    )
    character_errors = sum(
        observation.character_errors for observation in observations
    )
    gold_characters = sum(
        observation.gold_characters for observation in observations
    )
    conditional_character_errors = sum(
        observation.character_errors for observation in covered
    )
    conditional_gold_characters = sum(
        observation.gold_characters for observation in covered
    )
    return {
        "samples": sample_count,
        "covered_samples": covered_count,
        "top_k_coverage": _rounded_ratio(covered_count, sample_count),
        "top1_accuracy": _rounded_ratio(top1_hits, sample_count),
        "conditional_top1_accuracy": _rounded_ratio(
            conditional_top1_hits, covered_count
        ),
        "mrr": _rounded_ratio(reciprocal_rank_sum, sample_count),
        "conditional_mrr": _rounded_ratio(
            conditional_reciprocal_rank_sum, covered_count
        ),
        "cer": _rounded_ratio(character_errors, gold_characters),
        "conditional_cer": _rounded_ratio(
            conditional_character_errors, conditional_gold_characters
        ),
    }


def _edit_distance(left: str, right: str) -> int:
    previous = list(range(len(right) + 1))
    for left_index, left_character in enumerate(left, start=1):
        current = [left_index]
        for right_index, right_character in enumerate(right, start=1):
            current.append(
                min(
                    current[-1] + 1,
                    previous[right_index] + 1,
                    previous[right_index - 1]
                    + (left_character != right_character),
                )
            )
        previous = current
    return previous[-1]


def _observe(
    sample: Dict[str, Any],
    ranked_candidates: Sequence[str],
    latency_ms: float,
) -> _Observation:
    gold_text = sample["gold_text"]
    covered = gold_text in sample["candidates"]
    reciprocal_rank = 0.0
    if gold_text in ranked_candidates:
        reciprocal_rank = 1.0 / (ranked_candidates.index(gold_text) + 1)
    predicted_text = ranked_candidates[0] if ranked_candidates else ""
    return _Observation(
        domain=sample["domain"],
        tags=tuple(sample.get("tags", [])),
        covered=covered,
        top1_hit=bool(
            ranked_candidates and ranked_candidates[0] == gold_text
        ),
        reciprocal_rank=reciprocal_rank,
        character_errors=_edit_distance(predicted_text, gold_text),
        gold_characters=len(gold_text),
        latency_ms=latency_ms,
    )


def evaluate_dataset(
    samples: Sequence[Dict[str, Any]],
    ranker: Ranker,
    split: str,
    min_confidence: float = 0.0,
    details: Optional[List[Dict[str, Any]]] = None,
) -> Dict[str, Any]:
    observations: List[_Observation] = []
    raw_observations: List[_Observation] = []
    ranker_errors = 0
    abstained_samples = 0

    for sample in samples:
        started_at = perf_counter_ns()
        ranker_failed = False
        ranker_error: Optional[str] = None
        try:
            ranking = ranker.rank(sample)
            raw_candidates = list(ranking.candidates)
        except RankerError as error:
            ranker_errors += 1
            ranker_failed = True
            ranker_error = type(error).__name__
            raw_candidates = list(sample["candidates"])
            ranking = Ranking(tuple(raw_candidates), 0.0)
        latency_ms = (perf_counter_ns() - started_at) / 1_000_000

        raw_observations.append(_observe(sample, raw_candidates, latency_ms))
        applied_candidates = raw_candidates
        if not ranker_failed and ranking.confidence < min_confidence:
            abstained_samples += 1
            applied_candidates = list(sample["candidates"])
        observations.append(_observe(sample, applied_candidates, latency_ms))
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
                    "baseline_candidates": list(sample["candidates"]),
                    "ranked_candidates": raw_candidates,
                    "applied_candidates": applied_candidates,
                    "gold_text": sample["gold_text"],
                    "confidence": round(ranking.confidence, 6),
                    "applied": not ranker_failed
                    and ranking.confidence >= min_confidence,
                    "ranker_error": ranker_error,
                    "latency_ms": round(latency_ms, 6),
                }
            )

    aggregate = _aggregate(observations)
    raw_aggregate = _aggregate(raw_observations)
    observations_by_domain: DefaultDict[str, List[_Observation]] = defaultdict(list)
    observations_by_tag: DefaultDict[str, List[_Observation]] = defaultdict(list)
    for observation in observations:
        observations_by_domain[observation.domain].append(observation)
        for tag in observation.tags:
            observations_by_tag[tag].append(observation)

    latencies_ms = getattr(
        ranker,
        "attempt_latencies_ms",
        [observation.latency_ms for observation in observations],
    )
    ranker_report: Dict[str, Any] = {
        "name": ranker.name,
        "errors": ranker_errors,
    }
    model_artifact_id = getattr(ranker, "model_artifact_id", None)
    if model_artifact_id is not None:
        ranker_report["model_artifact_id"] = model_artifact_id
    attempted_samples = getattr(ranker, "attempted_samples", None)
    successful_samples = getattr(ranker, "successful_samples", None)
    if attempted_samples is not None and successful_samples is not None:
        ranker_report["attempted_samples"] = attempted_samples
        ranker_report["successful_samples"] = successful_samples
    cold_start_ms = getattr(ranker, "cold_start_ms", None)
    if cold_start_ms is not None:
        ranker_report["cold_start_ms"] = round(cold_start_ms, 6)
    peak_rss_bytes = getattr(ranker, "peak_rss_bytes", None)
    if peak_rss_bytes is not None:
        ranker_report["resource"] = {
            "peak_rss_bytes": peak_rss_bytes,
        }
    if min_confidence > 0:
        ranker_report["min_confidence"] = min_confidence
        ranker_report["abstained_samples"] = abstained_samples
    return {
        "schema_version": 1,
        "dataset": {
            "split": split,
            "samples": aggregate["samples"],
            "covered_samples": aggregate["covered_samples"],
            "top_k_coverage": aggregate["top_k_coverage"],
        },
        "ranker": ranker_report,
        "metrics": {
            "top1_accuracy": aggregate["top1_accuracy"],
            "conditional_top1_accuracy": aggregate[
                "conditional_top1_accuracy"
            ],
            "mrr": aggregate["mrr"],
            "conditional_mrr": aggregate["conditional_mrr"],
            "cer": aggregate["cer"],
            "conditional_cer": aggregate["conditional_cer"],
        },
        **(
            {
                "raw_metrics": {
                    "top1_accuracy": raw_aggregate["top1_accuracy"],
                    "conditional_top1_accuracy": raw_aggregate[
                        "conditional_top1_accuracy"
                    ],
                    "mrr": raw_aggregate["mrr"],
                    "conditional_mrr": raw_aggregate["conditional_mrr"],
                    "cer": raw_aggregate["cer"],
                    "conditional_cer": raw_aggregate["conditional_cer"],
                }
            }
            if min_confidence > 0
            else {}
        ),
        "latency_ms": {
            "samples": len(latencies_ms),
            "p50": _percentile(latencies_ms, 0.50),
            "p95": _percentile(latencies_ms, 0.95),
        },
        "slices": {
            "domain": {
                domain: _aggregate(domain_observations)
                for domain, domain_observations in sorted(
                    observations_by_domain.items()
                )
            },
            "tag": {
                tag: _aggregate(tag_observations)
                for tag, tag_observations in sorted(observations_by_tag.items())
            },
        },
    }
