"""Offline gates for candidate expansion and cloud correction behavior."""

from __future__ import annotations

import json
import math
from pathlib import Path
from typing import Any, Dict, Iterable, List


class CloudEvaluationError(ValueError):
    pass


def load_cloud_observations(path: Path) -> List[Dict[str, Any]]:
    observations = []
    with path.open(encoding="utf-8") as source:
        for line_number, line in enumerate(source, start=1):
            if not line.strip():
                continue
            try:
                value = json.loads(line)
            except json.JSONDecodeError as exc:
                raise CloudEvaluationError(
                    f"{path}:{line_number}: invalid JSON"
                ) from exc
            _validate_observation(value, path=path, line_number=line_number)
            observations.append(value)
    if not observations:
        raise CloudEvaluationError(f"{path}: contains no observations")
    return observations


def evaluate_cloud_observations(
    observations: Iterable[Dict[str, Any]],
) -> Dict[str, Any]:
    values = list(observations)
    if not values:
        raise CloudEvaluationError("cloud evaluation requires observations")
    baseline_covered = sum(
        value["gold_text"] in value["baseline_candidates"]
        for value in values
    )
    expanded_covered = sum(
        value["gold_text"] in value["expanded_candidates"]
        for value in values
    )
    fuzzy_choices = [
        value
        for value in values
        if value["decision"] == "choose"
        and value["selected_source"] == "rime_fuzzy"
    ]
    correct_fuzzy = sum(
        value["selected_text"] == value["gold_text"]
        for value in fuzzy_choices
    )
    completed = [value for value in values if value["latency_ms"] is not None]
    within_deadline = sum(
        value["latency_ms"] <= 800 for value in completed
    )
    final_correct = 0
    for value in values:
        final_text = (
            value["selected_text"]
            if value["decision"] == "choose"
            else value["baseline_candidates"][0]
        )
        final_correct += final_text == value["gold_text"]
    sample_count = len(values)
    baseline_coverage = baseline_covered / sample_count
    expanded_coverage = expanded_covered / sample_count
    correction_precision = (
        correct_fuzzy / len(fuzzy_choices) if fuzzy_choices else None
    )
    # Missing latency means the cloud request never completed and therefore
    # missed the product deadline. Excluding those rows would let a run with
    # widespread timeouts pass the 95% responsiveness gate.
    within_deadline_rate = within_deadline / sample_count
    metrics = {
        "samples": sample_count,
        "baseline_candidate_coverage": baseline_coverage,
        "expanded_candidate_coverage": expanded_coverage,
        "candidate_coverage_gain_pp": (
            expanded_coverage - baseline_coverage
        ) * 100,
        "correction_attempts": len(fuzzy_choices),
        "correction_precision": correction_precision,
        "end_to_end_top1_accuracy": final_correct / sample_count,
        "completed_cloud_requests": len(completed),
        "within_800_ms_rate": within_deadline_rate,
        "p95_latency_ms": _percentile(
            [value["latency_ms"] for value in completed],
            0.95,
        ),
        "stale_commits": sum(value["stale_commit"] for value in values),
        "secure_inference_requests": sum(
            value["secure_input"] and value["inference_sent"]
            for value in values
        ),
        "secure_history_writes": sum(
            value["secure_input"] and value["history_written"]
            for value in values
        ),
    }
    gates = {
        "candidate_coverage_gain_at_least_5pp":
            metrics["candidate_coverage_gain_pp"] >= 5,
        "correction_precision_at_least_98pct":
            correction_precision is not None
            and correction_precision >= 0.98,
        "cloud_within_800ms_at_least_95pct": within_deadline_rate >= 0.95,
        "zero_stale_commits": metrics["stale_commits"] == 0,
        "zero_secure_inference": metrics["secure_inference_requests"] == 0,
        "zero_secure_history_writes": metrics["secure_history_writes"] == 0,
    }
    return {
        "schema_version": 1,
        "metrics": metrics,
        "gates": gates,
        "passed": all(gates.values()),
    }


def _validate_observation(
    value: Any,
    *,
    path: Path,
    line_number: int,
) -> None:
    if not isinstance(value, dict):
        raise CloudEvaluationError(f"{path}:{line_number}: expected object")
    required_strings = ("gold_text", "decision", "selected_source")
    if any(not isinstance(value.get(key), str) for key in required_strings):
        raise CloudEvaluationError(
            f"{path}:{line_number}: required strings are missing"
        )
    for key in ("baseline_candidates", "expanded_candidates"):
        if (
            not isinstance(value.get(key), list)
            or not value[key]
            or any(not isinstance(item, str) or not item for item in value[key])
        ):
            raise CloudEvaluationError(
                f"{path}:{line_number}: {key} is invalid"
            )
    if value["decision"] not in {"choose", "keep", "abstain"}:
        raise CloudEvaluationError(
            f"{path}:{line_number}: decision is invalid"
        )
    selected_text = value.get("selected_text")
    if value["decision"] == "choose":
        if (
            not isinstance(selected_text, str)
            or selected_text not in value["expanded_candidates"]
        ):
            raise CloudEvaluationError(
                f"{path}:{line_number}: choice is outside expanded candidates"
            )
    elif selected_text is not None:
        raise CloudEvaluationError(
            f"{path}:{line_number}: abstention contains selected text"
        )
    latency = value.get("latency_ms")
    if latency is not None and (
        not isinstance(latency, (int, float))
        or isinstance(latency, bool)
        or not math.isfinite(latency)
        or latency < 0
    ):
        raise CloudEvaluationError(
            f"{path}:{line_number}: latency is invalid"
        )
    for key in (
        "secure_input",
        "inference_sent",
        "history_written",
        "stale_commit",
    ):
        if not isinstance(value.get(key), bool):
            raise CloudEvaluationError(
                f"{path}:{line_number}: {key} must be boolean"
            )


def _percentile(values: List[float], quantile: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    index = max(0, math.ceil(len(ordered) * quantile) - 1)
    return float(ordered[index])
