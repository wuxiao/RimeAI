"""MLX constrained worker: protocol bounds, rollback-cache parity against
naive re-prefill, and persistent-prefix determinism — all with fake
backends, no mlx import (the repo venv does not carry mlx)."""

import json

import pytest

from rimeai_runtime.constrained_decoder import PinyinTokenIndex
from rimeai_runtime.constrained_worker_protocol import (
    CONFIDENCE_CALIBER_MASK_RENORM,
    GenerateRequestError,
    generate_response,
    validate_generate_request,
)
from rimeai_runtime.mlx_worker import (
    BEAM_WIDTH,
    SEED_CONTEXT,
    MlxConstrainedEngine,
    MlxEngineError,
    PrefixRollbackCache,
    RollbackBackend,
    _beam_length_penalty,
    _SeedPathScorer,
    _user_lm_fusion_config,
    common_prefix_length,
    handle_request_line,
    model_artifact_id,
)
from rimeai_runtime.pinyin_guard import PinyinGuard


def _stable_probs(prefix: tuple[int, ...]) -> dict[int, float]:
    """Deterministic next-token distribution as a pure function of the
    consumed prefix (mirrors causal-LM KV semantics: a row read at
    position k depends only on tokens[:k])."""
    digest = 2166136261
    for token in prefix:
        digest = ((digest ^ (token + 0x9E3779B9)) * 16777619) & 0xFFFFFFFF
    return {
        token: round(((digest >> (token * 3)) % 997) / 997.0, 9)
        for token in (1, 2, 3, 4, 5, 6, 7)
    }


class _KvSimulatingBackend(RollbackBackend):
    """Fake trimmable KV cache: token list state + prefix-pure rows."""

    def __init__(self) -> None:
        self.tokens: list[int] = []
        self.feed_deltas: list[list[int]] = []

    def feed(self, delta: list[int]) -> list[tuple[int, ...]]:
        base = len(self.tokens)
        self.tokens = self.tokens + [int(token) for token in delta]
        self.feed_deltas.append([int(token) for token in delta])
        return [
            tuple(self.tokens[: base + offset + 1])
            for offset in range(len(delta))
        ]

    def trim(self, count: int) -> int:
        trimmed = min(count, len(self.tokens))
        self.tokens = self.tokens[: len(self.tokens) - trimmed]
        return trimmed

    def softmax(self, row: tuple[int, ...]) -> dict[int, float]:
        return _stable_probs(row)


def _naive_distribution(target: list[int]) -> dict[int, float]:
    """Torch-worker semantics: score the full sequence from scratch."""
    return _stable_probs(tuple(target))


# Beam-like call patterns: the initial frontier scores the bare seed,
# paths branch, revisit shorter prefixes after deeper ones, and diverge
# mid-path — the exact shapes _decode_beam produces.
_BEAM_CALL_PATHS = [
    [],
    [11],
    [11, 4],
    [11, 4, 7],
    [11, 7],
    [11, 4, 7, 2],
    [11, 4],
    [11, 7, 2, 5, 6],
    [11, 7, 2],
    [11, 4, 7, 2, 5],
    [11],
]


def test_rollback_cache_matches_naive_refill_bit_for_bit() -> None:
    backend = _KvSimulatingBackend()
    cache = PrefixRollbackCache(backend)
    seed = [1773, 9, 40]
    scorer = _SeedPathScorer(cache, seed)
    for path in _BEAM_CALL_PATHS:
        assert dict(scorer(path)) == _naive_distribution(seed + path), path


def test_parity_survives_context_extension_across_requests() -> None:
    backend = _KvSimulatingBackend()
    cache = PrefixRollbackCache(backend)
    first = _SeedPathScorer(cache, [1773, 9])
    for path in ([], [4], [4, 7], [4]):
        assert dict(first(path)) == _naive_distribution([1773, 9] + path)
    # Second request: context grew (seed extends the previous seed), the
    # cache persists, and parity must still hold.
    second = _SeedPathScorer(cache, [1773, 9, 13, 6])
    for path in ([], [4, 7], [4], [8, 1], [4, 7, 2]):
        assert dict(second(path)) == _naive_distribution(
            [1773, 9, 13, 6] + path
        )
    # Third request: context shrank — trim then rebuild.
    third = _SeedPathScorer(cache, [1773])
    for path in ([], [4], [4, 7, 2]):
        assert dict(third(path)) == _naive_distribution([1773] + path)


