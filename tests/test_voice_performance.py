import json
import hashlib
from dataclasses import replace
from pathlib import Path

import pytest

from rimeai_eval.voice_dataset import VoiceAudio
from rimeai_eval.voice_dataset import VoiceConditions
from rimeai_eval.voice_dataset import VoiceCorpus
from rimeai_eval.voice_dataset import VoiceManifest
from rimeai_eval.voice_dataset import VoiceQualityDeclarations
from rimeai_eval.voice_dataset import VoiceRights
from rimeai_eval.voice_dataset import VoiceSample
from rimeai_eval.voice_performance import aggregate_voice_performance
from rimeai_eval.voice_performance import load_voice_performance
from rimeai_eval.voice_performance import VoicePerformanceError
from rimeai_eval.voice_performance import voice_performance_sha256
from rimeai_eval.voice_performance import voice_run_sha256


PROCESS_ROLES = ("input_method", "candidate_service", "voice_helper")


def _corpus() -> VoiceCorpus:
    manifest = VoiceManifest(
        schema_version=1,
        corpus_id="voice-performance-v1",
        purpose="frozen_quality",
        normalization_profile="rimeai-voice-v1",
        samples_file="samples.jsonl",
        synthetic_fixture=False,
        rights=VoiceRights(
            basis="participant_consent",
            record_ref="controlled-rights-record",
        ),
        quality_declarations=VoiceQualityDeclarations(
            authorized_real_recordings=True,
            speaker_disjoint_by_identity=True,
        ),
    )
    sample = VoiceSample(
        id="voice-000001",
        split="test",
        speaker_group_id="private-speaker",
        domain="software",
        language_composition="mixed",
        conditions=VoiceConditions(noise="quiet", distance="near_field"),
        audio=VoiceAudio(
            path=Path("/private/audio/voice-000001.wav"),
            sha256="9" * 64,
            duration_ms=1_000.0,
            sample_rate_hz=16_000,
            channels=1,
            frame_count=16_000,
        ),
        reference="private reference",
        terms=(),
        is_blank=False,
    )
    return VoiceCorpus(
        root=Path("/private/corpus"),
        manifest=manifest,
        samples=(sample,),
        fingerprint="a" * 64,
        manifest_sha256="b" * 64,
        samples_sha256="c" * 64,
    )


def _run(corpus: VoiceCorpus) -> dict:
    return {
        "schema_version": 2,
        "evaluation_profile_id": "voice-release-plan-2026q3",
        "corpus_fingerprint": corpus.fingerprint,
        "implementation_fingerprint": "d" * 64,
        "collection_method": "automated",
        "engine": {
            "adapter_id": "sherpa-onnx",
            "engine_id": "sherpa-onnx@eeeeeeeeeeeeeeee",
            "asset_management": "product",
            "recognizer_locale": "zh-CN",
            "requires_on_device": True,
            "supports_on_device_at_run": True,
            "artifact_id": "rimeai-voice-zh-v1",
            "artifact_content_sha256": "e" * 64,
            "model_id": "sherpa-zh-small",
            "model_revision": "2026.08.1",
        },
        "platform": {
            "os_version": "14.7",
            "os_build": "23H124",
            "hardware_class": "Mac15,7",
            "arch": "arm64",
        },
        "audio_io": {
            "device_class": "built_in",
            "sample_format": "pcm_s16le",
            "sample_rate_hz": 16_000,
            "channels": 1,
        },
        "policy": {
            "endpoint_strategy": "push-to-talk",
            "hotwords_enabled": False,
            "postprocessor_id": "identity-v1",
        },
        "unsupported_subsets": [],
        "clock": {"domain": "helper_server_monotonic", "unit": "ms"},
    }


