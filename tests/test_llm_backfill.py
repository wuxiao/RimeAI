"""Tests for L3 signature-phrase backfill into L1 (LP-009)."""

from __future__ import annotations

import json
import sqlite3
from pathlib import Path
from typing import Any

import pytest

# Reuses the Swift-mirroring DDL and layout helpers from the
# consolidation suite so the schema stays single-sourced in tests.
from test_consolidation import (
    PHRASEBOOK_DDL,
    insert_commit,
    make_layout,
)

from rimeai_cloud_broker.profile import (
    CloudProfileSummarizer,
    ProfileStore,
    make_semantic_consolidator,
)
from rimeai_daemon.consolidation import (
    ConsolidationPipeline,
    phrase_entry_id,
)
from rimeai_daemon.llm_backfill import (
    BackfillReport,
    SignaturePhraseBackfiller,
)
from rimeai_runtime.pinyin_guard import PinyinGuard

DICT_BODY = """# temp dictionary
...
你\tni
好\thao
世界\tshi jie
下午茶\txia wu cha
测试\tce shi
长\tchang
长\tzhang
接口\tjie kou
"""


def make_dictionary(tmp_path: Path) -> Path:
    path = tmp_path / "luna_test.dict.yaml"
    path.write_text(DICT_BODY, encoding="utf-8")
    return path


def make_backfiller(
    tmp_path: Path, *, dictionary: Path | None = None
) -> tuple[SignaturePhraseBackfiller, Path]:
    dictionary = dictionary or make_dictionary(tmp_path)
    phrasebook = tmp_path / "phrasebook.sqlite3"
    with sqlite3.connect(phrasebook) as db:
        db.executescript(PHRASEBOOK_DDL)
    guard = PinyinGuard.from_rime_dictionary(dictionary)
    return SignaturePhraseBackfiller(phrasebook, guard), phrasebook


def rows(phrasebook: Path) -> dict[str, tuple[int, str, int, str]]:
    with sqlite3.connect(phrasebook) as db:
        found = db.execute(
            "SELECT text, count, pinyin_keys, source, protected FROM phrasebook_entries"
        ).fetchall()
    return {row[0]: (row[1], row[2], row[3], row[4]) for row in found}


def test_backfill_inserts_annotated_llm_rows(tmp_path: Path):
    backfiller, phrasebook = make_backfiller(tmp_path)
    report = backfiller.backfill("global", ["下午茶", "你好世界"], now_ms=1_000)
    assert report == BackfillReport(inserted=2, removed=0)
    found = rows(phrasebook)
    assert found["下午茶"] == (0, "xiawucha", "llm", 0)
    # Segmented greedy match: 你+好+世界, syllables joined without
    # separators (HistoryCommit.pinyin shape).
    assert found["你好世界"] == (0, "nihaoshijie", "llm", 0)
    with sqlite3.connect(phrasebook) as db:
        stored_id = db.execute(
            "SELECT id FROM phrasebook_entries WHERE text = '下午茶'"
        ).fetchone()[0]
    assert stored_id == phrase_entry_id("global", "下午茶")


def test_backfill_is_idempotent_for_same_revision(tmp_path: Path):
    backfiller, phrasebook = make_backfiller(tmp_path)
    first = backfiller.backfill("global", ["下午茶"], now_ms=1_000)
    second = backfiller.backfill("global", ["下午茶"], now_ms=2_000)
    assert first.inserted == 1
    assert second == BackfillReport(inserted=0, removed=0)
    assert rows(phrasebook)["下午茶"] == (0, "xiawucha", "llm", 0)


def test_backfill_never_overwrites_real_evidence(tmp_path: Path):
    backfiller, phrasebook = make_backfiller(tmp_path)
    with sqlite3.connect(phrasebook) as db:
        db.execute(
            """
            INSERT INTO phrasebook_entries(
                id, domain, text, pinyin_keys, count,
                first_seen_ms, last_used_ms, source, protected
            ) VALUES (?, 'global', '测试', 'ceshi', 7, 1, 1, 'auto', 0)
            """,
            (phrase_entry_id("global", "测试"),),
        )
    report = backfiller.backfill("global", ["测试"], now_ms=9_000)
    assert report.inserted == 0
    assert rows(phrasebook)["测试"][:3] == (7, "ceshi", "auto")


def test_backfill_prunes_orphans_but_keeps_protected(tmp_path: Path):
    backfiller, phrasebook = make_backfiller(tmp_path)
    backfiller.backfill("global", ["下午茶", "接口"], now_ms=1_000)
    with sqlite3.connect(phrasebook) as db:
        db.execute("UPDATE phrasebook_entries SET protected = 1 WHERE text = '接口'")
    report = backfiller.backfill("global", ["下午茶"], now_ms=2_000)
    assert report.removed == 0  # 接口 is protected, not an orphan delete
    found = rows(phrasebook)
    assert set(found) == {"下午茶", "接口"}
    # An unprotected orphan is removed on the next reconcile.
    with sqlite3.connect(phrasebook) as db:
        db.execute("UPDATE phrasebook_entries SET protected = 0 WHERE text = '接口'")
    report = backfiller.backfill("global", ["下午茶"], now_ms=3_000)
    assert report.removed == 1
    assert set(rows(phrasebook)) == {"下午茶"}


