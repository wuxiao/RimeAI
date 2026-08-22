"""Fail-closed orchestration for native macOS voice performance collection.

The native collector owns clocks and resource counters.  This module only
accepts identity plans and live boundary markers, binds the native result to a
validated corpus/run, and never accepts caller-supplied measurements.
"""

from __future__ import annotations

import copy
import hashlib
import json
import os
from pathlib import Path
import re
import select
import stat
import subprocess
import tempfile
import time
from typing import Any, BinaryIO, Dict, Mapping, Optional

from .voice_dataset import VoiceCorpus
from .voice_performance import (
    VoicePerformanceError,
    validate_voice_performance,
    voice_run_sha256,
)


class VoicePerformanceCollectionError(ValueError):
    """A collection input cannot produce trustworthy performance evidence."""


_PLAN_KEYS = {
    "schema_version",
    "collection_protocol",
    "sample_interval_ms",
    "native_collector_sha256",
    "expected_team_identifier",
    "artifact_directory",
    "processes",
}
_PROCESS_KEYS = {
    "role",
    "pid",
    "expected_executable_path",
    "expected_signing_identifier",
    "expected_cdhash",
}
_NATIVE_RESULT_KEYS = {
    "schema_version",
    "collection_protocol",
    "artifact",
    "collector",
    "environment",
    "cold_artifact_load_ms",
    "sessions",
    "keyboard_trials",
    "late_voice_commit_count",
    "late_challenge_counts",
}
_NATIVE_SESSION_KEYS = {
    "sample_id",
    "processing_duration_ms",
    "processes",
}
_PROCESS_ROLES = (
    "input_method",
    "candidate_service",
    "voice_helper",
)
_ROLE_SIGNING_IDENTIFIERS = {
    "input_method": "fun.wwcn.inputmethod.RimeAI",
    "candidate_service": "rimeai-daemon",
    "voice_helper": "fun.wwcn.rimeai.voice-helper",
}
_COLLECTOR_SIGNING_IDENTIFIER = (
    "fun.wwcn.rimeai.voice-performance-collector"
)
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
_EVENT_KEYS = {
    "cold_artifact_load_begin": {"schema_version", "event", "sequence"},
    "cold_artifact_load_end": {"schema_version", "event", "sequence"},
    "session_begin": {"schema_version", "event", "sample_id"},
    "session_end": {"schema_version", "event", "sample_id"},
    "keyboard_begin": {"schema_version", "event", "sequence", "phase"},
    "keyboard_candidate_ready": {
        "schema_version",
        "event",
        "sequence",
        "phase",
    },
    "late_voice_commit": {"schema_version", "event"},
    "challenge": {"schema_version", "event", "scenario"},
    "finish": {"schema_version", "event"},
}
_SAFE_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
_SIGNING_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9.-]{0,254}$")
_TEAM_ID_RE = re.compile(r"^[A-Z0-9]{10}$")
_CDHASH_RE = re.compile(r"^[0-9a-f]{40}$")
_SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
_MAXIMUM_PLAN_BYTES = 131_072
_MAXIMUM_EVENT_BYTES = 4_096
_MAXIMUM_NATIVE_RESULT_BYTES = 4 * 1_024 * 1_024
_NATIVE_STDIN_WRITE_TIMEOUT_SECONDS = 5
_NATIVE_EXIT_TIMEOUT_SECONDS = 30


class _InvalidJSON(ValueError):
    pass


