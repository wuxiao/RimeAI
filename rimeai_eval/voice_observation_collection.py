"""Fail-closed orchestration for native voice observation collection.

The Python side owns input identity, the privacy-minimal native plan, process
boundaries, and atomic installation.  The native driver owns replay and emits
only the observations JSONL that the authoritative evaluator accepts.
"""

from __future__ import annotations

import copy
import errno
import hashlib
import json
import math
import os
from pathlib import Path
import select
import signal
import stat
import subprocess
import tempfile
import time
from typing import Any, Dict, Mapping, Optional
import unicodedata

from .voice_dataset import VoiceCorpus, load_voice_corpus
from .voice_evaluation import (
    VoiceEvaluationError,
    load_voice_observations,
    load_voice_run,
)


class VoiceObservationCollectionError(ValueError):
    """An input cannot produce trustworthy voice observations."""


_PLAN_KEYS = {
    "schema_version",
    "collection_method",
    "corpus_fingerprint",
    "native_driver_sha256",
    "artifact_directory",
    "artifact",
    "recognizer_locale",
    "policy",
    "hotword_snapshot",
    "samples",
    "output_path",
}
_ARTIFACT_KEYS = (
    "artifact_id",
    "artifact_content_sha256",
    "adapter_id",
    "engine_id",
    "model_id",
    "model_revision",
)
_SAMPLE_KEYS = {
    "sample_id",
    "audio_path",
    "audio_sha256",
    "duration_ms",
    "sample_rate_hz",
    "channels",
    "frame_count",
}
_EMPTY_HOTWORD_SNAPSHOT = {
    "normalization_version": 1,
    "phrases": [],
    "hotword_set_sha256": (
        "3065f942bf0c8072df531e3a79a403a90a7c0ac884cb3d24085d838911c9adda"
    ),
}
_MAXIMUM_PLAN_BYTES = 4 * 1_024 * 1_024
_MAXIMUM_HOTWORD_SNAPSHOT_BYTES = 64 * 1_024
_MAXIMUM_OBSERVATIONS_BYTES = 16 * 1_024 * 1_024
_MAXIMUM_NATIVE_DIAGNOSTIC_BYTES = 4_096
_MAXIMUM_NATIVE_SAMPLES = 10_000
_MAXIMUM_NATIVE_SAMPLE_DURATION_MS = 60_000.0
_MAXIMUM_SWIFT_PATH_BYTES = 4_096
_NATIVE_STARTUP_ALLOWANCE_SECONDS = 30.0
_NATIVE_FINAL_DEADLINE_SECONDS = 5.0
_MAXIMUM_NATIVE_TIMEOUT_SECONDS = 60.0 * 60.0


def collect_voice_observations(
    corpus_root: Path,
    run_path: Path,
    native_driver: Path,
    artifact_dir: Path,
    output_path: Path,
    hotwords_file: Optional[Path] = None,
) -> str:
    """Collect and atomically install one validated observations file."""

    corpus = load_voice_corpus(Path(corpus_root))
    run = load_voice_run(Path(run_path), corpus)
    _require_supported_run(run, corpus)

    driver_path = _canonical_executable(Path(native_driver))
    artifact_path = _canonical_directory(Path(artifact_dir), "artifact directory")
    _require_swift_plan_path(artifact_path, "artifact directory")
    final_output = _canonical_output_path(Path(output_path))
    hotword_snapshot = _hotword_snapshot(run, hotwords_file)
    _reject_output_conflicts(
        final_output,
        corpus,
        Path(run_path),
        driver_path,
        artifact_path,
        hotwords_file,
    )

    timeout = _native_timeout_seconds(corpus)
    parent = final_output.parent
    try:
        temporary_directory = tempfile.TemporaryDirectory(
            prefix=f".{final_output.name}.collecting.",
            dir=str(parent),
        )
    except OSError as error:
        raise VoiceObservationCollectionError(
            "cannot prepare voice observation collection"
        ) from error

    with temporary_directory as raw_staging:
        staging = Path(raw_staging)
        try:
            staging.chmod(0o700)
        except OSError as error:
            raise VoiceObservationCollectionError(
                "cannot secure voice observation collection"
            ) from error
        plan_path = staging / "plan.json"
        native_output = staging / "observations.jsonl"
        validated_output = staging / "validated-observations.jsonl"
        pinned_driver = staging / "native-driver"
        _require_swift_plan_path(plan_path, "native collection plan")
        _require_swift_plan_path(native_output, "native observation output")
        driver_sha256, pinned_driver_metadata = _pin_native_driver(
            driver_path,
            pinned_driver,
            run["implementation_fingerprint"],
        )
        plan = _native_plan(
            corpus,
            run,
            driver_sha256,
            artifact_path,
            hotword_snapshot,
            native_output,
        )
        if set(plan) != _PLAN_KEYS or any(
            set(sample) != _SAMPLE_KEYS for sample in plan["samples"]
        ):
            raise AssertionError("invalid internal voice observation plan")
        plan_bytes = json.dumps(
            plan,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
            allow_nan=False,
        ).encode("utf-8")
        if len(plan_bytes) > _MAXIMUM_PLAN_BYTES:
            raise VoiceObservationCollectionError(
                "voice observation collection plan is too large"
            )
        _write_private_plan(plan_path, plan_bytes)
        plan_metadata = plan_path.lstat()
        staging_metadata = staging.lstat()
        _run_native_driver(pinned_driver, plan_path, native_output, timeout)
        native_output_metadata = _require_only_native_output(
            staging,
            staging_metadata,
            plan_path,
            plan_metadata,
            plan_bytes,
            pinned_driver,
            pinned_driver_metadata,
            driver_sha256,
            native_output,
        )
        validated_candidate = _capture_native_output(
            native_output,
            native_output_metadata,
            validated_output,
        )
        try:
            _validate_native_output(validated_candidate, corpus, run)
            output_sha256 = _fsync_and_hash(validated_candidate)
            _install_validated_output(
                validated_candidate.path,
                validated_candidate.metadata,
                output_sha256,
                final_output,
                parent,
            )
        finally:
            validated_candidate.close()
    return output_sha256


