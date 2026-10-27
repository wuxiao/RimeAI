import json
from types import SimpleNamespace
from typing import Any

import pytest

from rimeai_daemon.engine import LocalInferenceEngine
from rimeai_runtime.beam_decoder import BeamSentenceDecoder
from rimeai_runtime.neural_ranker import GLOBAL_NORM_METHOD, HybridSemanticRanker
from rimeai_runtime.ranking import RankerError


class _Ranker:
    def __init__(self, ranking, confidence):
        self.ranking = ranking
        self.confidence = confidence

    def rank(self, *, context, candidates):
        return self.ranking, self.confidence


class _SentenceDecoder:
    def __init__(
        self,
        text="",
        confidence=0.0,
        reason="no_change",
        segment_text=None,
        segment_confidence=0.0,
        segment_reason="no_change",
    ):
        self.result = SimpleNamespace(
            text=text,
            confidence=confidence,
            reason=reason,
        )
        self.segment_text = segment_text
        self.segment_confidence = segment_confidence
        self.segment_reason = segment_reason
        self.calls = []
        self.segment_calls = []

    def suggest(self, *, context, pinyin, candidates):
        self.calls.append((context, pinyin, list(candidates)))
        return self.result

    def suggest_segments(self, *, context, segments, active_candidates):
        self.segment_calls.append(
            (context, list(segments), list(active_candidates))
        )
        return SimpleNamespace(
            text=self.segment_text,
            confidence=self.segment_confidence,
            reason=self.segment_reason,
        )


def _engine(
    ranking,
    confidence,
    *,
    sentence="",
    sentence_confidence=0.0,
    sentence_reason="no_change",
    segment="",
    segment_confidence=0.0,
    segment_reason="no_change",
    t2s_converter=None,
):
    engine: Any = LocalInferenceEngine.__new__(LocalInferenceEngine)
    engine._ranker = _Ranker(ranking, confidence)
    engine._sentence_decoder = _SentenceDecoder(
        sentence,
        sentence_confidence,
        sentence_reason,
        segment_text=segment,
        segment_confidence=segment_confidence,
        segment_reason=segment_reason,
    )
    engine._ranker_min_confidence = 0.55
    engine._user_lm_path = None
    engine._user_lm = None
    engine._user_lm_mtime = None
    engine._user_lm_size = None
    engine._t2s_converter = t2s_converter
    return engine


def _request(*, allow_sentence=False):
    return {
        "context": "请执行这条",
        "pinyin": "mingling",
        "candidates": ["明令", "命令"],
        "allow_sentence": allow_sentence,
    }


def test_engine_reports_ranked_candidate_decision():
    result = _engine(["命令", "明令"], 0.91).infer(_request())

    assert result["decision"] == "ranked_candidate"
    assert result["ranked_candidate"] == "命令"


def test_engine_reports_same_top_candidate_as_a_successful_decision():
    result = _engine(["明令", "命令"], 0.88).infer(_request())

    assert result["decision"] == "same_top_candidate"
    assert result["ranked_candidate"] == ""


def test_engine_does_not_claim_agreement_when_only_one_candidate_is_comparable():
    candidates = [
        "附近服务为",
        "放进去",
        "风景区",
        "否决权",
        "飞进去",
        "范家满",
        "复决权",
    ]
    request = _request()
    request["pinyin"] = "fjfww"
    request["candidates"] = candidates

    result = _engine(candidates, 1.0).infer(request)

    assert result["decision"] == "insufficient_candidates"
    assert result["ranked_candidate"] == ""
    assert result["sentence_suggestion"] == ""
    assert result["confidence"] == 0.0