def load_voice_collection_plan(
    path: Path,
    run: Mapping[str, Any],
) -> Dict[str, Any]:
    """Load a strict plan that names exactly three live signed processes."""

    try:
        with path.open("rb") as source:
            raw_plan = source.read(_MAXIMUM_PLAN_BYTES + 1)
    except OSError as error:
        raise VoicePerformanceCollectionError(
            "cannot read voice performance collection plan"
        ) from error
    if len(raw_plan) > _MAXIMUM_PLAN_BYTES:
        raise VoicePerformanceCollectionError(
            "voice performance collection plan is too large"
        )
    try:
        value = json.loads(
            raw_plan.decode("utf-8"),
            object_pairs_hook=_strict_json_object,
            parse_constant=_reject_json_constant,
        )
    except (UnicodeDecodeError, RecursionError, ValueError) as error:
        raise VoicePerformanceCollectionError(
            "voice performance collection plan contains invalid JSON"
        ) from error
    _require_exact_keys(value, _PLAN_KEYS, "voice performance collection plan")
    if type(value["schema_version"]) is not int or value["schema_version"] != 1:
        raise VoicePerformanceCollectionError(
            "voice performance collection plan schema_version must be 1"
        )
    _validate_collection_protocol(
        value["collection_protocol"],
        "voice performance collection plan collection_protocol",
    )
    sample_interval = _positive_integer(
        value["sample_interval_ms"],
        "sample_interval_ms",
    )
    if sample_interval > 100:
        raise VoicePerformanceCollectionError(
            "sample_interval_ms must not exceed 100"
        )
    collector_sha256 = value["native_collector_sha256"]
    if (
        not isinstance(collector_sha256, str)
        or _SHA256_RE.fullmatch(collector_sha256) is None
    ):
        raise VoicePerformanceCollectionError(
            "native collector SHA-256 must be 64 lowercase hexadecimal characters"
        )
    team_identifier = value["expected_team_identifier"]
    if (
        not isinstance(team_identifier, str)
        or _TEAM_ID_RE.fullmatch(team_identifier) is None
    ):
        raise VoicePerformanceCollectionError(
            "expected TeamIdentifier must be ten uppercase ASCII characters"
        )

    engine = run.get("engine")
    if not isinstance(engine, Mapping):
        raise VoicePerformanceCollectionError("voice run engine is invalid")
    artifact_directory = value["artifact_directory"]
    if engine.get("asset_management") == "product":
        _validate_product_engine_identity(engine)
        value["artifact_directory"] = str(
            _canonical_existing_path(
                artifact_directory,
                directory=True,
                field="artifact directory",
            )
        )
    elif engine.get("asset_management") == "system":
        if artifact_directory is not None:
            raise VoicePerformanceCollectionError(
                "system-managed collection must not name an artifact directory"
            )
    else:
        raise VoicePerformanceCollectionError(
            "voice run asset management is invalid"
        )

    processes = value["processes"]
    if not isinstance(processes, list) or len(processes) != len(_PROCESS_ROLES):
        raise VoicePerformanceCollectionError(
            "voice performance collection process roles are incomplete"
        )
    seen_pids = set()
    for index, process in enumerate(processes):
        context = "voice performance collection process"
        _require_exact_keys(process, _PROCESS_KEYS, context)
        if process["role"] != _PROCESS_ROLES[index]:
            raise VoicePerformanceCollectionError(
                "voice performance collection process roles are invalid"
            )
        pid = _positive_integer(process["pid"], f"{context}.pid")
        if pid in seen_pids:
            raise VoicePerformanceCollectionError(
                "voice performance collection process identifiers are duplicated"
            )
        seen_pids.add(pid)
        signing_identifier = process["expected_signing_identifier"]
        if (
            not isinstance(signing_identifier, str)
            or _SIGNING_ID_RE.fullmatch(signing_identifier) is None
        ):
            raise VoicePerformanceCollectionError(
                "expected signing identifier is invalid"
            )
        if signing_identifier != _ROLE_SIGNING_IDENTIFIERS[process["role"]]:
            raise VoicePerformanceCollectionError(
                "expected signing identifier does not match its product role"
            )
        cdhash = process["expected_cdhash"]
        if not isinstance(cdhash, str) or _CDHASH_RE.fullmatch(cdhash) is None:
            raise VoicePerformanceCollectionError(
                "expected CDHash must be 40 lowercase hexadecimal characters"
            )
        process["expected_executable_path"] = str(
            _canonical_existing_path(
                process["expected_executable_path"],
                directory=False,
                field="expected executable path",
            )
        )
    return value


