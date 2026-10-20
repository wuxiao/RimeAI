"""Idle consolidation pipeline for the language profile (LP-004).

Fetches raw history commits past the rolling window, folds them into the
L1 phrasebook and the L2 user language model (statistics phase), then
either runs the optional L3 semantic consolidator or explicitly skips it,
and finally prunes raw text that satisfied the double-delete guard. Steps
are idempotent across completed rounds via the consolidation watermarks
maintained in the history database; a mid-round crash (claim expires while
the rows are still 'raw') re-fetches the batch and may re-count phrase
frequencies, domain stats, and user-LM statistics. Rows whose statistics
phase completed but whose semantic phase failed stay 'statistics_done' and
are re-fetched for the semantic pass on later rounds without re-counting
statistics; only rows in a terminal state ('consolidated' or explicitly
'skipped') at or below the semantic watermark are ever pruned.
"""

from __future__ import annotations

import contextlib
import hashlib
import logging
import sqlite3
import threading
import time
from collections.abc import Callable, Sequence
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from .user_lm import UserLanguageModel

WINDOW_DAYS = 7
BATCH_LIMIT = 512
COLD_START_THRESHOLD = 50
MAX_PHRASE_BYTES = 1_024
DOMAIN_SEPARATOR = "\x1f"
DAY_MILLISECONDS = 86_400_000
# A fetched batch is claimed for this long; a crashed round's claims expire
# and the rows become fetchable again. Rounds are hours apart, so a short
# lease is safe. The claim table is owned by this module (the Swift store
# never reads or writes it).
CLAIM_LEASE_MILLISECONDS = 15 * 60 * 1000

SemanticConsolidator = Callable[[Sequence["RawCommit"]], bool]


class ConsolidationError(RuntimeError):
    pass


@dataclass(frozen=True)
class ConsolidationPaths:
    history_db: Path
    phrasebook_db: Path
    user_lm: Path


@dataclass(frozen=True)
class RawCommit:
    id: str
    rowid: int
    committed_at_ms: int
    bundle_id: str
    pinyin: str
    committed_text: str
    state: str = "raw"


@dataclass(frozen=True)
class ConsolidationReport:
    considered: int = 0
    statistics_done: int = 0
    semantic_done: int = 0
    pruned: int = 0
    domains: dict[str, int] = field(default_factory=dict)

    def to_payload(self) -> dict[str, Any]:
        return {
            "considered": self.considered,
            "statistics_done": self.statistics_done,
            "semantic_done": self.semantic_done,
            "pruned": self.pruned,
            "domains": dict(self.domains),
        }


@dataclass(frozen=True)
class SemanticPass:
    """State of the L3 semantic pass for one consolidation round.

    `permanently_unavailable` separates the two reasons a round can run
    without a consolidator:

    - True: the semantic pass will never run here — the user opted out
      of cloud compression (no credential configured, or the pass is
      switched off), or this process does not run L3 at all. The L3
      backlog can be closed for good: its rows become terminal
      ('skipped') and the raw text is evicted, so the history database
      stays bounded.
    - False: the cloud is only temporarily unusable (a credential file
      that cannot be parsed, or one that is exposed to other local
      accounts). The backlog must survive so pending summaries are still
      produced once the cloud works again — a transient fault must not
      silently drop the user's L3 backlog.
    """

    consolidator: SemanticConsolidator | None = None
    permanently_unavailable: bool = True


def phrase_entry_id(domain: str, text: str) -> str:
    """Must match PhraseBookStore.entryIdentifier in Swift."""
    payload = f"{domain}{DOMAIN_SEPARATOR}{text}".encode()
    return hashlib.sha256(payload).hexdigest()


def _connect(database: Path) -> sqlite3.Connection:
    connection = sqlite3.connect(database, timeout=2)
    connection.execute("PRAGMA busy_timeout=1500")
    return connection