def _require_supported_run(
    run: Mapping[str, Any], corpus: VoiceCorpus
) -> None:
    engine = run["engine"]
    audio_io = run["audio_io"]
    policy = run["policy"]
    if engine["asset_management"] != "product":
        raise VoiceObservationCollectionError(
            "voice observation collection requires a product engine"
        )
    if (
        engine["requires_on_device"] is not True
        or engine["supports_on_device_at_run"] is not True
    ):
        raise VoiceObservationCollectionError(
            "voice observation collection requires an available offline engine"
        )
    if run["collection_method"] != "automated":
        raise VoiceObservationCollectionError(
            "voice observation collection requires automated collection"
        )
    if audio_io["device_class"] != "virtual_fixture":
        raise VoiceObservationCollectionError(
            "voice observation collection requires virtual fixture audio"
        )
    if run["clock"] != {
        "domain": "helper_server_monotonic",
        "unit": "ms",
    }:
        raise VoiceObservationCollectionError(
            "voice observation collection requires the helper monotonic clock"
        )
    if policy["endpoint_strategy"] != "push-to-talk":
        raise VoiceObservationCollectionError(
            "voice observation collection requires push-to-talk"
        )
    if policy["postprocessor_id"] != "none":
        raise VoiceObservationCollectionError(
            "voice observation collection requires the identity postprocessor"
        )
    if engine["recognizer_locale"] not in {"zh-CN", "en-US"}:
        raise VoiceObservationCollectionError(
            "voice observation collection requires a supported recognizer locale"
        )
    digest = engine["artifact_content_sha256"]
    candidate_engine_id = "%s@%s" % (engine["adapter_id"], digest[:16])
    derived_engine_id = (
        candidate_engine_id
        if len(candidate_engine_id.encode("utf-8")) <= 128
        else "product@%s" % digest[:16]
    )
    if engine["engine_id"] != derived_engine_id:
        raise VoiceObservationCollectionError(
            "voice observation collection engine identity is inconsistent"
        )
    if len(corpus.samples) > _MAXIMUM_NATIVE_SAMPLES:
        raise VoiceObservationCollectionError(
            "voice observation collection has too many samples"
        )
    if any(
        sample.audio.sample_rate_hz != audio_io["sample_rate_hz"]
        or sample.audio.channels != audio_io["channels"]
        or sample.audio.duration_ms > _MAXIMUM_NATIVE_SAMPLE_DURATION_MS
        for sample in corpus.samples
    ):
        raise VoiceObservationCollectionError(
            "voice run audio format does not match every corpus sample"
        )
    for sample in corpus.samples:
        _require_swift_plan_path(sample.audio.path, "voice sample audio")


def _native_plan(
    corpus: VoiceCorpus,
    run: Mapping[str, Any],
    driver_sha256: str,
    artifact_path: Path,
    hotword_snapshot: Mapping[str, Any],
    native_output: Path,
) -> Dict[str, Any]:
    engine = run["engine"]
    return {
        "schema_version": 1,
        "collection_method": "evaluation_replay",
        "corpus_fingerprint": corpus.fingerprint,
        "native_driver_sha256": driver_sha256,
        "artifact_directory": str(artifact_path),
        "artifact": {key: engine[key] for key in _ARTIFACT_KEYS},
        "recognizer_locale": engine["recognizer_locale"],
        "policy": copy.deepcopy(run["policy"]),
        "hotword_snapshot": copy.deepcopy(dict(hotword_snapshot)),
        "samples": [
            {
                "sample_id": sample.id,
                "audio_path": str(sample.audio.path),
                "audio_sha256": sample.audio.sha256,
                "duration_ms": sample.audio.duration_ms,
                "sample_rate_hz": sample.audio.sample_rate_hz,
                "channels": sample.audio.channels,
                "frame_count": sample.audio.frame_count,
            }
            for sample in corpus.samples
        ],
        "output_path": str(native_output),
    }


def _hotword_snapshot(
    run: Mapping[str, Any], hotwords_file: Optional[Path]
) -> Dict[str, Any]:
    enabled = run["policy"]["hotwords_enabled"]
    if not enabled:
        if hotwords_file is not None:
            raise VoiceObservationCollectionError(
                "hotword-disabled voice collection must not name a snapshot"
            )
        return copy.deepcopy(_EMPTY_HOTWORD_SNAPSHOT)
    if hotwords_file is None:
        raise VoiceObservationCollectionError(
            "hotword-enabled voice collection requires a valid snapshot"
        )
    snapshot_path = _canonical_regular_input(
        Path(hotwords_file), "hotword snapshot"
    )
    try:
        with snapshot_path.open("rb") as source:
            raw = source.read(_MAXIMUM_HOTWORD_SNAPSHOT_BYTES + 1)
    except OSError as error:
        raise VoiceObservationCollectionError(
            "hotword snapshot is unavailable"
        ) from error
    if len(raw) > _MAXIMUM_HOTWORD_SNAPSHOT_BYTES:
        raise VoiceObservationCollectionError("hotword snapshot is too large")
    try:
        value = json.loads(
            raw.decode("utf-8"),
            object_pairs_hook=_strict_json_object,
            parse_constant=_reject_json_constant,
        )
    except (UnicodeDecodeError, RecursionError, ValueError) as error:
        raise VoiceObservationCollectionError(
            "hotword snapshot contains invalid JSON"
        ) from error
    if not isinstance(value, dict) or set(value) != {
        "normalization_version",
        "phrases",
        "hotword_set_sha256",
    }:
        raise VoiceObservationCollectionError(
            "hotword snapshot fields are invalid"
        )
    if (
        type(value["normalization_version"]) is not int
        or value["normalization_version"] != 1
    ):
        raise VoiceObservationCollectionError(
            "hotword snapshot normalization version is invalid"
        )
    phrases = value["phrases"]
    if not isinstance(phrases, list) or len(phrases) > 128:
        raise VoiceObservationCollectionError(
            "hotword snapshot phrases are invalid"
        )
    canonical = _canonical_hotword_phrases(phrases)
    if not canonical:
        raise VoiceObservationCollectionError(
            "hotword-enabled voice collection requires a non-empty snapshot"
        )
    if canonical != phrases:
        raise VoiceObservationCollectionError(
            "hotword snapshot phrases are not canonical"
        )
    expected_digest = _hotword_digest(canonical)
    if value["hotword_set_sha256"] != expected_digest:
        raise VoiceObservationCollectionError(
            "hotword snapshot digest does not match its phrases"
        )
    if run["policy"]["hotword_set_sha256"] != expected_digest:
        raise VoiceObservationCollectionError(
            "hotword snapshot digest does not match the voice run"
        )
    return {
        "normalization_version": 1,
        "phrases": canonical,
        "hotword_set_sha256": expected_digest,
    }


