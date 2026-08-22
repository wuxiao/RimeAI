"""Strict, text-free performance evidence for a frozen voice run."""

from __future__ import annotations

import hashlib
import json
import math
from pathlib import Path
import re
from typing import Any, Dict, Mapping, Sequence

from .voice_dataset import VoiceCorpus


class VoicePerformanceError(ValueError):
    """Performance evidence cannot support a reproducible decision."""


_SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
_TEAM_ID_RE = re.compile(r"^[A-Z0-9]{10}$")
_ENGINE_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._@-]{0,127}$")
_HARDWARE_MODEL_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._,-]{0,127}$")
_PERFORMANCE_SHA256_DOMAIN = b"rimeai.voice-performance.v3\x00"
_UINT64_MAX = (1 << 64) - 1
_MAXIMUM_PERFORMANCE_BYTES = 16 * 1_024 * 1_024
_TOP_LEVEL_KEYS = {
    "schema_version",
    "evaluation_profile_id",
    "corpus_fingerprint",
    "implementation_fingerprint",
    "run_sha256",
    "collection_protocol",
    "artifact",
    "collector",
    "environment",
    "required_process_roles",
    "cold_artifact_load_ms",
    "sessions",
    "keyboard_trials",
    "late_voice_commit_count",
    "late_challenge_counts",
}
_COLLECTION_PROTOCOL_KEYS = {"id", "sha256"}
_SESSION_KEYS = {
    "sample_id",
    "audio_duration_ms",
    "processing_duration_ms",
    "processes",
}
_COLLECTOR_KEYS = {
    "collector_id",
    "clock_domain",
    "sample_interval_ms",
    "memory_source",
    "energy_source",
    "executable_sha256",
    "team_identifier",
    "signing_identifier",
}
_PROCESS_KEYS = {
    "role",
    "instance_id",
    "start_user_cpu_ns",
    "end_user_cpu_ns",
    "start_system_cpu_ns",
    "end_system_cpu_ns",
    "start_energy_nj",
    "end_energy_nj",
    "baseline_resident_bytes",
    "peak_resident_bytes",
    "baseline_phys_footprint_bytes",
    "peak_phys_footprint_bytes",
    "sample_count",
    "maximum_sample_gap_ms",
}
_REQUIRED_PROCESS_ROLES = (
    "input_method",
    "candidate_service",
    "voice_helper",
)
_ENVIRONMENT_KEYS = {
    "hardware_model",
    "physical_memory_bytes",
    "logical_cpu_count",
    "power_source",
    "low_power_mode",
    "thermal_state_start",
    "thermal_state_end",
}
_KEYBOARD_TRIAL_KEYS = {
    "sequence",
    "phase",
    "rime_candidate_latency_ms",
}
_KEYBOARD_PHASES = (
    "baseline",
    "helper_loaded_idle",
    "listening_cancel_to_rime",
)
_LATE_CHALLENGE_SCENARIOS = (
    "cancel",
    "application_switch",
    "secure_input",
    "target_invalidation",
    "keyboard_input",
)
_PRODUCT_ARTIFACT_KEYS = {
    "artifact_id",
    "artifact_content_sha256",
    "adapter_id",
    "engine_id",
    "model_id",
    "model_revision",
    "verified_payload_bytes",
    "verified_file_count",
}


class _InvalidJSON(ValueError):
    pass


def voice_run_sha256(run: Mapping[str, Any]) -> str:
    """Return the canonical content identity used by performance evidence."""

    try:
        encoded = json.dumps(
            run,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
            allow_nan=False,
        ).encode("utf-8")
    except (TypeError, ValueError) as error:
        raise VoicePerformanceError("voice run cannot be canonically hashed") from error
    return hashlib.sha256(encoded).hexdigest()


def voice_performance_sha256(value: Mapping[str, Any]) -> str:
    """Return the domain-separated identity of complete sidecar semantics."""

    if not isinstance(value, Mapping):
        raise VoicePerformanceError("voice performance must be an object")
    try:
        encoded = json.dumps(
            value,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
            allow_nan=False,
        ).encode("utf-8")
    except (TypeError, ValueError) as error:
        raise VoicePerformanceError(
            "voice performance cannot be canonically hashed"
        ) from error
    return hashlib.sha256(_PERFORMANCE_SHA256_DOMAIN + encoded).hexdigest()