def test_identical_request_skips_prefill_entirely() -> None:
    backend = _KvSimulatingBackend()
    cache = PrefixRollbackCache(backend)
    scorer = _SeedPathScorer(cache, [1773, 9])
    scorer([4, 7])
    fed_after_first = cache.stats["cache_fed_tokens"]
    assert fed_after_first == 4  # seed (2) + path (2)
    scorer([4, 7])
    assert cache.stats["cache_fed_tokens"] == fed_after_first
    scorer([4, 7, 2])
    assert cache.stats["cache_fed_tokens"] == fed_after_first + 1


def test_context_extension_prefills_only_the_delta() -> None:
    backend = _KvSimulatingBackend()
    cache = PrefixRollbackCache(backend)
    _SeedPathScorer(cache, [1773, 9])([4])
    fed_first = cache.stats["cache_fed_tokens"]
    assert fed_first == 3
    _SeedPathScorer(cache, [1773, 9, 13])([4])
    # Only the new context token (13) and the path token (4) are fed;
    # the shared seed prefix [1773, 9] is never re-fed.
    assert backend.feed_deltas[-1] == [13, 4]
    assert cache.stats["cache_fed_tokens"] == fed_first + 2


def test_diverging_beam_paths_share_only_the_common_prefix() -> None:
    backend = _KvSimulatingBackend()
    cache = PrefixRollbackCache(backend)
    scorer = _SeedPathScorer(cache, [1773])
    scorer([4, 7])
    scorer([4, 9])  # diverges at the second step
    # First call feeds the whole target in one window; the diverging
    # path reuses [1773, 4] and feeds only the new suffix.
    assert backend.feed_deltas == [[1773, 4, 7], [9]]
    assert cache.stats["cache_trim_operations"] >= 1


def test_trim_shortfall_fails_loud() -> None:
    class _StubbornBackend(_KvSimulatingBackend):
        def trim(self, count: int) -> int:
            return count - 1  # cache refuses to trim fully

    cache = PrefixRollbackCache(_StubbornBackend())
    cache.distribution([1, 2, 3])
    with pytest.raises(RuntimeError, match="not trimmable"):
        cache.distribution([1])


def test_backend_dropping_interior_rows_fails_loud() -> None:
    backend = _KvSimulatingBackend()
    cache = PrefixRollbackCache(backend)
    cache.distribution([1, 2, 3])
    # White-box: simulate a backend contract violation by erasing the
    # endpoint row an honest feed must have stored.
    del cache._rows[3]
    with pytest.raises(RuntimeError, match="dropped rows"):
        cache.distribution([1, 2, 3])


def test_common_prefix_length() -> None:
    assert common_prefix_length([], [1]) == 0
    assert common_prefix_length([1, 2, 3], [1, 2]) == 2
    assert common_prefix_length([1, 2], [1, 3]) == 1
    assert common_prefix_length([1], [1]) == 1


def test_constants_pin_the_frozen_contract() -> None:
    assert SEED_CONTEXT == "。"
    assert BEAM_WIDTH == 4
    artifact = model_artifact_id()
    assert artifact.startswith("qwen2.5-0.5b@060db649:")
    assert "sha256-9bc6f756079b" in artifact
    assert artifact.endswith(":mlx-8bit:constrained-v3-mlx")


def test_length_penalty_env_knob_defaults_and_bounds(monkeypatch) -> None:
    # 缺省/空串 → 0.0（冻结的联合对数概率排序，逐位不变）；合法
    # float 透传；非法值 fail-closed（评测环境里的 typo 不能静默
    # 重排 beam）。
    monkeypatch.delenv("RIMEAI_MLX_LENGTH_PENALTY", raising=False)
    assert _beam_length_penalty() == 0.0
    monkeypatch.setenv("RIMEAI_MLX_LENGTH_PENALTY", "")
    assert _beam_length_penalty() == 0.0
    monkeypatch.setenv("RIMEAI_MLX_LENGTH_PENALTY", "0.5")
    assert _beam_length_penalty() == 0.5
    monkeypatch.setenv("RIMEAI_MLX_LENGTH_PENALTY", "1.0")
    assert _beam_length_penalty() == 1.0
    for bad in ("abc", "-0.5", "5", "nan", "NaN", "inf", "-inf"):
        monkeypatch.setenv("RIMEAI_MLX_LENGTH_PENALTY", bad)
        with pytest.raises(MlxEngineError):
            _beam_length_penalty()


