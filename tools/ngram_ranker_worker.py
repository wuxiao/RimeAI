#!/usr/bin/env python3

"""Offline persistent worker for the frozen character n-gram ranker."""

import hashlib
import json
import math
import os
from pathlib import Path
import sys
from typing import Any, Dict, List, Tuple

PROJECT_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT_ROOT))

from rimeai_eval.ngram_ranker import NGramModelError, load_ngram_model


def fail(message: str) -> None:
    print(f"ngram-ranker: {message}", file=sys.stderr, flush=True)
    raise SystemExit(2)


def validate_request(request: Any) -> Tuple[str, str, List[Dict[str, str]]]:
    if not isinstance(request, dict):
        fail("request must be an object")
    if request.get("schema_version") != 1 or request.get("task") != "rerank":
        fail("unsupported request protocol")
    request_id = request.get("request_id")
    context = request.get("context")
    pinyin = request.get("pinyin")
    candidates = request.get("candidates")
    if (
        not isinstance(request_id, str)
        or not request_id
        or not isinstance(context, str)
        or len(context) > 400
        or not isinstance(pinyin, str)
        or not pinyin
        or len(pinyin) > 256
        or not isinstance(candidates, list)
        or not 1 <= len(candidates) <= 20
    ):
        fail("request fields failed validation")
    normalized: List[Dict[str, str]] = []
    seen_ids = set()
    seen_text = set()
    for candidate in candidates:
        if not isinstance(candidate, dict):
            fail("candidate must be an object")
        candidate_id = candidate.get("id")
        text = candidate.get("text")
        if (
            not isinstance(candidate_id, str)
            or not candidate_id
            or candidate_id in seen_ids
            or not isinstance(text, str)
            or not text
            or text in seen_text
            or len(text) > 128
        ):
            fail("candidate fields failed validation")
        seen_ids.add(candidate_id)
        seen_text.add(text)
        normalized.append({"id": candidate_id, "text": text})
    return request_id, context, normalized


def main() -> int:
    model_path_value = os.environ.get("RIMEAI_NGRAM_MODEL")
    if not model_path_value:
        fail("RIMEAI_NGRAM_MODEL is required")
    model_path = Path(model_path_value).resolve()
    try:
        model = load_ngram_model(model_path)
        artifact_sha256 = hashlib.sha256(model_path.read_bytes()).hexdigest()
    except (NGramModelError, OSError) as error:
        fail(str(error))
    artifact_id = (
        f"char-ngram-ranker:sha256-{artifact_sha256[:16]}:"
        f"dataset-{model.dataset_sha256[:16]}"
    )

    for line in sys.stdin:
        try:
            request = json.loads(line)
        except json.JSONDecodeError:
            fail("request is not valid JSON")
        request_id, context, candidates = validate_request(request)
        texts = [candidate["text"] for candidate in candidates]
        ranking, confidence = model.rank(
            context=context,
            candidates=texts,
        )
        if not math.isfinite(confidence):
            fail("model returned a non-finite confidence")
        ids_by_text = {
            candidate["text"]: candidate["id"] for candidate in candidates
        }
        response = {
            "schema_version": 1,
            "request_id": request_id,
            "ranking": [ids_by_text[text] for text in ranking],
            "confidence": confidence,
            "model_artifact_id": artifact_id,
        }
        sys.stdout.write(
            json.dumps(
                response,
                ensure_ascii=False,
                separators=(",", ":"),
                sort_keys=True,
            )
            + "\n"
        )
        sys.stdout.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
