"""Neural sentence arm: subprocess service behavior and the
sentence-late protocol tier (capability gating, revision staleness,
executor isolation)."""

from __future__ import annotations

import asyncio
import json
import sys
import tempfile
import textwrap
from pathlib import Path
from time import monotonic

import pytest

from rimeai_daemon.neural_sentence import (
    NeuralSentenceConfigurationError,
    NeuralSentenceService,
    load_neural_sentence_config,
)
from rimeai_daemon.server import RimeAIDaemonServer

# --------------------------------------------------------------------------
# Stub worker: a real subprocess speaking the generate_sentence protocol.


def _write_worker_script(directory: Path, behavior: str) -> Path:
    script = directory / f"worker_{behavior}.py"
    script.write_text(
        textwrap.dedent(
            f"""
            import json
            import sys

            behavior = {behavior!r}
            for line in sys.stdin:
                try:
                    request = json.loads(line)
                except json.JSONDecodeError:
                    sys.exit(2)
                if behavior == "echo":
                    response = {{
                        "schema_version": 1,
                        "request_id": request["request_id"],
                        "suggestion": "请执行命令",
                        "confidence": 0.5,
                        "model_artifact_id": "stub:mlx-8bit:v3",
                        "stats": {{"cache_fed_tokens": 3}},
                    }}
                elif behavior == "low_confidence":
                    response = {{
                        "schema_version": 1,
                        "request_id": request["request_id"],
                        "suggestion": "请执行命令",
                        "confidence": 0.01,
                        "model_artifact_id": "stub:mlx-8bit:v3",
                    }}
                elif behavior == "garbage":
                    sys.stdout.write("not json\\n")
                    sys.stdout.flush()
                    continue
                elif behavior == "exit":
                    sys.exit(0)
                elif behavior == "silent":
                    # Reads stdin but never answers (deadline/wedge probe).
                    import time
                    time.sleep(30)
                    continue
                elif behavior == "echo_then_silent":
                    import time
                    if not getattr(sys.modules[__name__], "_answered", False):
                        sys.modules[__name__]._answered = True
                        response = {{
                            "schema_version": 1,
                            "request_id": request["request_id"],
                            "suggestion": "请执行命令",
                            "confidence": 0.5,
                            "model_artifact_id": "stub:mlx-8bit:v3",
                        }}
                    else:
                        time.sleep(30)
                        continue
                elif behavior == "overlong":
                    sys.stdout.write("x" * (2 * 1024 * 1024))
                    sys.stdout.flush()
                    continue
                elif behavior == "slow_first":
                    import time
                    time.sleep(0.4)
                    response = {{
                        "schema_version": 1,
                        "request_id": request["request_id"],
                        "suggestion": "请执行命令",
                        "confidence": 0.5,
                        "model_artifact_id": "stub:mlx-8bit:v3",
                    }}
                elif behavior == "assert_no_stats":
                    if "stats" in request:
                        sys.stdout.write("not json\\n")
                        sys.stdout.flush()
                        continue
                    response = {{
                        "schema_version": 1,
                        "request_id": request["request_id"],
                        "suggestion": "请执行命令",
                        "confidence": 0.5,
                        "model_artifact_id": "stub:mlx-8bit:v3",
                    }}
                sys.stdout.write(
                    json.dumps(response, ensure_ascii=False) + "\\n"
                )
                sys.stdout.flush()
            """
        ),
        encoding="utf-8",
    )
    return script


def _config(command: list[str], **overrides: object) -> dict:
    config: dict[str, object] = {
        "schema_version": 1,
        "name": "stub-neural",
        "command": command,
        "timeout_ms": 5000,
        "budget_ms": 800,
    }
    config.update(overrides)
    return config


def _request(**overrides: object) -> dict:
    request: dict[str, object] = {
        "request_id": "req-1",
        "composition_id": "composition-1",
        "revision": 1,
        "app_session_id": "app-1",
        "context": "前文",
        "pinyin": "qingzhixing",
        "candidates": ["请执行"],
        "allow_sentence": True,
    }
    request.update(overrides)
    return {key: value for key, value in request.items() if value is not None}


# --------------------------------------------------------------------------
# Config loading


