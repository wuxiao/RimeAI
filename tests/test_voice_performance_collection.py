from contextlib import contextmanager
import json
import hashlib
import io
import os
from pathlib import Path
import stat
import sys
import threading

import pytest

import rimeai_eval.voice_performance_collection as voice_performance_collection
from deep_json import deep_nesting_payloads
from rimeai_eval.voice_performance_collection import (
    VoicePerformanceCollectionError,
    assemble_voice_performance,
    collect_voice_performance,
    decode_voice_collection_event,
    load_voice_collection_plan,
    write_voice_performance_atomic,
)

from test_voice_performance import _corpus, _performance, _run


PROCESS_ROLES = ("input_method", "candidate_service", "voice_helper")


def _plan(tmp_path: Path, run: dict) -> dict:
    artifact_directory = tmp_path / "artifact"
    artifact_directory.mkdir()
    processes = []
    signing_identifiers = {
        "input_method": "fun.wwcn.inputmethod.RimeAI",
        "candidate_service": "rimeai-daemon",
        "voice_helper": "fun.wwcn.rimeai.voice-helper",
    }
    for index, role in enumerate(PROCESS_ROLES, start=1):
        executable = tmp_path / f"{role}-executable"
        executable.write_bytes(role.encode("ascii"))
        executable.chmod(0o700)
        processes.append(
            {
                "role": role,
                "pid": 10_000 + index,
                "expected_executable_path": str(executable),
                "expected_signing_identifier": signing_identifiers[role],
                "expected_cdhash": f"{index:x}" * 40,
            }
        )
    return {
        "schema_version": 1,
        "collection_protocol": {
            "id": "rimeai-release-collection-v1",
            "sha256": "7" * 64,
        },
        "sample_interval_ms": 100,
        "native_collector_sha256": "f" * 64,
        "expected_team_identifier": "S3T42U45P8",
        "artifact_directory": str(artifact_directory)
        if run["engine"]["asset_management"] == "product"
        else None,
        "processes": processes,
    }


def _write_plan(tmp_path: Path, value: dict) -> Path:
    path = tmp_path / "collection-plan.json"
    path.write_text(json.dumps(value), encoding="utf-8")
    return path


def test_collection_plan_binds_exact_three_signed_process_roles(tmp_path: Path):
    corpus = _corpus()
    run = _run(corpus)
    expected = _plan(tmp_path, run)

    loaded = load_voice_collection_plan(_write_plan(tmp_path, expected), run)

    assert loaded == expected


@pytest.mark.parametrize(
    "protocol",
    [
        {"id": "private protocol 空格", "sha256": "7" * 64},
        {"id": "rimeai-release-collection-v1", "sha256": "A" * 64},
        {
            "id": "rimeai-release-collection-v1",
            "sha256": "7" * 64,
            "unexpected": True,
        },
    ],
)
def test_collection_plan_requires_an_exact_non_sensitive_protocol(
    tmp_path: Path,
    protocol: dict,
):
    corpus = _corpus()
    run = _run(corpus)
    value = _plan(tmp_path, run)
    value["collection_protocol"] = protocol

    with pytest.raises(VoicePerformanceCollectionError):
        load_voice_collection_plan(_write_plan(tmp_path, value), run)


@pytest.mark.parametrize(
    ("mutate", "message"),
    [
        (
            lambda value: value.update({"unexpected": True}),
            "unknown fields",
        ),
        (
            lambda value: value["processes"].pop(),
            "process roles",
        ),
        (
            lambda value: value["processes"][1].update(
                {"role": "input_method"}
            ),
            "process roles",
        ),
        (
            lambda value: value["processes"][1].update(
                {"pid": value["processes"][0]["pid"]}
            ),
            "process identifiers",
        ),
        (
            lambda value: value.update(
                {"expected_team_identifier": "user-controlled-team"}
            ),
            "TeamIdentifier",
        ),
        (
            lambda value: value["processes"][0].update(
                {"expected_cdhash": "A" * 40}
            ),
            "CDHash",
        ),
        (
            lambda value: value["processes"][1].update(
                {"expected_signing_identifier": "same-team-unrelated-tool"}
            ),
            "does not match its product role",
        ),
        (
            lambda value: value["processes"][0].update(
                {"expected_executable_path": "relative/program"}
            ),
            "executable path",
        ),
    ],
)
def test_collection_plan_rejects_ambiguous_or_untrusted_processes(
    tmp_path: Path,
    mutate,
    message: str,
):
    corpus = _corpus()
    run = _run(corpus)
    value = _plan(tmp_path, run)
    mutate(value)

    with pytest.raises(VoicePerformanceCollectionError, match=message):
        load_voice_collection_plan(_write_plan(tmp_path, value), run)


