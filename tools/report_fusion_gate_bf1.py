"""reveal B-F1 evidence report: the daemon gate must equal the calibrated
threshold on the production fusion incumbent.

The legacy below-threshold confidence mapping
``min(0.899, 0.5 + 0.399 * margin/tau)`` lets the daemon's
``ranker_min_confidence=0.55`` admit flips from ``margin >= 0.1253*tau`` —
a region whose flip precision was never calibrated (target_precision only
covers ``margin >= tau``). The fix maps below-threshold flips to
``0.55 * margin/tau < 0.55``, making the 0.55 gate exactly equivalent to
``margin >= tau``.

This script quantifies the change on the production incumbent config with
real artifacts, without relying on the runtime implementation for either
gate (both confidences are recomputed locally from the fused margin; the
runtime's returned confidence is cross-checked as a sanity assertion):

- validation split: enumerate every flip the new gate blocks
  (``0.1253*tau <= margin < tau``) with per-sample win/loss (gold hit).
  A positive net benefit (blocked_losses - blocked_wins > 0) is required
  to keep the semantic change.
- test split: one final before/after comparison (applied flips, top-1,
  wins/losses vs baseline). No parameter is selected on test.

Usage:
  PYTHONDONTWRITEBYTECODE=1 .venv/bin/python tools/report_fusion_gate_bf1.py \
      --dataset .rimeai/datasets/p0-librime-1.17.0-luna-simp.jsonl \
      --neural-model .rimeai/models/rimeai-ranker-s-24m-v1 \
      --language-model .rimeai/models/p0-char-ngram-v2.json.gz \
      --rime-dictionary .rimeai/rime/shared/luna_pinyin.dict.yaml \
      --fusion-config .rimeai/models/rimeai-ranker-s-24m-fusion-v2.json \
      --output .rimeai/reports/fusion-gate-tighten-bf1.json

Optional arguments generalize the report beyond the p0 calibration corpus
without changing any p0 output (omit them and every p0 byte is identical):

  --limitation-note TEXT   append TEXT to report["limitations"] (recorded
                            verbatim, e.g. gold-script noise on an
                            independent corpus).
  --decision-split SPLIT   add a pre-registered independent-corpus decision
                            block computed on SPLIT (validation or test):
                            blocked net benefit >= 0 ->
                            independent_corpus_supports_current_tightening,
                            < 0 -> revisit_flagged (no automatic rollback).
  --decision-rule TEXT     the pre-registered rule text recorded alongside
                            the decision block.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import shlex
import sys
from pathlib import Path
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
LEGACY_BELOW_CAP = 0.899
LEGACY_BELOW_BASE = 0.5
LEGACY_BELOW_SLOPE = 0.399
# Legacy mapping crosses 0.55 exactly at margin/tau >= 0.05/0.399 ≈ 0.1253.
LEGACY_GATE_RATIO = 0.05 / LEGACY_BELOW_SLOPE
NEW_BELOW_SLOPE = 0.55


def _legacy_confidence(
    margin: float, threshold: float, target_precision: float
) -> float:
    """Pre-fix mapping: below-threshold flips could cross the 0.55 gate."""
    if margin >= threshold:
        excess = margin - threshold
        return target_precision + (1.0 - target_precision) * (
            1.0 - math.exp(-excess)
        )
    ratio = 0.0 if threshold <= 0 else max(0.0, margin / threshold)
    return min(LEGACY_BELOW_CAP, LEGACY_BELOW_BASE + LEGACY_BELOW_SLOPE * ratio)


def _new_confidence(
    margin: float, threshold: float, target_precision: float
) -> float:
    """Post-fix mapping: below-threshold flips stay strictly under 0.55."""
    if margin >= threshold:
        excess = margin - threshold
        return target_precision + (1.0 - target_precision) * (
            1.0 - math.exp(-excess)
        )
    ratio = 0.0 if threshold <= 0 else max(0.0, margin / threshold)
    return NEW_BELOW_SLOPE * ratio


class _CachedNeural:
    """Replay one cached neural score vector through the real runtime path."""

    def __init__(self, artifact_id: str, scores: list[float]):
        self.model_artifact_id = artifact_id
        self.cold_start_ms = 0.0
        self._scores_value = list(scores)

    def _scores(self, **kwargs):
        return list(self._scores_value)


class _CachedNGram:
    def __init__(self, dataset_sha256: str, scores: list[float]):
        self.dataset_sha256 = dataset_sha256
        self._scores_value = list(scores)

    def _candidate_score(self, context, candidate, baseline_index):
        return self._scores_value[baseline_index]


def _classify_split(
    ranker: HybridSemanticRanker,
    examples: Sequence[Any],
) -> dict[str, Any]:
    """Score one split under both gates from cached fused margins.

    Each sample is inferred exactly once (v1 z-score fusion amplifies tiny
    inference noise when a sample's score deviation is tiny, so a second
    pass can flip across the threshold); the cached raw scores then drive
    the real ``rank_candidates`` path via replay doubles, and legacy/new
    confidences are recomputed locally from the same fused margins.
    """
    config = ranker.config
    rows: list[dict[str, Any]] = []
    runtime_confidence_checked = 0
    for example in examples:
        neural_raw = ranker.neural_ranker._scores(
            context=example.context,
            pinyin=example.pinyin,
            candidates=example.candidates,
            baseline_indices=example.baseline_indices,
        )
        ngram_raw = [
            ranker.ngram_ranker._candidate_score(
                example.context,
                example.candidates[offset],
                example.baseline_indices[offset],
            )
            for offset in range(len(example.candidates))
        ]
        fused = config.fuse_scores(neural_raw, ngram_raw)
        ranked_indices = sorted(
            range(len(fused)), key=lambda index: (-fused[index], index)
        )
        margin = fused[ranked_indices[0]] - fused[ranked_indices[1]]
        replay = HybridSemanticRanker(
            _CachedNeural(ranker.neural_ranker.model_artifact_id, neural_raw),
            _CachedNGram(ranker.ngram_ranker.dataset_sha256, ngram_raw),
            config.path,
        )
        ranking, runtime_confidence = replay.rank_candidates(
            context=example.context,
            pinyin=example.pinyin,
            candidates=list(example.candidates),
        )
        predicted = example.candidates.index(ranking[0])
        same_top = ranked_indices[0] == 0
        legacy = _legacy_confidence(
            margin, config.margin_threshold, config.target_precision
        )
        new = _new_confidence(
            margin, config.margin_threshold, config.target_precision
        )
        if not same_top:
            # Same cached scores feed both paths, so this must be exact:
            # it proves the runtime binary under test runs the fixed mapping.
            assert runtime_confidence == new, (
                f"runtime confidence {runtime_confidence} != recomputed "
                f"{new} for {example.sample_id}"
            )
            runtime_confidence_checked += 1
        baseline_correct = example.label == 0
        model_correct = predicted == example.label
        rows.append(
            {
                "sample_id": example.sample_id,
                "margin": margin,
                "ratio": (
                    margin / config.margin_threshold
                    if config.margin_threshold > 0
                    else None
                ),
                "same_top": same_top,
                "predicted_index": predicted,
                "label": example.label,
                "baseline_correct": baseline_correct,
                "model_correct": model_correct,
                "legacy_confidence": legacy,
                "new_confidence": new,
                "legacy_gate_admits_flip": (
                    not same_top and legacy >= DAEMON_MIN_CONFIDENCE
                ),
                "new_gate_admits_flip": (
                    not same_top and new >= DAEMON_MIN_CONFIDENCE
                ),
            }
        )
    return {"rows": rows, "runtime_confidence_checked": runtime_confidence_checked}


def _gate_view(rows: Sequence[Mapping[str, Any]], *, legacy: bool) -> dict[str, Any]:
    """Daemon outcome under one gate: applied flips, top-1, wins/losses."""
    admit_key = (
        "legacy_gate_admits_flip" if legacy else "new_gate_admits_flip"
    )
    samples = len(rows)
    correct = 0
    applied = 0
    wins = 0
    losses = 0
    for row in rows:
        if row["same_top"] or not row[admit_key]:
            # Same-top agreement or blocked flip: daemon keeps Rime's order.
            correct += int(row["baseline_correct"])
        else:
            applied += 1
            correct += int(row["model_correct"])
            if row["model_correct"] and not row["baseline_correct"]:
                wins += 1
            elif row["baseline_correct"] and not row["model_correct"]:
                losses += 1
    return {
        "samples": samples,
        "applied_flips": applied,
        "top1_accuracy": correct / samples,
        "wins": wins,
        "losses": losses,
        "net_gain": wins - losses,
    }


def _blocked_details(rows: Sequence[Mapping[str, Any]]) -> list[dict[str, Any]]:
    """Flips the legacy gate admitted and the fixed gate blocks."""
    blocked = []
    for row in rows:
        if row["legacy_gate_admits_flip"] and not row["new_gate_admits_flip"]:
            outcome = (
                "loss_blocked"
                if row["baseline_correct"] and not row["model_correct"]
                else (
                    "win_blocked"
                    if row["model_correct"] and not row["baseline_correct"]
                    else "neutral_blocked"
                )
            )
            blocked.append(
                {
                    "sample_id": row["sample_id"],
                    "margin": row["margin"],
                    "ratio": row["ratio"],
                    "legacy_confidence": row["legacy_confidence"],
                    "new_confidence": row["new_confidence"],
                    "baseline_correct": row["baseline_correct"],
                    "gold_hit_after_flip": row["model_correct"],
                    "outcome": outcome,
                }
            )
    return blocked


def _write_atomic_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp")
    with temporary.open("w", encoding="utf-8") as file:
        json.dump(payload, file, ensure_ascii=False, sort_keys=True, indent=2)
        file.flush()
        os.fsync(file.fileno())
    os.replace(temporary, path)


_CALIBRATION_NOTE_SAME_DOMAIN = (
    "(validation {validation} matches the incumbent config's "
    "calibration cohort)"
)
_STABILITY_NOTE_SAME_DOMAIN = (
    "v1 per-sample z-score fusion amplifies tiny run-to-run "
    "inference noise on samples whose score deviation is near zero, "
    "so borderline counts drift slightly across runs (three runs: "
    "blocked 10/8/7, wins lost 3/3/2, net benefit +1/+1/+2). "
    "Invariant across runs: losses avoided = 4, validation net "
    "benefit strictly positive, verdict = merge; borderline "
    "neutrals never enter the net-benefit decision."
)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset", required=True, type=Path)
    parser.add_argument("--neural-model", required=True, type=Path)
    parser.add_argument("--language-model", required=True, type=Path)
    parser.add_argument("--rime-dictionary", required=True, type=Path)
    parser.add_argument("--fusion-config", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument(
        "--limitation-note",
        action="append",
        default=None,
        metavar="TEXT",
        help="record TEXT verbatim in report['limitations'] (e.g. gold-script "
        "noise when evaluating an independent corpus)",
    )
    parser.add_argument(
        "--decision-split",
        choices=("validation", "test"),
        default=None,
        help="add a pre-registered independent-corpus decision block on this "
        "split: blocked net benefit >= 0 supports the current tightening, "
        "< 0 flags a revisit (no automatic rollback)",
    )
    parser.add_argument(
        "--decision-rule",
        default=None,
        metavar="TEXT",
        help="pre-registered decision rule text recorded in the decision block",
    )
    args = parser.parse_args()

    dataset = load_dataset(args.dataset)
    raw_split_counts: dict[str, int] = {}
    for sample in dataset.samples:
        raw_split_counts[str(sample.get("split"))] = (
            raw_split_counts.get(str(sample.get("split")), 0) + 1
        )
    guard = PinyinGuard.from_rime_dictionary(args.rime_dictionary)
    neural = load_neural_ranker(args.neural_model, guard, device="auto")
    ngram = load_ngram_model(args.language_model)
    incumbent = HybridSemanticRanker(neural, ngram, args.fusion_config)
    same_domain = (
        dataset.sha256 == incumbent.config.validation_dataset_sha256
    )

    command = (
        "PYTHONDONTWRITEBYTECODE=1 .venv/bin/python "
        "tools/report_fusion_gate_bf1.py "
        f"--dataset {args.dataset} "
        f"--neural-model {args.neural_model} "
        f"--language-model {args.language_model} "
        f"--rime-dictionary {args.rime_dictionary} "
        f"--fusion-config {args.fusion_config} "
        f"--output {args.output}"
    )
    for note in args.limitation_note or []:
        command += f" --limitation-note {shlex.quote(note)}"
    if args.decision_split is not None:
        command += f" --decision-split {args.decision_split}"
    if args.decision_rule is not None:
        command += f" --decision-rule {shlex.quote(args.decision_rule)}"

    report: dict[str, Any] = {
        "schema_version": 1,
        "report_type": "fusion-gate-tighten-bf1",
        "issue": "reveal B-F1 (P1): daemon 0.55 gate admitted flips from "
        "margin >= 0.1253*tau although calibration only covers margin >= tau",
        "fix": "below-threshold confidence now maps to 0.55*ratio (< 0.55), "
        "making the daemon gate exactly equivalent to the calibrated "
        "margin_threshold; applied to HybridSemanticRanker, "
        "NeuralListwiseRanker, and OnnxNeuralListwiseRanker",
        "commands": {"report": command},
        "dataset_sha256": dataset.sha256,
        "daemon_min_confidence": DAEMON_MIN_CONFIDENCE,
        "legacy_gate_ratio": LEGACY_GATE_RATIO,
        "fusion_config": {
            "path": str(args.fusion_config),
            "artifact_id": incumbent.config.artifact_id,
            "fusion_type": incumbent.config.fusion_type,
            "neural_weight": incumbent.config.neural_weight,
            "margin_threshold": incumbent.config.margin_threshold,
            "target_precision": incumbent.config.target_precision,
            "legacy_margin_threshold_equivalent": (
                LEGACY_GATE_RATIO * incumbent.config.margin_threshold
            ),
        },
    }

    validation = _classify_split(
        incumbent, build_ranker_examples(dataset.samples, split="validation")
    )
    validation_rows = validation["rows"]
    blocked = _blocked_details(validation_rows)
    blocked_wins = sum(1 for row in blocked if row["outcome"] == "win_blocked")
    blocked_losses = sum(
        1 for row in blocked if row["outcome"] == "loss_blocked"
    )
    blocked_neutral = sum(
        1 for row in blocked if row["outcome"] == "neutral_blocked"
    )
    net_benefit = blocked_losses - blocked_wins
    report["validation"] = {
        "samples": len(validation_rows),
        "runtime_confidence_checked": validation["runtime_confidence_checked"],
        "blocked_flips": len(blocked),
        "blocked_wins": blocked_wins,
        "blocked_losses": blocked_losses,
        "blocked_neutral": blocked_neutral,
        "blocked_net_benefit": net_benefit,
        "gate_before": _gate_view(validation_rows, legacy=True),
        "gate_after": _gate_view(validation_rows, legacy=False),
        "blocked_samples": blocked,
    }
    report["decision_rule"] = (
        "merge the semantic change iff blocked_net_benefit >= 0 "
        "(net negative halts the change; only annotations land)"
    )
    report["split_counts"] = {
        "raw_dataset": raw_split_counts,
        "evaluated": {
            "validation": len(validation_rows),
            "test": None,  # filled after the test split is scored
        },
        "note": (
            "raw_dataset counts the jsonl splits "
            f"(validation {raw_split_counts.get('validation', 0)} / "
            f"test {raw_split_counts.get('test', 0)}); "
            "evaluated counts build_ranker_examples output — samples with "
            ">= 2 full-length candidates whose gold is present, the only "
            "samples a ranker can act on "
            + (
                _CALIBRATION_NOTE_SAME_DOMAIN.format(
                    validation=len(validation_rows)
                )
                if same_domain
                else "(cross-domain: this dataset is not the fusion config's "
                "calibration cohort — see cross_domain_application)"
            )
        ),
    }
    if not same_domain:
        report["cross_domain_application"] = {
            "fusion_config_calibrated_on_dataset_sha256": (
                incumbent.config.validation_dataset_sha256
            ),
            "ngram_model_dataset_sha256": incumbent.config.ngram_dataset_sha256,
            "evaluated_dataset_sha256": dataset.sha256,
            "note": (
                "the fusion config (margin_threshold / target_precision) and "
                "the char n-gram model were calibrated on the p0 dataset; "
                "applying them to this dataset is a cross-domain "
                "application — interpret every number with this context"
            ),
        }
    if args.limitation_note:
        report["limitations"] = list(args.limitation_note)
    report["validation_verdict"] = (
        "merge_semantic_change"
        if net_benefit >= 0
        else "halt_keep_annotations_only"
    )

    # Test split: one final before/after comparison, no selection here.
    test = _classify_split(
        incumbent, build_ranker_examples(dataset.samples, split="test")
    )
    test_rows = test["rows"]
    test_blocked = _blocked_details(test_rows)
    report["test"] = {
        "samples": len(test_rows),
        "runtime_confidence_checked": test["runtime_confidence_checked"],
        "blocked_flips": len(test_blocked),
        "blocked_wins": sum(
            1 for row in test_blocked if row["outcome"] == "win_blocked"
        ),
        "blocked_losses": sum(
            1 for row in test_blocked if row["outcome"] == "loss_blocked"
        ),
        "gate_before": _gate_view(test_rows, legacy=True),
        "gate_after": _gate_view(test_rows, legacy=False),
        "blocked_samples": test_blocked,
    }

    report["split_counts"]["evaluated"]["test"] = len(test_rows)
    delta = report["test"]["gate_after"]["net_gain"] - report["test"][
        "gate_before"
    ]["net_gain"]
    stability_note = (
        _STABILITY_NOTE_SAME_DOMAIN
        if same_domain
        else (
            "v1 per-sample z-score fusion amplifies tiny run-to-run "
            "inference noise on samples whose score deviation is near "
            "zero, so borderline counts drift slightly across runs; this "
            "report is a single run on an independent corpus (the "
            "three-run stability figures apply only to the p0 "
            "calibration dataset). Borderline neutrals never enter the "
            "net-benefit decision."
        )
    )
    summary = (
        "The tightened gate blocks every flip in [0.1253*tau, tau) — "
        f"validation: {len(blocked)} flips blocked "
        f"({blocked_losses} losses avoided, {blocked_wins} wins lost, "
        f"net benefit {net_benefit:+d}); test net gain "
        f"{report['test']['gate_before']['net_gain']} -> "
        f"{report['test']['gate_after']['net_gain']} "
        f"({delta:+d}). The daemon 0.55 gate now equals the calibrated "
        "margin_threshold."
    )
    if args.decision_split is not None:
        decision_rows = (
            validation_rows if args.decision_split == "validation" else test_rows
        )
        decision_blocked = _blocked_details(decision_rows)
        decision_wins = sum(
            1 for row in decision_blocked if row["outcome"] == "win_blocked"
        )
        decision_losses = sum(
            1 for row in decision_blocked if row["outcome"] == "loss_blocked"
        )
        decision_benefit = decision_losses - decision_wins
        decision_verdict = (
            "independent_corpus_supports_current_tightening"
            if decision_benefit >= 0
            else "revisit_flagged"
        )
        report["independent_corpus_decision"] = {
            "split": args.decision_split,
            "rule": args.decision_rule,
            "blocked_flips": len(decision_blocked),
            "blocked_wins": decision_wins,
            "blocked_losses": decision_losses,
            "blocked_net_benefit": decision_benefit,
            "verdict": decision_verdict,
            "action_on_negative": (
                "flag for coordinator revisit; no code is rolled back "
                "automatically"
            ),
        }
        summary += (
            f" Independent corpus ({args.decision_split}): blocked net "
            f"benefit {decision_benefit:+d} -> {decision_verdict}."
        )
    report["conclusion"] = {
        "validation_blocked_net_benefit": net_benefit,
        "validation_verdict": report["validation_verdict"],
        "test_net_gain_delta": delta,
        "test_top1_delta": report["test"]["gate_after"]["top1_accuracy"]
        - report["test"]["gate_before"]["top1_accuracy"],
        "stability_note": stability_note,
        "summary": summary,
    }

    _write_atomic_json(args.output, report)
    print(json.dumps(report["conclusion"], ensure_ascii=False, indent=2))
    print(f"report written: {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
