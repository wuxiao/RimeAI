"""Tests for the CharLMScorer protocol and the fused user-LM scorer."""

from rimeai_daemon.fused_lm import FusedCharLM
from rimeai_daemon.user_lm import UserLanguageModel
from rimeai_runtime.lm_fusion import StaticCharLM
from rimeai_runtime.ngram_ranker import train_ngram_model


def _sample(
    sample_id: str,
    split: str,
    context: str,
    gold: str,
    candidates: list[str],
) -> dict:
    return {
        "schema_version": 1,
        "id": sample_id,
        "split": split,
        "domain": "developer",
        "context": context,
        "pinyin": "mingling",
        "candidates": candidates,
        "gold_text": gold,
        "tags": ["long-input"],
    }


def _static() -> StaticCharLM:
    samples = [
        _sample(
            "train-1",
            "train",
            "请在终端执行这条",
            "命令",
            ["明令", "命令"],
        ),
        _sample(
            "train-2",
            "train",
            "现在运行这条",
            "命令",
            ["明令", "命令"],
        ),
        _sample(
            "validation-ranker",
            "validation",
            "执行这条",
            "命令",
            ["明令", "命令"],
        ),
    ]
    model, _ = train_ngram_model(samples, dataset_sha256="d" * 64)
    return StaticCharLM(model)


CONTEXTS = [
    "",
    "请",
    "请在终端执行这条",
    "执" * 60,
]
CHARACTERS = ["命", "令", "明", "是", "时", "$"]


def test_fused_equals_base_without_user_evidence():
    base = _static()
    for domain in (None, "chat"):
        fused = FusedCharLM(base, UserLanguageModel(), domain)
        for context in CONTEXTS:
            for character in CHARACTERS:
                assert fused.next_char_log_prob(
                    context, character
                ) == base.next_char_log_prob(context, character)
        assert fused.max_context_characters == base.max_context_characters
        assert fused.character_frequency("命") == base.character_frequency("命")
        assert fused.character_frequency("无") == base.character_frequency("无")


def test_fused_shifts_toward_user_domain():
    base = _static()
    user_lm = UserLanguageModel()
    user_lm.update("chat", ["明令禁止"] * 200)
    fused = FusedCharLM(base, user_lm, "chat")

    assert (
        fused.next_char_log_prob("明", "令")
        > base.next_char_log_prob("明", "令")
    )


def test_fused_handles_blank_domain():
    base = _static()
    user_lm = UserLanguageModel()
    user_lm.update(None, ["命令行参数"] * 200)
    via_blank = FusedCharLM(base, user_lm, "  ")
    via_none = FusedCharLM(base, user_lm, None)

    for context in CONTEXTS:
        for character in CHARACTERS:
            assert via_blank.next_char_log_prob(
                context, character
            ) == via_none.next_char_log_prob(context, character)


def test_fused_caching_preserves_outputs():
    base = _static()
    user_lm = UserLanguageModel()
    user_lm.update("chat", ["明令禁止"] * 200)
    fused = FusedCharLM(base, user_lm, "chat")
    uncached = FusedCharLM(base, user_lm, "chat")

    for context in CONTEXTS:
        for character in CHARACTERS:
            first = fused.next_char_log_prob(context, character)
            second = fused.next_char_log_prob(context, character)
            assert first == second
            assert first == uncached.next_char_log_prob(context, character)

    assert fused.cache_hits > 0
    assert uncached.cache_hits == 0


def test_fused_cache_survives_long_contexts_beyond_the_window():
    # Two contexts sharing the last `max_context_characters` characters
    # must still hit the same cache entry: every backoff gram ends at the
    # scored position, so characters beyond the window cannot affect the
    # value of either layer.
    base = _static()
    user_lm = UserLanguageModel()
    user_lm.update("chat", ["明令禁止"] * 200)
    fused = FusedCharLM(base, user_lm, "chat")

    window = "请执行这条明令" * 6
    for prefix in ("甲", "乙乙"):
        context = prefix + window
        for character in CHARACTERS:
            first = fused.next_char_log_prob(context, character)
            again = fused.next_char_log_prob(context, character)
            assert first == again
    assert fused.cache_hits > 0


def test_fused_weights_computed_once(monkeypatch):
    base = _static()
    user_lm = UserLanguageModel()
    user_lm.update("chat", ["明令禁止"] * 200)
    calls: list[object] = []
    original = UserLanguageModel.user_weights

    def spy(self, domain=None):
        calls.append(domain)
        return original(self, domain)

    monkeypatch.setattr(UserLanguageModel, "user_weights", spy)

    fused = FusedCharLM(base, user_lm, "chat")
    assert fused._domain_weight > 0
    assert fused._global_weight == 0.0
    for context in CONTEXTS:
        for character in CHARACTERS:
            fused.next_char_log_prob(context, character)

    assert calls == ["chat"]
