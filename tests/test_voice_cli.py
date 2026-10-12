import json
import io
from pathlib import Path
from types import SimpleNamespace

from rimeai_eval import cli
from deep_json import deep_nesting_payloads
from rimeai_eval.voice_performance import voice_run_sha256
from test_voice_evaluation import _gates as _voice_gates
from test_voice_evaluation import _performance_evidence
from test_voice_evaluation import _release_case
from test_voice_evaluation import _run as _voice_run


class _BinaryStdin:
    def __init__(self, payload: bytes):
        self.buffer = io.BytesIO(payload)


def _performance_cli_inputs():
    sample = SimpleNamespace(
        id="voice-000001",
        audio=SimpleNamespace(duration_ms=1_000),
    )
    corpus = SimpleNamespace(fingerprint="a" * 64, samples=(sample,))
    run = {
        "evaluation_profile_id": "voice-release-plan-2026q3",
        "implementation_fingerprint": "d" * 64,
        "engine": {"asset_management": "system"},
        "platform": {"hardware_class": "Mac15.7"},
    }

    def process(role: str, offset: int) -> dict:
        return {
            "role": role,
            "instance_id": f"{role}-instance",
            "start_user_cpu_ns": offset,
            "end_user_cpu_ns": offset + 1,
            "start_system_cpu_ns": offset,
            "end_system_cpu_ns": offset + 1,
            "start_energy_nj": offset,
            "end_energy_nj": offset + 1,
            "baseline_resident_bytes": 1,
            "peak_resident_bytes": 1,
            "baseline_phys_footprint_bytes": 1,
            "peak_phys_footprint_bytes": 1,
            "sample_count": 2,
            "maximum_sample_gap_ms": 1,
        }

    roles = ("input_method", "candidate_service", "voice_helper")
    evidence = {
        "schema_version": 3,
        "evaluation_profile_id": run["evaluation_profile_id"],
        "corpus_fingerprint": corpus.fingerprint,
        "implementation_fingerprint": run["implementation_fingerprint"],
        "run_sha256": voice_run_sha256(run),
        "collection_protocol": {
            "id": "rimeai-release-collection-v1",
            "sha256": "7" * 64,
        },
        "artifact": None,
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
            "hardware_model": "Mac15.7",
            "physical_memory_bytes": 1,
            "logical_cpu_count": 1,
            "power_source": "ac",
            "low_power_mode": False,
            "thermal_state_start": "nominal",
            "thermal_state_end": "nominal",
        },
        "required_process_roles": list(roles),
        "cold_artifact_load_ms": [1],
        "sessions": [
            {
                "sample_id": sample.id,
                "audio_duration_ms": sample.audio.duration_ms,
                "processing_duration_ms": 1,
                "processes": [
                    process(role, index * 10) for index, role in enumerate(roles)
                ],
            }
        ],
        "keyboard_trials": [
            {
                "sequence": 1,
                "phase": phase,
                "rime_candidate_latency_ms": 1,
            }
            for phase in (
                "baseline",
                "helper_loaded_idle",
                "listening_cancel_to_rime",
            )
        ],
        "late_voice_commit_count": 0,
        "late_challenge_counts": {
            "cancel": 0,
            "application_switch": 0,
            "secure_input": 0,
            "target_invalidation": 0,
            "keyboard_input": 0,
        },
    }
    return corpus, run, evidence


def test_validate_voice_uses_the_requested_profile(
    tmp_path: Path, monkeypatch, capsys
):
    corpus_root = tmp_path / "corpus"
    corpus_root.mkdir()
    calls = []

    def load_corpus(path, expected_profile=None):
        calls.append((path, expected_profile))
        return object()

    monkeypatch.setattr(cli, "load_voice_corpus", load_corpus)

    exit_code = cli.main(
        [
            "validate-voice",
            str(corpus_root),
            "--profile",
            "fixture",
        ]
    )

    captured = capsys.readouterr()
    assert exit_code == 0
    assert calls == [(corpus_root, "fixture")]
    assert json.loads(captured.out) == {
        "kind": "voice_corpus_validation",
        "profile": "fixture",
        "schema_version": 1,
        "valid": True,
    }
    assert captured.err == ""


