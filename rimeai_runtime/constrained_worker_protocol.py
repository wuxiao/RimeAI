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
fuzzy gate. `confidence` is the geometric mean of the chosen tokens'
probabilities RENORMALIZED WITHIN THE PINYIN MASK (each step scores
the chosen token as p / Z where Z is the RAW softmax mass over that
step's allowed candidates): values live in [0, 1], are comparable
across sentence lengths, and are the basis for min_confidence gates.
The legacy RAW softmax geometric mean (length-decaying, judged weakly
informative by docs/baselines/constrained-qwen-v3-mlx.json) is
preserved for evaluation comparison inside `stats.confidence_raw`
when the request asks for stats; the wire field name `confidence` and
its [0,1] bound are unchanged from schema 1. Because that caliber
switch left the field name and schema_version untouched, every worker
self-declares its caliber via the OPTIONAL response field
`confidence_caliber` (the constants below): an absent marker means a
pre-switch (RAW caliber) or foreign product — never mix `confidence`
values across calibers. `stats` is otherwise optional engine telemetry
(prefill/cache counters, beam knobs) requested by evaluation tooling;
the daemon's deployment service deliberately does not request it and
drops it from the payload (reveal B-F6: dead telemetry).
"""
from __future__ import annotations

from collections.abc import Mapping
from typing import Any

MAX_CONTEXT_CHARS = 400
MAX_PINYIN_CHARS = 256
MAX_CANDIDATES = 20
MAX_CANDIDATE_CHARS = 128
MAX_CHARACTERS = 30

# reveal C-F1/C-F2/C-F3：`confidence` 口径自声明标记。掩码内归一化
# 口径（constrained 路线现行）与 RAW softmax 几何平均口径（prompt
# 路线、及口径切换前的旧产物）同名同域不同义，靠该字段区分。
CONFIDENCE_CALIBER_MASK_RENORM = "mask-renormalized-geometric-mean"
CONFIDENCE_CALIBER_RAW_SOFTMAX = "raw-softmax-geometric-mean"


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
    confidence_caliber: str | None = None,
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
    if confidence_caliber is not None:
        response["confidence_caliber"] = confidence_caliber
    return response
