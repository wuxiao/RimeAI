"""只读用户 LM 视图：与 rimeai_daemon.user_lm 真实实现的打分逐项一致性，
以及 fail-closed 加载契约。"""

import gzip
import json
import math
from pathlib import Path

import pytest

from rimeai_daemon.user_lm import DomainCounts, UserLanguageModel
from rimeai_runtime.user_lm_view import (
    BACKOFF_ALPHA,
    DomainCountsView,
    UserLanguageModelView,
    UserLmViewError,
)


def _train_model() -> UserLanguageModel:
    model = UserLanguageModel()
    model.update("developer", ["接口设计文档"] * 30 + ["数据库连接池"] * 12)
    model.update(None, ["今天天气很好", "明天下雨"] * 40)
    model.update("chat", ["帮我看看这个报错"] * 9)
    return model


_CONTEXTS = [
    "",
    "接口",
    "给我讲讲",
    "数据库",
    "帮我",
    "今天",
    "明天下",
    "接口设计文",
    "乱码上下文xyz",
    "很长的前文" * 12,
]
_TEXTS = [
    "接口设计",
    "接口测试",
    "接口设计文档",
    "数据库连接",
    "数据库连接池",
    "天气",
    "下雨",
    "报错",
    "这个",
    "a",
    "接口设计文档数据库连接池",
    "今天的明天下雨接口设计",
]
_DOMAINS = ["global", "developer", "chat", "unknown-domain", ""]


def _save_artifact(model: UserLanguageModel, path: Path) -> Path:
    model.save(path)
    return path


def test_view_matches_daemon_mean_log_prob_exactly(tmp_path):
    # 同一 artifact、同一批 context+text+domain 下，视图与 daemon
    # 真实实现的 mean_log_prob 打分逐项相等（bit 级，非 approx）。
    model = _train_model()
    artifact = _save_artifact(model, tmp_path / "user-lm.json.gz")
    view = UserLanguageModelView.load(artifact)
    compared = 0
    for domain in _DOMAINS:
        for context in _CONTEXTS:
            for text in _TEXTS:
                expected = model.mean_log_prob(context, text, domain)
                actual = view.mean_log_prob(context, text, domain)
                assert actual == expected, (domain, context, text)
                compared += 1
    assert compared == len(_DOMAINS) * len(_CONTEXTS) * len(_TEXTS)
    # 至少覆盖了有证据、无证据与 fallback 三类路径。
    assert view.mean_log_prob("接口", "接口设计文档", "developer") is not None
    assert view.mean_log_prob("接口", "接口设计文档", "unknown-domain") is not None
    empty = UserLanguageModelView()
    assert empty.mean_log_prob("接口", "接口设计") is None


def test_view_conditional_prob_matches_daemon_domain_counts(tmp_path):
    # DomainCounts 层逐字符对拍：覆盖高阶命中、逐级回退、终端 add-k
    # 与无证据四种分支。
    counts = DomainCounts()
    for text in ["接口设计文档", "数据库连接池", "接口设计", "接口"]:
        counts.observe(text)
    payload = counts.to_payload()
    view_counts = DomainCountsView.from_payload(payload)
    characters = [ch for text in _TEXTS[:8] for ch in text] + ["^", "$", "z"]
    for history in _CONTEXTS:
        for character in characters:
            expected = counts.conditional_prob(history, character)
            actual = view_counts.conditional_prob(history, character)
            assert actual == expected, (history, character)
    assert counts.conditional_prob("接口", "设") == pytest.approx(
        (counts.ngram_counts[4]["^接口设"] / counts.prefix_counts[4]["^接口"])
        * BACKOFF_ALPHA ** (5 - 4)
    )


def test_view_scores_empty_model_as_daemon_does(tmp_path):
    # 无任何证据的 artifact（domains 为空）与 daemon 空模型行为一致。
    model = UserLanguageModel()
    artifact = _save_artifact(model, tmp_path / "empty-user-lm.json.gz")
    view = UserLanguageModelView.load(artifact)
    for context in _CONTEXTS[:3]:
        for text in _TEXTS[:3]:
            assert view.mean_log_prob(context, text) is None
            assert model.mean_log_prob(context, text) is None