def test_collect_voice_performance_uses_live_stdin_and_writes_only_validated_output(
    tmp_path: Path,
    monkeypatch,
    capsys,
):
    corpus = object()
    run = object()
    plan = object()
    performance = {"schema_version": 2}
    event_payload = b'{"schema_version":1,"event":"finish"}\n'
    stdin = _BinaryStdin(event_payload)
    calls = []
    monkeypatch.setattr(cli.sys, "stdin", stdin)
    monkeypatch.setattr(
        cli,
        "load_voice_corpus",
        lambda path, expected_profile=None: corpus,
    )
    monkeypatch.setattr(cli, "load_voice_run", lambda path, value: run)
    monkeypatch.setattr(
        cli,
        "load_voice_collection_plan",
        lambda path, value: plan,
    )

    def collect(loaded_corpus, loaded_run, loaded_plan, native, events):
        assert (loaded_corpus, loaded_run, loaded_plan) == (corpus, run, plan)
        assert native == tmp_path / "native-collector"
        assert events is stdin.buffer
        calls.append("collect")
        return performance

    def write(value, path):
        assert value is performance
        assert path == tmp_path / "performance.json"
        calls.append("write")
        return "a" * 64

    monkeypatch.setattr(cli, "collect_voice_performance", collect)
    monkeypatch.setattr(cli, "write_voice_performance_atomic", write)

    exit_code = cli.main(
        [
            "collect-voice-performance",
            str(tmp_path / "corpus"),
            str(tmp_path / "run.json"),
            str(tmp_path / "plan.json"),
            "--native-collector",
            str(tmp_path / "native-collector"),
            "--output",
            str(tmp_path / "performance.json"),
        ]
    )

    captured = capsys.readouterr()
    assert exit_code == 0
    assert calls == ["collect", "write"]
    assert json.loads(captured.out) == {
        "kind": "voice_performance_collection",
        "schema_version": 2,
        "sha256": "a" * 64,
        "valid": True,
    }
    assert captured.err == ""


def test_collect_voice_performance_failure_is_exit_two_without_output(
    tmp_path: Path,
    monkeypatch,
    capsys,
):
    monkeypatch.setattr(cli.sys, "stdin", _BinaryStdin(b""))
    monkeypatch.setattr(
        cli,
        "load_voice_corpus",
        lambda path, expected_profile=None: object(),
    )
    monkeypatch.setattr(cli, "load_voice_run", lambda path, value: object())
    monkeypatch.setattr(
        cli,
        "load_voice_collection_plan",
        lambda path, value: object(),
    )
    monkeypatch.setattr(
        cli,
        "collect_voice_performance",
        lambda *args: (_ for _ in ()).throw(
            cli.VoicePerformanceCollectionError(
                "native voice performance collector rejected the collection"
            )
        ),
    )

    exit_code = cli.main(
        [
            "collect-voice-performance",
            str(tmp_path / "corpus"),
            str(tmp_path / "run.json"),
            str(tmp_path / "plan.json"),
            "--native-collector",
            str(tmp_path / "native-collector"),
            "--output",
            str(tmp_path / "performance.json"),
        ]
    )

    captured = capsys.readouterr()
    assert exit_code == 2
    assert captured.out == ""
    assert "rejected the collection" in captured.err
    assert not (tmp_path / "performance.json").exists()


def test_collect_voice_performance_rejects_a_5000_digit_plan_number_cleanly(
    tmp_path: Path,
    monkeypatch,
    capsys,
):
    plan_path = tmp_path / "plan.json"
    plan_path.write_bytes(b'{"schema_version":' + b"9" * 5_000 + b"}")
    monkeypatch.setattr(cli.sys, "stdin", _BinaryStdin(b""))
    monkeypatch.setattr(cli, "load_voice_corpus", lambda path: object())
    monkeypatch.setattr(cli, "load_voice_run", lambda path, corpus: object())

    exit_code = cli.main(
        [
            "collect-voice-performance",
            str(tmp_path / "corpus"),
            str(tmp_path / "run.json"),
            str(plan_path),
            "--native-collector",
            str(tmp_path / "native-collector"),
            "--output",
            str(tmp_path / "performance.json"),
        ]
    )

    captured = capsys.readouterr()
    assert exit_code == 2
    assert captured.out == ""
    assert "Traceback" not in captured.err


