"""MLX constrained worker: protocol bounds, rollback-cache parity against
naive re-prefill, and persistent-prefix determinism — all with fake
backends, no mlx import (the repo venv does not carry mlx)."""

import json

import pytest

from rimeai_runtime.constrained_worker_protocol import (
    GenerateRequestError,
    generate_response,
    validate_generate_request,
)
from rimeai_runtime.mlx_worker import (
    BEAM_WIDTH,
    SEED_CONTEXT,
    PrefixRollbackCache,
    RollbackBackend,
    _SeedPathScorer,
    common_prefix_length,
    handle_request_line,
    model_artifact_id,
)


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