def decode_voice_collection_event(
    raw_line: bytes,
    corpus: VoiceCorpus,
) -> bytes:
    """Validate one live marker and return canonical NDJSON for native stdin."""

    if not isinstance(raw_line, bytes) or len(raw_line) > _MAXIMUM_EVENT_BYTES:
        raise VoicePerformanceCollectionError("voice collection event is too large")
    payload = raw_line[:-1] if raw_line.endswith(b"\n") else raw_line
    if not payload or b"\n" in payload or b"\r" in payload:
        raise VoicePerformanceCollectionError(
            "voice collection event must be one NDJSON record"
        )
    try:
        text = payload.decode("utf-8")
        value = json.loads(
            text,
            object_pairs_hook=_strict_json_object,
            parse_constant=_reject_json_constant,
        )
    except (
        UnicodeDecodeError,
        json.JSONDecodeError,
        _InvalidJSON,
        RecursionError,
    ) as error:
        raise VoicePerformanceCollectionError(
            "voice collection event contains invalid JSON"
        ) from error
    if not isinstance(value, dict):
        raise VoicePerformanceCollectionError(
            "voice collection event must be an object"
        )
    if type(value.get("schema_version")) is not int or value["schema_version"] != 1:
        raise VoicePerformanceCollectionError(
            "voice collection event schema_version must be 1"
        )
    event = value.get("event")
    expected_keys = _EVENT_KEYS.get(event) if isinstance(event, str) else None
    if expected_keys is None:
        raise VoicePerformanceCollectionError("voice collection event is invalid")
    _require_exact_keys(value, expected_keys, "voice collection event")
    if "sequence" in expected_keys:
        _positive_integer(value["sequence"], "voice collection event sequence")
    if "sample_id" in expected_keys:
        sample_id = value["sample_id"]
        _require_safe_id(sample_id, "voice collection event sample_id")
        if sample_id not in {sample.id for sample in corpus.samples}:
            raise VoicePerformanceCollectionError(
                "voice collection event sample_id is not in corpus"
            )
    if "phase" in expected_keys and value["phase"] not in _KEYBOARD_PHASES:
        raise VoicePerformanceCollectionError(
            "voice collection event keyboard phase is invalid"
        )
    if (
        "scenario" in expected_keys
        and value["scenario"] not in _LATE_CHALLENGE_SCENARIOS
    ):
        raise VoicePerformanceCollectionError(
            "voice collection event challenge scenario is invalid"
        )
    return (
        json.dumps(
            value,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
            allow_nan=False,
        ).encode("utf-8")
        + b"\n"
    )