def _process(role: str, offset: int) -> dict:
    return {
        "role": role,
        "instance_id": f"{role}-instance",
        "start_user_cpu_ns": 1_000 + offset,
        "end_user_cpu_ns": 101_000 + offset,
        "start_system_cpu_ns": 2_000 + offset,
        "end_system_cpu_ns": 52_000 + offset,
        "start_energy_nj": 3_000 + offset,
        "end_energy_nj": 1_000_003_000 + offset,
        "baseline_resident_bytes": 10_000_000 + offset,
        "peak_resident_bytes": 20_000_000 + offset,
        "baseline_phys_footprint_bytes": 8_000_000 + offset,
        "peak_phys_footprint_bytes": 18_000_000 + offset,
        "sample_count": 11,
        "maximum_sample_gap_ms": 150,
    }


def _performance(corpus: VoiceCorpus, run: dict) -> dict:
    return {
        "schema_version": 3,
        "evaluation_profile_id": run["evaluation_profile_id"],
        "corpus_fingerprint": corpus.fingerprint,
        "implementation_fingerprint": run["implementation_fingerprint"],
        "run_sha256": voice_run_sha256(run),
        "collection_protocol": {
            "id": "rimeai-release-collection-v1",
            "sha256": "7" * 64,
        },
        "artifact": {
            "artifact_id": run["engine"]["artifact_id"],
            "artifact_content_sha256": run["engine"][
                "artifact_content_sha256"
            ],
            "adapter_id": run["engine"]["adapter_id"],
            "engine_id": run["engine"]["engine_id"],
            "model_id": run["engine"]["model_id"],
            "model_revision": run["engine"]["model_revision"],
            "verified_payload_bytes": 123_456_789,
            "verified_file_count": 5,
        },
        "collector": {
            "collector_id": "rimeai-voice-performance-v1",
            "clock_domain": "mach_continuous_time",
            "sample_interval_ms": 100,
            "memory_source": "proc_pid_rusage_v6",
            "energy_source": "proc_pid_rusage_v6_energy_nj",
            "executable_sha256": "c" * 64,
            "team_identifier": "S3T42U45P8",
            "signing_identifier": "fun.wwcn.rimeai.voice-performance-collector",
        },
        "environment": {
            "hardware_model": "Mac15,7",
            "physical_memory_bytes": 8_589_934_592,
            "logical_cpu_count": 8,
            "power_source": "ac",
            "low_power_mode": False,
            "thermal_state_start": "nominal",
            "thermal_state_end": "nominal",
        },
        "required_process_roles": list(PROCESS_ROLES),
        "cold_artifact_load_ms": [4_200.0, 4_050.0, 3_980.0],
        "sessions": [
            {
                "sample_id": corpus.samples[0].id,
                "audio_duration_ms": corpus.samples[0].audio.duration_ms,
                "processing_duration_ms": 500.0,
                "processes": [
                    _process(role, index * 1_000)
                    for index, role in enumerate(PROCESS_ROLES)
                ],
            }
        ],
        "keyboard_trials": [
            {
                "sequence": 1,
                "phase": "baseline",
                "rime_candidate_latency_ms": 10.0,
            },
            {
                "sequence": 1,
                "phase": "helper_loaded_idle",
                "rime_candidate_latency_ms": 12.0,
            },
            {
                "sequence": 1,
                "phase": "listening_cancel_to_rime",
                "rime_candidate_latency_ms": 14.0,
            },
        ],
        "late_voice_commit_count": 0,
        "late_challenge_counts": {
            "cancel": 1,
            "application_switch": 1,
            "secure_input": 1,
            "target_invalidation": 1,
            "keyboard_input": 1,
        },
    }


def test_valid_performance_sidecar_is_bound_and_loaded(tmp_path: Path):
    corpus = _corpus()
    run = _run(corpus)
    expected = _performance(corpus, run)
    path = tmp_path / "performance.json"
    path.write_text(json.dumps(expected), encoding="utf-8")

    assert load_voice_performance(path, corpus, run) == expected


