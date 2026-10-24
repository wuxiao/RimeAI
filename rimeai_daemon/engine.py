"""In-process P1 engine using only P0-approved local artifacts."""

from __future__ import annotations

import hashlib
import json
import logging
from pathlib import Path
from typing import Any

from rimeai_runtime.beam_decoder import (
    BeamSentenceDecoder,
    SegmentDecodeInput,
    load_beam_config,
)
from rimeai_runtime.candidate_policy import partition_full_length_candidates
from rimeai_runtime.lm_fusion import CharLMScorer, StaticCharLM
from rimeai_runtime.neural_ranker import (
    HybridSemanticRanker,
    load_neural_ranker,
)
from rimeai_runtime.ngram_ranker import load_ngram_model
from rimeai_runtime.pinyin_guard import PinyinGuard
from rimeai_runtime.ranking import RankerError
from rimeai_runtime.script_converter import SimplifiedScriptConverter

from .fused_lm import FusedCharLM
from .user_lm import UserLanguageModel

SENTENCE_MIN_CONFIDENCE = 0.60

logger = logging.getLogger(__name__)


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
        neural_model_path: Path | None = None,
        fusion_config_path: Path | None = None,
        neural_device: str = "cpu",
        ranker_min_confidence: float = 0.55,
        user_lm_path: Path | None = None,
        t2s_table_path: Path | None = None,
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
        hybrid_ranker: HybridSemanticRanker | None = None
        if neural_model_path is not None and fusion_config_path is not None:
            neural_ranker = load_neural_ranker(
                neural_model_path,
                guard,
                device=neural_device,
            )
            hybrid_ranker = HybridSemanticRanker(
                neural_ranker,
                language_model,
                fusion_config_path,
            )
            self._ranker = hybrid_ranker
        else:
            self._ranker = language_model
        self._sentence_decoder = BeamSentenceDecoder(
            language_model,
            guard,
            beam_config,
        )
        self._static_scorer = StaticCharLM(language_model)
        self._ranker_min_confidence = ranker_min_confidence
        self._user_lm_path = user_lm_path
        self._t2s_converter = (
            SimplifiedScriptConverter.load(t2s_table_path)
            if t2s_table_path is not None
            else None
        )
        self._user_lm: UserLanguageModel | None = None
        self._user_lm_mtime: float | None = None
        self._user_lm_size: int | None = None
        self._refresh_user_lm(force=True)
        self.artifacts: list[dict[str, Any]] = [
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
            neural_model_type = None
            try:
                neural_manifest_payload = json.loads(
                    neural_manifest.read_text(encoding="utf-8")
                )
            except (OSError, json.JSONDecodeError):
                neural_manifest_payload = None
            if isinstance(neural_manifest_payload, dict):
                neural_model_type = neural_manifest_payload.get("model_type")
            self.artifacts.extend(
                [
                    {
                        "role": "neural_ranker",
                        "path": str(neural_manifest.resolve()),
                        "sha256": _sha256_path(neural_manifest),
                        "model_type": neural_model_type,
                    },
                    {
                        "role": "fusion_config",
                        "path": str(fusion_config_path.resolve()),
                        "sha256": _sha256_path(fusion_config_path),
                    },
                ]
            )
            self.artifact_id = (
                f"{hybrid_ranker.model_artifact_id if hybrid_ranker else ''}:"
                f"beam-{beam_config_sha256[:12]}"
            )
        else:
            self.artifact_id = (
                f"rimeai-p1:lm-{language_model_sha256[:12]}:"
                f"beam-{beam_config_sha256[:12]}:"
                f"dict-{dictionary_sha256[:12]}"
            )
        logger.info(
            "engine loaded artifact_id=%s ranker=%s user_lm=%s t2s=%s",
            self.artifact_id,
            type(self._ranker).__name__,
            self._user_lm_path,
            self._t2s_converter is not None,
        )

    def _refresh_user_lm(self, *, force: bool = False) -> None:
        """Reloads the consolidated user LM when its artifact changes.

        A missing artifact leaves the engine without user evidence, which
        keeps the baseline behavior bit-for-bit."""
        path = self._user_lm_path
        if path is None:
            return
        try:
            status = path.stat()
        except OSError:
            # Saves are atomic (os.replace), so a missing file is a genuine
            # deletion (settings-page clear) — take effect live instead of
            # waiting for an engine restart.
            self._user_lm = None
            self._user_lm_mtime = None
            self._user_lm_size = None
            return
        # Compare (mtime, size): a rewrite inside the same filesystem
        # timestamp tick keeps the old mtime, and mtime alone would then
        # keep serving the previous model.
        if (
            not force
            and status.st_mtime == self._user_lm_mtime
            and status.st_size == self._user_lm_size
        ):
            return
        try:
            self._user_lm = UserLanguageModel.load(path)
            self._user_lm_mtime = status.st_mtime
            self._user_lm_size = status.st_size
            logger.debug("user LM reloaded path=%s", path)
        except ValueError:
            self._user_lm = None
            self._user_lm_mtime = None
            self._user_lm_size = None
            logger.warning("user LM artifact invalid; cleared path=%s", path)

    def _apply_user_evidence(
        self, ranking: list[str], request: dict[str, Any]
    ) -> list[str]:
        """Reranks the ranker's top window with the L2 user LM.

        Cold-start safe: without user evidence the ranking is returned
        unchanged."""
        user_lm = self._user_lm
        if user_lm is None or len(ranking) < 2:
            return ranking
        domain = request.get("domain")
        if not isinstance(domain, str):
            domain = None
        try:
            reranked, confidence = user_lm.rerank(
                request["context"], ranking, domain=domain
            )
        except (TypeError, ValueError, ArithmeticError):
            return ranking
        if confidence <= 0 or not reranked:
            return ranking
        logger.debug("user LM rerank applied domain=%s", domain)
        return reranked

    def _fused_scorer(self, request: dict[str, Any]) -> FusedCharLM | None:
        """Per-request fused scorer, or None to keep the static default.

        Construction is O(1) (reference wrapping); a failure to build the
        fused scorer must never take the sentence path down."""
        user_lm = self._user_lm
        if user_lm is None:
            return None
        domain = request.get("domain")
        if not isinstance(domain, str):
            domain = None
        try:
            return FusedCharLM(self._static_scorer, user_lm, domain)
        except Exception:
            return None

    def _decode_sentence(
        self,
        request: dict[str, Any],
        candidates: list[str],
        scorer: CharLMScorer | None,
    ) -> Any:
        """One sentence-decode pass; `scorer` None uses the static default."""
        segments = request.get("segments")
        decoder = self._sentence_decoder
        if segments and len(segments) > 1:
            kwargs: dict[str, Any] = {
                "context": request["context"],
                "segments": [
                    SegmentDecodeInput(
                        pinyin=segment["pinyin"],
                        separator=segment["separator"],
                        committed_text=segment.get("committed_text")
                        or "",
                    )
                    for segment in segments
                ],
                "active_candidates": candidates,
            }
            decode = decoder.suggest_segments
        else:
            kwargs = {
                "context": request["context"],
                "pinyin": request["pinyin"],
                "candidates": candidates,
            }
            decode = decoder.suggest
        if scorer is not None:
            kwargs["scorer"] = scorer
        return decode(**kwargs)

    def infer(self, request: dict[str, Any]) -> dict[str, Any]:
        # Cheap stat per request: consolidation rewrites the artifact in
        # another process; pick it up without a daemon restart.
        self._refresh_user_lm()
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
            logger.debug("ranker failed; using fallback n-gram ranker", exc_info=True)
            ranking, rank_confidence = self._fallback_ranker.rank(
                context=request["context"],
                candidates=candidates,
            )
        ranking = self._apply_user_evidence(list(ranking), request)
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
            try:
                suggestion = self._decode_sentence(
                    request,
                    candidates,
                    self._fused_scorer(request),
                )
            except Exception:
                # Fail-closed: retry once with the default static scorer.
                logger.warning(
                    "fused sentence decode failed; retrying with static scorer",
                    exc_info=True,
                )
                suggestion = self._decode_sentence(request, candidates, None)
            suggestion_text = suggestion.text
            if (
                self._t2s_converter is not None
                and request.get("character_set") == "simplified"
            ):
                # Output-time script conversion: the beam scores in the
                # traditional space; only the surfaced text adapts to
                # the user's RimeAICharacterSet so the client script
                # gate stops discarding accepted suggestions.
                suggestion_text = self._t2s_converter.convert(
                    suggestion_text
                )
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
                logger.debug("sentence decode rejected: too_long")
            elif getattr(suggestion, "reason", "") == "incomplete_candidate":
                if decision != "ranked_candidate":
                    decision = "sentence_incomplete"
                    ranked_candidate = ""
                    decision_confidence = 0.0
                    logger.debug("sentence decode rejected: incomplete_candidate")
        return {
            "decision": decision,
            "ranked_candidate": ranked_candidate,
            "sentence_suggestion": sentence_suggestion,
            "confidence": decision_confidence,
        }