def test_config_validation(tmp_path: Path) -> None:
    good = tmp_path / "good.json"
    good.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "name": "n",
                "command": ["x"],
                "timeout_ms": 1000,
                "budget_ms": 900,
                "min_confidence": 0.2,
                "model_type": "mlx-8bit",
            }
        ),
        encoding="utf-8",
    )
    config = load_neural_sentence_config(good)
    assert config["budget_ms"] == 900
    assert config["min_confidence"] == 0.2

    bad = tmp_path / "bad.json"
    bad.write_text("not json", encoding="utf-8")
    with pytest.raises(NeuralSentenceConfigurationError):
        load_neural_sentence_config(bad)

    for override in (
        {"schema_version": 2},
        {"name": ""},
        {"command": []},
        {"command": "x"},
        {"timeout_ms": 0},
        {"timeout_ms": True},
        {"budget_ms": 6000},
        {"min_confidence": -0.1},
        {"model_type": 3},
    ):
        payload = {
            "schema_version": 1,
            "name": "n",
            "command": ["x"],
            "timeout_ms": 1000,
        }
        payload.update(override)
        path = tmp_path / f"bad-{abs(hash(json.dumps(override)))}.json"
        path.write_text(json.dumps(payload), encoding="utf-8")
        with pytest.raises(NeuralSentenceConfigurationError):
            load_neural_sentence_config(path)


# --------------------------------------------------------------------------
# Service


def test_service_decodes_and_passes_payload_through(tmp_path: Path) -> None:
    script = _write_worker_script(tmp_path, "echo")
    service = NeuralSentenceService(
        _config([sys.executable, str(script)]), project_root=tmp_path
    )
    try:
        payload = service.decode(_request())
        assert payload is not None
        assert payload["suggestion"] == "请执行命令"
        assert payload["confidence"] == 0.5
        assert payload["model_artifact_id"] == "stub:mlx-8bit:v3"
        # reveal B-F6：部署服务不再请求/透传 worker 遥测。
        assert "stats" not in payload
        assert service.stats["delivered"] == 1
        artifacts = service.artifacts()
        assert artifacts[0]["role"] == "neural_sentence"
        assert artifacts[0]["model_artifact_id"] == "stub:mlx-8bit:v3"
    finally:
        service.close()


def test_service_abstains_on_ineligible_shapes_without_spawning(
    tmp_path: Path,
) -> None:
    script = _write_worker_script(tmp_path, "exit")
    service = NeuralSentenceService(
        _config([sys.executable, str(script)]), project_root=tmp_path
    )
    try:
        assert service.decode(_request(allow_sentence=False)) is None
        two_segments = [
            {"pinyin": "qing", "separator": "，"},
            {"pinyin": "zhixing", "separator": ""},
        ]
        assert (
            service.decode(_request(pinyin="zhixing", segments=two_segments))
            is None
        )
        assert service.decode(_request(candidates=[])) is None
        # Single-segment layouts stay eligible by design (the active
        # segment IS the composition): exactly one spawn against an
        # immediately-exiting worker, which abstains via its failure path.
        assert (
            service.decode(_request(segments=[{"pinyin": "qingzhixing"}]))
            is None
        )
        assert service.stats["worker_restarts"] == 1
        assert service.stats["abstained"] == 4
    finally:
        service.close()


def test_service_min_confidence_gate(tmp_path: Path) -> None:
    script = _write_worker_script(tmp_path, "low_confidence")
    service = NeuralSentenceService(
        _config([sys.executable, str(script)], min_confidence=0.2),
        project_root=tmp_path,
    )
    try:
        assert service.decode(_request()) is None
        assert service.stats["abstained"] == 1
    finally:
        service.close()


def test_service_opens_circuit_after_consecutive_failures(
    tmp_path: Path,
) -> None:
    script = _write_worker_script(tmp_path, "garbage")
    service = NeuralSentenceService(
        _config([sys.executable, str(script)]), project_root=tmp_path
    )
    try:
        for _ in range(3):
            assert service.decode(_request()) is None
        # Circuit open: further decodes abstain without touching the
        # worker.
        before = dict(service.stats)
        assert service.decode(_request()) is None
        assert service.stats["failures"] == before["failures"]
        assert service.stats["requests"] == before["requests"] + 1
    finally:
        service.close()