def test_collect_voice_performance_never_overwrites_an_input_path(
    tmp_path: Path,
    monkeypatch,
    capsys,
):
    run_path = tmp_path / "run.json"
    run_path.write_text('{"sentinel":true}\n', encoding="utf-8")
    monkeypatch.setattr(cli.sys, "stdin", _BinaryStdin(b""))

    exit_code = cli.main(
        [
            "collect-voice-performance",
            str(tmp_path / "corpus"),
            str(run_path),
            str(tmp_path / "plan.json"),
            "--native-collector",
            str(tmp_path / "native-collector"),
            "--output",
            str(run_path),
        ]
    )

    captured = capsys.readouterr()
    assert exit_code == 2
    assert captured.out == ""
    assert "must not overwrite" in captured.err
    assert run_path.read_text(encoding="utf-8") == '{"sentinel":true}\n'


def test_collect_voice_performance_never_writes_into_the_artifact_directory(
    tmp_path: Path,
    monkeypatch,
    capsys,
):
    artifact_directory = tmp_path / "artifact"
    artifact_directory.mkdir()
    protected_model = artifact_directory / "model.onnx"
    protected_model.write_bytes(b"model-bytes")
    plan = {
        "artifact_directory": str(artifact_directory),
        "processes": [],
    }
    monkeypatch.setattr(cli.sys, "stdin", _BinaryStdin(b""))
    monkeypatch.setattr(
        cli,
        "load_voice_corpus",
        lambda path, expected_profile=None: object(),
    )
    monkeypatch.setattr(cli, "load_voice_run", lambda path, value: object())
    monkeypatch.setattr(
        cli,
        "load_voice_collection_plan",
        lambda path, value: plan,
    )
    monkeypatch.setattr(
        cli,
        "collect_voice_performance",
        lambda *args: (_ for _ in ()).throw(AssertionError("must not collect")),
    )

    exit_code = cli.main(
        [
            "collect-voice-performance",
            str(tmp_path / "corpus"),
            str(tmp_path / "run.json"),
            str(tmp_path / "plan.json"),
            "--native-collector",
            str(tmp_path / "native-collector"),
            "--output",
            str(protected_model),
        ]
    )

    captured = capsys.readouterr()
    assert exit_code == 2
    assert captured.out == ""
    assert "must not overwrite" in captured.err
    assert protected_model.read_bytes() == b"model-bytes"


def test_collect_voice_performance_never_overwrites_a_measured_executable(
    tmp_path: Path,
    monkeypatch,
    capsys,
):
    measured_executable = tmp_path / "voice-helper"
    measured_executable.write_bytes(b"executable-bytes")
    plan = {
        "artifact_directory": None,
        "processes": [
            {"expected_executable_path": str(measured_executable)},
        ],
    }
    monkeypatch.setattr(cli.sys, "stdin", _BinaryStdin(b""))
    monkeypatch.setattr(
        cli,
        "load_voice_corpus",
        lambda path, expected_profile=None: object(),
    )
    monkeypatch.setattr(cli, "load_voice_run", lambda path, value: object())
    monkeypatch.setattr(
        cli,
        "load_voice_collection_plan",
        lambda path, value: plan,
    )
    monkeypatch.setattr(
        cli,
        "collect_voice_performance",
        lambda *args: (_ for _ in ()).throw(AssertionError("must not collect")),
    )

    exit_code = cli.main(
        [
            "collect-voice-performance",
            str(tmp_path / "corpus"),
            str(tmp_path / "run.json"),
            str(tmp_path / "plan.json"),
            "--native-collector",
            str(tmp_path / "native-collector"),
            "--output",
            str(measured_executable),
        ]
    )

    captured = capsys.readouterr()
    assert exit_code == 2
    assert captured.out == ""
    assert "must not overwrite" in captured.err
    assert measured_executable.read_bytes() == b"executable-bytes"