def test_performance_preserves_raw_macos_hardware_model_identity(tmp_path: Path):
    corpus = _corpus()
    run = _run(corpus)
    run["platform"]["hardware_class"] = "Mac15,7"
    expected = _performance(corpus, run)
    expected["environment"]["hardware_model"] = "Mac15,7"
    path = tmp_path / "performance.json"
    path.write_text(json.dumps(expected), encoding="utf-8")

    loaded = load_voice_performance(path, corpus, run)

    assert loaded["environment"]["hardware_model"] == "Mac15,7"


@pytest.mark.parametrize(
    "invalid_hardware_model",
    ["Mac15,7\nprivate", "M" * 129],
)
def test_performance_rejects_unsafe_hardware_model_without_echoing_it(
    tmp_path: Path,
    invalid_hardware_model: str,
):
    corpus = _corpus()
    run = _run(corpus)
    evidence = _performance(corpus, run)
    evidence["environment"]["hardware_model"] = invalid_hardware_model
    path = tmp_path / "performance.json"
    path.write_text(json.dumps(evidence), encoding="utf-8")

    with pytest.raises(VoicePerformanceError) as captured:
        load_voice_performance(path, corpus, run)

    assert "hardware model identifier" in str(captured.value)
    assert invalid_hardware_model not in str(captured.value)


def test_performance_does_not_normalize_hardware_model_identity(tmp_path: Path):
    corpus = _corpus()
    run = _run(corpus)
    evidence = _performance(corpus, run)
    evidence["environment"]["hardware_model"] = "Mac15.7"
    path = tmp_path / "performance.json"
    path.write_text(json.dumps(evidence), encoding="utf-8")

    with pytest.raises(VoicePerformanceError, match="does not match voice run"):
        load_voice_performance(path, corpus, run)


def test_performance_v3_digest_is_domain_separated_and_binds_protocol():
    corpus = _corpus()
    run = _run(corpus)
    evidence = _performance(corpus, run)
    canonical = json.dumps(
        evidence,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
        allow_nan=False,
    ).encode("utf-8")

    assert voice_performance_sha256(evidence) == hashlib.sha256(
        b"rimeai.voice-performance.v3\x00" + canonical
    ).hexdigest()
    changed = json.loads(json.dumps(evidence))
    changed["collection_protocol"]["sha256"] = "8" * 64
    assert voice_performance_sha256(changed) != voice_performance_sha256(evidence)


@pytest.mark.parametrize("invalid_version", [2, 3.0])
def test_performance_schema_version_requires_exact_integer_three(
    tmp_path: Path,
    invalid_version,
):
    corpus = _corpus()
    run = _run(corpus)
    evidence = _performance(corpus, run)
    evidence["schema_version"] = invalid_version
    path = tmp_path / "invalid-performance.json"
    path.write_text(json.dumps(evidence), encoding="utf-8")

    with pytest.raises(VoicePerformanceError, match="schema_version must be 3"):
        load_voice_performance(path, corpus, run)


@pytest.mark.parametrize(
    ("mutate", "message"),
    [
        (
            lambda evidence: evidence["sessions"][0].update(
                {"processing_duration_ms": 0}
            ),
            "processing_duration_ms",
        ),
        (
            lambda evidence: evidence["cold_artifact_load_ms"].__setitem__(0, 0),
            "cold_artifact_load_ms",
        ),
        (
            lambda evidence: evidence["keyboard_trials"][0].update(
                {"rime_candidate_latency_ms": 0}
            ),
            "rime_candidate_latency_ms",
        ),
        (
            lambda evidence: evidence["sessions"][0]["processes"][0].update(
                {"baseline_resident_bytes": 0}
            ),
            "baseline_resident_bytes",
        ),
        (
            lambda evidence: evidence["sessions"][0]["processes"][0].update(
                {"baseline_phys_footprint_bytes": 0}
            ),
            "baseline_phys_footprint_bytes",
        ),
        (
            lambda evidence: evidence["sessions"][0]["processes"][2].update(
                {
                    "end_user_cpu_ns": evidence["sessions"][0]["processes"][2][
                        "start_user_cpu_ns"
                    ],
                    "end_system_cpu_ns": evidence["sessions"][0]["processes"][2][
                        "start_system_cpu_ns"
                    ],
                }
            ),
            "voice_helper CPU",
        ),
        (
            lambda evidence: [
                process.update(
                    {
                        "end_energy_nj": process["start_energy_nj"],
                    }
                )
                for session in evidence["sessions"]
                for process in session["processes"]
            ],
            "energy",
        ),
    ],
)
def test_hollow_resource_evidence_is_rejected(mutate, message: str):
    corpus = _corpus()
    run = _run(corpus)
    evidence = _performance(corpus, run)
    mutate(evidence)

    with pytest.raises(VoicePerformanceError, match=message):
        aggregate_voice_performance(evidence, corpus, run)