def test_sentence_suggestion_can_recover_an_insufficient_candidate_pool():
    candidates = [
        "附近服务为",
        "放进去",
        "风景区",
        "否决权",
        "飞进去",
        "范家满",
        "复决权",
    ]
    request = _request(allow_sentence=True)
    request["pinyin"] = "fjfww"
    request["candidates"] = candidates

    result = _engine(
        candidates,
        1.0,
        sentence="附近服务网",
        sentence_confidence=0.60,
    ).infer(request)

    assert result["decision"] == "sentence_suggestion"
    assert result["ranked_candidate"] == ""
    assert result["sentence_suggestion"] == "附近服务网"
    assert result["confidence"] == 0.60


def test_too_long_sentence_abstains_instead_of_returning_a_ranked_fragment():
    result = _engine(
        ["命令", "明令"],
        0.91,
        sentence_reason="too_long",
    ).infer(_request(allow_sentence=True))

    assert result["decision"] == "sentence_too_long"
    assert result["ranked_candidate"] == ""
    assert result["sentence_suggestion"] == ""
    assert result["confidence"] == 0.0


def test_incomplete_sentence_keeps_a_confident_ranked_candidate():
    result = _engine(
        ["命令", "明令"],
        0.91,
        sentence_reason="incomplete_candidate",
    ).infer(_request(allow_sentence=True))

    assert result["decision"] == "ranked_candidate"
    assert result["ranked_candidate"] == "命令"
    assert result["sentence_suggestion"] == ""
    assert result["confidence"] == 0.91


def test_incomplete_sentence_abstains_without_a_ranked_candidate():
    result = _engine(
        ["明令", "命令"],
        0.54,
        sentence_reason="incomplete_candidate",
    ).infer(_request(allow_sentence=True))

    assert result["decision"] == "sentence_incomplete"
    assert result["ranked_candidate"] == ""
    assert result["sentence_suggestion"] == ""
    assert result["confidence"] == 0.0


def test_incomplete_sentence_abstains_on_a_same_top_candidate():
    result = _engine(
        ["明令", "命令"],
        0.88,
        sentence_reason="incomplete_candidate",
    ).infer(_request(allow_sentence=True))

    assert result["decision"] == "sentence_incomplete"
    assert result["ranked_candidate"] == ""
    assert result["confidence"] == 0.0


def test_engine_reports_below_confidence_instead_of_an_empty_rejection():
    result = _engine(["命令", "明令"], 0.54).infer(_request())

    assert result["decision"] == "below_confidence"
    assert result["ranked_candidate"] == ""


# --- reveal B-F1：calibrated threshold 即放行门 -------------------------
# 用真实 HybridSemanticRanker（v2 单位仿射归一 + w=0.5）精确固定 fused
# margin：neural=[0,0]、ngram=[0, margin/w] → fused=[0, margin]，候选 1
# （"命令"）以精确 margin 翻转胜出，margin < 0 在排序后结构性不可出现。


class _FixedNeuralScores:
    model_artifact_id = "neural:test"
    cold_start_ms = 0.0

    def __init__(self, scores):
        self._fixed = list(scores)

    def _scores(self, **kwargs):
        return list(self._fixed)


class _FixedNGramScores:
    dataset_sha256 = "b" * 64

    def __init__(self, scores):
        self._fixed = list(scores)

    def _candidate_score(self, context, candidate, baseline_index):
        return self._fixed[baseline_index]


def _hybrid_gate_engine(tmp_path, margin, *, threshold=0.3):
    config = tmp_path / "fusion-gate.json"
    config.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "fusion_type": "rimeai-neural-ngram-v2",
                "artifact_id": "fusion:test-gate",
                "neural_weight": 0.5,
                "neural_artifact_id": "neural:test",
                "ngram_dataset_sha256": "b" * 64,
                "validation_dataset_sha256": "c" * 64,
                "decision": {
                    "margin_threshold": threshold,
                    "target_precision": 0.9,
                },
                "score_normalization": {
                    "method": GLOBAL_NORM_METHOD,
                    "neural_mean": 0.0,
                    "neural_std": 1.0,
                    "ngram_mean": 0.0,
                    "ngram_std": 1.0,
                },
            }
        ),
        encoding="utf-8",
    )
    ranker = HybridSemanticRanker(
        _FixedNeuralScores([0.0, 0.0]),
        _FixedNGramScores([0.0, 2.0 * margin]),
        config,
    )
    engine: Any = LocalInferenceEngine.__new__(LocalInferenceEngine)
    engine._ranker = ranker
    engine._sentence_decoder = _SentenceDecoder()
    engine._ranker_min_confidence = 0.55
    engine._user_lm_path = None
    engine._user_lm = None
    engine._user_lm_mtime = None
    engine._user_lm_size = None
    engine._t2s_converter = None
    return engine


