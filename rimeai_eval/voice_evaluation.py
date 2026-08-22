"""Strict, reproducible scoring for the frozen voice corpus.

The evaluator deliberately consumes transcripts and timing events only.  It is
not a recorder, does not open audio files, and never copies per-sample text or
identifiers into its aggregate report.
"""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
import math
from pathlib import Path
import re
import unicodedata
from typing import Any, Dict, Iterable, List, Mapping, Optional, Sequence, Tuple

from .voice_dataset import VoiceCorpus
from .voice_performance import aggregate_voice_performance
from .voice_performance import voice_performance_sha256


class VoiceEvaluationError(ValueError):
    """The run cannot be evaluated without weakening its evidence contract."""


_SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
_SAFE_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
_HARDWARE_MODEL_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._,-]{0,127}$")
_ENGINE_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._@-]{0,127}$")
_OS_VERSION_RE = re.compile(r"^(\d+)(?:\.(\d+)){1,2}$")
_RUN_KEYS = {
    "schema_version",
    "evaluation_profile_id",
    "corpus_fingerprint",
    "implementation_fingerprint",
    "collection_method",
    "engine",
    "platform",
    "audio_io",
    "policy",
    "unsupported_subsets",
    "clock",
}
_ENGINE_REQUIRED_KEYS = {
    "adapter_id",
    "engine_id",
    "asset_management",
    "recognizer_locale",
    "requires_on_device",
    "supports_on_device_at_run",
}
_ENGINE_PRODUCT_IDENTITY_KEYS = {
    "artifact_id",
    "artifact_content_sha256",
    "model_id",
    "model_revision",
}
_ENGINE_OPTIONAL_KEYS = _ENGINE_PRODUCT_IDENTITY_KEYS
_CLOCK = {"domain": "helper_server_monotonic", "unit": "ms"}
_QUALITY_REPORT_SHA256_DOMAIN = b"rimeai.voice-quality-report.v2\x00"
_MAXIMUM_JSON_OBJECT_BYTES = 1 * 1_024 * 1_024
_MAXIMUM_OBSERVATION_LINE_BYTES = 1 * 1_024 * 1_024
_OBSERVATION_REQUIRED_KEYS = {
    "schema_version",
    "sample_id",
    "outcome",
    "partials",
}
_OBSERVATION_OPTIONAL_KEYS = {
    "stop_received_elapsed_ms",
    "final",
    "cancel_received_elapsed_ms",
    "capture_stopped_elapsed_ms",
    "resources",
}
_PARTIAL_KEYS = {"sequence", "text", "elapsed_ms"}
_FINAL_REQUIRED_KEYS = {"text", "elapsed_ms"}
_FINAL_OPTIONAL_KEYS = {"confidence"}
_RESOURCE_KEYS = {"processing_duration_ms", "samples"}
_RESOURCE_SAMPLE_REQUIRED_KEYS = {
    "elapsed_ms",
    "resident_memory_mb",
    "cpu_percent",
}
_RESOURCE_SAMPLE_OPTIONAL_KEYS = {"energy_impact"}

# These are all quality, latency, and resource thresholds, rather than a menu
# from which a caller can select only the metrics that happen to pass.  The two
# A/B limits encode the PRD's V1 hotword gate.
MANDATORY_GATE_THRESHOLDS = frozenset(
    {
        "mandarin_cer_max",
        "english_wer_max",
        "punctuation_edit_rate_max",
        "term_exact_match_rate_min",
        "blank_false_positive_rate_max",
        "partial_churn_rate_max",
        "collateral_substitution_rate_max",
        "first_partial_p95_ms_max",
        "stop_to_final_p95_ms_max",
        "cancel_to_capture_stop_p95_ms_max",
        "real_time_factor_p95_max",
        "cohort_peak_resident_mib_max",
        "cohort_peak_phys_footprint_mib_max",
        "voice_incremental_peak_phys_footprint_mib_max",
        "cpu_core_seconds_per_audio_second_p95_max",
        "energy_joules_per_audio_minute_p95_max",
        "product_artifact_payload_bytes_max",
        "cold_artifact_load_p95_ms_max",
        "keyboard_baseline_rime_p95_ms_max",
        "keyboard_helper_loaded_rime_p95_ms_max",
        "keyboard_helper_loaded_added_p95_ms_max",
        "keyboard_listening_cancel_to_rime_p95_ms_max",
        "keyboard_listening_cancel_added_p95_ms_max",
    }
)
HOTWORD_GATE_THRESHOLDS = frozenset(
    {
        "technical_term_exact_gain_pp_min",
        "mandarin_cer_regression_pp_max",
    }
)
MANDATORY_REQUIRED_SUBSETS = frozenset(
    {
        ("language_composition", "zh"),
        ("language_composition", "en"),
        ("language_composition", "mixed"),
        ("language_composition", "blank"),
        ("domain", "general"),
        ("domain", "software"),
        ("noise", "quiet"),
        ("noise", "common_noise"),
        ("distance", "near_field"),
        ("distance", "far_field"),
    }
)
EVIDENCE_REQUIREMENT_KEYS = frozenset(
    {
        "collection_protocol",
        "minimum_cold_artifact_load_trials",
        "minimum_paired_keyboard_sequences",
        "minimum_first_partial_samples",
        "minimum_stop_to_final_samples",
        "minimum_cancel_to_capture_stop_samples",
        "minimum_partial_churn_transitions",
        "minimum_required_subset_samples",
        "minimum_late_challenges_per_scenario",
    }
)
LATE_CHALLENGE_SCENARIOS = frozenset(
    {
        "cancel",
        "application_switch",
        "secure_input",
        "target_invalidation",
        "keyboard_input",
    }
)


class _InvalidJSON(ValueError):
    pass


@dataclass(frozen=True)
class _Sample:
    sample_id: str
    reference_text: str
    terms: Tuple["_Term", ...]
    subsets: Tuple[str, ...]
    blank: bool
    audio_duration_ms: float


@dataclass(frozen=True)
class _Term:
    text: str
    match_mode: str


def load_voice_run(path: Path, corpus: VoiceCorpus) -> Dict[str, Any]:
    """Load one strict run descriptor and bind it to ``corpus``."""

    value = _load_json_object(path, "voice run")
    _validate_loaded_run(value, corpus)
    return value


def load_voice_observations(
    path: Path, corpus: VoiceCorpus, run: Mapping[str, Any]
) -> List[Dict[str, Any]]:
    """Load JSONL observations and require exactly one row per corpus sample."""

    _validate_loaded_run(run, corpus)
    samples = _samples(corpus)
    expected_ids = {sample.sample_id for sample in samples}
    observations: List[Dict[str, Any]] = []
    seen = set()
    try:
        source = path.open("rb")
    except OSError as error:
        raise VoiceEvaluationError(f"{path}: cannot read voice observations") from error
    with source:
        line_number = 0
        while True:
            try:
                encoded = source.readline(_MAXIMUM_OBSERVATION_LINE_BYTES + 1)
            except OSError as error:
                raise VoiceEvaluationError(
                    f"{path}: cannot read voice observations"
                ) from error
            if not encoded:
                break
            line_number += 1
            if len(encoded) > _MAXIMUM_OBSERVATION_LINE_BYTES:
                raise VoiceEvaluationError(
                    f"{path}:{line_number}: observation line is too large"
                )
            if not encoded.strip():
                continue
            try:
                value = json.loads(
                    encoded.decode("utf-8"),
                    object_pairs_hook=_strict_json_object,
                    parse_constant=_reject_json_constant,
                )
            except (UnicodeDecodeError, RecursionError, ValueError) as error:
                raise VoiceEvaluationError(
                    f"{path}:{line_number}: invalid JSON"
                ) from error
            context = f"{path}:{line_number}"
            _validate_observation(value, context)
            sample_id = value["sample_id"]
            if sample_id in seen:
                raise VoiceEvaluationError(
                    f"{context}: duplicate sample_id '{sample_id}'"
                )
            if sample_id not in expected_ids:
                raise VoiceEvaluationError(
                    f"{context}: sample_id '{sample_id}' is not in corpus"
                )
            seen.add(sample_id)
            observations.append(value)
    missing = sorted(expected_ids - seen)
    if missing:
        raise VoiceEvaluationError(
            "voice observations are incomplete: missing " + ", ".join(missing)
        )
    if not observations:
        raise VoiceEvaluationError(f"{path}: contains no voice observations")
    return observations


def load_voice_gates(path: Path) -> Dict[str, Any]:
    """Load a strict gate configuration; completeness is scored fail-closed."""

    value = _load_json_object(path, "voice gates")
    _validate_gates(value)
    return value


