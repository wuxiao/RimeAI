import argparse
from collections import Counter
import hashlib
import json
from math import isfinite
from pathlib import Path
import sys
from typing import Mapping, Optional, Sequence

from .capture import CaptureError, capture_dataset
from .cloud_evaluation import (
    CloudEvaluationError,
    evaluate_cloud_observations,
    load_cloud_observations,
)
from rimeai_runtime.beam_decoder import (
    BeamDecoderError,
    BeamSentenceDecoder,
    load_beam_config,
    train_beam_decoder_config,
    write_beam_config_atomic,
)
from .command_ranker import CommandRanker, RankerConfigurationError
from .command_sentence_decoder import (
    CommandSentenceDecoder,
    SentenceDecoderConfigurationError,
)
from .dataset import DatasetValidationError, load_dataset
from .evaluation import (
    BaselineRanker,
    ContextRepeatRanker,
    evaluate_dataset,
)
from .keyboard_evaluation import (
    KeyboardEvaluationError,
    evaluate_keyboard_observations,
    load_keyboard_observations,
)
from .language_profile_eval import main as _language_profile_main
from rimeai_runtime.ngram_ranker import (
    NGramModelError,
    load_ngram_model,
    train_ngram_model,
    write_ngram_model_atomic,
)
from rimeai_runtime.neural_ranker import (
    HybridSemanticRanker,
    NeuralRankerError,
    load_neural_ranker,
    train_fusion_config,
    train_neural_ranker,
)
from rimeai_runtime.pinyin_guard import PinyinGuard
from rimeai_daemon.user_lm import UserLanguageModel
from .reporting import (
    ReportError,
    load_reports,
    render_markdown_comparison,
    write_jsonl_atomic,
)
from .sentence_benchmark import run_sentence_benchmark
from .sentence_evaluation import evaluate_sentence_dataset
from .voice_dataset import VoiceDatasetError, load_voice_corpus
from .voice_evaluation import (
    VoiceEvaluationError,
    evaluate_voice,
    load_voice_gates,
    load_voice_observations,
    load_voice_run,
)
from .voice_performance import VoicePerformanceError, load_voice_performance
from .voice_performance_collection import (
    VoicePerformanceCollectionError,
    collect_voice_performance,
    load_voice_collection_plan,
    write_voice_performance_atomic,
)
from .voice_observation_collection import (
    VoiceObservationCollectionError,
    collect_voice_observations,
)


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="rimeai-eval")
    subparsers = parser.add_subparsers(dest="command", required=True)

    validate_parser = subparsers.add_parser(
        "validate", help="validate a JSONL rerank dataset"
    )
    validate_parser.add_argument("dataset", type=Path)

    validate_voice_parser = subparsers.add_parser(
        "validate-voice",
        help="validate a privacy-safe voice evaluation corpus",
    )
    validate_voice_parser.add_argument("corpus_root", type=Path)
    validate_voice_parser.add_argument(
        "--profile",
        choices=("fixture", "frozen-quality"),
        required=True,
    )

    evaluate_parser = subparsers.add_parser(
        "evaluate", help="evaluate a ranker against a JSONL dataset"
    )
    evaluate_parser.add_argument("dataset", type=Path)
    evaluate_parser.add_argument(
        "--ranker",
        choices=("baseline", "context-repeat", "command", "neural", "hybrid"),
        default="baseline",
    )
    evaluate_parser.add_argument("--ranker-config", type=Path)
    evaluate_parser.add_argument("--rime-dictionary", type=Path)
    evaluate_parser.add_argument("--neural-model", type=Path)
    evaluate_parser.add_argument("--language-model", type=Path)
    evaluate_parser.add_argument(
        "--device", choices=("auto", "cpu", "mps"), default="auto"
    )
    evaluate_parser.add_argument("--details-output", type=Path)
    evaluate_parser.add_argument(
        "--split",
        choices=("train", "validation", "test", "all"),
        default="test",
    )
    evaluate_parser.add_argument("--min-confidence", type=float, default=0.0)
    evaluate_parser.add_argument(
        "--candidate-limit",
        type=int,
        choices=range(1, 21),
        default=20,
        metavar="K",
    )

    cloud_evaluate_parser = subparsers.add_parser(
        "evaluate-cloud",
        help="evaluate candidate expansion, correction, latency, and privacy gates",
    )
    cloud_evaluate_parser.add_argument("observations", type=Path)

    voice_evaluate_parser = subparsers.add_parser(
        "evaluate-voice",
        help="evaluate aggregate voice quality and optional quality gates",
    )
    voice_evaluate_parser.add_argument("corpus_root", type=Path)
    voice_evaluate_parser.add_argument("run", type=Path)
    voice_evaluate_parser.add_argument("observations", type=Path)
    voice_evaluate_parser.add_argument("--baseline-run", type=Path)
    voice_evaluate_parser.add_argument("--baseline-observations", type=Path)
    voice_evaluate_parser.add_argument("--gates-config", type=Path)
    voice_evaluate_parser.add_argument("--performance-evidence", type=Path)

    voice_collect_parser = subparsers.add_parser(
        "collect-voice-performance",
        help="collect native macOS voice performance evidence from live boundary events",
        description=(
            "Collect fail-closed macOS performance evidence from live NDJSON "
            "boundary events on stdin. The collector must be a canonical, "
            "Developer-ID-signed executable pinned by the collection plan."
        ),
        epilog=(
            "stdin must be a live pipe/socket/terminal, not a replay file; "
            "--output must be outside the corpus, artifact directory, plan, "
            "collector, and measured executables."
        ),
    )
    voice_collect_parser.add_argument(
        "corpus_root",
        type=Path,
        help="validated external voice corpus root",
    )
    voice_collect_parser.add_argument(
        "run",
        type=Path,
        help="schema-v2 voice run manifest",
    )
    voice_collect_parser.add_argument(
        "collection_plan",
        type=Path,
        help="strict process, collector, protocol, and artifact identity plan",
    )
    voice_collect_parser.add_argument(
        "--native-collector",
        required=True,
        type=Path,
        help="canonical signed rimeai-voice-performance-collector path",
    )
    voice_collect_parser.add_argument(
        "--output",
        required=True,
        type=Path,
        help="new or replaceable owner-only performance sidecar path",
    )

    voice_observation_collect_parser = subparsers.add_parser(
        "collect-voice-observations",
        help="collect validated observations through the native voice driver",
    )
    voice_observation_collect_parser.add_argument("corpus_root", type=Path)
    voice_observation_collect_parser.add_argument("run", type=Path)
    voice_observation_collect_parser.add_argument(
        "--native-driver", required=True, type=Path
    )
    voice_observation_collect_parser.add_argument(
        "--artifact-dir", required=True, type=Path
    )
    voice_observation_collect_parser.add_argument(
        "--output", required=True, type=Path
    )
    voice_observation_collect_parser.add_argument(
        "--hotwords-file", type=Path
    )

    compare_parser = subparsers.add_parser(
        "compare", help="compare compatible aggregate evaluation reports"
    )
    compare_parser.add_argument("reports", nargs="+", type=Path)
    compare_parser.add_argument(
        "--format", choices=("markdown",), default="markdown"
    )

    capture_parser = subparsers.add_parser(
        "capture", help="capture Rime candidates into a versioned JSONL dataset"
    )
    capture_parser.add_argument("source", type=Path)
    capture_parser.add_argument("--candidate-config", required=True, type=Path)
    capture_parser.add_argument("--output", required=True, type=Path)
    capture_parser.add_argument("--provenance-output", required=True, type=Path)

    train_ngram_parser = subparsers.add_parser(
        "train-ngram",
        help="train the deterministic character n-gram reranker",
    )
    train_ngram_parser.add_argument("dataset", type=Path)
    train_ngram_parser.add_argument("--output", required=True, type=Path)

    train_neural_parser = subparsers.add_parser(
        "train-neural-ranker",
        help="train the 24M pinyin-aware listwise Cross-Encoder",
    )
    train_neural_parser.add_argument("dataset", type=Path)
    train_neural_parser.add_argument("--base-model", required=True, type=Path)
    train_neural_parser.add_argument("--base-revision", required=True)
    train_neural_parser.add_argument(
        "--rime-dictionary", required=True, type=Path
    )
    train_neural_parser.add_argument("--output", required=True, type=Path)
    train_neural_parser.add_argument("--epochs", type=int, default=3)
    train_neural_parser.add_argument("--batch-size", type=int, default=4)
    train_neural_parser.add_argument("--learning-rate", type=float, default=2e-5)
    train_neural_parser.add_argument(
        "--ambiguous-repetitions", type=int, default=3
    )
    train_neural_parser.add_argument("--max-length", type=int, default=128)
    train_neural_parser.add_argument("--target-precision", type=float, default=0.9)
    train_neural_parser.add_argument(
        "--device", choices=("auto", "cpu", "mps"), default="auto"
    )
    train_neural_parser.add_argument("--seed", type=int, default=20260729)

    train_fusion_parser = subparsers.add_parser(
        "train-neural-fusion",
        help="calibrate validation-only neural and n-gram score fusion",
    )
    train_fusion_parser.add_argument("dataset", type=Path)
    train_fusion_parser.add_argument("--neural-model", required=True, type=Path)
    train_fusion_parser.add_argument("--language-model", required=True, type=Path)
    train_fusion_parser.add_argument(
        "--rime-dictionary", required=True, type=Path
    )
    train_fusion_parser.add_argument("--output", required=True, type=Path)
    train_fusion_parser.add_argument("--target-precision", type=float, default=0.9)
    train_fusion_parser.add_argument(
        "--device", choices=("auto", "cpu", "mps"), default="auto"
    )

    sentence_parser = subparsers.add_parser(
        "evaluate-sentence",
        help="evaluate a constrained local sentence decoder",
    )
    sentence_parser.add_argument("dataset", type=Path)
    sentence_parser.add_argument(
        "--decoder-config", required=True, type=Path
    )
    sentence_parser.add_argument(
        "--rime-dictionary", required=True, type=Path
    )
    sentence_parser.add_argument("--details-output", type=Path)
    sentence_parser.add_argument(
        "--split",
        choices=("train", "validation", "test", "all"),
        default="test",
    )
    sentence_parser.add_argument(
        "--candidate-limit",
        type=int,
        choices=range(1, 21),
        default=10,
        metavar="K",
    )
    sentence_parser.add_argument(
        "--min-confidence", type=float, default=0.0
    )

    keyboard_parser = subparsers.add_parser(
        "evaluate-keyboard",
        help="evaluate frozen real-keyboard interaction observations",
    )
    keyboard_parser.add_argument("observations", type=Path)

    train_beam_parser = subparsers.add_parser(
        "train-beam-decoder",
        help="calibrate a pinyin-constrained beam sentence decoder",
    )
    train_beam_parser.add_argument("datasets", nargs="+", type=Path)
    train_beam_parser.add_argument(
        "--language-model", required=True, type=Path
    )
    train_beam_parser.add_argument(
        "--rime-dictionary", required=True, type=Path
    )
    train_beam_parser.add_argument("--output", required=True, type=Path)

    sentence_benchmark_parser = subparsers.add_parser(
        "sentence-benchmark",
        help="benchmark the beam sentence decoder against the Rime baseline",
    )
    sentence_benchmark_parser.add_argument("dataset", type=Path)
    sentence_benchmark_parser.add_argument(
        "--language-model", required=True, type=Path
    )
    sentence_benchmark_parser.add_argument(
        "--decoder-config", required=True, type=Path
    )
    sentence_benchmark_parser.add_argument(
        "--rime-dictionary", required=True, type=Path
    )
    sentence_benchmark_parser.add_argument("--user-lm", type=Path)
    sentence_benchmark_parser.add_argument(
        "--command-decoder-config", type=Path
    )
    sentence_benchmark_parser.add_argument(
        "--split",
        choices=("train", "validation", "test", "all"),
        default="test",
    )
    sentence_benchmark_parser.add_argument(
        "--min-confidence", type=float, default=0.0
    )

    language_profile_parser = subparsers.add_parser(
        "language-profile",
        help="time-split evaluation of the language-profile learning layers",
    )
    language_profile_parser.add_argument(
        "--history-db", required=True, type=Path
    )
    language_profile_parser.add_argument(
        "--frozen-samples",
        required=True,
        type=Path,
        help="P0-format JSONL dataset with candidates and gold_text",
    )
    language_profile_parser.add_argument(
        "--baseline-model", required=True, type=Path
    )
    language_profile_parser.add_argument(
        "--train-ratio", type=float, default=0.8
    )
    language_profile_parser.add_argument("--report", type=Path, default=None)
    return parser


