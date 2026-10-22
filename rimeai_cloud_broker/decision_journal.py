"""Persistent teacher-decision journal: cloud-decisions.db (LM-003).

The cloud broker's in-process `_decision_cache` is a bounded LRU that
dies with the process — it cannot train anything (design G2). This
journal is the write-through counterpart decided on 2026-10-21: every
generate/abstain decision the broker synthesizes for an inference
request lands here with the request's pinyin, so LM-004 can read the
teacher side (this database) next to the daemon's decision log.

Privacy: same shape as the daemon decision log — pinyin (≤256 bytes),
the generated text, confidence and model metadata. No keystrokes, no
context text, no candidate pool, never uploaded (it *is* the local
mirror of decisions already made).
"""

from __future__ import annotations

import logging
import queue
import sqlite3
import threading
import time
from pathlib import Path
from typing import Any

OUTCOMES = (
    "pending",
    "adopted",
    "rejected",
    "superseded",
    "expired",
    "ignored",
)
RESOLVABLE_OUTCOMES = OUTCOMES[1:]

PINYIN_MAX_CHARS = 256
TEXT_MAX_CHARS = 160
DEFAULT_RETENTION_DAYS = 180
DEFAULT_CAPACITY = 100_000
DEFAULT_QUEUE_LIMIT = 512

_DDL = """
PRAGMA journal_mode=WAL;
CREATE TABLE IF NOT EXISTS decisions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    created_at_ms INTEGER NOT NULL,
    model_id TEXT NOT NULL,
    request_id TEXT,
    pinyin TEXT NOT NULL,
    decision TEXT NOT NULL,
    text TEXT NOT NULL,
    confidence REAL,
    outcome TEXT NOT NULL DEFAULT 'pending',
    outcome_at_ms INTEGER,
    UNIQUE(model_id, request_id)
);
CREATE INDEX IF NOT EXISTS cloud_decisions_created
ON decisions(created_at_ms);
CREATE INDEX IF NOT EXISTS cloud_decisions_request
ON decisions(request_id);
"""


class DecisionJournalError(ValueError):
    pass


def _now_ms() -> int:
    return int(time.time() * 1000)