def load_voice_performance(
    path: Path,
    corpus: VoiceCorpus,
    run: Mapping[str, Any],
) -> Dict[str, Any]:
    """Load and bind one exact performance sidecar to ``run`` and ``corpus``."""

    try:
        with path.open("rb") as source:
            encoded = source.read(_MAXIMUM_PERFORMANCE_BYTES + 1)
    except OSError as error:
        raise VoicePerformanceError(f"{path}: cannot read voice performance") from error
    if len(encoded) > _MAXIMUM_PERFORMANCE_BYTES:
        raise VoicePerformanceError(f"{path}: voice performance is too large")
    try:
        value = json.loads(
            encoded.decode("utf-8"),
            object_pairs_hook=_strict_json_object,
            parse_constant=_reject_json_constant,
        )
    except (UnicodeDecodeError, RecursionError, ValueError) as error:
        raise VoicePerformanceError(f"{path}: invalid JSON") from error
    return validate_voice_performance(value, corpus, run)


def validate_voice_performance(
    value: Mapping[str, Any],
    corpus: VoiceCorpus,
    run: Mapping[str, Any],
) -> Dict[str, Any]:
    """Validate already-decoded evidence and return a shallow owned copy."""

    if not isinstance(value, dict):
        raise VoicePerformanceError("voice performance must be an object")
    _require_exact_keys(value, _TOP_LEVEL_KEYS, "voice performance")
    if type(value["schema_version"]) is not int or value["schema_version"] != 3:
        raise VoicePerformanceError("voice performance schema_version must be 3")
    bindings = (
        ("evaluation_profile_id", run.get("evaluation_profile_id")),
        ("corpus_fingerprint", corpus.fingerprint),
        ("implementation_fingerprint", run.get("implementation_fingerprint")),
        ("run_sha256", voice_run_sha256(run)),
    )
    for field, expected in bindings:
        if value[field] != expected:
            raise VoicePerformanceError(
                f"voice performance {field} does not match voice run"
            )
    _require_safe_id(value["evaluation_profile_id"], "evaluation_profile_id")
    for field in (
        "corpus_fingerprint",
        "implementation_fingerprint",
        "run_sha256",
    ):
        _require_sha256(value[field], field)
    collection_protocol = value["collection_protocol"]
    _require_exact_keys(
        collection_protocol,
        _COLLECTION_PROTOCOL_KEYS,
        "voice performance collection_protocol",
    )
    _require_safe_id(
        collection_protocol["id"], "collection_protocol.id"
    )
    _require_sha256(
        collection_protocol["sha256"], "collection_protocol.sha256"
    )
    artifact = value["artifact"]
    engine = run.get("engine")
    if not isinstance(engine, Mapping):
        raise VoicePerformanceError("voice run engine is invalid")
    if engine.get("asset_management") == "product":
        _require_exact_keys(
            artifact,
            _PRODUCT_ARTIFACT_KEYS,
            "voice performance artifact",
        )
        for field in (
            "artifact_id",
            "artifact_content_sha256",
            "adapter_id",
            "engine_id",
            "model_id",
            "model_revision",
        ):
            if artifact[field] != engine.get(field):
                raise VoicePerformanceError(
                    f"voice performance artifact {field} does not match voice run"
                )
        for field in (
            "artifact_id",
            "adapter_id",
            "model_id",
            "model_revision",
        ):
            _require_safe_id(artifact[field], f"artifact.{field}")
        _require_engine_id(artifact["engine_id"], "artifact.engine_id")
        _require_sha256(
            artifact["artifact_content_sha256"],
            "artifact.artifact_content_sha256",
        )
        _require_positive_uint64(
            artifact["verified_payload_bytes"],
            "artifact.verified_payload_bytes",
        )
        _require_positive_uint64(
            artifact["verified_file_count"],
            "artifact.verified_file_count",
        )
    elif artifact is not None:
        raise VoicePerformanceError(
            "system-managed voice performance must not claim product artifact"
        )
    collector = value["collector"]
    _require_exact_keys(collector, _COLLECTOR_KEYS, "voice performance collector")
    expected_collector_values = {
        "collector_id": "rimeai-voice-performance-v1",
        "clock_domain": "mach_continuous_time",
        "memory_source": "proc_pid_rusage_v6",
        "energy_source": "proc_pid_rusage_v6_energy_nj",
        "signing_identifier": "fun.wwcn.rimeai.voice-performance-collector",
    }
    for field, expected in expected_collector_values.items():
        if collector[field] != expected:
            raise VoicePerformanceError(f"collector.{field} is invalid")
    sample_interval = _require_positive_integer(
        collector["sample_interval_ms"], "collector.sample_interval_ms"
    )
    if sample_interval > 100:
        raise VoicePerformanceError("collector.sample_interval_ms exceeds 100")
    if (
        not isinstance(collector["executable_sha256"], str)
        or _SHA256_RE.fullmatch(collector["executable_sha256"]) is None
    ):
        raise VoicePerformanceError("collector.executable_sha256 is invalid")
    if (
        not isinstance(collector["team_identifier"], str)
        or _TEAM_ID_RE.fullmatch(collector["team_identifier"]) is None
    ):
        raise VoicePerformanceError("collector.team_identifier is invalid")
    required_roles = value["required_process_roles"]
    if required_roles != list(_REQUIRED_PROCESS_ROLES):
        raise VoicePerformanceError(
            "voice performance required process roles are incomplete"
        )
    environment = value["environment"]
    _require_exact_keys(environment, _ENVIRONMENT_KEYS, "voice performance environment")
    _require_hardware_model(
        environment["hardware_model"], "environment.hardware_model"
    )
    platform = run.get("platform")
    if (
        not isinstance(platform, Mapping)
        or environment["hardware_model"] != platform.get("hardware_class")
    ):
        raise VoicePerformanceError(
            "voice performance environment hardware_model does not match voice run"
        )
    _require_positive_uint64(
        environment["physical_memory_bytes"], "environment.physical_memory_bytes"
    )
    _require_positive_uint64(
        environment["logical_cpu_count"], "environment.logical_cpu_count"
    )
    if environment["power_source"] not in {"ac", "battery"}:
        raise VoicePerformanceError("environment.power_source is invalid")
    if not isinstance(environment["low_power_mode"], bool):
        raise VoicePerformanceError("environment.low_power_mode must be boolean")
    if environment["low_power_mode"]:
        raise VoicePerformanceError(
            "voice performance low power mode must be disabled"
        )
    thermal_states = {"nominal", "fair", "serious", "critical"}
    for field in ("thermal_state_start", "thermal_state_end"):
        if environment[field] not in thermal_states:
            raise VoicePerformanceError(f"environment.{field} is invalid")
    if environment["thermal_state_start"] != environment["thermal_state_end"]:
        raise VoicePerformanceError(
            "voice performance thermal state changed during collection"
        )
    cold_artifact_load_ms = value["cold_artifact_load_ms"]
    if not isinstance(cold_artifact_load_ms, list) or not cold_artifact_load_ms:
        raise VoicePerformanceError(
            "voice performance cold_artifact_load_ms must be a non-empty array"
        )
    for index, duration in enumerate(cold_artifact_load_ms):
        _require_positive_uint64_number(
            duration, f"voice performance cold_artifact_load_ms[{index}]"
        )
    sessions = value["sessions"]
    if not isinstance(sessions, list):
        raise VoicePerformanceError("voice performance sessions must be an array")
    samples_by_id = {}
    for sample in corpus.samples:
        _require_safe_id(sample.id, "corpus sample_id")
        if sample.id in samples_by_id:
            raise VoicePerformanceError(
                "voice performance contains duplicate corpus sample identifiers"
            )
        samples_by_id[sample.id] = sample
    if len(samples_by_id) != len(corpus.samples):
        raise VoicePerformanceError(
            "voice performance contains duplicate corpus sample identifiers"
        )
    for sample_id, sample in samples_by_id.items():
        duration = sample.audio.duration_ms
        if (
            not _is_finite_number(duration)
            or duration <= 0
        ):
            raise VoicePerformanceError(
                f"voice performance corpus audio duration is invalid for {sample_id}"
            )
    expected_sample_ids = set(samples_by_id)
    seen_sample_ids = set()
    total_energy_delta_nj = 0
    for index, session in enumerate(sessions):
        context = f"voice performance sessions[{index}]"
        _require_exact_keys(session, _SESSION_KEYS, context)
        sample_id = session["sample_id"]
        _require_safe_id(sample_id, f"{context}.sample_id")
        if sample_id in seen_sample_ids:
            raise VoicePerformanceError(
                f"voice performance sessions contain duplicate sample_id '{sample_id}'"
            )
        if sample_id not in expected_sample_ids:
            raise VoicePerformanceError(
                f"{context}.sample_id is not in corpus"
            )
        seen_sample_ids.add(sample_id)
        audio_duration = _require_nonnegative_number(
            session["audio_duration_ms"], f"{context}.audio_duration_ms"
        )
        if audio_duration != float(samples_by_id[sample_id].audio.duration_ms):
            raise VoicePerformanceError(
                f"{context}.audio_duration_ms does not match corpus"
            )
        processing_duration = _require_uint64_number(
            session["processing_duration_ms"],
            f"{context}.processing_duration_ms",
        )
        if audio_duration > 0 and processing_duration <= 0:
            raise VoicePerformanceError(
                f"{context}.processing_duration_ms must be positive for non-zero audio"
            )
        processes = session["processes"]
        if not isinstance(processes, list):
            raise VoicePerformanceError(f"{context}.processes must be an array")
        process_roles = []
        process_instances = set()
        for process_index, process in enumerate(processes):
            process_context = f"{context}.processes[{process_index}]"
            _require_exact_keys(process, _PROCESS_KEYS, process_context)
            role = process["role"]
            if role not in _REQUIRED_PROCESS_ROLES or role in process_roles:
                raise VoicePerformanceError(
                    f"{context} process roles are invalid or duplicated"
                )
            process_roles.append(role)
            instance_id = process["instance_id"]
            _require_safe_id(instance_id, f"{process_context}.instance_id")
            if instance_id in process_instances:
                raise VoicePerformanceError(
                    f"{context} process instances are duplicated"
                )
            process_instances.add(instance_id)
            for start_field, end_field in (
                ("start_user_cpu_ns", "end_user_cpu_ns"),
                ("start_system_cpu_ns", "end_system_cpu_ns"),
                ("start_energy_nj", "end_energy_nj"),
            ):
                start = _require_uint64(
                    process[start_field],
                    f"{process_context}.{start_field}",
                )
                end = _require_uint64(
                    process[end_field],
                    f"{process_context}.{end_field}",
                )
                if end < start:
                    raise VoicePerformanceError(
                        f"{process_context} counter regressed"
                    )
                if start_field == "start_energy_nj":
                    total_energy_delta_nj += end - start
            if role == "voice_helper":
                voice_helper_cpu_delta = (
                    process["end_user_cpu_ns"]
                    - process["start_user_cpu_ns"]
                    + process["end_system_cpu_ns"]
                    - process["start_system_cpu_ns"]
                )
                if voice_helper_cpu_delta <= 0:
                    raise VoicePerformanceError(
                        f"{process_context} voice_helper CPU delta must be positive"
                    )
            for kind in ("resident", "phys_footprint"):
                baseline = _require_positive_uint64(
                    process[f"baseline_{kind}_bytes"],
                    f"{process_context}.baseline_{kind}_bytes",
                )
                peak = _require_uint64(
                    process[f"peak_{kind}_bytes"],
                    f"{process_context}.peak_{kind}_bytes",
                )
                if peak < baseline:
                    raise VoicePerformanceError(
                        f"{process_context} peak memory is below baseline"
                    )
            sample_count = _require_positive_uint64(
                process["sample_count"], f"{process_context}.sample_count"
            )
            minimum_samples = max(
                2,
                math.ceil(processing_duration / (sample_interval * 2)) + 1,
            )
            if sample_count < minimum_samples:
                raise VoicePerformanceError(
                    f"{process_context} sampling cadence does not cover the session"
                )
            maximum_gap = _require_uint64_number(
                process["maximum_sample_gap_ms"],
                f"{process_context}.maximum_sample_gap_ms",
            )
            if maximum_gap > sample_interval * 2:
                raise VoicePerformanceError(
                    f"{process_context} sampling cadence is incomplete"
                )
        if set(process_roles) != set(_REQUIRED_PROCESS_ROLES):
            raise VoicePerformanceError(
                f"{context} process roles do not match required process roles"
            )
    missing_sessions = expected_sample_ids - seen_sample_ids
    if missing_sessions:
        raise VoicePerformanceError(
            "voice performance sessions are incomplete: "
            + ", ".join(sorted(missing_sessions))
        )
    if total_energy_delta_nj <= 0:
        raise VoicePerformanceError(
            "voice performance total energy delta must be positive"
        )
    keyboard_trials = value["keyboard_trials"]
    if not isinstance(keyboard_trials, list) or not keyboard_trials:
        raise VoicePerformanceError(
            "voice performance keyboard trials must be a non-empty array"
        )
    trials_by_sequence: Dict[int, Dict[str, float]] = {}
    for index, trial in enumerate(keyboard_trials):
        context = f"voice performance keyboard_trials[{index}]"
        _require_exact_keys(trial, _KEYBOARD_TRIAL_KEYS, context)
        sequence = _require_positive_uint64(
            trial["sequence"], f"{context}.sequence"
        )
        phase = trial["phase"]
        if phase not in _KEYBOARD_PHASES:
            raise VoicePerformanceError(f"{context}.phase is invalid")
        phases = trials_by_sequence.setdefault(sequence, {})
        if phase in phases:
            raise VoicePerformanceError(
                f"voice performance keyboard phase is duplicated for sequence {sequence}"
            )
        phases[phase] = _require_positive_uint64_number(
            trial["rime_candidate_latency_ms"],
            f"{context}.rime_candidate_latency_ms",
        )
    for sequence, phases in trials_by_sequence.items():
        if set(phases) != set(_KEYBOARD_PHASES):
            raise VoicePerformanceError(
                f"voice performance keyboard phases are not paired for sequence {sequence}"
            )
    _require_uint64(
        value["late_voice_commit_count"], "late_voice_commit_count"
    )
    late_challenge_counts = value["late_challenge_counts"]
    _require_exact_keys(
        late_challenge_counts,
        set(_LATE_CHALLENGE_SCENARIOS),
        "voice performance late_challenge_counts",
    )
    for scenario in _LATE_CHALLENGE_SCENARIOS:
        _require_uint64(
            late_challenge_counts[scenario],
            f"late_challenge_counts.{scenario}",
        )
    return dict(value)


