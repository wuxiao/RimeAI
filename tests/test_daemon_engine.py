from types import SimpleNamespace

from rimeai_daemon.engine import LocalInferenceEngine


class _Ranker:
    def __init__(self, ranking, confidence):
        self.ranking = ranking
        self.confidence = confidence

    def rank(self, *, context, candidates):
        return self.ranking, self.confidence


class _SentenceDecoder:
    def __init__(self, text="", confidence=0.0, reason="no_change"):
        self.result = SimpleNamespace(
            text=text,
            confidence=confidence,
            reason=reason,
        )

    def suggest(self, *, context, pinyin, candidates):
        return self.result


def _engine(
    ranking,
    confidence,
    *,
    sentence="",
    sentence_confidence=0.0,
    sentence_reason="no_change",
):
    engine = LocalInferenceEngine.__new__(LocalInferenceEngine)
    engine._ranker = _Ranker(ranking, confidence)
    engine._sentence_decoder = _SentenceDecoder(
        sentence,
        sentence_confidence,
        sentence_reason,
    )
    engine._ranker_min_confidence = 0.55
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


def test_incomplete_sentence_abstains_instead_of_returning_a_ranked_fragment():
    result = _engine(
        ["命令", "明令"],
        0.91,
        sentence_reason="incomplete_candidate",
    ).infer(_request(allow_sentence=True))

    assert result["decision"] == "sentence_incomplete"
    assert result["ranked_candidate"] == ""
    assert result["sentence_suggestion"] == ""
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


def test_low_confidence_sentence_does_not_override_ranked_candidate():
    result = _engine(
        ["命令", "明令"],
        0.99,
        sentence="请执行这条命令",
        sentence_confidence=0.96,
    ).infer(_request(allow_sentence=True))

    assert result["decision"] == "ranked_candidate"
    assert result["ranked_candidate"] == "命令"
    assert result["sentence_suggestion"] == ""
    assert result["confidence"] == 0.99
