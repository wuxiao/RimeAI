"""Independent pinyin-consistency checks backed by a frozen Rime dictionary."""

from dataclasses import dataclass
from pathlib import Path
import re
from typing import Dict, FrozenSet, List, Optional, Set

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
    pronunciations: Dict[str, FrozenSet[str]]

    @classmethod
    def from_rime_dictionary(cls, path: Path) -> "PinyinGuard":
        pronunciations: Dict[str, Set[str]] = {}
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
    ) -> Optional[List[str]]:
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