def _canonical_hotword_phrases(phrases) -> list:
    seen = set()
    canonical = []
    aggregate_bytes = 0
    for phrase in phrases:
        if not isinstance(phrase, str):
            raise VoiceObservationCollectionError(
                "hotword snapshot phrases are invalid"
            )
        try:
            normalized = unicodedata.normalize("NFKC", phrase)
            normalized = _trim_foundation_whitespace(normalized)
            encoded = normalized.encode("utf-8")
        except (UnicodeError, ValueError) as error:
            raise VoiceObservationCollectionError(
                "hotword snapshot phrases are invalid"
            ) from error
        character_count = _swift_character_count(normalized)
        if not 2 <= character_count <= 32 or len(encoded) > 128:
            raise VoiceObservationCollectionError(
                "hotword snapshot phrases are invalid"
            )
        if any(
            ord(character) < 0x20 or 0x7F <= ord(character) <= 0x9F
            for character in normalized
        ) or any(forbidden in normalized for forbidden in "/:#@"):
            raise VoiceObservationCollectionError(
                "hotword snapshot phrases are invalid"
            )
        if normalized in seen:
            raise VoiceObservationCollectionError(
                "hotword snapshot phrases are duplicated"
            )
        seen.add(normalized)
        aggregate_bytes += len(encoded)
        if aggregate_bytes > 16_384:
            raise VoiceObservationCollectionError(
                "hotword snapshot is too large"
            )
        canonical.append(normalized)
    return canonical


_FOUNDATION_WHITESPACE_AND_NEWLINES = frozenset(
    "\u0009\u000a\u000b\u000c\u000d\u0020\u0085\u00a0\u1680"
    "\u2000\u2001\u2002\u2003\u2004\u2005\u2006\u2007\u2008\u2009"
    "\u200a\u2028\u2029\u202f\u205f\u3000"
)


def _trim_foundation_whitespace(value: str) -> str:
    start = 0
    end = len(value)
    while start < end and value[start] in _FOUNDATION_WHITESPACE_AND_NEWLINES:
        start += 1
    while end > start and value[end - 1] in _FOUNDATION_WHITESPACE_AND_NEWLINES:
        end -= 1
    return value[start:end]


def _swift_character_count(value: str) -> int:
    """Count common extended grapheme clusters used by Swift ``String.count``.

    The native decoder remains authoritative for the complete Unicode grapheme
    table.  This covers combining marks, emoji modifiers/ZWJ sequences, flags,
    and Hangul composition so Python never weakens the documented limits for
    the common cases.
    """

    count = 0
    regional_run = 0
    previous = ""
    join_next = False
    for character in value:
        codepoint = ord(character)
        category = unicodedata.category(character)
        regional = 0x1F1E6 <= codepoint <= 0x1F1FF
        extender = (
            category in {"Mn", "Mc", "Me"}
            or character == "\u200d"
            or 0xFE00 <= codepoint <= 0xFE0F
            or 0xE0100 <= codepoint <= 0xE01EF
            or 0x1F3FB <= codepoint <= 0x1F3FF
            or 0xE0020 <= codepoint <= 0xE007F
        )
        hangul_join = _hangul_cluster_continues(previous, character)
        if count == 0:
            count = 1
        elif join_next or extender or hangul_join:
            pass
        elif previous == "\r" and character == "\n":
            pass
        elif regional and regional_run % 2 == 1:
            pass
        else:
            count += 1
        if regional:
            regional_run += 1
        else:
            regional_run = 0
        join_next = character == "\u200d"
        previous = character
    return count


def _hangul_cluster_continues(previous: str, current: str) -> bool:
    if not previous:
        return False
    previous_class = _hangul_class(ord(previous))
    current_class = _hangul_class(ord(current))
    return (
        previous_class == "L" and current_class in {"L", "V", "LV", "LVT"}
    ) or (
        previous_class in {"LV", "V"} and current_class in {"V", "T"}
    ) or (previous_class in {"LVT", "T"} and current_class == "T")


def _hangul_class(codepoint: int) -> str:
    if 0x1100 <= codepoint <= 0x115F or 0xA960 <= codepoint <= 0xA97C:
        return "L"
    if 0x1160 <= codepoint <= 0x11A7 or 0xD7B0 <= codepoint <= 0xD7C6:
        return "V"
    if 0x11A8 <= codepoint <= 0x11FF or 0xD7CB <= codepoint <= 0xD7FB:
        return "T"
    if 0xAC00 <= codepoint <= 0xD7A3:
        return "LV" if (codepoint - 0xAC00) % 28 == 0 else "LVT"
    return ""


