from dataclasses import replace
import hashlib
import json
from pathlib import Path

import pytest

from deep_json import deep_nesting_payloads
from rimeai_eval.voice_dataset import VoiceAudio
from rimeai_eval.voice_dataset import VoiceConditions
from rimeai_eval.voice_dataset import VoiceCorpus
from rimeai_eval.voice_dataset import VoiceManifest
from rimeai_eval.voice_dataset import VoiceQualityDeclarations
from rimeai_eval.voice_dataset import VoiceRights
from rimeai_eval.voice_dataset import VoiceSample
from rimeai_eval.voice_dataset import VoiceTerm
from rimeai_eval.voice_evaluation import HOTWORD_GATE_THRESHOLDS
from rimeai_eval.voice_evaluation import MANDATORY_GATE_THRESHOLDS
from rimeai_eval.voice_evaluation import VoiceEvaluationError
from rimeai_eval.voice_evaluation import compare_voice_reports
from rimeai_eval.voice_evaluation import evaluate_voice
from rimeai_eval.voice_evaluation import load_voice_gates
from rimeai_eval.voice_evaluation import load_voice_observations
from rimeai_eval.voice_evaluation import load_voice_run
from rimeai_eval.voice_evaluation import quality_report_sha256
from rimeai_eval.voice_performance import voice_performance_sha256
from rimeai_eval.voice_performance import voice_run_sha256


def _sample(
    sample_id: str,
    reference: str,
    *,
    terms=(),
    blank: bool = False,
    domain: str = "software",
    language: str = "mixed",
    noise: str = "quiet",
    distance: str = "near_field",
) -> VoiceSample:
    return VoiceSample(
        id=sample_id,
        split="test",
        speaker_group_id="private-speaker-" + sample_id,
        domain=domain,
        language_composition=language,
        conditions=VoiceConditions(noise=noise, distance=distance),
        audio=VoiceAudio(
            path=Path("/private/audio/%s.wav" % sample_id),
            sha256="9" * 64,
            duration_ms=1_000.0,
            sample_rate_hz=16_000,
            channels=1,
            frame_count=16_000,
        ),
        reference=reference,
        terms=tuple(terms),
        is_blank=blank,
    )


def _term(text: str, mode: str = "ascii_casefold_word") -> VoiceTerm:
    return VoiceTerm(text=text, match_mode=mode)


def _corpus(
    samples,
    *,
    purpose: str = "frozen_quality",
    synthetic_fixture: bool = False,
) -> VoiceCorpus:
    manifest = VoiceManifest(
        schema_version=1,
        corpus_id="voice-quality-v1",
        purpose=purpose,
        normalization_profile="rimeai-voice-v1",
        samples_file="samples.jsonl",
        synthetic_fixture=synthetic_fixture,
        rights=(
            None
            if synthetic_fixture
            else VoiceRights(
                basis="participant_consent",
                record_ref="controlled-rights-record",
            )
        ),
        quality_declarations=VoiceQualityDeclarations(
            authorized_real_recordings=not synthetic_fixture,
            speaker_disjoint_by_identity=not synthetic_fixture,
        ),
    )
    return VoiceCorpus(
        root=Path("/private/corpus"),
        manifest=manifest,
        samples=tuple(samples),
        fingerprint="a" * 64,
        manifest_sha256="b" * 64,
        samples_sha256="c" * 64,
    )


def _run(
    corpus: VoiceCorpus,
    *,
    asset_management: str = "product",
    os_version: str = "14.7",
    hotwords: bool = False,
    implementation: str = "d" * 64,
    device_class: str = "built_in",
) -> dict:
    engine = {
        "adapter_id": "sherpa-onnx",
        "engine_id": "sherpa-onnx@eeeeeeeeeeeeeeee",
        "asset_management": asset_management,
        "recognizer_locale": "zh-CN",
        "requires_on_device": True,
        "supports_on_device_at_run": True,
    }
    if asset_management == "product":
        engine.update(
            {
                "artifact_id": "rimeai-voice-zh-v1",
                "artifact_content_sha256": "e" * 64,
                "model_id": "sherpa-zh-small",
                "model_revision": "2026.08.1",
            }
        )
    policy = {
        "endpoint_strategy": "push-to-talk",
        "hotwords_enabled": hotwords,
        "postprocessor_id": "identity-v1",
    }
    if hotwords:
        policy["hotword_set_sha256"] = "f" * 64
    return {
        "schema_version": 2,
        "evaluation_profile_id": "voice-release-plan-2026q3",
        "corpus_fingerprint": corpus.fingerprint,
        "implementation_fingerprint": implementation,
        "collection_method": "automated",
        "engine": engine,
        "platform": {
            "os_version": os_version,
            "os_build": "23H124",
            "hardware_class": "Mac15,7",
            "arch": "arm64",
        },
        "audio_io": {
            "device_class": device_class,
            "sample_format": "pcm_s16le",
            "sample_rate_hz": 16_000,
            "channels": 1,
        },
        "policy": policy,
        "unsupported_subsets": [],
        "clock": {"domain": "helper_server_monotonic", "unit": "ms"},
    }


def test_product_run_accepts_the_runtime_protocol_engine_identity():
    corpus, observations = _fixture_case()
    run = _run(corpus)

    report = evaluate_voice(corpus, run, observations)

    assert (
        report["provenance"]["engine"]["engine_id"]
        == "sherpa-onnx@eeeeeeeeeeeeeeee"
    )


def _final(
    sample_id: str,
    text: str,
    *,
    partials=(),
    stop: float = 300,
    final: float = 500,
    resources=None,
) -> dict:
    value = {
        "schema_version": 1,
        "sample_id": sample_id,
        "outcome": "final",
        "partials": list(partials),
        "stop_received_elapsed_ms": stop,
        "final": {"text": text, "elapsed_ms": final},
    }
    if resources is not None:
        value["resources"] = resources
    return value


def _cancelled(sample_id: str, *, cancel=600, capture_stopped=640) -> dict:
    return {
        "schema_version": 1,
        "sample_id": sample_id,
        "outcome": "cancelled",
        "partials": [],
        "cancel_received_elapsed_ms": cancel,
        "capture_stopped_elapsed_ms": capture_stopped,
    }