def test_handle_request_uses_startup_parsed_length_penalty(monkeypatch) -> None:
    # reveal A-F5：length_penalty 由 main() 启动期解析一次存入
    # engine，handle_request 与 stats 复用——不再逐请求读环境。旧代码
    # 在 typo 时 worker 存活却对每个请求抛错弃权（与 user-LM 启动期
    # exit(2) 的 fail-fast 不一致），stats 里还二次解析环境。
    monkeypatch.setenv("RIMEAI_MLX_LENGTH_PENALTY", "abc")  # 启动期即被拒
    engine = _engine()
    engine._length_penalty = 0.5  # main() 启动期解析后存入的合法值
    response = engine.handle_request(
        {
            "schema_version": 1,
            "task": "generate_sentence",
            "request_id": "r-lp",
            "context": "",
            "pinyin": "nihao",
            "candidates": ["你好"],
            "max_characters": 30,
            "stats": True,
        }
    )
    assert response["suggestion"] == "你好"
    assert response["stats"]["length_penalty"] == 0.5


def _request(**overrides: object) -> dict[str, object]:
    request: dict[str, object] = {
        "schema_version": 1,
        "task": "generate_sentence",
        "request_id": "req-1",
        "context": "前文",
        "pinyin": "nihao",
        "domain": "general",  # extra keys are tolerated
        "candidates": ["你好"],
        "max_characters": 30,
    }
    request.update(overrides)
    return request


def test_validate_accepts_canonical_request() -> None:
    (
        request_id,
        context,
        pinyin,
        candidates,
        max_characters,
        stats,
    ) = validate_generate_request(_request())
    assert (request_id, context, pinyin, candidates, max_characters) == (
        "req-1",
        "前文",
        "nihao",
        ["你好"],
        30,
    )
    assert stats is False


@pytest.mark.parametrize(
    "override",
    [
        {"schema_version": 2},
        {"task": "other"},
        {"request_id": ""},
        {"request_id": 7},
        {"context": 5},
        {"context": "文" * 401},
        {"pinyin": ""},
        {"pinyin": "a" * 257},
        {"pinyin": 42},
        {"candidates": []},
        {"candidates": ["a"] * 21},
        {"candidates": ["a", ""]},
        {"candidates": ["a", 3]},
        {"candidates": ["文" * 129]},
        {"max_characters": 0},
        {"max_characters": 31},
        {"max_characters": True},
        {"max_characters": "30"},
        {"stats": "yes"},
    ],
)
def test_validate_rejects_bound_violations(override: dict) -> None:
    with pytest.raises(GenerateRequestError):
        validate_generate_request(_request(**override))


def test_validate_rejects_non_object() -> None:
    with pytest.raises(GenerateRequestError):
        validate_generate_request([_request()])


def test_generate_response_envelope() -> None:
    plain = generate_response(
        request_id="r",
        suggestion="你好",
        confidence=0.5,
        model_artifact_id="artifact",
    )
    assert plain == {
        "schema_version": 1,
        "request_id": "r",
        "suggestion": "你好",
        "confidence": 0.5,
        "model_artifact_id": "artifact",
    }
    with_stats = generate_response(
        request_id="r",
        suggestion="",
        confidence=0.0,
        model_artifact_id="artifact",
        stats={"cache_fed_tokens": 3},
    )
    assert with_stats["stats"] == {"cache_fed_tokens": 3}
    # reveal C-F1：口径标记是可选字段——显式传入才出现（旧客户端按
    # 字段读取，不受影响；缺省 = 旧产物/未知口径）。
    with_marker = generate_response(
        request_id="r",
        suggestion="你好",
        confidence=0.5,
        model_artifact_id="artifact",
        confidence_caliber=CONFIDENCE_CALIBER_MASK_RENORM,
    )
    assert (
        with_marker["confidence_caliber"]
        == "mask-renormalized-geometric-mean"
    )
    assert "confidence_caliber" not in plain