@pytest.mark.parametrize(
    "ratio", [0.13, 0.5, 0.9, 0.999]
)
def test_engine_blocks_hybrid_flips_below_calibrated_threshold(tmp_path, ratio):
    # margin ∈ [0.1253τ, τ)：旧公式以 0.55~0.899 放行 → ranked_candidate；
    # 新映射 0.55·ratio < 0.55 → below_confidence。
    threshold = 0.3
    engine = _hybrid_gate_engine(tmp_path, ratio * threshold)

    result = engine.infer(_request())

    assert result["decision"] == "below_confidence"
    assert result["ranked_candidate"] == ""
    assert result["confidence"] == pytest.approx(0.55 * ratio)


@pytest.mark.parametrize("excess", [0.0, 0.15])
def test_engine_admits_hybrid_flips_at_or_above_calibrated_threshold(
    tmp_path, excess
):
    # margin ≥ τ：decision=ranked_candidate 的充要条件（same-top 之外）
    # 收窄为 margin ≥ τ，边界本身仍放行。
    threshold = 0.3
    engine = _hybrid_gate_engine(tmp_path, threshold + excess)

    result = engine.infer(_request())

    assert result["decision"] == "ranked_candidate"
    assert result["ranked_candidate"] == "命令"
    assert result["confidence"] >= 0.9


def test_engine_keeps_hybrid_same_top_decision(tmp_path):
    # 融合分持平（margin=0）→ 稳定排序回落原序 → same-top 语义不变。
    engine = _hybrid_gate_engine(tmp_path, 0.0)

    result = engine.infer(_request())

    assert result["decision"] == "same_top_candidate"
    assert result["confidence"] == 1.0


def test_sentence_suggestion_has_an_explicit_decision():
    result = _engine(
        ["命令", "明令"],
        0.7,
        sentence="请执行这条命令",
        sentence_confidence=0.98,
    ).infer(_request(allow_sentence=True))

    assert result["decision"] == "sentence_suggestion"
    assert result["sentence_suggestion"] == "请执行这条命令"
    assert result["ranked_candidate"] == ""


def test_sentence_suggestion_accepts_the_configured_point_six_confidence():
    result = _engine(
        ["明令", "命令"],
        0.7,
        sentence="请执行这条命令",
        sentence_confidence=0.60,
    ).infer(_request(allow_sentence=True))

    assert result["decision"] == "sentence_suggestion"
    assert result["sentence_suggestion"] == "请执行这条命令"
    assert result["confidence"] == 0.60


def test_low_confidence_sentence_does_not_override_ranked_candidate():
    result = _engine(
        ["命令", "明令"],
        0.99,
        sentence="请执行这条命令",
        sentence_confidence=0.59,
    ).infer(_request(allow_sentence=True))

    assert result["decision"] == "ranked_candidate"
    assert result["ranked_candidate"] == "命令"
    assert result["sentence_suggestion"] == ""
    assert result["confidence"] == 0.99


def _segmented_request(*, allow_sentence=True):
    request = _request(allow_sentence=allow_sentence)
    request["pinyin"] = "shi"
    request["segments"] = [
        {"pinyin": "mingling", "separator": "，", "committed_text": "明令"},
        {"pinyin": "shi", "separator": ""},
    ]
    return request


