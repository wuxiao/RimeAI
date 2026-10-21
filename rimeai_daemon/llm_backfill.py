"""L3 signature-phrase backfill into the L1 phrasebook (LP-009).

Reconciles ``traits.signature_phrases`` of a domain's style profile into
``phrasebook_entries`` rows with ``source='llm'``:

- inserts phrases that carry a full pinyin reading in the frozen Rime
  dictionary (word-level match first, then greedy longest-match
  segmentation over dictionary keys), always with ``count=0`` and
  ``protected=0``; existing ``auto``/``user`` rows are never overwritten
  (``ON CONFLICT DO NOTHING`` — real typing evidence outranks derived
  data);
- deletes ``source='llm'`` rows with ``protected=0`` whose text is no
  longer in the current signature set, so the derived rows follow the
  profile; a user-protected row always survives;
- is a whole-step no-op without a dictionary (fail-open enhancement:
  L1 keeps working, backfill simply does not happen).

The volume is bounded per domain by the profile layer
(``MAX_SIGNATURE_PHRASES``), and the phrasebook snapshot limit
(100_000) plus the LP-010 capacity cap keep backfilled rows visible to
the typing-path suggestion slot (no ``count`` filter there). Auto
history consolidation never accumulates frequency on ``source='llm'``
rows (see ``consolidation._upsert_phrase``).
"""

from __future__ import annotations

import contextlib
import json
import re
import sqlite3
import time
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path

from rimeai_runtime.pinyin_guard import PinyinGuard

from .consolidation import MAX_PHRASE_BYTES, phrase_entry_id

DOMAIN_PATTERN = re.compile(r"[a-z0-9-]{1,64}")


@dataclass(frozen=True)
class BackfillReport:
    """Rows written and removed by one reconcile round."""

    inserted: int = 0
    removed: int = 0


class SignaturePhraseBackfiller:
    """Stateless per-domain reconcile of profile phrases into L1.

    Stateless by design: the row set is a pure function of the current
    profile traits, so re-running for the same revision is naturally
    idempotent and no revision watermark file exists to go stale on
    domain rename/merge (known v1 behavior: a user-deleted ``llm`` row
    returns at the next profile revision while the phrase is still in
    the profile; ``protected`` is the durable opt-out).
    """

    def __init__(
        self, phrasebook_db: Path, guard: PinyinGuard | None
    ) -> None:
        self.phrasebook_db = phrasebook_db
        self.guard = guard
        self._max_key_length = (
            max(
                (len(key) for key in guard.pronunciations),
                default=0,
            )
            if guard is not None
            else 0
        )

    def annotate(self, text: str) -> str | None:
        """Full pinyin key for ``text``, or None when the dictionary
        cannot cover it. Word-level match wins; otherwise greedy
        longest-match segmentation. Readings of a polyphone resolve
        deterministically to the lexicographically first variant."""
        if self.guard is None:
            return None
        pronunciations = self.guard.pronunciations

        def reading(word: str) -> str:
            variants = pronunciations[word]
            chosen = sorted(variants)[0]
            return "".join(chosen.split())

        if text in pronunciations:
            return reading(text)
        position = 0
        syllables: list[str] = []
        while position < len(text):
            remaining = len(text) - position
            for length in range(
                min(self._max_key_length, remaining), 0, -1
            ):
                word = text[position : position + length]
                if word in pronunciations:
                    syllables.append(reading(word))
                    position += length
                    break
            else:
                return None
        return "".join(syllables)

    def backfill(
        self,
        domain: str,
        signature_phrases: Sequence[str],
        *,
        now_ms: int | None = None,
    ) -> BackfillReport:
        """Reconciles one domain; returns rows inserted and removed.

        Raises ValueError on an invalid domain name (the caller logs and
        skips — a bad domain must never half-write). Database errors
        propagate to the semantic-consolidation wrapper, which treats
        backfill as best-effort."""
        if DOMAIN_PATTERN.fullmatch(domain) is None:
            raise ValueError(f"backfill domain is invalid: {domain!r}")
        if self.guard is None:
            return BackfillReport(0, 0)
        cleaned: list[tuple[str, str]] = []
        seen: set[str] = set()
        for phrase in signature_phrases:
            if not isinstance(phrase, str):
                continue
            phrase = phrase.strip()
            if (
                not phrase
                or phrase in seen
                or len(phrase.encode("utf-8")) > MAX_PHRASE_BYTES
            ):
                continue
            keys = self.annotate(phrase)
            if not keys:
                continue
            seen.add(phrase)
            cleaned.append((phrase, keys))
        now = now_ms if now_ms is not None else int(time.time() * 1000)
        inserted = 0
        removed = 0
        with contextlib.closing(
            sqlite3.connect(self.phrasebook_db, timeout=2)
        ) as db:
            db.execute("PRAGMA busy_timeout=1500")
            db.execute("BEGIN IMMEDIATE")
            try:
                for phrase, keys in cleaned:
                    cursor = db.execute(
                        """
                        INSERT INTO phrasebook_entries(
                            id, domain, text, pinyin_keys, count,
                            first_seen_ms, last_used_ms, source, protected
                        ) VALUES (?, ?, ?, ?, 0, ?, ?, 'llm', 0)
                        ON CONFLICT(domain, text) DO NOTHING
                        """,
                        (
                            phrase_entry_id(domain, phrase),
                            domain,
                            phrase,
                            keys,
                            now,
                            now,
                        ),
                    )
                    inserted += max(cursor.rowcount, 0)
                cursor = db.execute(
                    """
                    DELETE FROM phrasebook_entries
                    WHERE domain = ? AND source = 'llm'
                      AND protected = 0
                      AND text NOT IN (SELECT value FROM json_each(?))
                    """,
                    (domain, json.dumps([phrase for phrase, _ in cleaned])),
                )
                removed = max(cursor.rowcount, 0)
                db.commit()
            except BaseException:
                db.rollback()
                raise
        return BackfillReport(inserted, removed)