def test_service_restarts_a_crashed_worker(tmp_path: Path) -> None:
    script = _write_worker_script(tmp_path, "exit")
    # The worker exits after every response batch; the service respawns.
    service = NeuralSentenceService(
        _config([sys.executable, str(script)]), project_root=tmp_path
    )
    try:
        assert service.decode(_request()) is None  # worker exits, no reply
        assert service.stats["failures"] == 1
        # Cooldown is not yet open after a single failure; the next call
        # respawns and fails again deterministically.
        assert service.decode(_request()) is None
        assert service.stats["worker_restarts"] == 2
    finally:
        service.close()


# --------------------------------------------------------------------------
# Protocol tier


class StubNeuralService(NeuralSentenceService):
    """In-process stand-in: decode() without a subprocess."""

    def __init__(
        self,
        *,
        suggestion: str = "请执行命令",
        delay: float = 0.0,
        abstain: bool = False,
    ) -> None:
        super().__init__(
            _config([sys.executable, "-c", "pass"]),
            project_root=Path("."),
        )
        self._suggestion = suggestion
        self._delay = delay
        self._abstain = abstain
        self.seen_revisions: list[int] = []
        self.stats["model_artifact_id"] = "stub:mlx-8bit:v3"

    def decode(
        self,
        request: dict,
        *,
        deadline: float | None = None,
    ) -> dict | None:
        self.seen_revisions.append(request["revision"])
        if self._delay:
            loop_delay = self._delay
            target = monotonic() + loop_delay
            while monotonic() < target:
                pass
        if self._abstain:
            return None
        return {
            "suggestion": self._suggestion,
            "confidence": 0.5,
            "model_artifact_id": "stub:mlx-8bit:v3",
        }


class FakeEngine:
    artifact_id = "fixture-engine-v1"

    def infer(self, request: dict) -> dict:
        return {
            "decision": "ranked_candidate",
            "ranked_candidate": request["candidates"][-1],
            "sentence_suggestion": "",
            "confidence": 0.9,
        }


async def _write_json(writer, payload) -> None:
    writer.write(
        (
            json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
            + "\n"
        ).encode("utf-8")
    )
    await writer.drain()


async def _read_json(reader):
    return json.loads((await reader.readline()).decode("utf-8"))


async def _hello(reader, writer, *, late_capability: bool = True):
    capabilities = ["rerank", "sentence", "cancel"]
    if late_capability:
        capabilities.append("sentence-late")
    await _write_json(
        writer,
        {
            "schema_version": 1,
            "type": "hello",
            "client_id": "test-client",
            "capabilities": capabilities,
        },
    )
    response = await _read_json(reader)
    assert response["type"] == "hello"
    return response


def _infer_message(revision: int, request_id: str, **overrides):
    message = {
        "schema_version": 1,
        "type": "infer",
        "request_id": request_id,
        "composition_id": "composition-1",
        "revision": revision,
        "app_session_id": "app-1",
        "context_policy": "standard",
        "context": "请执行这条",
        "pinyin": "mingling",
        "candidates": ["明令", "命令"],
        "deadline_ms": 400,
        "allow_sentence": True,
        "sensitive": False,
    }
    message.update(overrides)
    return message


def test_hello_advertises_capability_and_artifacts_when_configured():
    async def scenario(runtime_root: Path):
        socket_path = runtime_root / "runtime" / "rimeai.sock"
        service = StubNeuralService()
        server = RimeAIDaemonServer(
            socket_path, FakeEngine(), neural_sentence=service
        )
        await server.start()
        try:
            reader, writer = await asyncio.open_unix_connection(socket_path)
            response = await _hello(reader, writer)
            assert "sentence-late" in response["capabilities"]
            roles = [
                artifact.get("role")
                for artifact in response["model_artifacts"]
            ]
            assert "neural_sentence" in roles
            neural_entry = next(
                artifact
                for artifact in response["model_artifacts"]
                if artifact.get("role") == "neural_sentence"
            )
            assert neural_entry["model_artifact_id"] == "stub:mlx-8bit:v3"
            writer.close()
            await writer.wait_closed()
        finally:
            await server.close()

    with tempfile.TemporaryDirectory(prefix="rai-", dir="/tmp") as directory:
        asyncio.run(scenario(Path(directory)))


