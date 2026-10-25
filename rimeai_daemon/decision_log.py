"""Local decision log: the sensing layer of the optimization loop (LM-003).

Records every suggestion the daemon actually surfaced — sync inference
results (``local_rank`` / ``local_sentence``) and neural-arm late frames
(``neural_late``) — as a ``pending`` row; the ``sentence_feedback``
frame from the input method resolves rows to a final outcome (newest
pending row gets the reported outcome, older pending rows for the same
request become ``superseded`` — that is exactly what the user saw).

Privacy contract (design D1/D2): pinyin (≤256 bytes) and the single
suggestion string plus structured metadata only — no keystroke stream,
no context text, no candidate pool — and nothing ever leaves the
machine (upload would be a separate, off-by-default switch that does
not exist yet).

Writes go through a bounded queue drained by one writer thread: the
inference path never blocks on sqlite, and a full queue drops the
record (sensing must never degrade typing) instead of back-pressuring.
Rows are pruned by retention age and a capacity cap (ring-buffer
semantics from the design's failure table).
"""

from __future__ import annotations

import logging
import queue
import sqlite3
import threading
import time
from pathlib import Path
from typing import Any

SOURCES = (
    "local_rank",
    "local_sentence",
    "neural_late",
    "cloud",
    "phrase_book",
    "continuation",
)
OUTCOMES = (
    "pending",
    "adopted",
    # 内容一致即采纳（2026-10-24 神经臂假阴性裁决）：首选一致合并
    # 场景下 Space 上屏与展示建议同文，语义上是采纳；保留路径信息
    # 与 adopted 区分（Tab 采纳 vs 主候选路径同文上屏）。
    "adopted_via_main",
    "rejected",
    "superseded",
    "expired",
    "ignored",
)
RESOLVABLE_OUTCOMES = OUTCOMES[1:]

PINYIN_MAX_BYTES = 256
SUGGESTION_MAX_CHARS = 128
ARTIFACT_ID_MAX_CHARS = 128
DEFAULT_RETENTION_DAYS = 60
DEFAULT_CAPACITY = 50_000
DEFAULT_QUEUE_LIMIT = 512

_DDL = """
PRAGMA journal_mode=WAL;
CREATE TABLE IF NOT EXISTS decisions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    created_at_ms INTEGER NOT NULL,
    source TEXT NOT NULL,
    request_id TEXT NOT NULL,
    composition_id TEXT NOT NULL,
    revision INTEGER NOT NULL,
    pinyin TEXT NOT NULL,
    suggestion TEXT NOT NULL,
    confidence REAL,
    model_artifact_id TEXT,
    outcome TEXT NOT NULL DEFAULT 'pending',
    outcome_at_ms INTEGER,
    UNIQUE(source, request_id)
);
CREATE INDEX IF NOT EXISTS decisions_created
ON decisions(created_at_ms);
CREATE INDEX IF NOT EXISTS decisions_source_outcome
ON decisions(source, outcome);
"""


class DecisionLogError(ValueError):
    """Invalid argument to the decision log (never a runtime failure)."""


def _now_ms() -> int:
    return int(time.time() * 1000)