def test_performance_rejects_unrepresentable_numeric_without_overflow():
    corpus = _corpus()
    run = _run(corpus)
    evidence = _performance(corpus, run)
    evidence["cold_artifact_load_ms"][0] = 10**309

    with pytest.raises(VoicePerformanceError, match="finite"):
        aggregate_voice_performance(evidence, corpus, run)


def test_performance_rejects_counters_above_uint64():
    corpus = _corpus()
    run = _run(corpus)
    evidence = _performance(corpus, run)
    evidence["sessions"][0]["processes"][0]["end_energy_nj"] = 1 << 64

    with pytest.raises(VoicePerformanceError, match="unsigned 64-bit integer"):
        aggregate_voice_performance(evidence, corpus, run)


@pytest.mark.parametrize(
    "mutate",
    [
        lambda value: value["environment"].update(
            {"physical_memory_bytes": 1 << 64}
        ),
        lambda value: value["cold_artifact_load_ms"].__setitem__(0, 1 << 64),
        lambda value: value["sessions"][0].update(
            {"processing_duration_ms": 1 << 64}
        ),
        lambda value: value["sessions"][0]["processes"][0].update(
            {"baseline_resident_bytes": 1 << 64}
        ),
        lambda value: value["sessions"][0]["processes"][0].update(
            {"maximum_sample_gap_ms": 1 << 64}
        ),
        lambda value: value["keyboard_trials"][0].update(
            {"rime_candidate_latency_ms": 1 << 64}
        ),
        lambda value: value["artifact"].update(
            {"verified_payload_bytes": 1 << 64}
        ),
        lambda value: value["environment"].update(
            {"logical_cpu_count": 1 << 64}
        ),
        lambda value: value["sessions"][0]["processes"][0].update(
            {"sample_count": 1 << 64}
        ),
        lambda value: [
            trial.update({"sequence": 1 << 64})
            for trial in value["keyboard_trials"]
        ],
        lambda value: value.update({"late_voice_commit_count": 1 << 64}),
        lambda value: value["late_challenge_counts"].update(
            {"cancel": 1 << 64}
        ),
    ],
)
def test_performance_rejects_all_swift_uint64_fields_above_range(mutate):
    corpus = _corpus()
    run = _run(corpus)
    evidence = _performance(corpus, run)
    mutate(evidence)

    with pytest.raises(VoicePerformanceError, match="unsigned 64-bit"):
        aggregate_voice_performance(evidence, corpus, run)


def test_direct_validator_rejects_constructed_zero_duration_corpus_before_aggregation():
    corpus = _corpus()
    sample = corpus.samples[0]
    zero_duration_sample = replace(
        sample,
        audio=replace(sample.audio, duration_ms=0),
    )
    invalid_corpus = replace(corpus, samples=(zero_duration_sample,))
    run = _run(invalid_corpus)
    evidence = _performance(invalid_corpus, run)

    with pytest.raises(VoicePerformanceError, match="corpus audio duration"):
        aggregate_voice_performance(evidence, invalid_corpus, run)