class ConsolidationPipeline:
    def __init__(
        self,
        paths: ConsolidationPaths,
        *,
        window_days: int = WINDOW_DAYS,
        batch_limit: int = BATCH_LIMIT,
        cold_start_threshold: int = COLD_START_THRESHOLD,
    ) -> None:
        self.paths = paths
        self.window_days = window_days
        self.batch_limit = batch_limit
        self.cold_start_threshold = cold_start_threshold

    def run_once(
        self,
        *,
        semantic_consolidator: SemanticConsolidator | None = None,
        semantic_permanently_unavailable: bool = True,
    ) -> ConsolidationReport:
        """Runs one consolidation round.

        `semantic_permanently_unavailable` says whether the missing
        semantic pass is final (the user opted out — the backlog is
        closed and the raw text evicted) or transient (a broken cloud
        credential — the backlog is kept for a later retry).
        """
        batch = self._fetch_batch()
        if not batch:
            # Still honor explicit skip + prune for earlier batches.
            _, pruned = self._semantic_phase(
                [],
                semantic_consolidator,
                semantic_permanently_unavailable,
            )
            return ConsolidationReport(pruned=pruned)
        # Statistics run only for fresh 'raw' rows; 'statistics_done' rows
        # are a semantic-retry backlog whose L1/L2 counts already happened.
        fresh = [commit for commit in batch if commit.state == "raw"]
        effective: dict[str, str] = {}
        if fresh:
            effective, mapped = self._resolve_domains(fresh)
            self._update_phrasebook(fresh, effective, mapped)
            self._update_user_lm(fresh, effective)
            self._mark_statistics(fresh)
        semantic_done, pruned = self._semantic_phase(
            batch,
            semantic_consolidator,
            semantic_permanently_unavailable,
        )
        return ConsolidationReport(
            considered=len(batch),
            statistics_done=len(fresh),
            semantic_done=semantic_done,
            pruned=pruned,
            domains=dict(_count_domains(fresh, effective)) if fresh else {},
        )

    # -- phase 1: fetch ------------------------------------------------------

    def _fetch_batch(self) -> list[RawCommit]:
        """Claims a batch atomically so two processes can never
        double-process the same rows, even if two schedulers are
        misconfigured to run against the same database."""
        cutoff_ms = int((time.time() - self.window_days * 86_400) * 1000)
        now_ms = int(time.time() * 1000)
        with contextlib.closing(_connect(self.paths.history_db)) as db:
            db.execute("BEGIN IMMEDIATE")
            try:
                db.execute(
                    """
                    CREATE TABLE IF NOT EXISTS consolidation_claims (
                        commit_id TEXT PRIMARY KEY NOT NULL,
                        claimed_at_ms INTEGER NOT NULL
                    )
                    """
                )
                db.execute(
                    "DELETE FROM consolidation_claims WHERE claimed_at_ms < ?",
                    (now_ms - CLAIM_LEASE_MILLISECONDS,),
                )
                fresh_rows = db.execute(
                    """
                    SELECT id, rowid, committed_at_ms, bundle_id, pinyin,
                           committed_text, consolidation_state
                    FROM history_commits
                    WHERE consolidation_state = 'raw'
                      AND committed_at_ms <= ?
                      AND id NOT IN (
                          SELECT commit_id FROM consolidation_claims
                      )
                    ORDER BY rowid ASC
                    LIMIT ?
                    """,
                    (cutoff_ms, self.batch_limit),
                ).fetchall()
                # L3 retry backlog: statistics already counted, only the
                # semantic pass is re-attempted for these rows.
                retry_rows = []
                remaining = self.batch_limit - len(fresh_rows)
                if remaining > 0:
                    retry_rows = db.execute(
                        """
                        SELECT id, rowid, committed_at_ms, bundle_id, pinyin,
                               committed_text, consolidation_state
                        FROM history_commits
                        WHERE consolidation_state = 'statistics_done'
                          AND id NOT IN (
                              SELECT commit_id FROM consolidation_claims
                          )
                        ORDER BY rowid ASC
                        LIMIT ?
                        """,
                        (remaining,),
                    ).fetchall()
                rows = [*fresh_rows, *retry_rows]
                db.executemany(
                    """
                    INSERT OR REPLACE INTO consolidation_claims(
                        commit_id, claimed_at_ms
                    ) VALUES (?, ?)
                    """,
                    [(row[0], now_ms) for row in rows],
                )
                db.commit()
            except BaseException:
                db.rollback()
                raise
        return [
            RawCommit(
                id=row[0],
                rowid=row[1],
                committed_at_ms=row[2],
                bundle_id=row[3],
                pinyin=row[4],
                committed_text=row[5],
                state=row[6],
            )
            for row in rows
        ]

    # -- phase 2: domains ----------------------------------------------------

    def _resolve_domains(
        self, batch: Sequence[RawCommit]
    ) -> tuple[dict[str, str], dict[str, int]]:
        """Returns (effective bundle→domain map, mapped-domain commit
        counts). Mapped counts feed domain_stats even while a domain is
        still cold-start-routed to global, so slow-trickle domains can
        eventually cross the threshold."""
        mappings = self._domain_mappings()
        per_bundle = _count_bundles(batch)
        stats = self._domain_stats()
        effective: dict[str, str] = {}
        for bundle_id, commit_count in per_bundle.items():
            domain = mappings.get(bundle_id) or "global"
            if domain == "global":
                effective[bundle_id] = "global"
                continue
            total = stats.get(domain, 0) + commit_count
            if total < self.cold_start_threshold:
                # Cold start: the domain has not earned its own artifacts.
                effective[bundle_id] = "global"
            else:
                effective[bundle_id] = domain
        mapped = _count_domains(
            batch,
            {
                commit.bundle_id: mappings.get(commit.bundle_id) or "global"
                for commit in batch
            },
        )
        return effective, mapped

    def _domain_mappings(self) -> dict[str, str]:
        with contextlib.closing(_connect(self.paths.phrasebook_db)) as db:
            rows = db.execute(
                "SELECT bundle_id, domain FROM domain_map"
            ).fetchall()
        return {row[0]: row[1] for row in rows}

    def _domain_stats(self) -> dict[str, int]:
        with contextlib.closing(_connect(self.paths.phrasebook_db)) as db:
            rows = db.execute(
                "SELECT domain, commit_count FROM domain_stats"
            ).fetchall()
        return {row[0]: row[1] for row in rows}

    # -- phase 3: L1 phrasebook ---------------------------------------------

    def _update_phrasebook(
        self,
        batch: Sequence[RawCommit],
        effective: dict[str, str],
        mapped: dict[str, int],
    ) -> None:
        now_ms = int(time.time() * 1000)
        # domain_stats counts commits by their MAPPED domain, even while a
        # domain is still cold-start-routed to global — otherwise a
        # slow-trickle domain could never cross the threshold.
        stats_update = dict(mapped)
        with contextlib.closing(_connect(self.paths.phrasebook_db)) as db:
            db.execute("BEGIN IMMEDIATE")
            try:
                for commit in batch:
                    self._upsert_phrase(db, commit, effective, now_ms)
                for domain, count in stats_update.items():
                    db.execute(
                        """
                        INSERT INTO domain_stats(
                            domain, commit_count, updated_at_ms
                        ) VALUES (?, ?, ?)
                        ON CONFLICT(domain) DO UPDATE SET
                            commit_count = commit_count + excluded.commit_count,
                            updated_at_ms = excluded.updated_at_ms
                        """,
                        (domain, count, now_ms),
                    )
                db.commit()
            except BaseException:
                db.rollback()
                raise

    def _upsert_phrase(
        self,
        db: sqlite3.Connection,
        commit: RawCommit,
        domains: dict[str, str],
        now_ms: int,
    ) -> None:
        text = commit.committed_text
        if not text or len(text.encode("utf-8")) > MAX_PHRASE_BYTES:
            return
        domain = domains.get(commit.bundle_id, "global")
        db.execute(
            """
            INSERT INTO phrasebook_entries(
                id, domain, text, pinyin_keys, count,
                first_seen_ms, last_used_ms, source, protected
            ) VALUES (?, ?, ?, ?, 1, ?, ?, 'auto', 0)
            ON CONFLICT(domain, text) DO UPDATE SET
                count = count + 1,
                last_used_ms = excluded.last_used_ms
            """,
            (
                phrase_entry_id(domain, text),
                domain,
                text,
                commit.pinyin.lower(),
                commit.committed_at_ms,
                now_ms,
            ),
        )

    # -- phase 4: L2 user LM ---------------------------------------------------

    def _update_user_lm(
        self,
        batch: Sequence[RawCommit],
        domains: dict[str, str],
    ) -> None:
        model = UserLanguageModel.load(self.paths.user_lm)
        grouped: dict[str, list[str]] = {}
        for commit in batch:
            domain = domains.get(commit.bundle_id, "global")
            grouped.setdefault(domain, []).append(commit.committed_text)
        for domain, texts in grouped.items():
            model.update(domain, texts)
        self.paths.user_lm.parent.mkdir(parents=True, exist_ok=True)
        model.save(self.paths.user_lm)

    # -- phase 5: state transitions -------------------------------------------

    def _mark_statistics(self, batch: Sequence[RawCommit]) -> None:
        ids = [commit.id for commit in batch]
        with contextlib.closing(_connect(self.paths.history_db)) as db:
            db.execute("BEGIN IMMEDIATE")
            try:
                db.executemany(
                    """
                    UPDATE history_commits
                    SET consolidation_state = 'statistics_done'
                    WHERE id = ? AND consolidation_state = 'raw'
                    """,
                    [(commit_id,) for commit_id in ids],
                )
                db.executemany(
                    "DELETE FROM consolidation_claims WHERE commit_id = ?",
                    [(commit_id,) for commit_id in ids],
                )
                self._advance_watermark(db, "statistics_watermark")
                db.commit()
            except BaseException:
                db.rollback()
                raise

    def _semantic_phase(
        self,
        batch: Sequence[RawCommit],
        consolidator: SemanticConsolidator | None,
        permanently_unavailable: bool = True,
    ) -> tuple[int, int]:
        """Runs (or skips) the L3 pass, then prunes prunable rows.

        Returns (semantic_done, pruned) where pruned counts removed
        raw-text rows."""
        semantic_done = 0
        if consolidator is not None and batch:
            try:
                succeeded = bool(consolidator(list(batch)))
            except Exception as error:
                # Clean failure: release claims immediately so the next
                # round can retry instead of waiting out the lease. Rows
                # stay 'statistics_done' and are re-fetched for L3 only.
                self._release_claims(batch)
                raise ConsolidationError(
                    "semantic consolidator failed; batch kept for retry"
                ) from error
            if succeeded:
                semantic_done = self._mark_semantic(batch)
        elif batch:
            # No consolidator this round: release the claims so the same
            # rows are picked up again by the next round instead of
            # waiting out the claim lease.
            self._release_claims(batch)
        pruned = self._skip_or_prune(consolidator, permanently_unavailable)
        return semantic_done, pruned

    def _release_claims(self, batch: Sequence[RawCommit]) -> None:
        ids = [commit.id for commit in batch]
        if not ids:
            return
        with contextlib.closing(_connect(self.paths.history_db)) as db:
            db.execute("BEGIN IMMEDIATE")
            try:
                db.executemany(
                    "DELETE FROM consolidation_claims WHERE commit_id = ?",
                    [(commit_id,) for commit_id in ids],
                )
                db.commit()
            except BaseException:
                db.rollback()
                raise

    def _skip_or_prune(
        self,
        consolidator: SemanticConsolidator | None,
        permanently_unavailable: bool = True,
    ) -> int:
        with contextlib.closing(_connect(self.paths.history_db)) as db:
            db.execute("BEGIN IMMEDIATE")
            try:
                if consolidator is None and permanently_unavailable:
                    # The semantic pass will never run for these rows, so
                    # they move to the terminal 'skipped' state and become
                    # prunable below the semantic watermark.
                    db.execute(
                        """
                        UPDATE history_commits
                        SET consolidation_state = 'skipped'
                        WHERE consolidation_state = 'statistics_done'
                        """
                    )
                    db.execute(
                        """
                        DELETE FROM consolidation_claims
                        WHERE commit_id IN (
                            SELECT id FROM history_commits
                            WHERE consolidation_state = 'skipped'
                        )
                        """
                    )
                    self._advance_watermark(db, "semantic_watermark")
                elif consolidator is None:
                    # The cloud is only temporarily unusable (a broken or
                    # world-readable credential file). The L3 backlog
                    # stays 'statistics_done' and the semantic watermark
                    # does not advance, so nothing is pruned and the rows
                    # are retried once the cloud works again — a transient
                    # credential fault must not silently drop the user's
                    # pending summaries.
                    pass
                pruned = self._prune(db)
                db.commit()
            except BaseException:
                db.rollback()
                raise
        return pruned

    def _mark_semantic(self, batch: Sequence[RawCommit]) -> int:
        ids = [commit.id for commit in batch]
        with contextlib.closing(_connect(self.paths.history_db)) as db:
            db.execute("BEGIN IMMEDIATE")
            try:
                db.executemany(
                    """
                    UPDATE history_commits
                    SET consolidation_state = 'consolidated'
                    WHERE id = ? AND consolidation_state = 'statistics_done'
                    """,
                    [(commit_id,) for commit_id in ids],
                )
                db.executemany(
                    "DELETE FROM consolidation_claims WHERE commit_id = ?",
                    [(commit_id,) for commit_id in ids],
                )
                self._advance_watermark(db, "semantic_watermark")
                db.commit()
            except BaseException:
                db.rollback()
                raise
        return len(ids)

    def _advance_watermark(
        self, db: sqlite3.Connection, column: str
    ) -> None:
        now_ms = int(time.time() * 1000)
        if column == "statistics_watermark":
            db.execute(
                """
                UPDATE consolidation_state
                SET statistics_watermark = MAX(
                        statistics_watermark,
                        (
                            SELECT IFNULL(MAX(rowid), 0)
                            FROM history_commits
                            WHERE consolidation_state = 'statistics_done'
                        )
                    ),
                    updated_at_ms = ?
                WHERE id = 1
                """,
                (now_ms,),
            )
        else:
            db.execute(
                """
                UPDATE consolidation_state
                SET semantic_watermark = MAX(
                        semantic_watermark,
                        (
                            SELECT IFNULL(MAX(rowid), 0)
                            FROM history_commits
                            WHERE consolidation_state IN (
                                'consolidated', 'skipped'
                            )
                        )
                    ),
                    updated_at_ms = ?
                WHERE id = 1
                """,
                (now_ms,),
            )

    def _prune(self, db: sqlite3.Connection) -> int:
        row = db.execute(
            "SELECT semantic_watermark FROM consolidation_state WHERE id = 1"
        ).fetchone()
        watermark = row[0] if row else 0
        if watermark <= 0:
            return 0
        db.execute(
            """
            DELETE FROM history_fts
            WHERE commit_id IN (
                SELECT id FROM history_commits
                WHERE consolidation_state IN ('consolidated', 'skipped')
                  AND rowid <= ?
            )
            """,
            (watermark,),
        )
        cursor = db.execute(
            """
            DELETE FROM history_commits
            WHERE consolidation_state IN ('consolidated', 'skipped')
              AND rowid <= ?
            """,
            (watermark,),
        )
        pruned = max(cursor.rowcount, 0)
        if pruned:
            # Invalidate client history caches only when the visible
            # history actually changed; empty rounds must not bump it.
            db.execute(
                """
                UPDATE history_metadata
                SET generation = generation + 1
                WHERE id = 1
                """
            )
        return pruned