def test_collection_plan_rejects_duplicate_keys(tmp_path: Path):
    corpus = _corpus()
    run = _run(corpus)
    path = tmp_path / "collection-plan.json"
    path.write_text(
        '{"schema_version":1,"schema_version":1}',
        encoding="utf-8",
    )

    with pytest.raises(VoicePerformanceCollectionError, match="invalid JSON"):
        load_voice_collection_plan(path, run)


@pytest.mark.parametrize(
    "payload",
    [
        b"\xff",
        *deep_nesting_payloads(131_072),
        b'{"schema_version":' + b"9" * 5_000 + b"}",
        b"{" + b" " * 131_072 + b"}",
    ],
)
def test_collection_plan_rejects_invalid_utf8_and_oversized_input(
    tmp_path: Path,
    payload: bytes,
):
    corpus = _corpus()
    run = _run(corpus)
    path = tmp_path / "collection-plan.json"
    path.write_bytes(payload)

    with pytest.raises(VoicePerformanceCollectionError, match="invalid JSON|too large"):
        load_voice_collection_plan(path, run)


def test_system_run_forbids_artifact_directory(tmp_path: Path):
    corpus = _corpus()
    run = _run(corpus)
    run["engine"] = {
        "adapter_id": "apple-speech-ondevice",
        "engine_id": "apple-speech-ondevice",
        "asset_management": "system",
        "recognizer_locale": "zh-CN",
        "requires_on_device": True,
        "supports_on_device_at_run": True,
    }
    value = _plan(tmp_path, run)
    value["artifact_directory"] = str(tmp_path / "artifact")

    with pytest.raises(
        VoicePerformanceCollectionError,
        match="system-managed.*artifact",
    ):
        load_voice_collection_plan(_write_plan(tmp_path, value), run)


def test_product_plan_requires_the_runtime_engine_id_derived_from_artifact(
    tmp_path: Path,
):
    corpus = _corpus()
    run = _run(corpus)
    value = _plan(tmp_path, run)
    run["engine"]["engine_id"] = "friendly-display-name"

    with pytest.raises(
        VoicePerformanceCollectionError,
        match="runtime artifact identity",
    ):
        load_voice_collection_plan(_write_plan(tmp_path, value), run)


@pytest.mark.parametrize(
    "event",
    [
        {"schema_version": 1, "event": "cold_artifact_load_begin", "sequence": 1},
        {"schema_version": 1, "event": "cold_artifact_load_end", "sequence": 1},
        {
            "schema_version": 1,
            "event": "session_begin",
            "sample_id": "voice-000001",
        },
        {
            "schema_version": 1,
            "event": "session_end",
            "sample_id": "voice-000001",
        },
        {
            "schema_version": 1,
            "event": "keyboard_begin",
            "sequence": 1,
            "phase": "baseline",
        },
        {
            "schema_version": 1,
            "event": "keyboard_candidate_ready",
            "sequence": 1,
            "phase": "baseline",
        },
        {
            "schema_version": 1,
            "event": "challenge",
            "scenario": "cancel",
        },
        {"schema_version": 1, "event": "late_voice_commit"},
        {"schema_version": 1, "event": "finish"},
    ],
)
def test_live_events_are_canonical_boundary_markers_only(event: dict):
    corpus = _corpus()
    encoded = json.dumps(event).encode("utf-8") + b"\n"

    canonical = decode_voice_collection_event(encoded, corpus)

    assert json.loads(canonical) == event
    assert canonical.endswith(b"\n")


@pytest.mark.parametrize(
    ("event", "message"),
    [
        (
            {
                "schema_version": 1,
                "event": "session_end",
                "sample_id": "voice-000001",
                "processing_duration_ms": 1.0,
            },
            "unknown fields",
        ),
        (
            {
                "schema_version": 1,
                "event": "keyboard_candidate_ready",
                "sequence": 1,
                "phase": "baseline",
                "rime_candidate_latency_ms": 1.0,
            },
            "unknown fields",
        ),
        (
            {
                "schema_version": 1,
                "event": "session_begin",
                "sample_id": "private transcript 机密",
            },
            "controlled non-sensitive identifier",
        ),
        (
            {
                "schema_version": 1,
                "event": "keyboard_begin",
                "sequence": 1,
                "phase": "invented",
            },
            "phase",
        ),
    ],
)
def test_live_events_reject_measurements_text_and_unknown_semantics(
    event: dict,
    message: str,
):
    corpus = _corpus()

    with pytest.raises(VoicePerformanceCollectionError, match=message):
        decode_voice_collection_event(
            json.dumps(event).encode("utf-8") + b"\n",
            corpus,
        )