def test_collect_voice_performance_reports_a_symlink_loop_as_controlled_input_error(
    tmp_path: Path,
    monkeypatch,
    capsys,
):
    first = tmp_path / "first"
    second = tmp_path / "second"
    first.symlink_to(second)
    second.symlink_to(first)
    monkeypatch.setattr(cli.sys, "stdin", _BinaryStdin(b""))

    exit_code = cli.main(
        [
            "collect-voice-performance",
            str(tmp_path / "corpus"),
            str(tmp_path / "run.json"),
            str(tmp_path / "plan.json"),
            "--native-collector",
            str(tmp_path / "native-collector"),
            "--output",
            str(first),
        ]
    )

    captured = capsys.readouterr()
    assert exit_code == 2
    assert captured.out == ""
    assert captured.err == "error: collection path cannot be resolved\n"


def test_collect_voice_performance_writes_to_the_preflighted_output_target(
    tmp_path: Path,
    monkeypatch,
    capsys,
):
    safe_directory = tmp_path / "safe"
    artifact_directory = tmp_path / "artifact"
    safe_directory.mkdir()
    artifact_directory.mkdir()
    output_parent = tmp_path / "output-parent"
    output_parent.symlink_to(safe_directory, target_is_directory=True)
    requested_output = output_parent / "performance.json"
    expected_output = safe_directory / "performance.json"
    plan = {
        "artifact_directory": str(artifact_directory),
        "processes": [],
    }
    performance = {"schema_version": 2}
    monkeypatch.setattr(cli.sys, "stdin", _BinaryStdin(b""))
    monkeypatch.setattr(
        cli,
        "load_voice_corpus",
        lambda path, expected_profile=None: object(),
    )
    monkeypatch.setattr(cli, "load_voice_run", lambda path, value: object())
    monkeypatch.setattr(
        cli,
        "load_voice_collection_plan",
        lambda path, value: plan,
    )

    def collect(*args):
        output_parent.unlink()
        output_parent.symlink_to(artifact_directory, target_is_directory=True)
        return performance

    written_paths = []

    def write(value, path):
        assert value is performance
        written_paths.append(path)
        return "a" * 64

    monkeypatch.setattr(cli, "collect_voice_performance", collect)
    monkeypatch.setattr(cli, "write_voice_performance_atomic", write)

    exit_code = cli.main(
        [
            "collect-voice-performance",
            str(tmp_path / "corpus"),
            str(tmp_path / "run.json"),
            str(tmp_path / "plan.json"),
            "--native-collector",
            str(tmp_path / "native-collector"),
            "--output",
            str(requested_output),
        ]
    )

    captured = capsys.readouterr()
    assert exit_code == 0
    assert captured.err == ""
    assert written_paths == [expected_output]


def test_validate_voice_reports_invalid_input_as_exit_two(
    tmp_path: Path, monkeypatch, capsys
):
    corpus_root = tmp_path / "invalid-corpus"

    def reject_corpus(path, expected_profile=None):
        assert expected_profile == "frozen_quality"
        raise cli.VoiceDatasetError(
            "manifest.json",
            None,
            "purpose does not match expected_profile",
        )

    monkeypatch.setattr(cli, "load_voice_corpus", reject_corpus)

    exit_code = cli.main(
        [
            "validate-voice",
            str(corpus_root),
            "--profile",
            "frozen-quality",
        ]
    )

    captured = capsys.readouterr()
    assert exit_code == 2
    assert captured.out == ""
    assert captured.err == (
        "error: manifest.json: purpose does not match expected_profile\n"
    )
    assert "Traceback" not in captured.err


