"""Deterministic derivation helpers for long-input evaluation samples."""

import re
from typing import Optional, Tuple


_TRAILING_HAN = re.compile(r"([\u3400-\u9fff]+)$")
_HAN_ONLY = re.compile(r"^[\u3400-\u9fff]+$")


def derive_long_target(
    context: str,
    gold_text: str,
    *,
    minimum_target_characters: int = 6,
    preferred_target_characters: int = 10,
    maximum_target_characters: int = 12,
    minimum_remaining_context: int = 8,
) -> Optional[Tuple[str, str]]:
    """Move a suffix of the original context into a longer exact target."""

    if not _HAN_ONLY.fullmatch(gold_text):
        return None
    match = _TRAILING_HAN.search(context)
    if match is None:
        return None
    trailing_han = match.group(1)
    minimum_prefix = max(0, minimum_target_characters - len(gold_text))
    preferred_prefix = max(0, preferred_target_characters - len(gold_text))
    maximum_prefix = max(0, maximum_target_characters - len(gold_text))
    prefix_characters = min(len(trailing_han), preferred_prefix, maximum_prefix)
    if prefix_characters < minimum_prefix or prefix_characters == 0:
        return None
    short_context = context[:-prefix_characters]
    if len(short_context.strip()) < minimum_remaining_context:
        return None
    long_target = trailing_han[-prefix_characters:] + gold_text
    return short_context, long_target