def assemble_voice_performance(
    native_result: Mapping[str, Any],
    corpus: VoiceCorpus,
    run: Mapping[str, Any],
    expected_collection_protocol: Mapping[str, Any],
) -> Dict[str, Any]:
    """Bind an untrusted native result, then reuse the authoritative validator."""

    _require_exact_keys(
        native_result,
        _NATIVE_RESULT_KEYS,
        "native voice performance result",
    )
    if (
        type(native_result["schema_version"]) is not int
        or native_result["schema_version"] != 1
    ):
        raise VoicePerformanceCollectionError(
            "native voice performance result schema_version must be 1"
        )
    _validate_collection_protocol(
        expected_collection_protocol,
        "expected collection_protocol",
    )
    _validate_collection_protocol(
        native_result["collection_protocol"],
        "native voice performance collection_protocol",
    )
    if dict(native_result["collection_protocol"]) != dict(
        expected_collection_protocol
    ):
        raise VoicePerformanceCollectionError(
            "native collection_protocol does not match the collection plan"
        )
    sessions = native_result["sessions"]
    if not isinstance(sessions, list):
        raise VoicePerformanceCollectionError(
            "native voice performance sessions must be an array"
        )
    samples_by_id = {sample.id: sample for sample in corpus.samples}
    bound_sessions = []
    for session in sessions:
        _require_exact_keys(
            session,
            _NATIVE_SESSION_KEYS,
            "native voice performance session",
        )
        sample_id = session["sample_id"]
        _require_safe_id(sample_id, "native voice performance sample_id")
        sample = samples_by_id.get(sample_id)
        if sample is None:
            raise VoicePerformanceCollectionError(
                "native voice performance sample_id is not in corpus"
            )
        bound_sessions.append(
            {
                "sample_id": sample_id,
                "audio_duration_ms": sample.audio.duration_ms,
                "processing_duration_ms": session["processing_duration_ms"],
                "processes": copy.deepcopy(session["processes"]),
            }
        )
    result = {
        "schema_version": 3,
        "evaluation_profile_id": run.get("evaluation_profile_id"),
        "corpus_fingerprint": corpus.fingerprint,
        "implementation_fingerprint": run.get("implementation_fingerprint"),
        "run_sha256": voice_run_sha256(run),
        "collection_protocol": copy.deepcopy(
            native_result["collection_protocol"]
        ),
        "artifact": copy.deepcopy(native_result["artifact"]),
        "collector": copy.deepcopy(native_result["collector"]),
        "environment": copy.deepcopy(native_result["environment"]),
        "required_process_roles": list(_PROCESS_ROLES),
        "cold_artifact_load_ms": copy.deepcopy(
            native_result["cold_artifact_load_ms"]
        ),
        "sessions": bound_sessions,
        "keyboard_trials": copy.deepcopy(native_result["keyboard_trials"]),
        "late_voice_commit_count": native_result["late_voice_commit_count"],
        "late_challenge_counts": copy.deepcopy(
            native_result["late_challenge_counts"]
        ),
    }
    try:
        return validate_voice_performance(result, corpus, run)
    except VoicePerformanceError as error:
        raise VoicePerformanceCollectionError(
            "native voice performance result failed strict validation"
        ) from error


def native_voice_collection_plan(
    plan: Mapping[str, Any],
    run: Mapping[str, Any],
) -> Dict[str, Any]:
    """Add only run-owned expected artifact identity to the native plan."""

    engine = run["engine"]
    artifact = None
    if engine["asset_management"] == "product":
        artifact = {
            field: engine[field]
            for field in (
                "artifact_id",
                "artifact_content_sha256",
                "adapter_id",
                "engine_id",
                "model_id",
                "model_revision",
            )
        }
    return {**copy.deepcopy(dict(plan)), "artifact": artifact}


