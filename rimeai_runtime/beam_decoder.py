"""Pinyin-constrained beam decoder backed by a frozen character language model."""

from __future__ import annotations

from dataclasses import dataclass
import json
import math
import os
from pathlib import Path
import tempfile
from collections.abc import Sequence
from typing import Any

from .lm_fusion import CharLMScorer, StaticCharLM
from .ngram_ranker import NGramRankerModel
from .pinyin_guard import PinyinGuard

MAX_SENTENCE_CHARACTERS = 30
MAX_CANDIDATE_CHARACTERS = 128


class BeamDecoderError(ValueError):
    pass


@dataclass(frozen=True)
class BeamDecoderConfig:
    threshold: float
    beam_width: int
    characters_per_syllable: int
    language_model_sha256: str
    dictionary_sha256: str
    dataset_sha256: str
    # Weight of the order-2 character frequency prior in _next_score.
    # Artifacts written before this field existed (schema_version 1 without
    # the key) decode with the historical hardcoded value 0.5.
    character_frequency_weight: float = 0.5

    def to_dict(self) -> dict[str, Any]:
        return {
            "schema_version": 1,
            "decoder_type": "pinyin-beam-ngram",
            "threshold": self.threshold,
            "beam_width": self.beam_width,
            "characters_per_syllable": self.characters_per_syllable,
            "character_frequency_weight": self.character_frequency_weight,
            "language_model_sha256": self.language_model_sha256,
            "dictionary_sha256": self.dictionary_sha256,
            "dataset_sha256": self.dataset_sha256,
        }


@dataclass(frozen=True)
class BeamSuggestion:
    text: str
    confidence: float
    margin: float
    reason: str = "suggestion"


@dataclass(frozen=True)
class SegmentDecodeInput:
    pinyin: str
    separator: str
    committed_text: str


