from dataclasses import FrozenInstanceError
import hashlib
import json
from pathlib import Path
import wave

import pytest

from rimeai_eval.voice_dataset import VoiceDatasetError
from rimeai_eval.voice_dataset import load_voice_corpus


def _write_wav(
    path: Path,
    *,
    sample_rate_hz: int = 16_000,
    channels: int = 1,
    sample_width: int = 2,
    duration_ms: int = 100,
    sample_value: int = 0,
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    frame_count = sample_rate_hz * duration_ms // 1_000
    if sample_width == 2:
        encoded_sample = int(sample_value).to_bytes(
            2, "little", signed=True
        )
    else:
        encoded_sample = bytes([sample_value & 0xFF])
    frame = encoded_sample * channels
    with wave.open(str(path), "wb") as destination:
        destination.setnchannels(channels)
        destination.setsampwidth(sample_width)
        destination.setframerate(sample_rate_hz)
        destination.writeframes(frame * frame_count)


def _audio_record(
    root: Path,
    relative_path: str,
    *,
    sample_rate_hz: int = 16_000,
    channels: int = 1,
    duration_ms: float = 100.0,
) -> dict:
    path = root / relative_path
    return {
        "path": relative_path,
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "container": "wav",
        "encoding": "pcm_s16le",
        "sample_rate_hz": sample_rate_hz,
        "channels": channels,
        "duration_ms": duration_ms,
    }


def _sample(
    root: Path,
    sample_id: str = "sample-1",
    *,
    split: str = "test",
    speaker_group_id: str = "speaker-1",
    domain: str = "software",
    language: str = "mixed",
    reference: str = "我们需要 timeout 配置",
    terms: list = None,
    is_blank: bool = False,
    relative_audio_path: str = None,
    noise: str = "quiet",
    distance: str = "near_field",
) -> dict:
    if terms is None:
        terms = [
            {"text": "timeout", "match_mode": "ascii_casefold_word"}
        ]
    if relative_audio_path is None:
        relative_audio_path = "audio/%s.wav" % sample_id
    audio_path = root / relative_audio_path
    if not audio_path.exists():
        _write_wav(audio_path)
    return {
        "schema_version": 1,
        "id": sample_id,
        "split": split,
        "speaker_group_id": speaker_group_id,
        "domain": domain,
        "language_composition": language,
        "conditions": {"noise": noise, "distance": distance},
        "audio": _audio_record(root, relative_audio_path),
        "reference": reference,
        "terms": terms,
        "is_blank": is_blank,
    }


def _manifest(
    *,
    purpose: str = "fixture",
    synthetic_fixture: bool = True,
    rights: dict = None,
    authorized: bool = False,
    speaker_disjoint: bool = False,
) -> dict:
    return {
        "schema_version": 1,
        "corpus_id": "voice-fixture-v1",
        "purpose": purpose,
        "normalization_profile": "rimeai-voice-v1",
        "samples_file": "samples.jsonl",
        "synthetic_fixture": synthetic_fixture,
        "rights": rights,
        "quality_declarations": {
            "authorized_real_recordings": authorized,
            "speaker_disjoint_by_identity": speaker_disjoint,
        },
    }


def _write_corpus(
    root: Path,
    samples: list,
    *,
    manifest: dict = None,
    manifest_indent: int = None,
) -> None:
    root.mkdir(parents=True, exist_ok=True)
    if manifest is None:
        manifest = _manifest()
    (root / "manifest.json").write_text(
        json.dumps(
            manifest,
            ensure_ascii=False,
            sort_keys=True,
            indent=manifest_indent,
        )
        + "\n",
        encoding="utf-8",
    )
    (root / "samples.jsonl").write_text(
        "".join(
            json.dumps(sample, ensure_ascii=False, sort_keys=True) + "\n"
            for sample in samples
        ),
        encoding="utf-8",
    )


def _frozen_samples(
    root: Path,
    *,
    domains=("general", "software"),
    languages=("zh", "en", "mixed", "blank"),
    cover_common_noise: bool = True,
    cover_far_field: bool = True,
) -> list:
    shared_audio = root / "audio" / "shared.wav"
    _write_wav(shared_audio)
    samples = []
    for index in range(200):
        language = languages[index % len(languages)]
        if language == "blank":
            reference = ""
            terms = []
            is_blank = True
        elif language == "zh":
            reference = "这是测试"
            terms = []
            is_blank = False
        elif language == "en":
            reference = "timeout works"
            terms = [
                {"text": "timeout", "match_mode": "ascii_casefold_word"}
            ]
            is_blank = False
        else:
            reference = "增加 timeout 配置"
            terms = [
                {"text": "timeout", "match_mode": "ascii_casefold_word"}
            ]
            is_blank = False
        samples.append(
            _sample(
                root,
                "frozen-%03d" % index,
                speaker_group_id="speaker-%03d" % index,
                domain=domains[index % len(domains)],
                language=language,
                reference=reference,
                terms=terms,
                is_blank=is_blank,
                relative_audio_path="audio/shared.wav",
                noise=(
                    "common_noise"
                    if cover_common_noise and index % 2
                    else "quiet"
                ),
                distance=(
                    "far_field"
                    if cover_far_field and index % 3 == 0
                    else "near_field"
                ),
            )
        )
    return samples


def _frozen_manifest() -> dict:
    return _manifest(
        purpose="frozen_quality",
        synthetic_fixture=False,
        rights={
            "basis": "licensed_corpus",
            "record_ref": "license-review-v1",
        },
        authorized=True,
        speaker_disjoint=True,
    )


def test_loads_a_strict_immutable_fixture_corpus(tmp_path):
    root = tmp_path / "corpus"
    _write_corpus(root, [_sample(root)])

    corpus = load_voice_corpus(root, expected_profile="fixture")

    assert corpus.root == root.resolve()
    assert corpus.corpus_id == "voice-fixture-v1"
    assert corpus.purpose == "fixture"
    assert corpus.normalization_profile == "rimeai-voice-v1"
    assert corpus.synthetic_fixture is True
    assert len(corpus.samples) == 1
    assert isinstance(corpus.samples, tuple)
    assert corpus.samples[0].terms[0].text == "timeout"
    assert corpus.samples[0].audio.frame_count == 1_600
    assert len(corpus.fingerprint) == 64
    assert len(corpus.manifest_sha256) == 64
    assert len(corpus.samples_sha256) == 64
    with pytest.raises(FrozenInstanceError):
        corpus.manifest.purpose = "development"


def test_expected_profile_must_match_manifest_purpose(tmp_path):
    root = tmp_path / "corpus"
    _write_corpus(root, [_sample(root)])

    with pytest.raises(VoiceDatasetError, match="expected_profile"):
        load_voice_corpus(root, expected_profile="development")
    with pytest.raises(VoiceDatasetError, match="expected_profile is invalid"):
        load_voice_corpus(root, expected_profile="release")


def test_fixture_purpose_requires_synthetic_audio(tmp_path):
    root = tmp_path / "corpus"
    _write_corpus(
        root,
        [_sample(root)],
        manifest=_manifest(synthetic_fixture=False),
    )

    with pytest.raises(VoiceDatasetError, match="must be synthetic"):
        load_voice_corpus(root, expected_profile="fixture")


@pytest.mark.parametrize("separator", ["\u0085", "\u2028"])
def test_reference_unicode_separator_is_not_a_jsonl_boundary(
    tmp_path,
    separator,
):
    root = tmp_path / "corpus"
    reference = "alpha%stimeout" % separator
    sample = _sample(root, reference=reference)
    _write_corpus(root, [sample])

    corpus = load_voice_corpus(root)

    assert corpus.samples[0].reference == reference


def test_rejects_audio_path_traversal_without_echoing_sensitive_values(tmp_path):
    root = tmp_path / "corpus"
    root.mkdir()
    outside = tmp_path / "private-recording.wav"
    _write_wav(outside)
    sample = _sample(root)
    sample["reference"] = "secret reference phrase"
    sample["terms"] = []
    sample["audio"] = {
        **_audio_record(tmp_path, "private-recording.wav"),
        "path": "../private-recording.wav",
    }
    _write_corpus(root, [sample])

    with pytest.raises(VoiceDatasetError) as captured:
        load_voice_corpus(root)

    message = str(captured.value)
    assert "sample-1" in message
    assert "secret reference phrase" not in message
    assert "private-recording.wav" not in message


def test_rejects_audio_symlink_even_when_target_stays_inside_root(tmp_path):
    root = tmp_path / "corpus"
    target = root / "audio" / "target.wav"
    _write_wav(target)
    link = root / "audio" / "linked.wav"
    link.symlink_to(target.name)
    sample = _sample(root)
    sample["audio"] = {
        **_audio_record(root, "audio/linked.wav"),
        "path": "audio/linked.wav",
    }
    _write_corpus(root, [sample])

    with pytest.raises(VoiceDatasetError, match="symlink"):
        load_voice_corpus(root)


def test_rejects_audio_hash_mismatch_without_echoing_audio_path(tmp_path):
    root = tmp_path / "corpus"
    sample = _sample(root, relative_audio_path="audio/private-name.wav")
    sample["audio"]["sha256"] = "0" * 64
    _write_corpus(root, [sample])

    with pytest.raises(VoiceDatasetError) as captured:
        load_voice_corpus(root)

    assert "sha256 does not match" in str(captured.value)
    assert "private-name.wav" not in str(captured.value)


@pytest.mark.parametrize(
    ("actual_rate", "declared_rate", "sample_width", "error_pattern"),
    [
        (48_000, 16_000, 2, "WAV header"),
        (16_000, 16_000, 1, "WAV header"),
    ],
)
def test_rejects_wav_header_mismatch(
    tmp_path,
    actual_rate,
    declared_rate,
    sample_width,
    error_pattern,
):
    root = tmp_path / "corpus"
    audio_path = root / "audio" / "mismatch.wav"
    _write_wav(
        audio_path,
        sample_rate_hz=actual_rate,
        sample_width=sample_width,
    )
    sample = _sample(root)
    sample["audio"] = _audio_record(
        root,
        "audio/mismatch.wav",
        sample_rate_hz=declared_rate,
    )
    _write_corpus(root, [sample])

    with pytest.raises(VoiceDatasetError, match=error_pattern):
        load_voice_corpus(root)


def test_rejects_duration_that_disagrees_with_wav_frames(tmp_path):
    root = tmp_path / "corpus"
    sample = _sample(root)
    sample["audio"]["duration_ms"] = 99_999
    _write_corpus(root, [sample])

    with pytest.raises(VoiceDatasetError, match="duration"):
        load_voice_corpus(root)


def test_rejects_wav_with_truncated_pcm_frames(tmp_path):
    root = tmp_path / "corpus"
    sample = _sample(root)
    audio_path = root / sample["audio"]["path"]
    audio_path.write_bytes(audio_path.read_bytes()[:-2])
    sample["audio"] = _audio_record(root, sample["audio"]["path"])
    _write_corpus(root, [sample])

    with pytest.raises(VoiceDatasetError, match="WAV header"):
        load_voice_corpus(root)


def test_rejects_duplicate_sample_id(tmp_path):
    root = tmp_path / "corpus"
    first = _sample(root)
    second = _sample(root)
    _write_corpus(root, [first, second])

    with pytest.raises(VoiceDatasetError, match="duplicated"):
        load_voice_corpus(root)


def test_rejects_speaker_group_that_crosses_splits(tmp_path):
    root = tmp_path / "corpus"
    samples = [
        _sample(
            root,
            "sample-train",
            split="train",
            speaker_group_id="speaker-shared",
        ),
        _sample(
            root,
            "sample-test",
            split="test",
            speaker_group_id="speaker-shared",
        ),
    ]
    _write_corpus(root, samples)

    with pytest.raises(VoiceDatasetError, match="crosses dataset splits"):
        load_voice_corpus(root)


@pytest.mark.parametrize(
    ("language", "reference", "terms", "is_blank"),
    [
        ("blank", "unexpected words", [], True),
        ("blank", "", [{"text": "x", "match_mode": "exact"}], True),
        ("zh", "", [], False),
        ("blank", "", [], False),
    ],
)
def test_rejects_inconsistent_blank_reference_and_terms(
    tmp_path,
    language,
    reference,
    terms,
    is_blank,
):
    root = tmp_path / "corpus"
    sample = _sample(
        root,
        language=language,
        reference=reference,
        terms=terms,
        is_blank=is_blank,
    )
    _write_corpus(root, [sample])

    with pytest.raises(VoiceDatasetError, match="contract"):
        load_voice_corpus(root)


def test_frozen_quality_rejects_too_few_samples(tmp_path):
    root = tmp_path / "corpus"
    manifest = _manifest(
        purpose="frozen_quality",
        synthetic_fixture=False,
        rights={
            "basis": "participant_consent",
            "record_ref": "rights-review-v1",
        },
        authorized=True,
        speaker_disjoint=True,
    )
    _write_corpus(root, [_sample(root)], manifest=manifest)

    with pytest.raises(VoiceDatasetError, match="at least 200"):
        load_voice_corpus(root, expected_profile="frozen_quality")


@pytest.mark.parametrize(
    ("synthetic_fixture", "rights", "authorized", "speaker_disjoint", "match"),
    [
        (
            True,
            {"basis": "participant_consent", "record_ref": "r1"},
            True,
            True,
            "synthetic",
        ),
        (False, None, True, True, "requires rights"),
        (
            False,
            {"basis": "participant_consent", "record_ref": "r1"},
            False,
            True,
            "authorized",
        ),
        (
            False,
            {"basis": "participant_consent", "record_ref": "r1"},
            True,
            False,
            "speaker-disjoint",
        ),
    ],
)
def test_frozen_quality_requires_rights_and_declarations(
    tmp_path,
    synthetic_fixture,
    rights,
    authorized,
    speaker_disjoint,
    match,
):
    root = tmp_path / "corpus"
    manifest = _manifest(
        purpose="frozen_quality",
        synthetic_fixture=synthetic_fixture,
        rights=rights,
        authorized=authorized,
        speaker_disjoint=speaker_disjoint,
    )
    _write_corpus(root, [_sample(root)], manifest=manifest)

    with pytest.raises(VoiceDatasetError, match=match):
        load_voice_corpus(root)


def test_complete_frozen_quality_contract_shape_is_accepted(tmp_path):
    root = tmp_path / "corpus"
    _write_corpus(
        root,
        _frozen_samples(root),
        manifest=_frozen_manifest(),
    )

    corpus = load_voice_corpus(root, expected_profile="frozen_quality")

    assert len(corpus.samples) == 200
    assert corpus.purpose == "frozen_quality"


@pytest.mark.parametrize(
    ("sample_options", "error_pattern"),
    [
        ({"domains": ("general",)}, "domain coverage"),
        ({"languages": ("zh", "en", "mixed")}, "language coverage"),
        ({"cover_common_noise": False}, "noise coverage"),
        ({"cover_far_field": False}, "distance coverage"),
    ],
)
def test_frozen_quality_requires_all_mandated_subsets(
    tmp_path,
    sample_options,
    error_pattern,
):
    root = tmp_path / "corpus"
    _write_corpus(
        root,
        _frozen_samples(root, **sample_options),
        manifest=_frozen_manifest(),
    )

    with pytest.raises(VoiceDatasetError, match=error_pattern):
        load_voice_corpus(root, expected_profile="frozen_quality")


def test_fingerprint_binds_manifest_samples_and_actual_audio(tmp_path):
    root = tmp_path / "corpus"
    sample = _sample(root)
    manifest = _manifest()
    _write_corpus(root, [sample], manifest=manifest)
    original = load_voice_corpus(root)

    _write_corpus(root, [sample], manifest=manifest, manifest_indent=2)
    manifest_changed = load_voice_corpus(root)
    assert manifest_changed.fingerprint != original.fingerprint

    changed_sample = dict(sample)
    changed_sample["reference"] = "我们需要 timeout 配置。"
    _write_corpus(root, [changed_sample], manifest=manifest, manifest_indent=2)
    sample_changed = load_voice_corpus(root)
    assert sample_changed.fingerprint != manifest_changed.fingerprint

    audio_path = root / sample["audio"]["path"]
    _write_wav(audio_path, sample_value=123)
    changed_sample["audio"] = _audio_record(root, sample["audio"]["path"])
    _write_corpus(root, [changed_sample], manifest=manifest, manifest_indent=2)
    audio_changed = load_voice_corpus(root)
    assert audio_changed.fingerprint != sample_changed.fingerprint


def test_rejects_illegal_speaker_id_without_echoing_it(tmp_path):
    root = tmp_path / "corpus"
    sample = _sample(
        root,
        speaker_group_id="Alice Person <alice@example.invalid>",
    )
    _write_corpus(root, [sample])

    with pytest.raises(VoiceDatasetError) as captured:
        load_voice_corpus(root)

    message = str(captured.value)
    assert "speaker_group_id" in message
    assert "Alice" not in message
    assert "example.invalid" not in message


def test_rejects_unknown_schema_fields(tmp_path):
    root = tmp_path / "corpus"
    sample = _sample(root)
    sample["free_form_note"] = "must not enter the schema"
    _write_corpus(root, [sample])

    with pytest.raises(VoiceDatasetError, match="sample fields are invalid"):
        load_voice_corpus(root)


def test_rejects_duplicate_json_fields(tmp_path):
    root = tmp_path / "corpus"
    _write_corpus(root, [_sample(root)])
    samples_path = root / "samples.jsonl"
    samples_path.write_text(
        samples_path.read_text(encoding="utf-8").replace(
            '"id": "sample-1"',
            '"id": "sample-1", "id": "shadow-id"',
            1,
        ),
        encoding="utf-8",
    )

    with pytest.raises(VoiceDatasetError, match="valid JSON"):
        load_voice_corpus(root)


def test_rejects_boolean_schema_version(tmp_path):
    root = tmp_path / "corpus"
    sample = _sample(root)
    sample["schema_version"] = True
    _write_corpus(root, [sample])

    with pytest.raises(VoiceDatasetError, match="schema_version"):
        load_voice_corpus(root)


def test_rejects_noncanonical_relative_audio_path(tmp_path):
    root = tmp_path / "corpus"
    sample = _sample(root)
    sample["audio"]["path"] = "./audio/sample-1.wav"
    _write_corpus(root, [sample])

    with pytest.raises(VoiceDatasetError, match="inside corpus root"):
        load_voice_corpus(root)
