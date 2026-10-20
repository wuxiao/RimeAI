import asyncio
import json
import stat
import tempfile
import threading
import time
import typing
from pathlib import Path

import pytest

from rimeai_cloud_broker import cloud_model as cloud_model_module
from rimeai_cloud_broker.cloud_model import (
    CloudBrokerError,
    CloudModelClient,
    continuation_text_allows,
)
from rimeai_cloud_broker.server import (
    CloudBrokerServer,
    validate_continuation_request,
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
        "model_id": "glm-5.3-flash",
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


class StubCloudModelClient(CloudModelClient):
    def __init__(self, response: dict):
        super().__init__(api_key_loader=lambda: "secret")
        self.response = response
        self._payload: dict | None = None

    @property
    def payload(self) -> dict:
        """The last captured request payload; fails loudly when the stub
        never saw a request instead of surfacing as None-subscript."""
        assert self._payload is not None, "stub received no request"
        return self._payload

    def captured_payload(self) -> dict | None:
        """Non-raising view for tests asserting nothing was captured."""
        return self._payload

    # Emits JSON content: the continuation path parses JSON, and the
    # inference path's lenient unwrap reads {"text": ...} answers, so
    # one stub serves both contracts.
    def _post_json(self, path, payload, *, timeout, api_key=None):
        self._payload = payload
        return {
            "choices": [
                {
                    "message": {
                        "content": json.dumps(
                            self.response, ensure_ascii=False
                        )
                    },
                    "finish_reason": "stop",
                }
            ]
        }


def test_lenient_unwrap_still_reads_a_model_that_answers_json():
    # 纯文本输出合同（2026-10-12）：prompt 只要求直接输出句子。若模型
    # 无视指令仍回答 {"text": ...}，宽松解包取出内层 text，而不是把
    # JSON 字面量当成句子上屏；候选池不进 prompt，凭据也不进 prompt。
    class JsonAnsweringStub(StubCloudModelClient):
        def _post_json(self, path, payload, *, timeout, api_key=None):
            self._payload = payload
            return {
                "choices": [
                    {
                        "message": {"content": '{"text":"测试你好"}'},
                        "finish_reason": "stop",
                    }
                ]
            }

    ranker = JsonAnsweringStub({"text": "测试你好"})

    cloud_request = validate_request(_request())
    result = ranker.rank(cloud_request)

    assert result == {
        "decision": "generate",
        "candidate_id": None,
        "confidence": 1.0,
        "reason": "typo_match",
        "text": "测试你好",
    }
    serialized = json.dumps(ranker.payload, ensure_ascii=False)
    assert "candidates" not in serialized
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


def test_candidates_and_pool_hash_are_optional_and_ignored():
    # 候选池已从生成契约移除（2026-10-12）：candidates 与
    # candidate_pool_hash 接受但忽略，未重建的客户端照常工作；pool_hash
    # 在场时仍按 ≤128 字节的有界字符串校验。
    bare = _request()
    del bare["candidates"]
    del bare["candidate_pool_hash"]
    assert "candidate_pool_hash" not in validate_request(bare)

    malformed = _request()
    malformed["candidates"] = [{"id": "candidate-0"}]
    validate_request(malformed)  # 候选形状不再校验

    oversized = _request()
    oversized["candidate_pool_hash"] = "x" * 129
    with pytest.raises(ValueError, match="pool hash"):
        validate_request(oversized)


def test_production_ranker_never_falls_back_to_an_interactive_keychain_tool():
    ranker = CloudModelClient()
    with pytest.raises(CloudBrokerError, match="credential is unavailable"):
        ranker.embed_texts(["不应触发钥匙串授权界面"])


class _CountingRanker(CloudModelClient):
    def __init__(self, response: dict):
        super().__init__(api_key_loader=lambda: "secret")
        self.response = response
        self.calls = 0

    def _post_json(self, path, payload, *, timeout, api_key=None):
        self.calls += 1
        return {
            "choices": [
                {
                    "message": {"content": self.response["text"] or ""},
                    "finish_reason": "stop",
                }
            ]
        }


def test_generate_prompt_is_a_single_user_exchange():
    # 单轮消息契约（产品决策 2026-10-12）：messages 只有 system（不变
    # 契约，可复用 prefill 缓存）+ 一条 user（当次输入：拼音/分段 +
    # recent_context）。few-shot 示例对、history_snippets、profile_hints
    # 都不进 prompt——上下文只需让模型知道用户正在输入什么。
    ranker_with_payload = StubGenerateRanker({"text": "测试你好"})
    ranker_with_payload.rank(validate_request(_generate_request()))
    payload = ranker_with_payload.payload
    assert [message["role"] for message in payload["messages"]] == [
        "system",
        "user",
    ]
    prompt = json.loads(payload["messages"][-1]["content"])
    assert set(prompt) == {"pinyin", "recent_context"}
    assert "syllables" not in prompt
    # 反回声规则（输出严禁抄 recent_context 的词句）与 128 字符上限
    # 保留在 system 消息里；旧档位的"输出字数等于音节数"等对齐锚定
    # 规则已随档位移除（2026-10-13）。
    system_content = payload["messages"][0]["content"]
    assert "严禁把其中的词句抄进生成结果" in system_content
    assert "不超过 128 个字符" in system_content
    assert "音节数" not in system_content
    # OpenAI /chat/completions 请求结构：thinking disabled 防止 GLM 5.3
    # 把整个 max_tokens 预算烧在推理上（实测 2026-10-12 官方直连端点
    # 不认 reasoning_effort，只认 thinking.type=disabled）。
    assert payload["temperature"] == 0
    assert payload["max_tokens"] == 256
    assert payload["thinking"] == {"type": "disabled"}
    assert "think" not in payload
    assert "format" not in payload
    assert "options" not in payload
    assert "reasoning_effort" not in payload
    assert "response_format" not in payload


def test_pool_independent_decisions_are_cached_and_revalidated():
    ranker = _CountingRanker({"text": "测试你好"})

    first = ranker.rank(validate_request(_generate_request()))
    second = ranker.rank(validate_request(_generate_request()))

    assert ranker.calls == 1
    assert second == first


def test_prompt_context_is_tail_truncated_and_han_gated():
    # 协议允许 recent_context 长达 600 字，但离光标很远的文本对当前句
    # 没有帮助，只会喂大 prefill 并给 0.8b 提供回抄素材：prompt 只携带
    # 光标前最近 120 字；纯英文（无汉字）的语境不下发。
    long_context = "远" * 400 + "光标前的最近一句"
    request = _generate_request()
    request["recent_context"] = long_context
    ranker = StubGenerateRanker({"text": "测试你好"})
    ranker.rank(validate_request(request))
    prompt = json.loads(ranker.payload["messages"][-1]["content"])
    assert prompt["recent_context"] == long_context[-120:]
    assert len(prompt["recent_context"]) == 120

    latin_request = _generate_request()
    latin_request["recent_context"] = "hello world, no han here"
    ranker2 = StubGenerateRanker({"text": "测试你好"})
    ranker2.rank(validate_request(latin_request))
    prompt2 = json.loads(ranker2.payload["messages"][-1]["content"])
    assert prompt2["recent_context"] == ""


def test_length_truncated_runaway_output_abstains_instead_of_erroring():
    # 推理失控或回抄上下文跑到 max_tokens 截断（finish_reason=length），
    # content 是残缺 JSON。这是"没有可用组句"，不是服务错误：本地合成
    # abstain，不消耗客户端的云错误预算。
    class TruncatedStub(StubGenerateRanker):
        def _post_json(self, path, payload, *, timeout, api_key=None):
            self._payload = payload
            return {
                "choices": [
                    {
                        "message": {"content": '{"text":"情时就有些人说'},
                        "finish_reason": "length",
                    }
                ]
            }

    ranker = TruncatedStub({"text": None})
    assert ranker.rank(validate_request(_generate_request())) == {
        "decision": "abstain",
        "candidate_id": None,
        "confidence": None,
        "reason": "uncertain",
    }


def test_decision_cache_distinguishes_context():
    # 上下文进入 prompt 后，同一拼音在不同语境下的组句可能不同：
    # 缓存键必须包含 recent_context，否则旧语境的决策会污染新语境。
    ranker = _CountingRanker({"text": "测试你好"})

    first_request = _generate_request()
    ranker.rank(validate_request(first_request))
    second_request = _generate_request()
    second_request["recent_context"] = "完全不同的语境"
    ranker.rank(validate_request(second_request))

    assert ranker.calls == 2


def test_every_dict_decision_is_cached():
    # 纯文本合同下模型输出就是一个句子：空文本（拒答）同样缓存，
    # 命中后本地重新合成为 abstain，不再有 choose 排除。
    ranker = _CountingRanker({"text": None})

    assert ranker.rank(validate_request(_request()))["decision"] == "abstain"

    ranker.rank(validate_request(_request()))

    assert ranker.calls == 1


def test_brace_content_that_fails_to_parse_abstains():
    # 宽松解包只认 {"text": ...} 契约：以花括号包裹却解析失败（或解析
    # 出别的结构）的内容是模型弄脏了输出——按弃权处理，绝不把 JSON
    # 字面量当句子回给客户端。
    garbage = StubGenerateRanker({"text": '{"text": "测试",}'})
    decision = garbage.rank(validate_request(_generate_request()))
    assert decision["decision"] == "abstain"

    non_contract = StubGenerateRanker({"text": '{"answer": 42}'})
    decision = non_contract.rank(validate_request(_generate_request()))
    assert decision["decision"] == "abstain"


def test_generate_prompt_carries_context_and_no_candidates():
    # 生成路径的产品契约：模型直接根据拼音与上下文推导中文，候选池不进
    # prompt（决策校验仍在 broker 侧用完整池）。请求携带的
    # history_snippets 只用于本地检索索引，不进 prompt。
    request = _generate_request()
    request["history_snippets"] = [
        {
            "id": "snippet-0",
            "text": "上次聊过测试的事",
            "bundle_id": "com.example.Editor",
            "committed_at_ms": 0,
            "score": 0.9,
        }
    ]
    ranker = StubGenerateRanker({"text": "测试你好"})

    ranker.rank(validate_request(request))

    prompt = json.loads(ranker.payload["messages"][-1]["content"])
    assert "candidates" not in prompt
    assert "task" not in prompt
    assert prompt["recent_context"] == "请向客户问好"
    assert "history_snippets" not in prompt


def test_server_rejects_choose_decisions_entirely():
    # choose 已从协议删除（2026-10-12 产品决策）：无论置信度与候选形状
    # 如何一律拒绝，也不再有按候选来源区分的置信度门槛——只剩
    # generate/abstain 两种决策。
    with pytest.raises(ValueError, match="generated sentence"):
        validate_decision(
            {
                "decision": "choose",
                "candidate_id": "candidate-1",
                "confidence": 0.99,
                "reason": "typo_match",
            },
            validate_request(_request()),
        )


def test_slow_keychain_lookup_cannot_start_a_late_network_request():
    def slow_key_loader():
        time.sleep(0.79)
        return "secret"

    ranker = StubCloudModelClient({"text": None})
    ranker._api_key_loader = slow_key_loader

    cloud_request = validate_request(_request())
    cloud_request.pop("api_key")
    with pytest.raises(CloudBrokerError, match="deadline expired"):
        ranker.rank(cloud_request)
    assert ranker.captured_payload() is None


def test_cloud_socket_is_private_and_echoes_all_identity_fields():
    class FakeRanker:
        def rank(self, cloud_request):
            del cloud_request
            return {
                "decision": "generate",
                "candidate_id": None,
                "confidence": 1.0,
                "reason": "typo_match",
                "text": "测试你好",
            }

        def rank_continuation(self, cloud_request):
            del cloud_request
            return {"decision": "abstain", "reason": "capability_absent"}

        def embed_texts(self, texts):
            return [[] for _ in texts]

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
                                "capabilities": ["text-generation"],
                            }
                        )
                        + "\n"
                    ).encode()
                )
                await writer.drain()
                hello = json.loads(await reader.readline())
                assert hello["status"] == "ok"
                # 生成契约是唯一推理路径：broker 恒定通告两种生成能力。
                assert "text-generation" in hello["capabilities"]
                assert "continuation-generation" in hello["capabilities"]
                writer.write((json.dumps(_request()) + "\n").encode())
                await writer.drain()
                response = json.loads(await reader.readline())
                assert response["decision"] == "generate"
                assert response["generated_text"] == "测试你好"
                assert response["candidate_pool_hash"] == "pool-hash"
                assert response["history_generation"] == 4
                assert response["client_session_id"] == "client-session"
                writer.close()
                await writer.wait_closed()
            finally:
                await server.close()

    asyncio.run(scenario())


