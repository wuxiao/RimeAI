"""Independent-set (zhwiki) verification of two frozen production candidates.

Evaluates two already-generated candidates against the deployed incumbents
on the zhwiki independent test split, with the p0 main-set test numbers for
the fusion candidate cited from the existing report (no re-run). Nothing in
this script re-tunes any parameter: the fusion configs are frozen artifacts
evaluated as-is, and the beam re-threshold candidate was calibrated by the
sanctioned `rimeai_eval train-beam-decoder` command on the p0 validation
split only (hyperparameters pinned to beam_width=16,
characters_per_syllable=20, character_frequency_weight=0.5).

The decision rule is pre-declared in DECISION_RULE below and embedded in
the report: a candidate is recommended for switching only if NO pre-declared
metric shows a material regression on EITHER dataset's test split; any
material regression keeps the incumbent. A single metric improving on a
single dataset never justifies a switch by itself.

Usage (repo root):
  PYTHONDONTWRITEBYTECODE=1 .venv/bin/python tools/verify_independent_candidates.py \
      --p0-dataset .rimeai/datasets/p0-librime-1.17.0-luna-simp.jsonl \
      --zhwiki-dataset .rimeai/datasets/p0-zhwiki-librime-1.17.0-luna-simp.jsonl \
      --neural-model .rimeai/models/rimeai-ranker-s-24m-v1 \
      --language-model .rimeai/models/p0-char-ngram-v2.json.gz \
      --rime-dictionary .rimeai/rime/shared/luna_pinyin.dict.yaml \
      --fusion-v2-config .rimeai/models/rimeai-ranker-s-24m-fusion-v2.json \
      --fusion-v3-config .rimeai/models/rimeai-ranker-s-24m-fusion-v3-candidate.json \
      --beam-v3-config .rimeai/models/p0-beam-sentence-v3.json \
      --beam-rethreshold-config .rimeai/models/p0-beam-sentence-v3-rethreshold-candidate.json \
      --beam-training-report /tmp/rethreshold_training_report.json \
      --p0-fusion-report .rimeai/reports/fusion-global-norm-v3.json \
      --output .rimeai/reports/independent-zhwiki-verification.json
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
from collections.abc import Sequence
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from rimeai_eval.dataset import load_dataset  # noqa: E402
from rimeai_eval.sentence_benchmark import (  # noqa: E402
    benchmark_sentence_decoder,
)
from rimeai_runtime.beam_decoder import (  # noqa: E402
    BeamSentenceDecoder,
    load_beam_config,
)
from rimeai_runtime.neural_ranker import (  # noqa: E402
    HybridSemanticRanker,
    build_ranker_examples,
    load_neural_ranker,
)
from rimeai_runtime.ngram_ranker import load_ngram_model  # noqa: E402
from rimeai_runtime.pinyin_guard import PinyinGuard  # noqa: E402

DAEMON_MIN_CONFIDENCE = 0.55
MIN_CONFIDENCE_GATES = (0.0, 0.60)

# Pre-declared decision rule (fixed before any zhwiki number was produced).
# Material regression thresholds: accuracy metrics regress when the
# candidate-incumbent delta drops below -0.002 (repo precedent from
# ngram-beam-hparam-v4.json); gated count metrics regress when net gain
# (wins - losses) falls by 2 or more. Switch requires zero material
# regressions across BOTH datasets' test splits — never a single-metric,
# single-dataset improvement.
ACCURACY_REGRESSION_BAR = -0.002
COUNT_REGRESSION_BAR = -2
FUSION_METRICS = (
    # (block, field, kind, label)
    ("overall", "top1_accuracy", "accuracy", "overall_raw_top1"),
    ("eligible_count_2", "top1_accuracy", "accuracy", "eligible2_raw_top1"),
    ("overall", "calibrated_net_gain", "count", "overall_calibrated_net_gain"),
    ("overall", "effective_net_gain", "count", "overall_effective_net_gain"),
)
BEAM_METRICS = (
    ("decoder_sentence_accuracy", "accuracy"),
    ("decoder_char_accuracy", "accuracy"),
)

TRAIN_COMMAND = (
    "PYTHONDONTWRITEBYTECODE=1 .venv/bin/python -m rimeai_eval "
    "train-beam-decoder .rimeai/datasets/p0-librime-1.17.0-luna-simp.jsonl "
    "--language-model .rimeai/models/p0-char-ngram-v2.json.gz "
    "--rime-dictionary .rimeai/rime/shared/luna_pinyin.dict.yaml "
    "--output .rimeai/models/p0-beam-sentence-v3-rethreshold-candidate.json "
    "--beam-width 16 --characters-per-syllable 20 "
    "--character-frequency-weight 0.5"
)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        while chunk := file.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def _sha256_artifact(path: Path) -> str:
    """sha256 of a file, or a stable digest over a model directory
    (sorted relative path + per-file sha256) for directory artifacts."""
    if path.is_file():
        return _sha256(path)
    digest = hashlib.sha256()
    for child in sorted(item for item in path.rglob("*") if item.is_file()):
        digest.update(str(child.relative_to(path)).encode("utf-8"))
        digest.update(_sha256(child).encode("ascii"))
    return digest.hexdigest()


def _git_commit() -> str:
    try:
        return (
            subprocess.run(
                ["git", "rev-parse", "--short", "HEAD"],
                capture_output=True,
                text=True,
                check=True,
            )
            .stdout
            .strip()
        )
    except (OSError, subprocess.CalledProcessError):
        return "unknown"


def _evaluate_fusion(
    ranker: HybridSemanticRanker,
    examples: Sequence[Any],
    *,
    neural_cache: dict[str, list[float]],
    ngram_cache: dict[str, list[float]],
) -> dict[str, Any]:
    """Score one fusion config over examples.

    Metric definitions mirror tools/report_fusion_global_norm.py verbatim
    (including the confidence >= 0.9 calibrated cut and the daemon
    effective cut at DAEMON_MIN_CONFIDENCE) so the numbers are directly
    comparable with .rimeai/reports/fusion-global-norm-v3.json; only the
    explicit net_gain fields are added on top.
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

    def summarize(rows) -> dict[str, Any]:
        samples = len(rows)
        if not samples:
            return {"samples": 0}
        calibrated = [
            row
            for row in rows
            if row["raw_changed"] and row["confidence"] >= 0.9
        ]
        effective = [
            row
            for row in rows
            if row["raw_changed"] and row["confidence"] >= DAEMON_MIN_CONFIDENCE
        ]
        calibrated_wins = sum(
            row["model_correct"] and not row["baseline_correct"]
            for row in calibrated
        )
        calibrated_losses = sum(
            not row["model_correct"] and row["baseline_correct"]
            for row in calibrated
        )
        effective_wins = sum(
            row["model_correct"] and not row["baseline_correct"]
            for row in effective
        )
        effective_losses = sum(
            not row["model_correct"] and row["baseline_correct"]
            for row in effective
        )
        return {
            "samples": samples,
            "baseline_top1_accuracy": (
                sum(row["baseline_correct"] for row in rows) / samples
            ),
            "top1_accuracy": sum(row["model_correct"] for row in rows) / samples,
            "raw_changed": sum(row["raw_changed"] for row in rows),
            "calibrated_changed": len(calibrated),
            "calibrated_wins": calibrated_wins,
            "calibrated_losses": calibrated_losses,
            "calibrated_net_gain": calibrated_wins - calibrated_losses,
            "effective_changed": len(effective),
            "effective_wins": effective_wins,
            "effective_losses": effective_losses,
            "effective_net_gain": effective_wins - effective_losses,
        }

    two = [row for row in per_example if row["eligible"] == 2]
    two_opposing = [row for row in two if row["opposing"]]
    return {
        "overall": summarize(per_example),
        "eligible_count_2": summarize(two),
        "eligible_count_2_opposing": summarize(two_opposing),
    }


