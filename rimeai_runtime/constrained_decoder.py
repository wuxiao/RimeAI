"""Pinyin-constrained decoding primitives shared by runtime and eval."""

from dataclasses import dataclass
from itertools import product
import math
from typing import Callable, Dict, FrozenSet, List, Mapping, Optional, Sequence, Set, Tuple

from .pinyin_guard import PinyinGuard


Syllables = Tuple[str, ...]

# Frozen both-direction pinyin confusion pairs (cloud_model.py rules):
# finals swap directly; initials swap as zh/z, ch/c, sh/s prefixes.
_FUZZY_FINAL_PAIRS = frozenset(
    {
        ("an", "ang"),
        ("ang", "an"),
        ("en", "eng"),
        ("eng", "en"),
        ("in", "ing"),
        ("ing", "in"),
    }
)
_FUZZY_INITIAL_PREFIXES = (("zh", "z"), ("ch", "c"), ("sh", "s"))


def fuzzy_equal(a: str, b: str) -> bool:
    """Syllable-level pinyin equivalence for the frozen confusion pairs."""
    if a == b:
        return True
    if (a, b) in _FUZZY_FINAL_PAIRS:
        return True
    for thick, thin in _FUZZY_INITIAL_PREFIXES:
        for x, y in ((a, b), (b, a)):
            if x.startswith(thick) and y == thin + x[len(thick):]:
                return True
    return False


def fuzzy_segment_ok(
    guard: PinyinGuard,
    text: str,
    typed_syllables: Sequence[str],
) -> bool:
    """True when every character reading of ``text`` fuzzy-matches the
    typed syllables position for position."""
    if not text or len(text) != len(typed_syllables):
        return False
    readings = PinyinTokenIndex._readings(text, guard)
    typed = tuple(typed_syllables)
    return any(
        len(reading) == len(typed)
        and all(fuzzy_equal(actual, expected) for actual, expected in zip(reading, typed))
        for reading in readings
    )


class PinyinTokenIndex:
    """Maps vocabulary tokens to their pinyin syllable readings.

    PinyinGuard stores concatenated pinyin (spaces are stripped during
    normalization), so multi-character tokens compose their syllables
    from per-character readings — the same source of truth
    PinyinGuard.segment uses.
    """

    def __init__(
        self,
        token_syllables: Dict[int, FrozenSet[Syllables]],
        first_syllable_tokens: Dict[str, FrozenSet[int]],
        token_texts: Optional[Dict[int, str]] = None,
    ) -> None:
        self.token_syllables = token_syllables
        self.first_syllable_tokens = first_syllable_tokens
        self.token_texts = token_texts if token_texts is not None else {}

    @classmethod
    def build(cls, tokenizer, guard: PinyinGuard) -> "PinyinTokenIndex":
        token_syllables: Dict[int, Set[Syllables]] = {}
        token_texts: Dict[int, str] = {}
        first: Dict[str, Set[int]] = {}
        for token_id in range(tokenizer.vocab_size):
            text = tokenizer.decode([token_id])
            readings = cls._readings(text, guard) if text else ()
            if not readings:
                continue
            token_syllables[token_id] = set(readings)
            token_texts[token_id] = text
            for reading in readings:
                first.setdefault(reading[0], set()).add(token_id)
        return cls(
            {token_id: frozenset(readings) for token_id, readings in token_syllables.items()},
            {syllable: frozenset(ids) for syllable, ids in first.items()},
            token_texts,
        )

    @staticmethod
    def _readings(text: str, guard: PinyinGuard) -> Tuple[Syllables, ...]:
        if len(text) == 1:
            variants = guard.pronunciations.get(text)
            if not variants:
                return ()
            return tuple((variant,) for variant in variants)
        per_character = []
        for character in text:
            variants = guard.pronunciations.get(character)
            if not variants:
                return ()
            per_character.append(sorted(variants))
        return tuple(product(*per_character))

    def candidates(
        self,
        prefix: Sequence[str],
        *,
        fuzzy: bool = False,
    ) -> Dict[int, Syllables]:
        """Tokens whose reading is a prefix of ``prefix``; ``fuzzy``
        accepts the frozen pinyin confusion pairs at every position."""
        if not prefix:
            return {}
        result: Dict[int, Syllables] = {}
        if fuzzy:
            first_keys = {
                syllable
                for syllable in self.first_syllable_tokens
                if fuzzy_equal(syllable, prefix[0])
            }
            token_ids: Set[int] = set()
            for syllable in first_keys:
                token_ids.update(self.first_syllable_tokens[syllable])
            for token_id in sorted(token_ids):
                for reading in sorted(self.token_syllables.get(token_id, ())):
                    if len(reading) <= len(prefix) and all(
                        fuzzy_equal(actual, expected)
                        for actual, expected in zip(reading, prefix)
                    ):
                        result[token_id] = reading
                        break
            return result
        for token_id in sorted(self.first_syllable_tokens.get(prefix[0], ())):
            for reading in sorted(self.token_syllables.get(token_id, ())):
                if reading == tuple(prefix[: len(reading)]):
                    result[token_id] = reading
                    break
        return result


@dataclass(frozen=True)
class DecodeResult:
    text: str
    confidence: float
    consumed_syllables: int


class ConstrainedGreedyDecoder:
    """Greedy next-token decoding under a hard pinyin mask.

    Long-word priority: when the argmax candidate's probability is below
    0.9, the candidate consuming the most syllables wins among those with
    probability >= 0.5 * argmax. Ties break to the smaller token id.
    """

    ARGMAX_CONFIDENT = 0.9
    LONG_WORD_FLOOR = 0.5

    @classmethod
    def decode(
        cls,
        scorer: Callable[[Sequence[int]], Mapping[int, float]],
        syllables: Sequence[str],
        index: PinyinTokenIndex,
        *,
        max_characters: int = 30,
        fuzzy: bool = False,
    ) -> DecodeResult:
        remaining = list(syllables)
        generated: List[int] = []
        text_parts: List[str] = []
        log_probability_sum = 0.0
        steps = 0
        while remaining:
            probabilities = scorer(generated)
            allowed = index.candidates(remaining, fuzzy=fuzzy)
            consumed = len(syllables) - len(remaining)
            if not allowed:
                return DecodeResult("", 0.0, consumed)
            scored = [
                (probabilities.get(token_id, 0.0), token_id, reading)
                for token_id, reading in allowed.items()
            ]
            argmax_probability = max(
                probability for probability, _, _ in scored
            )
            if argmax_probability < cls.ARGMAX_CONFIDENT:
                floor = cls.LONG_WORD_FLOOR * argmax_probability
                probability, token_id, reading = max(
                    (item for item in scored if item[0] >= floor),
                    key=lambda item: (len(item[2]), item[0], -item[1]),
                )
            else:
                probability, token_id, reading = max(
                    scored, key=lambda item: (item[0], -item[1])
                )
            if probability <= 0.0:
                return DecodeResult("", 0.0, consumed)
            token_text = index.token_texts.get(token_id, "")
            if sum(len(part) for part in text_parts) + len(token_text) > max_characters:
                return DecodeResult("", 0.0, consumed)
            generated.append(token_id)
            text_parts.append(token_text)
            log_probability_sum += math.log(max(probability, 1e-12))
            steps += 1
            del remaining[: len(reading)]
        confidence = math.exp(log_probability_sum / steps) if steps else 0.0
        return DecodeResult("".join(text_parts), confidence, len(syllables))
