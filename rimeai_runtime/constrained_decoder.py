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
    """Syllable-level pinyin equivalence for the frozen confusion pairs:
    initials swap as zh/z, ch/c, sh/s prefixes; finals swap as
    an/ang, en/eng, in/ing suffixes (so jin~jing, shan~shang). A
    syllable confusing both initial and final is out of scope."""
    if a == b:
        return True
    for first, second in _FUZZY_FINAL_PAIRS:
        if a.endswith(first) and b.endswith(second) and a[: -len(first)] == b[: -len(second)]:
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
        self._readings_by_text: Optional[Dict[str, FrozenSet[Syllables]]] = None

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

    def readings_by_text(self) -> Dict[str, FrozenSet[Syllables]]:
        """Token text -> readings, cached; substrings of gold text are
        looked up here when tiling a reachable path."""
        if self._readings_by_text is None:
            merged: Dict[str, Set[Syllables]] = {}
            for token_id, text in self.token_texts.items():
                readings = self.token_syllables.get(token_id)
                if not readings:
                    continue
                merged.setdefault(text, set()).update(readings)
            self._readings_by_text = {
                text: frozenset(readings) for text, readings in merged.items()
            }
        return self._readings_by_text


@dataclass(frozen=True)
class DecodeResult:
    text: str
    # Geometric mean of the CHOSEN token's probability renormalized
    # within the pinyin mask: each step sums the RAW next-token
    # softmax probabilities over that step's allowed candidates (Z)
    # and scores the chosen token as p / Z. Values live in [0, 1] and
    # are comparable across sentence lengths and against thresholds,
    # unlike the raw softmax value below. Comparable only within this
    # route — never against prompt-route confidences or beam margins.
    confidence: float
    consumed_syllables: int
    # Legacy RAW geometric mean of the chosen tokens' next-token
    # softmax probabilities (NOT renormalized): absolute values are
    # small and decay with sentence length, which is why the v3-mlx
    # baseline judged it weakly informative for gating. Kept for
    # evaluation-side comparison; empty/abstained results carry 0.0
    # for both fields, so positional construction sites stay valid.
    raw_confidence: float = 0.0