def test_view_loads_v1_schema_artifact_without_folded_tokens(tmp_path):
    # v1 载荷没有 folded_tokens：把 v2 存量降级成 v1 再读，打分不变。
    model = _train_model()
    artifact = _save_artifact(model, tmp_path / "v2.json.gz")
    with gzip.open(artifact, "rt", encoding="utf-8") as handle:
        payload = json.load(handle)
    payload["schema_version"] = 1
    for domain_payload in payload["domains"].values():
        domain_payload.pop("folded_tokens", None)
    v1_path = tmp_path / "v1.json.gz"
    v1_path.write_bytes(
        gzip.compress(json.dumps(payload, ensure_ascii=False).encode("utf-8"))
    )
    view = UserLanguageModelView.load(v1_path)
    for domain in ("global", "developer"):
        for context in ("接口", "今天", ""):
            for text in ("接口设计文档", "天气"):
                assert view.mean_log_prob(context, text, domain) == (
                    model.mean_log_prob(context, text, domain)
                )


def test_log_prob_sum_is_summed_per_character_terms(tmp_path):
    # 融合口径：sum = 逐字符 log p 之和（mean * len 的恒等关系只在
    # 数学上成立，bit 级上 sum 就是各项之和本身）。
    model = _train_model()
    artifact = _save_artifact(model, tmp_path / "user-lm.json.gz")
    view = UserLanguageModelView.load(artifact)
    context, text = "接口", "接口设计文档"
    expected = 0.0
    for index, character in enumerate(text):
        probability = view.domain_counts("developer").conditional_prob(
            context + text[:index], character
        )
        assert probability is not None
        expected += math.log(probability)
    fused_sum = view.log_prob_sum(context, text, "developer")
    assert fused_sum is not None
    assert fused_sum == expected
    # 恒 <= 0（概率 <= 1），且 None 语义与 mean 口径一致。
    assert fused_sum <= 0.0
    empty = UserLanguageModelView()
    assert empty.log_prob_sum(context, text) is None


@pytest.mark.parametrize(
    "corrupt",
    [
        "missing",
        "not-gzip",
        "not-json",
        "bad-schema",
        "bad-model-type",
        "bad-domains",
        "bad-domain-payload",
    ],
)
def test_view_load_fails_closed(tmp_path, corrupt):
    # 一切加载失败都 fail-closed：绝不静默降级成空模型。
    path = tmp_path / "user-lm.json.gz"
    if corrupt == "missing":
        pass
    elif corrupt == "not-gzip":
        path.write_bytes(b"definitely not gzip")
    elif corrupt == "not-json":
        path.write_bytes(gzip.compress(b"{not json"))
    else:
        model = _train_model()
        model.save(path)
        with gzip.open(path, "rt", encoding="utf-8") as handle:
            payload = json.load(handle)
        if corrupt == "bad-schema":
            payload["schema_version"] = 99
        elif corrupt == "bad-model-type":
            payload["model_type"] = "something-else"
        elif corrupt == "bad-domains":
            payload["domains"] = []
        elif corrupt == "bad-domain-payload":
            payload["domains"]["global"] = {"ngram_counts": {}}
        path.write_bytes(
            gzip.compress(json.dumps(payload, ensure_ascii=False).encode("utf-8"))
        )
    with pytest.raises(UserLmViewError):
        UserLanguageModelView.load(path)


def test_view_exposes_no_write_surface(tmp_path):
    # 只读视图：没有 save/update/fold，也不会改动 artifact 字节。
    model = _train_model()
    artifact = _save_artifact(model, tmp_path / "user-lm.json.gz")
    before = artifact.read_bytes()
    view = UserLanguageModelView.load(artifact)
    assert not hasattr(view, "save")
    assert not hasattr(view, "update")
    assert not hasattr(view, "fold")
    view.mean_log_prob("接口", "接口设计文档", "developer")
    assert artifact.read_bytes() == before


def test_view_domains_listing_matches_daemon(tmp_path):
    model = _train_model()
    artifact = _save_artifact(model, tmp_path / "user-lm.json.gz")
    view = UserLanguageModelView.load(artifact)
    assert view.domains() == model.domains()