@pytest.mark.parametrize(
    "event",
    [
        {
            "schema_version": 1,
            "event": "challenge",
            "scenario": "invented",
        },
        {
            "schema_version": 1,
            "event": "challenge",
            "scenario": "cancel",
            "elapsed_ms": 1,
        },
        {
            "schema_version": 1,
            "event": "challenge",
            "scenario": "cancel",
            "text": "private",
        },
    ],
)
def test_challenge_events_reject_unknown_scenarios_measurements_and_text(event: dict):
    with pytest.raises(VoicePerformanceCollectionError):
        decode_voice_collection_event(
            json.dumps(event).encode("utf-8") + b"\n",
            _corpus(),
        )


def test_live_events_reject_duplicate_keys_and_oversized_lines():
    corpus = _corpus()
    with pytest.raises(VoicePerformanceCollectionError, match="invalid JSON"):
        decode_voice_collection_event(
            b'{"schema_version":1,"event":"finish","event":"finish"}\n',
            corpus,
        )
    with pytest.raises(VoicePerformanceCollectionError, match="too large"):
        decode_voice_collection_event(b"{" + b" " * 4096 + b"}\n", corpus)
    # Deep nesting must stay under the 4,096-byte event cap, so on
    # interpreters whose parser budget exceeds that depth there is no
    # event-sized input that can reach the RecursionError branch.
    for payload in deep_nesting_payloads(4_096):
        with pytest.raises(VoicePerformanceCollectionError, match="invalid JSON"):
            decode_voice_collection_event(payload + b"\n", corpus)


def test_event_validation_never_echoes_an_unknown_private_key():
    corpus = _corpus()
    private_value = "private transcript 机密"
    event = {
        "schema_version": 1,
        "event": "finish",
        private_value: True,
    }

    with pytest.raises(VoicePerformanceCollectionError) as captured:
        decode_voice_collection_event(
            json.dumps(event).encode("utf-8") + b"\n",
            corpus,
        )

    assert "unknown fields" in str(captured.value)
    assert private_value not in str(captured.value)


def test_native_result_is_bound_to_run_and_corpus_before_it_can_be_written():
    corpus = _corpus()
    run = _run(corpus)
    complete = _performance(corpus, run)
    native = {
        key: complete[key]
        for key in (
            "artifact",
            "collector",
            "environment",
            "collection_protocol",
            "cold_artifact_load_ms",
            "keyboard_trials",
            "late_voice_commit_count",
            "late_challenge_counts",
        )
    }
    native["schema_version"] = 1
    native["sessions"] = [
        {
            "sample_id": session["sample_id"],
            "processing_duration_ms": session["processing_duration_ms"],
            "processes": session["processes"],
        }
        for session in complete["sessions"]
    ]

    assembled = assemble_voice_performance(
        native, corpus, run, complete["collection_protocol"]
    )

    assert assembled == complete


def test_native_result_cannot_inject_bindings_or_audio_duration():
    corpus = _corpus()
    run = _run(corpus)
    complete = _performance(corpus, run)
    native = {
        "artifact": complete["artifact"],
        "schema_version": 1,
        "collection_protocol": complete["collection_protocol"],
        "collector": complete["collector"],
        "environment": complete["environment"],
        "cold_artifact_load_ms": complete["cold_artifact_load_ms"],
        "sessions": [
            {
                "sample_id": "voice-000001",
                "audio_duration_ms": 0,
                "processing_duration_ms": 500,
                "processes": complete["sessions"][0]["processes"],
            }
        ],
        "keyboard_trials": complete["keyboard_trials"],
        "late_voice_commit_count": 0,
        "late_challenge_counts": complete["late_challenge_counts"],
    }

    with pytest.raises(VoicePerformanceCollectionError, match="unknown fields"):
        assemble_voice_performance(
            native, corpus, run, complete["collection_protocol"]
        )


