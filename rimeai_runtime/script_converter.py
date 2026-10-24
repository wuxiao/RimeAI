"""Output-time traditional→simplified script conversion.

The beam sentence decoder scores entirely in the traditional space
(dictionary, n-gram and character frequencies are all traditional), so
its suggestions may carry traditional characters while the user's
`RimeAICharacterSet` is `simplified`. The engine converts the final
suggestion text only — scores, gates and thresholds are untouched.

Semantics mirror the OpenCC t2s conversion chain the table was baked
from (script/build_t2s_table.py): the disambiguation phrase table wins
with a longest-prefix match (乾隆→乾隆), otherwise the per-character
table's first candidate applies (乾→干), and characters without an
entry pass through unchanged (simplified input is a no-op).
"""

from __future__ import annotations

import json
import logging
from pathlib import Path

logger = logging.getLogger(__name__)


class SimplifiedScriptConverter:
    """Zero-dependency converter over the baked t2s-simplified.json."""

    def __init__(
        self,
        phrases: dict[str, str],
        characters: dict[str, str],
        max_phrase_length: int,
    ):
        self._phrases = phrases
        self._characters = characters
        self._max_phrase_length = max(2, max_phrase_length)

    @classmethod
    def load(cls, path: Path) -> SimplifiedScriptConverter | None:
        """Loads the table; returns None (with a warning) when missing
        or malformed so the engine degrades to no conversion instead of
        failing startup."""
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
            converter = cls(
                phrases=payload["phrases"],
                characters=payload["characters"],
                max_phrase_length=payload["max_phrase_length"],
            )
        except (OSError, ValueError, KeyError, TypeError):
            logger.warning("t2s table unusable; conversion disabled: %s", path)
            return None
        if not converter._characters:
            logger.warning("t2s table empty; conversion disabled: %s", path)
            return None
        return converter

    def convert(self, text: str) -> str:
        """Longest-phrase-first forward match; per-character fallback."""
        if not text:
            return text
        phrases = self._phrases
        characters = self._characters
        max_length = self._max_phrase_length
        pieces: list[str] = []
        index = 0
        length = len(text)
        while index < length:
            matched = ""
            for size in range(
                min(max_length, length - index), 1, -1
            ):
                candidate = text[index : index + size]
                phrase = phrases.get(candidate)
                if phrase is not None:
                    matched = phrase
                    index += size
                    break
            if matched:
                pieces.append(matched)
                continue
            character = text[index]
            pieces.append(characters.get(character, character))
            index += 1
        return "".join(pieces)