def _hotword_digest(phrases) -> str:
    payload = bytearray(b"rimeai.voice-hotwords.v1\0")
    payload.extend(len(phrases).to_bytes(4, "big"))
    for phrase in phrases:
        encoded = phrase.encode("utf-8")
        payload.extend(len(encoded).to_bytes(4, "big"))
        payload.extend(encoded)
    return hashlib.sha256(payload).hexdigest()


class _InvalidJSON(ValueError):
    pass


def _strict_json_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise _InvalidJSON("duplicate JSON key")
        value[key] = item
    return value


def _reject_json_constant(_):
    raise _InvalidJSON("invalid JSON number")


def _canonical_regular_input(path: Path, label: str) -> Path:
    try:
        if path.is_symlink():
            raise VoiceObservationCollectionError(f"{label} must not be a symlink")
        resolved = path.resolve(strict=True)
        metadata = path.stat()
    except VoiceObservationCollectionError:
        raise
    except (OSError, RuntimeError) as error:
        raise VoiceObservationCollectionError(f"{label} is unavailable") from error
    if not stat.S_ISREG(metadata.st_mode):
        raise VoiceObservationCollectionError(f"{label} must be a regular file")
    return resolved


def _canonical_executable(path: Path) -> Path:
    if not path.is_absolute():
        raise VoiceObservationCollectionError(
            "native voice driver path must be canonical"
        )
    try:
        if path.is_symlink():
            raise VoiceObservationCollectionError(
                "native voice driver path must be canonical"
            )
        resolved = path.resolve(strict=True)
        metadata = path.stat()
    except VoiceObservationCollectionError:
        raise
    except (OSError, RuntimeError) as error:
        raise VoiceObservationCollectionError(
            "native voice driver is unavailable"
        ) from error
    if resolved != path or not stat.S_ISREG(metadata.st_mode):
        raise VoiceObservationCollectionError(
            "native voice driver must be a canonical regular file"
        )
    if not os.access(path, os.X_OK):
        raise VoiceObservationCollectionError(
            "native voice driver must be executable"
        )
    return path


def _canonical_directory(path: Path, label: str) -> Path:
    if not path.is_absolute():
        raise VoiceObservationCollectionError(f"{label} must be canonical")
    try:
        if path.is_symlink():
            raise VoiceObservationCollectionError(f"{label} must be canonical")
        resolved = path.resolve(strict=True)
        metadata = path.stat()
    except VoiceObservationCollectionError:
        raise
    except (OSError, RuntimeError) as error:
        raise VoiceObservationCollectionError(f"{label} is unavailable") from error
    if resolved != path or not stat.S_ISDIR(metadata.st_mode):
        raise VoiceObservationCollectionError(
            f"{label} must be a canonical directory"
        )
    return path


def _canonical_output_path(path: Path) -> Path:
    if not path.name or path.name in {".", ".."}:
        raise VoiceObservationCollectionError("voice observation output is invalid")
    try:
        if path.is_symlink():
            raise VoiceObservationCollectionError(
                "voice observation output must not be a symlink"
            )
        parent = path.parent.resolve(strict=True)
        parent_metadata = parent.stat()
        if not stat.S_ISDIR(parent_metadata.st_mode):
            raise VoiceObservationCollectionError(
                "voice observation output parent must be a directory"
            )
        canonical = parent / path.name
        if canonical.exists():
            metadata = canonical.stat()
            if not stat.S_ISREG(metadata.st_mode):
                raise VoiceObservationCollectionError(
                    "voice observation output must be a regular file"
                )
    except VoiceObservationCollectionError:
        raise
    except (OSError, RuntimeError) as error:
        raise VoiceObservationCollectionError(
            "voice observation output is unavailable"
        ) from error
    return canonical


def _require_swift_plan_path(path: Path, label: str) -> None:
    value = str(path)
    if (
        not path.is_absolute()
        or "\0" in value
        or len(value.encode("utf-8")) > _MAXIMUM_SWIFT_PATH_BYTES
        or unicodedata.normalize("NFC", value) != value
        or Path(os.path.normpath(value)) != path
    ):
        raise VoiceObservationCollectionError(
            "%s cannot be represented in the native collection plan" % label
        )


def _reject_output_conflicts(
    output: Path,
    corpus: VoiceCorpus,
    run_path: Path,
    driver_path: Path,
    artifact_path: Path,
    hotwords_file: Optional[Path],
) -> None:
    if output == corpus.root or corpus.root in output.parents:
        raise VoiceObservationCollectionError(
            "voice observation output conflicts with an input"
        )
    if output == artifact_path or artifact_path in output.parents:
        raise VoiceObservationCollectionError(
            "voice observation output conflicts with an input"
        )
    protected = [driver_path]
    try:
        protected.append(Path(run_path).resolve(strict=True))
        if hotwords_file is not None:
            protected.append(Path(hotwords_file).resolve(strict=True))
    except (OSError, RuntimeError) as error:
        raise VoiceObservationCollectionError(
            "voice observation collection input is unavailable"
        ) from error
    protected.extend(sample.audio.path for sample in corpus.samples)
    if output in protected:
        raise VoiceObservationCollectionError(
            "voice observation output conflicts with an input"
        )
    if output.exists():
        try:
            output_identity = _file_identity(output)
            if any(
                candidate.is_file()
                and _file_identity(candidate) == output_identity
                for candidate in protected
            ):
                raise VoiceObservationCollectionError(
                    "voice observation output conflicts with an input"
                )
        except VoiceObservationCollectionError:
            raise
        except OSError as error:
            raise VoiceObservationCollectionError(
                "voice observation output is unavailable"
            ) from error