def test_handle_request_declares_mask_renormalized_caliber() -> None:
    # reveal C-F1：第二批把 confidence 从 RAW softmax 几何平均换成
    # 掩码内归一化口径，但 wire 字段名/schema_version 未变——新旧
    # 产物不可区分。信封现在自声明口径。
    engine = _engine()
    response = engine.handle_request(
        {
            "schema_version": 1,
            "task": "generate_sentence",
            "request_id": "r-caliber",
            "context": "",
            "pinyin": "nihao",
            "candidates": ["你好"],
            "max_characters": 30,
        }
    )
    assert response["suggestion"] == "你好"
    assert (
        response["confidence_caliber"]
        == "mask-renormalized-geometric-mean"
    )


# --------------------------------------------------------------------------
# reveal 修复轮：A-F4 per-request 兜底 / C-F7 请求后回滚


def test_handle_request_line_fails_closed_on_internal_error() -> None:
    # reveal A-F4：缓存合同违约/内部异常不再崩掉 worker——回空建议
    # （fail-closed 弃权），进程继续服务；协议级错误仍退出。
    class _ExplodingEngine:
        def handle_request(self, request: dict) -> dict:
            raise RuntimeError("cache contract violation")

    class _ProtocolEngine:
        def handle_request(self, request: dict) -> dict:
            raise GenerateRequestError("bad request shape")

    response = handle_request_line(
        _ExplodingEngine(), json.dumps(dict(_request()))
    )
    assert response is not None
    assert response["suggestion"] == ""
    assert response["confidence"] == 0.0
    assert response["request_id"] == "req-1"
    assert response["model_artifact_id"] == model_artifact_id()
    # fail-closed 兜底信封同样自声明口径（worker 恒为掩码内归一化）。
    assert response["confidence_caliber"] == "mask-renormalized-geometric-mean"

    with pytest.raises(GenerateRequestError):
        handle_request_line(
            _ProtocolEngine(), json.dumps(dict(_request()))
        )
    assert handle_request_line(_ExplodingEngine(), "not json") is None


def test_post_request_rollback_releases_beam_tail_rows() -> None:
    # reveal C-F7：请求结束后共享缓存回滚到 seed+context 端点——
    # beam 尾行/KV 不跨请求常驻，seed+context 行保留供下一请求复用。
    backend = _KvSimulatingBackend()
    cache = PrefixRollbackCache(backend)
    seed = [1773, 9, 40]
    scorer = _SeedPathScorer(cache, seed)
    # 一次"请求"：seed + context + 若干 beam 路径。
    for path in ([11, 4, 7, 2], [11, 7, 2, 5, 6]):
        scorer(path)
    # 缓存停在最后一个 beam 路径的末端（seed + 最长路径）。
    assert len(cache.tokens) == len(seed) + 5
    # handle_request 的收尾回滚：distribution(seed) 恰是纯裁剪。
    stats_before = dict(cache.stats)
    cache.distribution(seed)
    assert cache.tokens == seed
    # 回滚发生在 stats 快照之后：请求内遥测不受收尾影响。
    assert cache.stats["cache_trim_operations"] == (
        stats_before["cache_trim_operations"] + 1
    )
    # 下一请求从 seed 端点继续：只需喂自己的增量。
    scorer([11, 4])
    assert backend.feed_deltas[-1] == [11, 4]


# --------------------------------------------------------------------------
# 音节切分兜底：guard.segment 失败时改用通用词典切分（可完整铺满才用），
# 不再退成 PinyinTokenIndex 无法匹配的 [整串]。


class _VocabTokenizer:
    """decode/encode 双向都覆盖的最小 tokenizer（含 seed "。"）。"""

    def __init__(self, texts: list[str]) -> None:
        self.vocab_size = len(texts)
        self._texts = list(texts)

    def decode(self, ids: list[int]) -> str:
        return self._texts[ids[0]]

    def encode(self, text: str) -> list[int]:
        # 逐字符查表；未登录字符（如 context 里的 前文）落到 <pad>。
        return [self._texts.index(ch) if ch in self._texts else 0 for ch in text]