class DecisionLog:
    """Async-write sqlite decision log owned by the daemon server."""

    def __init__(
        self,
        path: Path,
        *,
        retention_days: int = DEFAULT_RETENTION_DAYS,
        capacity: int = DEFAULT_CAPACITY,
        queue_limit: int = DEFAULT_QUEUE_LIMIT,
    ) -> None:
        if retention_days < 1 or capacity < 1:
            raise DecisionLogError("retention and capacity must be >= 1")
        self.path = path
        self.retention_days = retention_days
        self.capacity = capacity
        self.dropped = 0
        self._dropped_lock = threading.Lock()
        self._queue: queue.Queue[
            tuple[str, Any]
        ] = queue.Queue(maxsize=queue_limit)
        path.parent.mkdir(parents=True, exist_ok=True)
        self._connection = sqlite3.connect(path, timeout=2, check_same_thread=False)
        self._connection.execute("PRAGMA busy_timeout=1500")
        self._connection.executescript(_DDL)
        self._connection.commit()
        self._writer = threading.Thread(
            target=self._writer_loop,
            name="rimeai-decision-log",
            daemon=True,
        )
        self._closed = False
        self._writer.start()

    # -- public, non-blocking ------------------------------------------------

    def record(
        self,
        *,
        source: str,
        request_id: str,
        composition_id: str,
        revision: int,
        pinyin: str,
        suggestion: str,
        confidence: float | None,
        model_artifact_id: str | None,
        created_at_ms: int | None = None,
    ) -> bool:
        """Enqueues one pending decision; False when the queue is full
        (the record is dropped, the caller proceeds unaffected)."""
        if source not in SOURCES:
            raise DecisionLogError(f"unknown decision source: {source!r}")
        if (
            not isinstance(request_id, str)
            or not request_id
            or len(request_id) > 256
            or not isinstance(composition_id, str)
            or not isinstance(revision, int)
            or isinstance(revision, bool)
            or revision < 0
        ):
            raise DecisionLogError("decision identifiers are invalid")
        pinyin = pinyin if isinstance(pinyin, str) else ""
        while len(pinyin.encode("utf-8")) > PINYIN_MAX_BYTES:
            pinyin = pinyin[:-1]
        suggestion = suggestion if isinstance(suggestion, str) else ""
        suggestion = suggestion[:SUGGESTION_MAX_CHARS]
        if model_artifact_id is not None:
            model_artifact_id = str(model_artifact_id)[
                :ARTIFACT_ID_MAX_CHARS
            ]
        if confidence is not None:
            try:
                confidence = (
                    float(confidence) if 0 <= float(confidence) <= 1 else None
                )
            except (TypeError, ValueError):
                confidence = None
        payload = (
            source,
            request_id,
            composition_id,
            revision,
            pinyin,
            suggestion,
            confidence,
            model_artifact_id,
            created_at_ms if created_at_ms is not None else _now_ms(),
        )
        return self._enqueue(("record", payload))

    def resolve(
        self,
        request_id: str,
        outcome: str,
        *,
        resolved_at_ms: int | None = None,
    ) -> bool:
        """Enqueues resolution for every pending row of one request."""
        if outcome not in RESOLVABLE_OUTCOMES:
            raise DecisionLogError(f"unknown outcome: {outcome!r}")
        if not isinstance(request_id, str) or not request_id:
            raise DecisionLogError("request_id is invalid")
        payload = (
            request_id,
            outcome,
            resolved_at_ms if resolved_at_ms is not None else _now_ms(),
        )
        return self._enqueue(("resolve", payload))

    def flush(self, timeout: float = 5.0) -> bool:
        """Blocks until queued writes are durable; for tests."""
        done = threading.Event()
        try:
            self._queue.put(("barrier", done), timeout=timeout)
        except queue.Full:
            return False
        return done.wait(timeout=timeout)

    def close(self) -> None:
        """Flushes and joins the writer; idempotent."""
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
                elif kind == "resolve":
                    self._resolve_rows(*payload)
                elif kind == "barrier":
                    payload.set()
                elif kind == "close":
                    return
                handled += 1
                # Opportunistic ring-buffer prune: cheap, bounded, and
                # off the inference path entirely. Only after a full
                # batch — never on the very first record (tests, and
                # freshly created logs, would prune their only row).
                if handled % 1_024 == 0:
                    self._prune()
            except sqlite3.Error:
                # Sensing must never crash the daemon: log, drop, move on.
                logging.getLogger(__name__).exception(
                    "decision-log write failed"
                )
            finally:
                self._queue.task_done()

    def _record_row(self, payload: tuple) -> None:
        (
            source,
            request_id,
            composition_id,
            revision,
            pinyin,
            suggestion,
            confidence,
            model_artifact_id,
            created_at_ms,
        ) = payload
        self._connection.execute(
            """
            INSERT INTO decisions(
                created_at_ms, source, request_id, composition_id,
                revision, pinyin, suggestion, confidence,
                model_artifact_id
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(source, request_id) DO NOTHING
            """,
            (
                created_at_ms,
                source,
                request_id,
                composition_id,
                revision,
                pinyin,
                suggestion,
                confidence,
                model_artifact_id,
            ),
        )
        self._connection.commit()

    def _resolve_rows(
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
            """
            UPDATE decisions
            SET outcome = ?, outcome_at_ms = ?
            WHERE id = ?
            """,
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