def _fixture_case():
    samples = [
        _sample(
            "mixed-secret-id",
            "数字三，Go timeout!",
            terms=(_term("go"), _term("timeout")),
        ),
        _sample(
            "english-secret-id",
            "algorithm",
            domain="general",
            language="en",
        ),
        _sample(
            "blank-secret-id",
            "",
            blank=True,
            domain="general",
            language="blank",
        ),
        _sample(
            "cancel-secret-id",
            "",
            blank=True,
            language="blank",
            noise="fan_noise",
            distance="far_field",
        ),
    ]
    observations = [
        _final(
            "mixed-secret-id",
            "数字3, go time out!",
            partials=(
                {"sequence": 1, "text": "数字", "elapsed_ms": 100},
                {"sequence": 2, "text": "数字3", "elapsed_ms": 200},
            ),
            resources={
                "processing_duration_ms": 450,
                "samples": [
                    {
                        "elapsed_ms": 100,
                        "resident_memory_mb": 120,
                        "cpu_percent": 10,
                    },
                    {
                        "elapsed_ms": 200,
                        "resident_memory_mb": 140,
                        "cpu_percent": 20,
                        "energy_impact": 3,
                    },
                ],
            },
        ),
        _final(
            "english-secret-id",
            "algorithm",
            partials=(
                {"sequence": 4, "text": "algorithm", "elapsed_ms": 50},
            ),
            stop=80,
            final=100,
        ),
        _final("blank-secret-id", "。", stop=90, final=110),
        _cancelled("cancel-secret-id"),
    ]
    return _corpus(samples), observations


def _release_case():
    corpus, observations = _fixture_case()
    zh_sample = _sample(
        "zh-secret-id",
        "语音，测试。",
        terms=(_term("语音", "exact"),),
        language="zh",
        noise="common_noise",
        distance="far_field",
    )
    base_samples = list(corpus.samples) + [zh_sample]
    base_observations = list(observations) + [
        _final(
            "zh-secret-id",
            "语音，测试。",
            partials=(
                {"sequence": 1, "text": "语音", "elapsed_ms": 80},
            ),
            stop=300,
            final=350,
            resources={"processing_duration_ms": 250},
        )
    ]
    samples = []
    expanded_observations = []
    for repetition in range(40):
        for sample, observation in zip(base_samples, base_observations):
            sample_id = "%s-%02d" % (sample.id, repetition)
            samples.append(
                replace(
                    sample,
                    id=sample_id,
                    speaker_group_id="speaker-%s" % sample_id,
                )
            )
            copied = json.loads(json.dumps(observation))
            copied["sample_id"] = sample_id
            expanded_observations.append(copied)
    return _corpus(samples), expanded_observations


