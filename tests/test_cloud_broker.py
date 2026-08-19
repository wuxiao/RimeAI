import asyncio
import json
from pathlib import Path
import stat
import tempfile
import threading
import time

import pytest

from rimeai_cloud_broker.qwen import QwenBrokerError, QwenCandidateRanker
from rimeai_cloud_broker.server import (
    CloudBrokerServer,
    validate_decision,
    validate_request,
)


def _request() -> dict:
    return {
        "schema_version": 1,
        "type": "inference",
        "api_key": "secret",
        "request_id": "request-1",
        "composition_id": "10000000-0000-0000-0000-000000000001",
        "revision": 2,
        "bundle_id": "com.example.Editor",
        "app_session_id": "com.example.Editor#session",
        "client_session_id": "client-session",
        "model_id": "glm-5.3",
        "deadline_ms": 800,
        "pinyin": "niihao",
        "candidates": [
            {
                "id": "candidate-0",
                "text": "你一号",
                "source": "rime_exact",
                "rime_index": 0,
                "consumed_start": 0,
                "consumed_length": 6,
                "aligned_pinyin": "niihao",
                "edit_cost": 0,
            },
            {
                "id": "candidate-1",
                "text": "你好",
                "source": "rime_fuzzy",
                "rime_index": 0,
                "consumed_start": 0,
                "consumed_length": 6,
                "aligned_pinyin": "nihao",
                "edit_cost": 1,
            },
        ],
        "candidate_pool_hash": "pool-hash",
        "recent_context": "请向客户问好",
        "history_snippets": [],
        "history_generation": 4,
    }


class StubQwenRanker(QwenCandidateRanker):
    def __init__(self, response: dict):
        super().__init__(api_key_loader=lambda: "secret")
        self.response = response
        self.payload = None

    def _post_json(self, path, payload, *, timeout, api_key=None):
        self.payload = payload
        return {
            "choices": [
                {"message": {"content": json.dumps(self.response)}}
            ]
        }


def test_qwen_ranker_can_only_choose_a_pool_candidate():
    ranker = StubQwenRanker(
        {
            "decision": "choose",
            "candidate_id": "candidate-1",
            "confidence": 0.99,
            "reason": "typo_match",
        }
    )

    cloud_request = validate_request(_request())
    result = ranker.rank(cloud_request)

    assert result == {
        "decision": "choose",
        "candidate_id": "candidate-1",
        "confidence": 0.99,
        "reason": "typo_match",
    }
    serialized = json.dumps(ranker.payload, ensure_ascii=False)
    assert "candidate-1" in serialized
    assert "secret" not in serialized
    assert "correction_text" not in serialized
    assert "api_key" not in cloud_request


def test_cloud_request_requires_a_bounded_ephemeral_credential():
    missing = _request()
    missing.pop("api_key")
    with pytest.raises(ValueError, match="credential"):
        validate_request(missing)

    oversized = _request()
    oversized["api_key"] = "x" * 513
    with pytest.raises(ValueError, match="credential"):
        validate_request(oversized)


def test_production_ranker_never_falls_back_to_an_interactive_keychain_tool():
    ranker = QwenCandidateRanker()
    with pytest.raises(QwenBrokerError, match="credential is unavailable"):
        ranker.embed_texts(["不应触发钥匙串授权界面"])


def test_low_confidence_fuzzy_correction_abstains():
    ranker = StubQwenRanker(
        {
            "decision": "choose",
            "candidate_id": "candidate-1",
            "confidence": 0.97,
            "reason": "typo_match",
        }
    )

    assert ranker.rank(validate_request(_request()))["decision"] == "abstain"


def test_server_rejects_low_confidence_fuzzy_choice_from_any_ranker():
    with pytest.raises(ValueError, match="confidence threshold"):
        validate_decision(
            {
                "decision": "choose",
                "candidate_id": "candidate-1",
                "confidence": 0.97,
                "reason": "typo_match",
            },
            validate_request(_request()),
        )