class BeamSentenceDecoder:
    def __init__(
        self,
        language_model: NGramRankerModel,
        guard: PinyinGuard,
        config: BeamDecoderConfig,
    ):
        self.language_model = language_model
        self.guard = guard
        self.config = config
        character_frequencies: dict[str, int] = {}
        for gram, count in language_model.ngram_counts[2].items():
            character = gram[-1]
            character_frequencies[character] = (
                character_frequencies.get(character, 0) + count
            )
        self._character_frequencies = character_frequencies
        self._default_scorer = StaticCharLM(language_model)
        reverse: dict[str, set[str]] = {}
        for text, pronunciations in guard.pronunciations.items():
            if len(text) != 1:
                continue
            for pronunciation in pronunciations:
                reverse.setdefault(pronunciation, set()).add(text)
        self._characters_by_syllable = {
            syllable: sorted(
                characters,
                key=lambda character: (
                    -character_frequencies.get(character, 0),
                    character,
                ),
            )
            for syllable, characters in reverse.items()
        }

    def _next_score(
        self,
        scorer: CharLMScorer,
        text: str,
        character: str,
    ) -> float:
        # The frequency prior stays static, sourced from the decoder's own
        # order-2 table; only the language-model term honors `scorer`.
        return self.config.character_frequency_weight * math.log1p(
            self._character_frequencies.get(character, 0)
        ) + scorer.next_char_log_prob(text, character)

    def _sequence_score(
        self,
        scorer: CharLMScorer,
        context: str,
        text: str,
    ) -> float:
        prefix = ""
        score = 0.0
        context_suffix = context[-scorer.max_context_characters :]
        for character in text:
            score += self._next_score(
                scorer,
                context_suffix + prefix,
                character,
            )
            prefix += character
        return score

    def _first_complete_candidate(
        self,
        *,
        pinyin: str,
        candidates: Sequence[str],
        maximum_characters: int,
    ) -> tuple[str, list[str]] | None:
        for candidate in candidates[:10]:
            syllables = self.guard.segment(
                candidate,
                pinyin,
                maximum_characters=maximum_characters,
            )
            if syllables is not None and len(syllables) == len(candidate):
                return candidate, syllables
        return None

    def _decode_pair(
        self,
        *,
        context: str,
        pinyin: str,
        candidates: Sequence[str],
        scorer: CharLMScorer | None = None,
    ) -> tuple[str, float, float | None]:
        """One static beam expansion returning the decoded text with the
        static margin (gate metric) and, when a scorer is given, the
        scorer-adjudicated margin."""
        if not candidates:
            return "", 0.0, None
        complete = self._first_complete_candidate(
            pinyin=pinyin,
            candidates=candidates,
            maximum_characters=MAX_SENTENCE_CHARACTERS,
        )
        if complete is None:
            return candidates[0], 0.0, None
        baseline, syllables = complete
        candidate_segments = [
            self.guard.segment(
                candidate,
                pinyin,
                maximum_characters=MAX_SENTENCE_CHARACTERS,
            )
            for candidate in candidates[:10]
        ]
        # Beam expansion always scores statically; a custom scorer only
        # adjudicates the final margin (final path vs baseline), never the
        # beam search itself.
        static_scorer = self._default_scorer
        beam: list[tuple[str, float]] = [("", 0.0)]
        context_suffix = context[-static_scorer.max_context_characters :]
        for position, syllable in enumerate(syllables):
            characters = set(
                self._characters_by_syllable.get(syllable, [])[
                    : self.config.characters_per_syllable
                ]
            )
            for candidate, segmentation in zip(
                candidates[:10], candidate_segments
            ):
                if (
                    segmentation is not None
                    and len(candidate) == len(syllables)
                ):
                    characters.add(candidate[position])
            if not characters:
                return baseline, 0.0, None
            expanded = [
                (
                    prefix + character,
                    score
                    + self._next_score(
                        static_scorer,
                        context_suffix + prefix,
                        character,
                    ),
                )
                for prefix, score in beam
                for character in characters
            ]
            expanded.sort(key=lambda item: (-item[1], item[0]))
            beam = expanded[: self.config.beam_width]
        best_text, best_score = beam[0]
        static_margin = best_score - self._sequence_score(
            static_scorer,
            context,
            baseline,
        )
        if scorer is None:
            return best_text, static_margin, None
        final_score = self._sequence_score(scorer, context, best_text)
        baseline_score = self._sequence_score(scorer, context, baseline)
        return best_text, static_margin, final_score - baseline_score

    def raw_decode(
        self,
        *,
        context: str,
        pinyin: str,
        candidates: Sequence[str],
        scorer: CharLMScorer | None = None,
    ) -> tuple[str, float]:
        text, static_margin, fused_margin = self._decode_pair(
            context=context,
            pinyin=pinyin,
            candidates=candidates,
            scorer=scorer,
        )
        if scorer is not None and fused_margin is not None:
            return text, fused_margin
        return text, static_margin

    def suggest(
        self,
        *,
        context: str,
        pinyin: str,
        candidates: Sequence[str],
        scorer: CharLMScorer | None = None,
    ) -> BeamSuggestion:
        if not candidates:
            return BeamSuggestion("", 0.0, 0.0, "no_candidate")
        complete = self._first_complete_candidate(
            pinyin=pinyin,
            candidates=candidates,
            maximum_characters=MAX_CANDIDATE_CHARACTERS,
        )
        if complete is None:
            return BeamSuggestion("", 0.0, 0.0, "incomplete_candidate")
        if len(complete[0]) > MAX_SENTENCE_CHARACTERS:
            return BeamSuggestion("", 0.0, 0.0, "too_long")
        # One-way ratchet: acceptance is decided by the statically calibrated
        # margin only; the fused scorer can raise confidence, never demote a
        # statically accepted suggestion below the gate.
        text, static_margin, fused_margin = self._decode_pair(
            context=context,
            pinyin=pinyin,
            candidates=candidates,
            scorer=scorer,
        )
        if not text or text == candidates[0]:
            return BeamSuggestion("", 0.0, static_margin, "no_change")
        if static_margin < self.config.threshold:
            return BeamSuggestion("", 0.0, static_margin, "below_threshold")
        confidence = 1.0 / (
            1.0
            + math.exp(
                -max(
                    -30.0,
                    min(30.0, static_margin - self.config.threshold),
                )
            )
        )
        if fused_margin is not None:
            fused_confidence = 1.0 / (
                1.0
                + math.exp(
                    -max(
                        -30.0,
                        min(30.0, fused_margin - self.config.threshold),
                    )
                )
            )
            if fused_confidence > confidence:
                confidence = fused_confidence
        return BeamSuggestion(text, confidence, static_margin, "suggestion")

    def suggest_segments(
        self,
        *,
        context: str,
        segments: Sequence[SegmentDecodeInput],
        active_candidates: Sequence[str],
        scorer: CharLMScorer | None = None,
    ) -> BeamSuggestion:
        if not active_candidates:
            return BeamSuggestion("", 0.0, 0.0, "no_candidate")
        confidences: list[float] = []
        margins: list[float] = []
        pieces: list[str] = []
        accumulated = context
        for index, segment in enumerate(segments):
            is_last = index == len(segments) - 1
            if is_last:
                baseline = active_candidates[0]
                candidates: Sequence[str] = active_candidates
            elif segment.committed_text:
                baseline = segment.committed_text
                candidates = [segment.committed_text]
            else:
                baseline = ""
                candidates = []
            segment_kwargs = (
                {"scorer": scorer} if scorer is not None else {}
            )
            suggestion = (
                self.suggest(
                    context=accumulated,
                    pinyin=segment.pinyin,
                    candidates=candidates,
                    **segment_kwargs,
                )
                if candidates
                else None
            )
            if suggestion is not None and suggestion.text:
                segment_text = suggestion.text
                confidences.append(suggestion.confidence)
                margins.append(suggestion.margin)
            else:
                segment_text = baseline
                if (
                    suggestion is not None
                    and suggestion.reason == "below_threshold"
                ):
                    margins.append(suggestion.margin)
            pieces.append(segment_text + segment.separator)
            accumulated += segment_text + segment.separator
        text = "".join(pieces)
        if len(text) > MAX_SENTENCE_CHARACTERS:
            return BeamSuggestion("", 0.0, 0.0, "too_long")
        if not margins:
            return BeamSuggestion("", 0.0, 0.0, "no_change")
        margin = min(margins)
        if margin < self.config.threshold:
            return BeamSuggestion("", 0.0, margin, "below_threshold")
        return BeamSuggestion(text, min(confidences), margin, "suggestion")