def test_native_result_protocol_must_match_the_user_plan():
    corpus = _corpus()
    run = _run(corpus)
    native = _native_result(corpus, run)
    expected = dict(native["collection_protocol"])
    native["collection_protocol"] = {**expected, "sha256": "8" * 64}

    with pytest.raises(VoicePerformanceCollectionError, match="collection_protocol"):
        assemble_voice_performance(native, corpus, run, expected)


def test_native_result_validation_never_echoes_private_nested_keys():
    corpus = _corpus()
    run = _run(corpus)
    native = _native_result(corpus, run)
    private_key = "private transcript 机密"
    native["sessions"][0]["processes"][0][private_key] = True

    with pytest.raises(VoicePerformanceCollectionError) as captured:
        assemble_voice_performance(
            native, corpus, run, _performance(corpus, run)["collection_protocol"]
        )

    assert private_key not in str(captured.value)


def _native_result(corpus, run):
    complete = _performance(corpus, run)
    result = {
        key: complete[key]
        for key in (
            "collection_protocol",
            "artifact",
            "collector",
            "environment",
            "cold_artifact_load_ms",
            "keyboard_trials",
            "late_voice_commit_count",
            "late_challenge_counts",
        )
    }
    result["schema_version"] = 1
    result["sessions"] = [
        {
            "sample_id": session["sample_id"],
            "processing_duration_ms": session["processing_duration_ms"],
            "processes": session["processes"],
        }
        for session in complete["sessions"]
    ]
    return result


def _fake_native_collector(
    tmp_path: Path,
    result: dict,
    *,
    tamper_collector: tuple[str, object] | None = None,
) -> Path:
    executable = tmp_path / "fake-native-collector"
    source = "\n".join(
        [
            f"#!{sys.executable}",
            "import json, sys",
            "assert sys.argv[1] == '--plan'",
            "with open(sys.argv[2], encoding='utf-8') as source:",
            "    plan = json.load(source)",
            "assert plan['schema_version'] == 1",
            f"result = json.loads({json.dumps(result, separators=(',', ':'))!r})",
            "result['collector']['executable_sha256'] = plan['native_collector_sha256']",
            "result['collector']['team_identifier'] = plan['expected_team_identifier']",
            "result['collector']['signing_identifier'] = 'fun.wwcn.rimeai.voice-performance-collector'",
            (
                f"result['collector'][{tamper_collector[0]!r}] = {tamper_collector[1]!r}"
                if tamper_collector is not None
                else ""
            ),
            "seen_finish = False",
            "for line in sys.stdin:",
            "    event = json.loads(line)",
            "    if event['event'] == 'finish':",
            "        seen_finish = True",
            "        break",
            "assert seen_finish",
            "print(json.dumps(result, separators=(',', ':')))",
            "",
        ]
    )
    executable.write_text(source, encoding="utf-8")
    executable.chmod(0o700)
    return executable


def _complete_events() -> bytes:
    values = [
        {"schema_version": 1, "event": "cold_artifact_load_begin", "sequence": 1},
        {"schema_version": 1, "event": "cold_artifact_load_end", "sequence": 1},
        {
            "schema_version": 1,
            "event": "session_begin",
            "sample_id": "voice-000001",
        },
        {
            "schema_version": 1,
            "event": "session_end",
            "sample_id": "voice-000001",
        },
    ]
    for phase in (
        "baseline",
        "helper_loaded_idle",
        "listening_cancel_to_rime",
    ):
        values.extend(
            [
                {
                    "schema_version": 1,
                    "event": "keyboard_begin",
                    "sequence": 1,
                    "phase": phase,
                },
                {
                    "schema_version": 1,
                    "event": "keyboard_candidate_ready",
                    "sequence": 1,
                    "phase": phase,
                },
            ]
        )
    values.append({"schema_version": 1, "event": "finish"})
    return b"".join(
        json.dumps(value).encode("utf-8") + b"\n" for value in values
    )


@contextmanager
def _live_event_source(payload: bytes):
    read_descriptor, write_descriptor = os.pipe()

    def write_events() -> None:
        try:
            with os.fdopen(write_descriptor, "wb", buffering=0) as destination:
                view = memoryview(payload)
                offset = 0
                while offset < len(view):
                    offset += destination.write(view[offset:])
        except BrokenPipeError:
            pass

    writer = threading.Thread(target=write_events, daemon=True)
    writer.start()
    try:
        with os.fdopen(read_descriptor, "rb") as source:
            yield source
    finally:
        writer.join(timeout=2)
        assert not writer.is_alive()


