"""Validation/test comparison report for the v2 global-norm fusion config.

Evaluates the legacy per-sample z-score fusion config and the new pooled
global-affine fusion config on the same splits with the same cached neural
scores. The test split is only ever scored once per config — no parameter
is selected here (selection happens exclusively in train_fusion_config on
the validation split).

Usage:
  PYTHONDONTWRITEBYTECODE=1 .venv/bin/python tools/report_fusion_global_norm.py \
      --dataset .rimeai/datasets/p0-librime-1.17.0-luna-simp.jsonl \
      --neural-model .rimeai/models/rimeai-ranker-s-24m-v1 \
      --language-model .rimeai/models/p0-char-ngram-v2.json.gz \
      --rime-dictionary .rimeai/rime/shared/luna_pinyin.dict.yaml \
      --legacy-config .rimeai/models/rimeai-ranker-s-24m-fusion-v2.json \
      --new-config .rimeai/models/rimeai-ranker-s-24m-fusion-v3-candidate.json \
      --output .rimeai/reports/fusion-global-norm-v3.json
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from statistics import fmean
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from collections.abc import Mapping, Sequence  # noqa: E402

from rimeai_eval.dataset import load_dataset  # noqa: E402
from rimeai_runtime.neural_ranker import (  # noqa: E402
    HybridSemanticRanker,
    build_ranker_examples,
    load_neural_ranker,
)
from rimeai_runtime.ngram_ranker import load_ngram_model  # noqa: E402
from rimeai_runtime.pinyin_guard import PinyinGuard  # noqa: E402

DAEMON_MIN_CONFIDENCE = 0.55


def _percentile(values: Sequence[float], fraction: float) -> float:
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, round(fraction * (len(ordered) - 1))))
    return ordered[index]


def _evaluate(
    ranker: HybridSemanticRanker,
    examples: Sequence[Any],
    *,
    neural_cache: dict[str, list[float]],
    ngram_cache: dict[str, list[float]],
) -> dict[str, Any]:
    """Score one config over examples, overall plus per-candidate-count cuts.

    Metrics:
    - raw_*: fusion top-1 ignoring the change threshold entirely.
    - calibrated_*: changes whose fused margin >= config threshold (the
      selection metric used by train_fusion_config).
    - effective_*: changes the daemon would actually apply
      (returned confidence >= DAEMON_MIN_CONFIDENCE).
    """
    per_example: list[dict[str, Any]] = []
    for example in examples:
        neural_raw = neural_cache[example.sample_id]
        ngram_raw = ngram_cache[example.sample_id]
        ranking, confidence = ranker.rank_candidates(
            context=example.context,
            pinyin=example.pinyin,
            candidates=list(example.candidates),
        )
        predicted = example.candidates.index(ranking[0])
        opposing = max(range(len(neural_raw)), key=lambda i: neural_raw[i]) != max(
            range(len(ngram_raw)), key=lambda i: ngram_raw[i]
        )
        per_example.append(
            {
                "eligible": len(example.candidates),
                "opposing": opposing,
                "baseline_correct": example.label == 0,
                "model_correct": predicted == example.label,
                "raw_changed": predicted != 0,
                "confidence": confidence,
            }
        )

    def summarize(rows: Sequence[Mapping[str, Any]]) -> dict[str, Any]:
        samples = len(rows)
        if not samples:
            return {"samples": 0}
        calibrated = [
            row
            for row in rows
            if row["raw_changed"] and row["confidence"] >= 0.9  # see note below
        ]
        # The confidence formula maps margin >= threshold onto
        # confidence >= target_precision >= 0.9, so the calibrated cut is
        # equivalent to margin >= threshold whenever target_precision >= 0.9.
        # Reuse the returned confidence to avoid duplicating the margin math.
        effective = [
            row
            for row in rows
            if row["raw_changed"] and row["confidence"] >= DAEMON_MIN_CONFIDENCE
        ]
        return {
            "samples": samples,
            "baseline_top1_accuracy": (
                sum(row["baseline_correct"] for row in rows) / samples
            ),
            "top1_accuracy": sum(row["model_correct"] for row in rows) / samples,
            "raw_changed": sum(row["raw_changed"] for row in rows),
            "calibrated_changed": len(calibrated),
            "calibrated_wins": sum(
                row["model_correct"] and not row["baseline_correct"]
                for row in calibrated
            ),
            "calibrated_losses": sum(
                not row["model_correct"] and row["baseline_correct"]
                for row in calibrated
            ),
            "effective_changed": len(effective),
            "effective_wins": sum(
                row["model_correct"] and not row["baseline_correct"]
                for row in effective
            ),
            "effective_losses": sum(
                not row["model_correct"] and row["baseline_correct"]
                for row in effective
            ),
        }

    two = [row for row in per_example if row["eligible"] == 2]
    two_opposing = [row for row in two if row["opposing"]]
    return {
        "overall": summarize(per_example),
        "eligible_count_2": summarize(two),
        "eligible_count_2_opposing": summarize(two_opposing),
    }


def _write_atomic_json(path: Path, payload: dict[str, Any]) -> None:
    """reveal C-F8：报告原子写（临时文件 + fsync + os.replace），
    与仓库既有 _write_atomic_json 模式一致——中断不再留下半份报告。"""
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp")
    with temporary.open("w", encoding="utf-8") as file:
        json.dump(payload, file, ensure_ascii=False, sort_keys=True, indent=2)
        file.write("\n")
        file.flush()
        os.fsync(file.fileno())
    os.replace(temporary, path)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset", required=True, type=Path)
    parser.add_argument("--neural-model", required=True, type=Path)
    parser.add_argument("--language-model", required=True, type=Path)
    parser.add_argument("--rime-dictionary", required=True, type=Path)
    parser.add_argument("--legacy-config", required=True, type=Path)
    parser.add_argument("--new-config", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    dataset = load_dataset(args.dataset)
    guard = PinyinGuard.from_rime_dictionary(args.rime_dictionary)
    neural = load_neural_ranker(args.neural_model, guard, device="auto")
    ngram = load_ngram_model(args.language_model)
    legacy = HybridSemanticRanker(neural, ngram, args.legacy_config)
    new = HybridSemanticRanker(neural, ngram, args.new_config)
    report: dict[str, Any] = {
        "schema_version": 1,
        "report_type": "fusion-global-norm-v3",
        "commands": {
            "train_new_config": (
                "PYTHONDONTWRITEBYTECODE=1 .venv/bin/python -m rimeai_eval "
                "train-neural-fusion .rimeai/datasets/"
                "p0-librime-1.17.0-luna-simp.jsonl --neural-model .rimeai/models/"
                "rimeai-ranker-s-24m-v1 --language-model .rimeai/models/"
                "p0-char-ngram-v2.json.gz --rime-dictionary .rimeai/rime/shared/"
                "luna_pinyin.dict.yaml --output .rimeai/models/"
                "rimeai-ranker-s-24m-fusion-v3-candidate.json --target-precision 0.9"
            ),
            "report": (
                "PYTHONDONTWRITEBYTECODE=1 .venv/bin/python "
                "tools/report_fusion_global_norm.py (this file, see argparse)"
            ),
        },
        "dataset_sha256": dataset.sha256,
        "daemon_min_confidence": DAEMON_MIN_CONFIDENCE,
        "configs": {
            "legacy_v1": {
                "path": str(args.legacy_config),
                "fusion_type": legacy.config.fusion_type,
                "neural_weight": legacy.config.neural_weight,
                "margin_threshold": legacy.config.margin_threshold,
                "artifact_id": legacy.config.artifact_id,
            },
            "new_v2": {
                "path": str(args.new_config),
                "fusion_type": new.config.fusion_type,
                "neural_weight": new.config.neural_weight,
                "margin_threshold": new.config.margin_threshold,
                "artifact_id": new.config.artifact_id,
                "score_normalization": {
                    "neural_mean": new.config.neural_mean,
                    "neural_std": new.config.neural_std,
                    "ngram_mean": new.config.ngram_mean,
                    "ngram_std": new.config.ngram_std,
                },
            },
        },
    }

    splits: dict[str, Any] = {}
    for split in ("validation", "test"):
        examples = build_ranker_examples(dataset.samples, split=split)
        neural_cache: dict[str, list[float]] = {}
        ngram_cache: dict[str, list[float]] = {}
        for example in examples:
            neural_cache[example.sample_id] = neural._scores(
                context=example.context,
                pinyin=example.pinyin,
                candidates=example.candidates,
                baseline_indices=example.baseline_indices,
            )
            ngram_cache[example.sample_id] = [
                ngram._candidate_score(
                    example.context,
                    example.candidates[offset],
                    example.baseline_indices[offset],
                )
                for offset in range(len(example.candidates))
            ]
        legacy_stats = _evaluate(
            legacy, examples, neural_cache=neural_cache, ngram_cache=ngram_cache
        )
        new_stats = _evaluate(
            new, examples, neural_cache=neural_cache, ngram_cache=ngram_cache
        )
        splits[split] = {
            "legacy_v1": legacy_stats,
            "new_v2": new_stats,
        }

    report["splits"] = splits
    report["latency_note"] = {
        "legacy_v1_ms": {
            "mean": fmean(legacy.attempt_latencies_ms),
            "p95": _percentile(legacy.attempt_latencies_ms, 0.95),
        },
        "new_v2_ms": {
            "mean": fmean(new.attempt_latencies_ms),
            "p95": _percentile(new.attempt_latencies_ms, 0.95),
        },
        "note": (
            "Latency measured under heavy parallel load; informative only, "
            "not a conclusion (per task brief). v2 adds only four float "
            "affine ops per candidate over v1's z-score path."
        ),
    }

    _write_atomic_json(args.output, report)
    print(json.dumps(report["splits"], ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