def collect_voice_performance(
    corpus: VoiceCorpus,
    run: Mapping[str, Any],
    plan: Mapping[str, Any],
    native_collector: Path,
    event_source: BinaryIO,
) -> Dict[str, Any]:
    """Forward live markers to the pinned native sampler and bind its result."""

    _require_live_event_source(event_source)
    collector_path = _canonical_existing_path(
        str(native_collector),
        directory=False,
        field="native collector path",
    )
    expected_sha256 = plan.get("native_collector_sha256")
    if not isinstance(expected_sha256, str) or _SHA256_RE.fullmatch(
        expected_sha256
    ) is None:
        raise VoicePerformanceCollectionError(
            "native collector SHA-256 is invalid"
        )
    if _sha256_file(collector_path) != expected_sha256:
        raise VoicePerformanceCollectionError(
            "native collector does not match the pinned SHA-256"
        )

    native_plan = native_voice_collection_plan(plan, run)
    plan_path: Optional[Path] = None
    process: Optional[subprocess.Popen] = None
    finished = False
    try:
        descriptor, raw_plan_path = tempfile.mkstemp(
            prefix="rimeai-voice-performance-plan.",
            suffix=".json",
        )
        plan_path = Path(raw_plan_path)
        try:
            os.fchmod(descriptor, 0o600)
            with os.fdopen(descriptor, "wb") as plan_file:
                plan_file.write(
                    json.dumps(
                        native_plan,
                        ensure_ascii=False,
                        sort_keys=True,
                        separators=(",", ":"),
                        allow_nan=False,
                    ).encode("utf-8")
                )
                plan_file.flush()
                os.fsync(plan_file.fileno())
        except Exception:
            try:
                os.close(descriptor)
            except OSError:
                pass
            raise

        with tempfile.TemporaryFile() as native_stdout, tempfile.TemporaryFile() as native_stderr:
            try:
                process = subprocess.Popen(
                    [str(collector_path), "--plan", str(plan_path)],
                    stdin=subprocess.PIPE,
                    stdout=native_stdout,
                    stderr=native_stderr,
                    close_fds=True,
                    env={
                        "LANG": "C",
                        "LC_ALL": "C",
                        "PATH": "/usr/bin:/bin",
                        "TMPDIR": tempfile.gettempdir(),
                    },
                )
            except OSError as error:
                raise VoicePerformanceCollectionError(
                    "cannot start the native voice performance collector"
                ) from error
            assert process.stdin is not None
            try:
                os.set_blocking(process.stdin.fileno(), False)
            except OSError as error:
                raise VoicePerformanceCollectionError(
                    "cannot configure the native voice performance collector"
                ) from error
            try:
                while True:
                    raw_line = event_source.readline(_MAXIMUM_EVENT_BYTES + 1)
                    if not raw_line:
                        break
                    canonical = decode_voice_collection_event(raw_line, corpus)
                    if finished:
                        raise VoicePerformanceCollectionError(
                            "voice collection finish must be the final event"
                        )
                    _write_native_event(process, canonical)
                    if json.loads(canonical)["event"] == "finish":
                        finished = True
                if not finished:
                    raise VoicePerformanceCollectionError(
                        "voice collection event stream ended before finish"
                    )
            finally:
                try:
                    process.stdin.close()
                except OSError:
                    pass
            try:
                return_code = process.wait(timeout=_NATIVE_EXIT_TIMEOUT_SECONDS)
            except subprocess.TimeoutExpired as error:
                _stop_child(process)
                raise VoicePerformanceCollectionError(
                    "native voice performance collector did not finish"
                ) from error
            if return_code != 0:
                raise VoicePerformanceCollectionError(
                    "native voice performance collector rejected the collection"
                )
            native_stdout.seek(0)
            raw_result = native_stdout.read(_MAXIMUM_NATIVE_RESULT_BYTES + 1)
            if len(raw_result) > _MAXIMUM_NATIVE_RESULT_BYTES:
                raise VoicePerformanceCollectionError(
                    "native voice performance result is too large"
                )
            native_result = _decode_native_result(raw_result)
            _validate_native_collector_identity(native_result, plan)
            return assemble_voice_performance(
                native_result,
                corpus,
                run,
                plan["collection_protocol"],
            )
    except Exception:
        if process is not None and process.poll() is None:
            _stop_child(process)
        raise
    finally:
        if plan_path is not None:
            try:
                plan_path.unlink()
            except OSError:
                pass


def write_voice_performance_atomic(
    value: Mapping[str, Any],
    path: Path,
) -> str:
    """Write validated aggregate evidence atomically with owner-only mode."""

    encoded = (
        json.dumps(
            value,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
            allow_nan=False,
        ).encode("utf-8")
        + b"\n"
    )
    parent = path.parent
    if not parent.is_dir():
        raise VoicePerformanceCollectionError(
            "voice performance output parent must be an existing directory"
        )
    temporary_path: Optional[Path] = None
    try:
        descriptor, raw_path = tempfile.mkstemp(
            prefix=f".{path.name}.",
            suffix=".installing",
            dir=str(parent),
        )
        temporary_path = Path(raw_path)
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb") as output:
            output.write(encoded)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary_path, path)
        temporary_path = None
        directory_descriptor = os.open(parent, os.O_RDONLY)
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
    except OSError as error:
        raise VoicePerformanceCollectionError(
            "cannot write voice performance evidence"
        ) from error
    finally:
        if temporary_path is not None:
            try:
                temporary_path.unlink()
            except OSError:
                pass
    return hashlib.sha256(encoded).hexdigest()