def test_direct_validator_rejects_an_unsafe_constructed_corpus_id_without_echoing_it():
    corpus = _corpus()
    private_id = "private transcript 机密"
    sample = replace(
        corpus.samples[0],
        id=private_id,
        audio=replace(corpus.samples[0].audio, duration_ms=0),
    )
    invalid_corpus = replace(corpus, samples=(sample,))
    run = _run(invalid_corpus)
    evidence = _performance(invalid_corpus, run)

    with pytest.raises(VoicePerformanceError) as captured:
        aggregate_voice_performance(evidence, invalid_corpus, run)

    assert "controlled non-sensitive identifier" in str(captured.value)
    assert private_id not in str(captured.value)


def test_direct_validator_rejects_duplicate_constructed_corpus_ids_before_folding():
    corpus = _corpus()
    duplicate = replace(corpus.samples[0], speaker_group_id="another-speaker")
    invalid_corpus = replace(corpus, samples=(corpus.samples[0], duplicate))
    run = _run(invalid_corpus)
    evidence = _performance(invalid_corpus, run)

    with pytest.raises(VoicePerformanceError, match="duplicate corpus sample"):
        aggregate_voice_performance(evidence, invalid_corpus, run)


@pytest.mark.parametrize(
    ("mutate", "message"),
    [
        (
            lambda value: value.update({"evaluation_profile_id": "other-profile"}),
            "evaluation_profile_id",
        ),
        (
            lambda value: value.update({"corpus_fingerprint": "1" * 64}),
            "corpus_fingerprint",
        ),
        (
            lambda value: value.update({"implementation_fingerprint": "2" * 64}),
            "implementation_fingerprint",
        ),
        (
            lambda value: value.update({"run_sha256": "3" * 64}),
            "run_sha256",
        ),
        (
            lambda value: value["artifact"].update(
                {"artifact_content_sha256": "4" * 64}
            ),
            "artifact_content_sha256",
        ),
        (
            lambda value: value["artifact"].update({"artifact_id": "other-artifact"}),
            "artifact_id",
        ),
        (
            lambda value: value["artifact"].update({"adapter_id": "other-adapter"}),
            "adapter_id",
        ),
        (
            lambda value: value["artifact"].update({"engine_id": "other-engine"}),
            "engine_id",
        ),
        (
            lambda value: value["artifact"].update({"model_id": "other-model"}),
            "model_id",
        ),
        (
            lambda value: value["artifact"].update(
                {"model_revision": "other-revision"}
            ),
            "model_revision",
        ),
    ],
)
def test_performance_identity_fields_are_bound_to_the_run(
    tmp_path: Path,
    mutate,
    message: str,
):
    corpus = _corpus()
    run = _run(corpus)
    invalid = _performance(corpus, run)
    mutate(invalid)
    path = tmp_path / "performance.json"
    path.write_text(json.dumps(invalid), encoding="utf-8")

    with pytest.raises(VoicePerformanceError, match=message):
        load_voice_performance(path, corpus, run)


@pytest.mark.parametrize(
    "contents",
    [
        '{"schema_version":1,"schema_version":1}',
        '{"schema_version":NaN}',
    ],
)
def test_performance_json_rejects_duplicate_keys_and_nonfinite_numbers(
    tmp_path: Path, contents: str
):
    corpus = _corpus()
    path = tmp_path / "performance.json"
    path.write_text(contents, encoding="utf-8")

    with pytest.raises(VoicePerformanceError, match="invalid JSON"):
        load_voice_performance(path, corpus, _run(corpus))


@pytest.mark.parametrize(
    "payload",
    [
        b"\xff",
        b"[" * 1_100 + b"0" + b"]" * 1_100,
        b'{"schema_version":' + b"9" * 5_000 + b"}",
    ],
)
def test_performance_loader_normalizes_untrusted_json_parser_failures(
    tmp_path: Path,
    payload: bytes,
):
    corpus = _corpus()
    path = tmp_path / "performance.json"
    path.write_bytes(payload)

    with pytest.raises(VoicePerformanceError, match="invalid JSON"):
        load_voice_performance(path, corpus, _run(corpus))