def _count_bundles(batch: Sequence[RawCommit]) -> dict[str, int]:
    counts: dict[str, int] = {}
    for commit in batch:
        counts[commit.bundle_id] = counts.get(commit.bundle_id, 0) + 1
    return counts


def _count_domains(
    batch: Sequence[RawCommit], domains: dict[str, str]
) -> dict[str, int]:
    counts: dict[str, int] = {}
    for commit in batch:
        domain = domains.get(commit.bundle_id, "global")
        counts[domain] = counts.get(domain, 0) + 1
    return counts


class IdleConsolidationScheduler:
    """Drives the consolidation loop inside the daemon process.

    A round fires only after the keyboard has been quiet for
    `idle_seconds` (no inference traffic) and at least
    `min_round_interval` has passed since the previous round, which keeps
    the cadence daily-ish under continuous use. Process-internal mutual
    exclusion guards overlapping rounds; crash idempotence comes from the
    consolidation watermarks in the history database."""

    def __init__(
        self,
        pipeline: ConsolidationPipeline,
        *,
        idle_seconds: float = 600.0,
        min_round_interval: float = 21_600.0,
        poll_seconds: float = 30.0,
        semantic_consolidator: SemanticConsolidator | None = None,
        semantic_consolidator_provider: (
            Callable[[], SemanticConsolidator | SemanticPass | None] | None
        ) = None,
        clock: Callable[[], float] | None = None,
        sleeper: Callable[[float], None] | None = None,
    ) -> None:
        if idle_seconds <= 0 or min_round_interval <= 0:
            raise ValueError("scheduler intervals must be positive")
        self._pipeline = pipeline
        self._idle_seconds = idle_seconds
        self._min_round_interval = min_round_interval
        self._poll_seconds = poll_seconds
        self._semantic_consolidator = semantic_consolidator
        # Evaluated at the start of every round (P2-1/P3-3): credentials
        # and domain mappings change at runtime, so the consolidator must
        # be re-resolved per round instead of once at process start.
        self._semantic_consolidator_provider = semantic_consolidator_provider
        self._clock = clock or time.monotonic
        self._sleeper = sleeper or time.sleep
        self._last_activity = self._clock()
        self._last_round = float("-inf")
        self._stop = threading.Event()
        self._round_lock = threading.Lock()
        self._thread: threading.Thread | None = None

    def note_activity(self) -> None:
        """Refreshes the idle deadline; called for every inference."""
        self._last_activity = self._clock()

    def start(self) -> None:
        if self._thread is not None:
            return
        self._thread = threading.Thread(
            target=self._loop,
            name="rimeai-consolidation",
            daemon=True,
        )
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        thread = self._thread
        self._thread = None
        if thread is not None and thread is not threading.current_thread():
            thread.join(timeout=self._poll_seconds * 2)

    def should_run(self) -> bool:
        now = self._clock()
        idle = now - self._last_activity
        since_round = now - self._last_round
        return idle >= self._idle_seconds and (
            since_round >= self._min_round_interval
        )

    def _current_semantic(self) -> tuple[SemanticConsolidator | None, bool]:
        """Resolves this round's consolidator and whether its absence is
        permanent (the pass will never run here) or transient (the cloud
        is temporarily unusable)."""
        provider = self._semantic_consolidator_provider
        if provider is not None:
            result = provider()
        else:
            result = self._semantic_consolidator
        if isinstance(result, SemanticPass):
            return result.consolidator, result.permanently_unavailable
        # A bare provider result keeps the historic contract: no
        # consolidator means the semantic pass will not run here.
        return result, True

    def run_round(
        self,
        *,
        semantic_consolidator: SemanticConsolidator | None = None,
    ) -> ConsolidationReport | None:
        """Runs one guarded round; None when a round is already active."""
        if not self._round_lock.acquire(blocking=False):
            return None
        try:
            permanently_unavailable = False
            if semantic_consolidator is None:
                (
                    semantic_consolidator,
                    permanently_unavailable,
                ) = self._current_semantic()
            report = self._pipeline.run_once(
                semantic_consolidator=semantic_consolidator,
                semantic_permanently_unavailable=permanently_unavailable,
            )
        finally:
            self._last_round = self._clock()
            self._round_lock.release()
        return report

    def _loop(self) -> None:
        while not self._stop.wait(self._poll_seconds):
            if not self.should_run():
                continue
            try:
                self.run_round(
                    semantic_consolidator=self._semantic_consolidator
                )
            except Exception:
                # Watermarks make failures safe to retry next idle window;
                # record the failure for LaunchAgent diagnostics.
                logging.getLogger(__name__).exception(
                    "consolidation round failed; will retry next idle window"
                )
                continue
