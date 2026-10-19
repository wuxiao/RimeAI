"""Shared JSONL worker protocol for pinyin-constrained sentence decoding.

Extracted from the frozen torch worker (tools/constrained_qwen_worker.py,
constrained-v2) so the MLX deployment worker (rimeai_runtime/mlx_worker.py)
locks byte-identical request bounds and response semantics. The torch
worker itself is frozen evaluation evidence and stays untouched.

Protocol (schema_version 1, one JSON object per line):

  request : {schema_version, task="generate_sentence", request_id,
             context<=400 chars, pinyin 1..256 chars, candidates 1..20
             non-empty each <=128 chars, max_characters 1..30, stats? bool}
  response: {schema_version, request_id, suggestion<=30 chars,
             confidence [0,1], model_artifact_id, stats? {...}}

`suggestion` is "" when no constrained suggestion survives the final
fuzzy gate. `stats` is optional engine telemetry (prefill/cache counters)
consumed by the deployment service; the frozen eval parser ignores it.
"""
from __future__ import annotations

from collections.abc import Mapping
from typing import Any

MAX_CONTEXT_CHARS = 400
MAX_PINYIN_CHARS = 256
MAX_CANDIDATES = 20
MAX_CANDIDATE_CHARS = 128
MAX_CHARACTERS = 30


class GenerateRequestError(ValueError):
    """Request failed protocol validation; the worker exits(2)."""


def validate_generate_request(request: Any) -> tuple[
    str, str, str, list, int, bool
]:
    """Returns (request_id, context, pinyin, candidates, max_characters,
    stats) or raises GenerateRequestError with the same bounds as the
    frozen torch worker."""
    if not isinstance(request, dict):
        raise GenerateRequestError("request must be an object")
    if (
        request.get("schema_version") != 1
        or request.get("task") != "generate_sentence"
    ):
        raise GenerateRequestError("unsupported request protocol")
    request_id = request.get("request_id")
    context = request.get("context")
    pinyin = request.get("pinyin")
    candidates = request.get("candidates")
    max_characters = request.get("max_characters")
    stats = request.get("stats", False)
    if (
        not isinstance(request_id, str)
        or not request_id
        or not isinstance(context, str)
        or len(context) > MAX_CONTEXT_CHARS
        or not isinstance(pinyin, str)
        or not pinyin
        or len(pinyin) > MAX_PINYIN_CHARS
        or not isinstance(candidates, list)
        or not 1 <= len(candidates) <= MAX_CANDIDATES
        or any(
            not isinstance(candidate, str)
            or not candidate
            or len(candidate) > MAX_CANDIDATE_CHARS
            for candidate in candidates
        )
        or not isinstance(max_characters, int)
        or isinstance(max_characters, bool)
        or not 1 <= max_characters <= MAX_CHARACTERS
        or not isinstance(stats, bool)
    ):
        raise GenerateRequestError("request fields failed validation")
    return (
        request_id,
        context,
        pinyin,
        candidates,
        max_characters,
        stats,
    )


def generate_response(
    *,
    request_id: str,
    suggestion: str,
    confidence: float,
    model_artifact_id: str,
    stats: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    response: dict[str, Any] = {
        "schema_version": 1,
        "request_id": request_id,
        "suggestion": suggestion,
        "confidence": confidence,
        "model_artifact_id": model_artifact_id,
    }
    if stats is not None:
        response["stats"] = dict(stats)
    return response