def test_interactive_cloud_calls_are_serialized_after_cancellation():
    class SerialProbeRanker:
        def __init__(self):
            self.lock = threading.Lock()
            self.active = 0
            self.maximum_active = 0

        def rank(self, cloud_request):
            del cloud_request
            with self.lock:
                self.active += 1
                self.maximum_active = max(self.maximum_active, self.active)
            try:
                time.sleep(0.05)
                return {
                    "decision": "generate",
                    "candidate_id": None,
                    "confidence": 1.0,
                    "reason": "typo_match",
                    "text": "测试你好",
                }
            finally:
                with self.lock:
                    self.active -= 1

        def rank_continuation(self, cloud_request):
            del cloud_request
            return {"decision": "abstain", "reason": "capability_absent"}

        def embed_texts(self, texts):
            return [[] for _ in texts]

    class MemoryWriter:
        def __init__(self):
            self.frames = []

        def write(self, data):
            self.frames.append(data)

        async def drain(self):
            return None

    async def scenario():
        ranker = SerialProbeRanker()
        server = CloudBrokerServer(
            Path(tempfile.gettempdir()) / "unused-cloud.sock",
            ranker,
        )
        writer = MemoryWriter()
        stream_writer = typing.cast("asyncio.StreamWriter", writer)
        lock = asyncio.Lock()
        first = _request()
        second = {**_request(), "request_id": "request-2", "revision": 3}
        first_key = (first["app_session_id"], first["composition_id"])
        second_key = (second["app_session_id"], second["composition_id"])
        latest = {first_key: first["revision"]}
        first_task = asyncio.create_task(
            server._run(first, first_key, latest, stream_writer, lock, set())
        )
        await asyncio.sleep(0.01)
        first_task.cancel()
        latest[second_key] = second["revision"]
        second_task = asyncio.create_task(
            server._run(second, second_key, latest, stream_writer, lock, set())
        )
        await asyncio.gather(first_task, return_exceptions=True)
        await second_task
        await server.close()
        assert ranker.maximum_active == 1
        assert len(writer.frames) == 1

    asyncio.run(scenario())


