"""Per-user character n-gram language model (L2 of the language profile).

Learns the user's phrasing habits from committed history and reranks
candidates by interpolating global and per-domain scores on top of the
frozen baseline ordering. Cold-start safe: with no user data the model
keeps the input ordering bit-for-bit.
"""

from __future__ import annotations

import contextlib
import gzip
import json
import math
import os
import tempfile
from collections import Counter, deque
from collections.abc import Sequence
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

ORDERS = (2, 3, 4, 5)
SMOOTHING_NUMERATOR = 0.1
SMOOTHING_DENOMINATOR = 1000.0
# Stupid-backoff discount per order of retreat, mirroring the frozen
# baseline n-gram ranker so both scorers agree character-for-character.
BACKOFF_ALPHA = 0.4
# Bayesian-shrinkage prior in characters: a domain needs roughly this many
# committed characters before its own weight approaches its cap.
PRIOR_CHARACTERS = 5000.0
# Weight cap for user evidence relative to the baseline rank prior.
# Kept conservative: adaptive-LM interpolation in production IMEs sits
# around 0.1-0.35 so user habits tilt, never dominate, the baseline.
MAX_USER_WEIGHT = 0.35
RANK_STICKINESS = 0.1
# v2: per-domain ``folded_tokens`` ring makes L2 folding idempotent —
# a crashed round whose claims expire re-fetches the same rows, and the
# re-fold must not double-count (LP-011). v1 payloads load unchanged
# (empty ring: every batch already folded by a v1 daemon is past the
# statistics watermark, so only future batches need dedup).
SCHEMA_VERSION = 2
MAX_TEXT_LENGTH = 256
# Ring capacity for folded commit ids: >4x the consolidation batch
# limit (512), comfortably covering the 15-minute claim-expiry window
# a crashed round's re-fetch can revisit.
FOLDED_TOKEN_CAPACITY = 2048
# Per-commit per-gram cap: one commit can increment each gram at most this
# many times, so a single repeated phrase cannot dominate the distribution.
PER_COMMIT_GRAM_CAP = 2


class UserLMError(ValueError):
    pass


def _fsync_directory(directory: Path) -> None:
    """Persists a rename inside `directory` (best effort).

    `os.replace` is atomic, but the directory entry is only durable
    after the directory itself is fsynced; without it a power cut can
    lose the new name even though the file data was fsynced. Failures
    are ignored: some filesystems refuse to open a directory for
    fsync, and the artifact bytes are already durable.
    """
    try:
        descriptor = os.open(directory, os.O_RDONLY)
    except OSError:
        return
    try:
        os.fsync(descriptor)
    except OSError:
        pass
    finally:
        os.close(descriptor)


