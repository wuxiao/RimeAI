"""Read-only view over a user-lm.json.gz artifact for shallow fusion.

The daemon's L2 user language model (``rimeai_daemon/user_lm.py``) is
the single writer: it folds committed history into per-domain character
n-gram counts and persists ``user-lm.json.gz`` (gzip JSON, schema v1/v2,
``domains/global`` structure). This module is the runtime-side
READ-ONLY twin: it loads the same artifact format and reproduces the
``DomainCounts`` scoring caliber EXACTLY — same ORDERS (2..5), same
stupid backoff (``BACKOFF_ALPHA = 0.4`` per order of retreat), same
terminal add-k smoothing (``0.1 / 1000``), same ``^``/``$`` boundaries —
so a score computed here equals the daemon's score bit for bit on the
same artifact (proven by the parity tests in tests/test_user_lm_view.py;
the implementation is deliberately independent of the daemon module so
``rimeai_runtime`` never imports ``rimeai_daemon``).

Differences from the daemon's model class are all read-side:

- ``load`` FAILS CLOSED: a missing or corrupt artifact raises
  ``UserLmViewError`` instead of returning an empty cold-start model
  (callers fuse user evidence only when they explicitly asked for it,
  so a bad path must be loud, never silently evidence-free);
- ``folded_tokens`` (the v2 write-side dedup ring) is ignored — it only
  matters when writing more evidence, which this view never does;
- no ``save``/``update``/``fold`` surface exists at all.

``log_prob_sum`` is the fusion-facing scorer: the SUM of per-character
log probabilities (the daemon's ``mean_log_prob`` is the mean of the
same per-character terms; both share one ``conditional_prob``).
"""

from __future__ import annotations

import gzip
import json
import math
from collections.abc import Sequence
from pathlib import Path
from typing import Any

# Frozen to mirror rimeai_daemon.user_lm exactly (see module docstring:
# the parity tests pin these to the daemon's constants).
ORDERS = (2, 3, 4, 5)
SMOOTHING_NUMERATOR = 0.1
SMOOTHING_DENOMINATOR = 1000.0
BACKOFF_ALPHA = 0.4
SCHEMA_VERSION = 2


class UserLmViewError(ValueError):
    """Artifact missing, unreadable, or not a user-lm v1/v2 payload."""


class DomainCountsView:
    """Read-only per-domain counts with the daemon's exact scoring."""

    def __init__(
        self,
        ngram_counts: dict[int, dict[str, int]],
        prefix_counts: dict[int, dict[str, int]],
        characters: int,
    ) -> None:
        self.ngram_counts = ngram_counts
        self.prefix_counts = prefix_counts
        self.characters = characters

    def conditional_prob(self, history: str, character: str) -> float | None:
        """Backoff probability of `character` following `history` —
        identical expression-for-expression to
        ``rimeai_daemon.user_lm.DomainCounts.conditional_prob`` (None
        when the domain carries no evidence at all)."""
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
            (count + SMOOTHING_NUMERATOR) / (prefix + SMOOTHING_DENOMINATOR)
        ) * BACKOFF_ALPHA**3

    def _log_prob_total(self, context: str, candidate: str) -> float | None:
        if self.characters <= 0 or not candidate:
            return None
        total = 0.0
        for index, character in enumerate(candidate):
            probability = self.conditional_prob(context + candidate[:index], character)
            if probability is None:
                return None
            total += math.log(probability)
        return total

    def mean_log_prob(self, context: str, candidate: str) -> float | None:
        """Mean per-character log-probability — the daemon's rerank
        caliber; None when the domain has no evidence or the candidate
        is empty."""
        total = self._log_prob_total(context, candidate)
        if total is None:
            return None
        return total / len(candidate)

    def log_prob_sum(self, context: str, candidate: str) -> float | None:
        """Summed per-character log-probability — the shallow-fusion
        caliber (each generated character contributes its own term, so
        multi-character tokens accumulate per character). Always <= 0:
        every conditional_prob is a probability in (0, 1]."""
        return self._log_prob_total(context, candidate)

    @classmethod
    def from_payload(cls, payload: dict[str, Any]) -> DomainCountsView:
        ngram_counts: dict[int, dict[str, int]] = {order: {} for order in ORDERS}
        prefix_counts: dict[int, dict[str, int]] = {order: {} for order in ORDERS}
        for order in ORDERS:
            ngram_counts[order] = {
                str(key): int(value)
                for key, value in payload["ngram_counts"][str(order)].items()
            }
            prefix_counts[order] = {
                str(key): int(value)
                for key, value in payload["prefix_counts"][str(order)].items()
            }
        return cls(
            ngram_counts,
            prefix_counts,
            int(payload["characters"]),
        )