# --- text generation (LLM-composed sentences) ---


class StubGenerateRanker(CloudModelClient):
    def __init__(self, response: dict):
        super().__init__(api_key_loader=lambda: "secret")
        self.response = response
        self._payload: dict | None = None

    @property
    def payload(self) -> dict:
        """The last captured request payload; fails loudly when the stub
        never saw a request instead of surfacing as None-subscript."""
        assert self._payload is not None, "stub received no request"
        return self._payload

    def _post_json(self, path, payload, *, timeout, api_key=None):
        self._payload = payload
        return {
            "choices": [
                {
                    "message": {
                        "content": self.response["text"] or "",
                    },
                    "finish_reason": "stop",
                }
            ]
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


def test_generated_sentence_within_structural_gates_is_accepted():
    ranker = StubGenerateRanker({"text": "测试你好"})

    result = ranker.rank(validate_request(_generate_request()))

    # 判定全部本地合成：采纳即二值通过，confidence 为常量；reason 是固定
    # 的模型侧标签 typo_match，不再是本地质量判断（2026-10-12 产品决策）。
    assert result == {
        "decision": "generate",
        "candidate_id": None,
        "confidence": 1.0,
        "reason": "typo_match",
        "text": "测试你好",
    }


def test_request_validation_is_single_policy_without_alignment_field():
    # 档位设计已整体移除（2026-10-13）：请求不再携带 pinyin_alignment，
    # 校验器也不再读取该字段——遗留字段被自然忽略（未知键不校验）。
    # 拼音字符集无条件为 [A-Za-z'] ≤256 字节（中英混拼是大写字母的
    # 来源），非法字符仍拒绝。
    validated = validate_request(_generate_request())
    assert "pinyin_alignment" not in validated

    legacy = _generate_request()
    legacy["pinyin_alignment"] = "loose"
    # 遗留字段被自然忽略：校验器不再读取，未知键原样透传，不校验。
    assert "pinyin_alignment" in validate_request(legacy)

    mixed = _generate_request()
    mixed["pinyin"] = "yongPythonxie"
    validate_request(mixed)  # 大写字母无条件合法

    strict = _generate_request()
    strict["pinyin"] = "yong-python2"
    with pytest.raises(ValueError, match="pinyin"):
        validate_request(strict)


def test_typo_correction_is_the_models_job_not_a_local_gate():
    # 单一策略：shi 敲成 si 不再是本地门槛——纠错是模型的事，用户在
    # 候选面板取舍（2026-10-12/13 产品决策）。
    def _typo_request() -> dict:
        request = _generate_request()
        request["pinyin"] = "cesinihao"
        return request

    ranker = StubGenerateRanker({"text": "测试你好"})
    result = ranker.rank(validate_request(_typo_request()))
    assert result["decision"] == "generate"
    assert result["reason"] == "typo_match"


def test_misaligned_generated_sentence_still_generates():
    # 字典对齐检查已整体移除（2026-10-12 产品决策）："世" 不在守卫词典、
    # 文本不逐字对应拼音都不是本地门槛——组句质量由模型负责，用户在
    # 候选面板取舍。
    ranker = StubGenerateRanker({"text": "测试世界"})

    result = ranker.rank(validate_request(_generate_request()))

    assert result == {
        "decision": "generate",
        "candidate_id": None,
        "confidence": 1.0,
        "reason": "typo_match",
        "text": "测试世界",
    }


def test_mixed_punctuation_and_latin_text_passes():
    # 结构门槛不要求纯汉字：标点/字母/数字（含空格）混排合法（长度上限
    # 128 字符）；控制字符拒绝。>0x20 标量与分段非空段是 Swift 客户端
    # 的最终门槛，broker 不重复。
    ranker = StubGenerateRanker({"text": "测试，hello 123"})

    result = ranker.rank(validate_request(_generate_request()))

    assert result["decision"] == "generate"
    assert result["text"] == "测试，hello 123"

    oversized = StubGenerateRanker({"text": "试" * 129})
    assert (
        oversized.rank(validate_request(_generate_request()))["decision"]
        == "abstain"
    )


def test_generation_rejects_context_echo_and_control_characters():
    # 没有对齐梯兜底后，复读防护由 recent_context 尾部重叠检查承担
    #（与 continuation 策略镜像）；控制字符/换行直接拒。门槛对每档一致。
    request = _generate_request()
    request["recent_context"] = "周末上山采蘑菇的时候请向客户问好"
    echoing = StubGenerateRanker({"text": "请向客户问好"})
    assert echoing.rank(validate_request(request))["decision"] == "abstain"

    newline = StubGenerateRanker({"text": "测试\n你好"})
    assert newline.rank(validate_request(_generate_request()))[
        "decision"
    ] == "abstain"


def test_generate_ignores_fields_outside_the_content_contract():
    # 生成契约只有 text 一个字段：小模型照抄的旧契约字段（decision、
    # candidate_id、confidence、reason）一律忽略，判定只看 text 过
    # 结构门槛。
    ranker = StubGenerateRanker(
        {
            "decision": "generate",
            "candidate_id": "existing ID for generate",
            "text": "测试你好",
            "confidence": 0.9,
            "reason": "uncertain",
        },
    )

    assert ranker.rank(validate_request(_generate_request())) == {
        "decision": "generate",
        "candidate_id": None,
        "confidence": 1.0,
        "reason": "typo_match",
        "text": "测试你好",
    }


def test_generate_matching_a_pool_candidate_stays_a_generate_decision():
    # 候选池不进 prompt，模型无从照抄：生成文本与池内候选一致是真实的
    # 一致意见，保持 generate，由客户端做可见去重。
    ranker = StubGenerateRanker({"text": "测试你好"})
    request = _generate_request()
    # candidate-1 的文本与生成文本一致：仍是 generate
    request["candidates"][1]["text"] = "测试你好"
    assert ranker.rank(validate_request(request)) == {
        "decision": "generate",
        "candidate_id": None,
        "confidence": 1.0,
        "reason": "typo_match",
        "text": "测试你好",
    }

    # 与首选一致同样保持 generate
    request2 = _generate_request()
    request2["candidates"][0]["text"] = "测试你好"
    assert ranker.rank(validate_request(request2)) == {
        "decision": "generate",
        "candidate_id": None,
        "confidence": 1.0,
        "reason": "typo_match",
        "text": "测试你好",
    }


def test_generate_ignores_an_in_pool_candidate_id_attachment():
    # 模型附带池内 candidate_id 也是契约外字段：忽略，文本照常过
    # 结构门槛。
    ranker = StubGenerateRanker(
        {"text": "测试你好", "candidate_id": "candidate-1"},
    )

    assert ranker.rank(validate_request(_generate_request())) == {
        "decision": "generate",
        "candidate_id": None,
        "confidence": 1.0,
        "reason": "typo_match",
        "text": "测试你好",
    }


def test_decision_survives_trailing_noise_after_the_json_object():
    # 纯文本合同下的防御：模型无视指令回 JSON 且在对象后追加碎片时，
    # 宽松解包只取第一个对象，后续噪声不进句子。
    class NoisyStub(StubCloudModelClient):
        def _post_json(self, path, payload, *, timeout, api_key=None):
            self._payload = payload
            return {
                "choices": [
                    {
                        "message": {
                            "content": '{"text":"测试你好"} {"text":"重复碎片"}'
                        },
                        "finish_reason": "stop",
                    }
                ]
            }

    ranker = NoisyStub({"text": "测试你好"})

    assert ranker.rank(validate_request(_generate_request())) == {
        "decision": "generate",
        "candidate_id": None,
        "confidence": 1.0,
        "reason": "typo_match",
        "text": "测试你好",
    }


def test_debug_flag_logs_metadata_only_never_payloads(
    monkeypatch, tmp_path, capsys
):
    # P2-9：显式诊断开关只记录元数据（路径+字节数）；prompt/响应原文
    # 与凭据一律不落盘——此前完整 payload 写入 broker stderr 日志。
    flag = tmp_path / "cloud-debug"
    monkeypatch.setattr(cloud_model_module, "DEBUG_FLAG", flag)

    class FakeResponse:
        def read(self, limit=-1):
            return b'{"message": {"content": "{}","usage": {}}}'

        def __enter__(self):
            return self

        def __exit__(self, *args):
            return False

    class FakeOpener:
        def open(self, req, timeout=None):
            return FakeResponse()

    monkeypatch.setattr(
        cloud_model_module.request, "build_opener", lambda *a, **k: FakeOpener()
    )

    ranker = CloudModelClient(api_key_loader=lambda: "secret")

    flag.touch()
    ranker._post_json(
        "/api/chat",
        {"model": "m", "messages": [{"role": "user", "content": "机密上下文"}]},
        timeout=1,
        api_key="secret",
    )
    err = capsys.readouterr().err
    assert "[cloud-debug] ->" in err
    assert "[cloud-debug] <-" in err
    assert "bytes=" in err
    # 原文、payload 内容与凭据都不得出现在日志里。
    assert '"model"' not in err
    assert "机密上下文" not in err
    assert "secret" not in err
    assert "usage" not in err

    flag.unlink()
    ranker._post_json(
        "/api/chat", {"model": "m"}, timeout=1, api_key="secret"
    )
    assert capsys.readouterr().err == ""


def test_generated_sentence_bound_is_128_printable_characters():
    # 旧 30 字上限随字典守卫移除：结构上限统一为 128 个可打印字符，
    # 超长输出本地按 abstain 处理，不进云错误预算。
    within = StubGenerateRanker({"text": "测" * 128})
    assert within.rank(validate_request(_generate_request()))["decision"] == (
        "generate"
    )

    oversized = StubGenerateRanker({"text": "测" * 129})
    assert oversized.rank(validate_request(_generate_request()))["decision"] == (
        "abstain"
    )


def test_model_declining_with_null_or_empty_text_abstains():
    # 内容契约下模型用 null/空串表示"没有站得住的读法"；本地合成为
    # abstain。模型自报的 confidence 已不再是契约的一部分。
    for declined in ({"text": None}, {"text": ""}, {"text": "  "}):
        ranker = StubGenerateRanker(declined)
        assert ranker.rank(validate_request(_generate_request())) == {
            "decision": "abstain",
            "candidate_id": None,
            "confidence": None,
            "reason": "uncertain",
        }


def test_generation_matching_the_top_pool_candidate_stays_generate():
    # 模型看不到候选池：生成文本恰与首选相同是模型独立得出的一致结论，
    # 保持 generate 上屏，客户端负责"云端与首选一致"的可见去重。
    ranker = StubGenerateRanker({"text": "策士你好"})

    result = ranker.rank(validate_request(_generate_request()))

    assert result == {
        "decision": "generate",
        "candidate_id": None,
        "confidence": 1.0,
        "reason": "typo_match",
        "text": "策士你好",
    }


def test_generation_with_non_string_text_is_rejected():
    ranker = StubGenerateRanker({"text": 42})

    with pytest.raises(CloudBrokerError, match="invalid"):
        ranker.rank(validate_request(_generate_request()))


def test_server_rejects_structurally_invalid_generation():
    request = validate_request(_generate_request())
    # 置信度区间是开区间 (0,1]：0 非法（低置信不再有单独门槛）。
    with pytest.raises(ValueError, match="generated sentence"):
        validate_decision(
            {
                "decision": "generate",
                "candidate_id": None,
                "text": "测试你好",
                "confidence": 0,
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


def test_server_decision_bound_is_128():
    # server 层只查结构（≤128、无控制字符、分段布局），不再有档位差异
    # 的 30 字/纯汉字检查（2026-10-12 产品决策；2026-10-13 档位移除后
    # 只剩单一门槛）。空格与分段非空段由 Swift 客户端最终把关。
    request = validate_request(_generate_request())
    frame = {
        "decision": "generate",
        "candidate_id": None,
        "text": "用Python写测试，hello",
        "confidence": 1.0,
        "reason": "typo_match",
    }
    assert validate_decision(frame, request) == frame
    # 旧 30 字上限已删除：128 为界。
    assert validate_decision(
        {**frame, "text": "试" * 128}, request
    ) == {**frame, "text": "试" * 128}

    oversized = {**frame, "text": "试" * 129}
    with pytest.raises(ValueError, match="generated sentence"):
        validate_decision(oversized, request)


def test_server_rejects_choose_and_keep_decisions_entirely():
    # choose/keep 已从协议删除：无论是否携带 text，一律拒绝——只剩
    # generate/abstain 是合法决策。
    request = validate_request(_generate_request())
    for decision in (
        {
            "decision": "choose",
            "candidate_id": "candidate-1",
            "text": "测试你好",
            "confidence": 0.99,
            "reason": "context_match",
        },
        {
            "decision": "choose",
            "candidate_id": "candidate-1",
            "confidence": 0.99,
            "reason": "typo_match",
        },
        {
            "decision": "keep",
            "candidate_id": None,
            "text": "测试你好",
            "confidence": None,
            "reason": "rime_rank",
        },
        {
            "decision": "keep",
            "candidate_id": None,
            "confidence": None,
            "reason": "rime_rank",
        },
    ):
        with pytest.raises(ValueError):
            validate_decision(decision, request)


def test_prompt_carries_single_policy_wording():
    # 单一策略（2026-10-13 档位移除）：唯一提词即原 loose 措辞——邀请
    # 纠错与中英混排、上限 128 字符、英文/数字原样保留；不再有任何
    # "逐字来自拼音" 的对齐措辞。规则与输出契约固定在 system 消息里
    #（前缀不变，prefill 缓存可复用）；用户消息只携带本次请求的纯
    # 数据，输出是纯文本句子，判定全部在本地合成。
    ranker = StubGenerateRanker({"text": None})

    ranker.rank(validate_request(_generate_request()))

    assert ranker.payload is not None
    assert ranker.payload["max_tokens"] == 256
    system_content = ranker.payload["messages"][0]["content"]
    assert "逐字" not in system_content
    assert "按最合理的意图纠正" in system_content
    assert "原样保留" in system_content
    assert "128" in system_content
    assert "直接输出句子本身的纯文本" in system_content
    assert "decision" not in system_content
    user_content = ranker.payload["messages"][-1]["content"]
    assert "generate" not in user_content
    serialized = json.dumps(ranker.payload, ensure_ascii=False)
    assert "secret" not in serialized


def test_client_without_text_generation_capability_gets_keep():
    class GenerateRanker:
        def rank(self, cloud_request):
            del cloud_request
            return {
                "decision": "generate",
                "candidate_id": None,
                "confidence": 0.9,
                "reason": "context_match",
                "text": "测试你好",
            }

        def rank_continuation(self, cloud_request):
            del cloud_request
            return {"decision": "abstain", "reason": "capability_absent"}

        def embed_texts(self, texts):
            return [[] for _ in texts]

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
            Path(tempfile.gettempdir()) / "unused.sock",
            GenerateRanker(),
        )
        writer = MemoryWriter()
        stream_writer = typing.cast("asyncio.StreamWriter", writer)
        lock = asyncio.Lock()
        # 过渡契约：请求未携带 candidate_pool_hash 时响应也不再回显。
        bare_request = _generate_request()
        del bare_request["candidate_pool_hash"]
        request = validate_request(bare_request)
        key = (request["app_session_id"], request["composition_id"])
        latest = {key: request["revision"]}
        await server._run(request, key, latest, stream_writer, lock, set())
        frame = json.loads(writer.frames[0].decode())
        assert frame["decision"] == "keep"
        assert "generated_text" not in frame
        assert "candidate_pool_hash" not in frame

        writer.frames.clear()
        await server._run(
            request, key, latest, stream_writer, lock, {"text-generation"}
        )
        frame = json.loads(writer.frames[0].decode())
        assert frame["decision"] == "generate"
        assert frame["generated_text"] == "测试你好"
        assert frame["generated_pinyin"] == "ceshinihao"
        assert "candidate_pool_hash" not in frame

    asyncio.run(scenario())


# --- cross-punctuation segmented generation (Task 3) ---


def _segmented_generate_request() -> dict:
    request = _request()
    request["pinyin"] = "nihao"
    request["candidates"] = [
        {
            "id": "candidate-0",
            "text": "你好",
            "source": "rime_exact",
            "rime_index": 0,
            "consumed_start": 0,
            "consumed_length": 5,
            "aligned_pinyin": "nihao",
            "edit_cost": 0,
        },
    ]
    request["segments"] = [
        {"pinyin": "ceshi", "separator": "，", "committed_text": "测试"},
        {"pinyin": "nihao", "separator": ""},
    ]
    return request


def test_segmented_generate_joins_separators():
    ranker = StubGenerateRanker({"text": "测试，你好"})

    result = ranker.rank(validate_request(_segmented_generate_request()))

    assert result == {
        "decision": "generate",
        "candidate_id": None,
        "confidence": 1.0,
        "reason": "typo_match",
        "text": "测试，你好",
    }
    # 单次 LLM 往返：segments 直接进入 prompt，而不是逐段调用。
    assert ranker.payload is not None
    system_content = ranker.payload["messages"][0]["content"]
    assert "被标点分隔" in system_content
    prompt = json.loads(ranker.payload["messages"][-1]["content"])
    assert prompt["segments"] == [
        {"pinyin": "ceshi", "separator": "，", "committed_text": "测试"},
        {"pinyin": "nihao", "separator": ""},
    ]


def test_segmented_generate_with_wrong_separator_abstains():
    ranker = StubGenerateRanker({"text": "测试。你好"})

    assert ranker.rank(validate_request(_segmented_generate_request()))[
        "decision"
    ] == "abstain"


def test_segmented_generate_with_empty_part_still_generates():
    # 空段（丢段/多打分隔符）不在 broker 侧拦截：Swift 客户端的
    # CloudGeneratedSentencePolicy 分段变体（每段非空）是最终门槛。
    ranker = StubGenerateRanker({"text": "，你好"})

    result = ranker.rank(validate_request(_segmented_generate_request()))

    assert result["decision"] == "generate"
    assert result["text"] == "，你好"


def test_segmented_generate_accepts_common_fuzzy_typo():
    # 用户把 shi 打成 si（平翘舌模糊音）：字典对齐已移除，纠错是模型的
    # 事；分段布局（分隔符原样保留）仍是硬门槛。
    request = _segmented_generate_request()
    request["segments"][0]["pinyin"] = "cesi"
    ranker = StubGenerateRanker({"text": "测试，你好"})

    result = ranker.rank(validate_request(request))

    assert result["decision"] == "generate"
    assert result["text"] == "测试，你好"
    assert result["reason"] == "typo_match"


def test_segmented_generate_with_misaligned_part_still_generates():
    # 段内不再查字典对齐："士好" 不逐字对应 nihao 也由模型负责、用户在
    # 候选面板取舍（2026-10-12 产品决策）；分段布局（separator 顺序）
    # 仍是每档一致的硬门槛，默认档与 loose 档同判。
    ranker = StubGenerateRanker({"text": "测试，士好"})

    result = ranker.rank(validate_request(_segmented_generate_request()))

    assert result["decision"] == "generate"
    assert result["text"] == "测试，士好"


def test_segments_request_validation_rejects_mismatched_active_pinyin_and_bad_separators():
    mismatched = _segmented_generate_request()
    mismatched["segments"][-1]["pinyin"] = "ceshi"
    with pytest.raises(ValueError):
        validate_request(mismatched)

    non_punctuation = _segmented_generate_request()
    non_punctuation["segments"][0]["separator"] = "ab"
    with pytest.raises(ValueError):
        validate_request(non_punctuation)

    empty_middle = _segmented_generate_request()
    empty_middle["segments"][0]["separator"] = ""
    with pytest.raises(ValueError):
        validate_request(empty_middle)

    non_empty_last = _segmented_generate_request()
    non_empty_last["segments"][-1]["separator"] = "，"
    with pytest.raises(ValueError):
        validate_request(non_empty_last)

    too_many = _segmented_generate_request()
    too_many["segments"] = [
        {"pinyin": "a", "separator": "，"},
    ] * 8 + [{"pinyin": "nihao", "separator": ""}]
    with pytest.raises(ValueError):
        validate_request(too_many)


def test_generated_segments_echoed_verbatim_in_response():
    class SegmentedGenerateRanker:
        def rank(self, cloud_request):
            del cloud_request
            return {
                "decision": "generate",
                "candidate_id": None,
                "confidence": 0.9,
                "reason": "context_match",
                "text": "测试，你好",
            }

        def rank_continuation(self, cloud_request):
            del cloud_request
            return {"decision": "abstain", "reason": "capability_absent"}

        def embed_texts(self, texts):
            return [[] for _ in texts]

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
            Path(tempfile.gettempdir()) / "unused.sock",
            SegmentedGenerateRanker(),
        )
        writer = MemoryWriter()
        stream_writer = typing.cast("asyncio.StreamWriter", writer)
        lock = asyncio.Lock()
        request = validate_request(_segmented_generate_request())
        key = (request["app_session_id"], request["composition_id"])
        latest = {key: request["revision"]}
        await server._run(
            request, key, latest, stream_writer, lock, {"text-generation"}
        )
        frame = json.loads(writer.frames[0].decode())
        assert frame["decision"] == "generate"
        assert frame["generated_text"] == "测试，你好"
        assert frame["generated_segments"] == json.dumps(
            request["segments"],
            sort_keys=True,
            ensure_ascii=False,
            separators=(",", ":"),
        )

    asyncio.run(scenario())


# --- post-commit continuation (Task 2) ---


def _continuation_request() -> dict:
    return {
        "schema_version": 1,
        "type": "continuation",
        "api_key": "secret",
        "request_id": "request-cont-1",
        "client_session_id": "client-session",
        "bundle_id": "com.example.Editor",
        "model_id": "glm-5.3-flash",
        "recent_context": "床前明月光",
        "history_snippets": [],
        "history_generation": 4,
        "deadline_ms": 800,
    }


class StubContinuationRanker:
    def __init__(self, decision: dict):
        self.decision = decision

    def rank(self, cloud_request):
        raise AssertionError("continuation must not hit the inference path")

    def rank_continuation(self, cloud_request):
        return self.decision

    def embed_texts(self, texts):
        return [[] for _ in texts]


class _ContinuationFrameWriter:
    def __init__(self):
        self.frames = []

    def write(self, payload):
        self.frames.append(payload)

    async def drain(self):
        return True

    def close(self):
        pass


def _continuation_frame(
    decision: dict,
    *,
    capabilities: set | None = None,
    request: dict | None = None,
    history_indexer=None,
) -> dict:
    if capabilities is None:
        capabilities = {"continuation-generation"}
    server = CloudBrokerServer(
        Path(tempfile.gettempdir()) / "unused-continuation.sock",
        StubContinuationRanker(decision),
        history_indexer=history_indexer,
    )
    writer = _ContinuationFrameWriter()
    stream_writer = typing.cast("asyncio.StreamWriter", writer)

    async def scenario():
        lock = asyncio.Lock()
        await server._run_continuation(
            validate_continuation_request(request or _continuation_request()),
            stream_writer,
            lock,
            capabilities,
        )
        await server.close()
        return json.loads(writer.frames[0].decode())

    return asyncio.run(scenario())


def test_continuation_request_validation_rejects_short_context_and_bad_model():
    request = validate_continuation_request(_continuation_request())
    assert request["recent_context"] == "床前明月光"

    short = _continuation_request()
    short["recent_context"] = "床前明"
    with pytest.raises(ValueError, match="recent context"):
        validate_continuation_request(short)

    oversized = _continuation_request()
    oversized["recent_context"] = "字" * 401
    with pytest.raises(ValueError, match="recent context"):
        validate_continuation_request(oversized)

    bad_model = _continuation_request()
    bad_model["model_id"] = "gpt-4o"
    with pytest.raises(ValueError, match="model"):
        validate_continuation_request(bad_model)

    bad_deadline = _continuation_request()
    bad_deadline["deadline_ms"] = 30001
    with pytest.raises(ValueError, match="deadline"):
        validate_continuation_request(bad_deadline)


def test_continuation_capability_absent_abstains():
    async def scenario():
        with tempfile.TemporaryDirectory(dir="/tmp") as root:
            socket_path = Path(root) / "runtime" / "rimeai-cloud.sock"
            server = CloudBrokerServer(
                socket_path,
                StubContinuationRanker(
                    {
                        "decision": "generate",
                        "generated_text": "疑是地上霜",
                        "confidence": 0.8,
                        "reason": "context_match",
                    }
                ),
            )
            try:
                await server.start()
            except PermissionError:
                pytest.skip("sandbox forbids Unix socket binding")
            try:
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
                assert "continuation-generation" in hello["capabilities"]
                # 客户端 hello 未声明 continuation-generation：broker 直接
                # abstain，不调用 ranker（旧客户端静默降级）。
                writer.write(
                    (json.dumps(_continuation_request()) + "\n").encode()
                )
                await writer.drain()
                response = json.loads(await reader.readline())
                assert response["status"] == "ok"
                assert response["request_id"] == "request-cont-1"
                assert response["decision"] == "abstain"
                assert response["reason"] == "capability_absent"
                assert "generated_text" not in response
                writer.close()
                await writer.wait_closed()
            finally:
                await server.close()

    asyncio.run(scenario())


def test_continuation_generates_passage_continuation():
    ranker = StubCloudModelClient(
        {
            "decision": "generate",
            "generated_text": "疑是地上霜",
            "confidence": 0.8,
            "reason": "context_match",
        }
    )

    result = ranker.rank_continuation(
        validate_continuation_request(_continuation_request())
    )

    assert result == {
        "decision": "generate",
        "generated_text": "疑是地上霜",
        "confidence": 0.8,
        "reason": "context_match",
    }
    # continuation 是纯上下文任务：prompt 必须携带 recent_context。
    # 与组句路径同构的单轮消息（产品决策 2026-10-12）：system 契约 +
    # 一条 user 消息，不再携带 few-shot 示例对。
    messages = ranker.payload["messages"]
    assert [message["role"] for message in messages] == ["system", "user"]
    assert "床前明月光" in messages[-1]["content"]
    serialized = json.dumps(ranker.payload, ensure_ascii=False)
    assert "secret" not in serialized


def test_continuation_decisionless_contract_accepted():
    # 输出契约下模型只回 {"generated_text": ..., "confidence": ...}，
    # 不带 decision 字段：validator 按 generated_text 推断。
    ranker = StubCloudModelClient(
        {"generated_text": "疑是地上霜", "confidence": 0.95}
    )
    result = ranker.rank_continuation(
        validate_continuation_request(_continuation_request())
    )
    assert result == {
        "decision": "generate",
        "generated_text": "疑是地上霜",
        "confidence": 0.95,
        "reason": "context_match",
    }

    declining = StubCloudModelClient({"generated_text": None, "confidence": None})
    result = declining.rank_continuation(
        validate_continuation_request(_continuation_request())
    )
    assert result["decision"] == "abstain"


def test_continuation_rejects_non_han_text():
    ranker = StubCloudModelClient(
        {
            "decision": "generate",
            "generated_text": "疑是地上霜。",
            "confidence": 0.9,
            "reason": "context_match",
        }
    )

    result = ranker.rank_continuation(
        validate_continuation_request(_continuation_request())
    )

    assert result == {
        "decision": "abstain",
        "generated_text": None,
        "confidence": None,
        "reason": "invalid_text",
    }


def test_continuation_rejects_low_confidence():
    ranker = StubCloudModelClient(
        {
            "decision": "generate",
            "generated_text": "疑是地上霜",
            "confidence": 0.64,
            "reason": "context_match",
        }
    )

    result = ranker.rank_continuation(
        validate_continuation_request(_continuation_request())
    )

    assert result == {
        "decision": "abstain",
        "generated_text": None,
        "confidence": None,
        "reason": "low_confidence",
    }


def test_continuation_rejects_context_echo():
    # 生成文本 == context 尾部：复读不是续写。
    ranker = StubCloudModelClient(
        {
            "decision": "generate",
            "generated_text": "床前明月光",
            "confidence": 0.9,
            "reason": "context_match",
        }
    )

    result = ranker.rank_continuation(
        validate_continuation_request(_continuation_request())
    )

    assert result == {
        "decision": "abstain",
        "generated_text": None,
        "confidence": None,
        "reason": "echoes_context",
    }


def test_continuation_ignores_history_generation_drift():
    # commit 的异步历史写入恰在请求飞行中 bump generation；continuation
    # 不做 inference 路径的 generation 响应期比对（竞态陷阱），新鲜度由
    # 客户端 commitEpoch 保证（spec §5.3）。
    class DriftIndexer:
        def generation(self):
            raise AssertionError(
                "continuation must not consult history generation"
            )

        def augment_request(self, request):
            return request

    frame = _continuation_frame(
        {
            "decision": "generate",
            "generated_text": "疑是地上霜",
            "confidence": 0.8,
            "reason": "context_match",
        },
        history_indexer=DriftIndexer(),
    )

    assert frame["status"] == "ok"
    assert frame["request_id"] == "request-cont-1"
    assert frame["decision"] == "generate"
    assert frame["generated_text"] == "疑是地上霜"
    assert frame["confidence"] == 0.8


def test_continuation_text_allows_unit():
    context = "床前明月光"
    assert continuation_text_allows("疑是地上霜", context, 0.8)
    # 含标点
    assert not continuation_text_allows("疑是地上霜。", context, 0.8)
    # 少于 2 个汉字
    assert not continuation_text_allows("霜", context, 0.8)
    # 超过 16 个汉字
    assert not continuation_text_allows("疑" * 17, context, 0.8)
    # 低置信
    assert not continuation_text_allows("疑是地上霜", context, 0.64)
    # 复读 context 尾部
    assert not continuation_text_allows("床前明月光", context, 0.9)
    assert not continuation_text_allows(
        "床前明月光", "今天读了床前明月光这首诗", 0.9
    )
    # 尾部重叠 ≥ 4 字拒，3 字放行
    assert not continuation_text_allows(
        "去公园散步真好", "今天我们去公园散步", 0.9
    )
    assert continuation_text_allows(
        "园散步去真好", "今天我们去公园散步", 0.9
    )


def test_cloud_env_loader_matches_swift_semantics(tmp_path, monkeypatch):
    # I3 回归：broker 侧固化（L3 云压缩）的凭据来自
    # ~/.config/rimeai/cloud.env，解析语义与 Swift CloudCredentialStore
    # 对齐：整行 # 注释、KEY=VALUE、成对引号剥离、行内 # 属于值、
    # 缺 = 的行视为文件损坏（显式报错而非静默无凭据）。
    # 凭据文件还必须 owner-only（Swift 侧写 0600）：group/world 可读的
    # 副本等于把 key 暴露给本机所有账号，loader 直接拒绝使用。
    from rimeai_cloud_broker.__main__ import (
        _cloud_env_loader,
    )

    credential = tmp_path / ".config" / "rimeai" / "cloud.env"
    credential.parent.mkdir(parents=True)
    credential.write_text(
        "# managed by the input method\n"
        'RIMEAI_CLOUD_API_KEY="key-with-#"\n'
        "\n"
        "OTHER=value\n",
        encoding="utf-8",
    )
    credential.chmod(0o600)
    monkeypatch.setenv("HOME", str(tmp_path))
    assert _cloud_env_loader() == "key-with-#"

    credential.write_text("RIMEAI_CLOUD_API_KEY=no-quotes\n", encoding="utf-8")
    credential.chmod(0o600)
    assert _cloud_env_loader() == "no-quotes"

    credential.write_text("broken line without equals\n", encoding="utf-8")
    credential.chmod(0o600)
    with pytest.raises(ValueError, match="malformed"):
        _cloud_env_loader()

    credential.unlink()
    assert _cloud_env_loader() == ""


def test_cloud_env_loader_refuses_world_readable_credentials(
    tmp_path, monkeypatch
):
    # 凭据文件被其他本机账号可读时不得使用：key 已经在共享目录或同步
    # 工具里裸奔，用它上云等于扩大泄露面。
    from rimeai_cloud_broker.__main__ import (
        CredentialPermissionError,
        _cloud_env_loader,
    )

    credential = tmp_path / ".config" / "rimeai" / "cloud.env"
    credential.parent.mkdir(parents=True)
    credential.write_text(
        "RIMEAI_CLOUD_API_KEY=leaky-key\n", encoding="utf-8"
    )
    credential.chmod(0o644)
    monkeypatch.setenv("HOME", str(tmp_path))

    with pytest.raises(CredentialPermissionError):
        _cloud_env_loader()

    credential.chmod(0o600)
    assert _cloud_env_loader() == "leaky-key"


def test_usable_cloud_api_key_separates_absent_from_broken(
    tmp_path, monkeypatch
):
    # 调度侧凭据决策分两类：
    # - absent（根本没配凭据）→ L3 永久关闭，积压按终态清理，统计与
    #   evict 照常运行；
    # - broken（有凭据文件但解析不了）→ 临时故障，保留 L3 积压重试，
    #   不得让一次手滑就永久丢掉待摘要的历史。
    from rimeai_cloud_broker.__main__ import (
        CloudCredentialState,
        _cloud_credential_state,
        _usable_cloud_api_key,
    )

    credential = tmp_path / ".config" / "rimeai" / "cloud.env"
    credential.parent.mkdir(parents=True)
    monkeypatch.setenv("HOME", str(tmp_path))

    credential.write_text("broken line without equals\n", encoding="utf-8")
    credential.chmod(0o600)
    with pytest.raises(ValueError, match="malformed"):
        _usable_cloud_api_key()
    assert (
        _cloud_credential_state() is CloudCredentialState.BROKEN
    )

    credential.write_text("RIMEAI_CLOUD_API_KEY=usable-key\n", encoding="utf-8")
    credential.chmod(0o600)
    assert _usable_cloud_api_key() == "usable-key"
    assert _cloud_credential_state() is CloudCredentialState.OK

    credential.write_text("# only comments\nOTHER=value\n", encoding="utf-8")
    credential.chmod(0o600)
    assert _usable_cloud_api_key() == ""
    assert (
        _cloud_credential_state() is CloudCredentialState.ABSENT
    )

    credential.unlink()
    assert _usable_cloud_api_key() == ""


def test_semantic_consolidator_skipped_when_credentials_unusable(
    tmp_path, monkeypatch
):
    # 固化循环的 L3 云压缩只在凭据文件存在且可解析时启用；损坏的
    # cloud.env 不得让每轮固化都抛 ConsolidationError 并阻塞原文清理
    # ——语义阶段本轮不跑，但积压保留（临时故障）而不是被判终态丢弃。
    from rimeai_cloud_broker.__main__ import _semantic_consolidator

    credential = tmp_path / ".config" / "rimeai" / "cloud.env"
    credential.parent.mkdir(parents=True)
    profile_directory = tmp_path / "language_profile"
    monkeypatch.setenv("HOME", str(tmp_path))
    ranker = CloudModelClient(
        api_key_loader=lambda: ""
    )

    def build(*, enabled: bool):
        return _semantic_consolidator(
            ranker.post_json,
            enabled=enabled,
            profile_directory=profile_directory,
            phrasebook_db=profile_directory / "phrasebook.sqlite3",
        )

    # 没有凭据文件 = 用户没开启云压缩 = 永久关闭。
    absent = build(enabled=True)
    assert absent.consolidator is None
    assert absent.permanently_unavailable is True

    credential.write_text("broken line without equals\n", encoding="utf-8")
    credential.chmod(0o600)
    broken = build(enabled=True)
    assert broken.consolidator is None
    assert broken.permanently_unavailable is False

    credential.write_text("RIMEAI_CLOUD_API_KEY=usable-key\n", encoding="utf-8")
    credential.chmod(0o600)
    usable = build(enabled=True)
    assert usable.consolidator is not None
    assert usable.permanently_unavailable is False

    # The --no-consolidation switch wins even with usable credentials.
    disabled = build(enabled=False)
    assert disabled.consolidator is None
    assert disabled.permanently_unavailable is True


def test_broker_activity_notifier_fires_on_valid_traffic_only():
    # 固化空闲门依赖 broker 的推理流量回执：通过校验的 inference /
    # continuation 帧刷新空闲期限，hello/非法帧不算输入活动。
    class TrafficRanker:
        def rank(self, cloud_request):
            del cloud_request
            return {
                "decision": "generate",
                "candidate_id": None,
                "confidence": 1.0,
                "reason": "typo_match",
                "text": "测试你好",
            }

        def rank_continuation(self, cloud_request):
            del cloud_request
            return {
                "decision": "abstain",
                "generated_text": None,
                "confidence": None,
                "reason": "uncertain",
            }

        def embed_texts(self, texts):
            return [[] for _ in texts]

    async def scenario():
        with tempfile.TemporaryDirectory(dir="/tmp") as root:
            socket_path = Path(root) / "runtime" / "rimeai-cloud.sock"
            calls = []
            server = CloudBrokerServer(
                socket_path,
                TrafficRanker(),
                activity_notifier=lambda: calls.append(1),
            )
            try:
                await server.start()
            except PermissionError:
                pytest.skip("sandbox forbids Unix socket binding")
            try:
                reader, writer = await asyncio.open_unix_connection(
                    socket_path
                )
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
                await reader.readline()
                assert calls == []

                writer.write((json.dumps(_request()) + "\n").encode())
                await writer.drain()
                await reader.readline()
                assert len(calls) == 1

                invalid = _request()
                invalid["pinyin"] = "NOT-LOWER"
                writer.write((json.dumps(invalid) + "\n").encode())
                await writer.drain()
                await asyncio.sleep(0.05)
                assert len(calls) == 1

                writer.write(
                    (json.dumps(_continuation_request()) + "\n").encode()
                )
                await writer.drain()
                await reader.readline()
                assert len(calls) == 2

                writer.close()
                await writer.wait_closed()
            finally:
                await server.close()

    asyncio.run(scenario())
