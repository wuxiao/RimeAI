"""Deterministic safety policies shared by semantic ranker workers."""

from typing import Dict, List, Sequence, Tuple


Candidate = Dict[str, str]
Pair = Tuple[str, str]


def _comparison_length(text: str) -> int:
    return len("".join(text.split()))


def partition_full_length_candidates(
    candidates: Sequence[Candidate],
) -> Tuple[List[Candidate], List[Candidate]]:
    """Keep incomplete Rime fallbacks out of semantic reordering.

    Rime may expose candidates that consume only a prefix of the active input.
    The ranker protocol does not currently carry consumed-input spans, so the
    first Rime candidate's normalized text length is used as a conservative
    proxy. Shorter and longer candidates preserve their original order.
    """

    if not candidates:
        return [], []
    target_length = _comparison_length(candidates[0]["text"])
    eligible: List[Candidate] = []
    preserved: List[Candidate] = []
    for candidate in candidates:
        destination = (
            eligible
            if _comparison_length(candidate["text"]) == target_length
            else preserved
        )
        destination.append(candidate)
    return eligible, preserved


def build_semantic_pairs(
    *,
    context: str,
    candidates: Sequence[Candidate],
    strategy: str,
) -> List[Pair]:
    """Build stable reranker inputs without including raw keystrokes."""

    if strategy == "context-candidate":
        return [(context, candidate["text"]) for candidate in candidates]
    if strategy == "context-completion":
        return [
            ("请判断候选是否自然地续接前文", f"{context}{candidate['text']}")
            for candidate in candidates
        ]
    raise ValueError(f"unsupported semantic pair strategy: {strategy}")