def test_performance_loader_rejects_more_than_sixteen_mibibytes(
    tmp_path: Path,
):
    corpus = _corpus()
    path = tmp_path / "performance.json"
    path.write_bytes(b" " * (16 * 1_024 * 1_024 + 1))

    with pytest.raises(VoicePerformanceError, match="too large"):
        load_voice_performance(path, corpus, _run(corpus))


@pytest.mark.parametrize(
    "mutate",
    [
        lambda value, secret: value.update({secret: True}),
        lambda value, secret: value["sessions"][0]["processes"][0].update(
            {secret: True}
        ),
    ],
)
def test_performance_unknown_fields_are_rejected_without_echoing_their_names(
    tmp_path: Path,
    mutate,
):
    corpus = _corpus()
    run = _run(corpus)
    evidence = _performance(corpus, run)
    secret = "private transcript 机密"
    mutate(evidence, secret)
    path = tmp_path / "performance.json"
    path.write_text(json.dumps(evidence), encoding="utf-8")

    with pytest.raises(VoicePerformanceError) as captured:
        load_voice_performance(path, corpus, run)

    assert "unknown fields" in str(captured.value)
    assert secret not in str(captured.value)


@pytest.mark.parametrize(
    ("mutate", "message"),
    [
        (
            lambda value: value["environment"].update(
                {"low_power_mode": True}
            ),
            "low power mode",
        ),
        (
            lambda value: value["environment"].update(
                {"thermal_state_end": "fair"}
            ),
            "thermal state changed",
        ),
    ],
)
def test_performance_environment_is_stable_for_release_evidence(
    tmp_path: Path,
    mutate,
    message: str,
):
    corpus = _corpus()
    run = _run(corpus)
    invalid = _performance(corpus, run)
    mutate(invalid)
    path = tmp_path / "performance.json"
    path.write_text(json.dumps(invalid), encoding="utf-8")

    with pytest.raises(VoicePerformanceError, match=message):
        load_voice_performance(path, corpus, run)


def test_performance_sessions_must_cover_the_corpus_exactly(tmp_path: Path):
    original = _corpus()
    second = replace(
        original.samples[0],
        id="voice-000002",
        speaker_group_id="private-speaker-2",
    )
    corpus = replace(original, samples=(original.samples[0], second))
    run = _run(corpus)
    incomplete = _performance(corpus, run)
    path = tmp_path / "performance.json"
    path.write_text(json.dumps(incomplete), encoding="utf-8")

    try:
        load_voice_performance(path, corpus, run)
    except Exception as error:
        assert "sessions are incomplete" in str(error)
    else:
        raise AssertionError("missing performance session was accepted")


def test_performance_rejects_uncontrolled_sample_id_without_echoing_it(
    tmp_path: Path,
):
    corpus = _corpus()
    run = _run(corpus)
    private_value = "private transcript 机密"
    invalid = _performance(corpus, run)
    invalid["sessions"][0]["sample_id"] = private_value
    path = tmp_path / "performance.json"
    path.write_text(json.dumps(invalid), encoding="utf-8")

    with pytest.raises(VoicePerformanceError) as captured:
        load_voice_performance(path, corpus, run)

    assert "controlled non-sensitive identifier" in str(captured.value)
    assert private_value not in str(captured.value)