def _int_grid(
    values: int | Sequence[int], name: str
) -> tuple[int, ...]:
    """Normalize a scalar or sequence int grid, failing closed."""
    entries = (values,) if isinstance(values, int) else tuple(values)
    if not entries:
        raise BeamDecoderError(f"{name} grid must not be empty")
    for entry in entries:
        if isinstance(entry, bool) or not isinstance(entry, int):
            raise BeamDecoderError(f"{name} grid entries must be integers")
        if entry < 1:
            raise BeamDecoderError(f"{name} grid entries must be >= 1")
    return tuple(dict.fromkeys(entries))


def _float_grid(
    values: int | float | Sequence[int | float], name: str
) -> tuple[float, ...]:
    """Normalize a scalar or sequence float grid, failing closed."""
    if isinstance(values, bool):
        raise BeamDecoderError(f"{name} grid entries must be numbers")
    entries = (
        (values,) if isinstance(values, (int, float)) else tuple(values)
    )
    if not entries:
        raise BeamDecoderError(f"{name} grid must not be empty")
    for entry in entries:
        if isinstance(entry, bool) or not isinstance(entry, (int, float)):
            raise BeamDecoderError(f"{name} grid entries must be numbers")
        if not math.isfinite(entry) or entry < 0.0:
            raise BeamDecoderError(
                f"{name} grid entries must be finite and >= 0"
            )
    return tuple(dict.fromkeys(float(entry) for entry in entries))