def evaluate_voice(
    corpus: VoiceCorpus,
    run: Mapping[str, Any],
    observations: Iterable[Mapping[str, Any]],
    baseline_run: Optional[Mapping[str, Any]] = None,
    baseline_observations: Optional[Iterable[Mapping[str, Any]]] = None,
    performance_evidence: Optional[Mapping[str, Any]] = None,
    gates: Optional[Mapping[str, Any]] = None,
) -> Dict[str, Any]:
    """Aggregate a run, optionally compare it with a strict A/B baseline."""

    _validate_loaded_run(run, corpus)
    samples = _samples(corpus)
    values = [dict(value) for value in observations]
    _validate_complete_observations(values, samples)
    metrics, subsets = _score(samples, values)
    performance_metrics = None
    if performance_evidence is not None:
        performance_metrics = aggregate_voice_performance(
            performance_evidence, corpus, run
        )
        metrics["performance"] = performance_metrics
    provenance = {
        **_safe_provenance(run),
        "authenticated_production_driver": (
            performance_metrics is not None
            and performance_metrics.get("authenticated_production_driver") is True
        ),
        "corpus_purpose": _first_field(corpus, ("purpose",), default=None),
        "synthetic_fixture": bool(
            _first_field(corpus, ("synthetic_fixture",), default=False)
        ),
    }
    if performance_evidence is not None:
        provenance["performance_evidence_sha256"] = voice_performance_sha256(
            performance_evidence
        )
        provenance["collection_protocol"] = dict(
            performance_evidence["collection_protocol"]
        )
    report: Dict[str, Any] = {
        "schema_version": 2,
        "decision": "measurement_only" if gates is None else "quality_gate_evaluation",
        "provenance": provenance,
        "metrics": metrics,
        "subsets": subsets,
    }

    comparison = None
    if (baseline_run is None) != (baseline_observations is None):
        raise VoiceEvaluationError(
            "baseline_run and baseline_observations must be supplied together"
        )
    if baseline_run is not None and baseline_observations is not None:
        _validate_loaded_run(baseline_run, corpus)
        baseline_values = [dict(value) for value in baseline_observations]
        _validate_complete_observations(baseline_values, samples)
        baseline_metrics, baseline_subsets = _score(samples, baseline_values)
        comparison = _compare_runs(
            run,
            baseline_run,
            metrics,
            baseline_metrics,
            subsets,
            baseline_subsets,
        )
        report["comparison"] = comparison

    if gates is not None:
        _validate_gates(gates)
        if gates["evaluation_profile_id"] != run["evaluation_profile_id"]:
            raise VoiceEvaluationError(
                "voice gates evaluation_profile_id does not match run"
            )
        expected_thresholds = set(MANDATORY_GATE_THRESHOLDS)
        if run["policy"]["hotwords_enabled"]:
            expected_thresholds.update(HOTWORD_GATE_THRESHOLDS)
        required_subsets = {
            (item["dimension"], item["value"])
            for item in gates["required_subsets"]
        }
        evidence_requirements = gates.get("evidence_requirements", {})
        challenge_requirements = evidence_requirements.get(
            "minimum_late_challenges_per_scenario", {}
        )
        authenticated_production_driver = (
            performance_metrics is not None
            and performance_metrics.get("authenticated_production_driver") is True
        )
        configuration_complete = (
            set(gates["thresholds"]) == expected_thresholds
            and MANDATORY_REQUIRED_SUBSETS <= required_subsets
            and set(evidence_requirements) == EVIDENCE_REQUIREMENT_KEYS
            and set(challenge_requirements) == LATE_CHALLENGE_SCENARIOS
            and authenticated_production_driver
        )
        checks = _evaluate_gates(
            corpus=corpus,
            run=run,
            metrics=metrics,
            subsets=subsets,
            comparison=comparison,
            performance_metrics=performance_metrics,
            gates=gates,
            configuration_complete=configuration_complete,
        )
        report["gates"] = checks
        incomplete = any(
            check.get("evidence_complete") is False for check in checks.values()
        )
        ineligible = any(
            not checks[name]["passed"]
            for name in (
                "frozen_non_fixture_evidence",
                "engine_policy_eligible",
                "on_device_runtime_eligible",
            )
        )
        if incomplete:
            report["decision"] = "policy_incomplete"
        elif ineligible:
            report["decision"] = "policy_ineligible"
        elif all(check["passed"] for check in checks.values()):
            report["decision"] = "pass"
        else:
            report["decision"] = "fail"
        report["quality_gate_pass"] = report["decision"] == "pass"
    _assert_private_aggregate(report)
    report["quality_report_sha256"] = quality_report_sha256(report)
    return report


def quality_report_sha256(report: Mapping[str, Any]) -> str:
    """Hash canonical report semantics without recursively hashing the digest."""

    if not isinstance(report, Mapping):
        raise VoiceEvaluationError("voice quality report must be an object")
    payload = dict(report)
    payload.pop("quality_report_sha256", None)
    try:
        canonical = json.dumps(
            payload,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
            allow_nan=False,
        ).encode("utf-8")
    except (TypeError, ValueError) as error:
        raise VoiceEvaluationError(
            "voice quality report cannot be canonically hashed"
        ) from error
    return hashlib.sha256(_QUALITY_REPORT_SHA256_DOMAIN + canonical).hexdigest()


def compare_voice_reports(
    baseline: Mapping[str, Any], candidate: Mapping[str, Any]
) -> Dict[str, Any]:
    """Compare two aggregate reports after checking collection comparability."""

    for label, report in (("baseline", baseline), ("candidate", candidate)):
        if not isinstance(report, Mapping):
            raise VoiceEvaluationError(f"{label} report must be an object")
        if not isinstance(report.get("provenance"), Mapping) or not isinstance(
            report.get("metrics"), Mapping
        ):
            raise VoiceEvaluationError(f"{label} report is missing aggregate fields")
    return _compare_safe_reports(baseline, candidate)


def _load_json_object(path: Path, label: str) -> Dict[str, Any]:
    try:
        with path.open("rb") as source:
            encoded = source.read(_MAXIMUM_JSON_OBJECT_BYTES + 1)
    except OSError as error:
        raise VoiceEvaluationError(f"{path}: cannot read {label}") from error
    if len(encoded) > _MAXIMUM_JSON_OBJECT_BYTES:
        raise VoiceEvaluationError(f"{label} is too large")
    try:
        value = json.loads(
            encoded.decode("utf-8"),
            object_pairs_hook=_strict_json_object,
            parse_constant=_reject_json_constant,
        )
    except (UnicodeDecodeError, RecursionError, ValueError) as error:
        raise VoiceEvaluationError(f"{path}: invalid JSON") from error
    if not isinstance(value, dict):
        raise VoiceEvaluationError(f"{label} must be an object")
    return value


def _strict_json_object(pairs: Sequence[Tuple[str, Any]]) -> Dict[str, Any]:
    value: Dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            raise _InvalidJSON("duplicate object key")
        value[key] = item
    return value


def _reject_json_constant(_: str) -> None:
    raise _InvalidJSON("non-finite JSON number")


def _require_exact_keys(
    value: Mapping[str, Any], expected: set, context: str
) -> None:
    if not isinstance(value, Mapping):
        raise VoiceEvaluationError(f"{context} must be an object")
    missing = sorted(expected - set(value))
    extra = sorted(set(value) - expected)
    if missing or extra:
        details = []
        if missing:
            details.append("missing " + ", ".join(missing))
        if extra:
            details.append("unknown " + ", ".join(extra))
        raise VoiceEvaluationError(f"{context} fields are invalid: {'; '.join(details)}")


def _require_allowed_keys(
    value: Mapping[str, Any], required: set, optional: set, context: str
) -> None:
    if not isinstance(value, Mapping):
        raise VoiceEvaluationError(f"{context} must be an object")
    missing = sorted(required - set(value))
    extra = sorted(set(value) - required - optional)
    if missing or extra:
        details = []
        if missing:
            details.append("missing " + ", ".join(missing))
        if extra:
            details.append("unknown " + ", ".join(extra))
        raise VoiceEvaluationError(f"{context} fields are invalid: {'; '.join(details)}")


def _require_sha256(value: Any, field: str) -> None:
    if not isinstance(value, str) or _SHA256_RE.fullmatch(value) is None:
        raise VoiceEvaluationError(f"{field} must be 64 lowercase hexadecimal characters")


def _require_nonempty_string(value: Any, field: str) -> None:
    if not isinstance(value, str) or not value.strip():
        raise VoiceEvaluationError(f"{field} must be a non-empty string")


def _require_safe_id(value: Any, field: str) -> None:
    if not isinstance(value, str) or _SAFE_ID_RE.fullmatch(value) is None:
        raise VoiceEvaluationError(f"{field} must be a controlled non-sensitive identifier")


def _require_hardware_model(value: Any, field: str) -> None:
    if not isinstance(value, str) or _HARDWARE_MODEL_RE.fullmatch(value) is None:
        raise VoiceEvaluationError(
            f"{field} must be a controlled non-sensitive hardware model identifier"
        )


def _require_engine_id(value: Any, field: str) -> None:
    if not isinstance(value, str) or _ENGINE_ID_RE.fullmatch(value) is None:
        raise VoiceEvaluationError(
            f"{field} must be a controlled non-sensitive engine identifier"
        )