@pytest.mark.parametrize(
    ("mutate", "message"),
    [
        (
            lambda value: value["sessions"][0]["processes"].pop(),
            "process roles",
        ),
        (
            lambda value: value["sessions"][0]["processes"][1].update(
                {
                    "instance_id": value["sessions"][0]["processes"][0][
                        "instance_id"
                    ]
                }
            ),
            "process instances",
        ),
        (
            lambda value: value["sessions"][0]["processes"][0].update(
                {"end_user_cpu_ns": 0}
            ),
            "counter regressed",
        ),
        (
            lambda value: value["sessions"][0]["processes"][0].update(
                {"peak_phys_footprint_bytes": 1}
            ),
            "peak memory",
        ),
        (
            lambda value: value["sessions"][0]["processes"][0].update(
                {"maximum_sample_gap_ms": 201}
            ),
            "sampling cadence",
        ),
        (
            lambda value: value["sessions"][0]["processes"][0].update(
                {"sample_count": 2}
            ),
            "sampling cadence",
        ),
    ],
)
def test_process_scope_counters_and_sampling_cadence_are_strict(
    tmp_path: Path,
    mutate,
    message: str,
):
    corpus = _corpus()
    run = _run(corpus)
    invalid = _performance(corpus, run)
    mutate(invalid)
    path = tmp_path / "performance.json"
    path.write_text(json.dumps(invalid), encoding="utf-8")

    with pytest.raises(VoicePerformanceError, match=message):
        load_voice_performance(path, corpus, run)


@pytest.mark.parametrize(
    ("mutate", "message"),
    [
        (
            lambda value: value["keyboard_trials"].pop(),
            "keyboard.*paired",
        ),
        (
            lambda value: value["keyboard_trials"].append(
                dict(value["keyboard_trials"][0])
            ),
            "keyboard.*duplicated",
        ),
    ],
)
def test_keyboard_phases_are_strictly_paired(
    tmp_path: Path,
    mutate,
    message: str,
):
    corpus = _corpus()
    run = _run(corpus)
    invalid = _performance(corpus, run)
    mutate(invalid)
    path = tmp_path / "performance.json"
    path.write_text(json.dumps(invalid), encoding="utf-8")

    with pytest.raises(VoicePerformanceError, match=message):
        load_voice_performance(path, corpus, run)


def test_performance_aggregation_uses_cohort_scope_and_audio_normalization():
    corpus = _corpus()
    run = _run(corpus)

    metrics = aggregate_voice_performance(_performance(corpus, run), corpus, run)

    assert metrics["authenticated_production_driver"] is False
    assert metrics["session_coverage_rate"] == 1.0
    assert metrics["real_time_factor"]["p95"] == 0.5
    assert metrics["cpu_core_seconds_per_audio_second"]["p95"] == pytest.approx(
        0.00045
    )
    assert metrics["energy_joules_per_audio_minute"]["p95"] == 180.0
    assert metrics["cohort_peak_resident_mib"]["p95"] == pytest.approx(
        60_003_000 / 1_048_576
    )
    assert metrics["cohort_peak_phys_footprint_mib"]["p95"] == pytest.approx(
        54_003_000 / 1_048_576
    )
    assert metrics["voice_incremental_peak_phys_footprint_mib"][
        "p95"
    ] == pytest.approx(30_000_000 / 1_048_576)
    assert metrics["cold_artifact_load_ms"]["p95"] == 4_200.0
    assert metrics["product_artifact_payload_bytes"] == {
        "value": 123_456_789,
        "measurement": "measured",
    }
    assert metrics["keyboard"]["baseline_rime_latency_ms"]["p95"] == 10.0
    assert metrics["keyboard"]["helper_loaded_rime_latency_ms"]["p95"] == 12.0
    assert metrics["keyboard"]["listening_cancel_to_rime_latency_ms"][
        "p95"
    ] == 14.0
    assert metrics["keyboard"]["helper_loaded_added_p95_ms"] == 2.0
    assert metrics["keyboard"]["listening_cancel_added_p95_ms"] == 4.0
    assert metrics["keyboard"]["late_voice_commit_count"] == 0


def test_schema_v3_rejects_a_user_supplied_driver_authentication_claim(
    tmp_path: Path,
):
    corpus = _corpus()
    run = _run(corpus)
    evidence = _performance(corpus, run)
    evidence["authenticated_production_driver"] = True
    path = tmp_path / "performance.json"
    path.write_text(json.dumps(evidence), encoding="utf-8")

    with pytest.raises(VoicePerformanceError, match="unknown fields"):
        load_voice_performance(path, corpus, run)