def test_evaluate_voice_measurement_omits_gate_pass_and_raw_text(
    tmp_path: Path, monkeypatch, capsys
):
    secret = "绝密原始听写文本-不得进入聚合输出"
    corpus_root = tmp_path / "corpus"
    corpus_root.mkdir()
    run_path = tmp_path / "run.json"
    observations_path = tmp_path / "observations.jsonl"
    run_path.write_text(secret, encoding="utf-8")
    observations_path.write_text(secret, encoding="utf-8")

    corpus = object()
    run = object()
    observations = object()

    monkeypatch.setattr(
        cli,
        "load_voice_corpus",
        lambda path, expected_profile=None: corpus,
    )

    def load_run(path, loaded_corpus):
        assert loaded_corpus is corpus
        assert path.read_text(encoding="utf-8") == secret
        return run

    def load_observations(path, loaded_corpus, loaded_run):
        assert loaded_corpus is corpus
        assert loaded_run is run
        assert path.read_text(encoding="utf-8") == secret
        return observations

    def evaluate(
        loaded_corpus,
        loaded_run,
        loaded_observations,
        *,
        baseline_run=None,
        baseline_observations=None,
        gates=None,
    ):
        assert loaded_corpus is corpus
        assert loaded_run is run
        assert loaded_observations is observations
        assert baseline_run is None
        assert baseline_observations is None
        assert gates is None
        # The CLI strips a stale release decision from measurement-only output.
        return {
            "schema_version": 2,
            "decision": "measurement_only",
            "metrics": {"cer": 0.1, "wer": 0.2},
            "quality_gate_pass": True,
            "release_pass": True,
        }

    monkeypatch.setattr(cli, "load_voice_run", load_run)
    monkeypatch.setattr(cli, "load_voice_observations", load_observations)
    monkeypatch.setattr(cli, "evaluate_voice", evaluate)

    exit_code = cli.main(
        [
            "evaluate-voice",
            str(corpus_root),
            str(run_path),
            str(observations_path),
        ]
    )

    captured = capsys.readouterr()
    report = json.loads(captured.out)
    assert exit_code == 0
    assert report["decision"] == "measurement_only"
    assert "quality_gate_pass" not in report
    assert "release_pass" not in report
    assert secret not in captured.out
    assert secret not in captured.err
    assert captured.err == ""


def test_evaluate_voice_incomplete_gate_is_exit_one(
    tmp_path: Path, monkeypatch, capsys
):
    corpus_root = tmp_path / "corpus"
    run_path = tmp_path / "run.json"
    observations_path = tmp_path / "observations.jsonl"
    gates_path = tmp_path / "gates.json"
    corpus = object()
    run = object()
    observations = object()
    gates = object()

    monkeypatch.setattr(
        cli,
        "load_voice_corpus",
        lambda path, expected_profile=None: corpus,
    )
    monkeypatch.setattr(cli, "load_voice_run", lambda path, value: run)
    monkeypatch.setattr(
        cli,
        "load_voice_observations",
        lambda path, value, loaded_run: observations,
    )
    monkeypatch.setattr(cli, "load_voice_gates", lambda path: gates)
    monkeypatch.setattr(
        cli,
        "evaluate_voice",
        lambda *args, **kwargs: {
            "schema_version": 2,
            "decision": "policy_incomplete",
            "quality_gate_pass": False,
            "release_pass": True,
            "gates": {"complete": False},
        },
    )

    exit_code = cli.main(
        [
            "evaluate-voice",
            str(corpus_root),
            str(run_path),
            str(observations_path),
            "--gates-config",
            str(gates_path),
        ]
    )

    captured = capsys.readouterr()
    assert exit_code == 1
    report = json.loads(captured.out)
    assert report["quality_gate_pass"] is False
    assert "release_pass" not in report
    assert captured.err == ""


def test_evaluate_voice_schema_v3_performance_is_always_exit_one(
    tmp_path: Path,
    monkeypatch,
    capsys,
):
    corpus, observations = _release_case()
    run = _voice_run(corpus)
    performance = _performance_evidence(corpus, run)
    gates = _voice_gates()
    monkeypatch.setattr(cli, "load_voice_corpus", lambda path: corpus)
    monkeypatch.setattr(cli, "load_voice_run", lambda path, value: run)
    monkeypatch.setattr(
        cli,
        "load_voice_observations",
        lambda path, value, loaded_run: observations,
    )
    monkeypatch.setattr(
        cli,
        "load_voice_performance",
        lambda path, loaded_corpus, loaded_run: performance,
    )
    monkeypatch.setattr(cli, "load_voice_gates", lambda path: gates)

    exit_code = cli.main(
        [
            "evaluate-voice",
            str(tmp_path / "corpus"),
            str(tmp_path / "run.json"),
            str(tmp_path / "observations.jsonl"),
            "--gates-config",
            str(tmp_path / "gates.json"),
            "--performance-evidence",
            str(tmp_path / "performance.json"),
        ]
    )

    report = json.loads(capsys.readouterr().out)
    assert exit_code == 1
    assert report["decision"] == "policy_incomplete"
    assert report["quality_gate_pass"] is False
    assert report["provenance"]["authenticated_production_driver"] is False