def _evaluate_combination(
    validation: Sequence[dict[str, Any]],
    language_model: NGramRankerModel,
    guard: PinyinGuard,
    *,
    beam_width: int,
    characters_per_syllable: int,
    character_frequency_weight: float,
    language_model_sha256: str,
    dictionary_sha256: str,
    dataset_sha256: str,
) -> tuple[float, float, float]:
    """Decode `validation` once, then sweep the gate threshold.

    Selection objective matches the historical single-knob trainer: highest
    validation sentence accuracy, threshold ties take the larger threshold.
    Only validation samples are ever read here.
    """
    provisional = BeamDecoderConfig(
        threshold=0.0,
        beam_width=beam_width,
        characters_per_syllable=characters_per_syllable,
        character_frequency_weight=character_frequency_weight,
        language_model_sha256=language_model_sha256,
        dictionary_sha256=dictionary_sha256,
        dataset_sha256=dataset_sha256,
    )
    decoder = BeamSentenceDecoder(language_model, guard, provisional)
    decoded = [
        (
            sample,
            *decoder.raw_decode(
                context=sample["context"],
                pinyin=sample["pinyin"],
                candidates=sample["candidates"][:10],
            ),
        )
        for sample in validation
    ]
    margins = [max(0.0, margin) for _, _, margin in decoded]
    thresholds = sorted(
        set([0.0, (max(margins) + 1.0) if margins else 1.0] + margins)
    )
    best_accuracy = -1.0
    best_threshold = 0.0
    for threshold in thresholds:
        hits = 0
        for sample, predicted, margin in decoded:
            baseline = sample["candidates"][0]
            applied = (
                predicted
                if predicted != baseline and margin >= threshold
                else baseline
            )
            hits += applied == sample["gold_text"]
        accuracy = hits / len(validation)
        if (
            accuracy > best_accuracy
            or (
                accuracy == best_accuracy
                and threshold > best_threshold
            )
        ):
            best_accuracy = accuracy
            best_threshold = threshold
    raw_accuracy = (
        sum(predicted == sample["gold_text"] for sample, predicted, _ in decoded)
        / len(validation)
    )
    return best_threshold, best_accuracy, raw_accuracy


def train_beam_decoder_config(
    samples: Sequence[dict[str, Any]],
    language_model: NGramRankerModel,
    guard: PinyinGuard,
    *,
    dataset_sha256: str,
    language_model_sha256: str,
    dictionary_sha256: str,
    beam_width: int | Sequence[int] = 16,
    characters_per_syllable: int | Sequence[int] = 20,
    character_frequency_weight: float | Sequence[float] = 0.5,
) -> tuple[BeamDecoderConfig, dict[str, Any]]:
    """Calibrate the beam decoder on the validation split only.

    Two-stage scan instead of a full Cartesian product: stage 1 scans the
    character-frequency weight x characters-per-syllable grid at the anchor
    beam width (the first entry of the beam grid), stage 2 scans the
    remaining beam widths at the stage-1 winner. Ties keep the earliest
    grid entry, so putting the current production values first makes the
    incumbent win unless a challenger is strictly better on validation.
    """
    validation = [
        sample for sample in samples if sample["split"] == "validation"
    ]
    if not validation:
        raise BeamDecoderError("dataset has no validation samples")
    beam_grid = _int_grid(beam_width, "beam_width")
    characters_grid = _int_grid(
        characters_per_syllable, "characters_per_syllable"
    )
    weight_grid = _float_grid(
        character_frequency_weight, "character_frequency_weight"
    )
    combination_kwargs = {
        "language_model_sha256": language_model_sha256,
        "dictionary_sha256": dictionary_sha256,
        "dataset_sha256": dataset_sha256,
    }
    stage1_rows: list[dict[str, Any]] = []
    best_threshold = 0.0
    best_accuracy = -1.0
    best_raw_accuracy = 0.0
    best_beam = beam_grid[0]
    best_characters = characters_grid[0]
    best_weight = weight_grid[0]
    for weight in weight_grid:
        for characters in characters_grid:
            threshold, accuracy, raw_accuracy = _evaluate_combination(
                validation,
                language_model,
                guard,
                beam_width=beam_grid[0],
                characters_per_syllable=characters,
                character_frequency_weight=weight,
                **combination_kwargs,
            )
            stage1_rows.append(
                {
                    "stage": 1,
                    "beam_width": beam_grid[0],
                    "characters_per_syllable": characters,
                    "character_frequency_weight": weight,
                    "threshold": threshold,
                    "validation_raw_sentence_accuracy": round(raw_accuracy, 6),
                    "validation_sentence_accuracy": round(accuracy, 6),
                }
            )
            if accuracy > best_accuracy:
                best_threshold = threshold
                best_accuracy = accuracy
                best_raw_accuracy = raw_accuracy
                best_characters = characters
                best_weight = weight
    stage2_rows: list[dict[str, Any]] = []
    for width in beam_grid[1:]:
        threshold, accuracy, raw_accuracy = _evaluate_combination(
            validation,
            language_model,
            guard,
            beam_width=width,
            characters_per_syllable=best_characters,
            character_frequency_weight=best_weight,
            **combination_kwargs,
        )
        stage2_rows.append(
            {
                "stage": 2,
                "beam_width": width,
                "characters_per_syllable": best_characters,
                "character_frequency_weight": best_weight,
                "threshold": threshold,
                "validation_raw_sentence_accuracy": round(raw_accuracy, 6),
                "validation_sentence_accuracy": round(accuracy, 6),
            }
        )
        if accuracy > best_accuracy:
            best_threshold = threshold
            best_accuracy = accuracy
            best_raw_accuracy = raw_accuracy
            best_beam = width
    baseline_accuracy = (
        sum(
            sample["candidates"][0] == sample["gold_text"]
            for sample in validation
        )
        / len(validation)
    )
    config = BeamDecoderConfig(
        threshold=best_threshold,
        beam_width=best_beam,
        characters_per_syllable=best_characters,
        character_frequency_weight=best_weight,
        language_model_sha256=language_model_sha256,
        dictionary_sha256=dictionary_sha256,
        dataset_sha256=dataset_sha256,
    )
    report = {
        "schema_version": 1,
        "decoder_type": "pinyin-beam-ngram",
        "validation_samples": len(validation),
        "test_samples_used": 0,
        "validation": {
            "baseline_sentence_accuracy": round(baseline_accuracy, 6),
            "raw_sentence_accuracy": round(best_raw_accuracy, 6),
            "sentence_accuracy": round(best_accuracy, 6),
        },
        "selected_hyperparameters": {
            "threshold": best_threshold,
            "beam_width": best_beam,
            "characters_per_syllable": best_characters,
            "character_frequency_weight": best_weight,
        },
        "hyperparameter_scan": {
            "strategy": "two-stage",
            "splits_used": ["validation"],
            "selection_rule": (
                "highest validation sentence accuracy; threshold ties take "
                "the larger threshold; combination ties keep the earliest "
                "grid entry (anchor values first)"
            ),
            "evaluated_combinations": len(stage1_rows) + len(stage2_rows),
            "combinations": [*stage1_rows, *stage2_rows],
        },
    }
    return config, report


