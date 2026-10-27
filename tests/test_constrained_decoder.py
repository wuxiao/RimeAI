"""Constrained decoding: pinyin token index, greedy decode, fuzzy gate."""

import math
import random
from pathlib import Path

import pytest

from rimeai_runtime.constrained_decoder import (
    ConstrainedGreedyDecoder,
    DecodeResult,
    PinyinTokenIndex,
    fuzzy_equal,
    fuzzy_segment_ok,
    gold_path_reachable,
)
from rimeai_runtime.pinyin_guard import PinyinGuard


class _StubTokenizer:
    """Duck-typed stand-in for a transformers tokenizer."""

    vocab_size = 18
    _tokens = [
        "你",
        "好",
        "世界",
        "的",
        "是",
        "<pad>",
        "\n",
        "长",
        "时",
        "四季",
        "界",
        "试",
        "我",
        "们",
        "门",
        "明天",
        "我们",
        "今天",
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
    # 每步 allowed 只有一个候选 → 掩码内归一化后恒为 1.0；
    # RAW 几何均值保留在 raw_confidence 供双口径对比。
    assert result.confidence == pytest.approx(1.0)
    assert result.raw_confidence == pytest.approx(math.sqrt(0.6 * 0.9))


def test_long_word_priority_promotes_longer_token_below_threshold():
    # argmax 时 0.89 < 0.9 → among prob >= 0.445 the longest coverage wins
    scorer = _FixedScorer({(): {8: 0.89, 2: 0.49}})
    result = ConstrainedGreedyDecoder.decode(scorer, ("shi", "jie"), _index())
    assert result.text == "世界"
    assert result.consumed_syllables == 2


def test_no_priority_when_argmax_at_or_above_threshold():
    # argmax 时 0.95 >= 0.9 → plain argmax wins even though 世界 is eligible
    scorer = _FixedScorer({(): {8: 0.95, 2: 0.49}, (8,): {10: 0.9}})
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
    scorer = _FixedScorer({(): {0: 0.9}, (0,): {1: 0.9}, (0, 1): {3: 0.9}})
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
    greedy = ConstrainedGreedyDecoder.decode(
        scorer, ("wo", "men", "ming", "tian"), _index()
    )
    assert greedy.text == "我门明天"
    beam = ConstrainedGreedyDecoder.decode(
        scorer, ("wo", "men", "ming", "tian"), _index(), beam_width=4
    )
    assert beam.text == "我们明天"
    assert beam.consumed_syllables == 4
    # 掩码内归一化：第 1 步 Z=0.5+0.2（我/我们），第 2 步 Z=0.9（明天）；
    # RAW 几何均值保留在 raw_confidence。
    assert beam.confidence == pytest.approx(math.sqrt((0.2 / 0.7) * 1.0))
    assert beam.raw_confidence == pytest.approx(math.sqrt(0.2 * 0.9))


# --------------------------------------------------------------------------
# 无损 early-stop：剪枝只砍掉严格劣于最优 completed 路径的 frontier，
# 任何输入的返回值必须与不剪枝的完整搜索完全一致。


class _CountingScorer:
    """Wraps a scorer and counts calls (proof that early-stop fires)."""

    def __init__(self, base):
        self.base = base
        self.calls = 0

    def __call__(self, step_token_ids):
        self.calls += 1
        return self.base(step_token_ids)


class _HashScorer:
    """Deterministic pseudo-random next-token distribution keyed on the
    consumed prefix (KV semantics: position k depends only on tokens[:k])."""

    def __init__(self, vocab_size=18, seed=0):
        self._vocab_size = vocab_size
        self._seed = seed

    def __call__(self, step_token_ids):
        digest = self._seed
        for token in step_token_ids:
            digest = ((digest ^ (token + 0x9E3779B9)) * 16777619) & 0xFFFFFFFF
        return {
            token: (((digest >> (token % 31)) % 997) + 1) / 997.0
            for token in range(self._vocab_size)
        }


def _reference_beam_decode(
    scorer,
    syllables,
    index,
    *,
    max_characters=30,
    fuzzy=False,
    beam_width=4,
):
    """Pre-change _decode_beam, copied verbatim as the oracle.

    路径选择与 RAW 分数完全沿用改前实现（无 early-stop 的完整
    搜索）：oracle 的 confidence 字段携带的正是改前的 RAW 几何
    均值口径，与新版 DecodeResult.raw_confidence 对位比较，
    证明文本输出/路径选择/RRAW 管线逐位不变。
    """
    total = len(syllables)

    def expand(state):
        tokens, text, consumed, log_probability_sum, steps = state
        probabilities = scorer(tokens)
        expanded = []
        for token_id, reading in index.candidates(
            syllables[consumed:], fuzzy=fuzzy
        ).items():
            probability = probabilities.get(token_id, 0.0)
            if probability <= 0.0:
                continue
            token_text = index.token_texts.get(token_id, "")
            if len(text) + len(token_text) > max_characters:
                continue
            expanded.append(
                (
                    tokens + [token_id],
                    text + token_text,
                    consumed + len(reading),
                    log_probability_sum + math.log(max(probability, 1e-12)),
                    steps + 1,
                )
            )
        return expanded

    frontier = [([], "", 0, 0.0, 0)]
    completed = []
    deepest = 0
    while frontier:
        next_frontier = []
        for state in frontier:
            deepest = max(deepest, state[2])
            for child in expand(state):
                if child[2] == total:
                    completed.append(child)
                else:
                    next_frontier.append(child)
        next_frontier.sort(key=lambda state: (-state[3], state[0]))
        frontier = next_frontier[:beam_width]
    if not completed:
        return DecodeResult("", 0.0, deepest)
    best = min(completed, key=lambda state: (-state[3], state[0]))
    confidence = math.exp(best[3] / best[4]) if best[4] else 0.0
    return DecodeResult(best[1], confidence, total)


# 单音节自由拼 + 必须成对出现的双音节 token 块（无单字 token），
# 混合出有/无 completed 路径、不同深度完成的随机输入。
_SINGLE_SYLLABLES = ("ni", "hao", "de", "shi", "jie", "wo", "men", "men")
_MULTI_SYLLABLE_BLOCKS = (("ming", "tian"), ("jin", "tian"), ("si", "ji"))


def _random_syllable_sequences(seed, count):
    rng = random.Random(seed)
    sequences = []
    for _ in range(count):
        parts = []
        for _ in range(rng.randint(2, 5)):
            if rng.random() < 0.5:
                parts.append(rng.choice(_SINGLE_SYLLABLES))
            else:
                parts.extend(rng.choice(_MULTI_SYLLABLE_BLOCKS))
        sequences.append(tuple(parts))
    return sequences


@pytest.mark.parametrize("max_characters", [30, 5])
@pytest.mark.parametrize("beam_width", [2, 4])
def test_beam_early_stop_matches_exhaustive_search(beam_width, max_characters):
    index = _index()
    for seed in range(6):
        for syllables in _random_syllable_sequences(1000 + seed, 6):
            fast = _CountingScorer(_HashScorer(seed=seed))
            slow = _CountingScorer(_HashScorer(seed=seed))
            result = ConstrainedGreedyDecoder.decode(
                fast,
                syllables,
                index,
                max_characters=max_characters,
                beam_width=beam_width,
            )
            expected = _reference_beam_decode(
                slow,
                syllables,
                index,
                max_characters=max_characters,
                beam_width=beam_width,
            )
            assert (
                result.text,
                result.consumed_syllables,
                result.raw_confidence,
            ) == (
                expected.text,
                expected.consumed_syllables,
                expected.confidence,
            ), (syllables, seed)
            # 早停只减不增 scorer 调用。
            assert fast.calls <= slow.calls, (syllables, seed)


_FUZZY_TYPED_SEQUENCES = (
    ("ni", "hao"),
    ("jing", "tian"),  # jin ~ jing
    ("si", "ji"),
    ("si", "jie"),  # shi ~ si
    ("cang",),  # chang ~ cang
    ("ni", "jing", "tian"),
    ("si", "jie", "ni", "hao"),
    ("jin", "tian", "si", "ji"),
)


@pytest.mark.parametrize("beam_width", [2, 4])
def test_beam_early_stop_matches_exhaustive_search_fuzzy(beam_width):
    index = _index()
    for seed in range(4):
        for syllables in _FUZZY_TYPED_SEQUENCES:
            fast = _CountingScorer(_HashScorer(seed=seed))
            slow = _CountingScorer(_HashScorer(seed=seed))
            result = ConstrainedGreedyDecoder.decode(
                fast,
                syllables,
                index,
                fuzzy=True,
                beam_width=beam_width,
            )
            expected = _reference_beam_decode(
                slow,
                syllables,
                index,
                fuzzy=True,
                beam_width=beam_width,
            )
            assert (
                result.text,
                result.consumed_syllables,
                result.raw_confidence,
            ) == (
                expected.text,
                expected.consumed_syllables,
                expected.confidence,
            ), (syllables, seed)
            assert fast.calls <= slow.calls, (syllables, seed)


def test_beam_early_stop_actually_skips_scoring_rounds():
    # 世界好 在第 2 轮以 log(0.63) 完成；frontier 里的 时界 log(0.02)、
    # 试界 log(0.01) 都严格更差，第 3 轮注定无用，不得再调用 scorer。
    table = {
        (): {2: 0.7, 8: 0.1, 11: 0.05},
        (2,): {1: 0.9},
        (8,): {10: 0.2},
        (11,): {10: 0.2},
        (8, 10): {1: 0.5},
        (11, 10): {1: 0.5},
    }
    fast = _CountingScorer(_FixedScorer(table))
    slow = _CountingScorer(_FixedScorer(table))
    result = ConstrainedGreedyDecoder.decode(
        fast, ("shi", "jie", "hao"), _index(), beam_width=4
    )
    expected = _reference_beam_decode(
        slow, ("shi", "jie", "hao"), _index(), beam_width=4
    )
    assert result.text == "世界好"
    assert (
        result.text,
        result.raw_confidence,
        result.consumed_syllables,
    ) == (
        expected.text,
        expected.confidence,
        expected.consumed_syllables,
    )
    # 掩码内归一化：世界 0.7/Z（Z=0.85），好 0.9/Z（Z=0.9）。
    assert result.confidence == pytest.approx(math.sqrt((0.7 / 0.85) * (0.9 / 0.9)))
    # 轮 1（1 个状态）+ 轮 2（3 个状态）= 4 次；参照还要跑轮 3（2 次）。
    assert fast.calls == 4
    assert fast.calls < slow.calls
    assert slow.calls == 6


def test_beam_never_prunes_without_completed_path():
    # 没有任何 completed 路径时绝不剪枝：你好 在第 2 轮只剩 log(0.005)
    # 的超低分 frontier，仍必须继续搜索并找到 你好的。
    scorer = _FixedScorer({(): {0: 0.5}, (0,): {1: 0.01}, (0, 1): {3: 0.9}})
    result = ConstrainedGreedyDecoder.decode(
        scorer, ("ni", "hao", "de"), _index(), beam_width=4
    )
    expected = _reference_beam_decode(
        _FixedScorer({(): {0: 0.5}, (0,): {1: 0.01}, (0, 1): {3: 0.9}}),
        ("ni", "hao", "de"),
        _index(),
        beam_width=4,
    )
    assert result.text == "你好的"
    assert result.consumed_syllables == 3
    # 每步 allowed 均只有单候选 → 归一化恒 1.0；RAW 均值走 raw 口径。
    assert result.confidence == pytest.approx(1.0)
    assert result.raw_confidence == pytest.approx((0.5 * 0.01 * 0.9) ** (1 / 3))
    assert (
        result.text,
        result.raw_confidence,
        result.consumed_syllables,
    ) == (
        expected.text,
        expected.confidence,
        expected.consumed_syllables,
    )


def test_beam_keeps_searching_on_equal_scores_for_tie_break():
    # 我们+明天 在第 2 轮以 log(0.2) 完成（tokens [16, 15]）；frontier 的
    # 我门路径 同样是 log(0.2)。同分不得剪枝：tie-break 比较 token id，
    # 更长的 [12, 14, 15] 首位 id 更小而胜出，且几何均值置信度更高
    # （0.2^(1/3) > 0.2^(1/2)）。用 <= 剪枝会错拿 我们明天。
    table = {
        (): {12: 0.4, 16: 0.4},
        (16,): {15: 0.5},
        (12,): {14: 0.5},
        (12, 14): {15: 1.0},
    }
    result = ConstrainedGreedyDecoder.decode(
        _FixedScorer(table), ("wo", "men", "ming", "tian"), _index(), beam_width=4
    )
    expected = _reference_beam_decode(
        _FixedScorer(table),
        ("wo", "men", "ming", "tian"),
        _index(),
        beam_width=4,
    )
    assert result.text == "我门明天"
    assert result.raw_confidence == pytest.approx(0.2 ** (1 / 3))
    # 归一化：我 0.4/Z（Z=0.8），门 0.5/Z（Z=0.5，们不在 scorer 表），
    # 明天 1.0/Z（Z=1.0）。
    assert result.confidence == pytest.approx(
        ((0.4 / 0.8) * (0.5 / 0.5) * (1.0 / 1.0)) ** (1 / 3)
    )
    assert (
        result.text,
        result.raw_confidence,
        result.consumed_syllables,
    ) == (
        expected.text,
        expected.confidence,
        expected.consumed_syllables,
    )


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
    result = ConstrainedGreedyDecoder.decode(scorer, ("si", "ji"), _index(), fuzzy=True)
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
    assert decoder.name == "constrained-qwen-v2"


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


def test_gold_path_reachable_exact_readings():
    assert gold_path_reachable(_index(), "你好", ("ni", "hao"))


def test_gold_path_reachable_via_multichar_token_without_single_chars():
    # 四/季 have no single-character token in the stub vocab; only the
    # whole-word token 四季 exists, so tiling must go through it.
    assert gold_path_reachable(_index(), "四季", ("si", "ji"))


def test_gold_path_reachable_fuzzy_syllables():
    assert gold_path_reachable(_index(), "四季", ("shi", "ji"))


def test_gold_path_reachable_polyphone_readings():
    assert gold_path_reachable(_index(), "长", ("zhang",))
    assert gold_path_reachable(_index(), "长", ("chang",))


def test_gold_path_reachable_rejects_reading_mismatch():
    assert not gold_path_reachable(_index(), "世界", ("ni", "hao"))


def test_gold_path_reachable_rejects_length_mismatch():
    assert not gold_path_reachable(_index(), "四季", ("si",))


def test_gold_path_reachable_rejects_unknown_character():
    assert not gold_path_reachable(_index(), "四喵", ("si", "mi"))


def test_gold_path_reachable_rejects_empty_inputs():
    assert not gold_path_reachable(_index(), "", ())
    assert not gold_path_reachable(_index(), "你好", ())


# --------------------------------------------------------------------------
# 掩码内归一化置信度：口径、单调性与边界。


def test_renormalized_confidence_monotone_in_chosen_share():
    # 选中 token 的 RAW 概率提高（掩码内另一竞争者 时/试 固定 0.2）
    # → 该步 p/Z 提高 → 几何均值提高。0.6/0.8 < 0.7/0.9 < 0.8/1.0。
    low = ConstrainedGreedyDecoder.decode(
        _FixedScorer({(): {8: 0.6, 11: 0.2}}), ("shi",), _index()
    )
    mid = ConstrainedGreedyDecoder.decode(
        _FixedScorer({(): {8: 0.7, 11: 0.2}}), ("shi",), _index()
    )
    high = ConstrainedGreedyDecoder.decode(
        _FixedScorer({(): {8: 0.8, 11: 0.2}}), ("shi",), _index()
    )
    assert low.text == mid.text == high.text == "时"
    assert low.confidence == pytest.approx(0.6 / 0.8)
    assert mid.confidence == pytest.approx(0.7 / 0.9)
    assert high.confidence == pytest.approx(0.8 / 1.0)
    assert low.confidence < mid.confidence < high.confidence


def test_renormalized_confidence_drops_when_mask_gains_mass():
    # 选中 token 的 RAW 概率不变，掩码内另一竞争者获得更多概率质量
    # → Z 增大 → p/Z 下降；RAW 口径纹丝不动。
    calm = ConstrainedGreedyDecoder.decode(
        _FixedScorer({(): {8: 0.6, 11: 0.2}}), ("shi",), _index()
    )
    contested = ConstrainedGreedyDecoder.decode(
        _FixedScorer({(): {8: 0.6, 11: 0.35}}), ("shi",), _index()
    )
    assert calm.text == contested.text == "时"
    assert calm.confidence == pytest.approx(0.6 / 0.8)
    assert contested.confidence == pytest.approx(0.6 / 0.95)
    assert contested.confidence < calm.confidence
    assert calm.raw_confidence == contested.raw_confidence == pytest.approx(0.6)


def test_renormalized_confidence_bounds_and_range():
    # 多步路径：每步 p/Z ∈ (0,1]，几何均值 ∈ (0,1]；RAW 口径与
    # 归一化口径在单候选步退化相同（1.0 vs RAW 概率本身）。
    result = ConstrainedGreedyDecoder.decode(
        _FixedScorer(
            {
                (): {12: 0.5, 16: 0.2, 4: 0.3},
                (12,): {14: 0.6, 13: 0.3},
                (12, 14): {15: 0.1, 4: 0.9},
                (16,): {15: 0.9, 4: 0.1},
            }
        ),
        ("wo", "men", "ming", "tian"),
        _index(),
        beam_width=4,
    )
    assert 0.0 < result.confidence <= 1.0
    assert 0.0 < result.raw_confidence <= 1.0


def test_zero_probability_mask_abstains_safely():
    # Z=0：掩码内全部候选 RAW 概率为 0（scorer 返回空表或全 0）→
    # 不得除零，弃权（空文本、双口径 0.0）。
    for probabilities in ({}, {0: 0.0, 4: 0.0}):
        result = ConstrainedGreedyDecoder.decode(
            _FixedScorer({(): probabilities}), ("ni",), _index()
        )
        assert result.text == ""
        assert result.confidence == 0.0
        assert result.raw_confidence == 0.0
        assert result.consumed_syllables == 0


def test_empty_allowed_set_abstains_safely():
    # allowed 为空（无 token 匹配音节前缀）→ 弃权，双口径 0.0。
    result = ConstrainedGreedyDecoder.decode(
        _FixedScorer({(): {0: 0.9}}), ("xx",), _index()
    )
    assert result.text == ""
    assert result.confidence == 0.0
    assert result.raw_confidence == 0.0


def test_empty_result_default_raw_confidence_matches_legacy_positions():
    # frozen dataclass 兼容性：位置构造（改前所有构造点的形态）依旧
    # 合法，raw_confidence 默认 0.0 与空结果语义一致。
    assert DecodeResult("", 0.0, 3) == DecodeResult("", 0.0, 3, 0.0)
    assert DecodeResult("", 0.0, 3).raw_confidence == 0.0


# --------------------------------------------------------------------------
# 长度惩罚：默认 0 逐位不变；显式启用改变 beam 排序。


def test_length_penalty_zero_keeps_decoding_bit_identical():
    # 默认值与显式 0.0 完全等价，且与改前 oracle（纯 RAW 联合对数
    # 概率排序 + 无早停完整搜索）在随机输入上逐位一致。
    index = _index()
    for seed in range(4):
        for syllables in _random_syllable_sequences(2300 + seed, 5):
            table_scorer = _HashScorer(seed=seed)
            default = ConstrainedGreedyDecoder.decode(
                table_scorer, syllables, index, beam_width=4
            )
            explicit = ConstrainedGreedyDecoder.decode(
                _HashScorer(seed=seed),
                syllables,
                index,
                beam_width=4,
                length_penalty=0.0,
            )
            oracle = _reference_beam_decode(
                _HashScorer(seed=seed), syllables, index, beam_width=4
            )
            assert default == explicit, (syllables, seed)
            assert (
                default.text,
                default.consumed_syllables,
                default.raw_confidence,
            ) == (
                oracle.text,
                oracle.consumed_syllables,
                oracle.confidence,
            ), (syllables, seed)


def test_length_penalty_promotes_more_step_path_when_enabled():
    # RAW 联合概率 我们(0.5) > 我门(0.5*0.9)，默认 0 选「我们」；
    # penalty=1.0 按步数归一化后 我门 log(0.45)/2 > 我们 log(0.5)/1，
    # 排序翻转，证明参数真实接入排序。
    table = {(): {16: 0.5, 12: 0.5}, (12,): {14: 0.9}}
    scorer = _FixedScorer(table)
    assert (
        ConstrainedGreedyDecoder.decode(
            scorer, ("wo", "men"), _index(), beam_width=4
        ).text
        == "我们"
    )
    assert (
        ConstrainedGreedyDecoder.decode(
            scorer,
            ("wo", "men"),
            _index(),
            beam_width=4,
            length_penalty=1.0,
        ).text
        == "我门"
    )


def test_length_penalty_keeps_early_stop_lossless():
    # penalty>0 时早停上界改用 L/total**penalty：随机输入下带惩罚
    # 的有早停实现必须与同一惩罚下的无早停完整搜索完全一致。
    index = _index()

    def exhaustive(scorer, syllables, *, fuzzy=False, penalty):
        total = len(syllables)
        frontier = [([], "", 0, 0.0, 0)]
        completed = []
        while frontier:
            nxt = []
            for tokens, text, consumed, log_p, steps in frontier:
                probabilities = scorer(tokens)
                for token_id, reading in index.candidates(
                    syllables[consumed:], fuzzy=fuzzy
                ).items():
                    probability = probabilities.get(token_id, 0.0)
                    if probability <= 0.0:
                        continue
                    token_text = index.token_texts.get(token_id, "")
                    if len(text) + len(token_text) > 30:
                        continue
                    child = (
                        tokens + [token_id],
                        text + token_text,
                        consumed + len(reading),
                        log_p + math.log(max(probability, 1e-12)),
                        steps + 1,
                    )
                    if child[2] == total:
                        completed.append(child)
                    else:
                        nxt.append(child)

            def rank(state):
                raw = state[3]
                if state[4] <= 0 or penalty == 0.0:
                    return raw
                return raw / (state[4] ** penalty)

            nxt.sort(key=lambda state: (-rank(state), state[0]))
            frontier = nxt[:4]
        if not completed:
            return None
        return min(completed, key=lambda state: (-rank(state), state[0]))

    for seed in range(5):
        for syllables in _random_syllable_sequences(3100 + seed, 5):
            for penalty in (0.5, 1.0):
                result = ConstrainedGreedyDecoder.decode(
                    _HashScorer(seed=seed),
                    syllables,
                    index,
                    beam_width=4,
                    length_penalty=penalty,
                )
                expected = exhaustive(
                    _HashScorer(seed=seed), syllables, penalty=penalty
                )
                if expected is None:
                    assert result.text == "" and result.consumed_syllables == 0
                else:
                    assert (
                        result.text,
                        result.consumed_syllables,
                        result.raw_confidence,
                    ) == (
                        expected[1],
                        total_len := len(syllables),
                        math.exp(expected[3] / expected[4]),
                    ), (syllables, seed, penalty)
                    assert result.consumed_syllables == total_len


def test_length_penalty_is_ignored_by_greedy():
    # greedy 单路径无长度竞争：penalty 传不传都不改变任何输出。
    scorer = _FixedScorer({(): {0: 0.6}, (0,): {1: 0.9}})
    baseline = ConstrainedGreedyDecoder.decode(scorer, ("ni", "hao"), _index())
    penalized = ConstrainedGreedyDecoder.decode(
        scorer, ("ni", "hao"), _index(), length_penalty=1.0
    )
    assert baseline == penalized
    assert baseline.text == "你好"


# --------------------------------------------------------------------------
# L2 用户 LM 浅融合：λ=0 逐位不变；λ>0 只改打分（排序分），不改掩码、
# 合法性与置信度口径；beam early-stop 在融合下保持无损。


class _CountingUserScorer:
    """Records calls and delegates; proves λ=0 never consults the user LM."""

    def __init__(self, base):
        self.base = base
        self.calls = 0

    def __call__(self, prefix_text, token_text):
        self.calls += 1
        return self.base(prefix_text, token_text)


class _HashUserScorer:
    """Deterministic pseudo-random summed log-probabilities in (-1, 0)."""

    def __init__(self, seed=0):
        self._seed = seed

    def __call__(self, prefix_text, token_text):
        digest = self._seed
        for ch in prefix_text[-8:] + "|" + token_text:
            digest = ((digest ^ (ord(ch) + 0x9E3779B9)) * 16777619) & 0xFFFFFFFF
        return -(((digest % 997) + 1) / 998.0)


class _FixedUserScorer:
    """Table-backed scorer: text -> score; default for everything else."""

    def __init__(self, table, default=-1.0):
        self.table = table
        self.default = default
        self.calls = []

    def __call__(self, prefix_text, token_text):
        self.calls.append((prefix_text, token_text))
        return self.table.get(token_text, self.default)


@pytest.mark.parametrize("fuzzy", [False, True])
@pytest.mark.parametrize("beam_width", [1, 4])
def test_user_fusion_weight_zero_is_bit_identical(fuzzy, beam_width):
    # λ=0：文本、置信度、RAW 置信度、消耗音节全部逐位不变，且用户
    # 打分器一次都不被调用（快路径不触碰冻结算术）。
    index = _index()
    for seed in range(5):
        for syllables in _random_syllable_sequences(2000 + seed, 8):
            scorer = _HashScorer(seed=seed)
            user = _CountingUserScorer(_HashUserScorer(seed=seed + 7))
            baseline = ConstrainedGreedyDecoder.decode(
                scorer,
                syllables,
                index,
                fuzzy=fuzzy,
                beam_width=beam_width,
                length_penalty=1.5 if beam_width > 1 else 0.0,
            )
            fused = ConstrainedGreedyDecoder.decode(
                scorer,
                syllables,
                index,
                fuzzy=fuzzy,
                beam_width=beam_width,
                length_penalty=1.5 if beam_width > 1 else 0.0,
                user_scorer=user,
                user_weight=0.0,
            )
            assert fused == baseline, (syllables, seed)
            assert user.calls == 0


def test_user_fusion_none_scorer_keeps_baseline():
    # 不传 user_scorer：与 λ=0 完全一致（默认关闭契约）。
    scorer = _HashScorer(seed=3)
    syllables = ("wo", "men", "ming", "tian")
    baseline = ConstrainedGreedyDecoder.decode(
        scorer, syllables, _index(), beam_width=4
    )
    assert (
        ConstrainedGreedyDecoder.decode(
            scorer, syllables, _index(), beam_width=4, user_weight=0.35
        )
        == baseline
    )


def test_user_fusion_greedy_prefers_user_word():
    # 我 p=0.5 vs 我们 p=0.2：无融合时长词规则 floor=0.25 排除 我们，
    # greedy 走 我门；融合后 我们 的用户证据把 fused 分抬过 我，
    # 路径改写成 我们（一次性消费两个音节）。
    table = {
        (): {12: 0.5, 16: 0.2},
        (12,): {13: 0.3, 14: 0.6},
        (16,): {15: 0.9},
    }
    scorer = _FixedScorer(table)
    user = _FixedUserScorer({"我们": -0.001, "我": -4.0, "门": -4.0, "们": -4.0})
    baseline = ConstrainedGreedyDecoder.decode(scorer, ("wo", "men"), _index())
    fused = ConstrainedGreedyDecoder.decode(
        scorer,
        ("wo", "men"),
        _index(),
        user_scorer=user,
        user_weight=0.5,
    )
    assert baseline.text == "我门"
    assert fused.text == "我们"
    # 多字 token 一次调用、整段文本传入；prefix 是已生成文本。
    assert ("", "我们") in user.calls
    assert all(prefix in ("", "我", "我们") for prefix, _ in user.calls)


def test_user_fusion_greedy_keeps_long_word_priority_in_fused_domain():
    # 融合域内长词优先规则仍生效：baseline 的 argmax（试 p=0.95）自信，
    # 直接取 argmax 走 试界；融合后 fused argmax 变为 世界 且不自信，
    # floor(log0.5) 之上还有更长 reading 的 世界 被提升 → 融合选 世界。
    scorer = _FixedScorer({(): {11: 0.95, 2: 0.4}, (11,): {10: 0.9}})
    user = _FixedUserScorer({"试": -1.2, "世界": -0.05})
    result = ConstrainedGreedyDecoder.decode(
        scorer,
        ("shi", "jie"),
        _index(),
        user_scorer=user,
        user_weight=1.0,
    )
    baseline = ConstrainedGreedyDecoder.decode(scorer, ("shi", "jie"), _index())
    assert baseline.text == "试界"
    assert result.text == "世界"


def test_user_fusion_beam_flips_winner_and_confidence_stays_pure_lm():
    # beam：无融合赢家是 我门明天（首步 我 0.5）；融合把 我们+明天
    # 抬成赢家。置信度仍是纯 LM 口径：赢路径的两个几何均值与
    # 逐 token 概率手工计算一致，不含任何 λ 项。
    scorer = _FixedScorer(
        {
            (): {12: 0.5, 16: 0.2},
            (12,): {14: 0.6, 13: 0.3},
            (16,): {15: 0.9},
            (12, 14): {15: 0.1},
            (12, 13): {15: 0.9},
        }
    )
    user = _FixedUserScorer({"我们": -0.001, "我": -2.0, "门": -2.0})
    baseline = ConstrainedGreedyDecoder.decode(
        scorer, ("wo", "men", "ming", "tian"), _index(), beam_width=4
    )
    fused = ConstrainedGreedyDecoder.decode(
        scorer,
        ("wo", "men", "ming", "tian"),
        _index(),
        beam_width=4,
        user_scorer=user,
        user_weight=0.5,
    )
    assert baseline.text == "我们明天"  # 长 joint 路径本就赢
    # 反向偏好：用户对 我们 整词与 们 字都强烈反感 → 我门明天 胜出
    # （注意 我+们 拆字路径也必须被压住，否则同文本路径仍会赢）。
    user_reverse = _FixedUserScorer(
        {"我们": -6.0, "们": -6.0, "我": -0.001, "门": -0.1}
    )
    flipped = ConstrainedGreedyDecoder.decode(
        scorer,
        ("wo", "men", "ming", "tian"),
        _index(),
        beam_width=4,
        user_scorer=user_reverse,
        user_weight=0.5,
    )
    assert flipped.text == "我门明天"
    # 纯 LM 置信度：我门明天 = (0.5/Z0.7)·(0.6/Z0.9)·(0.1/Z0.1) 的
    # 几何均值（Z 逐步只含掩码内候选，不含任何 λ 项）。
    assert flipped.confidence == pytest.approx(
        ((0.5 / 0.7) * (0.6 / 0.9) * 1.0) ** (1 / 3)
    )
    assert flipped.raw_confidence == pytest.approx((0.5 * 0.6 * 0.1) ** (1 / 3))
    assert fused.confidence == pytest.approx(math.sqrt((0.2 / 0.7) * 1.0))


def _reference_fused_beam_decode(
    scorer,
    user_scorer,
    user_weight,
    syllables,
    index,
    *,
    max_characters=30,
    fuzzy=False,
    beam_width=4,
    length_penalty=0.0,
):
    """Pre-fusion _decode_beam + user term, WITHOUT early stop (oracle)."""
    total = len(syllables)

    def rank(score, steps):
        if steps <= 0 or length_penalty == 0.0:
            return score
        return score / (steps**length_penalty)

    def expand(state):
        tokens, text, consumed, log_sum, steps, renorm, fused_sum = state
        probabilities = scorer(tokens)
        mask_total = sum(
            probabilities.get(t, 0.0)
            for t in index.candidates(syllables[consumed:], fuzzy=fuzzy)
        )
        children = []
        for token_id, reading in index.candidates(
            syllables[consumed:], fuzzy=fuzzy
        ).items():
            probability = probabilities.get(token_id, 0.0)
            if probability <= 0.0:
                continue
            token_text = index.token_texts.get(token_id, "")
            if len(text) + len(token_text) > max_characters:
                continue
            user_score = user_scorer(text, token_text)
            adjustment = user_weight * (user_score or 0.0)
            children.append(
                (
                    tokens + [token_id],
                    text + token_text,
                    consumed + len(reading),
                    log_sum + math.log(max(probability, 1e-12)),
                    steps + 1,
                    renorm
                    + (math.log(probability / mask_total) if mask_total > 0.0 else 0.0),
                    fused_sum + math.log(max(probability, 1e-12)) + adjustment,
                )
            )
        return children

    frontier = [([], "", 0, 0.0, 0, 0.0, 0.0)]
    completed = []
    while frontier:
        next_frontier = []
        for state in frontier:
            for child in expand(state):
                if child[2] == total:
                    completed.append(child)
                else:
                    next_frontier.append(child)
        next_frontier.sort(key=lambda state: (-rank(state[6], state[4]), state[0]))
        frontier = next_frontier[:beam_width]
    if not completed:
        return DecodeResult("", 0.0, total)
    best = min(completed, key=lambda state: (-rank(state[6], state[4]), state[0]))
    return DecodeResult(
        best[1],
        min(1.0, math.exp(best[5] / best[4])),
        total,
        math.exp(best[3] / best[4]),
    )


@pytest.mark.parametrize("length_penalty", [0.0, 1.0])
@pytest.mark.parametrize("beam_width", [2, 4])
def test_user_fusion_beam_early_stop_matches_exhaustive_search(
    beam_width, length_penalty
):
    # 融合开启时 early-stop 仍无损：随机 LM + 随机用户分数下，剪枝
    # beam 与完整搜索逐位一致（文本/置信度/RAW/消耗音节），且剪枝
    # 只减不增 scorer 调用。融合项 <= 0 保证 fused joint 沿路径
    # 不增，原有上界论证原样成立。
    index = _index()
    for seed in range(6):
        for syllables in _random_syllable_sequences(3000 + seed, 6):
            user = _HashUserScorer(seed=seed + 11)
            fast = _CountingScorer(_HashScorer(seed=seed))
            slow = _CountingScorer(_HashScorer(seed=seed))
            result = ConstrainedGreedyDecoder.decode(
                fast,
                syllables,
                index,
                beam_width=beam_width,
                length_penalty=length_penalty,
                user_scorer=user,
                user_weight=0.35,
            )
            expected = _reference_fused_beam_decode(
                slow,
                user,
                0.35,
                syllables,
                index,
                beam_width=beam_width,
                length_penalty=length_penalty,
            )
            assert (
                result.text,
                result.consumed_syllables,
                result.confidence,
                result.raw_confidence,
            ) == (
                expected.text,
                expected.consumed_syllables,
                expected.confidence,
                expected.raw_confidence,
            ), (syllables, seed)
            assert fast.calls <= slow.calls


def test_user_fusion_all_none_scores_keep_baseline_ranking():
    # 用户 LM 无证据（全 None）：调整量恒 0，融合退化为纯 LM 排序，
    # 输出与基线一致（冷启动安全）。
    index = _index()
    for seed in range(4):
        for syllables in _random_syllable_sequences(4000 + seed, 5):
            scorer = _HashScorer(seed=seed)
            baseline = ConstrainedGreedyDecoder.decode(
                scorer, syllables, index, beam_width=4
            )
            cold = ConstrainedGreedyDecoder.decode(
                scorer,
                syllables,
                index,
                beam_width=4,
                user_scorer=lambda prefix, text: None,
                user_weight=0.2,
            )
            assert cold == baseline, (syllables, seed)


@pytest.mark.parametrize("fuzzy", [False, True])
def test_user_fusion_preserves_mask_legality_and_fuzzy_gate(fuzzy):
    # 融合只改打分：输出仍逐字通过 fuzzy gate（掩码合法性与 λ 无关）。
    index = _index()
    guard = _guard()
    for syllables in _FUZZY_TYPED_SEQUENCES:
        result = ConstrainedGreedyDecoder.decode(
            _HashScorer(seed=9),
            syllables,
            index,
            fuzzy=fuzzy,
            beam_width=4,
            user_scorer=_HashUserScorer(seed=5),
            user_weight=0.35,
        )
        if result.text:
            assert fuzzy_segment_ok(guard, result.text, syllables), (
                syllables,
                result.text,
            )


def test_user_fusion_rejects_invalid_user_scores():
    # 契约：用户分数必须是有限且 <= 0 的 log 概率——违反即 fail loud
    # （正数/NaN/inf 都会破坏 early-stop 的无损上界前提）。
    scorer = _FixedScorer({(): {0: 0.6, 1: 0.3}})
    with pytest.raises(ValueError):
        ConstrainedGreedyDecoder.decode(
            scorer,
            ("ni", "hao"),
            _index(),
            user_scorer=lambda prefix, text: 0.5,
            user_weight=0.1,
        )
    with pytest.raises(ValueError):
        ConstrainedGreedyDecoder.decode(
            scorer,
            ("ni", "hao"),
            _index(),
            user_scorer=lambda prefix, text: float("nan"),
            user_weight=0.1,
        )
    with pytest.raises(ValueError):
        ConstrainedGreedyDecoder.decode(
            scorer,
            ("ni", "hao"),
            _index(),
            user_scorer=lambda prefix, text: float("inf"),
            user_weight=0.1,
        )
    with pytest.raises(ValueError):
        ConstrainedGreedyDecoder.decode(
            scorer,
            ("ni", "hao"),
            _index(),
            user_scorer=lambda prefix, text: -0.5,
            user_weight=-0.1,
        )


def test_decode_rejects_invalid_length_penalty():
    # 契约：length_penalty 必须是有限且 >= 0 的浮点数——NaN 让 beam
    # 排序全崩（NaN 比较恒为 False，min/sort 回退到列表首位），负数
    # 使早停上界 L / total**penalty 不再成立（total**penalty < 1 放大
    # 负数上界，"无损"剪枝可能剪掉真正赢家）。与 user_weight 同款
    # fail loud，且在 decode() 入口校验，greedy 分支同样拒绝。
    scorer = _FixedScorer({(): {0: 0.6, 1: 0.3}, (0,): {1: 0.9}})
    for beam_width in (1, 4):
        for penalty in (
            float("nan"),
            float("inf"),
            float("-inf"),
            -1.0,
            -1e-9,
        ):
            with pytest.raises(ValueError):
                ConstrainedGreedyDecoder.decode(
                    scorer,
                    ("ni", "hao"),
                    _index(),
                    beam_width=beam_width,
                    length_penalty=penalty,
                )


def test_decode_accepts_finite_nonnegative_length_penalty():
    # 合法域不变：0.0 与正有限值照常接受，行为与改前一致。
    scorer = _FixedScorer({(): {0: 0.6, 1: 0.3}, (0,): {1: 0.9}})
    for beam_width in (1, 4):
        for penalty in (0.0, 1.0, 2.5):
            result = ConstrainedGreedyDecoder.decode(
                scorer,
                ("ni", "hao"),
                _index(),
                beam_width=beam_width,
                length_penalty=penalty,
            )
            assert result.text != ""