def _validate_product_engine_identity(engine: Mapping[str, Any]) -> None:
    required = (
        "adapter_id",
        "engine_id",
        "artifact_id",
        "artifact_content_sha256",
        "model_id",
        "model_revision",
    )
    if any(not isinstance(engine.get(field), str) for field in required):
        raise VoicePerformanceCollectionError(
            "product voice run identity is incomplete"
        )
    digest = engine["artifact_content_sha256"]
    if re.fullmatch(r"[0-9a-f]{64}", digest) is None:
        raise VoicePerformanceCollectionError(
            "product artifact content identity is invalid"
        )
    candidate_engine_id = f"{engine['adapter_id']}@{digest[:16]}"
    expected_engine_id = (
        candidate_engine_id
        if len(candidate_engine_id.encode("utf-8")) <= 128
        else f"product@{digest[:16]}"
    )
    if engine["engine_id"] != expected_engine_id:
        raise VoicePerformanceCollectionError(
            "product engine_id does not match the runtime artifact identity"
        )


def _validate_collection_protocol(value: Any, context: str) -> None:
    _require_exact_keys(value, {"id", "sha256"}, context)
    _require_safe_id(value["id"], f"{context}.id")
    if not isinstance(value["sha256"], str) or _SHA256_RE.fullmatch(
        value["sha256"]
    ) is None:
        raise VoicePerformanceCollectionError(
            f"{context}.sha256 must be 64 lowercase hexadecimal characters"
        )


def _decode_native_result(raw_result: bytes) -> Mapping[str, Any]:
    if not raw_result or b"\x00" in raw_result:
        raise VoicePerformanceCollectionError(
            "native voice performance collector returned invalid JSON"
        )
    try:
        text = raw_result.decode("utf-8")
        value = json.loads(
            text,
            object_pairs_hook=_strict_json_object,
            parse_constant=_reject_json_constant,
        )
    except (
        UnicodeDecodeError,
        json.JSONDecodeError,
        _InvalidJSON,
        RecursionError,
    ) as error:
        raise VoicePerformanceCollectionError(
            "native voice performance collector returned invalid JSON"
        ) from error
    if not isinstance(value, Mapping):
        raise VoicePerformanceCollectionError(
            "native voice performance collector result must be an object"
        )
    return value


def _validate_native_collector_identity(
    native_result: Mapping[str, Any],
    plan: Mapping[str, Any],
) -> None:
    collector = native_result.get("collector")
    if not isinstance(collector, Mapping):
        raise VoicePerformanceCollectionError(
            "native collector identity does not match the collection plan"
        )
    expected = {
        "executable_sha256": plan.get("native_collector_sha256"),
        "team_identifier": plan.get("expected_team_identifier"),
        "signing_identifier": _COLLECTOR_SIGNING_IDENTIFIER,
        "sample_interval_ms": plan.get("sample_interval_ms"),
    }
    if any(collector.get(field) != value for field, value in expected.items()):
        raise VoicePerformanceCollectionError(
            "native collector identity does not match the collection plan"
        )


def _sha256_file(path: Path) -> str:
    try:
        before = path.stat()
        digest = hashlib.sha256()
        with path.open("rb") as source:
            while True:
                chunk = source.read(1_048_576)
                if not chunk:
                    break
                digest.update(chunk)
        after = path.stat()
    except OSError as error:
        raise VoicePerformanceCollectionError(
            "cannot hash the native voice performance collector"
        ) from error
    identity_before = (
        before.st_dev,
        before.st_ino,
        before.st_size,
        before.st_mtime_ns,
    )
    identity_after = (
        after.st_dev,
        after.st_ino,
        after.st_size,
        after.st_mtime_ns,
    )
    if identity_before != identity_after:
        raise VoicePerformanceCollectionError(
            "native voice performance collector changed while hashing"
        )
    return digest.hexdigest()