@dataclass
class DomainCounts:
    ngram_counts: dict[int, Counter] = field(
        default_factory=lambda: {order: Counter() for order in ORDERS}
    )
    prefix_counts: dict[int, Counter] = field(
        default_factory=lambda: {order: Counter() for order in ORDERS}
    )
    characters: int = 0

    def observe(self, text: str) -> None:
        """Fold one committed text into this domain's counts."""
        clipped = text[:MAX_TEXT_LENGTH]
        grams: Counter = Counter()
        padded = "^" + clipped + "$"
        for order in ORDERS:
            for start in range(len(padded) - order + 1):
                gram = padded[start : start + order]
                grams[gram] += 1
        for gram, occurrences in grams.items():
            capped = min(occurrences, PER_COMMIT_GRAM_CAP)
            order = len(gram)
            self.ngram_counts[order][gram] += capped
            self.prefix_counts[order][gram[:-1]] += capped
        self.characters += len(clipped)

    def conditional_prob(
        self, history: str, character: str
    ) -> float | None:
        """Backoff probability of `character` following `history` under
        this domain's counts; None when the domain has no evidence at
        all (`characters <= 0`). Applies the same stupid backoff as the
        frozen baseline ranker: the highest order whose gram and prefix
        were both observed, discounted by `BACKOFF_ALPHA ** (5 - order)`,
        else the terminal add-k bigram, which is always finite and
        positive so scoring never divides by zero."""
        if self.characters <= 0:
            return None
        text = "^" + history + character
        position = len(text) - 1
        for order in reversed(ORDERS):
            start = position - order + 1
            if start < 0:
                continue
            gram = text[start : position + 1]
            count = self.ngram_counts[order].get(gram, 0)
            prefix = self.prefix_counts[order].get(gram[:-1], 0)
            if count > 0 and prefix > 0:
                return (count / prefix) * BACKOFF_ALPHA ** (5 - order)
        gram = text[position - 1 : position + 1]
        count = self.ngram_counts[2].get(gram, 0)
        prefix = self.prefix_counts[2].get(gram[:-1], 0)
        return (
            (count + SMOOTHING_NUMERATOR)
            / (prefix + SMOOTHING_DENOMINATOR)
        ) * BACKOFF_ALPHA**3

    def mean_log_prob(
        self, context: str, candidate: str
    ) -> float | None:
        """Mean log-probability of `candidate` after `context` under this
        domain's counts; None when the domain has no evidence at all or
        the candidate is empty."""
        if self.characters <= 0 or not candidate:
            return None
        total = 0.0
        for index, character in enumerate(candidate):
            probability = self.conditional_prob(
                context + candidate[:index], character
            )
            if probability is None:
                return None
            total += math.log(probability)
        return total / len(candidate)

    def to_payload(self) -> dict[str, Any]:
        return {
            "ngram_counts": {
                str(order): dict(self.ngram_counts[order]) for order in ORDERS
            },
            "prefix_counts": {
                str(order): dict(self.prefix_counts[order]) for order in ORDERS
            },
            "characters": self.characters,
        }

    @classmethod
    def from_payload(cls, payload: dict[str, Any]) -> DomainCounts:
        counts = cls()
        for order in ORDERS:
            counts.ngram_counts[order] = Counter(
                {
                    str(key): int(value)
                    for key, value in payload["ngram_counts"][
                        str(order)
                    ].items()
                }
            )
            counts.prefix_counts[order] = Counter(
                {
                    str(key): int(value)
                    for key, value in payload["prefix_counts"][
                        str(order)
                    ].items()
                }
            )
        counts.characters = int(payload["characters"])
        return counts


