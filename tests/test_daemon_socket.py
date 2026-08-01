import asyncio
import json
import math
from pathlib import Path
import stat
import tempfile
import time

from rimeai_daemon.server import RimeAIDaemonServer
from rimeai_daemon.server import DaemonConfigurationError
from rimeai_daemon.server import _validate_inference_request


class FakeEngine:
    artifact_id = "fixture-engine-v1"

    def infer(self, request):
        if request["pinyin"] == "slow":
            time.sleep(0.1)
        return {
            "ranked_candidate": request["candidates"][-1],
            "sentence_suggestion": "",
            "confidence": 0.9,
        }


class InvalidEngine:
    artifact_id = "invalid-engine-v1"

    def infer(self, request):
        return {
            "ranked_candidate": "not-an-input-candidate",
            "sentence_suggestion": "contains\nnewline",
            "confidence": math.nan,
        }


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
            assert response["model_artifact_id"] == "fixture-engine-v1"
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