def _validate_loaded_run(run: Mapping[str, Any], corpus: VoiceCorpus) -> None:
    if not isinstance(run, Mapping):
        raise VoiceEvaluationError("voice run must be an object")
    # Reuse the same invariant checks without depending on a file round trip.
    _require_exact_keys(run, _RUN_KEYS, "voice run")
    if type(run.get("schema_version")) is not int or run["schema_version"] != 2:
        raise VoiceEvaluationError("voice run schema_version must be 2")
    _require_safe_id(run.get("evaluation_profile_id"), "evaluation_profile_id")
    _require_sha256(run.get("corpus_fingerprint"), "corpus_fingerprint")
    if run["corpus_fingerprint"] != _corpus_fingerprint(corpus):
        raise VoiceEvaluationError("voice run corpus_fingerprint does not match corpus")
    _require_sha256(
        run.get("implementation_fingerprint"), "implementation_fingerprint"
    )
    if run.get("collection_method") not in {"automated", "manual_assistive"}:
        raise VoiceEvaluationError(
            "collection_method must be automated or manual_assistive"
        )
    engine = run.get("engine")
    _require_allowed_keys(
        engine, _ENGINE_REQUIRED_KEYS, _ENGINE_OPTIONAL_KEYS, "voice run engine"
    )
    for field in ("adapter_id", "recognizer_locale"):
        _require_safe_id(engine.get(field), f"engine.{field}")
    _require_engine_id(engine.get("engine_id"), "engine.engine_id")
    for field in ("artifact_id", "model_id", "model_revision"):
        if field in engine:
            _require_safe_id(engine[field], f"engine.{field}")
    if "artifact_content_sha256" in engine:
        _require_sha256(
            engine["artifact_content_sha256"],
            "engine.artifact_content_sha256",
        )
    for field in ("requires_on_device", "supports_on_device_at_run"):
        if not isinstance(engine.get(field), bool):
            raise VoiceEvaluationError(f"engine.{field} must be boolean")
    if engine.get("asset_management") == "system":
        if _ENGINE_PRODUCT_IDENTITY_KEYS & set(engine):
            raise VoiceEvaluationError(
                "system-managed engine must not claim product identity"
            )
    elif engine.get("asset_management") == "product":
        if not _ENGINE_PRODUCT_IDENTITY_KEYS <= set(engine):
            raise VoiceEvaluationError(
                "product-managed engine requires product artifact identity"
            )
    else:
        raise VoiceEvaluationError(
            "engine.asset_management must be system or product"
        )

    platform = run.get("platform")
    _require_exact_keys(
        platform,
        {"os_version", "os_build", "hardware_class", "arch"},
        "platform",
    )
    os_version = platform.get("os_version")
    if not isinstance(os_version, str) or _OS_VERSION_RE.fullmatch(os_version) is None:
        raise VoiceEvaluationError(
            "platform.os_version must be a dotted numeric macOS version"
        )
    try:
        os_major = int(os_version.split(".", 1)[0])
    except ValueError as error:
        raise VoiceEvaluationError(
            "platform.os_version must be a dotted numeric macOS version"
        ) from error
    if os_major < 14:
        raise VoiceEvaluationError("platform.os_version must be macOS 14 or newer")
    _require_safe_id(platform.get("os_build"), "platform.os_build")
    _require_hardware_model(
        platform.get("hardware_class"), "platform.hardware_class"
    )
    if platform.get("arch") != "arm64":
        raise VoiceEvaluationError("platform.arch must be arm64")

    audio_io = run.get("audio_io")
    _require_exact_keys(
        audio_io,
        {"device_class", "sample_format", "sample_rate_hz", "channels"},
        "audio_io",
    )
    if audio_io.get("device_class") not in {
        "built_in",
        "usb",
        "headset",
        "bluetooth",
        "virtual_fixture",
    }:
        raise VoiceEvaluationError("audio_io.device_class is invalid")
    if audio_io.get("sample_format") != "pcm_s16le":
        raise VoiceEvaluationError("audio_io.sample_format must be pcm_s16le")
    for field in ("sample_rate_hz", "channels"):
        value = audio_io.get(field)
        if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
            raise VoiceEvaluationError(f"audio_io.{field} must be a positive integer")

    policy = run.get("policy")
    _require_allowed_keys(
        policy,
        {"endpoint_strategy", "hotwords_enabled", "postprocessor_id"},
        {"hotword_set_sha256"},
        "policy",
    )
    _require_safe_id(policy.get("endpoint_strategy"), "policy.endpoint_strategy")
    _require_safe_id(policy.get("postprocessor_id"), "policy.postprocessor_id")
    if not isinstance(policy.get("hotwords_enabled"), bool):
        raise VoiceEvaluationError("policy.hotwords_enabled must be boolean")
    if policy["hotwords_enabled"]:
        if "hotword_set_sha256" not in policy:
            raise VoiceEvaluationError(
                "hotword-enabled policy requires hotword_set_sha256"
            )
        _require_sha256(policy["hotword_set_sha256"], "policy.hotword_set_sha256")
    elif "hotword_set_sha256" in policy:
        raise VoiceEvaluationError(
            "hotword-disabled policy must not contain hotword_set_sha256"
        )

    unsupported = run.get("unsupported_subsets")
    if not isinstance(unsupported, list):
        raise VoiceEvaluationError(
            "unsupported_subsets must be an array"
        )
    unsupported_keys = set()
    for index, item in enumerate(unsupported):
        context = f"unsupported_subsets[{index}]"
        _require_exact_keys(item, {"dimension", "value", "reason_code"}, context)
        if item["dimension"] not in {
            "language_composition",
            "domain",
            "noise",
            "distance",
        }:
            raise VoiceEvaluationError(f"{context}.dimension is invalid")
        _require_safe_id(item["value"], f"{context}.value")
        _require_safe_id(item["reason_code"], f"{context}.reason_code")
        identity = (item["dimension"], item["value"])
        if identity in unsupported_keys:
            raise VoiceEvaluationError(f"{context} is duplicated")
        unsupported_keys.add(identity)
    if run.get("clock") != _CLOCK:
        raise VoiceEvaluationError(
            "clock must be helper_server_monotonic milliseconds"
        )


def _validate_observation(value: Any, context: str) -> None:
    _require_allowed_keys(
        value,
        _OBSERVATION_REQUIRED_KEYS,
        _OBSERVATION_OPTIONAL_KEYS,
        context,
    )
    if type(value["schema_version"]) is not int or value["schema_version"] != 1:
        raise VoiceEvaluationError(f"{context}: schema_version must be 1")
    _require_safe_id(value["sample_id"], f"{context}: sample_id")
    if value["outcome"] not in {"final", "no_result", "cancelled", "error"}:
        raise VoiceEvaluationError(f"{context}: outcome is invalid")
    partials = value["partials"]
    if not isinstance(partials, list):
        raise VoiceEvaluationError(f"{context}: partials must be an array")
    previous_sequence = -1
    previous_at = -1.0
    for index, partial in enumerate(partials):
        partial_context = f"{context}: partials[{index}]"
        _require_exact_keys(partial, _PARTIAL_KEYS, partial_context)
        sequence = partial["sequence"]
        if not isinstance(sequence, int) or isinstance(sequence, bool) or sequence < 0:
            raise VoiceEvaluationError(
                f"{partial_context}: sequence must be a non-negative integer"
            )
        if sequence <= previous_sequence:
            raise VoiceEvaluationError(
                f"{context}: partial sequence must be strictly increasing"
            )
        at_ms = _clock_value(
            partial["elapsed_ms"], f"{partial_context}: elapsed_ms"
        )
        if at_ms <= previous_at:
            raise VoiceEvaluationError(
                f"{context}: partial time must be strictly increasing"
            )
        if not isinstance(partial["text"], str):
            raise VoiceEvaluationError(f"{partial_context}: text must be a string")
        previous_sequence = sequence
        previous_at = at_ms

    stop = _optional_event(value, "stop_received_elapsed_ms", context)
    cancel = _optional_event(value, "cancel_received_elapsed_ms", context)
    capture_stopped = _optional_event(value, "capture_stopped_elapsed_ms", context)
    final = value.get("final")
    final_elapsed = None
    if final is not None:
        _require_allowed_keys(
            final, _FINAL_REQUIRED_KEYS, _FINAL_OPTIONAL_KEYS, f"{context}: final"
        )
        if not isinstance(final["text"], str):
            raise VoiceEvaluationError(f"{context}: final.text must be a string")
        final_elapsed = _clock_value(
            final["elapsed_ms"], f"{context}: final.elapsed_ms"
        )
        if "confidence" in final:
            confidence = final["confidence"]
            if (
                not _is_finite_number(confidence)
                or not 0 <= confidence <= 1
            ):
                raise VoiceEvaluationError(
                    f"{context}: final.confidence must be between 0 and 1"
                )

    outcome = value["outcome"]
    if outcome == "final":
        if stop is None or final_elapsed is None:
            raise VoiceEvaluationError(
                f"{context}: final outcome requires stop_received_elapsed_ms and final"
            )
        if cancel is not None or capture_stopped is not None:
            raise VoiceEvaluationError(
                f"{context}: final outcome contains incompatible cancellation fields"
            )
        if stop > final_elapsed:
            raise VoiceEvaluationError(f"{context}: stop occurs after final")
        terminal = final_elapsed
    elif outcome == "cancelled":
        if cancel is None or capture_stopped is None:
            raise VoiceEvaluationError(
                f"{context}: cancelled outcome requires cancel and capture-stop events"
            )
        if final is not None:
            raise VoiceEvaluationError(
                f"{context}: cancelled outcome must not contain final"
            )
        if cancel > capture_stopped:
            raise VoiceEvaluationError(
                f"{context}: cancel occurs after capture stopped"
            )
        if stop is not None and stop > cancel:
            raise VoiceEvaluationError(f"{context}: stop occurs after cancel")
        terminal = capture_stopped
    else:
        if final is not None or cancel is not None or capture_stopped is not None:
            raise VoiceEvaluationError(
                f"{context}: {outcome} outcome contains incompatible terminal fields"
            )
        if outcome == "no_result" and stop is None:
            raise VoiceEvaluationError(
                f"{context}: no_result outcome requires stop_received_elapsed_ms"
            )
        terminal = stop
    if terminal is not None and partials and previous_at > terminal:
        raise VoiceEvaluationError(f"{context}: partial occurs after terminal event")
    if "resources" in value:
        _validate_resources(value["resources"], context)