def _native_timeout_seconds(corpus: VoiceCorpus) -> float:
    required = (
        _NATIVE_STARTUP_ALLOWANCE_SECONDS
        + math.fsum(sample.audio.duration_ms for sample in corpus.samples) / 1_000.0
        + len(corpus.samples) * _NATIVE_FINAL_DEADLINE_SECONDS
    )
    if required > _MAXIMUM_NATIVE_TIMEOUT_SECONDS:
        raise VoiceObservationCollectionError(
            "voice observation collection exceeds the bounded runtime"
        )
    return required


def _write_private_plan(path: Path, payload: bytes) -> None:
    descriptor: Optional[int] = None
    try:
        descriptor = os.open(
            path,
            os.O_WRONLY
            | os.O_CREAT
            | os.O_EXCL
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0),
            0o600,
        )
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb") as output:
            descriptor = None
            output.write(payload)
            output.flush()
            os.fsync(output.fileno())
    except OSError as error:
        raise VoiceObservationCollectionError(
            "cannot write the native voice observation plan"
        ) from error
    finally:
        if descriptor is not None:
            try:
                os.close(descriptor)
            except OSError:
                pass


def _pin_native_driver(
    source: Path,
    destination: Path,
    expected_sha256: str,
):
    source_descriptor: Optional[int] = None
    destination_descriptor: Optional[int] = None
    digest = hashlib.sha256()
    try:
        path_metadata = source.lstat()
        source_descriptor = os.open(
            source,
            os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
        )
        source_before = os.fstat(source_descriptor)
        if (
            not stat.S_ISREG(path_metadata.st_mode)
            or _file_stat_identity(path_metadata)
            != _file_stat_identity(source_before)
        ):
            raise VoiceObservationCollectionError(
                "native voice driver changed before it could be pinned"
            )
        destination_descriptor = os.open(
            destination,
            os.O_WRONLY
            | os.O_CREAT
            | os.O_EXCL
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0),
            0o500,
        )
        while True:
            chunk = os.read(source_descriptor, 1_048_576)
            if not chunk:
                break
            digest.update(chunk)
            _write_all(destination_descriptor, chunk)
        source_after = os.fstat(source_descriptor)
        if _file_stat_identity(source_before) != _file_stat_identity(source_after):
            raise VoiceObservationCollectionError(
                "native voice driver changed while it was pinned"
            )
        actual_sha256 = digest.hexdigest()
        if actual_sha256 != expected_sha256:
            raise VoiceObservationCollectionError(
                "native voice driver identity does not match the voice run"
            )
        os.fchmod(destination_descriptor, 0o500)
        os.fsync(destination_descriptor)
        pinned_metadata = os.fstat(destination_descriptor)
        if (
            not stat.S_ISREG(pinned_metadata.st_mode)
            or pinned_metadata.st_uid != os.geteuid()
            or stat.S_IMODE(pinned_metadata.st_mode) != 0o500
            or pinned_metadata.st_size != source_before.st_size
        ):
            raise VoiceObservationCollectionError(
                "cannot secure the pinned native voice driver"
            )
        return actual_sha256, pinned_metadata
    except VoiceObservationCollectionError:
        raise
    except OSError as error:
        raise VoiceObservationCollectionError(
            "cannot pin the native voice driver"
        ) from error
    finally:
        if source_descriptor is not None:
            try:
                os.close(source_descriptor)
            except OSError:
                pass
        if destination_descriptor is not None:
            try:
                os.close(destination_descriptor)
            except OSError:
                pass


def _write_all(descriptor: int, payload: bytes) -> None:
    written = 0
    while written < len(payload):
        try:
            count = os.write(descriptor, payload[written:])
        except InterruptedError:
            continue
        if count <= 0:
            raise OSError("short write")
        written += count


def _run_native_driver(
    driver: Path,
    plan: Path,
    native_output: Path,
    timeout: float,
) -> None:
    try:
        process = subprocess.Popen(
            [str(driver), "--plan", str(plan)],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            close_fds=True,
            start_new_session=True,
            env={
                "LANG": "C",
                "LC_ALL": "C",
                "PATH": "/usr/bin:/bin",
                "TMPDIR": str(plan.parent),
            },
        )
    except OSError as error:
        raise VoiceObservationCollectionError(
            "cannot start the native voice driver"
        ) from error
    assert process.stdout is not None and process.stderr is not None
    streams = {
        process.stdout.fileno(): "standard output",
        process.stderr.fileno(): "standard error",
    }
    cleanup_attempted = False

    def cleanup_process_group_once() -> None:
        nonlocal cleanup_attempted
        if cleanup_attempted:
            return
        cleanup_attempted = True
        _stop_native_driver(process)

    try:
        for descriptor in streams:
            os.set_blocking(descriptor, False)
        deadline = time.monotonic() + timeout
        while streams or process.poll() is None:
            if process.poll() is not None:
                cleanup_process_group_once()
            _enforce_running_output_bound(native_output)
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise VoiceObservationCollectionError(
                    "native voice driver did not finish within its bound"
                )
            try:
                readable, _, _ = select.select(
                    list(streams), [], [], min(remaining, 0.05)
                )
            except OSError as error:
                raise VoiceObservationCollectionError(
                    "cannot monitor the native voice driver"
                ) from error
            for descriptor in readable:
                try:
                    chunk = os.read(
                        descriptor, _MAXIMUM_NATIVE_DIAGNOSTIC_BYTES + 1
                    )
                except BlockingIOError:
                    continue
                except OSError as error:
                    raise VoiceObservationCollectionError(
                        "cannot monitor the native voice driver"
                    ) from error
                if chunk:
                    stream_name = streams[descriptor]
                    raise VoiceObservationCollectionError(
                        f"native voice driver wrote unexpected {stream_name}"
                    )
                streams.pop(descriptor)
            _enforce_running_output_bound(native_output)
            if process.poll() is not None and streams and not readable:
                # EOF becomes readable immediately after process exit.  Keep
                # draining through the bounded reads above rather than calling
                # communicate(), which would allocate unbounded diagnostics.
                continue
        return_code = process.wait(timeout=0)
    except subprocess.TimeoutExpired as error:
        raise VoiceObservationCollectionError(
            "native voice driver did not finish within its bound"
        ) from error
    finally:
        try:
            cleanup_process_group_once()
        finally:
            process.stdout.close()
            process.stderr.close()
    if return_code != 0:
        raise VoiceObservationCollectionError(
            "native voice driver rejected the collection"
        )


