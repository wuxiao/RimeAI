"""Domain-lexicon builder tests (tools/build_domain_lexicon.py)."""

from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path

import pytest

TOOL_PATH = (
    Path(__file__).resolve().parent.parent / "tools" / "build_domain_lexicon.py"
)
spec = importlib.util.spec_from_file_location("build_domain_lexicon", TOOL_PATH)
assert spec is not None and spec.loader is not None
builder = importlib.util.module_from_spec(spec)
sys.modules.setdefault("build_domain_lexicon", builder)
spec.loader.exec_module(builder)


ANNOTATOR_DICT = """---
name: annotator
version: "1"
...
好\thao
词\tci
面向\tmian xiang
对象\tdui xiang
设计\tshe ji
模式\tmo shi
好词\thao ci
"""


def write_lexicon(tmp_path: Path, entries: str, manifest: dict | None = None):
    source_dir = tmp_path / "lexicon"
    source_dir.mkdir()
    (source_dir / "source.tsv").write_text(entries, encoding="utf-8")
    payload = manifest or {
        "name": "test-lexicon",
        "version": "1",
        "license": "CC0-1.0",
    }
    (source_dir / "manifest.json").write_text(
        json.dumps(payload, ensure_ascii=False), encoding="utf-8"
    )
    annotator = tmp_path / "annotator.dict.yaml"
    annotator.write_text(ANNOTATOR_DICT, encoding="utf-8")
    return source_dir, annotator


def test_parse_source_tsv_defaults_dedupes_and_rejects_bad_weights(tmp_path):
    source_dir, annotator = write_lexicon(
        tmp_path,
        "好词\t99\n设计模式\n好词\t40\n坏词\tx\n",
    )
    entries, report = builder.parse_source_tsv(source_dir / "source.tsv")
    # 好词 takes the strongest weight; 设计模式 defaults to 50.
    assert [(e.text, e.weight) for e in entries] == [("好词", 99), ("设计模式", 50)]
    assert report.duplicate_merges == 1
    assert report.invalid_weight == ["坏词"]


def test_normalize_pinyin_strips_tones_and_maps_v():
    assert builder.normalize_pinyin("Mian Xiàng") == "mian xiang"
    assert builder.normalize_pinyin("lǜ") == "lv"
    assert builder.normalize_pinyin("  hao   ci ") == "hao ci"


def test_annotate_prefers_word_level_then_falls_back_per_character():
    word, char = builder.load_annotator_from_text(ANNOTATOR_DICT)
    # 词级命中优先：好词 直接取词典注音。
    assert builder.annotate("好词", word, char) == "haoci"
    # 逐字回退：设计 + 模式（词表里没有四字词）。
    assert builder.annotate("设计模式", word, char) == "sheji moshi"
    # 未覆盖：未知字返回 None。
    assert builder.annotate("未知", word, char) is None


def test_build_end_to_end_product_shape(tmp_path):
    source_dir, annotator = write_lexicon(
        tmp_path, "好词\t99\n设计模式\t80\n未知词\t70\n"
    )
    document, manifest, report = builder.build(source_dir, annotator)
    lines = document.splitlines()
    assert lines[0] == "---"
    assert 'name: test-lexicon' in lines[1]
    assert lines[4] == "..."
    # 未知词被注音器拒绝，不进入产物。
    assert report.unpronounceable == ["未知词"]
    assert manifest["entries"] == 2
    assert "好词\thaoci\t990" in document
    assert "设计模式\tsheji moshi\t800" in document
    assert "未知词" not in document


def test_load_manifest_rejects_missing_and_malformed(tmp_path, capsys):
    source_dir = tmp_path / "empty"
    source_dir.mkdir()
    with pytest.raises(SystemExit) as missing:
        builder.load_manifest(source_dir)
    assert missing.value.code == 2
    (source_dir / "manifest.json").write_text("{bad json", encoding="utf-8")
    with pytest.raises(SystemExit) as malformed:
        builder.load_manifest(source_dir)
    assert malformed.value.code == 2
    (source_dir / "manifest.json").write_text('{"version": 1}', encoding="utf-8")
    with pytest.raises(SystemExit) as nameless:
        builder.load_manifest(source_dir)
    assert nameless.value.code == 2


def test_cli_writes_dist(tmp_path, capsys):
    source_dir, annotator = write_lexicon(tmp_path, "好词\t99\n")
    out = tmp_path / "out"
    code = builder.main(
        [
            str(source_dir),
            "--annotate",
            str(annotator),
            "--out",
            str(out),
        ]
    )
    assert code == 0
    produced = (out / "test-lexicon.dict.yaml").read_text(encoding="utf-8")
    assert "好词\thaoci\t990" in produced
    manifest = json.loads((out / "manifest.json").read_text(encoding="utf-8"))
    assert manifest["entries"] == 1
    assert manifest["license"] == "CC0-1.0"