class _FlatDistributionBackend(_KvSimulatingBackend):
    """固定分布后端：id 越小概率越高，decode 路径确定可断言。"""

    def softmax(self, row: tuple[int, ...]) -> dict[int, float]:
        return {1: 0.9, 2: 0.85, 3: 0.8, 4: 0.75, 5: 0.7, 6: 0.65, 7: 0.6}


def _engine() -> MlxConstrainedEngine:
    # 不触发 mlx 导入：手工装配 handle_request 用到的全部成员。
    tokenizer = _VocabTokenizer(
        ["<pad>", "你", "好", "的", "世", "界", "。", "<eos>"]
    )
    guard = PinyinGuard(
        {
            "你": frozenset({"ni"}),
            "好": frozenset({"hao"}),
            "的": frozenset({"de"}),
            "世": frozenset({"shi"}),
            "界": frozenset({"jie"}),
        }
    )
    engine = object.__new__(MlxConstrainedEngine)
    engine._tokenizer = tokenizer
    engine.guard = guard
    engine.index = PinyinTokenIndex.build(tokenizer, guard)
    engine.cache = PrefixRollbackCache(_FlatDistributionBackend())
    return engine


def test_handle_request_segment_success_keeps_guard_segmentation() -> None:
    # candidates[0] 自身读音即可铺满拼音 → 走 guard.segment，行为不变。
    engine = _engine()
    response = engine.handle_request(
        {
            "schema_version": 1,
            "task": "generate_sentence",
            "request_id": "r-1",
            "context": "",
            "pinyin": "nihaode",
            "candidates": ["你好的"],
            "max_characters": 30,
        }
    )
    assert response["suggestion"] == "你好的"
    assert response["request_id"] == "r-1"


def test_handle_request_segment_failure_uses_generic_syllables() -> None:
    # candidates[0]（你好）铺不满 nihaode → guard.segment None；旧逻辑退
    # ["nihaode"] 整串后 decode 必空建议；新逻辑拿到合法音节序列
    # ["ni", "hao", "de"] 并解出 你好的。
    engine = _engine()
    response = engine.handle_request(
        {
            "schema_version": 1,
            "task": "generate_sentence",
            "request_id": "r-2",
            "context": "",
            "pinyin": "nihaode",
            "candidates": ["你好"],
            "max_characters": 30,
        }
    )
    assert response["suggestion"] == "你好的"
    assert 0.0 < response["confidence"] <= 1.0
    # 请求后缓存回滚到 seed 端点（收尾流程未被 fallback 改动）。
    assert engine.cache.tokens == engine._tokenizer.encode(SEED_CONTEXT)


def test_handle_request_generic_failure_keeps_whole_string_fallback() -> None:
    # 通用切分也铺不满 zzzz → 维持原 [整串] 行为：空建议。
    engine = _engine()
    response = engine.handle_request(
        {
            "schema_version": 1,
            "task": "generate_sentence",
            "request_id": "r-3",
            "context": "",
            "pinyin": "zzzz",
            "candidates": ["你好"],
            "max_characters": 30,
        }
    )
    assert response["suggestion"] == ""
    assert response["confidence"] == 0.0


def test_handle_request_generic_syllables_pass_fuzzy_gate_and_report_stats() -> None:
    # 带 context 与 stats 的完整流程：fallback 得到的音节序列要通过
    # fuzzy gate（世界 = shi+jie），且 stats 快照先于收尾回滚。
    engine = _engine()
    response = engine.handle_request(
        {
            "schema_version": 1,
            "task": "generate_sentence",
            "request_id": "r-4",
            "context": "前文",
            "pinyin": "shijie",
            "candidates": ["你好"],
            "max_characters": 30,
            "stats": True,
        }
    )
    assert response["suggestion"] == "世界"
    assert "cache_fed_tokens" in response["stats"]
    # 双口径遥测：stats.confidence_raw 携带旧 RAW 口径，主字段
    # confidence 是掩码内归一化口径；length_penalty 记录当次旋钮。
    assert "confidence_raw" in response["stats"]
    assert response["stats"]["length_penalty"] == 0.0
    assert 0.0 < response["confidence"] <= 1.0
    assert 0.0 <= response["stats"]["confidence_raw"] <= 1.0
    assert engine.cache.tokens == engine._tokenizer.encode(SEED_CONTEXT) + engine._tokenizer.encode(
        "前文"
    )