def test_engine_segment_suggestion_joins_with_separators():
    engine = _engine(
        ["命令", "明令"],
        0.7,
        segment="命令，时",
        segment_confidence=0.9,
    )

    result = engine.infer(_segmented_request())

    assert result["decision"] == "sentence_suggestion"
    assert result["sentence_suggestion"] == "命令，时"
    assert result["ranked_candidate"] == ""
    assert result["confidence"] == 0.9
    decoder = engine._sentence_decoder
    assert decoder.calls == []
    assert len(decoder.segment_calls) == 1
    context, segments, active_candidates = decoder.segment_calls[0]
    assert context == "请执行这条"
    assert [segment.pinyin for segment in segments] == ["mingling", "shi"]
    assert [segment.separator for segment in segments] == ["，", ""]
    assert [segment.committed_text for segment in segments] == ["明令", ""]
    assert active_candidates == ["明令", "命令"]


def test_engine_segment_confidence_still_gates_the_joined_sentence():
    engine = _engine(
        ["命令", "明令"],
        0.7,
        segment="命令，时",
        segment_confidence=0.59,
    )

    result = engine.infer(_segmented_request())

    assert result["decision"] == "ranked_candidate"
    assert result["ranked_candidate"] == "命令"
    assert result["sentence_suggestion"] == ""


def test_engine_without_segments_keeps_single_segment_behavior():
    engine = _engine(
        ["明令", "命令"],
        0.7,
        sentence="命令",
        sentence_confidence=0.9,
        segment="不应出现",
        segment_confidence=0.9,
    )

    plain = _request(allow_sentence=True)
    result = engine.infer(plain)

    assert result["decision"] == "sentence_suggestion"
    assert result["sentence_suggestion"] == "命令"
    assert engine._sentence_decoder.segment_calls == []
    assert len(engine._sentence_decoder.calls) == 1

    single_segment = _request(allow_sentence=True)
    single_segment["segments"] = [
        {"pinyin": "mingling", "separator": ""},
    ]
    result = engine.infer(single_segment)

    assert result["decision"] == "sentence_suggestion"
    assert result["sentence_suggestion"] == "命令"
    assert engine._sentence_decoder.segment_calls == []
    assert len(engine._sentence_decoder.calls) == 2


def _user_trained_engine(ranking, confidence, texts, domain=None):
    from rimeai_daemon.user_lm import UserLanguageModel

    engine = _engine(ranking, confidence)
    model = UserLanguageModel()
    model.update(domain, texts)
    engine._user_lm = model
    return engine


def test_user_lm_refresh_clears_deleted_artifact(tmp_path):
    # P1-4：设置页清除会删除 user-lm.json.gz；daemon 的 mtime 热重载必须
    # 让删除即时生效，而不是等到进程重启才停用 L2。
    from rimeai_daemon.user_lm import UserLanguageModel

    path = tmp_path / "user-lm.json.gz"
    model = UserLanguageModel()
    model.update("global", ["接口设计"] * 50)
    model.save(path)

    engine = _engine(["命令", "明令"], 0.9)
    engine._user_lm_path = path
    engine._user_lm = None
    engine._user_lm_mtime = None
    engine._refresh_user_lm(force=True)
    assert engine._user_lm is not None

    path.unlink()
    engine._refresh_user_lm()
    assert engine._user_lm is None


