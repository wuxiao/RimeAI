#!/usr/bin/env python3
"""Compare mask-renormalized vs RAW confidence and beam length penalties.

Reads the details JSONL emitted by `rimeai_eval evaluate-sentence
--details-output` (schema: id/domain/pinyin/gold_text/raw_suggestion/
applied_text/status/confidence[renormalized]/raw_confidence[legacy
RAW softmax geometric mean]) plus the per-run report JSONs, and emits
the neural-confidence-mask-renorm report: precision-coverage for both
calibers, per-length-bucket discrimination, the length-penalty sweep,
and the final test summary. Pure offline aggregation — no worker, no
model.
"""

import argparse
import json
from pathlib import Path
from typing import Any


def load_details(path: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    try:
        with path.open(encoding="utf-8") as file:
            for line in file:
                line = line.strip()
                if line:
                    rows.append(json.loads(line))
    except (OSError, json.JSONDecodeError) as error:
        raise SystemExit(
            f"error: cannot read details '{path}': {error}"
        ) from error
    return rows


def load_report(path: Path | None) -> dict[str, Any] | None:
    if path is None:
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SystemExit(
            f"error: cannot read report '{path}': {error}"
        ) from error


def precision_coverage(
    rows: list[dict[str, Any]], field: str, thresholds: list[float]
) -> dict[str, dict[str, float]]:
    """Gate-style precision vs shown-coverage at absolute thresholds.

    Matches the frozen baseline's method (docs/baselines/
    constrained-qwen-v3-mlx.json confidence_gate_calibration): shown
    counts every sample at or above the threshold (empty suggestions
    carry confidence 0.0 and only surface at t=0), precision is the
    applied-hit rate among them.
    """
    total = len(rows)
    table: dict[str, dict[str, float]] = {}
    for threshold in thresholds:
        shown_rows = [
            row
            for row in rows
            if float(row.get(field) or 0.0) >= threshold
        ]
        shown = len(shown_rows)
        precision = (
            round(
                sum(1 for row in shown_rows if row["applied_text"] == row["gold_text"])
                / shown,
                4,
            )
            if shown
            else 0.0
        )
        decoder_precision = (
            round(
                sum(
                    1
                    for row in shown_rows
                    if row["raw_suggestion"] == row["gold_text"]
                )
                / shown,
                4,
            )
            if shown
            else 0.0
        )
        table[f"{threshold:g}"] = {
            "shown": shown,
            "coverage": round(shown / total, 4) if total else 0.0,
            "precision_applied": precision,
            "precision_decoder": decoder_precision,
        }
    return table


def auc(confidences_correct: list[float], confidences_wrong: list[float]) -> float:
    """Mann-Whitney AUC: P(score_correct > score_wrong) + 0.5 * ties."""
    if not confidences_correct or not confidences_wrong:
        return 0.5
    wins = 0.0
    for positive in confidences_correct:
        for negative in confidences_wrong:
            if positive > negative:
                wins += 1.0
            elif positive == negative:
                wins += 0.5
    return round(wins / (len(confidences_correct) * len(confidences_wrong)), 4)


def discrimination(
    rows: list[dict[str, Any]], field: str
) -> dict[str, Any]:
    """Discrimination of one confidence caliber over non-empty
    decoder suggestions (model-layer correctness)."""
    non_empty = [row for row in rows if row["raw_suggestion"]]
    correct = [
        float(row[field])
        for row in non_empty
        if row[field] is not None and row["raw_suggestion"] == row["gold_text"]
    ]
    wrong = [
        float(row[field])
        for row in non_empty
        if row[field] is not None and row["raw_suggestion"] != row["gold_text"]
    ]
    return {
        "samples_non_empty": len(non_empty),
        "correct_mean": round(sum(correct) / len(correct), 6) if correct else None,
        "wrong_mean": round(sum(wrong) / len(wrong), 6) if wrong else None,
        "auc": auc(correct, wrong),
    }


LENGTH_BUCKETS = ((1, 3), (4, 6), (7, 10), (11, 30))


def length_buckets(rows: list[dict[str, Any]]) -> dict[str, Any]:
    out: dict[str, Any] = {}
    for low, high in LENGTH_BUCKETS:
        bucket_rows = [
            row
            for row in rows
            if low <= len(row["gold_text"]) <= high
        ]
        if not bucket_rows:
            continue
        entry: dict[str, Any] = {
            "samples": len(bucket_rows),
        }
        for field, label in (
            ("confidence", "renormalized"),
            ("raw_confidence", "raw"),
        ):
            stats = discrimination(bucket_rows, field)
            entry[label] = {
                "correct_mean": stats["correct_mean"],
                "wrong_mean": stats["wrong_mean"],
                "auc": stats["auc"],
            }
        out[f"len_{low}-{high}"] = entry
    return out


def run_summary(
    rows: list[dict[str, Any]], report: dict[str, Any] | None
) -> dict[str, Any]:
    summary: dict[str, Any] = {
        "samples": len(rows),
        "sentence_accuracy": round(
            sum(1 for row in rows if row["applied_text"] == row["gold_text"])
            / len(rows),
            6,
        )
        if rows
        else None,
        "decoder_exact": round(
            sum(1 for row in rows if row["raw_suggestion"] == row["gold_text"])
            / len(rows),
            6,
        )
        if rows
        else None,
        "empty_suggestions": sum(1 for row in rows if not row["raw_suggestion"]),
        "status_counts": {
            status: sum(1 for row in rows if row["status"] == status)
            for status in sorted({row["status"] for row in rows})
        },
    }
    if report is not None:
        summary["latency_ms"] = report.get("latency_ms")
    return summary


def suggestion_agreement(
    left: list[dict[str, Any]], right: list[dict[str, Any]]
) -> dict[str, Any]:
    right_by_id = {row["id"]: row for row in right}
    shared = [row for row in left if row["id"] in right_by_id]
    if not shared:
        return {"shared": 0}
    same = sum(
        1
        for row in shared
        if row["raw_suggestion"] == right_by_id[row["id"]]["raw_suggestion"]
    )
    return {
        "shared": len(shared),
        "agreement": round(same / len(shared), 6),
        "differing": len(shared) - same,
    }


RENORM_THRESHOLDS = [0.0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.95, 0.99]
RAW_THRESHOLDS = [0.0, 1e-05, 1e-04, 1e-03, 1e-02, 1e-01, 0.2, 0.4, 0.6]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--validation-run",
        action="append",
        default=[],
        nargs=2,
        metavar=("LABEL", "DETAILS"),
        help="length-penalty sweep run: label + details JSONL",
    )
    parser.add_argument(
        "--validation-report",
        action="append",
        default=[],
        nargs=2,
        metavar=("LABEL", "REPORT_JSON"),
    )
    parser.add_argument(
        "--test-details",
        required=True,
        help="final test-split details JSONL",
    )
    parser.add_argument("--test-report")
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    reports = dict(args.validation_report)
    sweep: dict[str, Any] = {}
    baseline_rows: list[dict[str, Any]] | None = None
    for label, details_path in args.validation_run:
        rows = load_details(Path(details_path))
        sweep[label] = {
            "summary": run_summary(rows, load_report(Path(reports[label])) if label in reports else None),
        }
        if baseline_rows is None:
            baseline_rows = rows
        else:
            sweep[label]["vs_first_run_suggestions"] = suggestion_agreement(
                baseline_rows, rows
            )

    test_rows = load_details(Path(args.test_details))

    report: dict[str, Any] = {
        "schema_version": 1,
        "task": "neural confidence: pinyin-mask renormalization + beam length penalty tuning",
        "method": {
            "confidence": "DecodeResult.confidence is now the geometric mean of the chosen token's probability renormalized within each step's pinyin mask (p / Z, Z = RAW softmax mass over allowed candidates); raw_confidence keeps the legacy RAW softmax geometric mean. Protocol field names unchanged.",
            "precision_coverage": "gate-style precision vs shown-coverage at absolute thresholds on the same rows; precision_applied follows the frozen baseline's applied-text hit rate, precision_decoder scores the decoder output itself (raw_suggestion == gold).",
            "auc": "Mann-Whitney AUC of the confidence separating correct vs wrong non-empty decoder suggestions (higher = more discriminative; 0.5 = uninformative).",
        },
        "length_penalty_sweep": sweep,
        "test_final": {
            "summary": run_summary(
                test_rows, load_report(Path(args.test_report)) if args.test_report else None
            ),
            "confidence_calibration": {
                "renormalized": precision_coverage(
                    test_rows, "confidence", RENORM_THRESHOLDS
                ),
                "raw": precision_coverage(
                    test_rows, "raw_confidence", RAW_THRESHOLDS
                ),
            },
            "discrimination": {
                "renormalized": discrimination(test_rows, "confidence"),
                "raw": discrimination(test_rows, "raw_confidence"),
            },
            "by_length": length_buckets(test_rows),
        },
    }

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(
        json.dumps(report, ensure_ascii=False, indent=1) + "\n",
        encoding="utf-8",
    )
    print(json.dumps(report, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
