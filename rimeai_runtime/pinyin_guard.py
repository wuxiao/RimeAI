"""Independent pinyin-consistency checks backed by a frozen Rime dictionary."""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

_HAN_TEXT = re.compile(r"^[\u3400-\u9fff]+$")
_PINYIN = re.compile(r"^[a-zv]+$")


def _normalize_pinyin(value: str) -> str:
    return (
        value.lower()
        .replace("ü", "v")
        .replace("u:", "v")
        .replace(" ", "")
        .replace("'", "")
    )


@dataclass(frozen=True)
class PinyinGuard:
    pronunciations: dict[str, frozenset[str]]

    @classmethod
    def from_rime_dictionary(cls, path: Path) -> PinyinGuard:
        pronunciations: dict[str, set[str]] = {}
        body_started = False
        with path.open(encoding="utf-8") as dictionary:
            for line in dictionary:
                line = line.rstrip("\n")
                if not body_started:
                    if line == "...":
                        body_started = True
                    continue
                if not line or line.startswith("#"):
                    continue
                fields = line.split("\t")
                if len(fields) < 2:
                    continue
                text = fields[0]
                pinyin = _normalize_pinyin(fields[1])
                if (
                    _HAN_TEXT.fullmatch(text)
                    and _PINYIN.fullmatch(pinyin)
                ):
                    pronunciations.setdefault(text, set()).add(pinyin)
        if not body_started or not pronunciations:
            raise ValueError(f"{path}: no Rime dictionary entries found")
        return cls(
            {
                text: frozenset(values)
                for text, values in pronunciations.items()
            }
        )

    def matches(
        self,
        text: str,
        pinyin: str,
        *,
        maximum_characters: int = 30,
    ) -> bool:
        return (
            self.segment(
                text,
                pinyin,
                maximum_characters=maximum_characters,
            )
            is not None
        )

    def segment(
        self,
        text: str,
        pinyin: str,
        *,
        maximum_characters: int = 30,
    ) -> list[str] | None:
        normalized = _normalize_pinyin(pinyin)
        if (
            not text
            or len(text) > maximum_characters
            or not _HAN_TEXT.fullmatch(text)
            or not _PINYIN.fullmatch(normalized)
        ):
            return None

        paths = {0: []}
        for character in text:
            variants = self.pronunciations.get(character)
            if not variants:
                return None
            next_paths = {}
            for offset, parts in paths.items():
                for variant in sorted(variants):
                    # Match Rime's abbreviated pinyin: a syllable may be
                    # typed in full or reduced to its first letter.
                    forms = [variant]
                    if len(variant) > 1:
                        forms.append(variant[0])
                    for form in dict.fromkeys(forms):
                        if normalized.startswith(form, offset):
                            next_paths.setdefault(
                                offset + len(form),
                                parts + [variant],
                            )
            if not next_paths:
                return None
            paths = next_paths
        return paths.get(len(normalized))


# Per-instance memo attribute for _generic_syllable_table: PinyinGuard is
# frozen, so the cache is written via object.__setattr__ — it never takes
# part in eq/hash/repr and dies with the guard instance it belongs to.
_GENERIC_SYLLABLES_CACHE = "_generic_segmentation_syllables"


def _generic_syllable_table(guard: PinyinGuard) -> tuple[str, ...]:
    """Every single-character reading, longest-first then lexicographic.

    Rebuilding walks and re-sorts the whole dictionary, so the ordered
    tuple is memoized per guard instance (a frozen guard's pronunciation
    table never legitimately changes).
    """
    cached = getattr(guard, _GENERIC_SYLLABLES_CACHE, None)
    if cached is None:
        cached = tuple(
            sorted(
                {
                    pronunciation
                    for text, pronunciations in guard.pronunciations.items()
                    if len(text) == 1
                    for pronunciation in pronunciations
                },
                key=lambda value: (-len(value), value),
            )
        )
        object.__setattr__(guard, _GENERIC_SYLLABLES_CACHE, cached)
    return cached


def _normalize_generic(pinyin: str) -> str:
    # Frozen with the original neural_ranker normalization (no ü -> v
    # folding): the algorithm's observable behavior must not change.
    return pinyin.lower().replace("'", "").replace(" ", "")


def segment_generic_pinyin(pinyin: str, guard: PinyinGuard) -> list[str] | None:
    """Longest-syllable-first DP segmentation of a pinyin string.

    Returns None when the string cannot be fully tiled into
    single-character dictionary syllables; callers that need the
    historical whole-string fallback use generic_pinyin_segmentation.
    """
    normalized = _normalize_generic(pinyin)
    syllables = _generic_syllable_table(guard)
    paths: dict[int, list[str]] = {0: []}
    for start in range(len(normalized) + 1):
        if start not in paths:
            continue
        for syllable in syllables:
            if normalized.startswith(syllable, start):
                end = start + len(syllable)
                candidate = paths[start] + [syllable]
                previous = paths.get(end)
                if previous is None or len(candidate) < len(previous):
                    paths[end] = candidate
    return paths.get(len(normalized))


def generic_pinyin_segmentation(pinyin: str, guard: PinyinGuard) -> list[str]:
    """Segment ``pinyin`` into dictionary syllables, preferring fewer
    syllables; on failure return ``[normalized]`` (or ``[]`` for empty
    input) — the exact behavior of the former neural_ranker helper."""
    segmented = segment_generic_pinyin(pinyin, guard)
    if segmented is not None:
        return segmented
    normalized = _normalize_generic(pinyin)
    return [normalized] if normalized else []
