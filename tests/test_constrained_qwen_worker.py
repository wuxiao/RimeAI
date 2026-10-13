"""Constrained qwen worker: protocol handling with injected fakes."""

import pytest
import torch

from rimeai_runtime.constrained_decoder import PinyinTokenIndex
from rimeai_runtime.pinyin_guard import PinyinGuard
from tools.constrained_qwen_worker import SEED_CONTEXT, WorkerRuntime, handle_request


class _StubTokenizer:
    vocab_size = 12
    eos_token_id = 5
    _tokens = ["你", "好", "世界", "的", "是", "<pad>", "\n", "长", "时", "四季", "界", "试"]
    _encodings = {"。": [11], "前文": [7]}

    def decode(self, ids):
        return self._tokens[ids[0]]

    def encode(self, text):
        return list(self._encodings.get(text, [4]))


class _ScriptedModel:
    """Returns one logits row per forward call, cycling through a script."""

    def __init__(self, vocab_size, rows):
        self._rows = list(rows)
        self._calls = 0
        self.calls_input_ids = []

    def __call__(self, *, input_ids, past_key_values=None, use_cache=True):
        self.calls_input_ids.append(input_ids[0].tolist())
        row = torch.full((1, 1, _StubTokenizer.vocab_size), -6.0)
        row[0, 0, self._rows[self._calls % len(self._rows)]] = 6.0
        self._calls += 1
        return type(
            "Output",
            (),
            {"logits": row, "past_key_values": object()},
        )()


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
        }
    )


def _runtime(model):
    return WorkerRuntime(
        tokenizer=_StubTokenizer(),
        model=model,
        device="cpu",
        artifact_id="stub:constrained-v1",
    )


def _request(**overrides):
    request = {
        "schema_version": 1,
        "task": "generate_sentence",
        "request_id": "req-1",
        "context": "前文",
        "pinyin": "nihao",
        "domain": "general",
        "candidates": ["你好"],
        "max_characters": 30,
    }
    request.update(overrides)
    return request


def _index():
    return PinyinTokenIndex.build(_StubTokenizer(), _guard())


def test_handle_request_returns_protocol_response():
    model = _ScriptedModel(12, rows=[0, 1])  # 你 then 好
    response = handle_request(_runtime(model), _guard(), _index(), _request())
    assert response["schema_version"] == 1
    assert response["request_id"] == "req-1"
    assert response["suggestion"] == "你好"
    assert 0.0 < response["confidence"] <= 1.0
    assert response["model_artifact_id"].endswith("constrained-v1")


def test_handle_request_with_empty_context_still_decodes():
    model = _ScriptedModel(12, rows=[0, 1])
    response = handle_request(
        _runtime(model), _guard(), _index(), _request(context="")
    )
    assert response["suggestion"] == "你好"


def test_handle_request_abstains_on_unsolvable_pinyin():
    model = _ScriptedModel(12, rows=[0, 1])
    response = handle_request(
        _runtime(model), _guard(), _index(), _request(pinyin="xx", candidates=["没"])
    )
    assert response["suggestion"] == ""
    assert response["confidence"] == 0.0


def test_handle_request_recovers_fuzzy_initials():
    model = _ScriptedModel(12, rows=[9])  # 四季
    response = handle_request(
        _runtime(model), _guard(), _index(), _request(pinyin="siji", candidates=["四季"])
    )
    assert response["suggestion"] == "四季"


def test_handle_request_seeds_natural_context_prefix():
    model = _ScriptedModel(12, rows=[0, 1])
    handle_request(_runtime(model), _guard(), _index(), _request(context=""))
    assert model.calls_input_ids[0] == [11]  # seed alone

    model_with_context = _ScriptedModel(12, rows=[0, 1])
    handle_request(
        _runtime(model_with_context), _guard(), _index(), _request(context="前文")
    )
    assert model_with_context.calls_input_ids[0] == [11, 7]  # seed + context
    assert SEED_CONTEXT == "。"


class _HistorySensitiveTokenizer(_StubTokenizer):
    vocab_size = 18
    _tokens = [
        "你", "好", "世界", "的", "是", "<pad>", "\n", "长", "时", "四季",
        "界", "试", "我", "们", "门", "明天", "我们", "今天",
    ]
    _encodings = {"。": [11]}


class _BigramModel:
    """Logits depend on the full input history (last token), unlike
    _ScriptedModel — this is what catches scorer cache misuse."""

    def __init__(self):
        self.rows = {
            11: {12: 0.5, 16: 0.2},   # after 。: 我 / 我们
            12: {14: 0.6, 13: 0.3},   # after 我: 门 / 们
            16: {15: 0.9},            # after 我们: 明天
            14: {15: 0.1},            # after 我门: 明天 (weak)
            13: {15: 0.9},            # after 我们(chars): 明天
            15: {0: 1.0},
        }

    def __call__(self, *, input_ids, past_key_values=None, use_cache=True):
        last = int(input_ids[0][-1])
        row = torch.full((1, 1, _HistorySensitiveTokenizer.vocab_size), -6.0)
        for token_id, probability in self.rows.get(last, {}).items():
            row[0, 0, token_id] = probability
        return type("Output", (), {"logits": row, "past_key_values": object()})()


def _history_runtime():
    return WorkerRuntime(
        tokenizer=_HistorySensitiveTokenizer(),
        model=_BigramModel(),
        device="cpu",
        artifact_id="stub:constrained-v1",
    )


def _history_guard():
    return PinyinGuard(
        pronunciations={
            "我": frozenset({"wo"}),
            "们": frozenset({"men"}),
            "门": frozenset({"men"}),
            "明": frozenset({"ming"}),
            "天": frozenset({"tian"}),
        }
    )


def test_scorer_scores_each_beam_path_against_its_own_history():
    # Beam divergence must not leak another path's KV history: the
    # 我们 path needs the after-我们 distribution (明天 0.9), not the
    # after-我 one (门/们), else it dies and 我门明天 wins.
    response = handle_request(
        _history_runtime(),
        _history_guard(),
        PinyinTokenIndex.build(_HistorySensitiveTokenizer(), _history_guard()),
        _request(pinyin="women mingtian", candidates=["我们明天"], context=""),
    )
    assert response["suggestion"] == "我们明天"


def test_beam_abstains_when_all_complete_paths_exceed_max_characters():
    model = _ScriptedModel(12, rows=[0, 1])
    # syllables need 3 chars, cap is 2: no complete path fits
    response = handle_request(
        _runtime(model),
        _guard(),
        _index(),
        _request(pinyin="nihaoshi", candidates=["你好是"], max_characters=2),
    )
    assert response["suggestion"] == ""
    assert response["confidence"] == 0.0