def aggregate_voice_performance(
    value: Mapping[str, Any],
    corpus: VoiceCorpus,
    run: Mapping[str, Any],
) -> Dict[str, Any]:
    """Aggregate strict process- and keyboard-scoped evidence without identifiers."""

    evidence = validate_voice_performance(value, corpus, run)
    real_time_factors = []
    peak_resident_mib = []
    peak_phys_footprint_mib = []
    incremental_phys_footprint_mib = []
    cpu_per_audio_second = []
    energy_per_audio_minute = []
    bytes_per_mib = 1_048_576
    for session in evidence["sessions"]:
        audio_seconds = float(session["audio_duration_ms"]) / 1_000
        real_time_factors.append(
            float(session["processing_duration_ms"])
            / float(session["audio_duration_ms"])
        )
        processes = session["processes"]
        peak_resident_mib.append(
            sum(process["peak_resident_bytes"] for process in processes)
            / bytes_per_mib
        )
        peak_phys_footprint_mib.append(
            sum(process["peak_phys_footprint_bytes"] for process in processes)
            / bytes_per_mib
        )
        incremental_phys_footprint_mib.append(
            sum(
                process["peak_phys_footprint_bytes"]
                - process["baseline_phys_footprint_bytes"]
                for process in processes
            )
            / bytes_per_mib
        )
        cpu_ns = sum(
            process["end_user_cpu_ns"]
            - process["start_user_cpu_ns"]
            + process["end_system_cpu_ns"]
            - process["start_system_cpu_ns"]
            for process in processes
        )
        energy_nj = sum(
            process["end_energy_nj"] - process["start_energy_nj"]
            for process in processes
        )
        cpu_per_audio_second.append((cpu_ns / 1_000_000_000) / audio_seconds)
        energy_per_audio_minute.append(
            (energy_nj / 1_000_000_000) / (audio_seconds / 60)
        )

    keyboard_by_sequence: Dict[int, Dict[str, float]] = {}
    for trial in evidence["keyboard_trials"]:
        keyboard_by_sequence.setdefault(trial["sequence"], {})[trial["phase"]] = float(
            trial["rime_candidate_latency_ms"]
        )
    phase_values = {
        phase: [
            phases[phase]
            for _, phases in sorted(keyboard_by_sequence.items())
        ]
        for phase in _KEYBOARD_PHASES
    }
    helper_added = [
        phases["helper_loaded_idle"] - phases["baseline"]
        for _, phases in sorted(keyboard_by_sequence.items())
    ]
    cancel_added = [
        phases["listening_cancel_to_rime"] - phases["baseline"]
        for _, phases in sorted(keyboard_by_sequence.items())
    ]
    artifact = evidence["artifact"]
    artifact_payload = (
        {"value": artifact["verified_payload_bytes"], "measurement": "measured"}
        if artifact is not None
        else {"value": None, "measurement": "not_applicable"}
    )
    return {
        # Schema v3 binds measurements to user-plan identities but carries no
        # approved producer/identity policy.  This fact is not caller input.
        "authenticated_production_driver": False,
        "collection_protocol": dict(evidence["collection_protocol"]),
        "session_coverage_rate": 1.0,
        "environment": {
            "hardware_model": evidence["environment"]["hardware_model"],
            "power_source": evidence["environment"]["power_source"],
            "low_power_mode": evidence["environment"]["low_power_mode"],
            "thermal_state_start": evidence["environment"]["thermal_state_start"],
            "thermal_state_end": evidence["environment"]["thermal_state_end"],
        },
        "real_time_factor": _distribution(real_time_factors),
        "cohort_peak_resident_mib": _distribution(peak_resident_mib),
        "cohort_peak_phys_footprint_mib": _distribution(peak_phys_footprint_mib),
        "voice_incremental_peak_phys_footprint_mib": _distribution(
            incremental_phys_footprint_mib
        ),
        "cpu_core_seconds_per_audio_second": _distribution(cpu_per_audio_second),
        "energy_joules_per_audio_minute": _distribution(energy_per_audio_minute),
        "cold_artifact_load_ms": _distribution(
            [float(duration) for duration in evidence["cold_artifact_load_ms"]]
        ),
        "product_artifact_payload_bytes": artifact_payload,
        "keyboard": {
            "paired_sequence_count": len(keyboard_by_sequence),
            "baseline_rime_latency_ms": _distribution(phase_values["baseline"]),
            "helper_loaded_rime_latency_ms": _distribution(
                phase_values["helper_loaded_idle"]
            ),
            "listening_cancel_to_rime_latency_ms": _distribution(
                phase_values["listening_cancel_to_rime"]
            ),
            "helper_loaded_added_p95_ms": _percentile(helper_added, 0.95),
            "listening_cancel_added_p95_ms": _percentile(cancel_added, 0.95),
            "late_voice_commit_count": evidence["late_voice_commit_count"],
            "late_challenge_counts": dict(evidence["late_challenge_counts"]),
        },
    }