def test_pinned_native_collector_result_is_revalidated_end_to_end(tmp_path: Path):
    corpus = _corpus()
    run = _run(corpus)
    executable = _fake_native_collector(tmp_path, _native_result(corpus, run))
    plan_value = _plan(tmp_path, run)
    plan_value["native_collector_sha256"] = hashlib.sha256(
        executable.read_bytes()
    ).hexdigest()
    plan = load_voice_collection_plan(_write_plan(tmp_path, plan_value), run)

    with _live_event_source(_complete_events()) as events:
        result = collect_voice_performance(
            corpus,
            run,
            plan,
            executable,
            events,
        )

    expected = _performance(corpus, run)
    expected["collector"]["executable_sha256"] = plan_value[
        "native_collector_sha256"
    ]
    assert result == expected


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("executable_sha256", "0" * 64),
        ("team_identifier", "OTHERTEAM1"),
        ("signing_identifier", "same-team-unrelated-tool"),
        ("sample_interval_ms", 50),
    ],
)
def test_native_result_must_match_the_attested_collector_plan(
    tmp_path: Path,
    field: str,
    value: object,
):
    corpus = _corpus()
    run = _run(corpus)
    native = _native_result(corpus, run)
    executable = _fake_native_collector(
        tmp_path,
        native,
        tamper_collector=(field, value),
    )
    plan_value = _plan(tmp_path, run)
    plan_value["native_collector_sha256"] = hashlib.sha256(
        executable.read_bytes()
    ).hexdigest()
    plan = load_voice_collection_plan(_write_plan(tmp_path, plan_value), run)

    with _live_event_source(_complete_events()) as events, pytest.raises(
        VoicePerformanceCollectionError,
        match="collector identity does not match",
    ):
        collect_voice_performance(corpus, run, plan, executable, events)


def test_native_collector_hash_mismatch_fails_before_execution(tmp_path: Path):
    corpus = _corpus()
    run = _run(corpus)
    marker = tmp_path / "executed"
    executable = tmp_path / "fake-native-collector"
    executable.write_text(
        f"#!{sys.executable}\nopen({str(marker)!r}, 'w').close()\n",
        encoding="utf-8",
    )
    executable.chmod(0o700)
    plan_value = _plan(tmp_path, run)
    plan = load_voice_collection_plan(_write_plan(tmp_path, plan_value), run)

    with _live_event_source(_complete_events()) as events, pytest.raises(
        VoicePerformanceCollectionError,
        match="pinned SHA-256",
    ):
        collect_voice_performance(corpus, run, plan, executable, events)

    assert not marker.exists()


def test_collection_does_not_block_when_native_collector_stops_reading_events(
    tmp_path: Path,
    monkeypatch,
):
    corpus = _corpus()
    run = _run(corpus)
    executable = tmp_path / "stalled-native-collector"
    executable.write_text(
        f"#!{sys.executable}\nimport time\ntime.sleep(10)\n",
        encoding="utf-8",
    )
    executable.chmod(0o700)
    plan_value = _plan(tmp_path, run)
    plan_value["native_collector_sha256"] = hashlib.sha256(
        executable.read_bytes()
    ).hexdigest()
    plan = load_voice_collection_plan(_write_plan(tmp_path, plan_value), run)
    monkeypatch.setattr(
        voice_performance_collection,
        "_NATIVE_STDIN_WRITE_TIMEOUT_SECONDS",
        0.05,
    )
    payload = b"".join(
        json.dumps(
            {
                "schema_version": 1,
                "event": "cold_artifact_load_begin",
                "sequence": sequence,
            }
        ).encode("utf-8")
        + b"\n"
        for sequence in range(1, 20_000)
    )

    with _live_event_source(payload) as events, pytest.raises(
        VoicePerformanceCollectionError,
        match="did not accept voice collection events",
    ):
        collect_voice_performance(
            corpus,
            run,
            plan,
            executable,
            events,
        )


def test_collection_requires_an_explicit_finish_event(tmp_path: Path):
    corpus = _corpus()
    run = _run(corpus)
    executable = _fake_native_collector(tmp_path, _native_result(corpus, run))
    plan_value = _plan(tmp_path, run)
    plan_value["native_collector_sha256"] = hashlib.sha256(
        executable.read_bytes()
    ).hexdigest()
    plan = load_voice_collection_plan(_write_plan(tmp_path, plan_value), run)

    payload = b'{"schema_version":1,"event":"cold_artifact_load_begin","sequence":1}\n'
    with _live_event_source(payload) as events, pytest.raises(
        VoicePerformanceCollectionError,
        match="before finish",
    ):
        collect_voice_performance(corpus, run, plan, executable, events)


