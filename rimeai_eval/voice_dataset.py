"""Strict, privacy-conscious loader for frozen voice evaluation corpora."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
import math
from pathlib import Path, PurePosixPath
import re
import stat
from typing import Any, Dict, List, Optional, Set, Tuple
import wave


_SCHEMA_VERSION = 1
_NORMALIZATION_PROFILE = "rimeai-voice-v1"
_MANIFEST_KEYS = {
    "schema_version",
    "corpus_id",
    "purpose",
    "normalization_profile",
    "samples_file",
    "synthetic_fixture",
    "rights",
    "quality_declarations",
}
_SAMPLE_KEYS = {
    "schema_version",
    "id",
    "split",
    "speaker_group_id",
    "domain",
    "language_composition",
    "conditions",
    "audio",
    "reference",
    "terms",
    "is_blank",
}
_CONDITION_KEYS = {"noise", "distance"}
_AUDIO_KEYS = {
    "path",
    "sha256",
    "container",
    "encoding",
    "sample_rate_hz",
    "channels",
    "duration_ms",
}
_TERM_KEYS = {"text", "match_mode"}
_RIGHTS_KEYS = {"basis", "record_ref"}
_DECLARATION_KEYS = {
    "authorized_real_recordings",
    "speaker_disjoint_by_identity",
}

_PURPOSES = {"fixture", "development", "frozen_quality"}
_SPLITS = {"train", "validation", "test"}
_DOMAINS = {"general", "software"}
_LANGUAGE_COMPOSITIONS = {"zh", "en", "mixed", "blank"}
_NOISE_CONDITIONS = {
    "quiet",
    "common_noise",
    "keyboard_noise",
    "fan_noise",
    "other",
}
_DISTANCE_CONDITIONS = {"near_field", "far_field"}
_TERM_MATCH_MODES = {"exact", "ascii_casefold_word"}
_RIGHTS_BASES = {"participant_consent", "licensed_corpus"}
_SAMPLE_RATES = {16_000, 44_100, 48_000}
_CHANNEL_COUNTS = {1, 2}

_CONTROLLED_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}\Z")
_SHA256 = re.compile(r"[0-9a-f]{64}\Z")
_ASCII_WORD = re.compile(r"[A-Za-z0-9_]+\Z")
_MAX_REFERENCE_CHARACTERS = 4_096
_MAX_TERM_CHARACTERS = 256
_MINIMUM_FROZEN_SAMPLES = 200


class _InvalidJSON(ValueError):
    pass


class VoiceDatasetError(ValueError):
    """A corpus error that never includes raw text or audio paths."""

    def __init__(
        self,
        source: str,
        line_number: Optional[int],
        message: str,
        *,
        sample_id: Optional[str] = None,
    ) -> None:
        super().__init__(message)
        self.source = source
        self.line_number = line_number
        self.message = message
        self.sample_id = sample_id

    def __str__(self) -> str:
        location = self.source
        if self.line_number is not None:
            location += ":%d" % self.line_number
        if self.sample_id is not None:
            location += " [sample %s]" % self.sample_id
        return "%s: %s" % (location, self.message)


@dataclass(frozen=True)
class VoiceRights:
    basis: str
    record_ref: str


@dataclass(frozen=True)
class VoiceQualityDeclarations:
    authorized_real_recordings: bool
    speaker_disjoint_by_identity: bool


@dataclass(frozen=True)
class VoiceManifest:
    schema_version: int
    corpus_id: str
    purpose: str
    normalization_profile: str
    samples_file: str
    synthetic_fixture: bool
    rights: Optional[VoiceRights]
    quality_declarations: VoiceQualityDeclarations


@dataclass(frozen=True)
class VoiceTerm:
    text: str
    match_mode: str


@dataclass(frozen=True)
class VoiceConditions:
    noise: str
    distance: str


@dataclass(frozen=True)
class VoiceAudio:
    path: Path
    sha256: str
    duration_ms: float
    sample_rate_hz: int
    channels: int
    frame_count: int


@dataclass(frozen=True)
class VoiceSample:
    id: str
    split: str
    speaker_group_id: str
    domain: str
    language_composition: str
    conditions: VoiceConditions
    audio: VoiceAudio
    reference: str
    terms: Tuple[VoiceTerm, ...]
    is_blank: bool


@dataclass(frozen=True)
class VoiceCorpus:
    root: Path
    manifest: VoiceManifest
    samples: Tuple[VoiceSample, ...]
    fingerprint: str
    manifest_sha256: str
    samples_sha256: str

    @property
    def corpus_id(self) -> str:
        return self.manifest.corpus_id

    @property
    def purpose(self) -> str:
        return self.manifest.purpose

    @property
    def normalization_profile(self) -> str:
        return self.manifest.normalization_profile

    @property
    def synthetic_fixture(self) -> bool:
        return self.manifest.synthetic_fixture


def load_voice_corpus(
    root: Path,
    expected_profile: Optional[str] = None,
) -> VoiceCorpus:
    """Load and fully validate ``manifest.json`` plus its samples/audio."""

    if expected_profile is not None and (
        not isinstance(expected_profile, str)
        or expected_profile not in _PURPOSES
    ):
        raise VoiceDatasetError(
            "manifest.json", None, "expected_profile is invalid"
        )

    root_path = Path(root)
    try:
        resolved_root = root_path.resolve(strict=True)
    except OSError:
        raise VoiceDatasetError(
            "voice corpus", None, "root is not readable"
        ) from None
    if not resolved_root.is_dir():
        raise VoiceDatasetError(
            "voice corpus", None, "root must be a directory"
        )

    manifest_raw = _read_control_file(
        resolved_root / "manifest.json", "manifest.json"
    )
    manifest_value = _decode_json_object(
        manifest_raw, source="manifest.json", line_number=None
    )
    manifest = _validate_manifest(manifest_value)
    if expected_profile is not None and manifest.purpose != expected_profile:
        raise VoiceDatasetError(
            "manifest.json",
            None,
            "purpose does not match expected_profile",
        )

    samples_path = resolved_root / manifest.samples_file
    samples_raw = _read_control_file(samples_path, "samples.jsonl")
    samples = _load_samples(samples_raw, resolved_root)
    _validate_corpus_invariants(manifest, samples)

    manifest_sha256 = hashlib.sha256(manifest_raw).hexdigest()
    samples_sha256 = hashlib.sha256(samples_raw).hexdigest()
    fingerprint = _corpus_fingerprint(
        manifest_raw=manifest_raw,
        samples_raw=samples_raw,
        samples=samples,
    )
    return VoiceCorpus(
        root=resolved_root,
        manifest=manifest,
        samples=tuple(samples),
        fingerprint=fingerprint,
        manifest_sha256=manifest_sha256,
        samples_sha256=samples_sha256,
    )


def _read_control_file(path: Path, source: str) -> bytes:
    try:
        if path.is_symlink():
            raise VoiceDatasetError(source, None, "file must not be a symlink")
        metadata = path.stat()
        if not stat.S_ISREG(metadata.st_mode):
            raise VoiceDatasetError(source, None, "file must be a regular file")
        return path.read_bytes()
    except VoiceDatasetError:
        raise
    except OSError:
        raise VoiceDatasetError(source, None, "file is not readable") from None


def _decode_json_object(
    raw: bytes,
    *,
    source: str,
    line_number: Optional[int],
) -> Dict[str, Any]:
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        raise VoiceDatasetError(
            source, line_number, "content must be valid UTF-8"
        ) from None
    try:
        value = _strict_json_loads(text)
    except (json.JSONDecodeError, _InvalidJSON):
        raise VoiceDatasetError(
            source, line_number, "content must be valid JSON"
        ) from None
    if not isinstance(value, dict):
        raise VoiceDatasetError(source, line_number, "value must be an object")
    return value


def _validate_manifest(value: Dict[str, Any]) -> VoiceManifest:
    _require_exact_keys(
        value,
        _MANIFEST_KEYS,
        source="manifest.json",
        line_number=None,
        label="manifest",
    )
    if (
        type(value.get("schema_version")) is not int
        or value["schema_version"] != _SCHEMA_VERSION
    ):
        raise VoiceDatasetError(
            "manifest.json", None, "schema_version must be 1"
        )
    corpus_id = _controlled_id(
        value.get("corpus_id"),
        source="manifest.json",
        line_number=None,
        label="corpus_id",
    )
    purpose = value.get("purpose")
    if not isinstance(purpose, str) or purpose not in _PURPOSES:
        raise VoiceDatasetError("manifest.json", None, "purpose is invalid")
    if value.get("normalization_profile") != _NORMALIZATION_PROFILE:
        raise VoiceDatasetError(
            "manifest.json", None, "normalization_profile is unsupported"
        )
    if value.get("samples_file") != "samples.jsonl":
        raise VoiceDatasetError(
            "manifest.json", None, "samples_file must be samples.jsonl"
        )
    synthetic_fixture = value.get("synthetic_fixture")
    if not isinstance(synthetic_fixture, bool):
        raise VoiceDatasetError(
            "manifest.json", None, "synthetic_fixture must be boolean"
        )

    rights_value = value.get("rights")
    rights: Optional[VoiceRights]
    if rights_value is None:
        rights = None
    else:
        if not isinstance(rights_value, dict):
            raise VoiceDatasetError(
                "manifest.json", None, "rights must be an object or null"
            )
        _require_exact_keys(
            rights_value,
            _RIGHTS_KEYS,
            source="manifest.json",
            line_number=None,
            label="rights",
        )
        basis = rights_value.get("basis")
        if not isinstance(basis, str) or basis not in _RIGHTS_BASES:
            raise VoiceDatasetError(
                "manifest.json", None, "rights basis is invalid"
            )
        record_ref = _controlled_id(
            rights_value.get("record_ref"),
            source="manifest.json",
            line_number=None,
            label="rights record_ref",
        )
        rights = VoiceRights(basis=basis, record_ref=record_ref)

    declarations_value = value.get("quality_declarations")
    if not isinstance(declarations_value, dict):
        raise VoiceDatasetError(
            "manifest.json",
            None,
            "quality_declarations must be an object",
        )
    _require_exact_keys(
        declarations_value,
        _DECLARATION_KEYS,
        source="manifest.json",
        line_number=None,
        label="quality_declarations",
    )
    authorized = declarations_value.get("authorized_real_recordings")
    speaker_disjoint = declarations_value.get("speaker_disjoint_by_identity")
    if not isinstance(authorized, bool) or not isinstance(
        speaker_disjoint, bool
    ):
        raise VoiceDatasetError(
            "manifest.json",
            None,
            "quality declaration values must be boolean",
        )

    return VoiceManifest(
        schema_version=_SCHEMA_VERSION,
        corpus_id=corpus_id,
        purpose=purpose,
        normalization_profile=_NORMALIZATION_PROFILE,
        samples_file="samples.jsonl",
        synthetic_fixture=synthetic_fixture,
        rights=rights,
        quality_declarations=VoiceQualityDeclarations(
            authorized_real_recordings=authorized,
            speaker_disjoint_by_identity=speaker_disjoint,
        ),
    )


def _load_samples(raw: bytes, root: Path) -> List[VoiceSample]:
    samples: List[VoiceSample] = []
    sample_ids: Set[str] = set()
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        raise VoiceDatasetError(
            "samples.jsonl", None, "content must be valid UTF-8"
        ) from None
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    for line_number, line in enumerate(lines, start=1):
        if not line.strip():
            raise VoiceDatasetError(
                "samples.jsonl", line_number, "line must not be blank"
            )
        try:
            value = _strict_json_loads(line)
        except (json.JSONDecodeError, _InvalidJSON):
            raise VoiceDatasetError(
                "samples.jsonl", line_number, "line must be valid JSON"
            ) from None
        if not isinstance(value, dict):
            raise VoiceDatasetError(
                "samples.jsonl", line_number, "sample must be an object"
            )
        sample = _validate_sample(value, root=root, line_number=line_number)
        if sample.id in sample_ids:
            raise VoiceDatasetError(
                "samples.jsonl",
                line_number,
                "sample id is duplicated",
                sample_id=sample.id,
            )
        sample_ids.add(sample.id)
        samples.append(sample)
    if not samples:
        raise VoiceDatasetError(
            "samples.jsonl", None, "corpus contains no samples"
        )
    return samples


def _validate_sample(
    value: Dict[str, Any],
    *,
    root: Path,
    line_number: int,
) -> VoiceSample:
    _require_exact_keys(
        value,
        _SAMPLE_KEYS,
        source="samples.jsonl",
        line_number=line_number,
        label="sample",
    )
    if (
        type(value.get("schema_version")) is not int
        or value["schema_version"] != _SCHEMA_VERSION
    ):
        raise VoiceDatasetError(
            "samples.jsonl", line_number, "schema_version must be 1"
        )
    sample_id = _controlled_id(
        value.get("id"),
        source="samples.jsonl",
        line_number=line_number,
        label="id",
    )
    error_context = {
        "source": "samples.jsonl",
        "line_number": line_number,
        "sample_id": sample_id,
    }
    split = value.get("split")
    if not isinstance(split, str) or split not in _SPLITS:
        raise VoiceDatasetError(
            message="split is invalid", **error_context
        )
    speaker_group_id = _controlled_id(
        value.get("speaker_group_id"),
        label="speaker_group_id",
        **error_context,
    )
    domain = value.get("domain")
    if not isinstance(domain, str) or domain not in _DOMAINS:
        raise VoiceDatasetError(
            message="domain is invalid", **error_context
        )
    language = value.get("language_composition")
    if not isinstance(language, str) or language not in _LANGUAGE_COMPOSITIONS:
        raise VoiceDatasetError(
            message="language_composition is invalid", **error_context
        )

    conditions_value = value.get("conditions")
    if not isinstance(conditions_value, dict):
        raise VoiceDatasetError(
            message="conditions must be an object", **error_context
        )
    _require_exact_keys(
        conditions_value,
        _CONDITION_KEYS,
        label="conditions",
        **error_context,
    )
    noise = conditions_value.get("noise")
    distance = conditions_value.get("distance")
    if not isinstance(noise, str) or noise not in _NOISE_CONDITIONS:
        raise VoiceDatasetError(
            message="noise condition is invalid", **error_context
        )
    if not isinstance(distance, str) or distance not in _DISTANCE_CONDITIONS:
        raise VoiceDatasetError(
            message="distance condition is invalid", **error_context
        )

    reference = value.get("reference")
    if (
        not isinstance(reference, str)
        or "\n" in reference
        or "\r" in reference
        or len(reference) > _MAX_REFERENCE_CHARACTERS
    ):
        raise VoiceDatasetError(
            message="reference does not satisfy the text contract",
            **error_context,
        )
    is_blank = value.get("is_blank")
    if not isinstance(is_blank, bool):
        raise VoiceDatasetError(
            message="is_blank must be boolean", **error_context
        )
    raw_terms = value.get("terms")
    if is_blank and (
        language != "blank" or reference or raw_terms != []
    ):
        raise VoiceDatasetError(
            message="blank sample contract is inconsistent",
            **error_context,
        )
    if not is_blank and (language == "blank" or not reference):
        raise VoiceDatasetError(
            message="non-blank sample contract is inconsistent",
            **error_context,
        )
    terms = _validate_terms(
        raw_terms,
        reference=reference,
        **error_context,
    )

    audio_value = value.get("audio")
    if not isinstance(audio_value, dict):
        raise VoiceDatasetError(
            message="audio must be an object", **error_context
        )
    audio = _validate_audio(
        audio_value,
        root=root,
        **error_context,
    )
    return VoiceSample(
        id=sample_id,
        split=split,
        speaker_group_id=speaker_group_id,
        domain=domain,
        language_composition=language,
        conditions=VoiceConditions(noise=noise, distance=distance),
        audio=audio,
        reference=reference,
        terms=terms,
        is_blank=is_blank,
    )


def _validate_terms(
    value: Any,
    *,
    reference: str,
    source: str,
    line_number: int,
    sample_id: str,
) -> Tuple[VoiceTerm, ...]:
    context = {
        "source": source,
        "line_number": line_number,
        "sample_id": sample_id,
    }
    if not isinstance(value, list):
        raise VoiceDatasetError(message="terms must be an array", **context)
    terms: List[VoiceTerm] = []
    identities: Set[Tuple[str, str]] = set()
    for term_value in value:
        if not isinstance(term_value, dict):
            raise VoiceDatasetError(
                message="term must be an object", **context
            )
        _require_exact_keys(
            term_value,
            _TERM_KEYS,
            label="term",
            **context,
        )
        text = term_value.get("text")
        match_mode = term_value.get("match_mode")
        if (
            not isinstance(text, str)
            or not text
            or len(text) > _MAX_TERM_CHARACTERS
            or "\n" in text
            or "\r" in text
        ):
            raise VoiceDatasetError(
                message="term text is invalid", **context
            )
        if (
            not isinstance(match_mode, str)
            or match_mode not in _TERM_MATCH_MODES
        ):
            raise VoiceDatasetError(
                message="term match_mode is invalid", **context
            )
        if match_mode == "ascii_casefold_word":
            if not text.isascii() or _ASCII_WORD.fullmatch(text) is None:
                raise VoiceDatasetError(
                    message="ASCII word term is invalid", **context
                )
            escaped = re.escape(text.casefold())
            if re.search(
                r"(?<![a-z0-9_])%s(?![a-z0-9_])" % escaped,
                reference.casefold(),
            ) is None:
                raise VoiceDatasetError(
                    message="term is absent from reference", **context
                )
        elif text not in reference:
            raise VoiceDatasetError(
                message="term is absent from reference", **context
            )
        identity_text = (
            text.casefold() if match_mode == "ascii_casefold_word" else text
        )
        identity = (identity_text, match_mode)
        if identity in identities:
            raise VoiceDatasetError(
                message="term annotation is duplicated", **context
            )
        identities.add(identity)
        terms.append(VoiceTerm(text=text, match_mode=match_mode))
    return tuple(terms)


def _validate_audio(
    value: Dict[str, Any],
    *,
    root: Path,
    source: str,
    line_number: int,
    sample_id: str,
) -> VoiceAudio:
    context = {
        "source": source,
        "line_number": line_number,
        "sample_id": sample_id,
    }
    _require_exact_keys(value, _AUDIO_KEYS, label="audio", **context)
    relative_value = value.get("path")
    audio_path = _resolve_audio_path(relative_value, root=root, **context)

    expected_sha256 = value.get("sha256")
    if not isinstance(expected_sha256, str) or _SHA256.fullmatch(
        expected_sha256
    ) is None:
        raise VoiceDatasetError(message="audio sha256 is invalid", **context)
    actual_sha256 = _sha256_file(audio_path, context)
    if actual_sha256 != expected_sha256:
        raise VoiceDatasetError(
            message="audio sha256 does not match", **context
        )
    if value.get("container") != "wav":
        raise VoiceDatasetError(
            message="audio container must be wav", **context
        )
    if value.get("encoding") != "pcm_s16le":
        raise VoiceDatasetError(
            message="audio encoding must be pcm_s16le", **context
        )
    sample_rate = value.get("sample_rate_hz")
    if type(sample_rate) is not int or sample_rate not in _SAMPLE_RATES:
        raise VoiceDatasetError(
            message="audio sample_rate_hz is invalid", **context
        )
    channels = value.get("channels")
    if type(channels) is not int or channels not in _CHANNEL_COUNTS:
        raise VoiceDatasetError(
            message="audio channels is invalid", **context
        )
    duration = value.get("duration_ms")
    if not _is_finite_number(duration) or duration <= 0:
        raise VoiceDatasetError(
            message="audio duration_ms is invalid", **context
        )

    actual_audio_bytes: Optional[int] = None
    expected_audio_bytes: Optional[int] = None
    try:
        with wave.open(str(audio_path), "rb") as audio_file:
            actual_channels = audio_file.getnchannels()
            sample_width = audio_file.getsampwidth()
            actual_sample_rate = audio_file.getframerate()
            frame_count = audio_file.getnframes()
            compression = audio_file.getcomptype()
            if (
                compression == "NONE"
                and sample_width == 2
                and actual_channels == channels
                and actual_sample_rate == sample_rate
                and frame_count > 0
            ):
                expected_audio_bytes = frame_count * actual_channels * sample_width
                actual_audio_bytes = 0
                while actual_audio_bytes < expected_audio_bytes:
                    chunk = audio_file.readframes(min(frame_count, 65_536))
                    if not chunk:
                        break
                    actual_audio_bytes += len(chunk)
    except (OSError, EOFError, OverflowError, wave.Error):
        raise VoiceDatasetError(
            message="audio is not a readable PCM WAV", **context
        ) from None
    if (
        compression != "NONE"
        or sample_width != 2
        or actual_channels != channels
        or actual_sample_rate != sample_rate
        or frame_count <= 0
        or actual_audio_bytes != expected_audio_bytes
    ):
        raise VoiceDatasetError(
            message="audio WAV header does not match manifest", **context
        )
    actual_duration = frame_count * 1_000.0 / actual_sample_rate
    duration_tolerance = max(0.01, 1_000.0 / actual_sample_rate)
    if abs(float(duration) - actual_duration) > duration_tolerance:
        raise VoiceDatasetError(
            message="audio duration does not match WAV header", **context
        )
    return VoiceAudio(
        path=audio_path,
        sha256=actual_sha256,
        duration_ms=actual_duration,
        sample_rate_hz=actual_sample_rate,
        channels=actual_channels,
        frame_count=frame_count,
    )


def _resolve_audio_path(
    value: Any,
    *,
    root: Path,
    source: str,
    line_number: int,
    sample_id: str,
) -> Path:
    context = {
        "source": source,
        "line_number": line_number,
        "sample_id": sample_id,
    }
    if (
        not isinstance(value, str)
        or not value
        or len(value) > 512
        or "\\" in value
        or "\n" in value
        or "\r" in value
    ):
        raise VoiceDatasetError(message="audio path is invalid", **context)
    relative = PurePosixPath(value)
    if (
        relative.is_absolute()
        or any(
            component in {"", ".", ".."} for component in relative.parts
        )
        or relative.as_posix() != value
    ):
        raise VoiceDatasetError(
            message="audio path must stay inside corpus root", **context
        )

    candidate = root
    try:
        for component in relative.parts:
            candidate = candidate / component
            if candidate.is_symlink():
                raise VoiceDatasetError(
                    message="audio path must not contain symlinks", **context
                )
        resolved = candidate.resolve(strict=True)
        resolved.relative_to(root)
        metadata = resolved.stat()
    except VoiceDatasetError:
        raise
    except (OSError, ValueError):
        raise VoiceDatasetError(
            message="audio file is not a readable regular file", **context
        ) from None
    if not stat.S_ISREG(metadata.st_mode):
        raise VoiceDatasetError(
            message="audio file must be a regular file", **context
        )
    return resolved


def _sha256_file(path: Path, context: Dict[str, Any]) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as source:
            while True:
                chunk = source.read(1024 * 1024)
                if not chunk:
                    break
                digest.update(chunk)
    except OSError:
        raise VoiceDatasetError(
            message="audio file is not readable", **context
        ) from None
    return digest.hexdigest()


def _validate_corpus_invariants(
    manifest: VoiceManifest,
    samples: List[VoiceSample],
) -> None:
    speaker_splits: Dict[str, str] = {}
    for sample in samples:
        existing_split = speaker_splits.setdefault(
            sample.speaker_group_id, sample.split
        )
        if existing_split != sample.split:
            raise VoiceDatasetError(
                "samples.jsonl",
                None,
                "speaker group crosses dataset splits",
                sample_id=sample.id,
            )

    if manifest.purpose == "fixture":
        if not manifest.synthetic_fixture:
            raise VoiceDatasetError(
                "manifest.json",
                None,
                "fixture corpus must be synthetic",
            )
        return
    if manifest.purpose != "frozen_quality":
        return
    if manifest.synthetic_fixture:
        raise VoiceDatasetError(
            "manifest.json",
            None,
            "frozen_quality corpus must not be synthetic",
        )
    if manifest.rights is None:
        raise VoiceDatasetError(
            "manifest.json", None, "frozen_quality corpus requires rights"
        )
    declarations = manifest.quality_declarations
    if not declarations.authorized_real_recordings:
        raise VoiceDatasetError(
            "manifest.json",
            None,
            "frozen_quality corpus requires authorized real recordings",
        )
    if not declarations.speaker_disjoint_by_identity:
        raise VoiceDatasetError(
            "manifest.json",
            None,
            "frozen_quality corpus requires speaker-disjoint identity review",
        )
    if len(samples) < _MINIMUM_FROZEN_SAMPLES:
        raise VoiceDatasetError(
            "samples.jsonl",
            None,
            "frozen_quality corpus requires at least 200 samples",
        )
    if {sample.domain for sample in samples} != _DOMAINS:
        raise VoiceDatasetError(
            "samples.jsonl",
            None,
            "frozen_quality corpus lacks required domain coverage",
        )
    if {
        sample.language_composition for sample in samples
    } != _LANGUAGE_COMPOSITIONS:
        raise VoiceDatasetError(
            "samples.jsonl",
            None,
            "frozen_quality corpus lacks required language coverage",
        )
    noise_conditions = {sample.conditions.noise for sample in samples}
    if not {"quiet", "common_noise"}.issubset(noise_conditions):
        raise VoiceDatasetError(
            "samples.jsonl",
            None,
            "frozen_quality corpus lacks required noise coverage",
        )
    distance_conditions = {sample.conditions.distance for sample in samples}
    if not {"near_field", "far_field"}.issubset(distance_conditions):
        raise VoiceDatasetError(
            "samples.jsonl",
            None,
            "frozen_quality corpus lacks required distance coverage",
        )


def _corpus_fingerprint(
    *,
    manifest_raw: bytes,
    samples_raw: bytes,
    samples: List[VoiceSample],
) -> str:
    digest = hashlib.sha256()
    digest.update(b"rimeai-voice-corpus-v1\0")
    _update_hash_component(digest, b"manifest", manifest_raw)
    _update_hash_component(digest, b"samples", samples_raw)
    for sample in sorted(samples, key=lambda item: item.id):
        _update_hash_component(digest, b"sample-id", sample.id.encode("ascii"))
        _update_hash_component(
            digest,
            b"audio-sha256",
            bytes.fromhex(sample.audio.sha256),
        )
    return digest.hexdigest()


def _update_hash_component(
    digest: Any,
    label: bytes,
    payload: bytes,
) -> None:
    digest.update(len(label).to_bytes(4, "big"))
    digest.update(label)
    digest.update(len(payload).to_bytes(8, "big"))
    digest.update(payload)


def _strict_json_loads(text: str) -> Any:
    def object_from_pairs(pairs: List[Tuple[str, Any]]) -> Dict[str, Any]:
        result: Dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                raise _InvalidJSON()
            result[key] = value
        return result

    def reject_constant(_: str) -> Any:
        raise _InvalidJSON()

    return json.loads(
        text,
        object_pairs_hook=object_from_pairs,
        parse_constant=reject_constant,
    )


def _controlled_id(
    value: Any,
    *,
    source: str,
    line_number: Optional[int],
    label: str,
    sample_id: Optional[str] = None,
) -> str:
    if not isinstance(value, str) or _CONTROLLED_ID.fullmatch(value) is None:
        raise VoiceDatasetError(
            source,
            line_number,
            "%s must be a controlled identifier" % label,
            sample_id=sample_id,
        )
    return value


def _require_exact_keys(
    value: Dict[str, Any],
    expected: Set[str],
    *,
    source: str,
    line_number: Optional[int],
    label: str,
    sample_id: Optional[str] = None,
) -> None:
    if set(value) != expected:
        raise VoiceDatasetError(
            source,
            line_number,
            "%s fields are invalid" % label,
            sample_id=sample_id,
        )


def _is_finite_number(value: Any) -> bool:
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        return False
    try:
        return math.isfinite(value)
    except OverflowError:
        return False