def test_evaluate_voice_gate_pass_is_exit_zero(
    tmp_path: Path, monkeypatch, capsys
):
    corpus = object()
    run = object()
    observations = object()
    gates = object()
    monkeypatch.setattr(
        cli,
        "load_voice_corpus",
        lambda path, expected_profile=None: corpus,
    )
    monkeypatch.setattr(cli, "load_voice_run", lambda path, value: run)
    monkeypatch.setattr(
        cli,
        "load_voice_observations",
        lambda path, value, loaded_run: observations,
    )
    monkeypatch.setattr(cli, "load_voice_gates", lambda path: gates)
    monkeypatch.setattr(
        cli,
        "evaluate_voice",
        lambda *args, **kwargs: {
            "schema_version": 2,
            "decision": "pass",
            "quality_gate_pass": True,
        },
    )

    exit_code = cli.main(
        [
            "evaluate-voice",
            str(tmp_path / "corpus"),
            str(tmp_path / "run.json"),
            str(tmp_path / "observations.jsonl"),
            "--gates-config",
            str(tmp_path / "gates.json"),
        ]
    )

    captured = capsys.readouterr()
    assert exit_code == 0
    report = json.loads(captured.out)
    assert report["quality_gate_pass"] is True
    assert "release_pass" not in report
    assert captured.err == ""


def test_evaluate_voice_loads_and_forwards_performance_evidence(
    tmp_path: Path, monkeypatch, capsys
):
    corpus = object()
    run = object()
    observations = object()
    gates = object()
    performance = object()
    performance_path = tmp_path / "performance.json"
    calls = []

    monkeypatch.setattr(cli, "load_voice_corpus", lambda path: corpus)
    monkeypatch.setattr(cli, "load_voice_run", lambda path, value: run)
    monkeypatch.setattr(
        cli,
        "load_voice_observations",
        lambda path, value, loaded_run: observations,
    )
    monkeypatch.setattr(cli, "load_voice_gates", lambda path: gates)

    def load_performance(path, loaded_corpus, loaded_run):
        calls.append((path, loaded_corpus, loaded_run))
        return performance

    def evaluate(loaded_corpus, loaded_run, loaded_observations, **kwargs):
        assert loaded_corpus is corpus
        assert loaded_run is run
        assert loaded_observations is observations
        assert kwargs["performance_evidence"] is performance
        assert kwargs["gates"] is gates
        return {
            "schema_version": 2,
            "decision": "pass",
            "quality_gate_pass": True,
        }

    monkeypatch.setattr(cli, "load_voice_performance", load_performance)
    monkeypatch.setattr(cli, "evaluate_voice", evaluate)

    exit_code = cli.main(
        [
            "evaluate-voice",
            str(tmp_path / "corpus"),
            str(tmp_path / "run.json"),
            str(tmp_path / "observations.jsonl"),
            "--gates-config",
            str(tmp_path / "gates.json"),
            "--performance-evidence",
            str(performance_path),
        ]
    )

    captured = capsys.readouterr()
    assert exit_code == 0
    assert calls == [(performance_path, corpus, run)]
    report = json.loads(captured.out)
    assert report["quality_gate_pass"] is True
    assert "release_pass" not in report
    assert captured.err == ""


def test_evaluate_voice_rejects_hostile_performance_json_without_output_or_echo(
    tmp_path: Path,
    monkeypatch,
    capsys,
):
    corpus, run, evidence = _performance_cli_inputs()
    observations = object()
    secret = "private transcript 机密"
    monkeypatch.setattr(cli, "load_voice_corpus", lambda path: corpus)
    monkeypatch.setattr(cli, "load_voice_run", lambda path, value: run)
    monkeypatch.setattr(
        cli,
        "load_voice_observations",
        lambda path, value, loaded_run: observations,
    )

    top_level = {**evidence, secret: True}
    nested = json.loads(json.dumps(evidence))
    nested["sessions"][0]["processes"][0][secret] = True
    huge_numeric = json.loads(json.dumps(evidence))
    huge_numeric["cold_artifact_load_ms"][0] = 10**309
    huge_counter = json.loads(json.dumps(evidence))
    huge_counter["sessions"][0]["processes"][0]["end_energy_nj"] = 1 << 64
    payloads = [
        json.dumps(top_level, ensure_ascii=False).encode("utf-8"),
        json.dumps(nested, ensure_ascii=False).encode("utf-8"),
        json.dumps(huge_numeric).encode("utf-8"),
        json.dumps(huge_counter).encode("utf-8"),
        b"\xff",
        *deep_nesting_payloads(16 * 1_024 * 1_024),
        b'{"schema_version":' + b"9" * 5_000 + b"}",
    ]
    for index, payload in enumerate(payloads):
        performance_path = tmp_path / f"performance-{index}.json"
        performance_path.write_bytes(payload)

        exit_code = cli.main(
            [
                "evaluate-voice",
                str(tmp_path / "corpus"),
                str(tmp_path / "run.json"),
                str(tmp_path / "observations.jsonl"),
                "--performance-evidence",
                str(performance_path),
            ]
        )

        captured = capsys.readouterr()
        assert exit_code == 2
        assert captured.out == ""
        assert secret not in captured.err
        assert "Traceback" not in captured.err


