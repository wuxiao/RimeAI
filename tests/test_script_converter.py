import json
from pathlib import Path

import pytest

from rimeai_runtime.script_converter import SimplifiedScriptConverter

PROJECT_ROOT = Path(__file__).resolve().parents[1]


def _write_table(tmp_path: Path, *, phrases=None, characters=None) -> Path:
    payload = {
        "schema_version": 1,
        "name": "t2s-simplified",
        "max_phrase_length": 4,
        "phrases": phrases or {},
        "characters": characters or {},
    }
    path = tmp_path / "t2s-simplified.json"
    path.write_text(
        json.dumps(payload, ensure_ascii=False), encoding="utf-8"
    )
    return path


def test_load_returns_none_for_missing_file(tmp_path):
    assert SimplifiedScriptConverter.load(tmp_path / "absent.json") is None


def test_load_returns_none_for_malformed_payload(tmp_path):
    path = tmp_path / "t2s-simplified.json"
    path.write_text("{not json", encoding="utf-8")

    assert SimplifiedScriptConverter.load(path) is None


def test_load_returns_none_for_empty_character_table(tmp_path):
    path = _write_table(
        tmp_path,
        phrases={"乾隆": "乾隆"},
        characters={},
    )

    assert SimplifiedScriptConverter.load(path) is None


def test_convert_applies_character_fallback(tmp_path):
    converter = SimplifiedScriptConverter.load(
        _write_table(tmp_path, characters={"氣": "气", "後": "后"})
    )
    assert converter is not None

    assert converter.convert("今天天氣很好") == "今天天气很好"
    assert converter.convert("後面") == "后面"


def test_convert_phrase_match_wins_over_characters(tmp_path):
    converter = SimplifiedScriptConverter.load(
        _write_table(
            tmp_path,
            phrases={"乾隆": "乾隆", "乾乾淨淨": "干干净净"},
            characters={"乾": "干", "淨": "净"},
        )
    )
    assert converter is not None

    # The disambiguation phrase keeps 乾隆 intact while the bare
    # character default still converts other 乾 contexts.
    assert converter.convert("乾隆年間") == "乾隆年間"
    assert converter.convert("乾乾淨淨") == "干干净净"


def test_convert_longest_phrase_match_wins(tmp_path):
    converter = SimplifiedScriptConverter.load(
        _write_table(
            tmp_path,
            phrases={"一目瞭": "一目了", "一目瞭然": "一目了然"},
            characters={"瞭": "瞭"},
        )
    )
    assert converter is not None

    assert converter.convert("一目瞭然") == "一目了然"


def test_convert_passes_simplified_text_through(tmp_path):
    converter = SimplifiedScriptConverter.load(
        _write_table(tmp_path, characters={"氣": "气"})
    )
    assert converter is not None

    assert converter.convert("我们已是简体") == "我们已是简体"
    assert converter.convert("") == ""


def test_real_asset_converts_the_reference_samples():
    converter = SimplifiedScriptConverter.load(
        PROJECT_ROOT / ".rimeai/models/t2s-simplified.json"
    )
    if converter is None:
        pytest.skip("t2s asset not built")

    assert converter.convert("今天天氣很好") == "今天天气很好"
    assert converter.convert("乾隆年間") == "乾隆年间"
    assert converter.convert("皇后的後面") == "皇后的后面"
    assert converter.convert("乾乾淨淨") == "干干净净"