def test_hello_omits_capability_without_a_configured_service():
    async def scenario(runtime_root: Path):
        socket_path = runtime_root / "runtime" / "rimeai.sock"
        server = RimeAIDaemonServer(socket_path, FakeEngine())
        await server.start()
        try:
            reader, writer = await asyncio.open_unix_connection(socket_path)
            response = await _hello(reader, writer)
            assert "sentence-late" not in response["capabilities"]
            assert not [
                artifact
                for artifact in response["model_artifacts"]
                if artifact.get("role") == "neural_sentence"
            ]
            writer.close()
            await writer.wait_closed()
        finally:
            await server.close()

    with tempfile.TemporaryDirectory(prefix="rai-", dir="/tmp") as directory:
        asyncio.run(scenario(Path(directory)))


def test_late_frame_follows_result_and_binds_to_revision():
    async def scenario(runtime_root: Path):
        socket_path = runtime_root / "runtime" / "rimeai.sock"
        service = StubNeuralService()
        server = RimeAIDaemonServer(
            socket_path, FakeEngine(), neural_sentence=service
        )
        await server.start()
        try:
            reader, writer = await asyncio.open_unix_connection(socket_path)
            await _hello(reader, writer)
            await _write_json(
                writer, _infer_message(1, "request-1")
            )
            result = await _read_json(reader)
            assert result["type"] == "result"
            assert result["status"] == "ok"
            late = await _read_json(reader)
            assert late["type"] == "sentence_late"
            assert late["status"] == "ok"
            assert late["request_id"] == "request-1"
            assert late["composition_id"] == "composition-1"
            assert late["revision"] == 1
            assert late["app_session_id"] == "app-1"
            assert late["sentence_suggestion"] == "请执行命令"
            assert late["model_artifact_id"] == "stub:mlx-8bit:v3"
            assert late["elapsed_ms"] >= 0
            writer.close()
            await writer.wait_closed()
        finally:
            await server.close()

    with tempfile.TemporaryDirectory(prefix="rai-", dir="/tmp") as directory:
        asyncio.run(scenario(Path(directory)))


def test_client_without_capability_never_receives_late_frames():
    async def scenario(runtime_root: Path):
        socket_path = runtime_root / "runtime" / "rimeai.sock"
        service = StubNeuralService()
        server = RimeAIDaemonServer(
            socket_path, FakeEngine(), neural_sentence=service
        )
        await server.start()
        try:
            reader, writer = await asyncio.open_unix_connection(socket_path)
            await _hello(reader, writer, late_capability=False)
            await _write_json(
                writer, _infer_message(1, "request-1")
            )
            result = await _read_json(reader)
            assert result["type"] == "result"
            # No late frame may follow for a client that did not opt in;
            # prove it by sending another request on the same connection
            # and observing the next frame is its result, not a late one.
            await _write_json(
                writer, _infer_message(2, "request-2")
            )
            result2 = await _read_json(reader)
            assert result2["type"] == "result"
            assert result2["request_id"] == "request-2"
            writer.close()
            await writer.wait_closed()
        finally:
            await server.close()
        assert service.seen_revisions == []

    with tempfile.TemporaryDirectory(prefix="rai-", dir="/tmp") as directory:
        asyncio.run(scenario(Path(directory)))


def test_stale_revision_late_frame_is_dropped():
    async def scenario(runtime_root: Path):
        socket_path = runtime_root / "runtime" / "rimeai.sock"
        service = StubNeuralService(delay=0.08)
        server = RimeAIDaemonServer(
            socket_path, FakeEngine(), neural_sentence=service
        )
        await server.start()
        try:
            reader, writer = await asyncio.open_unix_connection(socket_path)
            await _hello(reader, writer)
            await _write_json(
                writer, _infer_message(1, "request-1")
            )
            await asyncio.sleep(0.01)
            await _write_json(
                writer, _infer_message(2, "request-2")
            )
            result1 = await _read_json(reader)
            assert result1["request_id"] == "request-1"
            result2 = await _read_json(reader)
            assert result2["request_id"] == "request-2"
            late = await _read_json(reader)
            # The revision-1 neural decode outlived its revision: only the
            # revision-2 frame may surface.
            assert late["type"] == "sentence_late"
            assert late["revision"] == 2
            writer.close()
            await writer.wait_closed()
        finally:
            await server.close()
        assert service.seen_revisions == [1, 2]

    with tempfile.TemporaryDirectory(prefix="rai-", dir="/tmp") as directory:
        asyncio.run(scenario(Path(directory)))