def test_user_lm_refresh_detects_rewrite_with_same_mtime(tmp_path):
    # 同一 mtime 刻度内的原子重写（gzip 输出大小变了）必须被探测到：
    # 只比 mtime 会让 daemon 继续用旧模型跑（size 是第二把钥匙）。
    import os

    from rimeai_daemon.user_lm import UserLanguageModel

    path = tmp_path / "user-lm.json.gz"
    model = UserLanguageModel()
    model.update("global", ["接口设计"] * 50)
    model.save(path)
    before = path.stat()

    engine = _engine(["命令", "明令"], 0.9)
    engine._user_lm_path = path
    engine._user_lm = None
    engine._user_lm_mtime = None
    engine._user_lm_size = None
    engine._refresh_user_lm(force=True)
    assert engine._user_lm is not None
    first = engine._user_lm

    # 内容变多 → 产物体积变化；再把 mtime 拨回原值，模拟同一时间刻度
    # 内的重写。
    bigger = UserLanguageModel()
    bigger.update("global", ["接口设计"] * 200)
    bigger.save(path)
    os.utime(path, (before.st_mtime, before.st_mtime))
    assert path.stat().st_size != before.st_size

    engine._refresh_user_lm()
    assert engine._user_lm is not first


def test_user_lm_reranks_toward_learned_phrasing():
    request = {
        "context": "请执行这条",
        "pinyin": "mingling",
        "candidates": ["命令", "明令"],
        "allow_sentence": False,
    }
    result = _user_trained_engine(
        ["命令", "明令"], 0.91, ["明令禁止"] * 200
    ).infer(request)
    assert result["decision"] == "ranked_candidate"
    assert result["ranked_candidate"] == "明令"


def test_user_lm_without_evidence_keeps_ranker_order():
    request = {
        "context": "请执行这条",
        "pinyin": "mingling",
        "candidates": ["明令", "命令"],
        "allow_sentence": False,
    }
    result = _engine(["命令", "明令"], 0.91).infer(request)
    assert result["ranked_candidate"] == "命令"


def test_user_lm_domain_field_is_honored():
    request = {
        "context": "我们看过那部",
        "pinyin": "liaotianjilu",
        "candidates": ["聊天记录", "聊天纪录"],
        "allow_sentence": False,
        "domain": "chat",
    }
    result = _user_trained_engine(
        ["聊天记录", "聊天纪录"],
        0.91,
        ["聊天纪录片"] * 300,
        domain="chat",
    ).infer(request)
    assert result["ranked_candidate"] == "聊天纪录"


# -- user-evidence window guard ---------------------------------------------
#
# 候选集同时携带三类成员：Top10 内 5 字全长候选（eligible 窗口）、
# Top10 内长度不同的 preserved 候选、Top10 之外的尾巴候选。fake ranker
# 固定输出 [eligible 重排] + [preserved 原序] + [尾巴原样] 的结构，
# 与真实 Hybrid / n-gram ranker 的输出布局一致。
_GUARD_CONTEXT = "附近有没有"
_GUARD_CANDIDATES = [
    "附近服务为",  # 0-5：eligible 全长窗口
    "附件服务为",
    "附件服务网",
    "福晋服务为",
    "复检服务为",
    "富锦服务为",
    "放进去",  # 6-9：preserved（与首候选长度不同）
    "风景区",
    "附近服务",
    "风景点",
    "风景区里",  # 10-11：Top10 之外的尾巴
    "放进去吧",
]
_GUARD_RANKING = [
    "附件服务为",  # eligible 窗口内重排（前两项交换）
    "附近服务为",
    "附件服务网",
    "福晋服务为",
    "复检服务为",
    "富锦服务为",
    "放进去",  # preserved 保持原序
    "风景区",
    "附近服务",
    "风景点",
    "风景区里",  # 尾巴原样拼接
    "放进去吧",
]
_GUARD_WINDOW = 6
_GUARD_ELIGIBLE = _GUARD_CANDIDATES[:_GUARD_WINDOW]
_GUARD_GUARDED = _GUARD_CANDIDATES[_GUARD_WINDOW:]


def _guard_request():
    return {
        "context": _GUARD_CONTEXT,
        "pinyin": "fjfww",
        "candidates": list(_GUARD_CANDIDATES),
        "allow_sentence": False,
    }


