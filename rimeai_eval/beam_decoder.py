"""Pinyin-constrained beam decoder backed by a frozen character language model."""

from dataclasses import dataclass
import json
import math
import os
from pathlib import Path
import tempfile
from typing import Any, Dict, List, Sequence, Tuple

from .ngram_ranker import NGramRankerModel, ORDERS
from .pinyin_guard import PinyinGuard


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

    def to_dict(self) -> Dict[str, Any]:
        return {
            "schema_version": 1,
            "decoder_type": "pinyin-beam-ngram",
            "threshold": self.threshold,
            "beam_width": self.beam_width,
            "characters_per_syllable": self.characters_per_syllable,
            "language_model_sha256": self.language_model_sha256,
            "dictionary_sha256": self.dictionary_sha256,
            "dataset_sha256": self.dataset_sha256,
        }


@dataclass(frozen=True)
class BeamSuggestion:
    text: str
    confidence: float
    margin: float


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
        character_frequencies: Dict[str, int] = {}
        for gram, count in language_model.ngram_counts[2].items():
            character = gram[-1]
            character_frequencies[character] = (
                character_frequencies.get(character, 0) + count
            )
        self._character_frequencies = character_frequencies
        reverse: Dict[str, set[str]] = {}
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

    def _next_score(self, text: str, character: str) -> float:
        full_text = text + character
        score = 0.5 * math.log1p(
            self._character_frequencies.get(character, 0)
        )
        for order in ORDERS:
            if len(full_text) < order:
                continue
            gram = full_text[-order:]
            prefix = gram[:-1]
            score += math.log(
                (
                    self.language_model.ngram_counts[order].get(gram, 0)
                    + 0.1
                )
                / (
                    self.language_model.prefix_counts[order].get(prefix, 0)
                    + 1000.0
                )
            )
        return score

    def _sequence_score(self, context: str, text: str) -> float:
        prefix = ""
        score = 0.0
        context_suffix = context[-self.language_model.max_context_characters :]
        for character in text:
            score += self._next_score(
                context_suffix + prefix,
                character,
            )
            prefix += character
        return score

    def raw_decode(
        self,
        *,
        context: str,
        pinyin: str,
        candidates: Sequence[str],
    ) -> Tuple[str, float]:
        if not candidates:
            return "", 0.0
        baseline = candidates[0]
        syllables = self.guard.segment(baseline, pinyin)
        if syllables is None or len(syllables) != len(baseline):
            return baseline, 0.0
        candidate_segments = [
            self.guard.segment(candidate, pinyin)
            for candidate in candidates[:10]
        ]
        beam: List[Tuple[str, float]] = [("", 0.0)]
        context_suffix = context[-self.language_model.max_context_characters :]
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
                return baseline, 0.0
            expanded = [
                (
                    prefix + character,
                    score
                    + self._next_score(
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
        baseline_score = self._sequence_score(context, baseline)
        return best_text, best_score - baseline_score

    def suggest(
        self,
        *,
        context: str,
        pinyin: str,
        candidates: Sequence[str],
    ) -> BeamSuggestion:
        if not candidates:
            return BeamSuggestion("", 0.0, 0.0)
        text, margin = self.raw_decode(
            context=context,
            pinyin=pinyin,
            candidates=candidates,
        )
        if (
            not text
            or text == candidates[0]
            or margin < self.config.threshold
        ):
            return BeamSuggestion("", 0.0, margin)
        confidence = 1.0 / (
            1.0
            + math.exp(
                -max(
                    -30.0,
                    min(30.0, margin - self.config.threshold),
                )
            )
        )
        return BeamSuggestion(text, confidence, margin)


def train_beam_decoder_config(
    samples: Sequence[Dict[str, Any]],
    language_model: NGramRankerModel,
    guard: PinyinGuard,
    *,
    dataset_sha256: str,
    language_model_sha256: str,
    dictionary_sha256: str,
    beam_width: int = 16,
    characters_per_syllable: int = 20,
) -> Tuple[BeamDecoderConfig, Dict[str, Any]]:
    validation = [
        sample for sample in samples if sample["split"] == "validation"
    ]
    if not validation:
        raise BeamDecoderError("dataset has no validation samples")
    provisional = BeamDecoderConfig(
        threshold=0.0,
        beam_width=beam_width,
        characters_per_syllable=characters_per_syllable,
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
    baseline_accuracy = (
        sum(
            sample["candidates"][0] == sample["gold_text"]
            for sample in validation
        )
        / len(validation)
    )
    raw_accuracy = (
        sum(predicted == sample["gold_text"] for sample, predicted, _ in decoded)
        / len(validation)
    )
    config = BeamDecoderConfig(
        threshold=best_threshold,
        beam_width=beam_width,
        characters_per_syllable=characters_per_syllable,
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
            "raw_sentence_accuracy": round(raw_accuracy, 6),
            "sentence_accuracy": round(best_accuracy, 6),
        },
        "selected_hyperparameters": {
            "threshold": best_threshold,
            "beam_width": beam_width,
            "characters_per_syllable": characters_per_syllable,
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
    try:
        config = BeamDecoderConfig(
            threshold=float(payload["threshold"]),
            beam_width=int(payload["beam_width"]),
            characters_per_syllable=int(
                payload["characters_per_syllable"]
            ),
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
    ):
        raise BeamDecoderError("beam decoder parameters are invalid")
    return config
