import asyncio
import json
from pathlib import Path
import stat
import tempfile
import threading
import time

import pytest

from rimeai_daemon.__main__ import _probe_running_daemon
from rimeai_daemon.server import RimeAIDaemonServer
from rimeai_daemon.server import DaemonConfigurationError
from rimeai_daemon.server import _validate_inference_request


class FakeEngine:
    artifact_id = "fixture-engine-v1"

    def infer(self, request):
        if request["pinyin"] == "slow":
            time.sleep(0.1)
        return {
            "decision": "ranked_candidate",
            "ranked_candidate": request["candidates"][-1],
            "sentence_suggestion": "",
            "confidence": 0.9,
        }


class InvalidEngine:
    artifact_id = "invalid-engine-v1"

    def infer(self, request):
        return {
            "decision": "sentence_suggestion",
            "ranked_candidate": request["candidates"][-1],
            "sentence_suggestion": "请执行这条命令",
            "confidence": 0.93,
        }


class LongInputAbstentionEngine:
    artifact_id = "long-input-abstention-v1"

    def infer(self, request):
        return {
            "decision": request["context"],
            "ranked_candidate": "",
            "sentence_suggestion": "",
            "confidence": 0.0,
        }


class ConcurrencyTrackingEngine:
    artifact_id = "serial-engine-v1"

    def __init__(self):
        self.active = 0
        self.maximum_active = 0
        self.lock = threading.Lock()

    def infer(self, request):
        with self.lock:
            self.active += 1
            self.maximum_active = max(self.maximum_active, self.active)
        try:
            time.sleep(0.05)
            return {
                "decision": "same_top_candidate",
                "ranked_candidate": "",
                "sentence_suggestion": "",
                "confidence": 1.0,
            }
        finally:
            with self.lock:
                self.active -= 1


async def _read_json(reader):
    return json.loads((await reader.readline()).decode("utf-8"))


async def _write_json(writer, payload):
    writer.write(
        (
            json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
            + "\n"
        ).encode("utf-8")
    )
    await writer.drain()


async def _hello(reader, writer):
    await _write_json(
        writer,
        {
            "schema_version": 1,
            "type": "hello",
            "client_id": "test-client",
            "capabilities": ["rerank", "sentence", "cancel"],
        },
    )
    response = await _read_json(reader)
    assert response["type"] == "hello"
    assert response["status"] == "ok"
    assert "decision-reasons" in response["capabilities"]
    assert "long-input-reasons" in response["capabilities"]


def test_daemon_socket_permissions_handshake_and_inference():
    async def scenario(runtime_root: Path):
        socket_path = runtime_root / "runtime" / "rimeai.sock"
        server = RimeAIDaemonServer(socket_path, FakeEngine())
        await server.start()
        try:
            assert stat.S_IMODE(socket_path.parent.stat().st_mode) == 0o700
            assert stat.S_IMODE(socket_path.stat().st_mode) == 0o600
            reader, writer = await asyncio.open_unix_connection(socket_path)
            await _hello(reader, writer)
            await _write_json(
                writer,
                {
                    "schema_version": 1,
                    "type": "infer",
                    "request_id": "request-1",
                    "composition_id": "composition-1",
                    "revision": 1,
                    "app_session_id": "app-1",
                    "context_policy": "standard",
                    "context": "请执行这条",
                    "pinyin": "mingling",
                    "candidates": ["明令", "命令"],
                    "deadline_ms": 400,
                    "allow_sentence": True,
                    "sensitive": False,
                },
            )
            response = await _read_json(reader)
            assert response["request_id"] == "request-1"
            assert response["status"] == "ok"
            assert response["ranked_candidate"] == "命令"
            assert response["decision"] == "ranked_candidate"
            assert response["model_artifact_id"] == "fixture-engine-v1"
            writer.close()
            await writer.wait_closed()
        finally:
            await server.close()

    with tempfile.TemporaryDirectory(prefix="rai-", dir="/tmp") as directory:
        asyncio.run(scenario(Path(directory)))


def test_release_health_probe_validates_artifact_and_offline_lock():
    async def scenario(runtime_root: Path):
        socket_path = runtime_root / "runtime" / "rimeai.sock"
        server = RimeAIDaemonServer(socket_path, FakeEngine())
        await server.start()
        try:
            response = await asyncio.to_thread(
                _probe_running_daemon,
                socket_path,
                expected_artifact_id="fixture-engine-v1",
                timeout_ms=500,
            )
            assert response["status"] == "ok"
            assert response["offline_lock"] is True

            with pytest.raises(ValueError, match="unexpected model artifact"):
                await asyncio.to_thread(
                    _probe_running_daemon,
                    socket_path,
                    expected_artifact_id="stale-engine",
                    timeout_ms=500,
                )
        finally:
            await server.close()

    with tempfile.TemporaryDirectory(prefix="rai-", dir="/tmp") as directory:
        asyncio.run(scenario(Path(directory)))