def test_empty_signature_set_reconciles_to_no_llm_rows(tmp_path: Path):
    backfiller, phrasebook = make_backfiller(tmp_path)
    backfiller.backfill("global", ["下午茶"], now_ms=1_000)
    report = backfiller.backfill("global", [], now_ms=2_000)
    assert report == BackfillReport(inserted=0, removed=1)
    assert rows(phrasebook) == {}


def test_unannotatable_phrases_are_skipped(tmp_path: Path):
    backfiller, phrasebook = make_backfiller(tmp_path)
    report = backfiller.backfill("global", ["αβγ", "  ", "下午茶"], now_ms=1_000)
    assert report.inserted == 1
    assert set(rows(phrasebook)) == {"下午茶"}


def test_without_guard_backfill_is_a_no_op(tmp_path: Path):
    phrasebook = tmp_path / "phrasebook.sqlite3"
    with sqlite3.connect(phrasebook) as db:
        db.executescript(PHRASEBOOK_DDL)
    backfiller = SignaturePhraseBackfiller(phrasebook, None)
    assert backfiller.backfill("global", ["下午茶"]) == BackfillReport()
    assert backfiller.annotate("下午茶") is None
    assert rows(phrasebook) == {}


def test_polyphone_reading_is_deterministic(tmp_path: Path):
    backfiller, _ = make_backfiller(tmp_path)
    assert backfiller.annotate("长") == "chang"


def test_invalid_domain_is_rejected(tmp_path: Path):
    backfiller, _ = make_backfiller(tmp_path)
    with pytest.raises(ValueError):
        backfiller.backfill("Work_Chat", ["下午茶"])


def test_auto_consolidation_never_accumulates_llm_rows(tmp_path: Path):
    paths = make_layout(tmp_path)
    guard = PinyinGuard.from_rime_dictionary(make_dictionary(tmp_path))
    backfiller = SignaturePhraseBackfiller(paths.phrasebook_db, guard)
    report = backfiller.backfill("global", ["测试"], now_ms=1_000)
    assert report.inserted == 1
    before = rows(paths.phrasebook_db)["测试"]
    insert_commit(
        paths,
        suffix="000000000001",
        age_days=8,
        text="测试",
        pinyin="ceshi",
    )
    ConsolidationPipeline(paths).run_once()
    after = rows(paths.phrasebook_db)["测试"]
    assert after == before


def _completion(content: str) -> dict[str, Any]:
    return {
        "choices": [
            {
                "message": {"role": "assistant", "content": content},
                "finish_reason": "stop",
            }
        ]
    }


class _Commit:
    bundle_id: str
    committed_text: str

    def __init__(self, bundle_id: str, committed_text: str) -> None:
        self.bundle_id = bundle_id
        self.committed_text = committed_text


def test_semantic_consolidator_invokes_backfill_per_domain(
    tmp_path: Path,
):
    store = ProfileStore(tmp_path / "language_profile")

    def transport(
        path: str, payload: dict[str, Any], *, timeout: float
    ) -> dict[str, Any]:
        return _completion(json.dumps({"signature_phrases": ["下午茶"]}))

    calls: list[tuple[str, Any]] = []

    def spy(domain: str, profile: Any) -> None:
        calls.append((domain, profile.traits.get("signature_phrases")))

    consolidate = make_semantic_consolidator(
        store,
        CloudProfileSummarizer(transport),
        domain_resolver=lambda bundle: "global",
        signature_backfill=spy,
    )
    assert consolidate([_Commit("com.example.Chat", "文本")]) is True
    assert calls == [("global", ["下午茶"])]


def test_backfill_failure_never_fails_the_semantic_batch(tmp_path: Path):
    store = ProfileStore(tmp_path / "language_profile")

    def transport(
        path: str, payload: dict[str, Any], *, timeout: float
    ) -> dict[str, Any]:
        return _completion(json.dumps({"register": ["classical"]}))

    def exploding_backfill(domain: str, profile: Any) -> None:
        raise RuntimeError("phrasebook busy")

    consolidate = make_semantic_consolidator(
        store,
        CloudProfileSummarizer(transport),
        domain_resolver=lambda bundle: "global",
        signature_backfill=exploding_backfill,
    )
    assert consolidate([_Commit("com.example.Chat", "文本")]) is True
    assert store.load("global") is not None
