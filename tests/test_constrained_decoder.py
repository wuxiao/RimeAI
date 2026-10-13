"""Constrained decoding: pinyin token index, greedy decode, fuzzy gate."""

import math

import pytest

from rimeai_runtime.constrained_decoder import PinyinTokenIndex
from rimeai_runtime.pinyin_guard import PinyinGuard


class _StubTokenizer:
    """Duck-typed stand-in for a transformers tokenizer."""

    vocab_size = 8
    _tokens = ["你", "好", "世界", "的", "是", "<pad>", "\n", "长"]

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