def _optional_event(
    value: Mapping[str, Any], key: str, context: str
) -> Optional[float]:
    if key not in value:
        return None
    return _clock_value(value[key], f"{context}: {key}")


def _validate_resources(value: Any, context: str) -> None:
    _require_allowed_keys(value, set(), _RESOURCE_KEYS, f"{context}: resources")
    if not value:
        raise VoiceEvaluationError(f"{context}: resources must not be empty")
    if "processing_duration_ms" in value:
        _clock_value(
            value["processing_duration_ms"],
            f"{context}: resources.processing_duration_ms",
        )
    if "samples" in value:
        samples = value["samples"]
        if not isinstance(samples, list) or not samples:
            raise VoiceEvaluationError(
                f"{context}: resources.samples must be a non-empty array"
            )
        previous_elapsed = -1.0
        for index, sample in enumerate(samples):
            sample_context = f"{context}: resources.samples[{index}]"
            _require_allowed_keys(
                sample,
                _RESOURCE_SAMPLE_REQUIRED_KEYS,
                _RESOURCE_SAMPLE_OPTIONAL_KEYS,
                sample_context,
            )
            elapsed = _clock_value(sample["elapsed_ms"], f"{sample_context}.elapsed_ms")
            if elapsed <= previous_elapsed:
                raise VoiceEvaluationError(
                    f"{context}: resource sample time must be strictly increasing"
                )
            previous_elapsed = elapsed
            for key in ("resident_memory_mb", "cpu_percent", "energy_impact"):
                if key in sample:
                    _clock_value(sample[key], f"{sample_context}.{key}")


def _clock_value(value: Any, field: str) -> float:
    if (
        not _is_finite_number(value)
        or value < 0
    ):
        raise VoiceEvaluationError(f"{field} must be a finite non-negative number")
    return float(value)


def _optional_clock_value(value: Any, field: str) -> Optional[float]:
    if value is None:
        return None
    return _clock_value(value, field)


def _validate_complete_observations(
    observations: Sequence[Mapping[str, Any]], samples: Sequence[_Sample]
) -> None:
    expected = {sample.sample_id for sample in samples}
    seen = set()
    for index, observation in enumerate(observations):
        _validate_observation(observation, f"observation[{index}]")
        sample_id = observation["sample_id"]
        if sample_id in seen:
            raise VoiceEvaluationError(f"duplicate sample_id '{sample_id}'")
        if sample_id not in expected:
            raise VoiceEvaluationError(f"sample_id '{sample_id}' is not in corpus")
        seen.add(sample_id)
    missing = sorted(expected - seen)
    if missing:
        raise VoiceEvaluationError(
            "voice observations are incomplete: missing " + ", ".join(missing)
        )


def _samples(corpus: Any) -> List[_Sample]:
    raw_samples = _field(corpus, "samples")
    if not isinstance(raw_samples, Sequence) or isinstance(raw_samples, (str, bytes)):
        raise VoiceEvaluationError("voice corpus samples are invalid")
    samples = []
    seen = set()
    for index, raw in enumerate(raw_samples):
        sample_id = _first_field(raw, ("id", "sample_id"))
        reference = _first_field(raw, ("reference", "reference_text"))
        if not isinstance(sample_id, str) or not sample_id:
            raise VoiceEvaluationError(f"corpus sample {index} has invalid sample_id")
        if sample_id in seen:
            raise VoiceEvaluationError(f"corpus has duplicate sample_id '{sample_id}'")
        if not isinstance(reference, str):
            raise VoiceEvaluationError(
                f"corpus sample '{sample_id}' has invalid reference_text"
            )
        raw_terms = _first_field(raw, ("terms",), default=[])
        if not isinstance(raw_terms, Sequence) or isinstance(raw_terms, (str, bytes)):
            raise VoiceEvaluationError(f"corpus sample '{sample_id}' terms are invalid")
        terms_list = []
        for term in raw_terms:
            term_text = _first_field(term, ("text",))
            match_mode = _first_field(term, ("match_mode",))
            if (
                not isinstance(term_text, str)
                or not term_text
                or match_mode not in {"exact", "ascii_casefold_word"}
            ):
                raise VoiceEvaluationError(
                    f"corpus sample '{sample_id}' terms are invalid"
                )
            terms_list.append(_Term(term_text, match_mode))
        terms = tuple(terms_list)
        domain = _first_field(raw, ("domain",))
        language = _first_field(raw, ("language_composition",))
        conditions = _first_field(raw, ("conditions",))
        noise = _first_field(conditions, ("noise",))
        distance = _first_field(conditions, ("distance",))
        dimension_values = (
            ("domain", domain),
            ("language_composition", language),
            ("noise", noise),
            ("distance", distance),
        )
        if any(not isinstance(item, str) or not item for _, item in dimension_values):
            raise VoiceEvaluationError(f"corpus sample '{sample_id}' subsets are invalid")
        subsets = tuple(
            "%s:%s" % (dimension, value) for dimension, value in dimension_values
        )
        blank_field = _first_field(raw, ("is_blank", "blank"), default=None)
        if blank_field is None:
            blank = not bool(_normalize(reference).strip())
        elif isinstance(blank_field, bool):
            blank = blank_field
        else:
            raise VoiceEvaluationError(f"corpus sample '{sample_id}' blank is invalid")
        audio = _first_field(raw, ("audio",))
        audio_duration_ms = _first_field(audio, ("duration_ms",))
        if (
            not _is_finite_number(audio_duration_ms)
            or audio_duration_ms <= 0
        ):
            raise VoiceEvaluationError(
                f"corpus sample '{sample_id}' audio duration is invalid"
            )
        samples.append(
            _Sample(
                sample_id=sample_id,
                reference_text=reference,
                terms=terms,
                subsets=tuple(sorted(set(subsets))),
                blank=blank,
                audio_duration_ms=float(audio_duration_ms),
            )
        )
        seen.add(sample_id)
    if not samples:
        raise VoiceEvaluationError("voice corpus contains no samples")
    return samples


def _field(value: Any, name: str) -> Any:
    if isinstance(value, Mapping):
        if name not in value:
            raise VoiceEvaluationError(f"voice corpus is missing {name}")
        return value[name]
    if not hasattr(value, name):
        raise VoiceEvaluationError(f"voice corpus is missing {name}")
    return getattr(value, name)


_MISSING = object()


def _first_field(value: Any, names: Sequence[str], default: Any = _MISSING) -> Any:
    for name in names:
        if isinstance(value, Mapping) and name in value:
            return value[name]
        if not isinstance(value, Mapping) and hasattr(value, name):
            return getattr(value, name)
    if default is not _MISSING:
        return default
    raise VoiceEvaluationError("voice corpus sample is missing " + "/".join(names))


def _corpus_fingerprint(corpus: Any) -> str:
    value = _first_field(corpus, ("fingerprint", "sha256"))
    _require_sha256(value, "corpus fingerprint")
    return value


def _normalize(text: str) -> str:
    return unicodedata.normalize("NFKC", text).casefold()


def _is_han(character: str) -> bool:
    codepoint = ord(character)
    return (
        0x3400 <= codepoint <= 0x4DBF
        or 0x4E00 <= codepoint <= 0x9FFF
        or 0xF900 <= codepoint <= 0xFAFF
        or 0x20000 <= codepoint <= 0x323AF
    )