def test_slow_keychain_lookup_cannot_start_a_late_network_request():
    def slow_key_loader():
        time.sleep(0.79)
        return "secret"

    ranker = StubQwenRanker(
        {
            "decision": "keep",
            "candidate_id": None,
            "confidence": None,
            "reason": "rime_rank",
        }
    )
    ranker._api_key_loader = slow_key_loader

    cloud_request = validate_request(_request())
    cloud_request.pop("api_key")
    with pytest.raises(QwenBrokerError, match="deadline expired"):
        ranker.rank(cloud_request)
    assert ranker.payload is None


def test_cloud_socket_is_private_and_echoes_all_identity_fields():
    class FakeRanker:
        def rank(self, request):
            return {
                "decision": "choose",
                "candidate_id": "candidate-1",
                "confidence": 0.99,
                "reason": "typo_match",
            }

    async def scenario():
        with tempfile.TemporaryDirectory(dir="/tmp") as root:
            socket_path = Path(root) / "runtime" / "rimeai-cloud.sock"
            server = CloudBrokerServer(socket_path, FakeRanker())
            try:
                await server.start()
            except PermissionError:
                pytest.skip("sandbox forbids Unix socket binding")
            try:
                assert stat.S_IMODE(socket_path.stat().st_mode) == 0o600
                reader, writer = await asyncio.open_unix_connection(socket_path)
                writer.write(
                    (
                        json.dumps(
                            {
                                "schema_version": 1,
                                "type": "hello",
                                "client_id": "test-client",
                            }
                        )
                        + "\n"
                    ).encode()
                )
                await writer.drain()
                hello = json.loads(await reader.readline())
                assert hello["status"] == "ok"
                writer.write((json.dumps(_request()) + "\n").encode())
                await writer.drain()
                response = json.loads(await reader.readline())
                assert response["candidate_id"] == "candidate-1"
                assert response["candidate_pool_hash"] == "pool-hash"
                assert response["history_generation"] == 4
                assert response["client_session_id"] == "client-session"
                writer.close()
                await writer.wait_closed()
            finally:
                await server.close()

    asyncio.run(scenario())


def test_interactive_qwen_calls_are_serialized_after_cancellation():
    class SerialProbeRanker:
        def __init__(self):
            self.lock = threading.Lock()
            self.active = 0
            self.maximum_active = 0

        def rank(self, request):
            with self.lock:
                self.active += 1
                self.maximum_active = max(self.maximum_active, self.active)
            try:
                time.sleep(0.05)
                return {
                    "decision": "choose",
                    "candidate_id": "candidate-1",
                    "confidence": 0.99,
                    "reason": "typo_match",
                }
            finally:
                with self.lock:
                    self.active -= 1

    class MemoryWriter:
        def __init__(self):
            self.frames = []

        def write(self, data):
            self.frames.append(data)

        async def drain(self):
            return None

    async def scenario():
        ranker = SerialProbeRanker()
        server = CloudBrokerServer(Path("/tmp/unused-cloud.sock"), ranker)
        writer = MemoryWriter()
        lock = asyncio.Lock()
        first = _request()
        second = {**_request(), "request_id": "request-2", "revision": 3}
        first_key = (first["app_session_id"], first["composition_id"])
        second_key = (second["app_session_id"], second["composition_id"])
        latest = {first_key: first["revision"]}
        first_task = asyncio.create_task(
            server._run(first, first_key, latest, writer, lock)
        )
        await asyncio.sleep(0.01)
        first_task.cancel()
        latest[second_key] = second["revision"]
        second_task = asyncio.create_task(
            server._run(second, second_key, latest, writer, lock)
        )
        await asyncio.gather(first_task, return_exceptions=True)
        await second_task
        await server.close()
        assert ranker.maximum_active == 1
        assert len(writer.frames) == 1

    asyncio.run(scenario())