# --------------------------------------------------------------------------
# L2 用户 LM 浅融合接线：环境旋钮 fail-closed，λ=0 逐位不变，
# 融合只改打分不动 KV cache 正确性。


def _save_user_lm(tmp_path, texts_by_domain):
    from rimeai_daemon.user_lm import UserLanguageModel
    from rimeai_runtime.user_lm_view import UserLanguageModelView

    model = UserLanguageModel()
    for domain, texts in texts_by_domain.items():
        model.update(domain, texts)
    artifact = tmp_path / "user-lm.json.gz"
    model.save(artifact)
    return UserLanguageModelView.load(artifact)


def test_user_lm_fusion_config_defaults_off(monkeypatch):
    monkeypatch.delenv("RIMEAI_MLX_USER_LM_PATH", raising=False)
    monkeypatch.delenv("RIMEAI_MLX_USER_LM_WEIGHT", raising=False)
    assert _user_lm_fusion_config() == (None, 0.0)
    # 空串视为未设置。
    monkeypatch.setenv("RIMEAI_MLX_USER_LM_PATH", "")
    monkeypatch.setenv("RIMEAI_MLX_USER_LM_WEIGHT", "")
    assert _user_lm_fusion_config() == (None, 0.0)


def test_user_lm_fusion_config_valid_pair(tmp_path, monkeypatch):
    view = _save_user_lm(tmp_path, {None: ["世界"] * 10})
    monkeypatch.setenv("RIMEAI_MLX_USER_LM_PATH", str(tmp_path / "user-lm.json.gz"))
    monkeypatch.setenv("RIMEAI_MLX_USER_LM_WEIGHT", "0.35")
    loaded, weight = _user_lm_fusion_config()
    assert weight == 0.35
    assert loaded is not None
    assert loaded.mean_log_prob("", "世界") == view.mean_log_prob("", "世界")
    # λ=0 也校验 artifact 本身（合法配置，仅融合不激活）。
    monkeypatch.setenv("RIMEAI_MLX_USER_LM_WEIGHT", "0.0")
    loaded_zero, weight_zero = _user_lm_fusion_config()
    assert loaded_zero is not None
    assert weight_zero == 0.0


@pytest.mark.parametrize(
    "path_value,weight_value",
    [
        ("/nonexistent/user-lm.json.gz", "0.2"),  # 路径不存在
        ("", "0.2"),  # 只有权重
        ("/some/path", ""),  # 只有路径
        ("/some/path", None),  # 路径设了权重未设
        (None, "0.2"),  # 权重设了路径未设
    ],
)
def test_user_lm_fusion_config_half_set_or_missing_fails_closed(
    tmp_path, monkeypatch, path_value, weight_value
):
    monkeypatch.delenv("RIMEAI_MLX_USER_LM_PATH", raising=False)
    monkeypatch.delenv("RIMEAI_MLX_USER_LM_WEIGHT", raising=False)
    if path_value is not None:
        monkeypatch.setenv("RIMEAI_MLX_USER_LM_PATH", path_value)
    if weight_value is not None:
        monkeypatch.setenv("RIMEAI_MLX_USER_LM_WEIGHT", weight_value)
    with pytest.raises(MlxEngineError):
        _user_lm_fusion_config()


@pytest.mark.parametrize(
    "weight_value",
    ["abc", "-0.1", "1.5", "nan", "inf"],
)
def test_user_lm_fusion_config_invalid_weight_fails_closed(
    tmp_path, monkeypatch, weight_value
):
    _save_user_lm(tmp_path, {None: ["世界"] * 5})
    monkeypatch.setenv("RIMEAI_MLX_USER_LM_PATH", str(tmp_path / "user-lm.json.gz"))
    monkeypatch.setenv("RIMEAI_MLX_USER_LM_WEIGHT", weight_value)
    with pytest.raises(MlxEngineError):
        _user_lm_fusion_config()