def _enforce_running_output_bound(path: Path) -> None:
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        return
    except OSError as error:
        raise VoiceObservationCollectionError(
            "cannot monitor native voice observations"
        ) from error
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_uid != os.geteuid()
        or stat.S_IMODE(metadata.st_mode) != 0o600
        or metadata.st_size > _MAXIMUM_OBSERVATIONS_BYTES
    ):
        raise VoiceObservationCollectionError(
            "native voice observations exceeded their secure bound"
        )


def _stop_native_driver(process: subprocess.Popen) -> None:
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except OSError as error:
        if error.errno != errno.ESRCH:
            raise VoiceObservationCollectionError(
                "cannot clean the native voice driver process group"
            ) from error
    try:
        process.wait(timeout=2)
    except subprocess.TimeoutExpired as error:
        try:
            process.kill()
            process.wait(timeout=2)
        except (OSError, subprocess.TimeoutExpired) as cleanup_error:
            raise VoiceObservationCollectionError(
                "cannot clean the native voice driver process group"
            ) from cleanup_error
        raise VoiceObservationCollectionError(
            "cannot clean the native voice driver process group"
        ) from error
    except OSError as error:
        raise VoiceObservationCollectionError(
            "cannot clean the native voice driver process group"
        ) from error


def _require_only_native_output(
    staging: Path,
    staging_metadata,
    plan_path: Path,
    plan_metadata,
    plan_bytes: bytes,
    pinned_driver: Path,
    pinned_driver_metadata,
    driver_sha256: str,
    native_output: Path,
):
    try:
        current_staging_metadata = staging.lstat()
        entries = _bounded_directory_entry_names(staging, maximum_entries=3)
        current_plan_metadata = plan_path.lstat()
        output_metadata = native_output.lstat()
        driver_metadata = pinned_driver.lstat()
        if (
            not stat.S_ISDIR(current_staging_metadata.st_mode)
            or current_staging_metadata.st_uid != os.geteuid()
            or stat.S_IMODE(current_staging_metadata.st_mode) != 0o700
            or _directory_stat_identity(current_staging_metadata)
            != _directory_stat_identity(staging_metadata)
        ):
            raise VoiceObservationCollectionError(
                "native voice driver changed its private staging directory"
            )
        if entries != {
            plan_path.name,
            pinned_driver.name,
            native_output.name,
        }:
            raise VoiceObservationCollectionError(
                "native voice driver produced unexpected files"
            )
        if (
            not stat.S_ISREG(current_plan_metadata.st_mode)
            or current_plan_metadata.st_uid != os.geteuid()
            or stat.S_IMODE(current_plan_metadata.st_mode) != 0o600
            or _file_stat_identity(current_plan_metadata)
            != _file_stat_identity(plan_metadata)
            or _read_bounded_regular_file(
                plan_path,
                _MAXIMUM_PLAN_BYTES,
                current_plan_metadata,
            )
            != plan_bytes
        ):
            raise VoiceObservationCollectionError(
                "native voice driver changed its collection plan"
            )
        if (
            not stat.S_ISREG(driver_metadata.st_mode)
            or stat.S_IMODE(driver_metadata.st_mode) != 0o500
            or _file_stat_identity(driver_metadata)
            != _file_stat_identity(pinned_driver_metadata)
            or hashlib.sha256(
                _read_bounded_regular_file(
                    pinned_driver,
                    pinned_driver_metadata.st_size,
                    pinned_driver_metadata,
                )
            ).hexdigest()
            != driver_sha256
        ):
            raise VoiceObservationCollectionError(
                "native voice driver changed its pinned executable"
            )
        if (
            not stat.S_ISREG(output_metadata.st_mode)
            or native_output.is_symlink()
            or stat.S_IMODE(output_metadata.st_mode) != 0o600
        ):
            raise VoiceObservationCollectionError(
                "native voice driver output is not a private regular file"
            )
        if output_metadata.st_size > _MAXIMUM_OBSERVATIONS_BYTES:
            raise VoiceObservationCollectionError(
                "native voice observations are too large"
            )
        return output_metadata
    except VoiceObservationCollectionError:
        raise
    except OSError as error:
        raise VoiceObservationCollectionError(
            "native voice driver did not produce observations"
        ) from error


def _bounded_directory_entry_names(
    directory: Path, maximum_entries: int
) -> set:
    names = set()
    with os.scandir(directory) as entries:
        for entry in entries:
            if len(names) >= maximum_entries or entry.name in names:
                raise VoiceObservationCollectionError(
                    "native voice driver produced too many staging entries"
                )
            names.add(entry.name)
    return names