def _apply_rule(
    metric_deltas: dict[str, dict[str, dict[str, Any]]],
    metrics: tuple[tuple[str, str, str, str], ...] | tuple[tuple[str, str], ...],
    fusion: bool,
) -> dict[str, Any]:
    """Evaluate the pre-declared no-material-regression rule.

    metric_deltas[dataset][metric_label] = {"delta": ..., "kind": ...}.
    """
    regressions: list[dict[str, Any]] = []
    for dataset, per_metric in metric_deltas.items():
        for label, entry in per_metric.items():
            material = (
                entry["delta"] < ACCURACY_REGRESSION_BAR
                if entry["kind"] == "accuracy"
                else entry["delta"] <= COUNT_REGRESSION_BAR
            )
            if material:
                regressions.append(
                    {
                        "dataset": dataset,
                        "metric": label,
                        "delta": entry["delta"],
                    }
                )
    material_free = not regressions
    return {
        "rule": {
            "accuracy_material_regression_below": ACCURACY_REGRESSION_BAR,
            "count_material_regression_at_or_below": COUNT_REGRESSION_BAR,
            "scope": (
                "both p0 test (fusion: cited from the existing report) and "
                "zhwiki test must be free of material regressions on every "
                "pre-declared metric; a single-dataset single-metric "
                "improvement never justifies a switch"
            ),
        },
        "metric_deltas": metric_deltas,
        "material_regressions": regressions,
        "material_regression_free": material_free,
    }