def test_allow_sentence_false_disables_the_tier():
    async def scenario(runtime_root: Path):
        socket_path = runtime_root / "runtime" / "rimeai.sock"
        service = StubNeuralService()
        server = RimeAIDaemonServer(
            socket_path, FakeEngine(), neural_sentence=service
        )
        await server.start()
        try:
            reader, writer = await asyncio.open_unix_connection(socket_path)
            await _hello(reader, writer)
            await _write_json(
                writer,
                _infer_message(
                    1, "request-1", allow_sentence=False
                ),
            )
            result = await _read_json(reader)
            assert result["type"] == "result"
            await _write_json(
                writer, _infer_message(2, "request-2")
            )
            result2 = await _read_json(reader)
            assert result2["type"] == "result"
            writer.close()
            await writer.wait_closed()
        finally:
            await server.close()
        assert service.seen_revisions == [2]

    with tempfile.TemporaryDirectory(prefix="rai-", dir="/tmp") as directory:
        asyncio.run(scenario(Path(directory)))


def test_abstaining_service_sends_no_late_frame():
    async def scenario(runtime_root: Path):
        socket_path = runtime_root / "runtime" / "rimeai.sock"
        service = StubNeuralService(abstain=True)
        server = RimeAIDaemonServer(
            socket_path, FakeEngine(), neural_sentence=service
        )
        await server.start()
        try:
            reader, writer = await asyncio.open_unix_connection(socket_path)
            await _hello(reader, writer)
            await _write_json(
                writer, _infer_message(1, "request-1")
            )
            result = await _read_json(reader)
            assert result["type"] == "result"
            await _write_json(
                writer, _infer_message(2, "request-2")
            )
            result2 = await _read_json(reader)
            assert result2["type"] == "result"
            writer.close()
            await writer.wait_closed()
        finally:
            await server.close()

    with tempfile.TemporaryDirectory(prefix="rai-", dir="/tmp") as directory:
        asyncio.run(scenario(Path(directory)))


# --------------------------------------------------------------------------
# reveal 修复轮：deadline 下传 / 有界行读 / 关闭唤醒 / 冷启动豁免 /
# 熔断上限 / server 侧 min_confidence / 不请求遥测


def test_decode_deadline_bounds_blocked_read(tmp_path: Path) -> None:
    # reveal B-F5/C-F2：交付预算下传 worker 读——阻塞的 decode 在
    # deadline 处释放执行器槽，而不是占满 timeout_ms。（首次冷启动
    # 读有独立豁免窗口，见 cold_start 测试；这里先热身再测稳态。）
    script = _write_worker_script(tmp_path, "echo_then_silent")
    service = NeuralSentenceService(
        _config([sys.executable, str(script)], timeout_ms=5000),
        project_root=tmp_path,
    )
    try:
        warmup = service.decode(_request())
        assert warmup is not None
        started = monotonic()
        payload = service.decode(
            _request(request_id="req-2"),
            deadline=monotonic() + 0.15,
        )
        elapsed = monotonic() - started
        assert payload is None
        assert elapsed < 2.0
        assert service.stats["failures"] == 1
    finally:
        service.close()


def test_overlong_response_line_is_rejected(tmp_path: Path) -> None:
    # reveal A-F3/B-F6：无换行的超长响应行按协议违规处理，不再
    # 无界缓冲。
    script = _write_worker_script(tmp_path, "overlong")
    service = NeuralSentenceService(
        _config([sys.executable, str(script)], timeout_ms=5000),
        project_root=tmp_path,
    )
    try:
        payload = service.decode(
            _request(), deadline=monotonic() + 5.0
        )
        assert payload is None
        assert service.stats["failures"] == 1
    finally:
        service.close()