def _distribution(values: Sequence[float]) -> Dict[str, Any]:
    return {
        "samples": len(values),
        "p50": _percentile(values, 0.50),
        "p95": _percentile(values, 0.95),
        "max": round(max(values), 6),
        "measurement": "measured",
    }


def _percentile(values: Sequence[float], percentile: float) -> float:
    ordered = sorted(values)
    rank = max(1, math.ceil(percentile * len(ordered)))
    return round(float(ordered[rank - 1]), 6)


def _strict_json_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise _InvalidJSON("duplicate key")
        result[key] = value
    return result


def _reject_json_constant(_value: str):
    raise _InvalidJSON("non-finite number")


def _require_exact_keys(value: Any, expected: set[str], context: str) -> None:
    if not isinstance(value, Mapping):
        raise VoicePerformanceError(f"{context} must be an object")
    actual = set(value)
    missing = expected - actual
    unexpected = actual - expected
    if missing:
        raise VoicePerformanceError(
            f"{context} is missing fields: " + ", ".join(sorted(missing))
        )
    if unexpected:
        raise VoicePerformanceError(f"{context} contains unknown fields")


def _require_sha256(value: Any, field: str) -> None:
    if not isinstance(value, str) or _SHA256_RE.fullmatch(value) is None:
        raise VoicePerformanceError(
            f"{field} must be 64 lowercase hexadecimal characters"
        )


