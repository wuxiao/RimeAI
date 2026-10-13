"""Fused character LM: baseline + user-evidence interpolation (LP §4.2).

Interpolates per-character probabilities as
`P = λ1·P_base + λ2·P_user_global + λ3·P_user_domain` with λ from the
user LM's shrinkage-capped `user_weights`. Cold-start safe: when no user
layer carries evidence, scoring delegates to the base scorer exactly, so
an empty user LM keeps the static beam output bit-for-bit.

Used for final-path adjudication in beam decoding (Ruling 10): a request
makes only ~2×sentence-length calls, so the scorer stays allocation-free
and without memoization.
"""

from __future__ import annotations

import math

from rimeai_runtime.lm_fusion import CharLMScorer

from .user_lm import DomainCounts, UserLanguageModel


def _resolve_domain(
    user_lm: UserLanguageModel, domain: str | None
) -> str:
    # Same normalization `UserLanguageModel` applies internally: blank or
    # missing domains collapse onto the global pseudo-domain.
    return (domain or user_lm.GLOBAL_DOMAIN).strip() or user_lm.GLOBAL_DOMAIN


class FusedCharLM:
    """CharLMScorer that folds user evidence into the baseline scorer.

    Construction is O(1): it wraps the base scorer and the user LM by
    reference and never copies count tables. The interpolation weights
    and the per-domain count stores are resolved once at construction
    (the domain is fixed per instance). Candidate character ordering
    (`max_context_characters`, `character_frequency`) stays static by
    delegating to the base."""

    def __init__(
        self,
        base: CharLMScorer,
        user_lm: UserLanguageModel,
        domain: str | None,
    ) -> None:
        self._base = base
        self._user_lm = user_lm
        self._domain = _resolve_domain(user_lm, domain)
        global_weight, domain_weight = user_lm.user_weights(self._domain)
        self._global_weight = global_weight
        self._domain_weight = domain_weight
        # Intra-package cooperation: the user LM exposes per-domain
        # conditional probabilities only through its private domain store.
        self._global_counts: DomainCounts | None = (
            user_lm._domains.get(user_lm.GLOBAL_DOMAIN)
            if global_weight > 0
            else None
        )
        self._domain_counts: DomainCounts | None = (
            user_lm._domains.get(self._domain)
            if domain_weight > 0 and self._domain != user_lm.GLOBAL_DOMAIN
            else None
        )

    @property
    def max_context_characters(self) -> int:
        return self._base.max_context_characters

    def character_frequency(self, character: str) -> int:
        return self._base.character_frequency(character)

    def next_char_log_prob(self, context: str, character: str) -> float:
        global_counts = self._global_counts
        domain_counts = self._domain_counts
        if global_counts is None and domain_counts is None:
            return self._base.next_char_log_prob(context, character)
        p_global = (
            global_counts.conditional_prob(context, character)
            if global_counts is not None
            else None
        )
        p_domain = (
            domain_counts.conditional_prob(context, character)
            if domain_counts is not None
            else None
        )
        if p_global is None and p_domain is None:
            return self._base.next_char_log_prob(context, character)
        base_log_prob = self._base.next_char_log_prob(context, character)
        global_weight = self._global_weight
        domain_weight = self._domain_weight
        base_weight = 1.0 - global_weight - domain_weight
        if p_global is None:
            base_weight += global_weight
        if p_domain is None:
            base_weight += domain_weight
        fused = base_weight * math.exp(base_log_prob)
        if p_global is not None:
            fused += global_weight * p_global
        if p_domain is not None:
            fused += domain_weight * p_domain
        return math.log(fused)