def _han_digit_units(text: str) -> List[str]:
    return [character for character in _normalize(text) if _is_han(character) or character.isdigit()]


def _latin_digit_words(text: str) -> List[str]:
    words = []
    current = []
    for character in _normalize(text):
        is_latin = character.isalpha() and unicodedata.name(character, "").startswith(
            "LATIN"
        )
        if is_latin or character.isdigit():
            current.append(character)
        elif current:
            words.append("".join(current))
            current = []
    if current:
        words.append("".join(current))
    return words


def _punctuation_units(text: str) -> List[str]:
    return [
        character
        for character in _normalize(text)
        if unicodedata.category(character).startswith("P")
    ]


def _edit_distance(reference: Sequence[str], hypothesis: Sequence[str]) -> int:
    if len(reference) > len(hypothesis):
        reference, hypothesis = hypothesis, reference
    previous = list(range(len(reference) + 1))
    for row, hypothesis_item in enumerate(hypothesis, start=1):
        current = [row]
        for column, reference_item in enumerate(reference, start=1):
            current.append(
                min(
                    previous[column] + 1,
                    current[column - 1] + 1,
                    previous[column - 1]
                    + (reference_item != hypothesis_item),
                )
            )
        previous = current
    return previous[-1]


def _score(
    samples: Sequence[_Sample], observations: Sequence[Mapping[str, Any]]
) -> Tuple[Dict[str, Any], Dict[str, Dict[str, Any]]]:
    by_id = {value["sample_id"]: value for value in observations}
    all_terms = tuple(
        sorted(
            {term for sample in samples for term in sample.terms},
            key=lambda term: (term.text, term.match_mode),
        )
    )
    overall = _score_slice(samples, by_id, all_terms)
    subset_names = sorted({subset for sample in samples for subset in sample.subsets})
    subsets = {
        subset: _score_slice(
            [sample for sample in samples if subset in sample.subsets],
            by_id,
            all_terms,
        )
        for subset in subset_names
    }
    return overall, subsets


def _score_slice(
    samples: Sequence[_Sample],
    by_id: Mapping[str, Mapping[str, Any]],
    all_terms: Sequence[_Term],
) -> Dict[str, Any]:
    han_errors = han_reference = 0
    word_errors = word_reference = 0
    punctuation_errors = punctuation_reference = 0
    punctuation_exact_matches = 0
    term_matches = term_reference = 0
    blank_false_positives = blank_samples = 0
    collateral_substitutions = collateral_opportunities = 0
    churn_edits = churn_reference = churn_transitions = 0
    first_partial_latencies = []
    stop_to_final_latencies = []
    cancel_to_capture_stop_latencies = []
    processing_durations = []
    memory_samples = []
    cpu_samples = []
    energy_samples = []
    real_time_factors = []
    outcomes = {"final": 0, "no_result": 0, "cancelled": 0, "error": 0}

    for sample in samples:
        observation = by_id[sample.sample_id]
        outcomes[observation["outcome"]] += 1
        final = observation.get("final")
        hypothesis = final["text"] if isinstance(final, Mapping) else ""
        reference_han = _han_digit_units(sample.reference_text)
        hypothesis_han = _han_digit_units(hypothesis)
        han_errors += _edit_distance(reference_han, hypothesis_han)
        han_reference += len(reference_han)
        reference_words = _latin_digit_words(sample.reference_text)
        hypothesis_words = _latin_digit_words(hypothesis)
        word_errors += _edit_distance(reference_words, hypothesis_words)
        word_reference += len(reference_words)
        reference_punctuation = _punctuation_units(sample.reference_text)
        hypothesis_punctuation = _punctuation_units(hypothesis)
        punctuation_errors += _edit_distance(
            reference_punctuation, hypothesis_punctuation
        )
        punctuation_reference += len(reference_punctuation)
        punctuation_exact_matches += reference_punctuation == hypothesis_punctuation
        for term in sample.terms:
            term_reference += 1
            term_matches += _contains_term(hypothesis, term)
        intended_terms = {(term.text, term.match_mode) for term in sample.terms}
        # This is deliberately a narrow, reproducible hotword-injection proxy:
        # count a corpus-annotated term only when neither this sample's
        # annotations nor its reference contain it, but the hypothesis does.
        # It does not infer what text was displaced or detect substitutions by
        # words that are not annotated anywhere in the corpus.
        for term in all_terms:
            if (term.text, term.match_mode) in intended_terms or _contains_term(
                sample.reference_text, term
            ):
                continue
            collateral_opportunities += 1
            collateral_substitutions += _contains_term(hypothesis, term)
        if sample.blank:
            blank_samples += 1
            normalized_hypothesis = _normalize(hypothesis)
            nonspace = [char for char in normalized_hypothesis if not char.isspace()]
            if nonspace:
                blank_false_positives += 1

        partials = observation["partials"]
        previous_units: Optional[List[str]] = None
        for partial in partials:
            current_units = list(_normalize(partial["text"]))
            if previous_units is not None:
                churn_edits += _edit_distance(previous_units, current_units)
                churn_reference += max(len(previous_units), len(current_units))
                churn_transitions += 1
            previous_units = current_units
        if partials:
            first_partial_latencies.append(float(partials[0]["elapsed_ms"]))
        if observation["outcome"] == "final":
            stop_to_final_latencies.append(
                float(observation["final"]["elapsed_ms"])
                - float(observation["stop_received_elapsed_ms"])
            )
        if observation["outcome"] == "cancelled":
            cancel_to_capture_stop_latencies.append(
                float(observation["capture_stopped_elapsed_ms"])
                - float(observation["cancel_received_elapsed_ms"])
            )
        resources = observation.get("resources", {})
        if "processing_duration_ms" in resources:
            processing_duration = float(resources["processing_duration_ms"])
            processing_durations.append(processing_duration)
            real_time_factors.append(
                processing_duration / sample.audio_duration_ms
            )
        for resource_sample in resources.get("samples", []):
            memory_samples.append(float(resource_sample["resident_memory_mb"]))
            cpu_samples.append(float(resource_sample["cpu_percent"]))
            if "energy_impact" in resource_sample:
                energy_samples.append(float(resource_sample["energy_impact"]))

    return {
        "samples": len(samples),
        "outcomes": outcomes,
        "mandarin_cer": _error_metric(han_errors, han_reference, "rate"),
        "english_wer": _error_metric(word_errors, word_reference, "rate"),
        "punctuation_edit_rate": _error_metric(
            punctuation_errors, punctuation_reference, "rate"
        ),
        "punctuation_exact_sequence": {
            "matches": punctuation_exact_matches,
            "samples": len(samples),
            "rate": _ratio(punctuation_exact_matches, len(samples)),
            "measurement": _measurement(len(samples)),
        },
        "term_exact_match": {
            "matches": term_matches,
            "reference_terms": term_reference,
            "rate": _ratio(term_matches, term_reference),
            "measurement": _measurement(term_reference),
        },
        "blank_false_positive": {
            "false_positives": blank_false_positives,
            "blank_samples": blank_samples,
            "rate": _ratio(blank_false_positives, blank_samples),
            "measurement": _measurement(blank_samples),
        },
        "partial_churn": {
            "edits": churn_edits,
            "reference_units": churn_reference,
            "transitions": churn_transitions,
            "rate": _ratio(churn_edits, churn_transitions),
            "revisions_per_sample": _ratio(churn_transitions, len(samples)),
            "measurement": _measurement(churn_transitions),
        },
        "collateral_substitution": {
            "substitutions": collateral_substitutions,
            "opportunities": collateral_opportunities,
            "rate": _ratio(collateral_substitutions, collateral_opportunities),
            "measurement": _measurement(collateral_opportunities),
        },
        "latency_ms": {
            "first_partial": _latency_metric(first_partial_latencies),
            "stop_to_final": _latency_metric(stop_to_final_latencies),
            "cancel_to_capture_stop": _latency_metric(
                cancel_to_capture_stop_latencies
            ),
        },
        "resources": {
            "processing_duration_ms": _latency_metric(processing_durations),
            "resident_memory_mb": _distribution_metric(memory_samples),
            "cpu_percent": _distribution_metric(cpu_samples),
            "energy_impact": _distribution_metric(energy_samples),
            "real_time_factor": _distribution_metric(real_time_factors),
        },
    }


def _contains_term(text: str, term: _Term) -> bool:
    haystack = _normalize(text)
    needle = _normalize(term.text)
    if not needle:
        return False
    word_mode = term.match_mode == "ascii_casefold_word"
    left_boundary = word_mode and bool(needle[0].isascii() and needle[0].isalnum())
    right_boundary = word_mode and bool(needle[-1].isascii() and needle[-1].isalnum())
    pattern = re.escape(needle)
    if left_boundary:
        pattern = r"(?<![A-Za-z0-9_])" + pattern
    if right_boundary:
        pattern += r"(?![A-Za-z0-9_])"
    return re.search(pattern, haystack) is not None