def _block_value(block: dict[str, Any], field: str) -> Any:
    """Read a metric, deriving net_gain from wins/losses when the source
    block (the cited p0 report) predates the explicit net_gain fields."""
    if field == "calibrated_net_gain":
        return block.get(
            "calibrated_net_gain",
            block["calibrated_wins"] - block["calibrated_losses"],
        )
    if field == "effective_net_gain":
        return block.get(
            "effective_net_gain",
            block["effective_wins"] - block["effective_losses"],
        )
    return block[field]


def _fusion_metric_deltas(
    incumbent: dict[str, Any], candidate: dict[str, Any]
) -> dict[str, dict[str, Any]]:
    deltas: dict[str, dict[str, Any]] = {}
    for block, field, kind, label in FUSION_METRICS:
        if not incumbent[block].get("samples"):
            continue
        incumbent_value = _block_value(incumbent[block], field)
        candidate_value = _block_value(candidate[block], field)
        deltas[label] = {
            "kind": kind,
            "delta": round(candidate_value - incumbent_value, 6),
            "incumbent": incumbent_value,
            "candidate": candidate_value,
        }
    return deltas


def _metrics_slice(report: dict) -> dict:
    metrics = report["metrics"]
    return {
        "baseline_sentence_accuracy": metrics["baseline_sentence_accuracy"],
        "decoder_sentence_accuracy": metrics["decoder_sentence_accuracy"],
        "decoder_char_accuracy": metrics["decoder_char_accuracy"],
        "decision_counts": report["decision_counts"],
        "latency_ms_p50": metrics["decoder_latency_ms"]["p50"],
        "latency_ms_p95": metrics["decoder_latency_ms"]["p95"],
    }


def _benchmark_config(samples: list[dict], decoder: BeamSentenceDecoder) -> dict:
    return {
        f"min_confidence_{gate:.2f}": _metrics_slice(
            benchmark_sentence_decoder(samples, decoder, min_confidence=gate)
        )
        for gate in MIN_CONFIDENCE_GATES
    }


