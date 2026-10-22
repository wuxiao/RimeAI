"""Cloud-decision journal (LM-003): teacher-decision write-through."""

from __future__ import annotations

import sqlite3
from pathlib import Path
from typing import Any

import pytest

from rimeai_cloud_broker.cloud_model import CloudModelClient
from rimeai_cloud_broker.decision_journal import (
    DecisionJournal,
    DecisionJournalError,
)


class _StubGenerateRanker(CloudModelClient):
    """Single-turn generate stub mirroring the transport shape."""

    def __init__(self, text: str) -> None:
        super().__init__(api_key_loader=lambda: "secret")
        self._text = text

    def _post_json(
        self, path: str, payload: dict[str, Any], *, timeout: float, api_key=None
    ) -> dict[str, Any]:
        return {
            "choices": [
                {
                    "message": {"content": self._text},
                    "finish_reason": "stop",
                }
            ]
        }


def _cloud_request() -> dict[str, Any]:
    return {
        "schema_version": 1,
        "type": "inference",
        "api_key": "secret",
        "request_id": "cloud-request-1",
        "composition_id": "10000000-0000-0000-0000-000000000001",
        "revision": 2,
        "bundle_id": "com.example.Editor",
        "app_session_id": "com.example.Editor#session",
        "client_session_id": "client-session",
        "model_id": "glm-5.3-flash",
        "deadline_ms": 800,
        "pinyin": "niihao",
        "candidates": [],
        "context": "",
        "recent_context": "",
        "history_generation": 0,
        "allow_sentence": True,
        "sensitive": False,
    }


def test_journal_record_and_resolve(tmp_path: Path):
    journal = DecisionJournal(tmp_path / "cloud-decisions.db")
    try:
        assert journal.record(
            model_id="glm-5.3-flash",
            request_id="cloud-request-1",
            pinyin="niihao",
            decision="generate",
            text="你好",
            confidence=1.0,
            created_at_ms=1_000,
        )
        assert journal.flush()
        with sqlite3.connect(tmp_path / "cloud-decisions.db") as db:
            row = db.execute(
                "SELECT model_id, request_id, pinyin, decision, text,"
                " outcome FROM decisions"
            ).fetchone()
        assert row == (
            "glm-5.3-flash",
            "cloud-request-1",
            "niihao",
            "generate",
            "你好",
            "pending",
        )
        # Duplicate (model_id, request_id) is idempotent.
        journal.record(
            model_id="glm-5.3-flash",
            request_id="cloud-request-1",
            pinyin="niihao",
            decision="generate",
            text="你好",
            confidence=1.0,
        )
        assert journal.flush()
        with sqlite3.connect(tmp_path / "cloud-decisions.db") as db:
            assert (
                db.execute("SELECT COUNT(*) FROM decisions").fetchone()[0]
                == 1
            )
        assert journal.resolve("cloud-request-1", "adopted")
        assert journal.flush()
        with sqlite3.connect(tmp_path / "cloud-decisions.db") as db:
            assert db.execute(
                "SELECT outcome FROM decisions"
            ).fetchone() == ("adopted",)
    finally:
        journal.close()


def test_journal_invalid_arguments_raise(tmp_path: Path):
    journal = DecisionJournal(tmp_path / "cloud-decisions.db")
    try:
        with pytest.raises(DecisionJournalError):
            journal.record(
                model_id="glm-5.3-flash",
                request_id=None,
                pinyin="a",
                decision="not-a-decision",
                text="",
                confidence=None,
            )
        with pytest.raises(DecisionJournalError):
            journal.resolve("cloud-request-1", "pending")
    finally:
        journal.close()


def test_rank_writes_through_to_the_journal(tmp_path: Path):
    journal = DecisionJournal(tmp_path / "cloud-decisions.db")
    ranker = _StubGenerateRanker("测试你好")
    ranker.decision_journal = journal
    try:
        decision = ranker.rank(_cloud_request())
        assert decision["decision"] == "generate"
        assert journal.flush()
        with sqlite3.connect(tmp_path / "cloud-decisions.db") as db:
            row = db.execute(
                "SELECT model_id, request_id, pinyin, decision, text"
                " FROM decisions"
            ).fetchone()
        assert row == (
            "glm-5.3-flash",
            "cloud-request-1",
            "niihao",
            "generate",
            "测试你好",
        )
        # The cache hit path journals too (re-decided locally, still a
        # teacher decision the dataset builder must see).
        second = ranker.rank(_cloud_request())
        assert second["decision"] == "generate"
        assert journal.flush()
        with sqlite3.connect(tmp_path / "cloud-decisions.db") as db:
            assert (
                db.execute("SELECT COUNT(*) FROM decisions").fetchone()[0]
                == 1
            )
    finally:
        journal.close()


def test_journal_failure_never_fails_the_request(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    journal = DecisionJournal(tmp_path / "cloud-decisions.db")

    def broken_record(**kwargs: Any) -> bool:
        raise RuntimeError("journal unavailable")

    monkeypatch.setattr(journal, "record", broken_record)
    ranker = _StubGenerateRanker("测试你好")
    ranker.decision_journal = journal
    try:
        decision = ranker.rank(_cloud_request())
        assert decision["decision"] == "generate"
    finally:
        journal.close()
