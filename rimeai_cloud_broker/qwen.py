"""Strict OpenAI-compatible Qwen client for candidate choice or generation."""

from __future__ import annotations

import json
import math
from threading import Lock
from time import monotonic
from typing import TYPE_CHECKING, Any, Callable, Dict, List, Optional, Sequence
from urllib import error, request

if TYPE_CHECKING:  # pragma: no cover - typing only, runtime injection
    from rimeai_eval.pinyin_guard import PinyinGuard


ENDPOINT = "https://newapi.wwcn.fun/v1"
PROVIDER = "wwcn New API Gateway"
ALLOWED_MODELS = {
    "glm-5.3-flash",
    "glm-5.3",
}
GENERATE_MINIMUM_CONFIDENCE = 0.60


class QwenBrokerError(RuntimeError):
    pass


class _RejectRedirects(request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise QwenBrokerError("Qwen endpoint redirect was refused")


class QwenCandidateRanker:
    def __init__(
        self,
        *,
        api_key_loader: Optional[Callable[[], str]] = None,
        endpoint: str = ENDPOINT,
        pinyin_guard: Optional["PinyinGuard"] = None,
    ) -> None:
        if endpoint.rstrip("/") != ENDPOINT:
            raise ValueError("the Qwen endpoint is fixed by the product contract")
        self._api_key_loader = api_key_loader
        self._api_key: Optional[str] = None
        self._api_key_lock = Lock()
        self._endpoint = ENDPOINT
        self._pinyin_guard = pinyin_guard

    @property
    def generation_enabled(self) -> bool:
        return self._pinyin_guard is not None

    def rank(self, cloud_request: Dict[str, Any]) -> Dict[str, Any]:
        started = monotonic()
        model_id = cloud_request["model_id"]
        if model_id not in ALLOWED_MODELS:
            raise QwenBrokerError("model is not in the frozen allowlist")
        candidates = cloud_request["candidates"]
        candidate_by_id = {
            candidate["id"]: candidate for candidate in candidates
        }
        prompt = {
            "task": (
                "Decide what the user is typing in pinyin. Either pick the "
                "single best existing candidate, or compose the intended "
                "Chinese sentence yourself. Composing is preferred: whenever "
                "any plausible Chinese reading of the pinyin exists, choose "
                "generate instead of abstaining. A composed sentence must be "
                "Han-only, at most 30 characters, contain no punctuation or "
                "spaces, and read exactly as the typed pinyin character by "
                "character (full syllables or first-letter abbreviation). "
                "When the typed pinyin looks misspelled but you can read a "
                "plausible intended sentence through it, still generate: the "
                "user is asking for intelligent pinyin correction, not "
                "strict literal transcription. Only abstain when no defensible "
                "reading exists."
            ),
            "pinyin": cloud_request["pinyin"],
            "recent_context": cloud_request["recent_context"],
            "history_snippets": cloud_request["history_snippets"],
            "candidates": candidates,
            "output_contract": {
                "decision": "choose | keep | abstain | generate",
                "candidate_id": "existing ID for choose, otherwise null",
                "text": (
                    "composed Han-only sentence for generate, otherwise null"
                ),
                "confidence": "0..1 for choose/generate, otherwise null",
                "reason": (
                    "context_match | history_match | typo_match | "
                    "rime_rank | uncertain"
                ),
            },
        }
        payload = {
            "model": model_id,
            "messages": [
                {
                    "role": "system",
                    "content": (
                        "You are a constrained Chinese IME assistant. "
                        "Output one JSON object only. Composed text may "
                        "only appear inside the text field of a generate "
                        "decision."
                    ),
                },
                {
                    "role": "user",
                    "content": json.dumps(
                        prompt,
                        ensure_ascii=False,
                        separators=(",", ":"),
                    ),
                },
            ],
            "temperature": 0,
            "max_tokens": 256,
            "thinking": {"type": "disabled"},
            "response_format": {"type": "json_object"},
        }
        api_key = self._resolve_api_key(cloud_request)
        remaining = (
            cloud_request["deadline_ms"] / 1000
            - (monotonic() - started)
            - 0.025
        )
        if remaining < 0.05:
            raise QwenBrokerError("cloud deadline expired before network send")
        response = self._post_json(
            "/chat/completions",
            payload,
            timeout=remaining,
            api_key=api_key,
        )
        try:
            content = response["choices"][0]["message"]["content"]
            decision = json.loads(content)
        except (KeyError, IndexError, TypeError, json.JSONDecodeError) as exc:
            raise QwenBrokerError("Qwen returned invalid structured output") from exc
        return self._validate_decision(
            decision,
            candidate_by_id=candidate_by_id,
            pinyin=cloud_request["pinyin"],
        )

    def embed_texts(self, texts: Sequence[str]) -> List[List[float]]:
        bounded = list(texts[:32])
        if not bounded or any(
            not isinstance(value, str) or len(value.encode()) > 16_384
            for value in bounded
        ):
            raise QwenBrokerError("embedding input is invalid")
        response = self._post_json(
            "/embeddings",
            {
                "model": "text-embedding-v4",
                "input": bounded,
                "dimensions": 512,
                "encoding_format": "float",
            },
            timeout=5,
            api_key=self._current_api_key(),
        )
        try:
            ordered = sorted(response["data"], key=lambda item: item["index"])
            vectors = [item["embedding"] for item in ordered]
        except (KeyError, TypeError) as exc:
            raise QwenBrokerError("embedding response is invalid") from exc
        if len(vectors) != len(bounded) or any(
            not isinstance(vector, list)
            or len(vector) != 512
            or any(
                not isinstance(value, (int, float))
                or isinstance(value, bool)
                or not math.isfinite(value)
                for value in vector
            )
            for vector in vectors
        ):
            raise QwenBrokerError("embedding dimensions are invalid")
        return [[float(value) for value in vector] for vector in vectors]

    def _validate_decision(
        self,
        decision: Any,
        *,
        candidate_by_id: Dict[str, Dict[str, Any]],
        pinyin: str,
    ) -> Dict[str, Any]:
        if not isinstance(decision, dict):
            raise QwenBrokerError("Qwen decision is not an object")
        action = decision.get("decision")
        candidate_id = decision.get("candidate_id")
        confidence = decision.get("confidence")
        reason = decision.get("reason")
        allowed_reasons = {
            "context_match",
            "history_match",
            "typo_match",
            "rime_rank",
            "uncertain",
        }
        if reason not in allowed_reasons:
            reason = "uncertain"
        if action not in {"choose", "keep", "abstain", "generate"}:
            raise QwenBrokerError("Qwen decision is unsupported")
        if action in {"keep", "abstain"}:
            return {
                "decision": action,
                "candidate_id": None,
                "confidence": None,
                "reason": reason,
            }
        if action == "generate":
            return self._validate_generated_decision(
                decision,
                candidate_by_id=candidate_by_id,
                pinyin=pinyin,
                confidence=confidence,
                reason=reason,
            )
        if (
            not isinstance(candidate_id, str)
            or candidate_id not in candidate_by_id
            or not isinstance(confidence, (int, float))
            or isinstance(confidence, bool)
            or not math.isfinite(confidence)
            or not 0 <= confidence <= 1
        ):
            raise QwenBrokerError("Qwen selected an invalid candidate")
        candidate = candidate_by_id[candidate_id]
        minimum_confidence = (
            0.98 if candidate["source"] == "rime_fuzzy" else 0.85
        )
        if confidence < minimum_confidence:
            return {
                "decision": "abstain",
                "candidate_id": None,
                "confidence": None,
                "reason": "uncertain",
            }
        first_id = next(iter(candidate_by_id))
        if candidate_id == first_id:
            return {
                "decision": "keep",
                "candidate_id": None,
                "confidence": None,
                "reason": "rime_rank",
            }
        return {
            "decision": "choose",
            "candidate_id": candidate_id,
            "confidence": float(confidence),
            "reason": reason,
        }

    def _validate_generated_decision(
        self,
        decision: Dict[str, Any],
        *,
        candidate_by_id: Dict[str, Dict[str, Any]],
        pinyin: str,
        confidence: Any,
        reason: str,
    ) -> Dict[str, Any]:
        text = decision.get("text")
        if (
            not isinstance(text, str)
            or not text
            or decision.get("candidate_id") is not None
            or not isinstance(confidence, (int, float))
            or isinstance(confidence, bool)
            or not math.isfinite(confidence)
            or not 0 <= confidence <= 1
        ):
            raise QwenBrokerError("Qwen generated sentence is invalid")
        guard = self._pinyin_guard
        if guard is None or confidence < GENERATE_MINIMUM_CONFIDENCE:
            return {
                "decision": "abstain",
                "candidate_id": None,
                "confidence": None,
                "reason": "uncertain",
            }
        # The dictionary alignment check is the anti-hallucination gate:
        # every character must read exactly as the typed pinyin.
        if not guard.matches(text, pinyin):
            return {
                "decision": "abstain",
                "candidate_id": None,
                "confidence": None,
                "reason": "uncertain",
            }
        # Deliberately NOT collapsing generate==top-candidate into keep
        # here: the client owns dedup and surfaces "cloud agrees with the
        # top candidate" visibly. Converting at this layer would silence
        # the LLM's participation before the client can show it.
        return {
            "decision": "generate",
            "candidate_id": None,
            "confidence": float(confidence),
            "reason": reason,
            "text": text,
        }

    def _post_json(
        self,
        path: str,
        payload: Dict[str, Any],
        *,
        timeout: float,
        api_key: Optional[str] = None,
    ) -> Dict[str, Any]:
        encoded = json.dumps(
            payload,
            ensure_ascii=False,
            separators=(",", ":"),
        ).encode("utf-8")
        cloud_request = request.Request(
            self._endpoint + path,
            data=encoded,
            headers={
                "Authorization": f"Bearer {api_key or self._current_api_key()}",
                "Content-Type": "application/json",
                "User-Agent": "RimeAI-CloudBroker/1.0",
            },
            method="POST",
        )
        try:
            opener = request.build_opener(_RejectRedirects())
            with opener.open(cloud_request, timeout=timeout) as response:
                body = response.read(1_048_577)
        except (error.URLError, TimeoutError, OSError) as exc:
            raise QwenBrokerError("Qwen request failed") from exc
        if len(body) > 1_048_576:
            raise QwenBrokerError("Qwen response is too large")
        try:
            value = json.loads(body)
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise QwenBrokerError("Qwen response is not JSON") from exc
        if not isinstance(value, dict):
            raise QwenBrokerError("Qwen response is not an object")
        return value

    def _resolve_api_key(self, cloud_request: Dict[str, Any]) -> str:
        supplied = cloud_request.pop("api_key", None)
        if supplied is not None:
            if (
                not isinstance(supplied, str)
                or not supplied
                or len(supplied.encode()) > 512
            ):
                raise QwenBrokerError("cloud credential is unavailable")
            with self._api_key_lock:
                self._api_key = supplied
            return supplied
        return self._current_api_key()

    def _current_api_key(self) -> str:
        with self._api_key_lock:
            value = self._api_key
        if value is None and self._api_key_loader is not None:
            value = self._api_key_loader()
            if isinstance(value, str) and value and len(value.encode()) <= 512:
                with self._api_key_lock:
                    self._api_key = value
        if not isinstance(value, str) or not value or len(value.encode()) > 512:
            raise QwenBrokerError("cloud credential is unavailable")
        return value