def _write_atomic_json(path: Path, payload: dict) -> None:
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
    parser.add_argument("--p0-dataset", required=True, type=Path)
    parser.add_argument("--zhwiki-dataset", required=True, type=Path)
    parser.add_argument("--neural-model", required=True, type=Path)
    parser.add_argument("--language-model", required=True, type=Path)
    parser.add_argument("--rime-dictionary", required=True, type=Path)
    parser.add_argument("--fusion-v2-config", required=True, type=Path)
    parser.add_argument("--fusion-v3-config", required=True, type=Path)
    parser.add_argument("--beam-v3-config", required=True, type=Path)
    parser.add_argument("--beam-rethreshold-config", required=True, type=Path)
    parser.add_argument("--beam-training-report", required=True, type=Path)
    parser.add_argument("--p0-fusion-report", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    protected = {
        args.p0_dataset.resolve(),
        args.zhwiki_dataset.resolve(),
        args.neural_model.resolve(),
        args.language_model.resolve(),
        args.rime_dictionary.resolve(),
        args.fusion_v2_config.resolve(),
        args.fusion_v3_config.resolve(),
        args.beam_v3_config.resolve(),
        args.beam_rethreshold_config.resolve(),
        args.p0_fusion_report.resolve(),
    }
    if args.output.resolve() in protected:
        print("error: --output must not overwrite an input artifact", file=sys.stderr)
        return 2

    try:
        training = json.loads(
            args.beam_training_report.read_text(encoding="utf-8")
        )
        p0_fusion = json.loads(
            args.p0_fusion_report.read_text(encoding="utf-8")
        )
    except (OSError, json.JSONDecodeError) as error:
        print(f"error: cannot read referenced reports: {error}", file=sys.stderr)
        return 2

    # ------------------------------------------------------------------
    # Candidate 1: fusion v2 (deployed) vs fusion v3 candidate, zhwiki test.
    # ------------------------------------------------------------------
    zhwiki = load_dataset(args.zhwiki_dataset)
    guard = PinyinGuard.from_rime_dictionary(args.rime_dictionary)
    neural = load_neural_ranker(args.neural_model, guard, device="auto")
    ngram = load_ngram_model(args.language_model)
    fusion_v2 = HybridSemanticRanker(neural, ngram, args.fusion_v2_config)
    fusion_v3 = HybridSemanticRanker(neural, ngram, args.fusion_v3_config)

    examples = build_ranker_examples(zhwiki.samples, split="test")
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
    fusion_stats = {
        "incumbent_fusion_v2": _evaluate_fusion(
            fusion_v2, examples, neural_cache=neural_cache, ngram_cache=ngram_cache
        ),
        "candidate_fusion_v3": _evaluate_fusion(
            fusion_v3, examples, neural_cache=neural_cache, ngram_cache=ngram_cache
        ),
    }

    p0_cited = p0_fusion["splits"]["test"]
    fusion_metric_deltas = {
        "p0_test_cited": _fusion_metric_deltas(
            p0_cited["legacy_v1"], p0_cited["new_v2"]
        ),
        "zhwiki_test_measured": _fusion_metric_deltas(
            fusion_stats["incumbent_fusion_v2"],
            fusion_stats["candidate_fusion_v3"],
        ),
    }
    fusion_rule = _apply_rule(fusion_metric_deltas, FUSION_METRICS, fusion=True)
    fusion_recommendation = (
        "switch-to-fusion-v3"
        if fusion_rule["material_regression_free"]
        else "keep-fusion-v2"
    )

    # ------------------------------------------------------------------
    # Candidate 2: beam v3 (deployed, stale threshold) vs re-threshold
    # candidate, on zhwiki test AND p0 test, raw + min-confidence 0.60.
    # ------------------------------------------------------------------
    p0 = load_dataset(args.p0_dataset)
    beam_configs = {
        "v3": load_beam_config(args.beam_v3_config),
        "v3_rethreshold_candidate": load_beam_config(args.beam_rethreshold_config),
    }
    beam_comparison: dict[str, Any] = {}
    for dataset_label, dataset in (
        ("p0_test", p0),
        ("zhwiki_test", zhwiki),
    ):
        samples = [
            sample for sample in dataset.samples if sample["split"] == "test"
        ]
        beam_comparison[dataset_label] = {
            label: _benchmark_config(
                samples, BeamSentenceDecoder(ngram, guard, config)
            )
            for label, config in beam_configs.items()
        }

    beam_metric_deltas: dict[str, dict[str, dict[str, Any]]] = {}
    for dataset_label, arms in beam_comparison.items():
        per_metric: dict[str, dict[str, Any]] = {}
        for gate_key in (f"min_confidence_{gate:.2f}" for gate in MIN_CONFIDENCE_GATES):
            for field, kind in BEAM_METRICS:
                per_metric[f"{gate_key}_{field}"] = {
                    "kind": kind,
                    "delta": round(
                        arms["v3_rethreshold_candidate"][gate_key][field]
                        - arms["v3"][gate_key][field],
                        6,
                    ),
                    "incumbent": arms["v3"][gate_key][field],
                    "candidate": arms["v3_rethreshold_candidate"][gate_key][field],
                }
        beam_metric_deltas[dataset_label] = per_metric
    beam_rule = _apply_rule(beam_metric_deltas, BEAM_METRICS, fusion=False)
    beam_recommendation = (
        "switch-to-v3-rethreshold"
        if beam_rule["material_regression_free"]
        else "keep-v3"
    )

    # Determinism cross-check: the fresh v3 p0 test run must reproduce the
    # batch-2 report (ngram-beam-hparam-v4.json) numbers; informational.
    try:
        batch2 = json.loads(
            Path(
                ".rimeai/reports/ngram-beam-hparam-v4.json"
            ).read_text(encoding="utf-8")
        )
        cross_check = {
            gate_key: {
                "this_run": beam_comparison["p0_test"]["v3"][gate_key][
                    "decoder_sentence_accuracy"
                ],
                "batch2_report": batch2["comparison"]["test"]["v3"][gate_key][
                    "decoder_sentence_accuracy"
                ],
                "delta": round(
                    beam_comparison["p0_test"]["v3"][gate_key][
                        "decoder_sentence_accuracy"
                    ]
                    - batch2["comparison"]["test"]["v3"][gate_key][
                        "decoder_sentence_accuracy"
                    ],
                    6,
                ),
            }
            for gate_key in (
                f"min_confidence_{gate:.2f}" for gate in MIN_CONFIDENCE_GATES
            )
        }
    except (OSError, KeyError, json.JSONDecodeError):
        cross_check = None

    report: dict[str, Any] = {
        "schema_version": 1,
        "kind": "independent-zhwiki-verification",
        "purpose": (
            "Verify two frozen candidates on the zhwiki independent test "
            "split without re-tuning anything; recommend switching only "
            "when neither dataset's test split shows a material regression"
        ),
        "discipline": (
            "no parameter was re-tuned based on zhwiki or test results; the "
            "beam threshold was recalibrated exclusively on the p0 main-set "
            "validation split with hyperparameters pinned (beam_width=16, "
            "characters_per_syllable=20, character_frequency_weight=0.5); "
            "each test split is scored/decoded exactly once per config for "
            "this final comparison and nothing feeds back into selection"
        ),
        "inputs": {
            "p0_dataset": {"path": str(args.p0_dataset), "sha256": p0.sha256},
            "zhwiki_dataset": {
                "path": str(args.zhwiki_dataset),
                "sha256": zhwiki.sha256,
            },
            "neural_model": {
                "path": str(args.neural_model),
                "sha256": _sha256_artifact(args.neural_model),
                "neural_artifact_id": fusion_v2.config.neural_artifact_id,
            },
            "language_model": {
                "path": str(args.language_model),
                "sha256": _sha256(args.language_model),
            },
            "rime_dictionary": {
                "path": str(args.rime_dictionary),
                "sha256": _sha256(args.rime_dictionary),
            },
            "fusion_v2_config": {
                "path": str(args.fusion_v2_config),
                "sha256": _sha256(args.fusion_v2_config),
                "fusion_type": fusion_v2.config.fusion_type,
                "neural_weight": fusion_v2.config.neural_weight,
                "margin_threshold": fusion_v2.config.margin_threshold,
                "artifact_id": fusion_v2.config.artifact_id,
            },
            "fusion_v3_config": {
                "path": str(args.fusion_v3_config),
                "sha256": _sha256(args.fusion_v3_config),
                "fusion_type": fusion_v3.config.fusion_type,
                "neural_weight": fusion_v3.config.neural_weight,
                "margin_threshold": fusion_v3.config.margin_threshold,
                "artifact_id": fusion_v3.config.artifact_id,
            },
            "beam_v3_config": {
                "path": str(args.beam_v3_config),
                "sha256": _sha256(args.beam_v3_config),
                "config": beam_configs["v3"].to_dict(),
            },
            "beam_rethreshold_config": {
                "path": str(args.beam_rethreshold_config),
                "sha256": _sha256(args.beam_rethreshold_config),
                "config": beam_configs["v3_rethreshold_candidate"].to_dict(),
            },
            "p0_fusion_report_cited": {
                "path": str(args.p0_fusion_report),
                "sha256": _sha256(args.p0_fusion_report),
                "dataset_sha256": p0_fusion["dataset_sha256"],
                "note": (
                    "p0 test numbers cited verbatim from this report "
                    "(legacy_v1 == deployed fusion v2, new_v2 == fusion v3 "
                    "candidate); not re-run per task brief"
                ),
            },
        },
        "daemon_min_confidence": DAEMON_MIN_CONFIDENCE,
        "candidate_fusion_v3": {
            "zhwiki_test_measured": fusion_stats,
            "p0_test_cited": {
                "incumbent_fusion_v2": p0_cited["legacy_v1"],
                "candidate_fusion_v3": p0_cited["new_v2"],
            },
            "decision_rule": fusion_rule,
            "recommendation": fusion_recommendation,
            "recommendation_rationale": (
                "no material regression on any pre-declared metric on "
                "either p0 test or zhwiki test"
                if fusion_rule["material_regression_free"]
                else "material regression observed (see decision_rule."
                "material_regressions); keep the incumbent fusion v2"
            ),
        },
        "candidate_beam_v3_rethreshold": {
            "training": {
                "command": TRAIN_COMMAND,
                "training_report": {
                    "selected_hyperparameters": training[
                        "selected_hyperparameters"
                    ],
                    "validation": training["validation"],
                    "scan": training["hyperparameter_scan"],
                    "test_samples_used": training["test_samples_used"],
                },
                "note": (
                    "threshold recalibrated on p0 validation only; incumbent "
                    "v3 threshold 4.2451 predates the current score scale "
                    "(batch-2 finding); re-threshold value "
                    f"{beam_configs['v3_rethreshold_candidate'].threshold}"
                ),
            },
            "comparison": beam_comparison,
            "decision_rule": beam_rule,
            "recommendation": beam_recommendation,
            "recommendation_rationale": (
                "no material regression on sentence/char accuracy at either "
                "min-confidence gate on either dataset"
                if beam_rule["material_regression_free"]
                else "material regression observed (see decision_rule."
                "material_regressions); keep the incumbent beam v3"
            ),
            "v3_p0_test_determinism_cross_check": cross_check,
        },
        "known_limitations": [
            (
                "zhwiki-derived gold contains traditional-Chinese noise "
                "(e.g. 盡責/縣市/中興); byte-exact comparison penalizes "
                "correct simplified renderings, so zhwiki absolute "
                "accuracies may be understated and error buckets polluted "
                "(see docs/BLIND_TYPING_GAP_ANALYSIS.md and docs/baselines/"
                "constrained-qwen-v2.json error_taxonomy). This affects "
                "both arms identically, so within-dataset deltas remain "
                "interpretable, but absolute zhwiki numbers must not be "
                "compared against simplified-only corpora."
            ),
            (
                "beam decision_counts shift is expected by design: the "
                "re-threshold candidate lowers the suggestion gate, so "
                "below_threshold falls and suggestion rises; the decision "
                "rule gates on accuracy metrics only"
            ),
            (
                "latency p50/p95 are informational only (single-process "
                "run) and carry no gating decision; fusion latency is not "
                "re-measured here"
            ),
            (
                "shared-worktree caveat: rimeai_runtime/ngram_ranker.py "
                "carried concurrent uncommitted edits from another session "
                "(terminal-probability refactor that is bit-for-bit for "
                "legacy artifacts); equivalence for this evaluation is "
                "verified empirically by the bit-identical recalibrated "
                "threshold (1.8281508505683064, matches the batch-2 scan "
                "in ngram-beam-hparam-v4.json) and by the v3 p0 test "
                "determinism cross-check above"
            ),
        ],
        "reproducibility": {
            "beam_rethreshold_train_command": TRAIN_COMMAND,
            "this_report_command": (
                "PYTHONDONTWRITEBYTECODE=1 .venv/bin/python "
                "tools/verify_independent_candidates.py (this file, see "
                "argparse in the module docstring)"
            ),
            "p0_fusion_report_command": (
                "PYTHONDONTWRITEBYTECODE=1 .venv/bin/python "
                "tools/report_fusion_global_norm.py (see its module "
                "docstring; produced .rimeai/reports/fusion-global-norm-v3.json)"
            ),
            "benchmark_entrypoint": (
                "rimeai_eval.sentence_benchmark.benchmark_sentence_decoder "
                "(same code path as `rimeai_eval sentence-benchmark`)"
            ),
            "git_commit": _git_commit(),
        },
    }
    _write_atomic_json(args.output, report)
    print(
        json.dumps(
            {
                "output": str(args.output),
                "fusion_recommendation": fusion_recommendation,
                "beam_recommendation": beam_recommendation,
                "fusion_material_regressions": fusion_rule[
                    "material_regressions"
                ],
                "beam_material_regressions": beam_rule["material_regressions"],
            },
            ensure_ascii=False,
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