def test_close_wakes_blocked_reader_without_counting_failure(
    tmp_path: Path,
) -> None:
    # reveal B-F4/C-F3：close() 先 terminate（EOF 唤醒阻塞读）再关
    # 管道；被打断的 decode 记 abstain 而非 failure，worker 被收割。
    import threading

    script = _write_worker_script(tmp_path, "silent")
    service = NeuralSentenceService(
        _config([sys.executable, str(script)], timeout_ms=5000),
        project_root=tmp_path,
    )
    outcome: dict[str, object] = {}

    def blocked_decode() -> None:
        outcome["payload"] = service.decode(_request())

    thread = threading.Thread(target=blocked_decode)
    thread.start()
    import time as _time

    _time.sleep(0.4)
    started = monotonic()
    service.close()
    thread.join(timeout=5.0)
    assert not thread.is_alive()
    assert monotonic() - started < 4.0
    assert outcome["payload"] is None
    # 打断不是 worker 失败：不触发熔断计数。
    assert service.stats["failures"] == 0
    assert service.stats["abstained"] == 1


def test_cold_start_grace_prevents_mid_load_kill(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    # reveal C-F6：冷启动窗口内首次读不按 timeout_ms 杀加载中的
    # worker（交付预算不受影响）。
    from rimeai_daemon import neural_sentence

    monkeypatch.setattr(
        neural_sentence, "COLD_START_GRACE_SECONDS", 5.0
    )
    script = _write_worker_script(tmp_path, "slow_first")
    service = NeuralSentenceService(
        _config([sys.executable, str(script)], timeout_ms=100),
        project_root=tmp_path,
    )
    try:
        payload = service.decode(
            _request(), deadline=monotonic() + 0.1
        )
        assert payload is not None
        assert service.stats["delivered"] == 1
        assert service.stats["failures"] == 0
    finally:
        service.close()


def test_cooldown_cycles_permanently_disable_the_arm(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    # reveal C-F6：连续多轮熔断冷却后永久弃权，不再 spawn→kill
    # 振荡。
    import time as _time

    from rimeai_daemon import neural_sentence

    monkeypatch.setattr(neural_sentence, "COOLDOWN_SECONDS", 0.01)
    script = _write_worker_script(tmp_path, "exit")
    service = NeuralSentenceService(
        _config([sys.executable, str(script)], timeout_ms=1000),
        project_root=tmp_path,
    )
    try:
        for _ in range(40):
            service.decode(
                _request(request_id=f"req-{monotonic()}"),
                deadline=monotonic() + 0.5,
            )
            if service._disabled:
                break
            _time.sleep(0.02)
        assert service._disabled
        restarts_before = service.stats["worker_restarts"]
        assert service.decode(_request()) is None
        assert service.stats["worker_restarts"] == restarts_before
    finally:
        service.close()


def test_worker_request_omits_stats_telemetry(tmp_path: Path) -> None:
    # reveal B-F6：部署服务不请求 worker 遥测（评测侧才用 stats）；
    # worker 收到带 stats 的请求会回垃圾行让本测试失败。
    script = _write_worker_script(tmp_path, "assert_no_stats")
    service = NeuralSentenceService(
        _config([sys.executable, str(script)]),
        project_root=tmp_path,
    )
    try:
        payload = service.decode(_request())
        assert payload is not None
        assert service.stats["delivered"] == 1
    finally:
        service.close()


def test_server_gate_drops_frames_below_min_confidence():
    # reveal B-F3：server 侧发帧门补齐 min_confidence（不再只在
    # service.decode 层强制）。
    async def scenario(runtime_root: Path):
        socket_path = runtime_root / "runtime" / "rimeai.sock"
        service = StubNeuralService()
        service.min_confidence = 0.8  # stub 固定回 0.5 → 必须被丢弃
        server = RimeAIDaemonServer(
            socket_path, FakeEngine(), neural_sentence=service
        )
        await server.start()
        try:
            reader, writer = await asyncio.open_unix_connection(
                socket_path
            )
            await _hello(reader, writer)
            await _write_json(
                writer, _infer_message(1, "request-1")
            )
            result = await _read_json(reader)
            assert result["type"] == "result"
            try:
                late = await asyncio.wait_for(
                    reader.readline(), timeout=1.0
                )
                frame = json.loads(late.decode("utf-8"))
                assert frame["type"] != "sentence_late", (
                    "below-min-confidence frame must be dropped"
                )
            except asyncio.TimeoutError:
                pass  # 预期：无迟到帧
            writer.close()
            await writer.wait_closed()
        finally:
            await server.close()

    with tempfile.TemporaryDirectory(prefix="rai-", dir="/tmp") as dir_:
        asyncio.run(scenario(Path(dir_)))
