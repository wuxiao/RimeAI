"""In-process P1 engine using only P0-approved local artifacts."""

import hashlib
from pathlib import Path
from typing import Any, Dict, Optional

from rimeai_eval.beam_decoder import (
    BeamSentenceDecoder,
    load_beam_config,
)
from rimeai_eval.ngram_ranker import load_ngram_model
from rimeai_eval.neural_ranker import (
    HybridSemanticRanker,
    load_neural_ranker,
)
from rimeai_eval.pinyin_guard import PinyinGuard
from rimeai_eval.evaluation import RankerError
from rimeai_eval.candidate_policy import partition_full_length_candidates


SENTENCE_MIN_CONFIDENCE = 0.60


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
        neural_model_path: Optional[Path] = None,
        fusion_config_path: Optional[Path] = None,
        neural_device: str = "cpu",
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
        if (neural_model_path is None) != (fusion_config_path is None):
            raise ValueError(
                "neural model and fusion config must be configured together"
            )
        self._fallback_ranker = language_model
        if neural_model_path is not None and fusion_config_path is not None:
            neural_ranker = load_neural_ranker(
                neural_model_path,
                guard,
                device=neural_device,
            )
            self._ranker = HybridSemanticRanker(
                neural_ranker,
                language_model,
                fusion_config_path,
            )
        else:
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
        if neural_model_path is not None and fusion_config_path is not None:
            neural_manifest = neural_model_path / "manifest.json"
            self.artifacts.extend(
                [
                    {
                        "role": "neural_ranker",
                        "path": str(neural_manifest.resolve()),
                        "sha256": _sha256_path(neural_manifest),
                    },
                    {
                        "role": "fusion_config",
                        "path": str(fusion_config_path.resolve()),
                        "sha256": _sha256_path(fusion_config_path),
                    },
                ]
            )
            self.artifact_id = (
                f"{self._ranker.model_artifact_id}:"
                f"beam-{beam_config_sha256[:12]}"
            )
        else:
            self.artifact_id = (
                f"rimeai-p1:lm-{language_model_sha256[:12]}:"
                f"beam-{beam_config_sha256[:12]}:"
                f"dict-{dictionary_sha256[:12]}"
            )

    def infer(self, request: Dict[str, Any]) -> Dict[str, Any]:
        candidates = request["candidates"]
        semantic_window = [
            {"id": str(index), "text": candidate}
            for index, candidate in enumerate(candidates[:10])
        ]
        comparable_candidates, _ = partition_full_length_candidates(
            semantic_window
        )
        try:
            if isinstance(self._ranker, HybridSemanticRanker):
                ranking, rank_confidence = self._ranker.rank_candidates(
                    context=request["context"],
                    pinyin=request["pinyin"],
                    candidates=candidates,
                )
            else:
                ranking, rank_confidence = self._ranker.rank(
                    context=request["context"],
                    candidates=candidates,
                )
        except RankerError:
            ranking, rank_confidence = self._fallback_ranker.rank(
                context=request["context"],
                candidates=candidates,
            )
        ranked_candidate = ""
        if not ranking:
            decision = "no_candidate"
        elif len(comparable_candidates) < 2:
            # The conservative completeness guard did not leave a real choice
            # for the ranker. This is not evidence that the model agreed with
            # Rime's first candidate.
            decision = "insufficient_candidates"
            rank_confidence = 0.0
        elif ranking[0] == candidates[0]:
            decision = "same_top_candidate"
        elif rank_confidence < self._ranker_min_confidence:
            decision = "below_confidence"
        else:
            decision = "ranked_candidate"
            ranked_candidate = ranking[0]
        decision_confidence = rank_confidence
        sentence_suggestion = ""
        sentence_confidence = 0.0
        if request["allow_sentence"]:
            suggestion = self._sentence_decoder.suggest(
                context=request["context"],
                pinyin=request["pinyin"],
                candidates=candidates,
            )
            suggestion_text = suggestion.text
            sentence_confidence = suggestion.confidence
            if (
                suggestion_text
                and sentence_confidence >= SENTENCE_MIN_CONFIDENCE
            ):
                sentence_suggestion = suggestion_text
                decision = "sentence_suggestion"
                ranked_candidate = ""
                decision_confidence = sentence_confidence
            elif getattr(suggestion, "reason", "") == "too_long":
                decision = "sentence_too_long"
                ranked_candidate = ""
                decision_confidence = 0.0
            elif getattr(suggestion, "reason", "") == "incomplete_candidate":
                if decision != "ranked_candidate":
                    decision = "sentence_incomplete"
                    ranked_candidate = ""
                    decision_confidence = 0.0
        return {
            "decision": decision,
            "ranked_candidate": ranked_candidate,
            "sentence_suggestion": sentence_suggestion,
            "confidence": decision_confidence,
        }