def test_user_evidence_cannot_promote_preserved_or_tail_candidates():
    # 守卫回归：preserved（长度不同）与 >Top10 尾巴候选即使有足够
    # 用户证据，也必须保持原位，不得被顶到第 1 绕过全长/Top10 守卫。
    engine = _user_trained_engine(
        list(_GUARD_RANKING),
        0.91,
        ["附近有没有放进去"] * 200 + ["附近有没有风景区里"] * 200,
    )
    # 证据足以越界：把完整 ranking 直接交给 user LM 时，preserved
    # 或尾巴候选会被顶到第 1（即修复前的行为）。
    leaked, leaked_confidence = engine._user_lm.rerank(
        _GUARD_CONTEXT, _GUARD_RANKING
    )
    assert leaked[0] in ("放进去", "风景区里")
    assert leaked_confidence > 0

    guarded = engine._apply_user_evidence(
        list(_GUARD_RANKING), _guard_request(), window=_GUARD_WINDOW
    )
    assert sorted(guarded[:_GUARD_WINDOW]) == sorted(
        _GUARD_RANKING[:_GUARD_WINDOW]
    )
    assert guarded[_GUARD_WINDOW:] == _GUARD_RANKING[_GUARD_WINDOW:]
    assert guarded[0] in _GUARD_ELIGIBLE

    result = engine.infer(_guard_request())
    assert result["decision"] in ("ranked_candidate", "same_top_candidate")
    assert result["ranked_candidate"] in ("", *_GUARD_ELIGIBLE)


def test_user_evidence_still_reranks_inside_eligible_window():
    # 窗口限制不得误伤个性化：eligible 窗口内的候选仍可被用户证据
    # 顶到第 1。
    engine = _user_trained_engine(
        list(_GUARD_RANKING), 0.91, ["附近有没有附件服务网"] * 200
    )

    result = engine.infer(_guard_request())

    assert result["decision"] == "ranked_candidate"
    assert result["ranked_candidate"] == "附件服务网"


def test_user_evidence_absent_keeps_ranking_bit_for_bit():
    # 无用户证据（未加载 LM，或已加载但无任何证据）时，ranking 必须
    # 逐位不变。
    request = _guard_request()
    engine = _engine(list(_GUARD_RANKING), 0.91)
    assert engine._apply_user_evidence(
        list(_GUARD_RANKING), request, window=_GUARD_WINDOW
    ) == _GUARD_RANKING

    from rimeai_daemon.user_lm import UserLanguageModel

    engine._user_lm = UserLanguageModel()
    assert engine._apply_user_evidence(
        list(_GUARD_RANKING), request, window=_GUARD_WINDOW
    ) == _GUARD_RANKING


def test_single_eligible_candidate_with_user_evidence_skips_rerank():
    # eligible==1 时 ranker 直接返回原始 candidates；窗口 <2 必须
    # 直接返回，用户证据不得触碰该列表。
    candidates = ["附近服务为", "放进去", "风景区", "风景点", "风景区里"]
    request = {
        "context": _GUARD_CONTEXT,
        "pinyin": "fjfww",
        "candidates": candidates,
        "allow_sentence": False,
    }
    engine = _user_trained_engine(
        list(candidates), 1.0, ["附近有没有放进去"] * 200
    )

    assert engine._apply_user_evidence(
        list(candidates), request, window=1
    ) == candidates

    result = engine.infer(request)
    assert result["decision"] == "insufficient_candidates"
    assert result["ranked_candidate"] == ""


class _FakeHybridRanker(HybridSemanticRanker):
    def __init__(self, ranking, confidence):
        self.ranking = ranking
        self.confidence = confidence

    def rank_candidates(self, *, context, pinyin, candidates):
        return list(self.ranking), self.confidence


class _ExplodingRanker:
    def rank(self, *, context, candidates):
        raise RankerError("neural ranker inference failed")


