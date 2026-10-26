"""Build the n-gram beam hyperparameter scan report (v3 vs v4 candidate).

Reads the training report captured from the sanctioned CLI command
(`rimeai_eval train-beam-decoder` stdout) plus the frozen v3 artifact and
the freshly trained v4 candidate, benchmarks both configs on the
validation split, and then — exactly once, as the final comparison — on
the test split. Test labels never influence any selection; the
recommendulation only uses test as a regression check.

Usage (repo root, CPU only):
  PYTHONDONTWRITEBYTECODE=1 .venv/bin/python tools/beam_hparam_scan_v4.py \
      --dataset .rimeai/datasets/p0-librime-1.17.0-luna-simp.jsonl \
      --language-model .rimeai/models/p0-char-ngram-v2.json.gz \
      --rime-dictionary .rimeai/rime/shared/luna_pinyin.dict.yaml \
      --v3-config .rimeai/models/p0-beam-sentence-v3.json \
      --v4-config .rimeai/models/p0-beam-sentence-v4-candidate.json \
      --training-report /tmp/v4_training_report.json \
      --output .rimeai/reports/ngram-beam-hparam-v4.json
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
from pathlib import Path

from rimeai_eval.dataset import load_dataset
from rimeai_eval.sentence_benchmark import benchmark_sentence_decoder
from rimeai_runtime.beam_decoder import BeamSentenceDecoder, load_beam_config
from rimeai_runtime.ngram_ranker import load_ngram_model
from rimeai_runtime.pinyin_guard import PinyinGuard

MIN_CONFIDENCE_GATES = (0.0, 0.60)
RECOMMEND_MIN_VALIDATION_GAIN = 0.002
RECOMMEND_MAX_TEST_REGRESSION = 0.0

TRAIN_COMMAND = (
    "PYTHONDONTWRITEBYTECODE=1 .venv/bin/python -m rimeai_eval "
    "train-beam-decoder .rimeai/datasets/p0-librime-1.17.0-luna-simp.jsonl "
    "--language-model .rimeai/models/p0-char-ngram-v2.json.gz "
    "--rime-dictionary .rimeai/rime/shared/luna_pinyin.dict.yaml "
    "--output .rimeai/models/p0-beam-sentence-v4-candidate.json "
    "--beam-width 16,8,12,24,32 "
    "--characters-per-syllable 20,10,30,40 "
    "--character-frequency-weight 0.5,0.0,0.25,1.0,2.0"
)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        while chunk := file.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


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
            benchmark_sentence_decoder(
                samples,
                decoder,
                min_confidence=gate,
            )
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
    parser.add_argument("--dataset", required=True, type=Path)
    parser.add_argument("--language-model", required=True, type=Path)
    parser.add_argument("--rime-dictionary", required=True, type=Path)
    parser.add_argument("--v3-config", required=True, type=Path)
    parser.add_argument("--v4-config", required=True, type=Path)
    parser.add_argument("--training-report", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    for label, path in (
        ("--v3-config", args.v3_config),
        ("--v4-config", args.v4_config),
    ):
        if path.resolve() == args.output.resolve():
            print(f"error: --output must not overwrite {label}", file=sys.stderr)
            return 2

    try:
        training = json.loads(
            args.training_report.read_text(encoding="utf-8")
        )
    except (OSError, json.JSONDecodeError) as error:
        print(
            f"error: cannot read training report "
            f"'{args.training_report}': {error}",
            file=sys.stderr,
        )
        return 2
    try:
        dataset = load_dataset(args.dataset)
        language_model = load_ngram_model(args.language_model)
        guard = PinyinGuard.from_rime_dictionary(args.rime_dictionary)
        v3_config = load_beam_config(args.v3_config)
        v4_config = load_beam_config(args.v4_config)
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2

    splits = {
        split: [sample for sample in dataset.samples if sample["split"] == split]
        for split in ("validation", "test")
    }
    decoders = {
        "v3": BeamSentenceDecoder(language_model, guard, v3_config),
        "v4_candidate": BeamSentenceDecoder(language_model, guard, v4_config),
    }
    # Selection happened on validation only (see training scan). The test
    # split below is the single, final comparison — nothing downstream of
    # it feeds back into any hyperparameter choice.
    comparison = {
        split: {
            label: _benchmark_config(samples, decoder)
            for label, decoder in decoders.items()
        }
        for split, samples in splits.items()
    }
    deltas = {
        split: {
            f"min_confidence_{gate:.2f}": round(
                comparison[split]["v4_candidate"][
                    f"min_confidence_{gate:.2f}"
                ]["decoder_sentence_accuracy"]
                - comparison[split]["v3"][f"min_confidence_{gate:.2f}"][
                    "decoder_sentence_accuracy"
                ],
                6,
            )
            for gate in MIN_CONFIDENCE_GATES
        }
        for split in splits
    }
    validation_gain = deltas["validation"]["min_confidence_0.00"]
    test_deltas = [deltas["test"][f"min_confidence_{gate:.2f}"]
                   for gate in MIN_CONFIDENCE_GATES]
    replace = (
        validation_gain >= RECOMMEND_MIN_VALIDATION_GAIN
        and all(delta >= RECOMMEND_MAX_TEST_REGRESSION for delta in test_deltas)
    )
    if replace:
        recommendation = "replace-v3-with-v4-candidate"
        rationale = (
            f"validation gated accuracy +{validation_gain:.6f} vs v3 with "
            "test non-regression at both min-confidence gates"
        )
    else:
        recommendation = "keep-v3"
        reasons = []
        if validation_gain < RECOMMEND_MIN_VALIDATION_GAIN:
            reasons.append(
                f"validation gain {validation_gain:+.6f} is below the "
                f"pre-declared {RECOMMEND_MIN_VALIDATION_GAIN:+.6f} bar"
            )
        regressed = [
            f"min_confidence_{gate:.2f} delta "
            f"{deltas['test'][f'min_confidence_{gate:.2f}']:+.6f}"
            for gate in MIN_CONFIDENCE_GATES
            if deltas["test"][f"min_confidence_{gate:.2f}"]
            < RECOMMEND_MAX_TEST_REGRESSION
        ]
        if regressed:
            reasons.append("test regression at " + "; ".join(regressed))
        rationale = "; ".join(reasons) + " - keep the incumbent v3 artifact"

    report = {
        "schema_version": 1,
        "kind": "ngram-beam-hparam-scan",
        "reproducibility": {
            "train_command": TRAIN_COMMAND,
            "benchmark_entrypoint": (
                "rimeai_eval.sentence_benchmark.benchmark_sentence_decoder "
                "(same code path as `rimeai_eval sentence-benchmark`)"
            ),
            "discipline": (
                "hyperparameters selected on validation only; test split "
                "decoded exactly once for this final comparison"
            ),
        },
        "inputs": {
            "dataset": {"path": str(args.dataset), "sha256": dataset.sha256},
            "language_model": {
                "path": str(args.language_model),
                "sha256": _sha256(args.language_model),
            },
            "dictionary": {
                "path": str(args.rime_dictionary),
                "sha256": _sha256(args.rime_dictionary),
            },
        },
        "configs": {
            "v3": v3_config.to_dict(),
            "v4_candidate": v4_config.to_dict(),
            "v4_candidate_path": str(args.v4_config),
            "v4_candidate_sha256": _sha256(args.v4_config),
        },
        "training": {
            "selected_hyperparameters": training[
                "selected_hyperparameters"
            ],
            "validation_metrics": training["validation"],
            "scan": training["hyperparameter_scan"],
        },
        "comparison": comparison,
        "accuracy_delta_v4_minus_v3": deltas,
        "latency_note": (
            "latency p50/p95 are informational only (single-process CPU "
            "run) and carry no gating decision"
        ),
        "recommendation": recommendation,
        "recommendation_rationale": rationale,
        "recommendation_rule": {
            "min_validation_gain": RECOMMEND_MIN_VALIDATION_GAIN,
            "max_test_regression": RECOMMEND_MAX_TEST_REGRESSION,
        },
    }
    _write_atomic_json(args.output, report)
    print(
        json.dumps(
            {
                "output": str(args.output),
                "recommendation": recommendation,
                "validation_gain": validation_gain,
                "test_deltas": deltas["test"],
            },
            ensure_ascii=False,
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
