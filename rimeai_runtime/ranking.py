"""Shared ranking result and ranker failure types for the RimeAI runtime."""

from dataclasses import dataclass
from typing import Tuple


@dataclass(frozen=True)
class Ranking:
    candidates: Tuple[str, ...]
    confidence: float


class RankerError(RuntimeError):
    """A recoverable ranker failure for one evaluation sample."""