def test_hybrid_path_user_evidence_stays_inside_window():
    engine = _user_trained_engine(
        list(_GUARD_RANKING), 0.91, ["附近有没有放进去"] * 200
    )
    engine._ranker = _FakeHybridRanker(list(_GUARD_RANKING), 0.91)

    result = engine.infer(_guard_request())

    assert result["decision"] in ("ranked_candidate", "same_top_candidate")
    assert result["ranked_candidate"] in ("", *_GUARD_ELIGIBLE)


def test_fallback_path_user_evidence_stays_inside_window():
    engine = _user_trained_engine(
        list(_GUARD_RANKING), 0.91, ["附近有没有放进去"] * 200
    )
    engine._ranker = _ExplodingRanker()
    engine._fallback_ranker = _Ranker(list(_GUARD_RANKING), 0.91)

    result = engine.infer(_guard_request())

    assert result["decision"] in ("ranked_candidate", "same_top_candidate")
    assert result["ranked_candidate"] in ("", *_GUARD_ELIGIBLE)


def _real_engine(user_lm_path):
    from pathlib import Path

    project_root = Path(__file__).resolve().parent.parent
    return LocalInferenceEngine(
        language_model_path=project_root
        / ".rimeai/models/p0-char-ngram-v2.json.gz",
        beam_config_path=project_root
        / ".rimeai/models/p0-beam-sentence-v3.json",
        rime_dictionary_path=project_root
        / ".rimeai/rime/shared/luna_pinyin.dict.yaml",
        user_lm_path=user_lm_path,
    )


def test_real_constructor_loads_user_lm_and_applies_evidence(tmp_path):
    # C1 回归：真实构造路径（构造器 + 加载器，而非直接注入私有属性）
    # 必须让 L2 证据参与排序——缺失 artifact 时保持基线行为。
    from rimeai_daemon.user_lm import UserLanguageModel

    artifact = tmp_path / "user-lm.json.gz"
    trained = UserLanguageModel()
    trained.update(None, ["明令禁止"] * 200)
    trained.save(artifact)

    request = {
        "context": "请执行这条",
        "pinyin": "mingling",
        "candidates": ["命令", "明令"],
        "allow_sentence": False,
        "sensitive": False,
    }
    cold = _real_engine(tmp_path / "absent.json.gz")
    warm = _real_engine(artifact)

    assert cold.infer(dict(request))["decision"] == "same_top_candidate"
    warm_result = warm.infer(dict(request))
    assert warm_result["decision"] == "ranked_candidate"
    assert warm_result["ranked_candidate"] == "明令"


def test_sentence_path_identical_with_empty_user_lm(tmp_path):
    # Review Focus 1 回归：空 user-LM 工件（冷启动）必须让整句路径与
    # 无工件路径逐位一致，包括 segments 多段路径。
    from rimeai_daemon.user_lm import UserLanguageModel

    empty_artifact = tmp_path / "empty-user-lm.json.gz"
    UserLanguageModel().save(empty_artifact)

    request = {
        "context": "请执行这条",
        "pinyin": "mingling",
        "candidates": ["明令", "命令"],
        "allow_sentence": True,
        "sensitive": False,
    }
    segment_request = dict(request)
    segment_request["pinyin"] = "shi"
    segment_request["candidates"] = ["是", "时"]
    segment_request["segments"] = [
        {"pinyin": "mingling", "separator": "，", "committed_text": "明令"},
        {"pinyin": "shi", "separator": ""},
    ]

    cold = _real_engine(tmp_path / "absent.json.gz")
    warm = _real_engine(empty_artifact)

    assert warm.infer(dict(request)) == cold.infer(dict(request))
    assert warm.infer(dict(segment_request)) == cold.infer(
        dict(segment_request)
    )


class _ScorerRecordingDecoder(BeamSentenceDecoder):
    def __init__(self, inner):
        self.inner = inner
        self.scorers = []

    def suggest(self, *, context, pinyin, candidates, scorer=None):
        self.scorers.append(scorer)
        return self.inner.suggest(
            context=context,
            pinyin=pinyin,
            candidates=candidates,
            scorer=scorer,
        )