def _require_safe_id(value: Any, field: str) -> None:
    if (
        not isinstance(value, str)
        or not value
        or len(value.encode("utf-8")) > 128
        or re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", value) is None
    ):
        raise VoicePerformanceError(
            f"{field} must be a controlled non-sensitive identifier"
        )


def _require_hardware_model(value: Any, field: str) -> None:
    if (
        not isinstance(value, str)
        or _HARDWARE_MODEL_RE.fullmatch(value) is None
    ):
        raise VoicePerformanceError(
            f"{field} must be a controlled non-sensitive hardware model identifier"
        )


def _require_engine_id(value: Any, field: str) -> None:
    if not isinstance(value, str) or _ENGINE_ID_RE.fullmatch(value) is None:
        raise VoicePerformanceError(
            f"{field} must be a controlled non-sensitive engine identifier"
        )


def _require_nonnegative_number(value: Any, field: str) -> float:
    if (
        not _is_finite_number(value)
        or value < 0
    ):
        raise VoicePerformanceError(f"{field} must be a finite non-negative number")
    return float(value)


def _is_finite_number(value: Any) -> bool:
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        return False
    try:
        return math.isfinite(value)
    except OverflowError:
        return False


def _require_positive_number(value: Any, field: str) -> float:
    result = _require_nonnegative_number(value, field)
    if result == 0:
        raise VoicePerformanceError(f"{field} must be a finite positive number")
    return result


def _require_uint64_number(value: Any, field: str) -> float:
    result = _require_nonnegative_number(value, field)
    if value > _UINT64_MAX:
        raise VoicePerformanceError(f"{field} must fit an unsigned 64-bit range")
    return result


def _require_positive_uint64_number(value: Any, field: str) -> float:
    result = _require_uint64_number(value, field)
    if result == 0:
        raise VoicePerformanceError(f"{field} must be a finite positive number")
    return result


def _require_nonnegative_integer(value: Any, field: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < 0:
        raise VoicePerformanceError(f"{field} must be a non-negative integer")
    return value


def _require_positive_integer(value: Any, field: str) -> int:
    result = _require_nonnegative_integer(value, field)
    if result == 0:
        raise VoicePerformanceError(f"{field} must be a positive integer")
    return result


def _require_uint64(value: Any, field: str) -> int:
    result = _require_nonnegative_integer(value, field)
    if result > _UINT64_MAX:
        raise VoicePerformanceError(f"{field} must be an unsigned 64-bit integer")
    return result


def _require_positive_uint64(value: Any, field: str) -> int:
    result = _require_uint64(value, field)
    if result == 0:
        raise VoicePerformanceError(f"{field} must be a positive integer")
    return result
