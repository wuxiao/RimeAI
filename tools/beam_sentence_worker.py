#!/usr/bin/env python3

"""Persistent worker for the pinyin-constrained beam sentence decoder."""

import hashlib
import json
import math
import os
from pathlib import Path
import sys
from typing import Any, List, NoReturn, Tuple

PROJECT_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT_ROOT))

from rimeai_runtime.beam_decoder import (
    BeamDecoderError,
    BeamSentenceDecoder,
    load_beam_config,
)
from rimeai_runtime.ngram_ranker import NGramModelError, load_ngram_model
from rimeai_runtime.pinyin_guard import PinyinGuard


def fail(message: str) -> NoReturn:
    print(f"beam-sentence: {message}", file=sys.stderr, flush=True)
    raise SystemExit(2)


def sha256_path(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        while True:
            chunk = file.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def validate_request(request: Any) -> Tuple[str, str, str, List[str], int]:
    if not isinstance(request, dict):
        fail("request must be an object")
    if (
        request.get("schema_version") != 1
        or request.get("task") != "generate_sentence"
    ):
        fail("unsupported request protocol")
    request_id = request.get("request_id")
    context = request.get("context")
    pinyin = request.get("pinyin")
    candidates = request.get("candidates")
    max_characters = request.get("max_characters")
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
        or any(
            not isinstance(candidate, str)
            or not candidate
            or len(candidate) > 128
            for candidate in candidates
        )
        or not isinstance(max_characters, int)
        or isinstance(max_characters, bool)
        or not 1 <= max_characters <= 30
    ):
        fail("request fields failed validation")
    return request_id, context, pinyin, candidates, max_characters


def main() -> int:
    config_path = Path(os.environ["RIMEAI_BEAM_DECODER_CONFIG"]).resolve()
    model_path = Path(os.environ["RIMEAI_NGRAM_MODEL"]).resolve()
    dictionary_path = Path(os.environ["RIMEAI_RIME_DICTIONARY"]).resolve()
    try:
        config = load_beam_config(config_path)
        model_sha256 = sha256_path(model_path)
        dictionary_sha256 = sha256_path(dictionary_path)
        if model_sha256 != config.language_model_sha256:
            fail("language model SHA-256 does not match decoder artifact")
        if dictionary_sha256 != config.dictionary_sha256:
            fail("Rime dictionary SHA-256 does not match decoder artifact")
        model = load_ngram_model(model_path)
        guard = PinyinGuard.from_rime_dictionary(dictionary_path)
    except (BeamDecoderError, NGramModelError, OSError, ValueError) as error:
        fail(str(error))
    decoder = BeamSentenceDecoder(model, guard, config)
    config_sha256 = sha256_path(config_path)
    artifact_id = (
        f"pinyin-beam-ngram:sha256-{config_sha256[:16]}:"
        f"lm-{model_sha256[:12]}:dict-{dictionary_sha256[:12]}"
    )

    for line in sys.stdin:
        try:
            request = json.loads(line)
        except json.JSONDecodeError:
            fail("request is not valid JSON")
        request_id, context, pinyin, candidates, max_characters = (
            validate_request(request)
        )
        suggestion = decoder.suggest(
            context=context,
            pinyin=pinyin,
            candidates=candidates,
        )
        text = suggestion.text
        if len(text) > max_characters:
            text = ""
        confidence = suggestion.confidence if text else 0.0
        if not math.isfinite(confidence):
            fail("decoder returned a non-finite confidence")
        response = {
            "schema_version": 1,
            "request_id": request_id,
            "suggestion": text,
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
