"""Tests for the L2 user character n-gram language model (LP-003)."""

import math
from pathlib import Path

import pytest

from rimeai_daemon.user_lm import (
    BACKOFF_ALPHA,
    MAX_USER_WEIGHT,
    PRIOR_CHARACTERS,
    SMOOTHING_DENOMINATOR,
    SMOOTHING_NUMERATOR,
    DomainCounts,
    UserLanguageModel,
    UserLMError,
)


def test_cold_start_keeps_baseline_order():
    model = UserLanguageModel()
    candidates = ["索引", "所以", "缩印"]
    ranked, confidence = model.rerank("给数据库加个", candidates)
    assert ranked == candidates
    assert confidence == 0.0


def test_learned_phrase_outranks_unrelated_candidates():
    model = UserLanguageModel()
    model.update(None, ["接口设计文档"] * 200)
    ranked, confidence = model.rerank(
        "接口", ["接口设计图", "接口设计", "接口测试"]
    )
    assert ranked[0] == "接口设计"
    assert confidence > 0.0


def test_per_commit_gram_cap_bounds_single_phrase_influence():
    capped = UserLanguageModel()
    capped.update(None, ["重复短语"] * 5)
    gram = "重复"
    counts = capped._domains["global"].ngram_counts[2][gram]

    # One commit whose text repeats the same gram three times contributes
    # at most the per-commit cap of two.
    flooded = UserLanguageModel()
    flooded.update(None, ["重复重复重复"])
    flooded_counts = flooded._domains["global"].ngram_counts[2][gram]

    assert flooded_counts == 2
    assert counts == 5


def test_weights_shrink_and_stay_under_cap():
    model = UserLanguageModel()
    model.update(None, ["字" * 100])
    global_weight, domain_weight = model.user_weights("work")
    assert global_weight == pytest.approx(
        100 / (100 + PRIOR_CHARACTERS), rel=1e-6
    )
    assert domain_weight == 0.0

    model.update("work", ["领域字" * 200])
    global_weight, domain_weight = model.user_weights("work")
    assert global_weight > 0
    assert domain_weight > 0
    assert global_weight + domain_weight <= MAX_USER_WEIGHT + 1e-9


def test_domain_data_only_uses_domain_for_its_domain():
    model = UserLanguageModel()
    model.update("chat", ["聊天口头禅"] * 300)
    # The chat domain has evidence; an unmapped-heavy domain has none and
    # falls back to global (also empty) -> baseline order.
    ranked, confidence = model.rerank(
        "聊天", ["聊天记录", "聊天口头禅"], domain="work"
    )
    assert ranked == ["聊天记录", "聊天口头禅"]
    assert confidence == 0.0

    chat_ranked, chat_confidence = model.rerank(
        "聊天", ["聊天记录", "聊天口头禅"], domain="chat"
    )
    assert chat_ranked[0] == "聊天口头禅"
    assert chat_confidence > 0.0


def test_empty_inputs_are_safe():
    model = UserLanguageModel()
    model.update(None, ["文本"])
    ranked, confidence = model.rerank("上下文", [])
    assert ranked == []
    assert confidence == 0.0
    model.update(None, [])
    model.update("work", ["", "  "])


def test_save_load_round_trip_preserves_scores(tmp_path: Path):
    path = tmp_path / "language_profile" / "user-lm.json.gz"
    model = UserLanguageModel()
    model.update(None, ["全局习惯文本"] * 120)
    model.update("work", ["工作习惯文本"] * 120)
    model.save(path)

    restored = UserLanguageModel.load(path)
    assert sorted(restored.domains()) == ["global", "work"]
    original = model.rerank("习惯", ["习惯文本图", "习惯文本"], domain="work")
    replayed = restored.rerank("习惯", ["习惯文本图", "习惯文本"], domain="work")
    assert replayed == original


def test_load_missing_file_returns_fresh_model(tmp_path: Path):
    model = UserLanguageModel.load(tmp_path / "absent.json.gz")
    assert model.domains() == []


def test_load_rejects_foreign_artifacts(tmp_path: Path):
    path = tmp_path / "foreign.json.gz"
    path.write_bytes(b"not json at all")
    with pytest.raises(UserLMError):
        UserLanguageModel.load(path)


def test_conditional_prob_uses_backoff():
    counts = DomainCounts()
    counts.observe("世界")
    # High-order grams bridging the unseen context are absent, so the
    # seen bigram backs off: MLE_2 * alpha ** (5 - 2).
    assert counts.conditional_prob("天气好世", "界") == pytest.approx(
        (1 / 1) * BACKOFF_ALPHA**3
    )
    # A fully unseen bigram falls to the terminal add-k branch, which is
    # always finite and positive.
    assert counts.conditional_prob("零零", "七") == pytest.approx(
        SMOOTHING_NUMERATOR / SMOOTHING_DENOMINATOR * BACKOFF_ALPHA**3
    )


def test_conditional_prob_none_when_domain_empty():
    counts = DomainCounts()
    assert counts.conditional_prob("上下", "文") is None


def test_mean_log_prob_unchanged_semantics():
    counts = DomainCounts()
    counts.observe("接口设计文档")
    context, candidate = "接口", "接口设计"
    per_position = [
        counts.conditional_prob(context + candidate[:index], character)
        for index, character in enumerate(candidate)
    ]
    assert all(prob is not None for prob in per_position)
    expected = sum(math.log(prob) for prob in per_position) / len(candidate)
    assert counts.mean_log_prob(context, candidate) == pytest.approx(expected)

    # A trained domain with zero relevant counts still yields a finite
    # smoothed score rather than None.
    unrelated = counts.mean_log_prob("完全无关", "别的文本")
    assert unrelated is not None and math.isfinite(unrelated)

    # An empty candidate has no positions to average over.
    assert counts.mean_log_prob("接口", "") is None


def test_mean_log_prob_public_scorer_prefers_domain_then_global():
    # Task 4 handoff: public scorer surface. A trained domain wins over an
    # empty global; an untrained domain falls back to global; with no
    # evidence at all it reports None.
    model = UserLanguageModel()
    assert model.mean_log_prob("接口", "接口设计") is None

    model.update(None, ["接口设计文档"] * 50)
    global_score = model.mean_log_prob("接口", "接口设计")
    assert global_score is not None and global_score < 0

    model.update("work", ["工作术语文本"] * 50)
    work_score = model.mean_log_prob("工作", "工作术语", domain="work")
    assert work_score is not None
    # An untrained domain falls back to the global pseudo-domain; a
    # trained one answers with its own (smoothed) evidence.
    fallback = model.mean_log_prob("接口", "接口设计", domain="chat")
    assert fallback == pytest.approx(global_score, rel=1e-12)
