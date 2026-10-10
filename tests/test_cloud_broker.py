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
            server._run(first, first_key, latest, writer, lock, set())
        )
        await asyncio.sleep(0.01)
        first_task.cancel()
        latest[second_key] = second["revision"]
        second_task = asyncio.create_task(
            server._run(second, second_key, latest, writer, lock, set())
        )
        await asyncio.gather(first_task, return_exceptions=True)
        await second_task
        await server.close()
        assert ranker.maximum_active == 1
        assert len(writer.frames) == 1

    asyncio.run(scenario())


# --- text generation (LLM-composed sentences) ---


def _guard() -> "PinyinGuard":
    from rimeai_eval.pinyin_guard import PinyinGuard

    return PinyinGuard(
        {
            "测": frozenset({"ce"}),
            "试": frozenset({"shi"}),
            "策": frozenset({"ce"}),
            "士": frozenset({"shi"}),
            "你": frozenset({"ni"}),
            "好": frozenset({"hao"}),
        }
    )


class StubGenerateRanker(QwenCandidateRanker):
    def __init__(self, response: dict, guard):
        super().__init__(api_key_loader=lambda: "secret", pinyin_guard=guard)
        self.response = response
        self.payload = None

    def _post_json(self, path, payload, *, timeout, api_key=None):
        self.payload = payload
        return {
            "choices": [{"message": {"content": json.dumps(self.response)}}]
        }


def _generate_request() -> dict:
    request = _request()
    request["pinyin"] = "ceshinihao"
    request["candidates"] = [
        {
            "id": "candidate-0",
            "text": "策士你好",
            "source": "rime_exact",
            "rime_index": 0,
            "consumed_start": 0,
            "consumed_length": 10,
            "aligned_pinyin": "ceshinihao",
            "edit_cost": 0,
        },
        {
            "id": "candidate-1",
            "text": "测试",
            "source": "rime_exact",
            "rime_index": 1,
            "consumed_start": 0,
            "consumed_length": 10,
            "aligned_pinyin": "ceshinihao",
            "edit_cost": 0,
        },
    ]
    return request


def test_generated_sentence_passes_dictionary_alignment():
    ranker = StubGenerateRanker(
        {
            "decision": "generate",
            "candidate_id": None,
            "text": "测试你好",
            "confidence": 0.9,
            "reason": "context_match",
        },
        _guard(),
    )

    result = ranker.rank(validate_request(_generate_request()))

    assert result == {
        "decision": "generate",
        "candidate_id": None,
        "confidence": 0.9,
        "reason": "context_match",
        "text": "测试你好",
    }


def test_misaligned_generated_sentence_abstains():
    ranker = StubGenerateRanker(
        {
            "decision": "generate",
            "candidate_id": None,
            "text": "测试世界",
            "confidence": 0.99,
            "reason": "context_match",
        },
        _guard(),
    )

    assert ranker.rank(validate_request(_generate_request()))[
        "decision"
    ] == "abstain"


def test_generated_sentence_with_punctuation_or_latin_abstains():
    ranker = StubGenerateRanker(
        {
            "decision": "generate",
            "candidate_id": None,
            "text": "测试，hello",
            "confidence": 0.99,
            "reason": "context_match",
        },
        _guard(),
    )

    assert ranker.rank(validate_request(_generate_request()))[
        "decision"
    ] == "abstain"


def test_generated_sentence_without_dictionary_guard_abstains():
    ranker = StubGenerateRanker(
        {
            "decision": "generate",
            "candidate_id": None,
            "text": "测试你好",
            "confidence": 0.99,
            "reason": "context_match",
        },
        None,
    )
    assert ranker.generation_enabled is False

    assert ranker.rank(validate_request(_generate_request()))[
        "decision"
    ] == "abstain"


def test_low_confidence_generation_abstains():
    ranker = StubGenerateRanker(
        {
            "decision": "generate",
            "candidate_id": None,
            "text": "测试你好",
            "confidence": 0.59,
            "reason": "context_match",
        },
        _guard(),
    )

    assert ranker.rank(validate_request(_generate_request()))[
        "decision"
    ] == "abstain"


