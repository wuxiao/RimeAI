"""Capture-source builder tests (tools/build_capture_source.py)."""

import bz2
import importlib.util
import sys
from pathlib import Path

import pytest

TOOL_PATH = (
    Path(__file__).resolve().parent.parent / "tools" / "build_capture_source.py"
)
spec = importlib.util.spec_from_file_location("build_capture_source", TOOL_PATH)
assert spec is not None and spec.loader is not None
builder = importlib.util.module_from_spec(spec)
sys.modules.setdefault("build_capture_source", builder)
spec.loader.exec_module(builder)


TRAD_SENTENCE = "這裡曾經是一個安靜的小村莊，村民世代以種植茶葉為主要生計來源。"
# Sentence-boundary punctuation is consumed by SENTENCE_BOUNDARY splitting.
SIMP_SENTENCE = "这里曾经是一个安静的小村庄，村民世代以种植茶叶为主要生计来源"
TRAD_FEATURE_CHARS = "這裡經個莊為來"


def write_dump(path: Path, pages: list[tuple[str, int, str]]) -> None:
    body = "".join(
        f"<page><title>{title}</title><ns>{ns}</ns>"
        f"<revision><text>{text}</text></revision></page>"
        for title, ns, text in pages
    )
    path.write_bytes(
        bz2.compress(f"<mediawiki>{body}</mediawiki>".encode())
    )


def test_strip_language_converter_prefers_zh_cn_branch() -> None:
    assert (
        builder.strip_language_converter("-{zh-cn:内存;zh-tw:記憶體}-")
        == "内存"
    )


def test_strip_language_converter_falls_back_to_last_branch() -> None:
    assert builder.strip_language_converter("-{zh-hant:軟體;zh-sg:软件}-") == "软件"


def test_strip_language_converter_bare_content_is_kept() -> None:
    # Flag-less form: the marker is dropped, content stays verbatim.
    assert builder.strip_language_converter("-{显示文本}-") == "显示文本"


def test_clean_wikitext_drops_file_links() -> None:
    raw = (
        "[[File:river.jpg|right|thumb|250px|河渡照片]]"
        "泰斯巴赫河是德国的河流，位于该国东南部。"
    )
    cleaned = builder.clean_wikitext(raw)
    assert "right" not in cleaned and "thumb" not in cleaned
    assert "河渡照片" not in cleaned  # caption goes away with the link
    assert "泰斯巴赫河是德国的河流" in cleaned


def test_zhwiki_documents_simplifies_and_filters_namespace(tmp_path: Path) -> None:
    dump = tmp_path / "zhwiki.xml.bz2"
    write_dump(
        dump,
        [
            ("測試條目", 0, TRAD_SENTENCE),
            ("討論頁", 1, TRAD_SENTENCE),
        ],
    )
    documents = list(
        builder.zhwiki_documents(dump, builder.OpenCC("t2s"))
    )
    assert len(documents) == 1
    title, url, text = documents[0]
    assert title == "測試條目"
    assert url == "https://zh.wikipedia.org/wiki/%E6%B8%AC%E8%A9%A6%E6%A2%9D%E7%9B%AE"
    assert text == SIMP_SENTENCE
    assert not any(char in text for char in TRAD_FEATURE_CHARS)


def test_zhwiki_documents_keeps_sentence_set_stable(tmp_path: Path) -> None:
    second = "茶葉的採摘時間會直接影響成品的香氣與口感，因此每年春季都是最繁忙的季節。"
    dump = tmp_path / "zhwiki.xml.bz2"
    write_dump(dump, [("雙句條目", 0, TRAD_SENTENCE + second)])
    documents = list(
        builder.zhwiki_documents(dump, builder.OpenCC("t2s"))
    )
    assert len(documents) == 1
    _, _, text = documents[0]
    # Re-splitting the joined output must yield the same sentence count.
    assert len(list(builder.normalized_sentences(text))) == 2


def test_main_requires_at_least_one_corpus(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    essay = tmp_path / "essay.txt"
    essay.write_text("词语\tci\n", encoding="utf-8")
    output = tmp_path / "out.jsonl"
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "build_capture_source",
            "--essay",
            str(essay),
            "--output",
            str(output),
        ],
    )
    assert builder.main() == 2
    assert "at least one corpus" in capsys.readouterr().err
