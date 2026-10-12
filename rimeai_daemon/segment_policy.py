"""Pinyin-segment validation shared by the daemon and the cloud broker.

Mirror of Swift PinyinSegmentPolicy (Sources/RimeAIInputCore/DaemonProtocol.swift):
keep the Python and Swift copies byte-identical so the canonical JSON echo
stays stable end to end. Both Python servers import this single module —
do not fork it back into per-server copies.
"""

from __future__ import annotations

import re
from collections.abc import Sequence
from typing import Any

SEGMENT_MAXIMUM_SEGMENTS = 8
SEGMENT_MAXIMUM_PINYIN_LETTERS = 64
SEGMENT_MAXIMUM_TOTAL_LETTERS = 256
SEGMENT_MAXIMUM_COMMITTED_TEXT = 64
SEGMENT_MAXIMUM_SEPARATOR_UTF8_BYTES = 8

# ASCII punctuation, General Punctuation, CJK punctuation and fullwidth
# ASCII variants. U+2028/U+2029 are excluded so the canonical JSON encoding
# stays byte-stable against the Swift mirror.
_PUNCTUATION_SCALAR_RANGES: tuple[range, ...] = (
    range(0x21, 0x2F + 1),
    range(0x3A, 0x40 + 1),
    range(0x5B, 0x60 + 1),
    range(0x7B, 0x7E + 1),
    range(0x2000, 0x2027 + 1),
    range(0x202A, 0x206F + 1),
    range(0x3001, 0x303F + 1),
    range(0xFF01, 0xFF5E + 1),
)


def is_separator_punctuation(separator: str) -> bool:
    return all(
        any(ord(scalar) in interval for interval in _PUNCTUATION_SCALAR_RANGES)
        for scalar in separator
    )


def validate_pinyin_segments(
    segments: Any, *, active_pinyin: str
) -> list[dict[str, Any]]:
    if (
        not isinstance(segments, list)
        or not 1 <= len(segments) <= SEGMENT_MAXIMUM_SEGMENTS
    ):
        raise ValueError("segments must contain 1 to 8 pinyin segments")
    validated: list[dict[str, Any]] = []
    total_letters = 0
    for index, segment in enumerate(segments):
        is_last = index == len(segments) - 1
        if not isinstance(segment, dict):
            raise ValueError("each segment must be an object")
        pinyin = segment.get("pinyin")
        separator = segment.get("separator")
        committed_text = segment.get("committed_text")
        if (
            not isinstance(pinyin, str)
            or re.fullmatch(r"[a-z']+", pinyin) is None
            or len(pinyin.replace("'", "")) > SEGMENT_MAXIMUM_PINYIN_LETTERS
            or not isinstance(separator, str)
            or (is_last and separator != "")
            or (not is_last and not separator)
            or len(separator.encode("utf-8"))
            > SEGMENT_MAXIMUM_SEPARATOR_UTF8_BYTES
            or not is_separator_punctuation(separator)
        ):
            raise ValueError("segment pinyin or separator is invalid")
        if committed_text is not None and (
            not isinstance(committed_text, str)
            or len(committed_text) > SEGMENT_MAXIMUM_COMMITTED_TEXT
            or "\n" in committed_text
            or "\0" in committed_text
        ):
            raise ValueError("segment committed_text is invalid")
        total_letters += len(pinyin.replace("'", ""))
        entry = {"pinyin": pinyin, "separator": separator}
        if committed_text is not None:
            entry["committed_text"] = committed_text
        validated.append(entry)
    if validated[-1]["pinyin"] != active_pinyin:
        raise ValueError("the last segment must carry the active pinyin")
    if total_letters > SEGMENT_MAXIMUM_TOTAL_LETTERS:
        raise ValueError("segments exceed the total pinyin letter budget")
    return validated


def split_segmented_text(
    text: str, segments: Sequence[dict[str, Any]]
) -> list[str] | None:
    """Splits a joined sentence by the request separators, in order.

    Returns None when the layout does not reproduce the separators
    exactly. Parts may be empty and are not required to be pure Han or to
    fit their segment's pinyin letter count — the Swift client is the
    final gate for part-level rules (non-empty parts, >0x20 scalars);
    alignment is the model's job."""
    parts: list[str] = []
    remaining = text
    for segment in segments[:-1]:
        separator = segment["separator"]
        head, matched, remaining = remaining.partition(separator)
        if not matched:
            return None
        parts.append(head)
    parts.append(remaining)
    return parts
