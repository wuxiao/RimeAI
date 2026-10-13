"""Constrained decoding: pinyin token index, greedy decode, fuzzy gate."""

import math

from pathlib import Path

import pytest

from rimeai_runtime.constrained_decoder import (
    ConstrainedGreedyDecoder,
    DecodeResult,
    PinyinTokenIndex,
    fuzzy_equal,
    fuzzy_segment_ok,
)
from rimeai_runtime.pinyin_guard import PinyinGuard

class _StubTokenizer:
    """Duck-typed stand-in for a transformers tokenizer."""

    vocab_size = 18
    _tokens = [
        "你", "好", "世界", "的", "是", "<pad>", "\n", "长", "时", "四季",
        "界", "试", "我", "们", "门", "明天", "我们", "今天",
    ]

    def decode(self, ids):
        return self._tokens[ids[0]]


def _guard() -> PinyinGuard:
    return PinyinGuard(
        pronunciations={
            "你": frozenset({"ni"}),
            "好": frozenset({"hao"}),
            "的": frozenset({"de"}),
            "世": frozenset({"shi"}),
            "界": frozenset({"jie"}),
            "四": frozenset({"si"}),
            "季": frozenset({"ji"}),
            "长": frozenset({"chang", "zhang"}),
            "时": frozenset({"shi"}),
            "试": frozenset({"shi"}),
            "我": frozenset({"wo"}),
            "们": frozenset({"men"}),
            "门": frozenset({"men"}),
            "明": frozenset({"ming"}),
            "天": frozenset({"tian"}),
            "今": frozenset({"jin"}),
        }
    )


def _index() -> PinyinTokenIndex:
    return PinyinTokenIndex.build(_StubTokenizer(), _guard())


def test_index_builds_from_tokenizer_and_guard():
    index = _index()
    assert 0 in index.token_syllables  # 你
    assert 2 in index.token_syllables  # 世界
    assert index.token_syllables[2] == frozenset({("shi", "jie")})


def test_candidates_returns_prefix_matching_tokens():
    result = _index().candidates(("shi", "jie", "hao"))
    assert result[2] == ("shi", "jie")
    # 好 does not start with "shi"
    assert 1 not in result


def test_candidates_single_character_consumes_one_syllable():
    assert _index().candidates(("ni", "hao"))[0] == ("ni",)


def test_polyphone_entry_matches_each_reading():
    index = _index()
    assert 7 in index.candidates(("chang",))
    assert 7 in index.candidates(("zhang",))
    assert index.token_syllables[7] == frozenset({("chang",), ("zhang",)})


def test_tokens_without_pronunciation_never_match():
    index = _index()
    for syllables in (("shi",), ("de",), ("ni",), ("chang",)):
        result = index.candidates(syllables)
        for excluded in (4, 5, 6):
            assert excluded not in result


def test_empty_prefix_yields_no_candidates():
    assert _index().candidates(()) == {}


class _FixedScorer:
    """step_token_ids -> fixed probability mapping for that step."""

    def __init__(self, table):
        self._table = {tuple(k): v for k, v in table.items()}

    def __call__(self, step_token_ids):
        return self._table.get(tuple(step_token_ids), {})


def test_decode_chains_greedy_tokens_with_geometric_mean_confidence():
    scorer = _FixedScorer({(): {0: 0.6}, (0,): {1: 0.9}})
    result = ConstrainedGreedyDecoder.decode(scorer, ("ni", "hao"), _index())
    assert result.text == "你好"
    assert result.consumed_syllables == 2
    assert result.confidence == pytest.approx(math.sqrt(0.6 * 0.9))


def test_long_word_priority_promotes_longer_token_below_threshold():
    # argmax 时 0.89 < 0.9 → among prob >= 0.445 the longest coverage wins
    scorer = _FixedScorer({(): {8: 0.89, 2: 0.49}})
    result = ConstrainedGreedyDecoder.decode(scorer, ("shi", "jie"), _index())
    assert result.text == "世界"
    assert result.consumed_syllables == 2


def test_no_priority_when_argmax_at_or_above_threshold():
    # argmax 时 0.95 >= 0.9 → plain argmax wins even though 世界 is eligible
    scorer = _FixedScorer(
        {(): {8: 0.95, 2: 0.49}, (8,): {10: 0.9}}
    )
    result = ConstrainedGreedyDecoder.decode(scorer, ("shi", "jie"), _index())
    assert result.text == "时界"
    assert result.consumed_syllables == 2


def test_long_word_priority_requires_half_of_argmax_probability():
    # 世界 0.3 < 0.5 * 0.8 → not eligible, 时 wins
    scorer = _FixedScorer({(): {8: 0.8, 2: 0.3}, (8,): {10: 0.9}})
    result = ConstrainedGreedyDecoder.decode(scorer, ("shi", "jie"), _index())
    assert result.text == "时界"


def test_tie_breaks_to_smaller_token_id():
    scorer = _FixedScorer({(): {8: 0.5, 11: 0.5}, (8,): {10: 0.9}})
    result = ConstrainedGreedyDecoder.decode(scorer, ("shi", "jie"), _index())
    assert result.text == "时界"


def test_no_legal_first_token_abstains_with_empty_text():
    scorer = _FixedScorer({(): {0: 1.0}})
    result = ConstrainedGreedyDecoder.decode(scorer, ("xx",), _index())
    assert result.text == ""
    assert result.confidence == 0.0
    assert result.consumed_syllables == 0


def test_mid_decode_dead_end_abstains_with_empty_text():
    # 你 consumes "ni"; "hao" has candidate 好 but scorer returns nothing
    scorer = _FixedScorer({(): {0: 0.7}})
    result = ConstrainedGreedyDecoder.decode(scorer, ("ni", "hao"), _index())
    assert result.text == ""
    assert result.confidence == 0.0
    assert result.consumed_syllables == 1


