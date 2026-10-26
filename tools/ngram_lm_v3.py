"""Train the v3 char n-gram LM candidate (smoothing + corpus expansion).

Three questions, all answered on the p0 primary dataset's validation
split only, with the test splits decoded exactly once at the end:

1. Smoothing: does a unigram-backoff terminal for unseen bigrams beat
   the legacy add-k constant (weights fixed at the frozen v2 values)?
2. Corpus expansion: does adding the zhwiki train split to the counts
   help on top of (or instead of) the smoothing change?
3. Recommendation: does the best candidate beat the incumbent v2 LM on
   validation without regressing on the p0 and zhwiki test splits?

Usage (repo root, CPU only):
  PYTHONDONTWRITEBYTECODE=1 .venv/bin/python tools/ngram_lm_v3.py \
      --dataset .rimeai/datasets/p0-librime-1.17.0-luna-simp.jsonl \
      --extra-dataset .rimeai/datasets/p0-zhwiki-librime-1.17.0-luna-simp.jsonl \
      --rime-dictionary .rimeai/rime/shared/luna_pinyin.dict.yaml \
      --incumbent-model .rimeai/models/p0-char-ngram-v2.json.gz \
      --incumbent-beam-config .rimeai/models/p0-beam-sentence-v3.json \
      --output-model .rimeai/models/p0-char-ngram-v3-candidate.json.gz \
      --output-beam-config .rimeai/models/p0-beam-sentence-v5-candidate.json \
      --output-report .rimeai/reports/ngram-lm-v3.json
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
from pathlib import Path
from typing import Any

from rimeai_eval.dataset import load_dataset
from rimeai_eval.evaluation import evaluate_dataset
from rimeai_eval.sentence_benchmark import benchmark_sentence_decoder
from rimeai_runtime.beam_decoder import (
    BeamSentenceDecoder,
    load_beam_config,
    train_beam_decoder_config,
    write_beam_config_atomic,
)
from rimeai_runtime.ngram_ranker import (
    NGramRankerModel,
    check_extra_train_leakage,
    load_ngram_model,
    train_ngram_model,
    write_ngram_model_atomic,
)
from rimeai_runtime.pinyin_guard import PinyinGuard
from rimeai_runtime.ranking import Ranking

MIN_CONFIDENCE_GATES = (0.0, 0.60)
# Pre-declared recommendation bar: the candidate must improve validation
# conditional top-1 by at least this much AND not regress any test gate.
RECOMMEND_MIN_VALIDATION_TOP1_GAIN = 0.002
RECOMMEND_MAX_TEST_REGRESSION = 0.0

# Frozen v2 selection (artifact hyperparameters) — weights stay fixed so
# the scan isolates the smoothing and corpus effects.
V2_RANK_WEIGHT = 0.25
V2_FREQUENCY_WEIGHT = 2.0
V2_LANGUAGE_WEIGHT = 1.0
ALPHA_GRID = (0.2, 0.4, 0.6, 0.8)
UNIGRAM_ADD_K_GRID = (0.01, 0.1, 1.0)

# Beam scan grid, anchored on the incumbent v3 production values so ties
# keep the incumbent unless a challenger is strictly better.
BEAM_WIDTH_GRID = (16, 8, 12, 24, 32)
CHARACTERS_PER_SYLLABLE_GRID = (20, 10, 30, 40)
CHARACTER_FREQUENCY_WEIGHT_GRID = (0.5, 0.0, 0.25, 1.0, 2.0)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        while chunk := file.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


class _NGramRankerAdapter:
    """In-process Ranker view of NGramRankerModel for evaluate_dataset."""

    name = "char-ngram-ranker"

    def __init__(self, model: NGramRankerModel) -> None:
        self._model = model

    def rank(self, sample: dict) -> Ranking:
        ranking, confidence = self._model.rank(
            context=sample["context"],
            candidates=sample["candidates"],
        )
        return Ranking(tuple(ranking), confidence)


def _ranker_metrics(model: NGramRankerModel, samples: list[dict]) -> dict:
    report = evaluate_dataset(
        samples,
        _NGramRankerAdapter(model),
        split="eval",
        min_confidence=0.0,
    )
    metrics = report["metrics"]
    return {
        "covered_samples": report["dataset"]["covered_samples"],
        "top_k_coverage": report["dataset"]["top_k_coverage"],
        "conditional_top1_accuracy": metrics["conditional_top1_accuracy"],
        "conditional_mrr": metrics["conditional_mrr"],
        "top1_accuracy": metrics["top1_accuracy"],
        "mrr": metrics["mrr"],
    }


def _beam_full(
    model: NGramRankerModel,
    guard: PinyinGuard,
    config: Any,
    samples: list[dict],
) -> dict:
    decoder = BeamSentenceDecoder(model, guard, config)
    return {
        f"min_confidence_{gate:.2f}": _beam_gate_metrics(
            decoder, samples, gate
        )
        for gate in MIN_CONFIDENCE_GATES
    }


def _beam_gate_metrics(decoder: Any, samples: list[dict], gate: float) -> dict:
    report = benchmark_sentence_decoder(samples, decoder, min_confidence=gate)
    metrics = report["metrics"]
    return {
        "baseline_sentence_accuracy": metrics["baseline_sentence_accuracy"],
        "decoder_sentence_accuracy": metrics["decoder_sentence_accuracy"],
        "decoder_char_accuracy": metrics["decoder_char_accuracy"],
        "decision_counts": report["decision_counts"],
        "latency_ms_p50": metrics["decoder_latency_ms"]["p50"],
        "latency_ms_p95": metrics["decoder_latency_ms"]["p95"],
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
    parser.add_argument("--dataset", required=True, type=Path)
    parser.add_argument("--extra-dataset", required=True, type=Path)
    parser.add_argument("--rime-dictionary", required=True, type=Path)
    parser.add_argument("--incumbent-model", required=True, type=Path)
    parser.add_argument("--incumbent-beam-config", required=True, type=Path)
    parser.add_argument("--output-model", required=True, type=Path)
    parser.add_argument("--output-beam-config", required=True, type=Path)
    parser.add_argument("--output-report", required=True, type=Path)
    args = parser.parse_args()

    protected = {
        args.dataset.resolve(),
        args.extra_dataset.resolve(),
        args.rime_dictionary.resolve(),
        args.incumbent_model.resolve(),
        args.incumbent_beam_config.resolve(),
    }
    for label, path in (
        ("--output-model", args.output_model),
        ("--output-beam-config", args.output_beam_config),
        ("--output-report", args.output_report),
    ):
        if path.resolve() in protected:
            print(f"error: {label} must not overwrite an input", file=sys.stderr)
            return 2

    try:
        dataset = load_dataset(args.dataset)
        extra = load_dataset(args.extra_dataset)
        guard = PinyinGuard.from_rime_dictionary(args.rime_dictionary)
        incumbent_model = load_ngram_model(args.incumbent_model)
        incumbent_config = load_beam_config(args.incumbent_beam_config)
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2

    extra_all = extra.samples
    extra_train = [
        sample for sample in extra_all if sample["split"] == "train"
    ]
    splits = {
        "validation": [
            sample for sample in dataset.samples
            if sample["split"] == "validation"
        ],
        "test": [
            sample for sample in dataset.samples
            if sample["split"] == "test"
        ],
    }
    extra_heldout = {
        split: [
            sample for sample in extra_all if sample["split"] == split
        ]
        for split in ("validation", "test")
    }

    # Leakage checks: the extra corpus's train split vs the primary AND
    # the extra dataset's own validation/test splits (per-sample id and
    # whitespace-normalized context+gold text). train_ngram_model re-runs
    # the primary-side checks defensively before counting anything.
    leakage_checks = [
        check_extra_train_leakage(
            extra_train, heldout, f"primary:{name}"
        )
        for name, heldout in splits.items()
    ] + [
        check_extra_train_leakage(
            extra_train, heldout, f"extra:{name}"
        )
        for name, heldout in extra_heldout.items()
    ]
    for check in leakage_checks:
        if check["id_overlap_samples"] or check["text_overlap_samples"]:
            print(
                f"error: extra corpus leaks {check['heldout_split']} "
                f"samples: {check}",
                file=sys.stderr,
            )
            return 2

    fixed_weights: dict[str, Any] = {
        "rank_weight_grid": (V2_RANK_WEIGHT,),
        "frequency_weight_grid": (V2_FREQUENCY_WEIGHT,),
        "language_weight_grid": (V2_LANGUAGE_WEIGHT,),
        "backoff_alpha_grid": ALPHA_GRID,
    }

    arms: dict[str, tuple[NGramRankerModel, dict]] = {}
    # Arm A: p0-only corpus. Legacy vs unigram terminal, weights fixed.
    arms["A_smoothing_legacy"] = train_ngram_model(
        dataset.samples,
        dataset_sha256=dataset.sha256,
        terminal_method_grid=("legacy",),
        **fixed_weights,
    )
    arms["A_smoothing_unigram"] = train_ngram_model(
        dataset.samples,
        dataset_sha256=dataset.sha256,
        terminal_method_grid=("unigram",),
        unigram_add_k_grid=UNIGRAM_ADD_K_GRID,
        **fixed_weights,
    )
    # Arm B: p0 + zhwiki train corpus. Legacy vs unigram terminal.
    arms["B_extra_legacy"] = train_ngram_model(
        dataset.samples,
        dataset_sha256=dataset.sha256,
        extra_train_samples=extra_train,
        terminal_method_grid=("legacy",),
        **fixed_weights,
    )
    arms["B_extra_unigram"] = train_ngram_model(
        dataset.samples,
        dataset_sha256=dataset.sha256,
        extra_train_samples=extra_train,
        terminal_method_grid=("unigram",),
        unigram_add_k_grid=UNIGRAM_ADD_K_GRID,
        **fixed_weights,
    )

    validation = splits["validation"]
    incumbent_validation = _ranker_metrics(incumbent_model, validation)
    arm_rows = {}
    for name, (model, train_report) in arms.items():
        arm_rows[name] = {
            "train_report": train_report,
            "validation_ranker": _ranker_metrics(model, validation),
        }
    # Candidate selection: highest validation conditional top-1, ties by
    # MRR, ties prefer the incumbent-preserving legacy terminal.
    def selection_key(name: str):
        metrics = arm_rows[name]["validation_ranker"]
        terminal = arm_rows[name]["train_report"][
            "selected_hyperparameters"
        ]["terminal_method"]
        return (
            metrics["conditional_top1_accuracy"],
            metrics["conditional_mrr"],
            -float(terminal == "unigram"),
            -float("extra" in name),
            name,
        )

    ranked_arms = sorted(arm_rows, key=selection_key, reverse=True)
    best_arm = ranked_arms[0]
    candidate_model, candidate_train_report = arms[best_arm]
    candidate_validation = arm_rows[best_arm]["validation_ranker"]
    incumbent_gain = (
        candidate_validation["conditional_top1_accuracy"]
        - incumbent_validation["conditional_top1_accuracy"]
    )

    # Persist the candidate artifacts (new files only; nothing incumbent
    # is overwritten).
    model_sha256 = write_ngram_model_atomic(
        args.output_model, candidate_model
    )
    dictionary_sha256 = _sha256(args.rime_dictionary)
    beam_config, beam_train_report = train_beam_decoder_config(
        dataset.samples,
        candidate_model,
        guard,
        dataset_sha256=dataset.sha256,
        language_model_sha256=model_sha256,
        dictionary_sha256=dictionary_sha256,
        beam_width=BEAM_WIDTH_GRID,
        characters_per_syllable=CHARACTERS_PER_SYLLABLE_GRID,
        character_frequency_weight=CHARACTER_FREQUENCY_WEIGHT_GRID,
    )
    write_beam_config_atomic(args.output_beam_config, beam_config)

    # Final comparison: each test split decoded exactly once, no further
    # selection downstream. Validation rows are the selection evidence.
    comparison = {}
    for split, samples in {
        "validation": validation,
        "p0_test": splits["test"],
        "zhwiki_test": extra_heldout["test"],
    }.items():
        comparison[split] = {
            "incumbent_v2": {
                "ranker": _ranker_metrics(incumbent_model, samples),
                "beam": _beam_full(
                    incumbent_model, guard, incumbent_config, samples
                ),
            },
            "v3_candidate": {
                "ranker": _ranker_metrics(candidate_model, samples),
                "beam": _beam_full(
                    candidate_model, guard, beam_config, samples
                ),
            },
        }

    validation_gain = (
        comparison["validation"]["v3_candidate"]["ranker"][
            "conditional_top1_accuracy"
        ]
        - comparison["validation"]["incumbent_v2"]["ranker"][
            "conditional_top1_accuracy"
        ]
    )
    test_regressions = {}
    for split in ("p0_test", "zhwiki_test"):
        for metric_path in (
            ("ranker", "conditional_top1_accuracy"),
            ("beam", "min_confidence_0.00", "decoder_sentence_accuracy"),
            ("beam", "min_confidence_0.60", "decoder_sentence_accuracy"),
        ):
            incumbent_value = comparison[split]["incumbent_v2"]
            candidate_value = comparison[split]["v3_candidate"]
            for key in metric_path[:-1]:
                incumbent_value = incumbent_value[key]
                candidate_value = candidate_value[key]
            delta = candidate_value[metric_path[-1]] - incumbent_value[
                metric_path[-1]
            ]
            if delta < RECOMMEND_MAX_TEST_REGRESSION:
                test_regressions[f"{split}:{'/'.join(metric_path)}"] = round(
                    delta, 6
                )
    if (
        validation_gain >= RECOMMEND_MIN_VALIDATION_TOP1_GAIN
        and not test_regressions
    ):
        recommendation = "replace-v2-with-v3-candidate"
        rationale = (
            f"validation conditional top-1 +{validation_gain:.6f} over the "
            "incumbent v2 with no test regression on p0/zhwiki at either "
            "min-confidence gate"
        )
    else:
        recommendation = "keep-v2"
        reasons = []
        if validation_gain < RECOMMEND_MIN_VALIDATION_TOP1_GAIN:
            reasons.append(
                f"validation gain {validation_gain:+.6f} is below the "
                f"pre-declared {RECOMMEND_MIN_VALIDATION_TOP1_GAIN:+.6f} bar"
            )
        if test_regressions:
            reasons.append(
                "test regressions: "
                + "; ".join(
                    f"{key} {delta:+.6f}"
                    for key, delta in sorted(test_regressions.items())
                )
            )
        rationale = "; ".join(reasons) + " — keep the incumbent v2 artifact"

    report = {
        "schema_version": 1,
        "kind": "ngram-lm-v3",
        "reproducibility": {
            "train_commands": [
                "PYTHONDONTWRITEBYTECODE=1 .venv/bin/python "
                "tools/ngram_lm_v3.py "
                f"--dataset {args.dataset} "
                f"--extra-dataset {args.extra_dataset} "
                f"--rime-dictionary {args.rime_dictionary} "
                f"--incumbent-model {args.incumbent_model} "
                f"--incumbent-beam-config {args.incumbent_beam_config} "
                f"--output-model {args.output_model} "
                f"--output-beam-config {args.output_beam_config} "
                f"--output-report {args.output_report}",
            ],
            "cli_equivalent": (
                "rimeai_eval train-ngram <dataset> --output <model> "
                "--extra-train-dataset <extra> --terminal-method unigram"
            ),
            "discipline": (
                "all hyperparameters selected on the p0 primary dataset "
                "validation split only; p0 test and zhwiki test decoded "
                "exactly once for the final comparison and never used for "
                "selection"
            ),
        },
        "inputs": {
            "dataset": {"path": str(args.dataset), "sha256": dataset.sha256},
            "extra_dataset": {
                "path": str(args.extra_dataset),
                "sha256": extra.sha256,
                "split_alignment": {
                    split: len(samples)
                    for split, samples in extra_heldout.items()
                },
                "train_samples": len(extra_train),
            },
            "rime_dictionary": {
                "path": str(args.rime_dictionary),
                "sha256": dictionary_sha256,
            },
            "incumbent_model": {
                "path": str(args.incumbent_model),
                "sha256": _sha256(args.incumbent_model),
            },
            "incumbent_beam_config": {
                "path": str(args.incumbent_beam_config),
                "sha256": _sha256(args.incumbent_beam_config),
            },
        },
        "leakage_checks": leakage_checks,
        "scan": {
            "fixed_weights": {
                "rank_weight": V2_RANK_WEIGHT,
                "frequency_weight": V2_FREQUENCY_WEIGHT,
                "language_weight": V2_LANGUAGE_WEIGHT,
                "note": (
                    "frozen at the v2 artifact's selected values so the "
                    "scan isolates smoothing and corpus effects"
                ),
            },
            "backoff_alpha_grid": list(ALPHA_GRID),
            "unigram_add_k_grid": list(UNIGRAM_ADD_K_GRID),
            "unigram_discount_rule": "alpha ** 3 (follows the backoff chain)",
            "arms": arm_rows,
            "arm_selection_order": ranked_arms,
            "selected_arm": best_arm,
            "selected_arm_validation_gain_vs_v2": round(incumbent_gain, 6),
        },
        "artifacts": {
            "model": {
                "path": str(args.output_model),
                "sha256": model_sha256,
            },
            "beam_config": {
                "path": str(args.output_beam_config),
                "sha256": _sha256(args.output_beam_config),
                "training_report": beam_train_report,
            },
        },
        "comparison": comparison,
        "recommendation": recommendation,
        "recommendation_rationale": rationale,
        "recommendation_rule": {
            "min_validation_conditional_top1_gain": (
                RECOMMEND_MIN_VALIDATION_TOP1_GAIN
            ),
            "max_test_regression": RECOMMEND_MAX_TEST_REGRESSION,
            "checked_test_metrics": [
                "p0_test:ranker/conditional_top1_accuracy",
                "p0_test:beam/min_confidence_0.00/decoder_sentence_accuracy",
                "p0_test:beam/min_confidence_0.60/decoder_sentence_accuracy",
                "zhwiki_test:ranker/conditional_top1_accuracy",
                "zhwiki_test:beam/min_confidence_0.00/decoder_sentence_accuracy",
                "zhwiki_test:beam/min_confidence_0.60/decoder_sentence_accuracy",
            ],
        },
    }
    _write_atomic_json(args.output_report, report)
    print(
        json.dumps(
            {
                "output_report": str(args.output_report),
                "selected_arm": best_arm,
                "validation_gain": round(validation_gain, 6),
                "recommendation": recommendation,
            },
            ensure_ascii=False,
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
