"""In-process P1 engine using only P0-approved local artifacts."""

import hashlib
from pathlib import Path
from typing import Any, Dict

from rimeai_eval.beam_decoder import (
    BeamSentenceDecoder,
    load_beam_config,
)
from rimeai_eval.ngram_ranker import load_ngram_model
from rimeai_eval.pinyin_guard import PinyinGuard


def _sha256_path(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        while True:
            chunk = file.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


class LocalInferenceEngine:
    def __init__(
        self,
        *,
        language_model_path: Path,
        beam_config_path: Path,
        rime_dictionary_path: Path,
        ranker_min_confidence: float = 0.55,
    ):
        if not 0 <= ranker_min_confidence <= 1:
            raise ValueError("ranker_min_confidence must be from 0 to 1")
        language_model_sha256 = _sha256_path(language_model_path)
        dictionary_sha256 = _sha256_path(rime_dictionary_path)
        beam_config_sha256 = _sha256_path(beam_config_path)
        language_model = load_ngram_model(language_model_path)
        beam_config = load_beam_config(beam_config_path)
        if beam_config.language_model_sha256 != language_model_sha256:
            raise ValueError("beam config language model SHA-256 mismatch")
        if beam_config.dictionary_sha256 != dictionary_sha256:
            raise ValueError("beam config Rime dictionary SHA-256 mismatch")
        guard = PinyinGuard.from_rime_dictionary(rime_dictionary_path)
        self._ranker = language_model
        self._sentence_decoder = BeamSentenceDecoder(
            language_model,
            guard,
            beam_config,
        )
        self._ranker_min_confidence = ranker_min_confidence
        self.artifacts = [
            {
                "role": "language_model",
                "path": str(language_model_path.resolve()),
                "sha256": language_model_sha256,
            },
            {
                "role": "sentence_config",
                "path": str(beam_config_path.resolve()),
                "sha256": beam_config_sha256,
            },
            {
                "role": "rime_dictionary",
                "path": str(rime_dictionary_path.resolve()),
                "sha256": dictionary_sha256,
            },
        ]
        self.artifact_id = (
            f"rimeai-p1:lm-{language_model_sha256[:12]}:"
            f"beam-{beam_config_sha256[:12]}:"
            f"dict-{dictionary_sha256[:12]}"
        )

    def infer(self, request: Dict[str, Any]) -> Dict[str, Any]:
        candidates = request["candidates"]
        ranking, rank_confidence = self._ranker.rank(
            context=request["context"],
            candidates=candidates,
        )
        ranked_candidate = ""
        if (
            ranking
            and ranking[0] != candidates[0]
            and rank_confidence >= self._ranker_min_confidence
        ):
            ranked_candidate = ranking[0]
        sentence_suggestion = ""
        sentence_confidence = 0.0
        if request["allow_sentence"]:
            suggestion = self._sentence_decoder.suggest(
                context=request["context"],
                pinyin=request["pinyin"],
                candidates=candidates,
            )
            sentence_suggestion = suggestion.text
            sentence_confidence = suggestion.confidence
        return {
            "ranked_candidate": ranked_candidate,
            "sentence_suggestion": sentence_suggestion,
            "confidence": max(rank_confidence, sentence_confidence),
        }