def test_exceeding_max_characters_abstains_with_empty_text():
    scorer = _FixedScorer(
        {(): {0: 0.9}, (0,): {1: 0.9}, (0, 1): {3: 0.9}}
    )
    result = ConstrainedGreedyDecoder.decode(
        scorer, ("ni", "hao", "de"), _index(), max_characters=2
    )
    assert result.text == ""
    assert result.confidence == 0.0
    assert result.consumed_syllables == 2


def test_beam_prefers_jointly_better_path_over_greedy():
    # Greedy step scores favor 我(0.5) then 门(0.6), but the joint path
    # through 我们(0.2)+明天(0.9) dominates 我(0.5)+门(0.6)+明天(0.1).
    scorer = _FixedScorer(
        {
            (): {12: 0.5, 16: 0.2},
            (12,): {14: 0.6, 13: 0.3},
            (16,): {15: 0.9},
            (12, 14): {15: 0.1},
            (12, 13): {15: 0.9},
        }
    )
    greedy = ConstrainedGreedyDecoder.decode(scorer, ("wo", "men", "ming", "tian"), _index())
    assert greedy.text == "我门明天"
    beam = ConstrainedGreedyDecoder.decode(
        scorer, ("wo", "men", "ming", "tian"), _index(), beam_width=4
    )
    assert beam.text == "我们明天"
    assert beam.consumed_syllables == 4
    assert beam.confidence == pytest.approx(math.sqrt(0.2 * 0.9))


def test_fuzzy_equal_covers_frozen_pairs_both_directions():
    assert fuzzy_equal("an", "ang")
    assert fuzzy_equal("ang", "an")
    assert fuzzy_equal("en", "eng")
    assert fuzzy_equal("in", "ing")
    assert fuzzy_equal("z", "zh")
    assert fuzzy_equal("zh", "z")
    assert fuzzy_equal("c", "ch")
    assert fuzzy_equal("s", "sh")
    assert fuzzy_equal("an", "an")
    assert not fuzzy_equal("an", "en")
    assert not fuzzy_equal("shi", "xi")


def test_fuzzy_equal_applies_final_swaps_to_whole_syllables():
    assert fuzzy_equal("jin", "jing")
    assert fuzzy_equal("shan", "shang")
    assert fuzzy_equal("chen", "cheng")
    assert fuzzy_equal("fen", "feng")
    assert fuzzy_equal("wan", "wang")
    # double confusion (initial AND final) stays out of scope
    assert not fuzzy_equal("chen", "chang")
    assert not fuzzy_equal("zhan", "zang")


def test_fuzzy_candidates_recover_mistyped_final():
    result = _index().candidates(("jing", "tian"), fuzzy=True)
    assert result[17] == ("jin", "tian")  # 今天 via jin ~ jing


def test_fuzzy_candidates_match_mistyped_initials():
    exact = _index().candidates(("si", "ji"), fuzzy=True)
    assert exact[9] == ("si", "ji")
    mistyped = _index().candidates(("si", "jie"), fuzzy=True)
    assert mistyped[2] == ("shi", "jie")  # shi ~ si via s/sh, jie exact


def test_fuzzy_decode_recovers_intended_word():
    scorer = _FixedScorer({(): {9: 0.8}})
    result = ConstrainedGreedyDecoder.decode(
        scorer, ("si", "ji"), _index(), fuzzy=True
    )
    assert result.text == "四季"
    assert result.consumed_syllables == 2


def test_fuzzy_segment_ok_accepts_exact_and_fuzzy():
    guard = _guard()
    assert fuzzy_segment_ok(guard, "四季", ("si", "ji"))
    assert fuzzy_segment_ok(guard, "世界", ("si", "jie"))
    assert not fuzzy_segment_ok(guard, "世界", ("wu", "jie"))
    assert not fuzzy_segment_ok(guard, "世界", ("si",))


def test_constrained_qwen_decoder_config_is_loadable():
    from pathlib import Path

    from rimeai_eval.command_sentence_decoder import (
        CommandSentenceDecoder,
        SentenceDecoderConfigurationError,
    )

    try:
        decoder = CommandSentenceDecoder.from_config(
            Path("examples/constrained_qwen_decoder.json")
        )
    except SentenceDecoderConfigurationError as error:
        pytest.fail(f"decoder config rejected: {error}")
    assert decoder.name == "constrained-qwen-v1"


_REAL_DICTIONARY = Path(".rimeai/rime/shared/luna_pinyin.dict.yaml")


class _TextTokenizer:
    """Minimal tokenizer whose vocab is exactly the given texts."""

    def __init__(self, texts):
        self.vocab_size = len(texts)
        self._texts = list(texts)

    def decode(self, ids):
        return self._texts[ids[0]]


@pytest.mark.skipif(
    not _REAL_DICTIONARY.is_file(), reason="real Rime dictionary not bootstrapped"
)
def test_real_dictionary_indexes_multi_char_tokens():
    # Pins the Task-1 ruling against real data: pronunciation values are
    # concatenated (spaces stripped by PinyinGuard), so multi-char
    # syllables must come from per-character readings, never from
    # splitting the word-level value on spaces.
    guard = PinyinGuard.from_rime_dictionary(_REAL_DICTIONARY)
    index = PinyinTokenIndex.build(
        _TextTokenizer(["世界", "今天", "你", "<pad>"]), guard
    )
    assert index.token_syllables[0] == frozenset({("shi", "jie")})
    assert index.token_syllables[1] == frozenset({("jin", "tian")})
    assert 0 in index.candidates(("shi", "jie", "hao"))
    assert 1 in index.candidates(("jin", "tian"))