def _error_metric(errors: int, reference_units: int, rate_name: str) -> Dict[str, Any]:
    return {
        "edits": errors,
        "reference_units": reference_units,
        rate_name: _ratio(errors, reference_units),
        "measurement": _measurement(reference_units),
    }


def _ratio(numerator: int, denominator: int) -> Optional[float]:
    if denominator == 0:
        return None
    return round(numerator / denominator, 6)


def _measurement(denominator: int) -> str:
    return "measured" if denominator else "unmeasured"


def _latency_metric(values: Sequence[float]) -> Dict[str, Any]:
    return {
        "samples": len(values),
        "p50": _percentile(values, 0.50),
        "p95": _percentile(values, 0.95),
        "measurement": "measured" if values else "unmeasured",
    }


def _distribution_metric(values: Sequence[float]) -> Dict[str, Any]:
    if not values:
        return {
            "samples": 0,
            "p50": None,
            "p95": None,
            "max": None,
            "measurement": "unmeasured",
        }
    return {
        "samples": len(values),
        "p50": _percentile(values, 0.50),
        "p95": _percentile(values, 0.95),
        "max": round(max(values), 6),
        "measurement": "measured",
    }


def _percentile(values: Sequence[float], percentile: float) -> Optional[float]:
    if not values:
        return None
    ordered = sorted(values)
    rank = max(1, math.ceil(percentile * len(ordered)))
    return round(float(ordered[rank - 1]), 6)


def _safe_provenance(run: Mapping[str, Any]) -> Dict[str, Any]:
    return {
        "evaluation_profile_id": run["evaluation_profile_id"],
        "corpus_fingerprint": run["corpus_fingerprint"],
        "implementation_fingerprint": run["implementation_fingerprint"],
        "collection_method": run["collection_method"],
        "engine": dict(run["engine"]),
        "platform": dict(run["platform"]),
        "audio_io": dict(run["audio_io"]),
        "policy": dict(run["policy"]),
        "unsupported_subsets": sorted(
            (dict(item) for item in run["unsupported_subsets"]),
            key=lambda item: (item["dimension"], item["value"]),
        ),
        "clock": dict(run["clock"]),
    }


def _validate_gates(gates: Mapping[str, Any]) -> None:
    _require_exact_keys(
        gates,
        {
            "schema_version",
            "evaluation_profile_id",
            "required_subsets",
            "thresholds",
            "evidence_requirements",
        },
        "voice gates",
    )
    if type(gates["schema_version"]) is not int or gates["schema_version"] != 2:
        raise VoiceEvaluationError("voice gates schema_version must be 2")
    _require_safe_id(gates["evaluation_profile_id"], "gates.evaluation_profile_id")
    required_subsets = gates["required_subsets"]
    if not isinstance(required_subsets, list):
        raise VoiceEvaluationError("voice gates required_subsets must be an array")
    identities = set()
    for index, item in enumerate(required_subsets):
        context = f"voice gates required_subsets[{index}]"
        _require_exact_keys(item, {"dimension", "value"}, context)
        if item["dimension"] not in {
            "language_composition",
            "domain",
            "noise",
            "distance",
        }:
            raise VoiceEvaluationError(f"{context}.dimension is invalid")
        _require_safe_id(item["value"], f"{context}.value")
        identity = (item["dimension"], item["value"])
        if identity in identities:
            raise VoiceEvaluationError(f"{context} is duplicated")
        identities.add(identity)
    thresholds = gates["thresholds"]
    if not isinstance(thresholds, Mapping):
        raise VoiceEvaluationError("voice gate thresholds must be an object")
    unknown = set(thresholds) - MANDATORY_GATE_THRESHOLDS - HOTWORD_GATE_THRESHOLDS
    if unknown:
        raise VoiceEvaluationError(
            "voice gate thresholds contain unknown fields: "
            + ", ".join(sorted(unknown))
        )
    for key, value in thresholds.items():
        if (
            not _is_finite_number(value)
            or value < 0
        ):
            raise VoiceEvaluationError(f"voice gate threshold {key} is invalid")
    evidence_requirements = gates["evidence_requirements"]
    if not isinstance(evidence_requirements, Mapping):
        raise VoiceEvaluationError("voice gate evidence_requirements must be an object")
    unknown_requirements = set(evidence_requirements) - EVIDENCE_REQUIREMENT_KEYS
    if unknown_requirements:
        raise VoiceEvaluationError(
            "voice gate evidence_requirements contain unknown fields: "
            + ", ".join(sorted(unknown_requirements))
        )
    collection_protocol = evidence_requirements.get("collection_protocol")
    if collection_protocol is not None:
        _require_exact_keys(
            collection_protocol,
            {"id", "sha256"},
            "voice gate evidence_requirements.collection_protocol",
        )
        _require_safe_id(
            collection_protocol["id"],
            "evidence_requirements.collection_protocol.id",
        )
        _require_sha256(
            collection_protocol["sha256"],
            "evidence_requirements.collection_protocol.sha256",
        )
    scalar_minimums = EVIDENCE_REQUIREMENT_KEYS - {
        "collection_protocol",
        "minimum_late_challenges_per_scenario",
    }
    for key in scalar_minimums & set(evidence_requirements):
        value = evidence_requirements[key]
        if type(value) is not int or value <= 0:
            raise VoiceEvaluationError(
                f"voice gate evidence requirement {key} must be a positive integer"
            )
    challenge_minimums = evidence_requirements.get(
        "minimum_late_challenges_per_scenario"
    )
    if challenge_minimums is not None:
        if not isinstance(challenge_minimums, Mapping):
            raise VoiceEvaluationError(
                "voice gate minimum_late_challenges_per_scenario must be an object"
            )
        unknown_scenarios = set(challenge_minimums) - LATE_CHALLENGE_SCENARIOS
        if unknown_scenarios:
            raise VoiceEvaluationError(
                "voice gate late challenge requirements contain unknown scenarios: "
                + ", ".join(sorted(unknown_scenarios))
            )
        for scenario, value in challenge_minimums.items():
            if type(value) is not int or value <= 0:
                raise VoiceEvaluationError(
                    "voice gate late challenge requirement must be a positive integer"
                )