def test_daemon_emits_long_input_abstentions_without_partial_text():
    async def scenario(runtime_root: Path):
        socket_path = runtime_root / "runtime" / "rimeai.sock"
        server = RimeAIDaemonServer(
            socket_path, LongInputAbstentionEngine()
        )
        await server.start()
        try:
            reader, writer = await asyncio.open_unix_connection(socket_path)
            await _hello(reader, writer)
            for revision, decision in enumerate(
                ("sentence_too_long", "sentence_incomplete"), start=1
            ):
                await _write_json(
                    writer,
                    {
                        "schema_version": 1,
                        "type": "infer",
                        "request_id": f"long-input-{revision}",
                        "composition_id": f"composition-{revision}",
                        "revision": revision,
                        "app_session_id": "app-1",
                        "context_policy": "standard",
                        "context": decision,
                        "pinyin": "shifou",
                        "candidates": ["是否", "是", "时"],
                        "deadline_ms": 400,
                        "allow_sentence": True,
                        "sensitive": False,
                    },
                )
                response = await _read_json(reader)
                assert response["status"] == "ok"
                assert response["decision"] == decision
                assert response["ranked_candidate"] == ""
                assert response["sentence_suggestion"] == ""
                assert response["confidence"] == 0.0
            writer.close()
            await writer.wait_closed()
        finally:
            await server.close()

    with tempfile.TemporaryDirectory(prefix="rai-", dir="/tmp") as directory:
        asyncio.run(scenario(Path(directory)))


def test_latest_request_wins_and_old_result_is_never_emitted():
    async def scenario(runtime_root: Path):
        socket_path = runtime_root / "runtime" / "rimeai.sock"
        server = RimeAIDaemonServer(socket_path, FakeEngine())
        await server.start()
        try:
            reader, writer = await asyncio.open_unix_connection(socket_path)
            await _hello(reader, writer)
            base = {
                "schema_version": 1,
                "type": "infer",
                "composition_id": "composition-1",
                "app_session_id": "app-1",
                "context_policy": "standard",
                "context": "上下文",
                "candidates": ["第一", "第二"],
                "deadline_ms": 400,
                "allow_sentence": False,
                "sensitive": False,
            }
            await _write_json(
                writer,
                {
                    **base,
                    "request_id": "old",
                    "revision": 1,
                    "pinyin": "slow",
                },
            )
            await asyncio.sleep(0.01)
            await _write_json(
                writer,
                {
                    **base,
                    "request_id": "new",
                    "revision": 2,
                    "pinyin": "fast",
                },
            )

            response = await asyncio.wait_for(_read_json(reader), 0.3)
            assert response["request_id"] == "new"
            assert response["status"] == "ok"
            try:
                await asyncio.wait_for(reader.readline(), 0.15)
            except asyncio.TimeoutError:
                pass
            else:
                raise AssertionError("the stale request emitted a response")
            writer.close()
            await writer.wait_closed()
        finally:
            await server.close()

    with tempfile.TemporaryDirectory(prefix="rai-", dir="/tmp") as directory:
        asyncio.run(scenario(Path(directory)))


def test_deadline_and_sensitive_policy_fail_closed():
    async def scenario(runtime_root: Path):
        socket_path = runtime_root / "runtime" / "rimeai.sock"
        server = RimeAIDaemonServer(socket_path, FakeEngine())
        await server.start()
        try:
            reader, writer = await asyncio.open_unix_connection(socket_path)
            await _hello(reader, writer)
            request = {
                "schema_version": 1,
                "type": "infer",
                "composition_id": "composition-1",
                "revision": 1,
                "app_session_id": "app-1",
                "context_policy": "strict",
                "context": "",
                "pinyin": "slow",
                "candidates": ["第一", "第二"],
                "deadline_ms": 10,
                "allow_sentence": False,
                "sensitive": False,
            }
            await _write_json(
                writer, {**request, "request_id": "deadline"}
            )
            timeout_response = await _read_json(reader)
            assert timeout_response["status"] == "timeout"

            await _write_json(
                writer,
                {
                    **request,
                    "request_id": "sensitive",
                    "pinyin": "fast",
                    "sensitive": True,
                },
            )
            privacy_response = await _read_json(reader)
            assert privacy_response["status"] == "privacy_blocked"
            writer.close()
            await writer.wait_closed()
        finally:
            await server.close()

    with tempfile.TemporaryDirectory(prefix="rai-", dir="/tmp") as directory:
        asyncio.run(scenario(Path(directory)))


def test_native_inference_remains_serial_after_a_request_times_out():
    async def scenario(runtime_root: Path):
        socket_path = runtime_root / "runtime" / "rimeai.sock"
        engine = ConcurrencyTrackingEngine()
        server = RimeAIDaemonServer(socket_path, engine)
        await server.start()
        try:
            reader, writer = await asyncio.open_unix_connection(socket_path)
            await _hello(reader, writer)
            base = {
                "schema_version": 1,
                "type": "infer",
                "revision": 1,
                "app_session_id": "app-serial",
                "context_policy": "strict",
                "context": "",
                "pinyin": "mingling",
                "candidates": ["明令", "命令"],
                "allow_sentence": False,
                "sensitive": False,
            }
            await _write_json(
                writer,
                {
                    **base,
                    "request_id": "times-out",
                    "composition_id": "composition-timeout",
                    "deadline_ms": 10,
                },
            )
            assert (await _read_json(reader))["status"] == "timeout"
            await _write_json(
                writer,
                {
                    **base,
                    "request_id": "after-timeout",
                    "composition_id": "composition-after",
                    "deadline_ms": 400,
                },
            )
            assert (await _read_json(reader))["status"] == "ok"
            assert engine.maximum_active == 1
            writer.close()
            await writer.wait_closed()
        finally:
            await server.close()

    with tempfile.TemporaryDirectory(prefix="rai-", dir="/tmp") as directory:
        asyncio.run(scenario(Path(directory)))