def _stop_child(process: subprocess.Popen) -> None:
    if process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=2)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=2)


def _write_native_event(process: subprocess.Popen, value: bytes) -> None:
    stdin = process.stdin
    if stdin is None:
        raise VoicePerformanceCollectionError(
            "native voice performance collector stopped early"
        )
    descriptor = stdin.fileno()
    deadline = time.monotonic() + _NATIVE_STDIN_WRITE_TIMEOUT_SECONDS
    offset = 0
    while offset < len(value):
        if process.poll() is not None:
            raise VoicePerformanceCollectionError(
                "native voice performance collector stopped early"
            )
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise VoicePerformanceCollectionError(
                "native voice performance collector did not accept voice collection events"
            )
        try:
            _, writable, _ = select.select(
                [],
                [descriptor],
                [],
                min(remaining, 0.1),
            )
        except OSError as error:
            raise VoicePerformanceCollectionError(
                "native voice performance collector stopped early"
            ) from error
        if not writable:
            continue
        try:
            written = os.write(descriptor, value[offset:])
        except BlockingIOError:
            continue
        except (BrokenPipeError, OSError) as error:
            raise VoicePerformanceCollectionError(
                "native voice performance collector stopped early"
            ) from error
        if written <= 0:
            raise VoicePerformanceCollectionError(
                "native voice performance collector stopped early"
            )
        offset += written


def _require_live_event_source(event_source: BinaryIO) -> None:
    try:
        descriptor = event_source.fileno()
    except (AttributeError, OSError) as error:
        raise VoicePerformanceCollectionError(
            "voice collection events require a live operating-system stream"
        ) from error
    try:
        metadata = os.fstat(descriptor)
    except OSError as error:
        raise VoicePerformanceCollectionError(
            "voice collection event stream is unavailable"
        ) from error
    if stat.S_ISREG(metadata.st_mode):
        raise VoicePerformanceCollectionError(
            "voice collection events must arrive through a live pipe, socket, or terminal"
        )


def _canonical_existing_path(
    value: Any,
    *,
    directory: bool,
    field: str,
) -> Path:
    if not isinstance(value, str) or not value or not value.startswith("/"):
        raise VoicePerformanceCollectionError(f"{field} must be an absolute path")
    path = Path(value)
    try:
        resolved = path.resolve(strict=True)
        metadata = path.stat()
    except (OSError, RuntimeError) as error:
        raise VoicePerformanceCollectionError(f"{field} is unavailable") from error
    if resolved != path:
        raise VoicePerformanceCollectionError(
            f"{field} must be canonical and contain no symlink"
        )
    if directory:
        if not stat.S_ISDIR(metadata.st_mode):
            raise VoicePerformanceCollectionError(f"{field} must be a directory")
    elif not stat.S_ISREG(metadata.st_mode) or not os.access(path, os.X_OK):
        raise VoicePerformanceCollectionError(
            f"{field} must be an executable regular file"
        )
    return path


def _require_exact_keys(value: Any, expected: set, context: str) -> None:
    if not isinstance(value, Mapping):
        raise VoicePerformanceCollectionError(f"{context} must be an object")
    actual = set(value)
    missing = expected - actual
    unexpected = actual - expected
    if missing:
        raise VoicePerformanceCollectionError(
            f"{context} is missing required fields"
        )
    if unexpected:
        raise VoicePerformanceCollectionError(
            f"{context} contains unknown fields"
        )


def _positive_integer(value: Any, field: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
        raise VoicePerformanceCollectionError(f"{field} must be a positive integer")
    return value


def _require_safe_id(value: Any, field: str) -> None:
    if not isinstance(value, str) or _SAFE_ID_RE.fullmatch(value) is None:
        raise VoicePerformanceCollectionError(
            f"{field} must be a controlled non-sensitive identifier"
        )


def _strict_json_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise _InvalidJSON("duplicate key")
        result[key] = value
    return result


def _reject_json_constant(_value: str):
    raise _InvalidJSON("non-finite number")