class UserLanguageModelView:
    """Global + per-domain read-only scoring view over one artifact."""

    GLOBAL_DOMAIN = "global"

    def __init__(self) -> None:
        self._domains: dict[str, DomainCountsView] = {
            self.GLOBAL_DOMAIN: DomainCountsView({}, {}, 0)
        }

    @classmethod
    def load(cls, path: Path) -> UserLanguageModelView:
        """Loads a user-lm.json.gz artifact (schema v1 or v2).

        FAILS CLOSED on every failure mode — missing file, I/O error,
        corrupt gzip/JSON, wrong schema — by raising ``UserLmViewError``.
        (The daemon's ``load`` returns an empty cold-start model for a
        missing file; that is a writer-side choice this read-only view
        deliberately does not inherit: fusion callers ask for user
        evidence explicitly, so a bad path must surface immediately.)
        """
        view = cls()
        try:
            with gzip.open(path, "rt", encoding="utf-8") as handle:
                payload = json.load(handle)
        except FileNotFoundError as error:
            raise UserLmViewError(
                f"user language model artifact is missing: '{path}'"
            ) from error
        except (OSError, json.JSONDecodeError) as error:
            raise UserLmViewError(
                f"cannot read user language model '{path}'"
            ) from error
        if (
            not isinstance(payload, dict)
            or payload.get("schema_version") not in {1, SCHEMA_VERSION}
            or payload.get("model_type") != "user-char-ngram"
        ):
            raise UserLmViewError("unsupported user language model artifact")
        domains = payload.get("domains")
        if not isinstance(domains, dict):
            raise UserLmViewError("user language model domains are invalid")
        for name, domain_payload in domains.items():
            try:
                view._domains[str(name)] = DomainCountsView.from_payload(domain_payload)
            except (KeyError, TypeError, ValueError) as error:
                raise UserLmViewError(
                    f"user language model domain '{name}' is invalid"
                ) from error
        view._domains.setdefault(view.GLOBAL_DOMAIN, DomainCountsView({}, {}, 0))
        return view

    def domains(self) -> list[str]:
        return sorted(
            name for name, counts in self._domains.items() if counts.characters > 0
        )

    def domain_counts(self, domain: str | None) -> DomainCountsView:
        resolved = self._resolve(domain)
        return self._domains.get(resolved) or self._domains[self.GLOBAL_DOMAIN]

    def _resolve(self, domain: str | None) -> str:
        return (domain or self.GLOBAL_DOMAIN).strip() or self.GLOBAL_DOMAIN

    def _score(
        self,
        context: str,
        text: str,
        domain: str,
        caliber: str,
    ) -> float | None:
        """Domain-then-global fallback, mirroring the daemon's
        UserLanguageModel.mean_log_prob structure: the domain's own
        counts when it has any evidence, otherwise the global
        pseudo-domain's."""
        resolved = self._resolve(domain)
        domain_counts = self._domains.get(resolved)
        candidates: Sequence[DomainCountsView] = (
            (domain_counts, self._domains[self.GLOBAL_DOMAIN])
            if domain_counts is not None and resolved != self.GLOBAL_DOMAIN
            else (self._domains[self.GLOBAL_DOMAIN],)
        )
        for counts in candidates:
            scorer = counts.mean_log_prob if caliber == "mean" else counts.log_prob_sum
            score = scorer(context, text)
            if score is not None:
                return score
        return None

    def mean_log_prob(
        self,
        context: str,
        text: str,
        domain: str = GLOBAL_DOMAIN,
    ) -> float | None:
        """Daemon-parity caliber (see DomainCountsView.mean_log_prob)."""
        return self._score(context, text, domain, "mean")

    def log_prob_sum(
        self,
        context: str,
        text: str,
        domain: str = GLOBAL_DOMAIN,
    ) -> float | None:
        """Fusion caliber: summed per-character log-probability, or
        None when neither the domain nor global carries evidence."""
        return self._score(context, text, domain, "sum")