def test_evaluate_voice_rejects_huge_gate_numbers_without_a_traceback(
    tmp_path: Path,
    monkeypatch,
    capsys,
):
    corpus = object()
    run = object()
    observations = object()
    monkeypatch.setattr(cli, "load_voice_corpus", lambda path: corpus)
    monkeypatch.setattr(cli, "load_voice_run", lambda path, value: run)
    monkeypatch.setattr(
        cli,
        "load_voice_observations",
        lambda path, value, loaded_run: observations,
    )
    payloads = [
        json.dumps(
            {
                "schema_version": 2,
                "evaluation_profile_id": "voice-release-plan-2026q3",
                "required_subsets": [],
                "thresholds": {"mandarin_cer_max": 10**309},
                "evidence_requirements": {},
            }
        ).encode("utf-8"),
        b'{"schema_version":' + b"9" * 5_000 + b"}",
    ]
    for index, payload in enumerate(payloads):
        gates_path = tmp_path / f"gates-{index}.json"
        gates_path.write_bytes(payload)

        exit_code = cli.main(
            [
                "evaluate-voice",
                str(tmp_path / "corpus"),
                str(tmp_path / "run.json"),
                str(tmp_path / "observations.jsonl"),
                "--gates-config",
                str(gates_path),
            ]
        )

        captured = capsys.readouterr()
        assert exit_code == 2
        assert captured.out == ""
        assert "Traceback" not in captured.err


def test_evaluate_voice_requires_a_complete_baseline_pair(
    tmp_path: Path, monkeypatch, capsys
):
    def unexpected_load(*args, **kwargs):
        raise AssertionError("invalid CLI arguments must fail before loading inputs")

    monkeypatch.setattr(cli, "load_voice_corpus", unexpected_load)

    exit_code = cli.main(
        [
            "evaluate-voice",
            str(tmp_path / "corpus"),
            str(tmp_path / "run.json"),
            str(tmp_path / "observations.jsonl"),
            "--baseline-run",
            str(tmp_path / "baseline-run.json"),
        ]
    )

    captured = capsys.readouterr()
    assert exit_code == 2
    assert captured.out == ""
    assert captured.err == (
        "error: --baseline-run and --baseline-observations must be used together\n"
    )


def test_evaluate_voice_v1_contract_error_is_exit_two(
    tmp_path: Path, monkeypatch, capsys
):
    corpus = object()
    monkeypatch.setattr(cli, "load_voice_corpus", lambda path: corpus)

    def reject_v1(path, loaded_corpus):
        assert loaded_corpus is corpus
        raise cli.VoiceEvaluationError("voice run schema_version must be 2")

    monkeypatch.setattr(cli, "load_voice_run", reject_v1)

    exit_code = cli.main(
        [
            "evaluate-voice",
            str(tmp_path / "corpus"),
            str(tmp_path / "run-v1.json"),
            str(tmp_path / "observations.jsonl"),
        ]
    )

    captured = capsys.readouterr()
    assert exit_code == 2
    assert captured.out == ""
    assert captured.err == "error: voice run schema_version must be 2\n"