def test_user_lm_domain_influences_sentence_suggestion(tmp_path):
    # 偏置 domain 用户 LM 后整句建议路径确实走融合打分器，且输出不再
    # 与静态路径全等、不抛异常。
    from rimeai_daemon.user_lm import UserLanguageModel

    artifact = tmp_path / "biased-user-lm.json.gz"
    biased = UserLanguageModel()
    biased.update("chat", ["明令禁止"] * 400)
    biased.save(artifact)

    request = {
        "context": "请执行这条",
        "pinyin": "mingling",
        "candidates": ["命令", "明令"],
        "allow_sentence": True,
        "domain": "chat",
        "sensitive": False,
    }
    cold = _real_engine(tmp_path / "absent.json.gz")
    warm = _real_engine(artifact)
    recorder = _ScorerRecordingDecoder(warm._sentence_decoder)
    warm._sentence_decoder = recorder

    warm_result = warm.infer(dict(request))

    assert len(recorder.scorers) == 1
    assert recorder.scorers[0] is not None
    assert warm_result == warm.infer(dict(request))
    assert warm_result != cold.infer(dict(request))


def test_running_engine_reloads_user_lm_on_rewrite(tmp_path):
    # I1 回归：固化循环在另一进程重写 user-lm.json.gz 后，运行中的
    # daemon 无需重启即可拿到新证据（mtime 触发重载）。
    import os

    from rimeai_daemon.user_lm import UserLanguageModel

    artifact = tmp_path / "user-lm.json.gz"
    first = UserLanguageModel()
    first.update(None, ["明令禁止"] * 200)
    first.save(artifact)
    engine = _real_engine(artifact)

    request = {
        "context": "请执行这条",
        "pinyin": "mingling",
        "candidates": ["命令", "明令"],
        "allow_sentence": False,
        "sensitive": False,
    }
    assert engine.infer(dict(request))["ranked_candidate"] == "明令"

    replacement = UserLanguageModel()
    replacement.update(None, ["命令行参数说明"] * 200)
    replacement.save(artifact)
    # gzip 原子替换可能落在同一 mtime 里；显式前移 mtime 触发重载。
    stamped = artifact.stat().st_mtime + 10
    os.utime(artifact, (stamped, stamped))

    assert engine.infer(dict(request))["decision"] == "same_top_candidate"


class _StubConverter:
    def convert(self, text):
        return text.replace("氣", "气").replace("後", "后")


def test_sentence_suggestion_converts_to_simplified_when_requested():
    engine = _engine(
        ["明令", "命令"],
        0.0,
        sentence="今天天氣很好",
        sentence_confidence=0.9,
        sentence_reason="suggestion",
        t2s_converter=_StubConverter(),
    )
    request = _request(allow_sentence=True)
    request["character_set"] = "simplified"

    result = engine.infer(request)

    assert result["decision"] == "sentence_suggestion"
    assert result["sentence_suggestion"] == "今天天气很好"


def test_sentence_suggestion_keeps_traditional_without_character_set():
    engine = _engine(
        ["明令", "命令"],
        0.0,
        sentence="今天天氣很好",
        sentence_confidence=0.9,
        sentence_reason="suggestion",
        t2s_converter=_StubConverter(),
    )

    result = engine.infer(_request(allow_sentence=True))

    assert result["sentence_suggestion"] == "今天天氣很好"


def test_sentence_suggestion_skips_conversion_without_a_table():
    engine = _engine(
        ["明令", "命令"],
        0.0,
        sentence="今天天氣很好",
        sentence_confidence=0.9,
        sentence_reason="suggestion",
    )
    request = _request(allow_sentence=True)
    request["character_set"] = "simplified"

    result = engine.infer(request)

    assert result["sentence_suggestion"] == "今天天氣很好"
