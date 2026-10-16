"""CharLMScorer protocol plus the static adapter over the frozen n-gram model.

The protocol is the seam between the beam sentence decoder and any
character-level language model: the default adapter scores with the frozen
baseline's stupid backoff, while `rimeai_daemon.fused_lm.FusedCharLM`
interpolates user evidence on top of the same interface.
"""

from __future__ import annotations

import math
from typing import Protocol

from .ngram_ranker import NGramRankerModel, ORDERS


class CharLMScorer(Protocol):
    @property
    def max_context_characters(self) -> int:
        """Upper bound of the fused context window, in characters."""
        ...

    def next_char_log_prob(self, context: str, character: str) -> float:
        """Log probability of `character` following `context`."""
        ...

    def character_frequency(self, character: str) -> int:
        """Corpus frequency of `character` from order-2 counts."""
        ...


class StaticCharLM:
    """CharLMScorer view of the frozen baseline n-gram model.

    `next_char_log_prob` reproduces the baseline's stupid-backoff
    probability bit-for-bit, including the `"^"` start-of-text padding,
    so fused scoring and `NGramRankerModel.language_score` agree
    character-for-character."""

    def __init__(self, model: NGramRankerModel) -> None:
        self._model = model
        character_frequencies: dict[str, int] = {}
        for gram, count in model.ngram_counts[2].items():
            character = gram[-1]
            character_frequencies[character] = (
                character_frequencies.get(character, 0) + count
            )
        self._character_frequencies = character_frequencies

    @property
    def max_context_characters(self) -> int:
        return self._model.max_context_characters

    def next_char_log_prob(self, context: str, character: str) -> float:
        model = self._model
        text = "^" + context[-model.max_context_characters :] + character
        position = len(text) - 1
        for order in reversed(ORDERS):
            start = position - order + 1
            if start < 0:
                continue
            gram = text[start : position + 1]
            count = model.ngram_counts[order].get(gram, 0)
            prefix_count = model.prefix_counts[order].get(gram[:-1], 0)
            if count > 0 and prefix_count > 0:
                probability = (count / prefix_count) * model.backoff_alpha ** (
                    5 - order
                )
                return math.log(probability)
        gram = text[position - 1 : position + 1]
        count = model.ngram_counts[2].get(gram, 0)
        prefix_count = model.prefix_counts[2].get(gram[:-1], 0)
        probability = (
            (count + 0.1) / (prefix_count + 1000.0)
        ) * model.backoff_alpha**3
        return math.log(probability)

    def character_frequency(self, character: str) -> int:
        return self._character_frequencies.get(character, 0)