def write_beam_config_atomic(path: Path, config: BeamDecoderConfig) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        dir=path.parent,
        prefix=f".{path.name}.",
        suffix=".tmp",
    )
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as file:
            json.dump(
                config.to_dict(),
                file,
                ensure_ascii=False,
                separators=(",", ":"),
                sort_keys=True,
            )
            file.write("\n")
            file.flush()
            os.fsync(file.fileno())
        os.replace(temporary_name, path)
    except BaseException:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass
        raise


def load_beam_config(path: Path) -> BeamDecoderConfig:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise BeamDecoderError(f"cannot read decoder artifact '{path}'") from error
    if (
        not isinstance(payload, dict)
        or payload.get("schema_version") != 1
        or payload.get("decoder_type") != "pinyin-beam-ngram"
    ):
        raise BeamDecoderError("unsupported beam decoder artifact")
    # Optional since schema_version 1 artifacts gained the field: absent
    # means the historical hardcoded 0.5 prior weight. Anything present
    # must be a real, finite, non-negative number (bools and strings are
    # rejected) so bad artifacts fail closed.
    raw_frequency_weight = payload.get("character_frequency_weight", 0.5)
    if isinstance(raw_frequency_weight, bool) or not isinstance(
        raw_frequency_weight, (int, float)
    ):
        raise BeamDecoderError("beam decoder artifact fields are invalid")
    try:
        config = BeamDecoderConfig(
            threshold=float(payload["threshold"]),
            beam_width=int(payload["beam_width"]),
            characters_per_syllable=int(
                payload["characters_per_syllable"]
            ),
            character_frequency_weight=float(raw_frequency_weight),
            language_model_sha256=str(
                payload["language_model_sha256"]
            ),
            dictionary_sha256=str(payload["dictionary_sha256"]),
            dataset_sha256=str(payload["dataset_sha256"]),
        )
    except (KeyError, TypeError, ValueError) as error:
        raise BeamDecoderError("beam decoder artifact fields are invalid") from error
    if (
        config.beam_width < 1
        or config.characters_per_syllable < 1
        or config.threshold < 0
        or not math.isfinite(config.character_frequency_weight)
        or config.character_frequency_weight < 0.0
    ):
        raise BeamDecoderError("beam decoder parameters are invalid")
    return config