def _validate(dataset_path: Path) -> int:
    try:
        dataset = load_dataset(dataset_path)
    except DatasetValidationError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    samples = dataset.samples

    report = {
        "schema_version": 1,
        "samples": len(samples),
        "domains": dict(sorted(Counter(s["domain"] for s in samples).items())),
        "splits": dict(sorted(Counter(s["split"] for s in samples).items())),
    }
    print(json.dumps(report, ensure_ascii=False, sort_keys=True))
    return 0


def _validate_voice(corpus_root: Path, profile: str) -> int:
    expected_profile = profile.replace("-", "_")
    try:
        load_voice_corpus(corpus_root, expected_profile=expected_profile)
    except (VoiceDatasetError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    report = {
        "kind": "voice_corpus_validation",
        "profile": profile,
        "schema_version": 1,
        "valid": True,
    }
    print(json.dumps(report, ensure_ascii=False, sort_keys=True))
    return 0


def _evaluate_voice(
    corpus_root: Path,
    run_path: Path,
    observations_path: Path,
    baseline_run_path: Optional[Path],
    baseline_observations_path: Optional[Path],
    gates_config_path: Optional[Path],
    performance_evidence_path: Optional[Path],
) -> int:
    if (baseline_run_path is None) != (baseline_observations_path is None):
        print(
            "error: --baseline-run and --baseline-observations must be used together",
            file=sys.stderr,
        )
        return 2

    try:
        corpus = load_voice_corpus(corpus_root)
        run = load_voice_run(run_path, corpus)
        observations = load_voice_observations(
            observations_path,
            corpus,
            run,
        )
        performance_evidence = (
            load_voice_performance(performance_evidence_path, corpus, run)
            if performance_evidence_path is not None
            else None
        )
        baseline_run = None
        baseline_observations = None
        if (
            baseline_run_path is not None
            and baseline_observations_path is not None
        ):
            baseline_run = load_voice_run(baseline_run_path, corpus)
            baseline_observations = load_voice_observations(
                baseline_observations_path,
                corpus,
                baseline_run,
            )
        gates = (
            load_voice_gates(gates_config_path)
            if gates_config_path is not None
            else None
        )
        evaluation_options = {
            "baseline_run": baseline_run,
            "baseline_observations": baseline_observations,
            "gates": gates,
        }
        if performance_evidence is not None:
            evaluation_options["performance_evidence"] = performance_evidence
        report = evaluate_voice(corpus, run, observations, **evaluation_options)
    except (
        VoiceDatasetError,
        VoiceEvaluationError,
        VoicePerformanceError,
        OSError,
    ) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2

    # A measurement run must never be mistaken for a quality-gate decision,
    # even if a future evaluator accidentally leaves a stale field in its result.
    report = dict(report)
    report.pop("release_pass", None)
    if gates_config_path is None:
        report.pop("quality_gate_pass", None)
        report["decision"] = "measurement_only"
    print(json.dumps(report, ensure_ascii=False, sort_keys=True))
    if gates_config_path is None:
        return 0
    return 0 if report.get("quality_gate_pass") is True else 1


def _collect_voice_performance(
    corpus_root: Path,
    run_path: Path,
    collection_plan_path: Path,
    native_collector_path: Path,
    output_path: Path,
) -> int:
    try:
        output_resolved = output_path.resolve()
        protected_inputs = (
            run_path.resolve(),
            collection_plan_path.resolve(),
            native_collector_path.resolve(),
        )
        corpus_resolved = corpus_root.resolve()
        output_is_in_corpus = (
            output_resolved == corpus_resolved
            or corpus_resolved in output_resolved.parents
        )
        if output_resolved in protected_inputs or output_is_in_corpus:
            raise VoicePerformanceCollectionError(
                "--output must not overwrite a collection input"
            )
        corpus = load_voice_corpus(corpus_root)
        run = load_voice_run(run_path, corpus)
        plan = load_voice_collection_plan(collection_plan_path, run)
        if _voice_performance_output_conflicts_with_plan(output_resolved, plan):
            raise VoicePerformanceCollectionError(
                "--output must not overwrite a collection input"
            )
        performance = collect_voice_performance(
            corpus,
            run,
            plan,
            native_collector_path,
            sys.stdin.buffer,
        )
        output_sha256 = write_voice_performance_atomic(
            performance,
            output_resolved,
        )
    except RuntimeError:
        print("error: collection path cannot be resolved", file=sys.stderr)
        return 2
    except (
        VoiceDatasetError,
        VoiceEvaluationError,
        VoicePerformanceError,
        VoicePerformanceCollectionError,
        OSError,
    ) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    print(
        json.dumps(
            {
                "kind": "voice_performance_collection",
                "schema_version": 2,
                "sha256": output_sha256,
                "valid": True,
            },
            sort_keys=True,
        )
    )
    return 0


def _voice_performance_output_conflicts_with_plan(
    output_path: Path,
    plan,
) -> bool:
    if not isinstance(plan, Mapping):
        return False
    output = output_path.resolve()
    artifact_directory = plan.get("artifact_directory")
    if isinstance(artifact_directory, str):
        artifact = Path(artifact_directory).resolve()
        if output == artifact or artifact in output.parents:
            return True
    processes = plan.get("processes")
    if isinstance(processes, list):
        for process in processes:
            if not isinstance(process, Mapping):
                continue
            executable = process.get("expected_executable_path")
            if isinstance(executable, str) and output == Path(executable).resolve():
                return True
    return False


def _collect_voice_observations(
    corpus_root: Path,
    run_path: Path,
    native_driver_path: Path,
    artifact_dir: Path,
    output_path: Path,
    hotwords_file: Optional[Path],
) -> int:
    try:
        output_sha256 = collect_voice_observations(
            corpus_root,
            run_path,
            native_driver_path,
            artifact_dir,
            output_path,
            hotwords_file,
        )
    except (
        VoiceDatasetError,
        VoiceEvaluationError,
        VoiceObservationCollectionError,
        OSError,
    ):
        print("error: voice observation collection failed", file=sys.stderr)
        return 2
    print(
        json.dumps(
            {
                "kind": "voice_observation_collection",
                "schema_version": 1,
                "sha256": output_sha256,
                "valid": True,
            },
            sort_keys=True,
        )
    )
    return 0


def _evaluate(
    dataset_path: Path,
    ranker_name: str,
    ranker_config: Optional[Path],
    split: str,
    min_confidence: float,
    details_output: Optional[Path],
    candidate_limit: int,
    dictionary_path: Optional[Path],
    device: str,
    neural_model_path: Optional[Path],
    language_model_path: Optional[Path],
) -> int:
    if not isfinite(min_confidence) or not 0 <= min_confidence <= 1:
        print(
            "error: --min-confidence must be from 0 to 1",
            file=sys.stderr,
        )
        return 2

    try:
        dataset = load_dataset(dataset_path)
    except DatasetValidationError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    samples = dataset.samples

    selected_samples = (
        samples
        if split == "all"
        else [sample for sample in samples if sample["split"] == split]
    )
    selected_samples = [
        {
            **sample,
            "candidates": sample["candidates"][:candidate_limit],
        }
        for sample in selected_samples
    ]
    if not selected_samples:
        print(
            f"error: {dataset_path}: dataset contains no samples for split '{split}'",
            file=sys.stderr,
        )
        return 2

    if (
        details_output is not None
        and details_output.resolve() == dataset_path.resolve()
    ):
        print(
            "error: --details-output must not overwrite the dataset",
            file=sys.stderr,
        )
        return 2
    details = [] if details_output is not None else None

    if ranker_name in {"baseline", "context-repeat"}:
        if ranker_config is not None:
            print(
                "error: --ranker-config is only valid with --ranker command",
                file=sys.stderr,
            )
            return 2
        ranker = (
            BaselineRanker()
            if ranker_name == "baseline"
            else ContextRepeatRanker()
        )
        report = evaluate_dataset(
            selected_samples,
            ranker,
            split,
            min_confidence,
            details,
        )
    elif ranker_name == "command":
        if ranker_config is None:
            print(
                "error: --ranker-config is required with --ranker command",
                file=sys.stderr,
            )
            return 2
        try:
            with CommandRanker.from_config(ranker_config) as ranker:
                report = evaluate_dataset(
                    selected_samples,
                    ranker,
                    split,
                    min_confidence,
                    details,
                )
        except RankerConfigurationError as error:
            print(f"error: {error}", file=sys.stderr)
            return 2
    elif ranker_name == "neural":
        if ranker_config is None or dictionary_path is None:
            print(
                "error: --ranker-config and --rime-dictionary are required "
                "with --ranker neural",
                file=sys.stderr,
            )
            return 2
        try:
            ranker = load_neural_ranker(
                ranker_config,
                PinyinGuard.from_rime_dictionary(dictionary_path),
                device=device,
            )
            report = evaluate_dataset(
                selected_samples,
                ranker,
                split,
                min_confidence,
                details,
            )
        except (NeuralRankerError, OSError, ValueError) as error:
            print(f"error: {error}", file=sys.stderr)
            return 2
    else:
        if (
            ranker_config is None
            or dictionary_path is None
            or neural_model_path is None
            or language_model_path is None
        ):
            print(
                "error: --ranker-config, --neural-model, --language-model, "
                "and --rime-dictionary are required with --ranker hybrid",
                file=sys.stderr,
            )
            return 2
        try:
            guard = PinyinGuard.from_rime_dictionary(dictionary_path)
            neural = load_neural_ranker(
                neural_model_path,
                guard,
                device=device,
            )
            ranker = HybridSemanticRanker(
                neural,
                load_ngram_model(language_model_path),
                ranker_config,
            )
            report = evaluate_dataset(
                selected_samples,
                ranker,
                split,
                min_confidence,
                details,
            )
        except (
            NeuralRankerError,
            NGramModelError,
            OSError,
            ValueError,
        ) as error:
            print(f"error: {error}", file=sys.stderr)
            return 2

    report["dataset"]["sha256"] = dataset.sha256
    if candidate_limit != 20:
        report["dataset"]["candidate_limit"] = candidate_limit
    if details_output is not None:
        assert details is not None
        try:
            write_jsonl_atomic(details_output, details)
        except OSError as error:
            print(
                f"error: cannot write details output '{details_output}': {error}",
                file=sys.stderr,
            )
            return 2
    print(json.dumps(report, ensure_ascii=False, sort_keys=True))
    return 0


def _compare(report_paths: Sequence[Path]) -> int:
    try:
        reports = load_reports(report_paths)
        comparison = render_markdown_comparison(reports)
    except (ReportError, KeyError, TypeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    print(comparison, end="")
    return 0


def _capture(
    source_path: Path,
    candidate_config_path: Path,
    output_path: Path,
    provenance_output_path: Path,
) -> int:
    try:
        report = capture_dataset(
            source_path,
            candidate_config_path,
            output_path,
            provenance_output_path,
        )
    except (CaptureError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    print(json.dumps(report, ensure_ascii=False, sort_keys=True))
    return 0


def _train_ngram(dataset_path: Path, output_path: Path) -> int:
    if output_path.resolve() == dataset_path.resolve():
        print(
            "error: --output must not overwrite the dataset",
            file=sys.stderr,
        )
        return 2
    try:
        dataset = load_dataset(dataset_path)
        model, report = train_ngram_model(
            dataset.samples,
            dataset_sha256=dataset.sha256,
        )
        artifact_sha256 = write_ngram_model_atomic(output_path, model)
    except (DatasetValidationError, NGramModelError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    report["artifact"] = {
        "path": str(output_path),
        "bytes": output_path.stat().st_size,
        "sha256": artifact_sha256,
    }
    print(json.dumps(report, ensure_ascii=False, sort_keys=True))
    return 0


def _train_neural_ranker(
    dataset_path: Path,
    base_model_path: Path,
    base_revision: str,
    dictionary_path: Path,
    output_path: Path,
    epochs: int,
    batch_size: int,
    learning_rate: float,
    ambiguous_repetitions: int,
    max_length: int,
    target_precision: float,
    device: str,
    seed: int,
) -> int:
    protected = {
        dataset_path.resolve(),
        base_model_path.resolve(),
        dictionary_path.resolve(),
    }
    if output_path.resolve() in protected:
        print("error: --output must not overwrite an input", file=sys.stderr)
        return 2
    try:
        dataset = load_dataset(dataset_path)
        report = train_neural_ranker(
            dataset.samples,
            dataset_sha256=dataset.sha256,
            base_model_path=base_model_path,
            base_model_revision=base_revision,
            dictionary_path=dictionary_path,
            output_path=output_path,
            epochs=epochs,
            batch_size=batch_size,
            learning_rate=learning_rate,
            ambiguous_repetitions=ambiguous_repetitions,
            max_length=max_length,
            target_precision=target_precision,
            device=device,
            seed=seed,
        )
    except (
        DatasetValidationError,
        NeuralRankerError,
        OSError,
        ValueError,
    ) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    print(json.dumps(report, ensure_ascii=False, sort_keys=True))
    return 0


def _train_neural_fusion(
    dataset_path: Path,
    neural_model_path: Path,
    language_model_path: Path,
    dictionary_path: Path,
    output_path: Path,
    target_precision: float,
    device: str,
) -> int:
    try:
        dataset = load_dataset(dataset_path)
        guard = PinyinGuard.from_rime_dictionary(dictionary_path)
        neural = load_neural_ranker(
            neural_model_path,
            guard,
            device=device,
        )
        report = train_fusion_config(
            dataset.samples,
            dataset_sha256=dataset.sha256,
            neural_ranker=neural,
            ngram_ranker=load_ngram_model(language_model_path),
            output_path=output_path,
            target_precision=target_precision,
        )
    except (
        DatasetValidationError,
        NeuralRankerError,
        NGramModelError,
        OSError,
        ValueError,
    ) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    print(json.dumps(report, ensure_ascii=False, sort_keys=True))
    return 0


def _evaluate_sentence(
    dataset_path: Path,
    decoder_config_path: Path,
    dictionary_path: Path,
    split: str,
    candidate_limit: int,
    min_confidence: float,
    details_output: Optional[Path],
) -> int:
    if not isfinite(min_confidence) or not 0 <= min_confidence <= 1:
        print(
            "error: --min-confidence must be from 0 to 1",
            file=sys.stderr,
        )
        return 2
    if (
        details_output is not None
        and details_output.resolve() == dataset_path.resolve()
    ):
        print(
            "error: --details-output must not overwrite the dataset",
            file=sys.stderr,
        )
        return 2
    try:
        dataset = load_dataset(dataset_path)
        guard = PinyinGuard.from_rime_dictionary(dictionary_path)
    except (DatasetValidationError, OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    samples = (
        dataset.samples
        if split == "all"
        else [sample for sample in dataset.samples if sample["split"] == split]
    )
    samples = [
        {
            **sample,
            "candidates": sample["candidates"][:candidate_limit],
        }
        for sample in samples
    ]
    if not samples:
        print(
            f"error: {dataset_path}: dataset contains no samples for split '{split}'",
            file=sys.stderr,
        )
        return 2
    details = [] if details_output is not None else None
    try:
        with CommandSentenceDecoder.from_config(
            decoder_config_path
        ) as decoder:
            report = evaluate_sentence_dataset(
                samples,
                decoder,
                guard,
                split=split,
                min_confidence=min_confidence,
                details=details,
            )
    except SentenceDecoderConfigurationError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    report["dataset"]["sha256"] = dataset.sha256
    report["dataset"]["candidate_limit"] = candidate_limit
    if details_output is not None:
        assert details is not None
        try:
            write_jsonl_atomic(details_output, details)
        except OSError as error:
            print(
                f"error: cannot write details output '{details_output}': {error}",
                file=sys.stderr,
            )
            return 2
    print(json.dumps(report, ensure_ascii=False, sort_keys=True))
    return 0


def _sentence_benchmark(
    dataset_path: Path,
    language_model_path: Path,
    decoder_config_path: Path,
    dictionary_path: Path,
    user_lm_path: Optional[Path],
    command_decoder_config_path: Optional[Path],
    split: str,
    min_confidence: float,
) -> int:
    if not isfinite(min_confidence) or not 0 <= min_confidence <= 1:
        print(
            "error: --min-confidence must be from 0 to 1",
            file=sys.stderr,
        )
        return 2
    try:
        dataset = load_dataset(dataset_path)
        guard = PinyinGuard.from_rime_dictionary(dictionary_path)
        language_model = load_ngram_model(language_model_path)
        config = load_beam_config(decoder_config_path)
        user_lm = (
            UserLanguageModel.load(user_lm_path)
            if user_lm_path is not None
            else None
        )
    except (
        DatasetValidationError,
        NGramModelError,
        BeamDecoderError,
        OSError,
        ValueError,
    ) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    samples = (
        dataset.samples
        if split == "all"
        else [sample for sample in dataset.samples if sample["split"] == split]
    )
    if not samples:
        print(
            f"error: {dataset_path}: dataset contains no samples for split '{split}'",
            file=sys.stderr,
        )
        return 2
    decoder = BeamSentenceDecoder(language_model, guard, config)
    if command_decoder_config_path is None:
        report = run_sentence_benchmark(
            samples,
            decoder,
            min_confidence=min_confidence,
            user_lm=user_lm,
        )
    else:
        try:
            command_decoder = CommandSentenceDecoder.from_config(
                command_decoder_config_path
            )
        except SentenceDecoderConfigurationError as error:
            print(f"error: {error}", file=sys.stderr)
            return 2
        with command_decoder as neural_decoder:
            report = run_sentence_benchmark(
                samples,
                decoder,
                min_confidence=min_confidence,
                user_lm=user_lm,
                command_decoder=neural_decoder,
            )
    print(json.dumps(report, ensure_ascii=False, sort_keys=True))
    return 0


def _evaluate_keyboard(observations_path: Path) -> int:
    try:
        observations = load_keyboard_observations(observations_path)
        report = evaluate_keyboard_observations(
            observations,
            dataset_path=observations_path,
        )
    except (KeyboardEvaluationError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    print(json.dumps(report, ensure_ascii=False, sort_keys=True))
    return 0


def _sha256_path(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        while True:
            chunk = file.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def _train_beam_decoder(
    dataset_paths: Sequence[Path],
    language_model_path: Path,
    dictionary_path: Path,
    output_path: Path,
) -> int:
    protected_paths = {
        *(dataset_path.resolve() for dataset_path in dataset_paths),
        language_model_path.resolve(),
        dictionary_path.resolve(),
    }
    if output_path.resolve() in protected_paths:
        print(
            "error: --output must not overwrite an input artifact",
            file=sys.stderr,
        )
        return 2
    try:
        datasets = [load_dataset(dataset_path) for dataset_path in dataset_paths]
        samples = [sample for dataset in datasets for sample in dataset.samples]
        dataset_sha256 = (
            datasets[0].sha256
            if len(datasets) == 1
            else hashlib.sha256(
                b"\0".join(dataset_path.read_bytes() for dataset_path in dataset_paths)
            ).hexdigest()
        )
        language_model = load_ngram_model(language_model_path)
        guard = PinyinGuard.from_rime_dictionary(dictionary_path)
        language_model_sha256 = _sha256_path(language_model_path)
        dictionary_sha256 = _sha256_path(dictionary_path)
        config, report = train_beam_decoder_config(
            samples,
            language_model,
            guard,
            dataset_sha256=dataset_sha256,
            language_model_sha256=language_model_sha256,
            dictionary_sha256=dictionary_sha256,
        )
        write_beam_config_atomic(output_path, config)
        artifact_sha256 = _sha256_path(output_path)
    except (
        DatasetValidationError,
        NGramModelError,
        BeamDecoderError,
        OSError,
        ValueError,
    ) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    report["dataset_sha256"] = dataset_sha256
    report["datasets"] = [
        {"path": str(path), "sha256": dataset.sha256}
        for path, dataset in zip(dataset_paths, datasets)
    ]
    report["dependencies"] = {
        "language_model_sha256": language_model_sha256,
        "dictionary_sha256": dictionary_sha256,
    }
    report["artifact"] = {
        "path": str(output_path),
        "bytes": output_path.stat().st_size,
        "sha256": artifact_sha256,
    }
    print(json.dumps(report, ensure_ascii=False, sort_keys=True))
    return 0


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = _build_parser().parse_args(argv)
    if args.command == "validate":
        return _validate(args.dataset)
    if args.command == "validate-voice":
        return _validate_voice(args.corpus_root, args.profile)
    if args.command == "evaluate":
        return _evaluate(
            args.dataset,
            args.ranker,
            args.ranker_config,
            args.split,
            args.min_confidence,
            args.details_output,
            args.candidate_limit,
            args.rime_dictionary,
            args.device,
            args.neural_model,
            args.language_model,
        )
    if args.command == "evaluate-cloud":
        try:
            report = evaluate_cloud_observations(
                load_cloud_observations(args.observations)
            )
        except (CloudEvaluationError, OSError) as error:
            print(f"error: {error}", file=sys.stderr)
            return 2
        print(json.dumps(report, ensure_ascii=False, sort_keys=True))
        return 0 if report["passed"] else 1
    if args.command == "evaluate-voice":
        return _evaluate_voice(
            args.corpus_root,
            args.run,
            args.observations,
            args.baseline_run,
            args.baseline_observations,
            args.gates_config,
            args.performance_evidence,
        )
    if args.command == "collect-voice-performance":
        return _collect_voice_performance(
            args.corpus_root,
            args.run,
            args.collection_plan,
            args.native_collector,
            args.output,
        )
    if args.command == "collect-voice-observations":
        return _collect_voice_observations(
            args.corpus_root,
            args.run,
            args.native_driver,
            args.artifact_dir,
            args.output,
            args.hotwords_file,
        )
    if args.command == "compare":
        return _compare(args.reports)
    if args.command == "capture":
        return _capture(
            args.source,
            args.candidate_config,
            args.output,
            args.provenance_output,
        )
    if args.command == "train-ngram":
        return _train_ngram(args.dataset, args.output)
    if args.command == "train-neural-ranker":
        return _train_neural_ranker(
            args.dataset,
            args.base_model,
            args.base_revision,
            args.rime_dictionary,
            args.output,
            args.epochs,
            args.batch_size,
            args.learning_rate,
            args.ambiguous_repetitions,
            args.max_length,
            args.target_precision,
            args.device,
            args.seed,
        )
    if args.command == "train-neural-fusion":
        return _train_neural_fusion(
            args.dataset,
            args.neural_model,
            args.language_model,
            args.rime_dictionary,
            args.output,
            args.target_precision,
            args.device,
        )
    if args.command == "evaluate-sentence":
        return _evaluate_sentence(
            args.dataset,
            args.decoder_config,
            args.rime_dictionary,
            args.split,
            args.candidate_limit,
            args.min_confidence,
            args.details_output,
        )
    if args.command == "evaluate-keyboard":
        return _evaluate_keyboard(args.observations)
    if args.command == "train-beam-decoder":
        return _train_beam_decoder(
            args.datasets,
            args.language_model,
            args.rime_dictionary,
            args.output,
        )
    if args.command == "sentence-benchmark":
        return _sentence_benchmark(
            args.dataset,
            args.language_model,
            args.decoder_config,
            args.rime_dictionary,
            args.user_lm,
            args.command_decoder_config,
            args.split,
            args.min_confidence,
        )
    if args.command == "language-profile":
        return _language_profile_main(
            [
                "--history-db", str(args.history_db),
                "--frozen-samples", str(args.frozen_samples),
                "--baseline-model", str(args.baseline_model),
                "--train-ratio", str(args.train_ratio),
                *(["--report", str(args.report)] if args.report else []),
            ]
        )
    raise AssertionError("unreachable")