def test_daemon_refuses_to_replace_an_active_socket():
    async def scenario(runtime_root: Path):
        socket_path = runtime_root / "runtime" / "rimeai.sock"
        first = RimeAIDaemonServer(socket_path, FakeEngine())
        second = RimeAIDaemonServer(socket_path, FakeEngine())
        await first.start()
        try:
            try:
                await second.start()
            except DaemonConfigurationError:
                pass
            else:
                raise AssertionError("second daemon replaced the active socket")
        finally:
            await first.close()

    with tempfile.TemporaryDirectory(prefix="rai-", dir="/tmp") as directory:
        asyncio.run(scenario(Path(directory)))


def test_request_validation_accepts_only_bounded_ascii_pinyin():
    base = {
        "request_id": "request-1",
        "composition_id": "composition-1",
        "revision": 1,
        "app_session_id": "app-1",
        "context_policy": "strict",
        "context": "",
        "pinyin": "ming'ling",
        "candidates": ["明令", "命令"],
        "deadline_ms": 400,
        "allow_sentence": False,
        "sensitive": False,
    }
    assert _validate_inference_request(base)["pinyin"] == "ming'ling"

    for invalid_pinyin in ("命令", "ming ling", "ming1ling", "MINGLING"):
        try:
            _validate_inference_request(
                {**base, "pinyin": invalid_pinyin}
            )
        except ValueError:
            pass
        else:
            raise AssertionError(f"accepted invalid pinyin: {invalid_pinyin}")


def test_invalid_engine_output_opens_the_circuit():
    async def scenario(runtime_root: Path):
        socket_path = runtime_root / "runtime" / "rimeai.sock"
        server = RimeAIDaemonServer(socket_path, InvalidEngine())
        await server.start()
        try:
            reader, writer = await asyncio.open_unix_connection(socket_path)
            await _hello(reader, writer)
            base = {
                "schema_version": 1,
                "type": "infer",
                "app_session_id": "app-1",
                "context_policy": "strict",
                "context": "",
                "pinyin": "mingling",
                "candidates": ["明令", "命令"],
                "deadline_ms": 400,
                "allow_sentence": True,
                "sensitive": False,
            }
            for revision in range(1, 4):
                await _write_json(
                    writer,
                    {
                        **base,
                        "request_id": f"bad-{revision}",
                        "composition_id": f"composition-{revision}",
                        "revision": revision,
                    },
                )
                response = await _read_json(reader)
                assert response["status"] == "engine_error"

            await _write_json(
                writer,
                {
                    **base,
                    "request_id": "circuit",
                    "composition_id": "composition-4",
                    "revision": 4,
                },
            )
            response = await _read_json(reader)
            assert response["status"] == "circuit_open"
            writer.close()
            await writer.wait_closed()
        finally:
            await server.close()

    with tempfile.TemporaryDirectory(prefix="rai-", dir="/tmp") as directory:
        asyncio.run(scenario(Path(directory)))


def test_explicit_cancel_acknowledges_and_never_emits_a_result():
    async def scenario(runtime_root: Path):
        socket_path = runtime_root / "runtime" / "rimeai.sock"
        server = RimeAIDaemonServer(socket_path, FakeEngine())
        await server.start()
        try:
            reader, writer = await asyncio.open_unix_connection(socket_path)
            await _hello(reader, writer)
            await _write_json(
                writer,
                {
                    "schema_version": 1,
                    "type": "infer",
                    "request_id": "cancel-me",
                    "composition_id": "composition-1",
                    "revision": 1,
                    "app_session_id": "app-1",
                    "context_policy": "strict",
                    "context": "",
                    "pinyin": "slow",
                    "candidates": ["第一", "第二"],
                    "deadline_ms": 400,
                    "allow_sentence": False,
                    "sensitive": False,
                },
            )
            await _write_json(
                writer,
                {
                    "schema_version": 1,
                    "type": "cancel",
                    "request_id": "cancel-me",
                },
            )
            response = await _read_json(reader)
            assert response == {
                "request_id": "cancel-me",
                "schema_version": 1,
                "status": "ok",
                "type": "cancelled",
            }
            try:
                await asyncio.wait_for(reader.readline(), 0.15)
            except asyncio.TimeoutError:
                pass
            else:
                raise AssertionError("cancelled inference emitted a result")
            writer.close()
            await writer.wait_closed()
        finally:
            await server.close()

    with tempfile.TemporaryDirectory(prefix="rai-", dir="/tmp") as directory:
        asyncio.run(scenario(Path(directory)))