class ConstrainedGreedyDecoder:
    """Constrained next-token decoding under a hard pinyin mask.

    beam_width=1 is stepwise greedy with the long-word priority rule
    (argmax below 0.9 promotes the longest candidate with probability
    >= 0.5 * argmax; ties break to the smaller token id). beam_width > 1
    expands every allowed candidate and keeps the best complete paths by
    joint log-probability, which recovers sentences whose best reading
    needs the whole path compared, not stepwise winners. ``length_penalty``
    (beam only, default 0.0) divides the joint log-probability by
    steps**penalty GNMT-style before ranking, counteracting the built-in
    bias toward fewer-token paths; 0.0 keeps the ranking bit-identical
    to the plain joint log-probability.
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
        beam_width: int = 1,
        length_penalty: float = 0.0,
    ) -> DecodeResult:
        if beam_width <= 1:
            # Greedy follows one path, so no length competition exists;
            # length_penalty is a beam-ranking knob only.
            return cls._decode_greedy(
                scorer, syllables, index,
                max_characters=max_characters, fuzzy=fuzzy,
            )
        return cls._decode_beam(
            scorer, syllables, index,
            max_characters=max_characters, fuzzy=fuzzy, beam_width=beam_width,
            length_penalty=length_penalty,
        )

    @classmethod
    def _decode_greedy(
        cls,
        scorer: Callable[[Sequence[int]], Mapping[int, float]],
        syllables: Sequence[str],
        index: PinyinTokenIndex,
        *,
        max_characters: int,
        fuzzy: bool,
    ) -> DecodeResult:
        remaining = list(syllables)
        generated: List[int] = []
        text_parts: List[str] = []
        log_probability_sum = 0.0
        renormalized_log_sum = 0.0
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
            # Mask-normalizer Z: the RAW probability mass the pinyin
            # mask lets through this step. The chosen token's p is
            # always part of Z, so Z >= p > 0 on any surviving path
            # (p <= 0 abstains below); the guard keeps a degenerate
            # all-zero mask (Z == 0) from producing a divide-by-zero.
            mask_total = sum(probability for probability, _, _ in scored)
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
            if mask_total > 0.0:
                renormalized_log_sum += math.log(probability / mask_total)
            steps += 1
            del remaining[: len(reading)]
        raw_confidence = math.exp(log_probability_sum / steps) if steps else 0.0
        # Per-step ratios p / Z stay <= 1 (Z sums every allowed token's
        # probability, the chosen one included), so the exponential
        # lives in (0, 1]; the clamp only guards pathological scorer
        # inputs (e.g. negative probabilities on non-chosen tokens).
        confidence = (
            min(1.0, math.exp(renormalized_log_sum / steps))
            if steps
            else 0.0
        )
        return DecodeResult("".join(text_parts), confidence, len(syllables), raw_confidence)

    @staticmethod
    def _beam_rank_score(
        log_probability_sum: float, steps: int, length_penalty: float
    ) -> float:
        """Ranking score for a beam state: the joint log-probability,
        optionally divided by steps**length_penalty (GNMT-style).

        length_penalty 0.0 returns the joint log-probability untouched
        (bit-identical ranking); unfinished states (steps == 0) also
        rank by the raw sum, since only their extensions compete.
        """
        if steps <= 0 or length_penalty == 0.0:
            return log_probability_sum
        return log_probability_sum / (steps ** length_penalty)

    @classmethod
    def _decode_beam(
        cls,
        scorer: Callable[[Sequence[int]], Mapping[int, float]],
        syllables: Sequence[str],
        index: PinyinTokenIndex,
        *,
        max_characters: int,
        fuzzy: bool,
        beam_width: int,
        length_penalty: float = 0.0,
    ) -> DecodeResult:
        total = len(syllables)

        def expand(state):
            tokens, text, consumed, log_probability_sum, steps, renorm_log_sum = state
            probabilities = scorer(tokens)
            allowed = index.candidates(
                syllables[consumed:], fuzzy=fuzzy
            )
            # Mask-normalizer Z shared by every child of this state:
            # the RAW probability mass the mask lets through here.
            # Every kept child has probability > 0 and is part of Z, so
            # probability / mask_total stays in (0, 1].
            mask_total = sum(
                probabilities.get(token_id, 0.0)
                for token_id in allowed
            )
            expanded = []
            for token_id, reading in allowed.items():
                probability = probabilities.get(token_id, 0.0)
                if probability <= 0.0:
                    continue
                token_text = index.token_texts.get(token_id, "")
                if len(text) + len(token_text) > max_characters:
                    continue
                expanded.append(
                    (
                        tokens + [token_id],
                        text + token_text,
                        consumed + len(reading),
                        log_probability_sum + math.log(max(probability, 1e-12)),
                        steps + 1,
                        renorm_log_sum
                        + (
                            math.log(probability / mask_total)
                            if mask_total > 0.0
                            else 0.0
                        ),
                    )
                )
            return expanded

        frontier = [([], "", 0, 0.0, 0, 0.0)]
        completed: List[tuple] = []
        deepest = 0
        best_completed_score: float | None = None
        while frontier:
            next_frontier: List[tuple] = []
            for state in frontier:
                deepest = max(deepest, state[2])
                for child in expand(state):
                    if child[2] == total:
                        completed.append(child)
                        child_score = cls._beam_rank_score(
                            child[3], child[4], length_penalty
                        )
                        if best_completed_score is None or child_score > best_completed_score:
                            best_completed_score = child_score
                    else:
                        next_frontier.append(child)
            next_frontier.sort(
                key=lambda state: (
                    -cls._beam_rank_score(state[3], state[4], length_penalty),
                    state[0],
                )
            )
            frontier = next_frontier[:beam_width]
            # Lossless early stop. RAW joint scores never increase along
            # a path (every step adds log(max(p, 1e-12)) <= 0), so for a
            # frontier state at raw score L (< 0) any completion of
            # length len <= total scores at most L / len**penalty <=
            # L / total**penalty under the rank score (dividing a
            # negative bound by a larger positive divisor only raises
            # it, so total — the largest possible len — bounds every
            # completion). Once a complete path exists, any frontier
            # state whose rank-score upper bound L / total**penalty
            # sits strictly below the incumbent's rank score can only
            # ever complete strictly below it and can never beat the
            # incumbent under (-rank_score, tokens). With penalty 0 the
            # bound is L itself, exactly the plain joint-log-probability
            # prune. The comparison must stay strict: at equal scores
            # the token-id lexicographic tie-break can still flip the
            # winner, so equal-score states keep searching exactly as
            # before. With no completed path there is no incumbent to
            # prune against, so never prune.
            if (
                frontier
                and best_completed_score is not None
                and all(
                    cls._beam_rank_score(state[3], total, length_penalty)
                    < best_completed_score
                    for state in frontier
                )
            ):
                break
        if not completed:
            return DecodeResult("", 0.0, deepest)
        best = min(
            completed,
            key=lambda state: (
                -cls._beam_rank_score(state[3], state[4], length_penalty),
                state[0],
            ),
        )
        raw_confidence = math.exp(best[3] / best[4]) if best[4] else 0.0
        confidence = (
            min(1.0, math.exp(best[5] / best[4])) if best[4] else 0.0
        )
        return DecodeResult(best[1], confidence, total, raw_confidence)


def _syllable_matches(actual: str, typed: str, *, fuzzy: bool) -> bool:
    return actual == typed or (fuzzy and fuzzy_equal(actual, typed))


def gold_path_reachable(
    index: PinyinTokenIndex,
    gold_text: str,
    syllables: Sequence[str],
    *,
    fuzzy: bool = True,
) -> bool:
    """True when ``gold_text`` can be produced token-by-token under the
    index while consuming exactly ``syllables``.

    Index readings compose one syllable per character, so this reduces to:
    syllable count equals character count, each position's character has a
    reading matching the typed syllable, and the text can be tiled by
    indexed token texts (a character without its own token must be covered
    by a multi-character token)."""
    if not gold_text or len(syllables) != len(gold_text):
        return False
    readings_by_text = index.readings_by_text()
    if not readings_by_text:
        return False
    total = len(gold_text)
    max_length = min(max(len(text) for text in readings_by_text), total)
    reachable = {0}
    stack = [0]
    while stack:
        start = stack.pop()
        for length in range(1, min(max_length, total - start) + 1):
            text = gold_text[start : start + length]
            for reading in readings_by_text.get(text, ()):
                window = syllables[start : start + length]
                if len(reading) == length and all(
                    _syllable_matches(actual, typed, fuzzy=fuzzy)
                    for actual, typed in zip(reading, window)
                ):
                    end = start + length
                    if end == total:
                        return True
                    if end not in reachable:
                        reachable.add(end)
                        stack.append(end)
                    break
    return False
