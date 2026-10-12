import errno
import hashlib
import json
import os
from pathlib import Path
import stat
import sys
import threading
import time
import wave

import pytest

from rimeai_eval.voice_dataset import load_voice_corpus
from rimeai_eval import voice_observation_collection as observation_collection
from rimeai_eval.voice_observation_collection import (
    VoiceObservationCollectionError,
    collect_voice_observations,
)


_EMPTY_HOTWORD_SHA256 = (
    "3065f942bf0c8072df531e3a79a403a90a7c0ac884cb3d24085d838911c9adda"
)


def _hotword_snapshot(phrases):
    payload = bytearray(b"rimeai.voice-hotwords.v1\0")
    payload.extend(len(phrases).to_bytes(4, "big"))
    for phrase in phrases:
        encoded = phrase.encode("utf-8")
        payload.extend(len(encoded).to_bytes(4, "big"))
        payload.extend(encoded)
    return {
        "normalization_version": 1,
        "phrases": phrases,
        "hotword_set_sha256": hashlib.sha256(payload).hexdigest(),
    }


def _write_fixture_corpus(
    tmp_path: Path,
    *,
    frame_count: int = 100,
    sample_count: int = 1,
) -> Path:
    root = tmp_path / "corpus"
    audio_dir = root / "audio"
    audio_dir.mkdir(parents=True)
    audio_path = audio_dir / "sample.wav"
    with wave.open(str(audio_path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(44_100)
        output.writeframes(b"\0\0" * frame_count)
    audio_sha256 = hashlib.sha256(audio_path.read_bytes()).hexdigest()
    manifest = {
        "schema_version": 1,
        "corpus_id": "voice-fixture-v1",
        "purpose": "fixture",
        "normalization_profile": "rimeai-voice-v1",
        "samples_file": "samples.jsonl",
        "synthetic_fixture": True,
        "rights": None,
        "quality_declarations": {
            "authorized_real_recordings": False,
            "speaker_disjoint_by_identity": False,
        },
    }
    sample = {
        "schema_version": 1,
        "id": "voice-000001",
        "split": "test",
        "speaker_group_id": "private-speaker-group",
        "domain": "software",
        "language_composition": "mixed",
        "conditions": {"noise": "quiet", "distance": "near_field"},
        "audio": {
            "path": "audio/sample.wav",
            "sha256": audio_sha256,
            "container": "wav",
            "encoding": "pcm_s16le",
            "duration_ms": frame_count * 1000.0 / 44_100,
            "sample_rate_hz": 44_100,
            "channels": 1,
        },
        "reference": "private API reference",
        "terms": [{"text": "API", "match_mode": "ascii_casefold_word"}],
        "is_blank": False,
    }
    (root / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, separators=(",", ":")),
        encoding="utf-8",
    )
    samples = []
    for index in range(sample_count):
        value = dict(sample)
        value["id"] = "voice-%06d" % (index + 1)
        samples.append(
            json.dumps(value, ensure_ascii=False, separators=(",", ":"))
        )
    (root / "samples.jsonl").write_text("\n".join(samples) + "\n", encoding="utf-8")
    return root.resolve()


def _write_native_driver(
    tmp_path: Path,
    *,
    expected_policy=None,
    expected_hotword_snapshot=None,
) -> Path:
    if expected_policy is None:
        expected_policy = {
            "endpoint_strategy": "push-to-talk",
            "hotwords_enabled": False,
            "postprocessor_id": "none",
        }
    if expected_hotword_snapshot is None:
        expected_hotword_snapshot = {
            "normalization_version": 1,
            "phrases": [],
            "hotword_set_sha256": _EMPTY_HOTWORD_SHA256,
        }
    expected_policy_json = json.dumps(
        expected_policy, ensure_ascii=False, separators=(",", ":")
    )
    expected_hotword_json = json.dumps(
        expected_hotword_snapshot, ensure_ascii=False, separators=(",", ":")
    )
    driver = tmp_path / "native-driver"
    source = f"""#!{sys.executable}
import json
import os
import stat
import sys

assert sys.argv[1] == "--plan" and len(sys.argv) == 3
plan_path = sys.argv[2]
assert stat.S_IMODE(os.stat(plan_path).st_mode) == 0o600
with open(plan_path, "r", encoding="utf-8") as source:
    plan = json.load(source)
assert set(plan) == {{
    "schema_version", "collection_method", "corpus_fingerprint",
    "native_driver_sha256", "artifact_directory", "artifact",
    "recognizer_locale", "policy", "hotword_snapshot", "samples",
    "output_path",
}}
assert plan["schema_version"] == 1
assert plan["collection_method"] == "evaluation_replay"
assert set(plan["artifact"]) == {{
    "artifact_id", "artifact_content_sha256", "adapter_id", "engine_id",
    "model_id", "model_revision",
}}
assert plan["policy"] == json.loads({expected_policy_json!r})
assert plan["hotword_snapshot"] == json.loads({expected_hotword_json!r})
assert len(plan["samples"]) == 1
sample = plan["samples"][0]
assert set(sample) == {{
    "sample_id", "audio_path", "audio_sha256", "duration_ms",
    "sample_rate_hz", "channels", "frame_count",
}}
assert sample["duration_ms"] == 100 * 1000.0 / 44100
serialized = json.dumps(plan, ensure_ascii=False)
assert "private API reference" not in serialized
assert "private-speaker-group" not in serialized
assert "terms" not in serialized
assert not os.path.exists(plan["output_path"])
observation = {{
    "schema_version": 1,
    "sample_id": sample["sample_id"],
    "outcome": "final",
    "partials": [],
    "stop_received_elapsed_ms": 10,
    "final": {{"text": "recognized", "elapsed_ms": 20}},
}}
payload = (json.dumps(observation, separators=(",", ":")) + "\\n").encode()
descriptor = os.open(
    plan["output_path"], os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600
)
with os.fdopen(descriptor, "wb") as output:
    output.write(payload)
    output.flush()
    os.fsync(output.fileno())
"""
    driver.write_text(source, encoding="utf-8")
    driver.chmod(0o700)
    return driver.resolve()


def _write_failure_driver(
    tmp_path: Path,
    behavior: str,
    *,
    descendant_marker: Path = None,
) -> Path:
    driver = tmp_path / "native-driver"
    source = f"""#!{sys.executable}
import json
import os
import sys
import time

with open(sys.argv[2], "rb") as source:
    plan_bytes = source.read()
plan = json.loads(plan_bytes.decode("utf-8"))
behavior = {behavior!r}
descendant_marker = {str(descendant_marker) if descendant_marker else None!r}
if behavior == "early":
    raise SystemExit(0)
if behavior == "nonzero":
    raise SystemExit(9)
if behavior == "timeout":
    time.sleep(5)
    raise SystemExit(0)
def final_observation(sample_id):
    return {{
        "schema_version": 1,
        "sample_id": sample_id,
        "outcome": "final",
        "partials": [],
        "stop_received_elapsed_ms": 10,
        "final": {{"text": "recognized", "elapsed_ms": 20}},
    }}
observation = final_observation(plan["samples"][0]["sample_id"])
if behavior == "invalid":
    payload = b"{{}}\\n"
elif behavior in {{"oversize", "oversize_then_sleep"}}:
    payload = b" " * 8192
elif behavior == "reversed":
    payload = b"".join(
        (json.dumps(final_observation(sample["sample_id"]), separators=(",", ":")) + "\\n").encode()
        for sample in reversed(plan["samples"])
    )
elif behavior == "cancelled":
    observation = {{
        "schema_version": 1,
        "sample_id": plan["samples"][0]["sample_id"],
        "outcome": "cancelled",
        "partials": [],
        "cancel_received_elapsed_ms": 10,
        "capture_stopped_elapsed_ms": 11,
    }}
    payload = (json.dumps(observation, separators=(",", ":")) + "\\n").encode()
elif behavior == "resources":
    observation["resources"] = {{"processing_duration_ms": 1}}
    payload = (json.dumps(observation, separators=(",", ":")) + "\\n").encode()
else:
    payload = (json.dumps(observation, separators=(",", ":")) + "\\n").encode()
mode = 0o644 if behavior == "wrong_mode" else 0o600
descriptor = os.open(
    plan["output_path"], os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode
)
with os.fdopen(descriptor, "wb") as output:
    output.write(payload)
    output.flush()
    os.fsync(output.fileno())
if behavior == "oversize_then_sleep":
    time.sleep(5)
if behavior == "extra_file":
    with open(os.path.join(os.path.dirname(plan["output_path"]), "extra"), "wb") as extra:
        extra.write(b"x")
if behavior == "replace_plan":
    os.unlink(sys.argv[2])
    plan_descriptor = os.open(
        sys.argv[2], os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600
    )
    with os.fdopen(plan_descriptor, "wb") as replacement:
        replacement.write(plan_bytes)
        replacement.flush()
        os.fsync(replacement.fileno())
if behavior == "staging_mode":
    os.chmod(os.path.dirname(plan["output_path"]), 0o777)
if behavior in {{"fork_descendant", "fork_descendant_nonzero"}}:
    if os.fork() == 0:
        os.close(1)
        os.close(2)
        time.sleep(0.3)
        with open(descendant_marker, "wb") as marker:
            marker.write(b"survived")
        os._exit(0)
    if behavior == "fork_descendant_nonzero":
        raise SystemExit(9)
if behavior == "trailing_stdout":
    sys.stdout.write("diagnostic")
    sys.stdout.flush()
if behavior == "trailing_stderr":
    sys.stderr.write("diagnostic")
    sys.stderr.flush()
"""
    driver.write_text(source, encoding="utf-8")
    driver.chmod(0o700)
    return driver.resolve()


def _write_product_run(
    corpus_root: Path,
    driver: Path,
    *,
    hotword_snapshot=None,
) -> Path:
    corpus = load_voice_corpus(corpus_root)
    driver_sha256 = hashlib.sha256(driver.read_bytes()).hexdigest()
    artifact_sha256 = "e" * 64
    run = {
        "schema_version": 2,
        "evaluation_profile_id": "voice-v0-fixture",
        "corpus_fingerprint": corpus.fingerprint,
        "implementation_fingerprint": driver_sha256,
        "collection_method": "automated",
        "engine": {
            "adapter_id": "sherpa-onnx",
            "engine_id": "sherpa-onnx@" + artifact_sha256[:16],
            "asset_management": "product",
            "recognizer_locale": "zh-CN",
            "requires_on_device": True,
            "supports_on_device_at_run": True,
            "artifact_id": "rimeai-voice-zh-en-v1",
            "artifact_content_sha256": artifact_sha256,
            "model_id": "streaming-zipformer-zh-en",
            "model_revision": "2026.08.1",
        },
        "platform": {
            "os_version": "14.7",
            "os_build": "23H124",
            "hardware_class": "Mac15.7",
            "arch": "arm64",
        },
        "audio_io": {
            "device_class": "virtual_fixture",
            "sample_format": "pcm_s16le",
            "sample_rate_hz": 44_100,
            "channels": 1,
        },
        "policy": {
            "endpoint_strategy": "push-to-talk",
            "hotwords_enabled": hotword_snapshot is not None,
            "postprocessor_id": "none",
        },
        "unsupported_subsets": [],
        "clock": {"domain": "helper_server_monotonic", "unit": "ms"},
    }
    if hotword_snapshot is not None:
        run["policy"]["hotword_set_sha256"] = hotword_snapshot[
            "hotword_set_sha256"
        ]
    path = corpus_root.parent / "run.json"
    path.write_text(
        json.dumps(run, ensure_ascii=False, separators=(",", ":")),
        encoding="utf-8",
    )
    return path.resolve()


def test_collects_through_exact_private_plan_and_atomically_installs_output(
    tmp_path: Path,
):
    corpus_root = _write_fixture_corpus(tmp_path)
    driver = _write_native_driver(tmp_path)
    run_path = _write_product_run(corpus_root, driver)
    artifact_dir = (tmp_path / "artifact").resolve()
    artifact_dir.mkdir()
    output_path = tmp_path / "observations.jsonl"
    output_path.write_bytes(b"previous-output\n")
    output_path.chmod(0o644)

    digest = collect_voice_observations(
        corpus_root,
        run_path,
        driver,
        artifact_dir,
        output_path,
    )

    assert output_path.is_file()
    assert not output_path.is_symlink()
    assert stat.S_IMODE(output_path.stat().st_mode) == 0o600
    assert digest == hashlib.sha256(output_path.read_bytes()).hexdigest()
    assert json.loads(output_path.read_text(encoding="utf-8"))["sample_id"] == (
        "voice-000001"
    )


def test_hotword_enabled_collection_passes_an_exact_validated_snapshot(
    tmp_path: Path,
):
    snapshot = _hotword_snapshot(["API", "接口"])
    corpus_root = _write_fixture_corpus(tmp_path)
    policy = {
        "endpoint_strategy": "push-to-talk",
        "hotwords_enabled": True,
        "postprocessor_id": "none",
        "hotword_set_sha256": snapshot["hotword_set_sha256"],
    }
    driver = _write_native_driver(
        tmp_path,
        expected_policy=policy,
        expected_hotword_snapshot=snapshot,
    )
    run_path = _write_product_run(
        corpus_root,
        driver,
        hotword_snapshot=snapshot,
    )
    artifact_dir = (tmp_path / "artifact").resolve()
    artifact_dir.mkdir()
    hotwords_file = (tmp_path / "hotwords.json").resolve()
    hotwords_file.write_text(
        json.dumps(snapshot, ensure_ascii=False, separators=(",", ":")),
        encoding="utf-8",
    )

    digest = collect_voice_observations(
        corpus_root,
        run_path,
        driver,
        artifact_dir,
        tmp_path / "observations.jsonl",
        hotwords_file,
    )

    assert len(digest) == 64


def test_hotword_snapshot_rejects_one_swift_grapheme_cluster(tmp_path: Path):
    snapshot = _hotword_snapshot(["👩‍👩‍👧‍👧"])
    corpus_root = _write_fixture_corpus(tmp_path)
    driver = _write_native_driver(
        tmp_path,
        expected_hotword_snapshot=snapshot,
        expected_policy={
            "endpoint_strategy": "push-to-talk",
            "hotwords_enabled": True,
            "postprocessor_id": "none",
            "hotword_set_sha256": snapshot["hotword_set_sha256"],
        },
    )
    run_path = _write_product_run(
        corpus_root,
        driver,
        hotword_snapshot=snapshot,
    )
    artifact_dir = (tmp_path / "artifact").resolve()
    artifact_dir.mkdir()
    hotwords_file = (tmp_path / "hotwords.json").resolve()
    hotwords_file.write_text(
        json.dumps(snapshot, ensure_ascii=False, separators=(",", ":")),
        encoding="utf-8",
    )
    output_path = tmp_path / "observations.jsonl"

    with pytest.raises(VoiceObservationCollectionError):
        collect_voice_observations(
            corpus_root,
            run_path,
            driver,
            artifact_dir,
            output_path,
            hotwords_file,
        )

    assert not output_path.exists()


@pytest.mark.parametrize(
    ("field", "claimed_value"),
    (("sample_rate_hz", 16_000), ("channels", 2)),
)
def test_run_audio_format_must_match_every_corpus_sample(
    tmp_path: Path,
    field: str,
    claimed_value: int,
):
    corpus_root = _write_fixture_corpus(tmp_path)
    driver = _write_native_driver(tmp_path)
    run_path = _write_product_run(corpus_root, driver)
    run = json.loads(run_path.read_text(encoding="utf-8"))
    run["audio_io"][field] = claimed_value
    run_path.write_text(
        json.dumps(run, ensure_ascii=False, separators=(",", ":")),
        encoding="utf-8",
    )
    artifact_dir = (tmp_path / "artifact").resolve()
    artifact_dir.mkdir()
    output_path = tmp_path / "observations.jsonl"

    with pytest.raises(VoiceObservationCollectionError):
        collect_voice_observations(
            corpus_root,
            run_path,
            driver,
            artifact_dir,
            output_path,
        )

    assert not output_path.exists()


@pytest.mark.parametrize("stream_name", ("stdout", "stderr"))
def test_native_diagnostics_are_bounded_while_the_driver_is_running(
    tmp_path: Path,
    monkeypatch,
    stream_name: str,
):
    corpus_root = _write_fixture_corpus(tmp_path)
    driver = tmp_path / "native-driver"
    target = "sys.stdout" if stream_name == "stdout" else "sys.stderr"
    driver.write_text(
        f"#!{sys.executable}\n"
        "import sys\n"
        "import time\n"
        f"{target}.write('x' * 8192)\n"
        f"{target}.flush()\n"
        "time.sleep(5)\n",
        encoding="utf-8",
    )
    driver.chmod(0o700)
    driver = driver.resolve()
    run_path = _write_product_run(corpus_root, driver)
    artifact_dir = (tmp_path / "artifact").resolve()
    artifact_dir.mkdir()
    output_path = tmp_path / "observations.jsonl"
    monkeypatch.setattr(
        observation_collection, "_NATIVE_STARTUP_ALLOWANCE_SECONDS", 5.0
    )
    monkeypatch.setattr(
        observation_collection, "_NATIVE_FINAL_DEADLINE_SECONDS", 0.0
    )
    monkeypatch.setattr(
        observation_collection, "_MAXIMUM_NATIVE_TIMEOUT_SECONDS", 10.0
    )

    started = time.monotonic()
    # Detection happens in the 0.05-second monitor poll once the driver
    # writes — well inside the ~5-second deadline — so the elapsed bound
    # guards the abort without guessing at subprocess spawn time.
    diagnostic = "output" if stream_name == "stdout" else "error"
    with pytest.raises(
        VoiceObservationCollectionError,
        match=f"wrote unexpected standard {diagnostic}",
    ):
        collect_voice_observations(
            corpus_root,
            run_path,
            driver,
            artifact_dir,
            output_path,
        )
    elapsed = time.monotonic() - started

    assert elapsed < 5.0
    assert not output_path.exists()


@pytest.mark.parametrize(
    ("section", "field", "value"),
    (
        (None, "collection_method", "manual_assistive"),
        ("audio_io", "device_class", "built_in"),
        ("policy", "endpoint_strategy", "on-device-required"),
        ("policy", "postprocessor_id", "identity-v1"),
        ("engine", "requires_on_device", False),
        ("engine", "supports_on_device_at_run", False),
    ),
)
def test_collection_accepts_only_the_offline_evaluation_replay_run_mode(
    tmp_path: Path,
    section,
    field: str,
    value,
):
    corpus_root = _write_fixture_corpus(tmp_path)
    driver = _write_native_driver(tmp_path)
    run_path = _write_product_run(corpus_root, driver)
    run = json.loads(run_path.read_text(encoding="utf-8"))
    target = run if section is None else run[section]
    target[field] = value
    run_path.write_text(
        json.dumps(run, ensure_ascii=False, separators=(",", ":")),
        encoding="utf-8",
    )
    artifact_dir = (tmp_path / "artifact").resolve()
    artifact_dir.mkdir()
    output_path = tmp_path / "observations.jsonl"

    with pytest.raises(VoiceObservationCollectionError):
        collect_voice_observations(
            corpus_root,
            run_path,
            driver,
            artifact_dir,
            output_path,
        )

    assert not output_path.exists()


@pytest.mark.parametrize(
    "violation",
    (
        "unsupported_locale",
        "underived_engine_id",
        "sample_over_sixty_seconds",
        "enabled_empty_hotwords",
        "non_nfc_artifact_path",
        "non_nfc_output_path",
    ),
)
def test_swift_plan_constraints_are_rejected_before_native_launch(
    tmp_path: Path,
    violation: str,
):
    frame_count = 44_100 * 61 if violation == "sample_over_sixty_seconds" else 100
    corpus_root = _write_fixture_corpus(tmp_path, frame_count=frame_count)
    launch_marker = tmp_path / "native-launched"
    driver = _write_native_driver(tmp_path)
    original = driver.read_text(encoding="utf-8")
    driver.write_text(
        original.replace(
            "import stat\n",
            "import stat\nfrom pathlib import Path\n"
            f"Path({str(launch_marker)!r}).write_text('launched')\n",
            1,
        ),
        encoding="utf-8",
    )
    driver.chmod(0o700)
    driver = driver.resolve()
    run_path = _write_product_run(corpus_root, driver)
    run = json.loads(run_path.read_text(encoding="utf-8"))
    artifact_dir = (tmp_path / "artifact").resolve()
    hotwords_file = None
    if violation == "unsupported_locale":
        run["engine"]["recognizer_locale"] = "fr-FR"
    elif violation == "underived_engine_id":
        run["engine"]["engine_id"] = "sherpa-onnx@" + "0" * 16
    elif violation == "enabled_empty_hotwords":
        run["policy"]["hotwords_enabled"] = True
        run["policy"]["hotword_set_sha256"] = _EMPTY_HOTWORD_SHA256
        hotwords_file = (tmp_path / "hotwords.json").resolve()
        hotwords_file.write_text(
            json.dumps(_hotword_snapshot([]), separators=(",", ":")),
            encoding="utf-8",
        )
    elif violation == "non_nfc_artifact_path":
        artifact_dir = tmp_path / "artifact-e\u0301"
    artifact_dir.mkdir()
    run_path.write_text(
        json.dumps(run, ensure_ascii=False, separators=(",", ":")),
        encoding="utf-8",
    )
    output_path = (
        tmp_path / "observations-e\u0301.jsonl"
        if violation == "non_nfc_output_path"
        else tmp_path / "observations.jsonl"
    )

    with pytest.raises(VoiceObservationCollectionError):
        collect_voice_observations(
            corpus_root,
            run_path,
            driver,
            artifact_dir,
            output_path,
            hotwords_file,
        )

    assert not launch_marker.exists()
    assert not output_path.exists()


@pytest.mark.parametrize(
    "behavior",
    (
        "early",
        "nonzero",
        "timeout",
        "oversize",
        "trailing_stdout",
        "trailing_stderr",
        "invalid",
        "wrong_mode",
        "extra_file",
    ),
)
def test_native_failure_never_installs_observations(
    tmp_path: Path,
    monkeypatch,
    behavior: str,
):
    corpus_root = _write_fixture_corpus(tmp_path)
    driver = _write_failure_driver(tmp_path, behavior)
    run_path = _write_product_run(corpus_root, driver)
    artifact_dir = (tmp_path / "artifact").resolve()
    artifact_dir.mkdir()
    output_path = tmp_path / "observations.jsonl"
    if behavior == "timeout":
        monkeypatch.setattr(
            observation_collection, "_NATIVE_STARTUP_ALLOWANCE_SECONDS", 0.1
        )
        monkeypatch.setattr(
            observation_collection, "_NATIVE_FINAL_DEADLINE_SECONDS", 0.0
        )
        monkeypatch.setattr(
            observation_collection, "_MAXIMUM_NATIVE_TIMEOUT_SECONDS", 1.0
        )
    if behavior == "oversize":
        monkeypatch.setattr(
            observation_collection, "_MAXIMUM_OBSERVATIONS_BYTES", 128
        )

    with pytest.raises(VoiceObservationCollectionError):
        collect_voice_observations(
            corpus_root,
            run_path,
            driver,
            artifact_dir,
            output_path,
        )

    assert not output_path.exists()


@pytest.mark.parametrize("behavior", ("reversed", "cancelled", "resources"))
def test_native_output_must_match_driver_order_outcomes_and_shape(
    tmp_path: Path,
    behavior: str,
):
    corpus_root = _write_fixture_corpus(
        tmp_path,
        sample_count=2 if behavior == "reversed" else 1,
    )
    driver = _write_failure_driver(tmp_path, behavior)
    run_path = _write_product_run(corpus_root, driver)
    artifact_dir = (tmp_path / "artifact").resolve()
    artifact_dir.mkdir()
    output_path = tmp_path / "observations.jsonl"

    with pytest.raises(VoiceObservationCollectionError):
        collect_voice_observations(
            corpus_root,
            run_path,
            driver,
            artifact_dir,
            output_path,
        )

    assert not output_path.exists()


@pytest.mark.parametrize("behavior", ("replace_plan", "staging_mode"))
def test_plan_and_staging_identity_are_revalidated_after_native_exit(
    tmp_path: Path,
    behavior: str,
):
    corpus_root = _write_fixture_corpus(tmp_path)
    driver = _write_failure_driver(tmp_path, behavior)
    run_path = _write_product_run(corpus_root, driver)
    artifact_dir = (tmp_path / "artifact").resolve()
    artifact_dir.mkdir()
    output_path = tmp_path / "observations.jsonl"

    with pytest.raises(VoiceObservationCollectionError):
        collect_voice_observations(
            corpus_root,
            run_path,
            driver,
            artifact_dir,
            output_path,
        )

    assert not output_path.exists()


@pytest.mark.parametrize("mismatch", ("snapshot", "run"))
def test_hotword_digest_mismatch_is_rejected_before_native_collection(
    tmp_path: Path,
    mismatch: str,
):
    valid_snapshot = _hotword_snapshot(["API", "接口"])
    file_snapshot = dict(valid_snapshot)
    run_snapshot = dict(valid_snapshot)
    if mismatch == "snapshot":
        file_snapshot["hotword_set_sha256"] = "0" * 64
    else:
        run_snapshot["hotword_set_sha256"] = "f" * 64
    corpus_root = _write_fixture_corpus(tmp_path)
    driver = _write_native_driver(tmp_path)
    run_path = _write_product_run(
        corpus_root,
        driver,
        hotword_snapshot=run_snapshot,
    )
    artifact_dir = (tmp_path / "artifact").resolve()
    artifact_dir.mkdir()
    hotwords_file = (tmp_path / "hotwords.json").resolve()
    hotwords_file.write_text(
        json.dumps(file_snapshot, ensure_ascii=False, separators=(",", ":")),
        encoding="utf-8",
    )
    output_path = tmp_path / "observations.jsonl"

    with pytest.raises(VoiceObservationCollectionError):
        collect_voice_observations(
            corpus_root,
            run_path,
            driver,
            artifact_dir,
            output_path,
            hotwords_file,
        )

    assert not output_path.exists()


@pytest.mark.parametrize(
    "violation", ("driver_hash", "driver_symlink", "artifact_symlink")
)
def test_native_and_artifact_paths_must_have_pinned_canonical_identity(
    tmp_path: Path,
    violation: str,
):
    corpus_root = _write_fixture_corpus(tmp_path)
    driver = _write_native_driver(tmp_path)
    run_path = _write_product_run(corpus_root, driver)
    real_artifact = (tmp_path / "artifact-real").resolve()
    real_artifact.mkdir()
    artifact_dir = real_artifact
    native_driver = driver
    if violation == "driver_hash":
        run = json.loads(run_path.read_text(encoding="utf-8"))
        run["implementation_fingerprint"] = "0" * 64
        run_path.write_text(
            json.dumps(run, ensure_ascii=False, separators=(",", ":")),
            encoding="utf-8",
        )
    elif violation == "driver_symlink":
        native_driver = tmp_path / "driver-link"
        native_driver.symlink_to(driver)
    else:
        artifact_dir = tmp_path / "artifact-link"
        artifact_dir.symlink_to(real_artifact, target_is_directory=True)
    output_path = tmp_path / "observations.jsonl"

    with pytest.raises(VoiceObservationCollectionError):
        collect_voice_observations(
            corpus_root,
            run_path,
            native_driver,
            artifact_dir,
            output_path,
        )

    assert not output_path.exists()


def test_executes_a_pinned_driver_copy_when_the_original_path_is_replaced(
    tmp_path: Path,
    monkeypatch,
):
    corpus_root = _write_fixture_corpus(tmp_path)
    driver = _write_native_driver(tmp_path)
    run_path = _write_product_run(corpus_root, driver)
    artifact_dir = (tmp_path / "artifact").resolve()
    artifact_dir.mkdir()
    replacement_marker = tmp_path / "replacement-ran"
    replacement = tmp_path / "replacement-driver"
    replacement.write_text(
        f"#!{sys.executable}\n"
        "from pathlib import Path\n"
        f"Path({str(replacement_marker)!r}).write_text('ran')\n"
        "raise SystemExit(9)\n",
        encoding="utf-8",
    )
    replacement.chmod(0o700)
    real_popen = observation_collection.subprocess.Popen

    def replace_original_then_spawn(*args, **kwargs):
        os.replace(replacement, driver)
        return real_popen(*args, **kwargs)

    monkeypatch.setattr(
        observation_collection.subprocess,
        "Popen",
        replace_original_then_spawn,
    )
    output_path = tmp_path / "observations.jsonl"

    digest = collect_voice_observations(
        corpus_root,
        run_path,
        driver,
        artifact_dir,
        output_path,
    )

    assert not replacement_marker.exists()
    assert digest == hashlib.sha256(output_path.read_bytes()).hexdigest()


@pytest.mark.parametrize(
    "target_kind",
    ("corpus", "run", "driver", "artifact", "hotwords", "audio"),
)
def test_output_cannot_overwrite_or_enter_any_collection_input(
    tmp_path: Path,
    target_kind: str,
):
    corpus_root = _write_fixture_corpus(tmp_path)
    snapshot = _hotword_snapshot(["API", "接口"])
    driver = _write_native_driver(tmp_path)
    run_path = _write_product_run(
        corpus_root,
        driver,
        hotword_snapshot=snapshot if target_kind == "hotwords" else None,
    )
    artifact_dir = (tmp_path / "artifact").resolve()
    artifact_dir.mkdir()
    hotwords_file = None
    if target_kind == "hotwords":
        hotwords_file = (tmp_path / "hotwords.json").resolve()
        hotwords_file.write_text(
            json.dumps(snapshot, ensure_ascii=False, separators=(",", ":")),
            encoding="utf-8",
        )
    targets = {
        "corpus": corpus_root / "attempt.jsonl",
        "run": run_path,
        "driver": driver,
        "artifact": artifact_dir / "attempt.jsonl",
        "hotwords": hotwords_file,
        "audio": corpus_root / "audio" / "sample.wav",
    }
    output_path = targets[target_kind]
    assert output_path is not None
    original = output_path.read_bytes() if output_path.is_file() else None

    with pytest.raises(VoiceObservationCollectionError):
        collect_voice_observations(
            corpus_root,
            run_path,
            driver,
            artifact_dir,
            output_path,
            hotwords_file,
        )

    if original is None:
        assert not output_path.exists()
    else:
        assert output_path.read_bytes() == original


def test_oversize_observations_are_bounded_while_driver_is_running(
    tmp_path: Path,
    monkeypatch,
):
    corpus_root = _write_fixture_corpus(tmp_path)
    driver = _write_failure_driver(tmp_path, "oversize_then_sleep")
    run_path = _write_product_run(corpus_root, driver)
    artifact_dir = (tmp_path / "artifact").resolve()
    artifact_dir.mkdir()
    output_path = tmp_path / "observations.jsonl"
    monkeypatch.setattr(
        observation_collection, "_MAXIMUM_OBSERVATIONS_BYTES", 128
    )
    monkeypatch.setattr(
        observation_collection, "_NATIVE_STARTUP_ALLOWANCE_SECONDS", 5.0
    )
    monkeypatch.setattr(
        observation_collection, "_NATIVE_FINAL_DEADLINE_SECONDS", 0.0
    )
    monkeypatch.setattr(
        observation_collection, "_MAXIMUM_NATIVE_TIMEOUT_SECONDS", 10.0
    )

    started = time.monotonic()
    # Detection happens in the 0.05-second monitor poll once the driver
    # writes — well inside the ~5-second deadline — so the elapsed bound
    # guards the abort without guessing at subprocess spawn time.
    with pytest.raises(
        VoiceObservationCollectionError,
        match="exceeded their secure bound",
    ):
        collect_voice_observations(
            corpus_root,
            run_path,
            driver,
            artifact_dir,
            output_path,
        )
    elapsed = time.monotonic() - started

    assert elapsed < 5.0
    assert not output_path.exists()


def test_native_process_group_is_cleaned_after_parent_success(
    tmp_path: Path,
):
    corpus_root = _write_fixture_corpus(tmp_path)
    descendant_marker = tmp_path / "descendant-survived"
    driver = _write_failure_driver(
        tmp_path,
        "fork_descendant",
        descendant_marker=descendant_marker,
    )
    run_path = _write_product_run(corpus_root, driver)
    artifact_dir = (tmp_path / "artifact").resolve()
    artifact_dir.mkdir()
    output_path = tmp_path / "observations.jsonl"

    collect_voice_observations(
        corpus_root,
        run_path,
        driver,
        artifact_dir,
        output_path,
    )
    time.sleep(0.6)

    assert not descendant_marker.exists()


def test_native_process_group_is_cleaned_after_parent_failure(
    tmp_path: Path,
):
    corpus_root = _write_fixture_corpus(tmp_path)
    descendant_marker = tmp_path / "descendant-survived"
    driver = _write_failure_driver(
        tmp_path,
        "fork_descendant_nonzero",
        descendant_marker=descendant_marker,
    )
    run_path = _write_product_run(corpus_root, driver)
    artifact_dir = (tmp_path / "artifact").resolve()
    artifact_dir.mkdir()
    output_path = tmp_path / "observations.jsonl"

    with pytest.raises(VoiceObservationCollectionError):
        collect_voice_observations(
            corpus_root,
            run_path,
            driver,
            artifact_dir,
            output_path,
        )
    time.sleep(0.6)

    assert not descendant_marker.exists()
    assert not output_path.exists()


def test_native_process_group_cleanup_failure_is_fail_closed_and_not_retried(
    tmp_path: Path,
    monkeypatch,
):
    corpus_root = _write_fixture_corpus(tmp_path)
    driver = _write_native_driver(tmp_path)
    run_path = _write_product_run(corpus_root, driver)
    artifact_dir = (tmp_path / "artifact").resolve()
    artifact_dir.mkdir()
    output_path = tmp_path / "observations.jsonl"
    calls = []

    def reject_group_cleanup(process_group_id, signal_number):
        calls.append((process_group_id, signal_number))
        raise OSError(errno.EPERM, "injected process-group denial")

    monkeypatch.setattr(
        observation_collection.os,
        "killpg",
        reject_group_cleanup,
    )

    with pytest.raises(VoiceObservationCollectionError):
        collect_voice_observations(
            corpus_root,
            run_path,
            driver,
            artifact_dir,
            output_path,
        )

    assert len(calls) == 1
    assert not output_path.exists()


@pytest.mark.parametrize("replacement_kind", ("regular", "fifo"))
def test_loader_is_bound_to_the_captured_candidate_before_path_open(
    tmp_path: Path,
    monkeypatch,
    replacement_kind: str,
):
    corpus_root = _write_fixture_corpus(tmp_path)
    driver = _write_native_driver(tmp_path)
    run_path = _write_product_run(corpus_root, driver)
    artifact_dir = (tmp_path / "artifact").resolve()
    artifact_dir.mkdir()
    output_path = tmp_path / "observations.jsonl"
    real_loader = observation_collection.load_voice_observations
    observed_texts = []
    fifo_path_opens = []
    swapped_observation = {
        "schema_version": 1,
        "sample_id": "voice-000001",
        "outcome": "final",
        "partials": [],
        "stop_received_elapsed_ms": 10,
        "final": {"text": "path-swap", "elapsed_ms": 20},
    }
    swapped_payload = (
        json.dumps(swapped_observation, separators=(",", ":")) + "\n"
    ).encode("utf-8")

    def replace_before_authoritative_open(path, corpus, run):
        candidate_path = Path(str(path))
        candidate_path.unlink()
        writer = None
        stop_writer = None
        if replacement_kind == "fifo":
            os.mkfifo(candidate_path, 0o600)
            stop_writer = threading.Event()

            def write_fifo_when_reader_arrives():
                deadline = time.monotonic() + 0.5
                while not stop_writer.is_set() and time.monotonic() < deadline:
                    try:
                        descriptor = os.open(
                            candidate_path,
                            os.O_WRONLY | os.O_NONBLOCK,
                        )
                    except OSError as error:
                        if error.errno in {errno.ENXIO, errno.ENOENT}:
                            time.sleep(0.005)
                            continue
                        return
                    fifo_path_opens.append(True)
                    try:
                        os.write(descriptor, swapped_payload)
                    finally:
                        os.close(descriptor)
                    return

            writer = threading.Thread(
                target=write_fifo_when_reader_arrives,
                daemon=True,
            )
            writer.start()
        else:
            candidate_path.write_bytes(swapped_payload)
            candidate_path.chmod(0o600)
        try:
            observations = real_loader(path, corpus, run)
        finally:
            if writer is not None:
                stop_writer.set()
                writer.join(timeout=1)
        observed_texts.append(observations[0]["final"]["text"])
        return observations

    monkeypatch.setattr(
        observation_collection,
        "load_voice_observations",
        replace_before_authoritative_open,
    )

    with pytest.raises(VoiceObservationCollectionError):
        collect_voice_observations(
            corpus_root,
            run_path,
            driver,
            artifact_dir,
            output_path,
        )

    assert observed_texts == []
    assert fifo_path_opens == []
    assert not output_path.exists()


@pytest.mark.parametrize("replacement_kind", ("regular", "fifo"))
def test_loader_path_replacement_cannot_change_the_installed_candidate(
    tmp_path: Path,
    monkeypatch,
    replacement_kind: str,
):
    corpus_root = _write_fixture_corpus(tmp_path)
    driver = _write_native_driver(tmp_path)
    run_path = _write_product_run(corpus_root, driver)
    artifact_dir = (tmp_path / "artifact").resolve()
    artifact_dir.mkdir()
    output_path = tmp_path / "observations.jsonl"
    real_loader = observation_collection.load_voice_observations

    def replace_after_load(path, corpus, run):
        observations = real_loader(path, corpus, run)
        candidate_path = Path(str(path))
        candidate_path.unlink()
        if replacement_kind == "fifo":
            os.mkfifo(candidate_path, 0o600)
        else:
            candidate_path.write_bytes(b"{}\n")
            candidate_path.chmod(0o600)
        return observations

    monkeypatch.setattr(
        observation_collection,
        "load_voice_observations",
        replace_after_load,
    )

    with pytest.raises(VoiceObservationCollectionError):
        collect_voice_observations(
            corpus_root,
            run_path,
            driver,
            artifact_dir,
            output_path,
        )

    assert not output_path.exists()


@pytest.mark.parametrize("had_existing_output", (False, True))
def test_post_commit_directory_fsync_failure_returns_verified_success(
    tmp_path: Path,
    monkeypatch,
    had_existing_output: bool,
):
    corpus_root = _write_fixture_corpus(tmp_path)
    driver = _write_native_driver(tmp_path)
    run_path = _write_product_run(corpus_root, driver)
    artifact_dir = (tmp_path / "artifact").resolve()
    artifact_dir.mkdir()
    output_path = tmp_path / "observations.jsonl"
    if had_existing_output:
        output_path.write_bytes(b"old\n")
    real_replace = observation_collection.os.replace
    real_fsync = observation_collection.os.fsync
    state = {"committed": False, "failed": False}

    def record_commit(source, destination):
        result = real_replace(source, destination)
        state["committed"] = True
        return result

    def fail_post_commit_directory_fsync_once(descriptor):
        metadata = os.fstat(descriptor)
        if (
            state["committed"]
            and not state["failed"]
            and stat.S_ISDIR(metadata.st_mode)
        ):
            state["failed"] = True
            raise OSError("injected post-commit fsync failure")
        return real_fsync(descriptor)

    monkeypatch.setattr(observation_collection.os, "replace", record_commit)
    monkeypatch.setattr(
        observation_collection.os,
        "fsync",
        fail_post_commit_directory_fsync_once,
    )

    digest = collect_voice_observations(
        corpus_root,
        run_path,
        driver,
        artifact_dir,
        output_path,
    )

    assert state == {"committed": True, "failed": True}
    assert stat.S_IMODE(output_path.stat().st_mode) == 0o600
    assert digest == hashlib.sha256(output_path.read_bytes()).hexdigest()
    assert json.loads(output_path.read_text(encoding="utf-8"))["sample_id"] == (
        "voice-000001"
    )