class UserLanguageModel:
    """Global + per-domain character n-gram store with shrinkage-adaptive
    interpolation. The `global` pseudo-domain always exists."""

    GLOBAL_DOMAIN = "global"

    def __init__(
        self, *, folded_token_capacity: int = FOLDED_TOKEN_CAPACITY
    ) -> None:
        if folded_token_capacity < 1:
            raise UserLMError("folded token capacity must be >= 1")
        self._folded_token_capacity = folded_token_capacity
        self._domains: dict[str, DomainCounts] = {
            self.GLOBAL_DOMAIN: DomainCounts()
        }
        self._folded: dict[str, deque[str]] = {
            self.GLOBAL_DOMAIN: deque(maxlen=folded_token_capacity)
        }

    # -- evidence ingestion -------------------------------------------------

    def update(self, domain: str | None, texts: Sequence[str]) -> None:
        resolved = (domain or self.GLOBAL_DOMAIN).strip() or self.GLOBAL_DOMAIN
        counts = self._domains.setdefault(resolved, DomainCounts())
        for text in texts:
            if text:
                counts.observe(text)

    def fold(
        self, domain: str | None, items: Sequence[tuple[str, str]]
    ) -> int:
        """Folds ``(commit_id, text)`` pairs idempotently (LP-011).

        Each distinct commit id is counted at most once for as long as
        it stays in the bounded ring, so re-folding a batch whose claim
        expired mid-round is a no-op instead of a double count. Within
        one call, later duplicates of the same id are skipped too. The
        return value is the number of newly folded items; the input's
        order never changes the resulting counts (addition commutes,
        and dedup is by id, not position)."""
        resolved = (domain or self.GLOBAL_DOMAIN).strip() or self.GLOBAL_DOMAIN
        counts = self._domains.setdefault(resolved, DomainCounts())
        ring = self._folded.setdefault(
            resolved, deque(maxlen=self._folded_token_capacity)
        )
        seen = set(ring)
        folded = 0
        for token, text in items:
            if not token or token in seen:
                continue
            seen.add(token)
            ring.append(token)
            if text:
                counts.observe(text)
            folded += 1
        return folded

    def domains(self) -> list[str]:
        return sorted(
            name
            for name, counts in self._domains.items()
            if counts.characters > 0
        )

    # -- scoring ------------------------------------------------------------

    def mean_log_prob(
        self,
        context: str,
        text: str,
        domain: str = GLOBAL_DOMAIN,
    ) -> float | None:
        """Mean log-probability of `text` after `context` under the user's
        evidence; the domain's counts when it has evidence, otherwise the
        global pseudo-domain's. None when neither carries any evidence."""
        resolved = (domain or self.GLOBAL_DOMAIN).strip() or self.GLOBAL_DOMAIN
        domain_counts = self._domains.get(resolved)
        candidates = (
            (domain_counts, self._domains[self.GLOBAL_DOMAIN])
            if domain_counts is not None
            and resolved != self.GLOBAL_DOMAIN
            else (self._domains[self.GLOBAL_DOMAIN],)
        )
        for counts in candidates:
            score = counts.mean_log_prob(context, text)
            if score is not None:
                return score
        return None

    def user_weights(self, domain: str | None) -> tuple[float, float]:
        """(global_weight, domain_weight) after shrinkage toward zero."""
        resolved = (domain or self.GLOBAL_DOMAIN).strip() or self.GLOBAL_DOMAIN
        global_characters = self._domains[self.GLOBAL_DOMAIN].characters
        domain_counts = self._domains.get(resolved) or DomainCounts()
        domain_characters = domain_counts.characters
        global_weight = global_characters / (global_characters + PRIOR_CHARACTERS)
        domain_weight = domain_characters / (
            domain_characters + PRIOR_CHARACTERS
        )
        if resolved == self.GLOBAL_DOMAIN:
            domain_weight = 0.0
        total = global_weight + domain_weight
        if total <= 0:
            return (0.0, 0.0)
        scale = min(total, MAX_USER_WEIGHT) / total
        return (global_weight * scale, domain_weight * scale)

    def rerank(
        self,
        context: str,
        candidates: Sequence[str],
        domain: str | None = None,
    ) -> tuple[list[str], float]:
        """Reorders candidates by interpolated user evidence. With no user
        data the input ordering is returned unchanged with confidence 0."""
        global_weight, domain_weight = self.user_weights(domain)
        if (global_weight <= 0 and domain_weight <= 0) or not candidates:
            return list(candidates), 0.0
        resolved = (domain or self.GLOBAL_DOMAIN).strip() or self.GLOBAL_DOMAIN
        global_counts = self._domains[self.GLOBAL_DOMAIN]
        domain_counts = self._domains.get(resolved) or DomainCounts()
        base_weight = 1.0 - global_weight - domain_weight
        evidence_weight = global_weight + domain_weight
        scored: list[tuple[float, int, str]] = []
        has_user_evidence = False
        for index, candidate in enumerate(candidates):
            user_score = 0.0
            weight_seen = 0.0
            global_score = global_counts.mean_log_prob(context, candidate)
            if global_score is not None and global_weight > 0:
                user_score += global_weight * global_score
                weight_seen += global_weight
            if domain_weight > 0:
                domain_score = domain_counts.mean_log_prob(
                    context, candidate
                )
                if domain_score is not None:
                    user_score += domain_weight * domain_score
                    weight_seen += domain_weight
            if weight_seen <= 0:
                # No usable evidence for this candidate: keep rank prior.
                score = -index * RANK_STICKINESS
            else:
                has_user_evidence = True
                normalized_user = user_score / max(evidence_weight, 1e-9)
                # Rank prior keeps Rime's ordering under weak evidence.
                score = (
                    base_weight * (-index * RANK_STICKINESS)
                    + evidence_weight * normalized_user
                )
            scored.append((score, index, candidate))
        if not has_user_evidence:
            return list(candidates), 0.0
        scored.sort(key=lambda item: (-item[0], item[1]))
        ranked = [item[2] for item in scored]
        changed = ranked[0] != candidates[0]
        confidence = min(1.0, evidence_weight) if changed else 0.0
        return ranked, confidence

    # -- persistence ----------------------------------------------------------

    def save(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        payload = {
            "schema_version": SCHEMA_VERSION,
            "model_type": "user-char-ngram",
            "domains": {
                name: {
                    **counts.to_payload(),
                    "folded_tokens": list(self._folded.get(name, ())),
                }
                for name, counts in self._domains.items()
                if counts.characters > 0
            },
        }
        descriptor, temporary = tempfile.mkstemp(
            dir=path.parent, prefix=f".{path.name}.", suffix=".tmp"
        )
        try:
            with os.fdopen(descriptor, "wb") as raw_file:
                with gzip.GzipFile(
                    filename="", mode="wb", fileobj=raw_file, mtime=0
                ) as compressed:
                    compressed.write(
                        json.dumps(
                            payload,
                            ensure_ascii=False,
                            separators=(",", ":"),
                            sort_keys=True,
                        ).encode("utf-8")
                    )
                raw_file.flush()
                os.fsync(raw_file.fileno())
            os.replace(temporary, path)
            # fsync the directory entry too: os.replace is atomic, but
            # without a directory fsync the rename itself can be lost on
            # a power cut, leaving the previous artifact (or no file).
            _fsync_directory(path.parent)
        except BaseException:
            with contextlib.suppress(FileNotFoundError):
                os.unlink(temporary)
            raise

    @classmethod
    def load(cls, path: Path) -> UserLanguageModel:
        model = cls()
        try:
            with gzip.open(path, "rt", encoding="utf-8") as handle:
                payload = json.load(handle)
        except FileNotFoundError:
            return model
        except (OSError, json.JSONDecodeError) as error:
            raise UserLMError(
                f"cannot read user language model '{path}'"
            ) from error
        if (
            not isinstance(payload, dict)
            or payload.get("schema_version") not in {1, SCHEMA_VERSION}
            or payload.get("model_type") != "user-char-ngram"
        ):
            raise UserLMError("unsupported user language model artifact")
        domains = payload.get("domains")
        if not isinstance(domains, dict):
            raise UserLMError("user language model domains are invalid")
        for name, domain_payload in domains.items():
            try:
                model._domains[str(name)] = DomainCounts.from_payload(
                    domain_payload
                )
            except (KeyError, TypeError, ValueError) as error:
                raise UserLMError(
                    f"user language model domain '{name}' is invalid"
                ) from error
            tokens = (
                domain_payload.get("folded_tokens")
                if isinstance(domain_payload, dict)
                else None
            )
            if isinstance(tokens, list):
                # v1 payloads carry no ring: everything folded before the
                # v2 upgrade sits past the statistics watermark, so an
                # empty ring loses nothing (only future batches dedup).
                model._folded[str(name)] = deque(
                    (
                        token
                        for token in tokens
                        if isinstance(token, str) and token
                    ),
                    maxlen=model._folded_token_capacity,
                )
        model._domains.setdefault(model.GLOBAL_DOMAIN, DomainCounts())
        return model