def _read_bounded_regular_file(
    path: Path,
    maximum_bytes: int,
    expected_metadata,
) -> bytes:
    descriptor: Optional[int] = None
    try:
        path_metadata = path.lstat()
        if (
            not stat.S_ISREG(path_metadata.st_mode)
            or path_metadata.st_size < 0
            or path_metadata.st_size > maximum_bytes
            or _file_stat_identity(path_metadata)
            != _file_stat_identity(expected_metadata)
        ):
            raise VoiceObservationCollectionError(
                "bounded native collection input changed"
            )
        descriptor = os.open(
            path,
            os.O_RDONLY
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0)
            | getattr(os, "O_NONBLOCK", 0),
        )
        before = os.fstat(descriptor)
        if _file_stat_identity(before) != _file_stat_identity(path_metadata):
            raise VoiceObservationCollectionError(
                "bounded native collection input changed"
            )
        payload = bytearray()
        while len(payload) <= maximum_bytes:
            chunk = os.read(
                descriptor,
                min(65_536, maximum_bytes + 1 - len(payload)),
            )
            if not chunk:
                break
            payload.extend(chunk)
        after = os.fstat(descriptor)
        if (
            len(payload) > maximum_bytes
            or _file_stat_identity(before) != _file_stat_identity(after)
        ):
            raise VoiceObservationCollectionError(
                "bounded native collection input changed"
            )
        return bytes(payload)
    except VoiceObservationCollectionError:
        raise
    except OSError as error:
        raise VoiceObservationCollectionError(
            "cannot read bounded native collection input"
        ) from error
    finally:
        if descriptor is not None:
            try:
                os.close(descriptor)
            except OSError:
                pass


class _PinnedObservationSource:
    """A loader-compatible view over one already authenticated candidate fd."""

    def __init__(self, path: Path, descriptor: int, metadata) -> None:
        self.path = path
        self._descriptor: Optional[int] = descriptor
        self.metadata = metadata

    def __str__(self) -> str:
        return str(self.path)

    def open(self, mode: str):
        if mode != "rb":
            raise OSError(errno.EINVAL, "pinned observation source is read-only")
        try:
            descriptor = self._require_descriptor()
            self._require_unchanged()
            os.lseek(descriptor, 0, os.SEEK_SET)
            duplicate = os.dup(descriptor)
            try:
                self._require_unchanged()
                return os.fdopen(duplicate, "rb")
            except BaseException:
                os.close(duplicate)
                raise
        except VoiceObservationCollectionError as error:
            raise OSError(errno.EIO, "pinned observation source changed") from error

    def descriptor(self) -> int:
        return self._require_descriptor()

    def require_unchanged(self) -> None:
        self._require_unchanged()

    def close(self) -> None:
        if self._descriptor is None:
            return
        descriptor = self._descriptor
        self._descriptor = None
        try:
            os.close(descriptor)
        except OSError:
            pass

    def _require_descriptor(self) -> int:
        if self._descriptor is None:
            raise VoiceObservationCollectionError(
                "captured native voice observations are unavailable"
            )
        return self._descriptor

    def _require_unchanged(self) -> None:
        try:
            metadata = os.fstat(self._require_descriptor())
        except OSError as error:
            raise VoiceObservationCollectionError(
                "captured native voice observations are unavailable"
            ) from error
        if _file_stat_identity(metadata) != _file_stat_identity(self.metadata):
            raise VoiceObservationCollectionError(
                "captured native voice observations changed"
            )


def _capture_native_output(
    source: Path,
    source_metadata,
    destination: Path,
) -> _PinnedObservationSource:
    source_descriptor: Optional[int] = None
    destination_descriptor: Optional[int] = None
    try:
        current_source_metadata = source.lstat()
        if (
            not stat.S_ISREG(current_source_metadata.st_mode)
            or current_source_metadata.st_uid != os.geteuid()
            or stat.S_IMODE(current_source_metadata.st_mode) != 0o600
            or current_source_metadata.st_size < 0
            or current_source_metadata.st_size > _MAXIMUM_OBSERVATIONS_BYTES
            or _file_stat_identity(current_source_metadata)
            != _file_stat_identity(source_metadata)
        ):
            raise VoiceObservationCollectionError(
                "native voice observations changed before capture"
            )
        source_descriptor = os.open(
            source,
            os.O_RDONLY
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0)
            | getattr(os, "O_NONBLOCK", 0),
        )
        source_before = os.fstat(source_descriptor)
        if _file_stat_identity(source_before) != _file_stat_identity(
            current_source_metadata
        ):
            raise VoiceObservationCollectionError(
                "native voice observations changed before capture"
            )
        destination_descriptor = os.open(
            destination,
            os.O_RDWR
            | os.O_CREAT
            | os.O_EXCL
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0)
            | getattr(os, "O_NONBLOCK", 0),
            0o600,
        )
        copied = 0
        while copied <= _MAXIMUM_OBSERVATIONS_BYTES:
            chunk = os.read(
                source_descriptor,
                min(
                    1_048_576,
                    _MAXIMUM_OBSERVATIONS_BYTES + 1 - copied,
                ),
            )
            if not chunk:
                break
            copied += len(chunk)
            _write_all(destination_descriptor, chunk)
        source_after = os.fstat(source_descriptor)
        if (
            copied > _MAXIMUM_OBSERVATIONS_BYTES
            or copied != source_before.st_size
            or _file_stat_identity(source_before)
            != _file_stat_identity(source_after)
        ):
            raise VoiceObservationCollectionError(
                "native voice observations changed during capture"
            )
        os.fchmod(destination_descriptor, 0o600)
        os.fsync(destination_descriptor)
        destination_metadata = os.fstat(destination_descriptor)
        if (
            not stat.S_ISREG(destination_metadata.st_mode)
            or destination_metadata.st_uid != os.geteuid()
            or stat.S_IMODE(destination_metadata.st_mode) != 0o600
            or destination_metadata.st_size != copied
        ):
            raise VoiceObservationCollectionError(
                "cannot secure captured native voice observations"
            )
        candidate = _PinnedObservationSource(
            destination,
            destination_descriptor,
            destination_metadata,
        )
        destination_descriptor = None
        return candidate
    except VoiceObservationCollectionError:
        raise
    except OSError as error:
        raise VoiceObservationCollectionError(
            "cannot capture native voice observations"
        ) from error
    finally:
        if source_descriptor is not None:
            try:
                os.close(source_descriptor)
            except OSError:
                pass
        if destination_descriptor is not None:
            try:
                os.close(destination_descriptor)
            except OSError:
                pass