def _evaluate_gates(
    *,
    corpus: VoiceCorpus,
    run: Mapping[str, Any],
    metrics: Mapping[str, Any],
    subsets: Mapping[str, Mapping[str, Any]],
    comparison: Optional[Mapping[str, Any]],
    performance_metrics: Optional[Mapping[str, Any]],
    gates: Mapping[str, Any],
    configuration_complete: bool,
) -> Dict[str, Dict[str, Any]]:
    thresholds = gates["thresholds"]
    checks: Dict[str, Dict[str, Any]] = {}
    checks["gate_policy_complete"] = {
        "actual": "complete" if configuration_complete else "incomplete",
        "threshold": (
            "all mandatory thresholds, subsets, evidence requirements, and "
            "an authenticated production driver"
        ),
        "passed": configuration_complete,
        "evidence_complete": configuration_complete,
    }
    authenticated_production_driver = (
        performance_metrics is not None
        and performance_metrics.get("authenticated_production_driver") is True
    )
    checks["authenticated_production_driver"] = {
        "actual": authenticated_production_driver,
        "threshold": True,
        "passed": authenticated_production_driver,
        "evidence_complete": authenticated_production_driver,
    }
    performance_complete = (
        performance_metrics is not None and authenticated_production_driver
    )
    checks["performance_evidence_complete"] = {
        "actual": (
            "authenticated"
            if performance_complete
            else "unauthenticated"
            if performance_metrics is not None
            else "missing"
        ),
        "threshold": (
            "valid authenticated production-driver performance evidence "
            "bound to this run"
        ),
        "passed": performance_complete,
        "evidence_complete": performance_complete,
    }
    evidence_requirements = gates.get("evidence_requirements", {})

    expected_protocol = evidence_requirements.get("collection_protocol")
    actual_protocol = (
        performance_metrics.get("collection_protocol")
        if isinstance(performance_metrics, Mapping)
        else None
    )
    protocol_complete = (
        isinstance(expected_protocol, Mapping)
        and isinstance(actual_protocol, Mapping)
        and dict(actual_protocol) == dict(expected_protocol)
    )
    checks["evidence:collection_protocol"] = {
        "actual": dict(actual_protocol)
        if isinstance(actual_protocol, Mapping)
        else None,
        "threshold": dict(expected_protocol)
        if isinstance(expected_protocol, Mapping)
        else None,
        "passed": protocol_complete,
        "evidence_complete": protocol_complete,
    }

    def evidence_minimum(name: str, actual: Optional[float], key: str) -> None:
        threshold = evidence_requirements.get(key)
        complete = actual is not None and threshold is not None and actual >= threshold
        checks[f"evidence:{name}"] = {
            "actual": actual,
            "threshold": threshold,
            "passed": complete,
            "evidence_complete": complete,
        }

    evidence_minimum(
        "cold_artifact_load_trials",
        _nested_number(performance_metrics or {}, "cold_artifact_load_ms", "samples"),
        "minimum_cold_artifact_load_trials",
    )
    performance_for_evidence = performance_metrics or {}
    keyboard_for_evidence = performance_for_evidence.get("keyboard", {})
    evidence_minimum(
        "paired_keyboard_sequences",
        _number_or_none(keyboard_for_evidence.get("paired_sequence_count"))
        if isinstance(keyboard_for_evidence, Mapping)
        else None,
        "minimum_paired_keyboard_sequences",
    )
    evidence_minimum(
        "first_partial_samples",
        _number_or_none(metrics["latency_ms"]["first_partial"]["samples"]),
        "minimum_first_partial_samples",
    )
    evidence_minimum(
        "stop_to_final_samples",
        _number_or_none(metrics["latency_ms"]["stop_to_final"]["samples"]),
        "minimum_stop_to_final_samples",
    )
    evidence_minimum(
        "cancel_to_capture_stop_samples",
        _number_or_none(
            metrics["latency_ms"]["cancel_to_capture_stop"]["samples"]
        ),
        "minimum_cancel_to_capture_stop_samples",
    )
    evidence_minimum(
        "partial_churn_transitions",
        _number_or_none(metrics["partial_churn"]["transitions"]),
        "minimum_partial_churn_transitions",
    )
    challenge_requirements = evidence_requirements.get(
        "minimum_late_challenges_per_scenario", {}
    )
    challenge_counts = (
        keyboard_for_evidence.get("late_challenge_counts", {})
        if isinstance(keyboard_for_evidence, Mapping)
        else {}
    )
    for scenario in sorted(LATE_CHALLENGE_SCENARIOS):
        threshold = (
            challenge_requirements.get(scenario)
            if isinstance(challenge_requirements, Mapping)
            else None
        )
        actual = (
            _number_or_none(challenge_counts.get(scenario))
            if isinstance(challenge_counts, Mapping)
            else None
        )
        complete = actual is not None and threshold is not None and actual >= threshold
        checks[f"evidence:late_challenge:{scenario}"] = {
            "actual": actual,
            "threshold": threshold,
            "passed": complete,
            "evidence_complete": complete,
        }

    def maximum(name: str, actual: Optional[float], threshold_key: str) -> None:
        threshold = thresholds.get(threshold_key)
        complete = actual is not None and threshold is not None
        checks[name] = {
            "actual": actual,
            "threshold": threshold,
            "passed": complete and actual <= threshold,
            "evidence_complete": complete,
        }

    def minimum(name: str, actual: Optional[float], threshold_key: str) -> None:
        threshold = thresholds.get(threshold_key)
        complete = actual is not None and threshold is not None
        checks[name] = {
            "actual": actual,
            "threshold": threshold,
            "passed": complete and actual >= threshold,
            "evidence_complete": complete,
        }

    maximum(
        "mandarin_cer", metrics["mandarin_cer"]["rate"], "mandarin_cer_max"
    )
    maximum(
        "english_wer", metrics["english_wer"]["rate"], "english_wer_max"
    )
    minimum(
        "term_exact_match_rate",
        metrics["term_exact_match"]["rate"],
        "term_exact_match_rate_min",
    )
    maximum(
        "punctuation_edit_rate",
        metrics["punctuation_edit_rate"]["rate"],
        "punctuation_edit_rate_max",
    )
    maximum(
        "blank_false_positive_rate",
        metrics["blank_false_positive"]["rate"],
        "blank_false_positive_rate_max",
    )
    maximum(
        "collateral_substitution_rate",
        metrics["collateral_substitution"]["rate"],
        "collateral_substitution_rate_max",
    )
    maximum(
        "partial_churn_rate",
        metrics["partial_churn"]["rate"],
        "partial_churn_rate_max",
    )
    maximum(
        "first_partial_p95_ms",
        metrics["latency_ms"]["first_partial"]["p95"],
        "first_partial_p95_ms_max",
    )
    maximum(
        "stop_to_final_p95_ms",
        metrics["latency_ms"]["stop_to_final"]["p95"],
        "stop_to_final_p95_ms_max",
    )
    maximum(
        "cancel_to_capture_stop_p95_ms",
        metrics["latency_ms"]["cancel_to_capture_stop"]["p95"],
        "cancel_to_capture_stop_p95_ms_max",
    )

    performance = performance_metrics or {}
    keyboard = performance.get("keyboard", {})
    maximum(
        "real_time_factor_p95",
        _nested_number(performance, "real_time_factor", "p95"),
        "real_time_factor_p95_max",
    )
    maximum(
        "cohort_peak_resident_mib",
        _nested_number(performance, "cohort_peak_resident_mib", "max"),
        "cohort_peak_resident_mib_max",
    )
    maximum(
        "cohort_peak_phys_footprint_mib",
        _nested_number(performance, "cohort_peak_phys_footprint_mib", "max"),
        "cohort_peak_phys_footprint_mib_max",
    )
    maximum(
        "voice_incremental_peak_phys_footprint_mib",
        _nested_number(
            performance, "voice_incremental_peak_phys_footprint_mib", "max"
        ),
        "voice_incremental_peak_phys_footprint_mib_max",
    )
    maximum(
        "cpu_core_seconds_per_audio_second_p95",
        _nested_number(
            performance, "cpu_core_seconds_per_audio_second", "p95"
        ),
        "cpu_core_seconds_per_audio_second_p95_max",
    )
    maximum(
        "energy_joules_per_audio_minute_p95",
        _nested_number(performance, "energy_joules_per_audio_minute", "p95"),
        "energy_joules_per_audio_minute_p95_max",
    )
    product_payload = _nested_number(
        performance, "product_artifact_payload_bytes", "value"
    )
    if run["engine"]["asset_management"] == "system":
        checks["product_artifact_payload_bytes"] = {
            "actual": "not_applicable",
            "threshold": thresholds.get("product_artifact_payload_bytes_max"),
            "passed": thresholds.get("product_artifact_payload_bytes_max") is not None,
            "evidence_complete": thresholds.get(
                "product_artifact_payload_bytes_max"
            )
            is not None,
        }
    else:
        maximum(
            "product_artifact_payload_bytes",
            product_payload,
            "product_artifact_payload_bytes_max",
        )
    maximum(
        "cold_artifact_load_p95_ms",
        _nested_number(performance, "cold_artifact_load_ms", "p95"),
        "cold_artifact_load_p95_ms_max",
    )
    maximum(
        "keyboard_baseline_rime_p95_ms",
        _nested_number(keyboard, "baseline_rime_latency_ms", "p95"),
        "keyboard_baseline_rime_p95_ms_max",
    )
    maximum(
        "keyboard_helper_loaded_rime_p95_ms",
        _nested_number(keyboard, "helper_loaded_rime_latency_ms", "p95"),
        "keyboard_helper_loaded_rime_p95_ms_max",
    )
    maximum(
        "keyboard_helper_loaded_added_p95_ms",
        _number_or_none(keyboard.get("helper_loaded_added_p95_ms")),
        "keyboard_helper_loaded_added_p95_ms_max",
    )
    maximum(
        "keyboard_listening_cancel_to_rime_p95_ms",
        _nested_number(
            keyboard, "listening_cancel_to_rime_latency_ms", "p95"
        ),
        "keyboard_listening_cancel_to_rime_p95_ms_max",
    )
    maximum(
        "keyboard_listening_cancel_added_p95_ms",
        _number_or_none(keyboard.get("listening_cancel_added_p95_ms")),
        "keyboard_listening_cancel_added_p95_ms_max",
    )
    late_commits = _number_or_none(keyboard.get("late_voice_commit_count"))
    late_commits_complete = late_commits is not None
    checks["keyboard_late_voice_commit_zero"] = {
        "actual": late_commits,
        "threshold": 0,
        "passed": late_commits_complete and late_commits == 0,
        "evidence_complete": late_commits_complete,
    }
    environment = performance.get("environment")
    stable_environment = (
        isinstance(environment, Mapping)
        and environment.get("power_source") == "ac"
        and environment.get("low_power_mode") is False
        and environment.get("thermal_state_start") == "nominal"
        and environment.get("thermal_state_end") == "nominal"
    )
    checks["performance_environment_eligible"] = {
        "actual": dict(environment) if isinstance(environment, Mapping) else "missing",
        "threshold": "AC power, low power mode off, nominal thermal state",
        "passed": stable_environment,
        "evidence_complete": isinstance(environment, Mapping),
    }

    if run["policy"]["hotwords_enabled"]:
        gain = comparison.get("technical_term_exact_gain_pp") if comparison else None
        regression = (
            comparison.get("mandarin_cer_regression_pp") if comparison else None
        )
        minimum(
            "technical_term_exact_gain_pp",
            gain,
            "technical_term_exact_gain_pp_min",
        )
        maximum(
            "mandarin_cer_regression_pp",
            regression,
            "mandarin_cer_regression_pp_max",
        )
        baseline_is_unheated = comparison is not None and comparison.get(
            "baseline_hotwords_enabled"
        ) is False
        checks["unheated_comparable_baseline"] = {
            "actual": "present" if comparison else "missing",
            "threshold": "strictly comparable baseline with hotwords disabled",
            "passed": baseline_is_unheated,
            "evidence_complete": baseline_is_unheated,
        }
    corpus_fixture = corpus.synthetic_fixture
    corpus_purpose = corpus.purpose
    declarations = corpus.manifest.quality_declarations
    release_corpus = (
        not corpus_fixture
        and corpus_purpose == "frozen_quality"
        and len(corpus.samples) >= 200
        and corpus.manifest.rights is not None
        and declarations.authorized_real_recordings
        and declarations.speaker_disjoint_by_identity
        and run["audio_io"]["device_class"] != "virtual_fixture"
    )
    checks["frozen_non_fixture_evidence"] = {
        "actual": {
            "purpose": corpus_purpose,
            "samples": len(corpus.samples),
            "rights_declared": corpus.manifest.rights is not None,
            "authorized_recordings_declared": declarations.authorized_real_recordings,
            "split_isolation_declared": declarations.speaker_disjoint_by_identity,
        },
        "threshold": "authorized speaker-disjoint frozen_quality corpus with >=200 real samples",
        "passed": release_corpus,
        "evidence_complete": True,
    }
    os_major = _macos_major(run["platform"])
    system_ineligible = (
        run["engine"]["asset_management"] == "system"
        and (os_major is None or os_major < 26)
    )
    checks["engine_policy_eligible"] = {
        "actual": (
            f"system/macos-{os_major}"
            if run["engine"]["asset_management"] == "system"
            else run["engine"]["asset_management"]
        ),
        "threshold": "product-managed on macOS 14/15; system-managed only on macOS 26+",
        "passed": not system_ineligible,
        "evidence_complete": True,
    }
    on_device_eligible = (
        run["engine"]["requires_on_device"]
        and run["engine"]["supports_on_device_at_run"]
    )
    checks["on_device_runtime_eligible"] = {
        "actual": "on_device" if on_device_eligible else "not_on_device",
        "threshold": "requires and supports on-device recognition at collection time",
        "passed": on_device_eligible,
        "evidence_complete": True,
    }
    required = gates["required_subsets"]
    unsupported = {
        "%s:%s" % (item["dimension"], item["value"])
        for item in run["unsupported_subsets"]
    }
    for subset_value in required:
        subset = "%s:%s" % (subset_value["dimension"], subset_value["value"])
        present = subset in subsets and subsets[subset]["samples"] > 0
        checks[f"required_subset:{subset}"] = {
            "actual": "unsupported" if subset in unsupported else ("present" if present else "missing"),
            "threshold": "present and supported",
            "passed": present and subset not in unsupported,
            "evidence_complete": present and subset not in unsupported,
        }
        evidence_minimum(
            f"required_subset_samples:{subset}",
            _number_or_none(subsets[subset]["samples"])
            if subset in subsets and subset not in unsupported
            else None,
            "minimum_required_subset_samples",
        )
    return checks


