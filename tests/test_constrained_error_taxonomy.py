"""Error taxonomy classification over eval details rows."""

from tools.constrained_error_taxonomy import (
    DICT_RECALL_MISS,
    GATE_MISMATCH,
    INDEX_RECALL_MISS,
    MODEL_PATH_MISS,
    PINYIN_MISMATCH,
    classify_detail,
)

from rimeai_runtime.constrained_decoder import PinyinTokenIndex
from rimeai_runtime.pinyin_guard import PinyinGuard


class _StubTokenizer:
    vocab_size = 12
    _tokens = ["你", "好", "世界", "的", "是", "<pad>", "\n", "长", "时", "四季", "界", "试"]

    def decode(self, ids):
        return self._tokens[ids[0]]


def _guard() -> PinyinGuard:
    return PinyinGuard(
        pronunciations={
            "你": frozenset({"ni"}),
            "好": frozenset({"hao"}),
            "世": frozenset({"shi"}),
            "界": frozenset({"jie"}),
            "四": frozenset({"si"}),
            "季": frozenset({"ji"}),
            "长": frozenset({"chang", "zhang"}),
        }
    )


def _index() -> PinyinTokenIndex:
    return PinyinTokenIndex.build(_StubTokenizer(), _guard())


def _detail(**overrides):
    row = {
        "id": "t",
        "domain": "general",
        "pinyin": "siji",
        "gold_text": "四季",
        "raw_suggestion": "四季",
        "status": "applied",
        "applied_hit": False,
    }
    row.update(overrides)
    return row


def test_gate_rejection_buckets_before_recall_checks():
    bucket, extra = classify_detail(_guard(), _index(), _detail(status="fallback-pinyin"))
    assert bucket == GATE_MISMATCH
    assert extra == {"gate_lost_win": True}


def test_gate_rejection_counts_non_win_separately():
    bucket, extra = classify_detail(
        _guard(),
        _index(),
        _detail(status="fallback-pinyin", raw_suggestion="时节"),
    )
    assert bucket == GATE_MISMATCH
    assert extra == {"gate_lost_win": False}


def test_unknown_character_is_dict_recall_miss():
    bucket, extra = classify_detail(
        _guard(), _index(), _detail(gold_text="四喵", pinyin="simiao")
    )
    assert bucket == DICT_RECALL_MISS
    assert extra == {"unknown_characters": "喵"}


def test_unmatchable_pinyin_is_pinyin_mismatch():
    bucket, _ = classify_detail(_guard(), _index(), _detail(pinyin="wujia"))
    assert bucket == PINYIN_MISMATCH


def test_untileable_gold_is_index_recall_miss():
    # 龙 is in the dictionary (pinyin aligns) but has no token in the stub
    # vocab, so the gold text cannot be tiled by indexed tokens — mirrors the
    # real-data 攤販/蠟燭 cases the old conflated bucket mislabeled.
    guard = PinyinGuard(
        pronunciations=_guard().pronunciations | {"龙": frozenset({"long"})}
    )
    bucket, _ = classify_detail(guard, _index(), _detail(gold_text="龙", pinyin="long"))
    assert bucket == INDEX_RECALL_MISS


def test_reachable_path_is_model_path_miss():
    bucket, _ = classify_detail(_guard(), _index(), _detail(raw_suggestion="世纪"))
    assert bucket == MODEL_PATH_MISS


def test_polyphone_gold_reaches_model_path_miss():
    bucket, _ = classify_detail(
        _guard(), _index(), _detail(gold_text="长", pinyin="zhang", raw_suggestion="场")
    )
    assert bucket == MODEL_PATH_MISS