def test_collection_rejects_any_event_after_finish(tmp_path: Path):
    corpus = _corpus()
    run = _run(corpus)
    executable = _fake_native_collector(tmp_path, _native_result(corpus, run))
    plan_value = _plan(tmp_path, run)
    plan_value["native_collector_sha256"] = hashlib.sha256(
        executable.read_bytes()
    ).hexdigest()
    plan = load_voice_collection_plan(_write_plan(tmp_path, plan_value), run)
    payload = _complete_events() + (
        b'{"schema_version":1,"event":"late_voice_commit"}\n'
    )

    with _live_event_source(payload) as events, pytest.raises(
        VoicePerformanceCollectionError,
        match="finish must be the final event",
    ):
        collect_voice_performance(corpus, run, plan, executable, events)


def test_collection_rejects_a_replayed_regular_event_file(tmp_path: Path):
    corpus = _corpus()
    run = _run(corpus)
    executable = _fake_native_collector(tmp_path, _native_result(corpus, run))
    plan_value = _plan(tmp_path, run)
    plan_value["native_collector_sha256"] = hashlib.sha256(
        executable.read_bytes()
    ).hexdigest()
    plan = load_voice_collection_plan(_write_plan(tmp_path, plan_value), run)
    event_path = tmp_path / "replayed-events.jsonl"
    event_path.write_bytes(_complete_events())

    with event_path.open("rb") as events, pytest.raises(
        VoicePerformanceCollectionError,
        match="live pipe, socket, or terminal",
    ):
        collect_voice_performance(
            corpus,
            run,
            plan,
            executable,
            events,
        )


def test_collection_rejects_an_event_source_without_an_os_stream_identity(
    tmp_path: Path,
):
    corpus = _corpus()
    run = _run(corpus)
    executable = _fake_native_collector(tmp_path, _native_result(corpus, run))
    plan_value = _plan(tmp_path, run)
    plan_value["native_collector_sha256"] = hashlib.sha256(
        executable.read_bytes()
    ).hexdigest()
    plan = load_voice_collection_plan(_write_plan(tmp_path, plan_value), run)

    with pytest.raises(
        VoicePerformanceCollectionError,
        match="live operating-system stream",
    ):
        collect_voice_performance(
            corpus,
            run,
            plan,
            executable,
            io.BytesIO(_complete_events()),
        )


def test_live_event_reader_rejects_an_oversized_unterminated_record_without_eof(
    tmp_path: Path,
):
    corpus = _corpus()
    run = _run(corpus)
    executable = _fake_native_collector(tmp_path, _native_result(corpus, run))
    plan_value = _plan(tmp_path, run)
    plan_value["native_collector_sha256"] = hashlib.sha256(
        executable.read_bytes()
    ).hexdigest()
    plan = load_voice_collection_plan(_write_plan(tmp_path, plan_value), run)
    read_descriptor, write_descriptor = os.pipe()
    os.write(write_descriptor, b"x" * 4_097)
    finished = threading.Event()
    captured = []

    def collect() -> None:
        try:
            with os.fdopen(read_descriptor, "rb") as events:
                collect_voice_performance(
                    corpus,
                    run,
                    plan,
                    executable,
                    events,
                )
        except Exception as error:
            captured.append(error)
        finally:
            finished.set()

    worker = threading.Thread(target=collect, daemon=True)
    worker.start()
    rejected_before_eof = finished.wait(timeout=1)
    os.close(write_descriptor)
    worker.join(timeout=2)

    assert rejected_before_eof
    assert len(captured) == 1
    assert isinstance(captured[0], VoicePerformanceCollectionError)
    assert "too large" in str(captured[0])


def test_validated_performance_is_written_atomically_owner_only(tmp_path: Path):
    corpus = _corpus()
    run = _run(corpus)
    value = _performance(corpus, run)
    output = tmp_path / "performance.json"

    digest = write_voice_performance_atomic(value, output)

    assert json.loads(output.read_text(encoding="utf-8")) == value
    assert stat.S_IMODE(output.stat().st_mode) == 0o600
    assert digest == hashlib.sha256(output.read_bytes()).hexdigest()
    assert not list(tmp_path.glob(".performance.json.*.installing"))
