#!/usr/bin/env python3

import json
import math
import os
from pathlib import Path
import sys
from typing import Any, Dict, List, Tuple

import torch
from transformers import AutoTokenizer

PROJECT_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT_ROOT))

from rimeai_eval.candidate_policy import (
    build_semantic_pairs,
    partition_full_length_candidates,
)


MODEL_REVISION = "8215cf04918ba6f7b6a62bb44238ce2953d8831c"
MODEL_SHA256 = "10ebaa49322dd7e01a13a91c49810939e3f91f231aceaa47fdf0cab3083954f6"
EXPECTED_TORCH = "2.8.0"
EXPECTED_TRANSFORMERS = "4.39.3"
MAX_LENGTH = 256


def fail(message: str) -> "NoReturn":
    print(f"gte-ranker: {message}", file=sys.stderr, flush=True)
    raise SystemExit(2)


def load_runtime() -> Tuple[Any, Any, torch.device, torch.dtype, str]:
    import transformers

    if torch.__version__.split("+", 1)[0] != EXPECTED_TORCH:
        fail(f"expected torch {EXPECTED_TORCH}, found {torch.__version__}")
    if transformers.__version__ != EXPECTED_TRANSFORMERS:
        fail(
            f"expected transformers {EXPECTED_TRANSFORMERS}, "
            f"found {transformers.__version__}"
        )
    model_dir = Path(os.environ["RIMEAI_GTE_MODEL_DIR"]).resolve()
    code_dir = Path(os.environ["RIMEAI_GTE_CODE_DIR"]).resolve()
    if not (model_dir / "model.safetensors").is_file():
        fail("model files are missing")
    if not (code_dir / "modeling.py").is_file():
        fail("pinned model implementation is missing")
    sys.path.insert(0, str(code_dir.parent))
    package_name = code_dir.name
    configuration_module = __import__(
        f"{package_name}.configuration", fromlist=["NewConfig"]
    )
    modeling_module = __import__(
        f"{package_name}.modeling",
        fromlist=["NewForSequenceClassification"],
    )
    device_name = os.environ.get("RIMEAI_GTE_DEVICE", "mps")
    if device_name == "mps":
        if not torch.backends.mps.is_available():
            fail("MPS is not available")
        device = torch.device("mps")
        dtype = torch.float16
    elif device_name == "cpu":
        device = torch.device("cpu")
        dtype = torch.float32
    else:
        fail("RIMEAI_GTE_DEVICE must be mps or cpu")
    config = configuration_module.NewConfig.from_pretrained(
        model_dir,
        local_files_only=True,
    )
    model = modeling_module.NewForSequenceClassification.from_pretrained(
        model_dir,
        config=config,
        local_files_only=True,
        torch_dtype=dtype,
    )
    model.eval()
    model.to(device)
    tokenizer = AutoTokenizer.from_pretrained(
        model_dir,
        local_files_only=True,
    )
    artifact_id = (
        f"gte-multilingual-reranker-base@{MODEL_REVISION[:8]}"
        f":sha256-{MODEL_SHA256[:12]}:{device_name}:"
        f"{'fp16' if dtype == torch.float16 else 'fp32'}"
    )
    return tokenizer, model, device, dtype, artifact_id


def validate_request(request: Any) -> Tuple[str, str, str, List[Dict[str, str]]]:
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
    normalized_candidates: List[Dict[str, str]] = []
    seen_ids = set()
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
            or len(text) > 128
        ):
            fail("candidate fields failed validation")
        seen_ids.add(candidate_id)
        normalized_candidates.append({"id": candidate_id, "text": text})
    return request_id, context, pinyin, normalized_candidates


def score_candidates(
    tokenizer: Any,
    model: Any,
    device: torch.device,
    context: str,
    candidates: List[Dict[str, str]],
    strategy: str,
) -> Tuple[List[str], float]:
    eligible, preserved = partition_full_length_candidates(candidates)
    pairs = build_semantic_pairs(
        context=context,
        candidates=eligible,
        strategy=strategy,
    )
    inputs = tokenizer(
        pairs,
        padding=True,
        truncation=True,
        max_length=MAX_LENGTH,
        return_tensors="pt",
    )
    inputs = {key: value.to(device) for key, value in inputs.items()}
    with torch.inference_mode():
        logits = model(**inputs).logits.float().reshape(-1)
    probabilities = torch.softmax(logits, dim=0)
    ranked_indices = sorted(
        range(len(eligible)),
        key=lambda index: (-float(logits[index].item()), index),
    )
    confidence = float(probabilities[ranked_indices[0]].item())
    if not math.isfinite(confidence):
        fail("model returned a non-finite confidence")
    return (
        [eligible[index]["id"] for index in ranked_indices]
        + [candidate["id"] for candidate in preserved],
        confidence,
    )


def write_response(response: Dict[str, Any]) -> None:
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


def main() -> int:
    tokenizer, model, device, _, artifact_id = load_runtime()
    strategy = os.environ.get("RIMEAI_GTE_STRATEGY", "context-candidate")
    if strategy not in {"context-candidate", "context-completion"}:
        fail("RIMEAI_GTE_STRATEGY is not supported")
    artifact_id = f"{artifact_id}:{strategy}:same-length"
    score_candidates(
        tokenizer,
        model,
        device,
        "这是一次",
        [{"id": "c0", "text": "测试"}, {"id": "c1", "text": "侧视"}],
        strategy,
    )
    for line in sys.stdin:
        try:
            request = json.loads(line)
        except json.JSONDecodeError:
            fail("request is not valid JSON")
        request_id, context, pinyin, candidates = validate_request(request)
        ranking, confidence = score_candidates(
            tokenizer,
            model,
            device,
            context,
            candidates,
            strategy,
        )
        write_response(
            {
                "schema_version": 1,
                "request_id": request_id,
                "ranking": ranking,
                "confidence": confidence,
                "model_artifact_id": artifact_id,
            }
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