def _gates(*, hotwords: bool = False, required=None) -> dict:
    thresholds = {key: 1.0 for key in MANDATORY_GATE_THRESHOLDS}
    thresholds.update(
        {
            "first_partial_p95_ms_max": 1_000,
            "stop_to_final_p95_ms_max": 1_000,
            "cancel_to_capture_stop_p95_ms_max": 1_000,
            "term_exact_match_rate_min": 0,
            "real_time_factor_p95_max": 2,
            "cohort_peak_resident_mib_max": 1_000,
            "cohort_peak_phys_footprint_mib_max": 1_000,
            "voice_incremental_peak_phys_footprint_mib_max": 1_000,
            "cpu_core_seconds_per_audio_second_p95_max": 10,
            "energy_joules_per_audio_minute_p95_max": 1_000,
            "product_artifact_payload_bytes_max": 1_000_000_000,
            "cold_artifact_load_p95_ms_max": 10_000,
            "keyboard_baseline_rime_p95_ms_max": 1_000,
            "keyboard_helper_loaded_rime_p95_ms_max": 1_000,
            "keyboard_helper_loaded_added_p95_ms_max": 100,
            "keyboard_listening_cancel_to_rime_p95_ms_max": 1_000,
            "keyboard_listening_cancel_added_p95_ms_max": 100,
        }
    )
    if hotwords:
        thresholds.update(
            {
                "technical_term_exact_gain_pp_min": 5,
                "mandarin_cer_regression_pp_max": 1,
            }
        )
    if required is None:
        required = [
            {"dimension": dimension, "value": value}
            for dimension, value in sorted(
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
        ]
    return {
        "schema_version": 2,
        "evaluation_profile_id": "voice-release-plan-2026q3",
        "required_subsets": required,
        "thresholds": thresholds,
        "evidence_requirements": {
            "collection_protocol": {
                "id": "rimeai-release-collection-v1",
                "sha256": "7" * 64,
            },
            "minimum_cold_artifact_load_trials": 3,
            "minimum_paired_keyboard_sequences": 1,
            "minimum_first_partial_samples": 120,
            "minimum_stop_to_final_samples": 160,
            "minimum_cancel_to_capture_stop_samples": 40,
            "minimum_partial_churn_transitions": 40,
            "minimum_required_subset_samples": 40,
            "minimum_late_challenges_per_scenario": {
                "cancel": 1,
                "application_switch": 1,
                "secure_input": 1,
                "target_invalidation": 1,
                "keyboard_input": 1,
            },
        },
    }


def _performance_evidence(corpus: VoiceCorpus, run: dict) -> dict:
    def process(role: str, offset: int) -> dict:
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

    roles = ("input_method", "candidate_service", "voice_helper")
    artifact = None
    if run["engine"]["asset_management"] == "product":
        artifact = {
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
        }
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
        "artifact": artifact,
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
            "hardware_model": run["platform"]["hardware_class"],
            "physical_memory_bytes": 8_589_934_592,
            "logical_cpu_count": 8,
            "power_source": "ac",
            "low_power_mode": False,
            "thermal_state_start": "nominal",
            "thermal_state_end": "nominal",
        },
        "required_process_roles": list(roles),
        "cold_artifact_load_ms": [4_200.0, 4_050.0, 3_980.0],
        "sessions": [
            {
                "sample_id": sample.id,
                "audio_duration_ms": sample.audio.duration_ms,
                "processing_duration_ms": sample.audio.duration_ms / 2,
                "processes": [
                    process(role, index * 1_000)
                    for index, role in enumerate(roles)
                ],
            }
            for sample in corpus.samples
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


def test_evidence_requirements_are_policy_driven_and_fail_incomplete_at_minimum_minus_one():
    corpus, observations = _release_case()
    run = _run(corpus)
    exact = evaluate_voice(
        corpus,
        run,
        observations,
        performance_evidence=_performance_evidence(corpus, run),
        gates=_gates(),
    )
    assert exact["gates"]["evidence:cold_artifact_load_trials"][
        "evidence_complete"
    ] is True
    assert exact["gates"]["evidence:cold_artifact_load_trials"]["actual"] == 3

    gates = _gates()
    gates["evidence_requirements"]["minimum_cold_artifact_load_trials"] = 4

    report = evaluate_voice(
        corpus,
        run,
        observations,
        performance_evidence=_performance_evidence(corpus, run),
        gates=gates,
    )

    assert report["decision"] == "policy_incomplete"
    assert report["gates"]["evidence:cold_artifact_load_trials"] == {
        "actual": 3,
        "threshold": 4,
        "passed": False,
        "evidence_complete": False,
    }


@pytest.mark.parametrize(
    ("requirement", "minimum_minus_one", "check"),
    [
        (
            "minimum_paired_keyboard_sequences",
            1,
            "evidence:paired_keyboard_sequences",
        ),
        ("minimum_first_partial_samples", 120, "evidence:first_partial_samples"),
        ("minimum_stop_to_final_samples", 160, "evidence:stop_to_final_samples"),
        (
            "minimum_cancel_to_capture_stop_samples",
            40,
            "evidence:cancel_to_capture_stop_samples",
        ),
        (
            "minimum_partial_churn_transitions",
            40,
            "evidence:partial_churn_transitions",
        ),
        (
            "minimum_required_subset_samples",
            40,
            "evidence:required_subset_samples:language_composition:zh",
        ),
    ],
)
def test_each_configured_evidence_minimum_is_complete_exactly_at_its_boundary(
    requirement: str,
    minimum_minus_one: int,
    check: str,
):
    corpus, observations = _release_case()
    run = _run(corpus)
    exact = evaluate_voice(
        corpus,
        run,
        observations,
        performance_evidence=_performance_evidence(corpus, run),
        gates=_gates(),
    )
    assert exact["gates"][check]["actual"] == minimum_minus_one
    assert exact["gates"][check]["evidence_complete"] is True

    insufficient_gates = _gates()
    insufficient_gates["evidence_requirements"][requirement] = minimum_minus_one + 1
    insufficient = evaluate_voice(
        corpus,
        run,
        observations,
        performance_evidence=_performance_evidence(corpus, run),
        gates=insufficient_gates,
    )

    assert insufficient["decision"] == "policy_incomplete"
    assert insufficient["gates"][check]["actual"] == minimum_minus_one
    assert insufficient["gates"][check]["evidence_complete"] is False


@pytest.mark.parametrize(
    "scenario",
    [
        "cancel",
        "application_switch",
        "secure_input",
        "target_invalidation",
        "keyboard_input",
    ],
)
def test_each_late_challenge_scenario_has_a_policy_driven_denominator(scenario: str):
    corpus, observations = _release_case()
    run = _run(corpus)
    exact = evaluate_voice(
        corpus,
        run,
        observations,
        performance_evidence=_performance_evidence(corpus, run),
        gates=_gates(),
    )
    check = f"evidence:late_challenge:{scenario}"
    assert exact["gates"][check]["actual"] == 1
    assert exact["gates"][check]["evidence_complete"] is True

    insufficient_gates = _gates()
    insufficient_gates["evidence_requirements"][
        "minimum_late_challenges_per_scenario"
    ][scenario] = 2
    insufficient = evaluate_voice(
        corpus,
        run,
        observations,
        performance_evidence=_performance_evidence(corpus, run),
        gates=insufficient_gates,
    )
    assert insufficient["decision"] == "policy_incomplete"
    assert insufficient["gates"][check]["evidence_complete"] is False


def test_observed_late_voice_commit_is_complete_evidence_but_fails_the_gate():
    corpus, observations = _release_case()
    run = _run(corpus)
    performance = _performance_evidence(corpus, run)
    performance["late_voice_commit_count"] = 1

    report = evaluate_voice(
        corpus,
        run,
        observations,
        performance_evidence=performance,
        gates=_gates(),
    )

    assert report["decision"] == "policy_incomplete"
    assert report["gates"]["keyboard_late_voice_commit_zero"] == {
        "actual": 1.0,
        "threshold": 0,
        "passed": False,
        "evidence_complete": True,
    }


def test_collection_protocol_must_match_the_approved_evidence_requirement():
    corpus, observations = _release_case()
    run = _run(corpus)
    performance = _performance_evidence(corpus, run)
    gates = _gates()
    gates["evidence_requirements"]["collection_protocol"]["sha256"] = "8" * 64

    report = evaluate_voice(
        corpus,
        run,
        observations,
        performance_evidence=performance,
        gates=gates,
    )

    assert report["decision"] == "policy_incomplete"
    assert report["gates"]["evidence:collection_protocol"]["actual"] == (
        performance["collection_protocol"]
    )
    assert report["gates"]["evidence:collection_protocol"]["evidence_complete"] is False


def test_missing_evidence_requirement_is_reported_as_policy_incomplete():
    corpus, observations = _release_case()
    run = _run(corpus)
    gates = _gates()
    gates["evidence_requirements"].pop("minimum_first_partial_samples")

    report = evaluate_voice(
        corpus,
        run,
        observations,
        performance_evidence=_performance_evidence(corpus, run),
        gates=gates,
    )

    assert report["decision"] == "policy_incomplete"
    assert report["gates"]["gate_policy_complete"]["evidence_complete"] is False
    assert report["gates"]["evidence:first_partial_samples"]["threshold"] is None


@pytest.mark.parametrize(
    "mutate",
    [
        lambda requirements: requirements.update({"invented_minimum": 1}),
        lambda requirements: requirements.update(
            {"minimum_first_partial_samples": True}
        ),
        lambda requirements: requirements[
            "minimum_late_challenges_per_scenario"
        ].update({"invented_scenario": 1}),
    ],
)
def test_evidence_requirement_unknown_fields_and_illegal_types_are_schema_errors(
    tmp_path: Path,
    mutate,
):
    gates = _gates()
    mutate(gates["evidence_requirements"])
    path = tmp_path / "gates.json"
    path.write_text(json.dumps(gates), encoding="utf-8")

    with pytest.raises(VoiceEvaluationError):
        load_voice_gates(path)


@pytest.mark.parametrize(
    "mutate",
    [
        lambda gates: gates.update(
            {"authenticated_production_driver": True}
        ),
        lambda gates: gates["evidence_requirements"].update(
            {"authenticated_production_driver": True}
        ),
    ],
)
def test_gates_cannot_assert_production_driver_authentication(
    tmp_path: Path,
    mutate,
):
    gates = _gates()
    mutate(gates)
    path = tmp_path / "gates.json"
    path.write_text(json.dumps(gates), encoding="utf-8")

    with pytest.raises(VoiceEvaluationError, match="unknown"):
        load_voice_gates(path)


def test_gate_threshold_above_float_domain_is_a_controlled_schema_error(
    tmp_path: Path,
):
    gates = _gates()
    gates["thresholds"]["mandarin_cer_max"] = 10**309
    path = tmp_path / "gates.json"
    path.write_text(json.dumps(gates), encoding="utf-8")

    with pytest.raises(VoiceEvaluationError, match="threshold.*invalid"):
        load_voice_gates(path)


def test_hand_calculated_micro_metrics_normalization_and_nearest_rank_latency():
    corpus, observations = _fixture_case()

    report = evaluate_voice(corpus, _run(corpus), observations)
    metrics = report["metrics"]

    # NFKC/casefold is applied before scoring.  Digits participate in both the
    # Han character stream and the Latin word stream.
    assert metrics["mandarin_cer"] == {
        "edits": 1,
        "reference_units": 3,
        "rate": 0.333333,
        "measurement": "measured",
    }
    assert metrics["english_wer"]["edits"] == 3
    assert metrics["english_wer"]["reference_units"] == 3
    assert metrics["english_wer"]["rate"] == 1.0
    assert metrics["punctuation_edit_rate"]["rate"] == 0.5
    assert metrics["punctuation_exact_sequence"]["rate"] == 0.75
    assert metrics["term_exact_match"]["rate"] == 0.5
    assert metrics["blank_false_positive"]["rate"] == 0.5
    assert metrics["partial_churn"]["edits"] == 1
    assert metrics["partial_churn"]["transitions"] == 1
    assert metrics["partial_churn"]["rate"] == 1.0
    assert metrics["partial_churn"]["revisions_per_sample"] == 0.25
    assert metrics["collateral_substitution"]["rate"] == 0
    assert metrics["latency_ms"]["first_partial"]["p50"] == 50
    assert metrics["latency_ms"]["first_partial"]["p95"] == 100
    assert metrics["latency_ms"]["stop_to_final"]["p95"] == 200
    assert metrics["latency_ms"]["cancel_to_capture_stop"]["p95"] == 40
    assert metrics["resources"]["resident_memory_mb"]["max"] == 140
    assert metrics["resources"]["real_time_factor"]["max"] == 0.45


def test_collateral_substitution_is_a_corpus_term_injection_proxy():
    corpus = _corpus(
        [
            _sample(
                "term-source",
                "timeout",
                terms=(_term("timeout"),),
            ),
            _sample("ordinary-substitution", "hello world", language="en"),
        ]
    )
    observations = [
        _final("term-source", "timeout"),
        _final("ordinary-substitution", "hello universe"),
    ]

    metric = evaluate_voice(corpus, _run(corpus), observations)["metrics"][
        "collateral_substitution"
    ]

    assert metric == {
        "substitutions": 0,
        "opportunities": 1,
        "rate": 0,
        "measurement": "measured",
    }


def test_digit_three_and_ascii_term_boundary_are_frozen():
    corpus = _corpus(
        [
            _sample(
                "digit",
                "数字三",
                terms=(_term("go"),),
                language="zh",
            )
        ]
    )
    report = evaluate_voice(
        corpus,
        _run(corpus),
        [_final("digit", "数字3 algorithm")],
    )

    assert report["metrics"]["mandarin_cer"]["rate"] == 0.333333
    assert report["metrics"]["term_exact_match"]["rate"] == 0

    full_width = evaluate_voice(
        corpus,
        _run(corpus),
        [_final("digit", "数字三 ＧＯ")],
    )
    assert full_width["metrics"]["term_exact_match"]["rate"] == 1


def test_missing_denominators_and_timings_are_null_and_unmeasured():
    corpus = _corpus([_sample("blank", "", blank=True, language="blank")])
    observation = {
        "schema_version": 1,
        "sample_id": "blank",
        "outcome": "error",
        "partials": [],
    }

    metrics = evaluate_voice(corpus, _run(corpus), [observation])["metrics"]

    for key in ("mandarin_cer", "english_wer", "punctuation_edit_rate"):
        assert metrics[key]["rate"] is None
        assert metrics[key]["measurement"] == "unmeasured"
    assert metrics["term_exact_match"]["rate"] is None
    assert metrics["partial_churn"]["rate"] is None
    for metric in metrics["latency_ms"].values():
        assert metric["p50"] is None
        assert metric["p95"] is None
        assert metric["measurement"] == "unmeasured"
    assert metrics["resources"]["cpu_percent"]["max"] is None


def test_aggregate_never_contains_raw_text_paths_sample_or_speaker_values():
    corpus, observations = _fixture_case()
    report = evaluate_voice(corpus, _run(corpus), observations)
    encoded = json.dumps(report, ensure_ascii=False, sort_keys=True)

    for secret in (
        "数字三，Go timeout!",
        "数字3, go time out!",
        "mixed-secret-id",
        "private-speaker",
        "/private/audio",
        "/private/corpus",
    ):
        assert secret not in encoded

    def keys(value):
        if isinstance(value, dict):
            for key, item in value.items():
                yield key
                yield from keys(item)
        elif isinstance(value, list):
            for item in value:
                yield from keys(item)

    assert not {"text", "path", "sample_id", "speaker", "partials"} & set(
        keys(report)
    )


def test_run_loader_enforces_identity_asset_and_clock_contract(tmp_path):
    corpus, _ = _fixture_case()
    run = _run(corpus)
    path = tmp_path / "run.json"
    path.write_text(json.dumps(run), encoding="utf-8")

    assert load_voice_run(path, corpus) == run

    invalid = dict(run)
    invalid["implementation_fingerprint"] = "A" * 64
    path.write_text(json.dumps(invalid), encoding="utf-8")
    with pytest.raises(VoiceEvaluationError, match="lowercase hexadecimal"):
        load_voice_run(path, corpus)

    system = _run(corpus, asset_management="system")
    system["engine"]["artifact_sha256"] = "e" * 64
    path.write_text(json.dumps(system), encoding="utf-8")
    with pytest.raises(VoiceEvaluationError, match="unknown artifact_sha256"):
        load_voice_run(path, corpus)

    product = _run(corpus)
    product["engine"].pop("artifact_content_sha256")
    path.write_text(json.dumps(product), encoding="utf-8")
    with pytest.raises(VoiceEvaluationError, match="requires product artifact"):
        load_voice_run(path, corpus)

    wrong_clock = _run(corpus)
    wrong_clock["clock"] = {"domain": "client_wall", "unit": "ms"}
    path.write_text(json.dumps(wrong_clock), encoding="utf-8")
    with pytest.raises(VoiceEvaluationError, match="helper_server_monotonic"):
        load_voice_run(path, corpus)

    invalid_os = _run(corpus)
    invalid_os["platform"]["os_version"] = "unknown"
    path.write_text(json.dumps(invalid_os), encoding="utf-8")
    with pytest.raises(VoiceEvaluationError, match="dotted numeric"):
        load_voice_run(path, corpus)


def test_run_loader_preserves_raw_macos_hardware_model_identity(tmp_path):
    corpus, _ = _fixture_case()
    run = _run(corpus)
    run["platform"]["hardware_class"] = "Mac15,7"
    path = tmp_path / "run.json"
    path.write_text(json.dumps(run), encoding="utf-8")

    loaded = load_voice_run(path, corpus)

    assert loaded["platform"]["hardware_class"] == "Mac15,7"


@pytest.mark.parametrize(
    "invalid_hardware_model",
    ["Mac15,7\nprivate", "M" * 129],
)
def test_run_loader_rejects_unsafe_hardware_model_without_echoing_it(
    tmp_path,
    invalid_hardware_model,
):
    corpus, _ = _fixture_case()
    run = _run(corpus)
    run["platform"]["hardware_class"] = invalid_hardware_model
    path = tmp_path / "run.json"
    path.write_text(json.dumps(run), encoding="utf-8")

    with pytest.raises(VoiceEvaluationError) as captured:
        load_voice_run(path, corpus)

    assert "hardware model identifier" in str(captured.value)
    assert invalid_hardware_model not in str(captured.value)


@pytest.mark.parametrize("invalid_version", [1, 2.0])
def test_run_schema_version_requires_exact_integer_two(
    tmp_path,
    invalid_version,
):
    corpus, _ = _fixture_case()
    run = _run(corpus)
    run["schema_version"] = invalid_version
    path = tmp_path / "invalid-run.json"
    path.write_text(json.dumps(run), encoding="utf-8")

    with pytest.raises(VoiceEvaluationError, match="schema_version must be 2"):
        load_voice_run(path, corpus)


def test_product_run_v2_accepts_explicit_model_and_artifact_identity(tmp_path):
    corpus, _ = _fixture_case()
    run = _run(corpus)
    path = tmp_path / "run-v2.json"
    path.write_text(json.dumps(run), encoding="utf-8")

    assert load_voice_run(path, corpus) == run


def test_product_run_v2_rejects_legacy_artifact_sha256_identity(tmp_path):
    corpus, _ = _fixture_case()
    run = _run(corpus)
    run["engine"]["artifact_sha256"] = run["engine"].pop(
        "artifact_content_sha256"
    )
    path = tmp_path / "legacy-run.json"
    path.write_text(json.dumps(run), encoding="utf-8")

    with pytest.raises(VoiceEvaluationError, match="unknown artifact_sha256"):
        load_voice_run(path, corpus)


@pytest.mark.parametrize(
    "field",
    ("artifact_id", "artifact_content_sha256", "model_id", "model_revision"),
)
def test_product_run_v2_requires_every_product_identity_field(tmp_path, field):
    corpus, _ = _fixture_case()
    run = _run(corpus)
    run["engine"].pop(field)
    path = tmp_path / "incomplete-run.json"
    path.write_text(json.dumps(run), encoding="utf-8")

    with pytest.raises(VoiceEvaluationError, match="requires product artifact identity"):
        load_voice_run(path, corpus)


@pytest.mark.parametrize(
    "field",
    ("artifact_id", "artifact_content_sha256", "model_id", "model_revision"),
)
def test_system_run_v2_prohibits_every_product_identity_field(tmp_path, field):
    corpus, _ = _fixture_case()
    run = _run(corpus, asset_management="system")
    run["engine"][field] = "e" * 64 if field.endswith("sha256") else "forbidden"
    path = tmp_path / "system-run.json"
    path.write_text(json.dumps(run), encoding="utf-8")

    with pytest.raises(VoiceEvaluationError, match="must not claim product identity"):
        load_voice_run(path, corpus)


def test_run_and_observation_json_reject_duplicate_keys_and_nan(tmp_path):
    corpus = _corpus([_sample("one", "一")])
    run = _run(corpus)
    run_path = tmp_path / "run.json"
    encoded = json.dumps(run)
    run_path.write_text(
        encoded[:-1] + ',"schema_version":1}', encoding="utf-8"
    )
    with pytest.raises(VoiceEvaluationError, match="invalid JSON"):
        load_voice_run(run_path, corpus)

    observations_path = tmp_path / "observations.jsonl"
    observations_path.write_text(
        '{"schema_version":1,"sample_id":"one","outcome":"final",'
        '"partials":[],"stop_received_elapsed_ms":0,'
        '"final":{"text":"一","elapsed_ms":NaN}}\n',
        encoding="utf-8",
    )
    with pytest.raises(VoiceEvaluationError, match="invalid JSON"):
        load_voice_observations(observations_path, corpus, run)


@pytest.mark.parametrize(
    "payload",
    [
        b"\xff",
        *deep_nesting_payloads(1 * 1_024 * 1_024),
        b'{"schema_version":' + b"9" * 5_000 + b"}",
    ],
)
def test_run_loader_normalizes_untrusted_json_parser_failures(
    tmp_path: Path,
    payload: bytes,
):
    path = tmp_path / "run.json"
    path.write_bytes(payload)

    with pytest.raises(VoiceEvaluationError, match="invalid JSON"):
        load_voice_run(path, object())


def test_run_loader_normalizes_an_unrepresentable_os_major_version(
    tmp_path: Path,
):
    corpus = _corpus([_sample("one", "一")])
    run = _run(corpus)
    run["platform"]["os_version"] = "9" * 5_000 + ".0"
    path = tmp_path / "run.json"
    path.write_text(json.dumps(run), encoding="utf-8")

    with pytest.raises(VoiceEvaluationError, match="os_version"):
        load_voice_run(path, corpus)


@pytest.mark.parametrize(
    "payload",
    [
        b"\xff\n",
        *(payload + b"\n" for payload in deep_nesting_payloads(1 * 1_024 * 1_024)),
        b'{"schema_version":' + b"9" * 5_000 + b"}\n",
    ],
)
def test_observation_loader_normalizes_untrusted_json_parser_failures(
    tmp_path: Path,
    payload: bytes,
):
    corpus = _corpus([_sample("one", "一")])
    run = _run(corpus)
    path = tmp_path / "observations.jsonl"
    path.write_bytes(payload)

    with pytest.raises(VoiceEvaluationError, match="invalid JSON"):
        load_voice_observations(path, corpus, run)


def test_run_gates_and_observation_loaders_enforce_byte_limits(
    tmp_path: Path,
):
    corpus = _corpus([_sample("one", "一")])
    run = _run(corpus)
    oversized = b" " * (1 * 1_024 * 1_024 + 1)

    run_path = tmp_path / "run.json"
    run_path.write_bytes(oversized)
    with pytest.raises(VoiceEvaluationError, match="too large"):
        load_voice_run(run_path, corpus)

    gates_path = tmp_path / "gates.json"
    gates_path.write_bytes(oversized)
    with pytest.raises(VoiceEvaluationError, match="too large"):
        load_voice_gates(gates_path)

    observations_path = tmp_path / "observations.jsonl"
    observations_path.write_bytes(oversized)
    with pytest.raises(VoiceEvaluationError, match="too large"):
        load_voice_observations(observations_path, corpus, run)


@pytest.mark.parametrize("invalid_version", [True, 2.0])
def test_observation_and_gate_schema_versions_require_exact_integers(
    tmp_path,
    invalid_version,
):
    corpus = _corpus([_sample("one", "一")])
    run = _run(corpus)
    observation = _final("one", "一")
    observation["schema_version"] = invalid_version
    observations_path = tmp_path / "observations.jsonl"
    observations_path.write_text(
        json.dumps(observation) + "\n",
        encoding="utf-8",
    )

    with pytest.raises(VoiceEvaluationError, match="schema_version must be 1"):
        load_voice_observations(observations_path, corpus, run)

    gates = _gates()
    gates["schema_version"] = invalid_version
    gates_path = tmp_path / "gates.json"
    gates_path.write_text(json.dumps(gates), encoding="utf-8")

    with pytest.raises(VoiceEvaluationError, match="schema_version must be 2"):
        load_voice_gates(gates_path)


def test_legacy_gate_schema_v1_is_rejected_instead_of_silently_ignoring_requirements(
    tmp_path: Path,
):
    gates = _gates()
    gates["schema_version"] = 1
    path = tmp_path / "legacy-gates.json"
    path.write_text(json.dumps(gates), encoding="utf-8")

    with pytest.raises(VoiceEvaluationError, match="schema_version must be 2"):
        load_voice_gates(path)


def test_observation_rejects_uncontrolled_sample_id_without_echoing_it(tmp_path):
    corpus = _corpus([_sample("one", "一")])
    run = _run(corpus)
    private_value = "private transcript 机密"
    observation = _final(private_value, "一")
    path = tmp_path / "observations.jsonl"
    path.write_text(json.dumps(observation) + "\n", encoding="utf-8")

    with pytest.raises(VoiceEvaluationError) as captured:
        load_voice_observations(path, corpus, run)

    assert "controlled non-sensitive identifier" in str(captured.value)
    assert private_value not in str(captured.value)


def test_observation_loader_rejects_missing_duplicate_and_extra_samples(tmp_path):
    corpus = _corpus([_sample("one", "一"), _sample("two", "二")])
    run = _run(corpus)
    path = tmp_path / "observations.jsonl"
    first = _final("one", "一")
    second = _final("two", "二")

    path.write_text(json.dumps(first) + "\n", encoding="utf-8")
    with pytest.raises(VoiceEvaluationError, match="incomplete"):
        load_voice_observations(path, corpus, run)

    path.write_text(
        json.dumps(first) + "\n" + json.dumps(first) + "\n",
        encoding="utf-8",
    )
    with pytest.raises(VoiceEvaluationError, match="duplicate"):
        load_voice_observations(path, corpus, run)

    extra = {**second, "sample_id": "three"}
    path.write_text(
        json.dumps(first) + "\n" + json.dumps(extra) + "\n",
        encoding="utf-8",
    )
    with pytest.raises(VoiceEvaluationError, match="not in corpus"):
        load_voice_observations(path, corpus, run)


@pytest.mark.parametrize(
    ("mutation", "message"),
    [
        (
            lambda value: value["partials"].append(
                {"sequence": 1, "text": "late", "elapsed_ms": 150}
            ),
            "sequence",
        ),
        (
            lambda value: value["partials"].append(
                {"sequence": 3, "text": "back", "elapsed_ms": 50}
            ),
            "time",
        ),
        (lambda value: value.update({"stop_received_elapsed_ms": 600}), "after final"),
    ],
)
def test_observation_rejects_non_monotonic_sequence_and_clocks(mutation, message):
    corpus = _corpus([_sample("one", "一")])
    observation = _final(
        "one",
        "一",
        partials=({"sequence": 1, "text": "一", "elapsed_ms": 100},),
    )
    mutation(observation)

    with pytest.raises(VoiceEvaluationError, match=message):
        evaluate_voice(corpus, _run(corpus), [observation])


def test_cancel_clock_must_precede_capture_stop():
    corpus = _corpus([_sample("one", "", blank=True, language="blank")])

    with pytest.raises(VoiceEvaluationError, match="after capture stopped"):
        evaluate_voice(
            corpus,
            _run(corpus),
            [_cancelled("one", cancel=200, capture_stopped=100)],
        )


def test_final_outcome_rejects_cancellation_only_fields():
    corpus = _corpus([_sample("one", "一")])
    observation = _final("one", "一")
    observation["capture_stopped_elapsed_ms"] = 450

    with pytest.raises(VoiceEvaluationError, match="incompatible cancellation"):
        evaluate_voice(corpus, _run(corpus), [observation])


def test_no_gates_is_measurement_only_and_never_claims_a_quality_gate_pass():
    corpus, observations = _fixture_case()

    report = evaluate_voice(corpus, _run(corpus), observations)

    assert report["decision"] == "measurement_only"
    assert "quality_gate_pass" not in report
    assert "release_pass" not in report
    assert "gates" not in report


def test_report_v2_contains_domain_separated_canonical_quality_digest():
    corpus, observations = _fixture_case()

    report = evaluate_voice(corpus, _run(corpus), observations)

    assert report["schema_version"] == 2
    payload = dict(report)
    digest = payload.pop("quality_report_sha256")
    canonical = json.dumps(
        payload,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
        allow_nan=False,
    ).encode("utf-8")
    assert digest == hashlib.sha256(
        b"rimeai.voice-quality-report.v2\x00" + canonical
    ).hexdigest()


def test_quality_digest_excludes_itself_and_binds_metrics_gates_and_model_provenance():
    corpus, observations = _release_case()
    run = _run(corpus)
    report = evaluate_voice(
        corpus,
        run,
        observations,
        performance_evidence=_performance_evidence(corpus, run),
        gates=_gates(),
    )
    original = report["quality_report_sha256"]

    self_changed = json.loads(json.dumps(report))
    self_changed["quality_report_sha256"] = "0" * 64
    assert quality_report_sha256(self_changed) == original

    mutations = []
    metrics_changed = json.loads(json.dumps(report))
    metrics_changed["metrics"]["mandarin_cer"]["edits"] += 1
    mutations.append(metrics_changed)
    gates_changed = json.loads(json.dumps(report))
    gates_changed["gates"]["mandarin_cer"]["actual"] = 0.125
    mutations.append(gates_changed)
    provenance_changed = json.loads(json.dumps(report))
    provenance_changed["provenance"]["implementation_fingerprint"] = "1" * 64
    mutations.append(provenance_changed)
    model_changed = json.loads(json.dumps(report))
    model_changed["provenance"]["engine"]["model_revision"] = "2026.08.2"
    mutations.append(model_changed)

    assert all(quality_report_sha256(value) != original for value in mutations)


def test_quality_report_binds_the_complete_performance_collector_evidence():
    corpus, observations = _release_case()
    run = _run(corpus)
    performance = _performance_evidence(corpus, run)

    report = evaluate_voice(
        corpus,
        run,
        observations,
        performance_evidence=performance,
    )
    original_report_digest = report["quality_report_sha256"]

    assert report["provenance"]["performance_evidence_sha256"] == (
        voice_performance_sha256(performance)
    )
    changed = json.loads(json.dumps(performance))
    changed["collector"]["executable_sha256"] = "d" * 64
    changed_report = evaluate_voice(
        corpus,
        run,
        observations,
        performance_evidence=changed,
    )
    assert changed_report["metrics"]["performance"] == report["metrics"][
        "performance"
    ]
    assert changed_report["provenance"]["performance_evidence_sha256"] != (
        report["provenance"]["performance_evidence_sha256"]
    )
    assert changed_report["quality_report_sha256"] != original_report_digest


def test_schema_v3_remains_available_for_unauthenticated_measurement():
    corpus, observations = _release_case()
    run = _run(corpus)

    report = evaluate_voice(
        corpus,
        run,
        observations,
        performance_evidence=_performance_evidence(corpus, run),
    )

    assert report["decision"] == "measurement_only"
    assert "quality_gate_pass" not in report
    assert report["provenance"]["authenticated_production_driver"] is False
    assert report["metrics"]["performance"][
        "authenticated_production_driver"
    ] is False
    assert report["metrics"]["performance"]["real_time_factor"]["p95"] == 0.5


def test_release_gate_without_performance_evidence_is_policy_incomplete():
    corpus, observations = _release_case()

    report = evaluate_voice(
        corpus,
        _run(corpus),
        observations,
        gates=_gates(),
    )

    assert report["decision"] == "policy_incomplete"
    assert report["quality_gate_pass"] is False
    assert "release_pass" not in report
    assert report["gates"]["performance_evidence_complete"] == {
        "actual": "missing",
        "threshold": (
            "valid authenticated production-driver performance evidence "
            "bound to this run"
        ),
        "passed": False,
        "evidence_complete": False,
    }


def test_schema_v3_performance_can_never_authenticate_a_release_gate():
    corpus, observations = _release_case()
    run = _run(corpus)

    report = evaluate_voice(
        corpus,
        run,
        observations,
        performance_evidence=_performance_evidence(corpus, run),
        gates=_gates(),
    )

    assert report["provenance"]["authenticated_production_driver"] is False
    assert report["metrics"]["performance"][
        "authenticated_production_driver"
    ] is False
    assert report["gates"]["gate_policy_complete"]["evidence_complete"] is False
    assert report["gates"]["performance_evidence_complete"][
        "evidence_complete"
    ] is False
    assert report["gates"]["authenticated_production_driver"] == {
        "actual": False,
        "threshold": True,
        "passed": False,
        "evidence_complete": False,
    }
    assert report["decision"] == "policy_incomplete"
    assert report["quality_gate_pass"] is False


def test_incomplete_gate_policy_is_a_reported_release_failure(tmp_path):
    corpus, observations = _release_case()
    run = _run(corpus)
    gates = _gates()
    gates["thresholds"].pop("mandarin_cer_max")
    path = tmp_path / "gates.json"
    path.write_text(json.dumps(gates), encoding="utf-8")

    loaded = load_voice_gates(path)
    report = evaluate_voice(
        corpus,
        run,
        observations,
        performance_evidence=_performance_evidence(corpus, run),
        gates=loaded,
    )

    assert report["decision"] == "policy_incomplete"
    assert report["quality_gate_pass"] is False


def test_complete_numeric_policy_remains_measured_but_v3_cannot_pass():
    corpus, observations = _release_case()
    run = _run(corpus)

    report = evaluate_voice(
        corpus,
        run,
        observations,
        performance_evidence=_performance_evidence(corpus, run),
        gates=_gates(),
    )

    assert report["decision"] == "policy_incomplete"
    assert report["quality_gate_pass"] is False
    assert "release_pass" not in report
    assert report["gates"]["authenticated_production_driver"]["passed"] is False
    assert report["gates"]["mandarin_cer"]["passed"] is True
    assert report["gates"]["real_time_factor_p95"]["passed"] is True


def test_resource_and_keyboard_thresholds_are_mandatory_and_fail_closed():
    corpus, observations = _release_case()
    run = _run(corpus)
    gates = _gates()
    gates["thresholds"]["product_artifact_payload_bytes_max"] = 10
    gates["thresholds"]["keyboard_helper_loaded_added_p95_ms_max"] = 1

    report = evaluate_voice(
        corpus,
        run,
        observations,
        performance_evidence=_performance_evidence(corpus, run),
        gates=gates,
    )

    assert report["decision"] == "policy_incomplete"
    assert report["quality_gate_pass"] is False
    assert report["gates"]["product_artifact_payload_bytes"]["passed"] is False
    assert report["gates"]["keyboard_helper_loaded_added_p95_ms"][
        "passed"
    ] is False
    assert report["gates"]["keyboard_late_voice_commit_zero"]["passed"] is True
    assert report["metrics"]["performance"]["real_time_factor"]["p95"] == 0.5


def test_gate_rechecks_frozen_sample_count_even_for_constructed_corpus():
    full_corpus, full_observations = _release_case()
    corpus = replace(full_corpus, samples=full_corpus.samples[:5])
    observations = full_observations[:5]
    run = _run(corpus)

    report = evaluate_voice(
        corpus,
        run,
        observations,
        performance_evidence=_performance_evidence(corpus, run),
        gates=_gates(),
    )

    assert report["decision"] == "policy_incomplete"
    assert report["quality_gate_pass"] is False
    assert report["gates"]["frozen_non_fixture_evidence"]["passed"] is False


def test_fixture_system_macos_14_and_missing_required_subset_fail_closed():
    corpus, observations = _release_case()
    system_run = _run(corpus, asset_management="system", os_version="14.7")

    system = evaluate_voice(
        corpus,
        system_run,
        observations,
        performance_evidence=_performance_evidence(corpus, system_run),
        gates=_gates(),
    )
    assert system["quality_gate_pass"] is False
    assert system["decision"] == "policy_incomplete"
    assert system["gates"]["engine_policy_eligible"]["passed"] is False

    system_25_run = _run(corpus, asset_management="system", os_version="25.0")
    system_25 = evaluate_voice(
        corpus,
        system_25_run,
        observations,
        performance_evidence=_performance_evidence(corpus, system_25_run),
        gates=_gates(),
    )
    assert system_25["decision"] == "policy_incomplete"
    assert system_25["gates"]["engine_policy_eligible"]["passed"] is False

    not_on_device_run = _run(corpus)
    not_on_device_run["engine"]["supports_on_device_at_run"] = False
    not_on_device = evaluate_voice(
        corpus,
        not_on_device_run,
        observations,
        performance_evidence=_performance_evidence(corpus, not_on_device_run),
        gates=_gates(),
    )
    assert not_on_device["decision"] == "policy_incomplete"
    assert not_on_device["gates"]["on_device_runtime_eligible"]["passed"] is False

    fixture_corpus = replace(
        corpus,
        manifest=replace(corpus.manifest, purpose="fixture", synthetic_fixture=True),
    )
    fixture_run = _run(fixture_corpus)
    fixture = evaluate_voice(
        fixture_corpus,
        fixture_run,
        observations,
        performance_evidence=_performance_evidence(fixture_corpus, fixture_run),
        gates=_gates(),
    )
    assert fixture["quality_gate_pass"] is False
    assert fixture["gates"]["frozen_non_fixture_evidence"]["passed"] is False

    missing_run = _run(corpus)
    missing = evaluate_voice(
        corpus,
        missing_run,
        observations,
        performance_evidence=_performance_evidence(corpus, missing_run),
        gates=_gates(
            required=[{"dimension": "noise", "value": "keyboard_noise"}]
        ),
    )
    assert missing["quality_gate_pass"] is False
    assert missing["decision"] == "policy_incomplete"
    assert missing["gates"]["required_subset:noise:keyboard_noise"]["passed"] is False


def test_an_unmeasured_mandatory_metric_fails_closed():
    corpus = _corpus([_sample("blank", "", blank=True, language="blank")])
    observation = {
        "schema_version": 1,
        "sample_id": "blank",
        "outcome": "error",
        "partials": [],
    }

    run = _run(corpus)
    report = evaluate_voice(
        corpus,
        run,
        [observation],
        performance_evidence=_performance_evidence(corpus, run),
        gates=_gates(),
    )

    assert report["quality_gate_pass"] is False
    assert report["gates"]["mandarin_cer"]["actual"] is None
    assert report["gates"]["mandarin_cer"]["passed"] is False


def test_hotword_gate_requires_strict_ab_and_reports_gain_and_regression():
    corpus, candidate_observations = _release_case()
    candidate_run = _run(corpus, hotwords=True, implementation="1" * 64)
    baseline_run = _run(corpus, hotwords=False, implementation="2" * 64)
    baseline_observations = [dict(value) for value in candidate_observations]
    for index in range(0, len(baseline_observations), 5):
        sample_id = baseline_observations[index]["sample_id"]
        baseline_observations[index] = _final(
            sample_id,
            "数字3, walk away!",
            partials=(
                {"sequence": 1, "text": "数字", "elapsed_ms": 100},
                {"sequence": 2, "text": "数字3", "elapsed_ms": 200},
            ),
        )

    report = evaluate_voice(
        corpus,
        candidate_run,
        candidate_observations,
        baseline_run=baseline_run,
        baseline_observations=baseline_observations,
        performance_evidence=_performance_evidence(corpus, candidate_run),
        gates=_gates(hotwords=True),
    )

    assert report["comparison"]["technical_term_exact_gain_pp"] == 33.3334
    assert report["comparison"]["mandarin_cer_regression_pp"] == 0
    assert report["gates"]["unheated_comparable_baseline"]["passed"] is True
    assert report["decision"] == "policy_incomplete"
    assert report["quality_gate_pass"] is False


def test_hotword_gate_without_baseline_fails_and_incomparable_ab_raises():
    corpus, observations = _release_case()
    candidate_run = _run(corpus, hotwords=True, implementation="1" * 64)

    missing = evaluate_voice(
        corpus,
        candidate_run,
        observations,
        performance_evidence=_performance_evidence(corpus, candidate_run),
        gates=_gates(hotwords=True),
    )
    assert missing["quality_gate_pass"] is False
    assert missing["gates"]["unheated_comparable_baseline"]["passed"] is False

    baseline_run = _run(corpus, implementation="2" * 64)
    baseline_run["audio_io"] = {**baseline_run["audio_io"], "sample_rate_hz": 48_000}
    with pytest.raises(VoiceEvaluationError, match="not comparable: audio_io"):
        evaluate_voice(
            corpus,
            candidate_run,
            observations,
            baseline_run=baseline_run,
            baseline_observations=observations,
        )


def test_compare_aggregate_reports_uses_the_same_strict_contract():
    corpus, observations = _fixture_case()
    baseline = evaluate_voice(corpus, _run(corpus), observations)
    candidate_run = _run(corpus, hotwords=True, implementation="7" * 64)
    candidate = evaluate_voice(corpus, candidate_run, observations)

    comparison = compare_voice_reports(baseline, candidate)

    assert comparison["technical_term_exact_gain_pp"] == 0
    assert comparison["mandarin_cer_regression_pp"] == 0


@pytest.mark.parametrize(
    "field",
    (
        "adapter_id",
        "engine_id",
        "artifact_id",
        "artifact_content_sha256",
        "model_id",
        "model_revision",
    ),
)
def test_product_identity_is_aggregated_and_required_for_ab_comparability(field):
    corpus, observations = _fixture_case()
    candidate_run = _run(corpus, implementation="1" * 64)
    report = evaluate_voice(corpus, candidate_run, observations)
    assert report["provenance"]["engine"][field] == candidate_run["engine"][field]

    baseline_run = _run(corpus, implementation="2" * 64)
    baseline_run["engine"][field] = (
        "3" * 64 if field == "artifact_content_sha256" else "different-id"
    )
    with pytest.raises(VoiceEvaluationError, match="not comparable: engine"):
        evaluate_voice(
            corpus,
            candidate_run,
            observations,
            baseline_run=baseline_run,
            baseline_observations=observations,
        )