class DecisionJournal:
    """Async-write sqlite journal owned by the cloud broker."""

    def __init__(
        self,
        path: Path,
        *,
        retention_days: int = DEFAULT_RETENTION_DAYS,
        capacity: int = DEFAULT_CAPACITY,
        queue_limit: int = DEFAULT_QUEUE_LIMIT,
    ) -> None:
        if retention_days < 1 or capacity < 1:
            raise DecisionJournalError(
                "retention and capacity must be >= 1"
            )
        self.path = path
        self.retention_days = retention_days
        self.capacity = capacity
        self.dropped = 0
        self._dropped_lock = threading.Lock()
        self._queue: queue.Queue[
            tuple[str, Any]
        ] = queue.Queue(maxsize=queue_limit)
        path.parent.mkdir(parents=True, exist_ok=True)
        self._connection = sqlite3.connect(
            path, timeout=2, check_same_thread=False
        )
        self._connection.execute("PRAGMA busy_timeout=1500")
        self._connection.executescript(_DDL)
        self._connection.commit()
        self._writer = threading.Thread(
            target=self._writer_loop,
            name="rimeai-cloud-decision-journal",
            daemon=True,
        )
        self._closed = False
        self._writer.start()

    def record(
        self,
        *,
        model_id: str,
        request_id: str | None,
        pinyin: str,
        decision: str,
        text: str,
        confidence: float | None,
        created_at_ms: int | None = None,
    ) -> bool:
        """Enqueues one teacher decision; False when dropped."""
        if not isinstance(model_id, str) or not model_id:
            raise DecisionJournalError("model_id is invalid")
        if decision not in {"generate", "abstain"}:
            raise DecisionJournalError(f"unknown decision: {decision!r}")
        if request_id is not None and (
            not isinstance(request_id, str)
            or not request_id
            or len(request_id) > 256
        ):
            raise DecisionJournalError("request_id is invalid")
        pinyin = pinyin if isinstance(pinyin, str) else ""
        pinyin = pinyin[:PINYIN_MAX_CHARS]
        text = text if isinstance(text, str) else ""
        text = text[:TEXT_MAX_CHARS]
        if confidence is not None:
            try:
                confidence = (
                    float(confidence)
                    if 0 <= float(confidence) <= 1
                    else None
                )
            except (TypeError, ValueError):
                confidence = None
        payload = (
            model_id,
            request_id,
            pinyin,
            decision,
            text,
            confidence,
            created_at_ms if created_at_ms is not None else _now_ms(),
        )
        return self._enqueue(("record", payload))

    def resolve(
        self, request_id: str, outcome: str
    ) -> bool:
        """Enqueues outcome resolution for the request's pending row."""
        if outcome not in RESOLVABLE_OUTCOMES:
            raise DecisionJournalError(f"unknown outcome: {outcome!r}")
        if not isinstance(request_id, str) or not request_id:
            raise DecisionJournalError("request_id is invalid")
        return self._enqueue(("resolve", (request_id, outcome, _now_ms())))

    def flush(self, timeout: float = 5.0) -> bool:
        done = threading.Event()
        try:
            self._queue.put(("barrier", done), timeout=timeout)
        except queue.Full:
            return False
        return done.wait(timeout=timeout)

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        self.flush()
        self._enqueue(("close", None), block=False)
        self._writer.join(timeout=5.0)
        self._connection.close()

    # -- internals -----------------------------------------------------------

    def _enqueue(
        self, item: tuple[str, Any], *, block: bool = True
    ) -> bool:
        if self._closed:
            return False
        try:
            if block:
                self._queue.put(item, timeout=0.05)
            else:
                self._queue.put_nowait(item)
            return True
        except queue.Full:
            with self._dropped_lock:
                self.dropped += 1
            return False

    def _writer_loop(self) -> None:
        handled = 0
        while True:
            kind, payload = self._queue.get()
            try:
                if kind == "record":
                    self._record_row(payload)
                    handled += 1
                    if handled % 1_024 == 0:
                        self._prune()
                elif kind == "resolve":
                    self._resolve_row(*payload)
                elif kind == "barrier":
                    payload.set()
                elif kind == "close":
                    return
            except sqlite3.Error:
                logging.getLogger(__name__).exception(
                    "cloud-decision journal write failed"
                )
            finally:
                self._queue.task_done()

    def _record_row(self, payload: tuple) -> None:
        (
            model_id,
            request_id,
            pinyin,
            decision,
            text,
            confidence,
            created_at_ms,
        ) = payload
        self._connection.execute(
            """
            INSERT INTO decisions(
                created_at_ms, model_id, request_id, pinyin,
                decision, text, confidence
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(model_id, request_id) DO NOTHING
            """,
            (
                created_at_ms,
                model_id,
                request_id,
                pinyin,
                decision,
                text,
                confidence,
            ),
        )
        self._connection.commit()

    def _resolve_row(
        self, request_id: str, outcome: str, resolved_at_ms: int
    ) -> None:
        cursor = self._connection.execute(
            """
            SELECT MAX(id) FROM decisions
            WHERE request_id = ? AND outcome = 'pending'
            """,
            (request_id,),
        )
        newest = cursor.fetchone()[0]
        if newest is None:
            return
        self._connection.execute(
            """
            UPDATE decisions
            SET outcome = 'superseded', outcome_at_ms = ?
            WHERE request_id = ? AND outcome = 'pending' AND id < ?
            """,
            (resolved_at_ms, request_id, newest),
        )
        self._connection.execute(
            "UPDATE decisions SET outcome = ?, outcome_at_ms = ?"
            " WHERE id = ?",
            (outcome, resolved_at_ms, newest),
        )
        self._connection.commit()

    def _prune(self, *, now_ms: int | None = None) -> int:
        now = now_ms if now_ms is not None else _now_ms()
        cutoff = now - self.retention_days * 86_400_000
        cursor = self._connection.execute(
            "DELETE FROM decisions WHERE created_at_ms < ?", (cutoff,)
        )
        removed = max(0, cursor.rowcount)
        cursor = self._connection.execute(
            """
            DELETE FROM decisions WHERE id IN (
                SELECT id FROM decisions
                ORDER BY id DESC LIMIT -1 OFFSET ?
            )
            """,
            (self.capacity,),
        )
        removed += max(0, cursor.rowcount)
        self._connection.commit()
        return removed
