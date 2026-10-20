from types import SimpleNamespace
from typing import Any

from rimeai_daemon.engine import LocalInferenceEngine
from rimeai_runtime.beam_decoder import BeamSentenceDecoder


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