def _validate_native_output(
    source: _PinnedObservationSource,
    corpus: VoiceCorpus,
    run: Mapping[str, Any],
) -> None:
    try:
        observations = load_voice_observations(source, corpus, run)
        source.require_unchanged()
    except VoiceObservationCollectionError:
        raise
    except (VoiceEvaluationError, OSError) as error:
        raise VoiceObservationCollectionError(
            "native voice observations failed strict validation"
        ) from error
    if [value["sample_id"] for value in observations] != [
        sample.id for sample in corpus.samples
    ]:
        raise VoiceObservationCollectionError(
            "native voice observations are not in corpus order"
        )
    if any(
        value["outcome"] not in {"final", "no_result", "error"}
        or "resources" in value
        for value in observations
    ):
        raise VoiceObservationCollectionError(
            "native voice observations contain unsupported evidence"
        )


def _fsync_and_hash(source: _PinnedObservationSource) -> str:
    digest = hashlib.sha256()
    try:
        source.require_unchanged()
        descriptor = source.descriptor()
        before = os.fstat(descriptor)
        os.lseek(descriptor, 0, os.SEEK_SET)
        total = 0
        while True:
            chunk = os.read(
                descriptor,
                min(
                    1_048_576,
                    _MAXIMUM_OBSERVATIONS_BYTES + 1 - total,
                ),
            )
            if not chunk:
                break
            total += len(chunk)
            if total > _MAXIMUM_OBSERVATIONS_BYTES:
                raise VoiceObservationCollectionError(
                    "native voice observations changed before installation"
                )
            digest.update(chunk)
        os.fsync(descriptor)
        after = os.fstat(descriptor)
        if (
            total != before.st_size
            or _file_stat_identity(before) != _file_stat_identity(after)
            or _file_stat_identity(after) != _file_stat_identity(source.metadata)
        ):
            raise VoiceObservationCollectionError(
                "native voice observations changed before installation"
            )
    except VoiceObservationCollectionError:
        raise
    except OSError as error:
        raise VoiceObservationCollectionError(
            "cannot finalize native voice observations"
        ) from error
    return digest.hexdigest()


def _install_validated_output(
    candidate: Path,
    candidate_metadata,
    candidate_sha256: str,
    final_output: Path,
    parent: Path,
) -> None:
    directory_descriptor: Optional[int] = None
    committed = False
    try:
        directory_descriptor = os.open(
            parent,
            os.O_RDONLY
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_DIRECTORY", 0),
        )
        # Nothing has been mutated yet.  Failure to establish a durable parent
        # boundary therefore remains an ordinary no-commit error.
        os.fsync(directory_descriptor)
        current_candidate = candidate.lstat()
        if _file_stat_identity(current_candidate) != _file_stat_identity(
            candidate_metadata
        ):
            raise VoiceObservationCollectionError(
                "validated voice observations changed before commit"
            )

        # This same-directory rename is the irreversible commit point.  From
        # here onward an error must never be reported while a safely verifiable
        # new file is already installed.
        os.replace(candidate, final_output)
        committed = True
        try:
            os.fsync(directory_descriptor)
        except OSError as error:
            if _committed_output_matches(
                final_output,
                candidate_metadata,
                candidate_sha256,
            ):
                return
            raise VoiceObservationCollectionError(
                "voice observation installation is indeterminate"
            ) from error
    except VoiceObservationCollectionError:
        raise
    except OSError as error:
        if committed and not _committed_output_matches(
            final_output,
            candidate_metadata,
            candidate_sha256,
        ):
            raise VoiceObservationCollectionError(
                "voice observation installation is indeterminate"
            ) from error
        if committed:
            return
        raise VoiceObservationCollectionError(
            "cannot install voice observations"
        ) from error
    finally:
        if directory_descriptor is not None:
            try:
                os.close(directory_descriptor)
            except OSError:
                pass


def _committed_output_matches(
    path: Path,
    candidate_metadata,
    expected_sha256: str,
) -> bool:
    descriptor: Optional[int] = None
    try:
        path_metadata = path.lstat()
        if (
            not stat.S_ISREG(path_metadata.st_mode)
            or path_metadata.st_uid != os.geteuid()
            or stat.S_IMODE(path_metadata.st_mode) != 0o600
            or path_metadata.st_dev != candidate_metadata.st_dev
            or path_metadata.st_ino != candidate_metadata.st_ino
            or path_metadata.st_size != candidate_metadata.st_size
            or path_metadata.st_size < 0
            or path_metadata.st_size > _MAXIMUM_OBSERVATIONS_BYTES
        ):
            return False
        descriptor = os.open(
            path,
            os.O_RDONLY
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0)
            | getattr(os, "O_NONBLOCK", 0),
        )
        before = os.fstat(descriptor)
        if _file_stat_identity(before) != _file_stat_identity(path_metadata):
            return False
        digest = hashlib.sha256()
        total = 0
        while total <= _MAXIMUM_OBSERVATIONS_BYTES:
            chunk = os.read(
                descriptor,
                min(
                    1_048_576,
                    _MAXIMUM_OBSERVATIONS_BYTES + 1 - total,
                ),
            )
            if not chunk:
                break
            total += len(chunk)
            digest.update(chunk)
        after = os.fstat(descriptor)
        return (
            total == before.st_size
            and total <= _MAXIMUM_OBSERVATIONS_BYTES
            and _file_stat_identity(before) == _file_stat_identity(after)
            and digest.hexdigest() == expected_sha256
        )
    except OSError:
        return False
    finally:
        if descriptor is not None:
            try:
                os.close(descriptor)
            except OSError:
                pass


def _file_identity(path: Path):
    metadata = path.stat()
    return metadata.st_dev, metadata.st_ino


def _file_stat_identity(metadata):
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_uid,
        metadata.st_nlink,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )


def _directory_stat_identity(metadata):
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_uid,
    )