def test_generation_matching_the_top_pool_candidate_passes_through():
    # The client owns dedup and surfaces agreement visibly; converting to
    # keep at the broker would silence the LLM's participation.
    ranker = StubGenerateRanker(
        {
            "decision": "generate",
            "candidate_id": None,
            "text": "策士你好",
            "confidence": 0.99,
            "reason": "context_match",
        },
        _guard(),
    )

    result = ranker.rank(validate_request(_generate_request()))

    assert result["decision"] == "generate"
    assert result["confidence"] == 0.99
    assert result["text"] == "策士你好"


def test_generation_without_text_is_rejected():
    ranker = StubGenerateRanker(
        {
            "decision": "generate",
            "candidate_id": None,
            "text": None,
            "confidence": 0.99,
            "reason": "context_match",
        },
        _guard(),
    )

    with pytest.raises(QwenBrokerError, match="invalid"):
        ranker.rank(validate_request(_generate_request()))


def test_server_rejects_structurally_invalid_generation():
    request = validate_request(_generate_request())
    with pytest.raises(ValueError, match="generated sentence"):
        validate_decision(
            {
                "decision": "generate",
                "candidate_id": None,
                "text": "测试你好",
                "confidence": 0.55,
                "reason": "context_match",
            },
            request,
        )
    with pytest.raises(ValueError, match="generated sentence"):
        validate_decision(
            {
                "decision": "generate",
                "candidate_id": "candidate-1",
                "text": "测试你好",
                "confidence": 0.9,
                "reason": "context_match",
            },
            request,
        )


def test_server_rejects_text_in_choose_and_keep_decisions():
    request = validate_request(_generate_request())
    with pytest.raises(ValueError, match="candidate pool"):
        validate_decision(
            {
                "decision": "choose",
                "candidate_id": "candidate-1",
                "text": "测试你好",
                "confidence": 0.99,
                "reason": "context_match",
            },
            request,
        )
    with pytest.raises(ValueError, match="text"):
        validate_decision(
            {
                "decision": "keep",
                "candidate_id": None,
                "text": "测试你好",
                "confidence": None,
                "reason": "rime_rank",
            },
            request,
        )


def test_prompt_requests_aligned_han_only_generation():
    ranker = StubGenerateRanker(
        {
            "decision": "keep",
            "candidate_id": None,
            "confidence": None,
            "reason": "rime_rank",
        },
        _guard(),
    )

    ranker.rank(validate_request(_generate_request()))

    assert ranker.payload["max_tokens"] == 256
    user_content = ranker.payload["messages"][1]["content"]
    assert "generate" in user_content
    assert "read exactly as the typed pinyin" in user_content
    serialized = json.dumps(ranker.payload, ensure_ascii=False)
    assert "secret" not in serialized


def test_client_without_text_generation_capability_gets_keep():
    class GenerateRanker:
        def rank(self, request):
            return {
                "decision": "generate",
                "candidate_id": None,
                "confidence": 0.9,
                "reason": "context_match",
                "text": "测试你好",
            }

    class MemoryWriter:
        def __init__(self):
            self.frames = []

        def write(self, payload):
            self.frames.append(payload)

        async def drain(self):
            return True

        def close(self):
            pass

    async def scenario():
        server = CloudBrokerServer(
            Path("/tmp/unused.sock"),
            GenerateRanker(),
            text_generation_enabled=True,
        )
        writer = MemoryWriter()
        lock = asyncio.Lock()
        request = validate_request(_generate_request())
        key = (request["app_session_id"], request["composition_id"])
        latest = {key: request["revision"]}
        await server._run(request, key, latest, writer, lock, set())
        frame = json.loads(writer.frames[0].decode())
        assert frame["decision"] == "keep"
        assert "generated_text" not in frame

        writer.frames.clear()
        await server._run(
            request, key, latest, writer, lock, {"text-generation"}
        )
        frame = json.loads(writer.frames[0].decode())
        assert frame["decision"] == "generate"
        assert frame["generated_text"] == "测试你好"
        assert frame["generated_pinyin"] == "ceshinihao"

    asyncio.run(scenario())


def test_broker_main_degrades_when_dictionary_is_unavailable(tmp_path):
    from rimeai_cloud_broker.__main__ import _load_pinyin_guard

    assert _load_pinyin_guard(None) is None
    assert _load_pinyin_guard(tmp_path / "missing.dict.yaml") is None