def test_user_lm_fusion_config_corrupt_artifact_fails_closed(tmp_path, monkeypatch):
    artifact = tmp_path / "broken.json.gz"
    artifact.write_bytes(b"not gzip at all")
    monkeypatch.setenv("RIMEAI_MLX_USER_LM_PATH", str(artifact))
    monkeypatch.setenv("RIMEAI_MLX_USER_LM_WEIGHT", "0.2")
    with pytest.raises(MlxEngineError):
        _user_lm_fusion_config()


class _ShijieBackend(_KvSimulatingBackend):
    """固定分布：试(shi) 0.95 自信胜出，世/界低分。"""

    def softmax(self, row: tuple[int, ...]) -> dict[int, float]:
        return {4: 0.4, 5: 0.5, 8: 0.95}


def _fusion_engine(tmp_path, view, weight) -> MlxConstrainedEngine:
    tokenizer = _VocabTokenizer(
        ["<pad>", "你", "好", "的", "世", "界", "。", "<eos>", "试"]
    )
    guard = PinyinGuard(
        {
            "你": frozenset({"ni"}),
            "好": frozenset({"hao"}),
            "的": frozenset({"de"}),
            "世": frozenset({"shi"}),
            "界": frozenset({"jie"}),
            "试": frozenset({"shi"}),
        }
    )
    engine = object.__new__(MlxConstrainedEngine)
    engine._tokenizer = tokenizer
    engine.guard = guard
    engine.index = PinyinTokenIndex.build(tokenizer, guard)
    engine.cache = PrefixRollbackCache(_ShijieBackend())
    engine._user_lm = view
    engine._user_weight = weight
    return engine


def _fusion_request(request_id="r-fusion"):
    return {
        "schema_version": 1,
        "task": "generate_sentence",
        "request_id": request_id,
        "context": "",
        "pinyin": "shijie",
        "candidates": ["世界"],
        "max_characters": 30,
        "stats": True,
    }


def test_handle_request_without_fusion_keeps_baseline(tmp_path):
    # 无融合：试(shi p=0.95) 自信胜出 → 试界。
    engine = _fusion_engine(tmp_path, None, 0.0)
    response = engine.handle_request(_fusion_request())
    assert response["suggestion"] == "试界"
    assert response["stats"]["user_lm_weight"] == 0.0


def test_handle_request_fusion_reranks_toward_user_evidence(tmp_path):
    # 融合（λ=0.35）：用户 LM 只见过 世界，试 的逐字 log 概率极低，
    # fused 排序翻转为 世界——掩码合法性（fuzzy gate）原样通过。
    view = _save_user_lm(tmp_path, {None: ["世界"] * 500})
    engine = _fusion_engine(tmp_path, view, 0.35)
    response = engine.handle_request(_fusion_request("r-fused"))
    assert response["suggestion"] == "世界"
    assert 0.0 < response["confidence"] <= 1.0
    assert response["stats"]["user_lm_weight"] == 0.35
    # KV cache：浅融合不改 scorer 调用路径，请求后仍回滚到 seed 端点。
    assert engine.cache.tokens == engine._tokenizer.encode(SEED_CONTEXT)


def test_handle_request_fusion_weight_zero_is_bit_identical(tmp_path):
    # λ=0（同一 view 已加载）：响应与无融合基线逐位一致（含 stats 数字）。
    view = _save_user_lm(tmp_path, {None: ["世界"] * 500})
    baseline = _fusion_engine(tmp_path, None, 0.0)
    zero = _fusion_engine(tmp_path, view, 0.0)
    request = _fusion_request("r-zero")
    assert zero.handle_request(request) == baseline.handle_request(request)


def test_handle_request_fusion_context_feeds_user_lm(tmp_path):
    # 融合上下文 = seed("。") + request context + 已生成文本：把训练语料
    # 换成 只在 前文=前文 时出现 的 世界，验证 context 进入打分。
    view = _save_user_lm(tmp_path, {None: ["前文世界"] * 500})
    engine = _fusion_engine(tmp_path, view, 0.35)
    request = _fusion_request("r-ctx")
    request["context"] = "前文"
    response = engine.handle_request(request)
    assert response["suggestion"] == "世界"
