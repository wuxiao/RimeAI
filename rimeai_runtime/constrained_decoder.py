"""Pinyin-constrained decoding primitives shared by runtime and eval."""

from itertools import product
from typing import Callable, Dict, FrozenSet, Mapping, Sequence, Set, Tuple

from .pinyin_guard import PinyinGuard


Syllables = Tuple[str, ...]


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
    ) -> None:
        self.token_syllables = token_syllables
        self.first_syllable_tokens = first_syllable_tokens

    @classmethod
    def build(cls, tokenizer, guard: PinyinGuard) -> "PinyinTokenIndex":
        token_syllables: Dict[int, Set[Syllables]] = {}
        first: Dict[str, Set[int]] = {}
        for token_id in range(tokenizer.vocab_size):
            text = tokenizer.decode([token_id])
            readings = cls._readings(text, guard) if text else ()
            if not readings:
                continue
            token_syllables[token_id] = set(readings)
            for reading in readings:
                first.setdefault(reading[0], set()).add(token_id)
        return cls(
            {token_id: frozenset(readings) for token_id, readings in token_syllables.items()},
            {syllable: frozenset(ids) for syllable, ids in first.items()},
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
        """Tokens whose reading is a prefix of ``prefix`` (fuzzy=False)."""
        if fuzzy:
            raise NotImplementedError("fuzzy matching arrives with the fuzzy gate")
        if not prefix:
            return {}
        result: Dict[int, Syllables] = {}
        for token_id in sorted(self.first_syllable_tokens.get(prefix[0], ())):
            for reading in sorted(self.token_syllables.get(token_id, ())):
                if reading == tuple(prefix[: len(reading)]):
                    result[token_id] = reading
                    break
        return result