def _number_or_none(value: Any) -> Optional[float]:
    if not _is_finite_number(value):
        return None
    return float(value)


def _is_finite_number(value: Any) -> bool:
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        return False
    try:
        return math.isfinite(value)
    except OverflowError:
        return False


def _nested_number(value: Mapping[str, Any], key: str, field: str) -> Optional[float]:
    nested = value.get(key)
    if not isinstance(nested, Mapping):
        return None
    return _number_or_none(nested.get(field))


def _macos_major(platform: Mapping[str, Any]) -> Optional[int]:
    version = platform.get("os_version")
    if not isinstance(version, (str, int, float)):
        return None
    match = re.match(r"^(\d+)", str(version))
    return int(match.group(1)) if match else None


def _compare_runs(
    candidate_run: Mapping[str, Any],
    baseline_run: Mapping[str, Any],
    candidate_metrics: Mapping[str, Any],
    baseline_metrics: Mapping[str, Any],
    candidate_subsets: Mapping[str, Mapping[str, Any]],
    baseline_subsets: Mapping[str, Mapping[str, Any]],
) -> Dict[str, Any]:
    # Implementation identity and hotword policy are intentionally allowed to
    # differ.  Everything that determines the corpus and collection conditions
    # must be byte-for-byte comparable.
    for key in (
        "evaluation_profile_id",
        "corpus_fingerprint",
        "collection_method",
        "engine",
        "platform",
        "audio_io",
        "unsupported_subsets",
        "clock",
    ):
        if candidate_run[key] != baseline_run[key]:
            raise VoiceEvaluationError(f"A/B runs are not comparable: {key} differs")
    candidate_policy = dict(candidate_run["policy"])
    baseline_policy = dict(baseline_run["policy"])
    for key in set(candidate_policy) | set(baseline_policy):
        if key in {"hotwords_enabled", "hotword_set_sha256"}:
            continue
        if candidate_policy.get(key) != baseline_policy.get(key):
            raise VoiceEvaluationError(
                f"A/B runs are not comparable: policy.{key} differs"
            )
    if set(candidate_subsets) != set(baseline_subsets):
        raise VoiceEvaluationError("A/B runs are not comparable: subsets differ")
    candidate_term = candidate_metrics["term_exact_match"]["rate"]
    baseline_term = baseline_metrics["term_exact_match"]["rate"]
    candidate_cer = candidate_metrics["mandarin_cer"]["rate"]
    baseline_cer = baseline_metrics["mandarin_cer"]["rate"]
    return {
        "baseline_implementation_fingerprint": baseline_run[
            "implementation_fingerprint"
        ],
        "candidate_implementation_fingerprint": candidate_run[
            "implementation_fingerprint"
        ],
        "baseline_hotwords_enabled": baseline_run["policy"]["hotwords_enabled"],
        "candidate_hotwords_enabled": candidate_run["policy"]["hotwords_enabled"],
        "technical_term_exact_gain_pp": _difference_pp(
            candidate_term, baseline_term
        ),
        "mandarin_cer_regression_pp": _difference_pp(
            candidate_cer, baseline_cer
        ),
    }


def _compare_safe_reports(
    baseline: Mapping[str, Any], candidate: Mapping[str, Any]
) -> Dict[str, Any]:
    baseline_provenance = baseline["provenance"]
    candidate_provenance = candidate["provenance"]
    for key in (
        "evaluation_profile_id",
        "corpus_fingerprint",
        "collection_method",
        "engine",
        "platform",
        "audio_io",
        "unsupported_subsets",
        "clock",
    ):
        if baseline_provenance.get(key) != candidate_provenance.get(key):
            raise VoiceEvaluationError(f"A/B reports are not comparable: {key} differs")
    baseline_policy = dict(baseline_provenance.get("policy", {}))
    candidate_policy = dict(candidate_provenance.get("policy", {}))
    for key in set(candidate_policy) | set(baseline_policy):
        if key in {"hotwords_enabled", "hotword_set_sha256"}:
            continue
        if candidate_policy.get(key) != baseline_policy.get(key):
            raise VoiceEvaluationError(
                f"A/B reports are not comparable: policy.{key} differs"
            )
    return {
        "baseline_implementation_fingerprint": baseline_provenance.get(
            "implementation_fingerprint"
        ),
        "candidate_implementation_fingerprint": candidate_provenance.get(
            "implementation_fingerprint"
        ),
        "baseline_hotwords_enabled": baseline_policy.get("hotwords_enabled"),
        "candidate_hotwords_enabled": candidate_policy.get("hotwords_enabled"),
        "technical_term_exact_gain_pp": _difference_pp(
            candidate["metrics"]["term_exact_match"]["rate"],
            baseline["metrics"]["term_exact_match"]["rate"],
        ),
        "mandarin_cer_regression_pp": _difference_pp(
            candidate["metrics"]["mandarin_cer"]["rate"],
            baseline["metrics"]["mandarin_cer"]["rate"],
        ),
    }


def _difference_pp(candidate: Optional[float], baseline: Optional[float]) -> Optional[float]:
    if candidate is None or baseline is None:
        return None
    return round((candidate - baseline) * 100, 6)


def _assert_private_aggregate(report: Mapping[str, Any]) -> None:
    def visit(value: Any, path: str) -> None:
        if isinstance(value, Mapping):
            for key, item in value.items():
                lowered = str(key).casefold()
                # Aggregate metric names such as first_partial contain no event
                # payload.  The exact raw-data keys remain forbidden.
                if lowered in {"sample_id", "speaker", "speaker_id", "path", "text", "final_text", "partials"}:
                    raise VoiceEvaluationError(
                        f"aggregate privacy invariant violated at {path}.{key}"
                    )
                visit(item, f"{path}.{key}")
        elif isinstance(value, list):
            for index, item in enumerate(value):
                visit(item, f"{path}[{index}]")

    visit(report, "report")