def test_evaluate_voice_forwards_a_complete_baseline_pair(
    tmp_path: Path, monkeypatch, capsys
):
    corpus = object()
    candidate_run = object()
    baseline_run = object()
    candidate_observations = object()
    baseline_observations = object()
    candidate_run_path = tmp_path / "candidate-run.json"
    baseline_run_path = tmp_path / "baseline-run.json"
    candidate_observations_path = tmp_path / "candidate.jsonl"
    baseline_observations_path = tmp_path / "baseline.jsonl"

    monkeypatch.setattr(cli, "load_voice_corpus", lambda path: corpus)

    def load_run(path, loaded_corpus):
        assert loaded_corpus is corpus
        return candidate_run if path == candidate_run_path else baseline_run

    def load_observations(path, loaded_corpus, run):
        assert loaded_corpus is corpus
        if path == candidate_observations_path:
            assert run is candidate_run
            return candidate_observations
        assert path == baseline_observations_path
        assert run is baseline_run
        return baseline_observations

    def evaluate(loaded_corpus, run, observations, **kwargs):
        assert loaded_corpus is corpus
        assert run is candidate_run
        assert observations is candidate_observations
        assert kwargs == {
            "baseline_run": baseline_run,
            "baseline_observations": baseline_observations,
            "gates": None,
        }
        return {"schema_version": 2, "decision": "measurement_only"}

    monkeypatch.setattr(cli, "load_voice_run", load_run)
    monkeypatch.setattr(cli, "load_voice_observations", load_observations)
    monkeypatch.setattr(cli, "evaluate_voice", evaluate)

    exit_code = cli.main(
        [
            "evaluate-voice",
            str(tmp_path / "corpus"),
            str(candidate_run_path),
            str(candidate_observations_path),
            "--baseline-run",
            str(baseline_run_path),
            "--baseline-observations",
            str(baseline_observations_path),
        ]
    )

    captured = capsys.readouterr()
    assert exit_code == 0
    assert json.loads(captured.out)["decision"] == "measurement_only"
    assert captured.err == ""


def test_collect_voice_observations_forwards_inputs_and_reports_safe_digest(
    tmp_path: Path, monkeypatch, capsys
):
    corpus_root = tmp_path / "corpus"
    run_path = tmp_path / "run.json"
    native_driver = tmp_path / "native-driver"
    artifact_dir = tmp_path / "artifact"
    output_path = tmp_path / "observations.jsonl"
    hotwords_file = tmp_path / "hotwords.json"
    calls = []

    def collect(corpus, run, driver, artifact, output, hotwords):
        calls.append((corpus, run, driver, artifact, output, hotwords))
        return "a" * 64

    monkeypatch.setattr(cli, "collect_voice_observations", collect)

    exit_code = cli.main(
        [
            "collect-voice-observations",
            str(corpus_root),
            str(run_path),
            "--native-driver",
            str(native_driver),
            "--artifact-dir",
            str(artifact_dir),
            "--output",
            str(output_path),
            "--hotwords-file",
            str(hotwords_file),
        ]
    )

    captured = capsys.readouterr()
    assert exit_code == 0
    assert calls == [
        (
            corpus_root,
            run_path,
            native_driver,
            artifact_dir,
            output_path,
            hotwords_file,
        )
    ]
    assert json.loads(captured.out) == {
        "kind": "voice_observation_collection",
        "schema_version": 1,
        "sha256": "a" * 64,
        "valid": True,
    }
    assert captured.err == ""


def test_collect_voice_observations_failure_is_exit_two_and_redacted(
    tmp_path: Path, monkeypatch, capsys
):
    output_path = tmp_path / "observations.jsonl"
    sensitive = "private phrase at /private/corpus/audio.wav"

    def reject(*args):
        raise cli.VoiceObservationCollectionError(sensitive)

    monkeypatch.setattr(cli, "collect_voice_observations", reject)

    exit_code = cli.main(
        [
            "collect-voice-observations",
            str(tmp_path / "corpus"),
            str(tmp_path / "run.json"),
            "--native-driver",
            str(tmp_path / "native-driver"),
            "--artifact-dir",
            str(tmp_path / "artifact"),
            "--output",
            str(output_path),
        ]
    )

    captured = capsys.readouterr()
    assert exit_code == 2
    assert captured.out == ""
    assert captured.err == "error: voice observation collection failed\n"
    assert sensitive not in captured.err
    assert not output_path.exists()
