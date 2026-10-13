#!/usr/bin/env python3

"""Pinned offline Qwen sentence decoder using pinyin-constrained
decoding: no prompt, no chat template — the model scores next tokens
and the pinyin mask decides what is legal."""

import hashlib
import json
import os
from pathlib import Path
import sys
from time import monotonic
from typing import Any, Dict, List, Mapping, Sequence, Tuple

import torch
from transformers import AutoModelForCausalLM, AutoTokenizer

PROJECT_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT_ROOT))

from rimeai_runtime.constrained_decoder import (
    ConstrainedGreedyDecoder,
    DecodeResult,
    PinyinTokenIndex,
    fuzzy_segment_ok,
)
from rimeai_runtime.pinyin_guard import PinyinGuard


MODEL_NAME = "qwen2.5-0.5b"
MODEL_REVISION = "060db6499f32faf8b98477b0a26969ef7d8b9987"
MODEL_SHA256 = "88c142557820ccad55bb59756bfcfcf891de9cc6202816bd346445188a0ed342"
EXPECTED_TORCH = "2.8.0"
EXPECTED_TRANSFORMERS = "4.39.3"
PROMPT_VERSION = "constrained-v2"
# The base (non-instruct) variant is required: the instruct model's raw
# next-token distribution ranks homophones by RLHF noise, not by natural
# Chinese (measured 2026-10-13: P(今天|。) ranked 5th behind 仅/紧/金/锦
# on instruct, while base decodes 今天天气很好 at 100x the confidence).
# A bare EOS seed is likewise unfit; this invariant one-token prefix puts
# the model at a sentence boundary. It is a context stabilizer, not an
# instruction — no chat template is ever applied.
SEED_CONTEXT = "。"


def fail(message: str) -> None:
    print(f"constrained-qwen: {message}", file=sys.stderr, flush=True)
    raise SystemExit(2)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        while chunk := file.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def validate_request(
    request: Any,
) -> Tuple[str, str, str, List[str], int]:
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


class WorkerRuntime:
    def __init__(self, tokenizer: Any, model: Any, device: Any, artifact_id: str):
        self.tokenizer = tokenizer
        self.model = model
        self.device = device
        self.artifact_id = artifact_id


def load_runtime() -> WorkerRuntime:
    import transformers

    if torch.__version__.split("+", 1)[0] != EXPECTED_TORCH:
        fail(f"expected torch {EXPECTED_TORCH}, found {torch.__version__}")
    if transformers.__version__ != EXPECTED_TRANSFORMERS:
        fail(
            f"expected transformers {EXPECTED_TRANSFORMERS}, "
            f"found {transformers.__version__}"
        )
    model_dir = Path(os.environ["RIMEAI_QWEN_MODEL_DIR"]).resolve()
    weights = model_dir / "model.safetensors"
    if not weights.is_file():
        fail("model files are missing")
    actual_sha256 = sha256_file(weights)
    if actual_sha256 != MODEL_SHA256:
        fail("model weights do not match the pinned SHA-256")
    device_name = os.environ.get("RIMEAI_QWEN_DEVICE", "mps")
    if device_name == "mps":
        if not torch.backends.mps.is_available():
            fail("MPS is not available")
        device = torch.device("mps")
        dtype = torch.float16
    elif device_name == "cpu":
        device = torch.device("cpu")
        dtype = torch.float32
    else:
        fail("RIMEAI_QWEN_DEVICE must be mps or cpu")
    tokenizer = AutoTokenizer.from_pretrained(
        model_dir,
        local_files_only=True,
    )
    model = AutoModelForCausalLM.from_pretrained(
        model_dir,
        local_files_only=True,
        torch_dtype=dtype,
    )
    model.eval()
    model.to(device)
    artifact_id = (
        f"{MODEL_NAME}@{MODEL_REVISION[:8]}:"
        f"sha256-{MODEL_SHA256[:12]}:{device_name}:"
        f"{'fp16' if dtype == torch.float16 else 'fp32'}:{PROMPT_VERSION}"
    )
    return WorkerRuntime(tokenizer, model, device, artifact_id)


class _ProbabilityView:
    """Probability lookup backing the scorer protocol: the decoder only
    probes a handful of token ids per step, so the full vocab is never
    materialized as a dict."""

    def __init__(self, probabilities: Any) -> None:
        self._probabilities = probabilities

    def get(self, token_id: int, default: float = 0.0) -> float:
        index = int(token_id)
        if 0 <= index < self._probabilities.shape[-1]:
            return float(self._probabilities[index])
        return default


def make_scorer(
    runtime: WorkerRuntime, context_ids: Sequence[int]
) -> Any:
    model = runtime.model
    device = runtime.device
    seed = list(context_ids)
    with torch.inference_mode():
        output = model(
            input_ids=torch.tensor(
                [seed], dtype=torch.long, device=device
            ),
            use_cache=True,
        )
    # Beam paths diverge by construction: the cached history is only
    # valid while the requested path extends it, otherwise the whole
    # seed+path is re-prefilled so every path is scored against its own
    # history (bounded: <= 30 tokens x beam_width per step).
    state = {
        "fed": [],
        "past": output.past_key_values,
        "logits": output.logits[0, -1],
    }

    def scorer(step_token_ids: Sequence[int]) -> Mapping[int, float]:
        ids = [int(token_id) for token_id in step_token_ids]
        with torch.inference_mode():
            if ids[: len(state["fed"])] == state["fed"]:
                new_tokens = ids[len(state["fed"]):]
                if new_tokens:
                    output = model(
                        input_ids=torch.tensor(
                            [new_tokens], dtype=torch.long, device=device
                        ),
                        past_key_values=state["past"],
                        use_cache=True,
                    )
                    state["past"] = output.past_key_values
                    state["logits"] = output.logits[0, -1]
                    state["fed"] = ids
            else:
                output = model(
                    input_ids=torch.tensor(
                        [seed + ids], dtype=torch.long, device=device
                    ),
                    use_cache=True,
                )
                state["past"] = output.past_key_values
                state["logits"] = output.logits[0, -1]
                state["fed"] = ids
        return _ProbabilityView(
            torch.softmax(state["logits"].float(), dim=-1)
        )

    return scorer


def handle_request(
    runtime: WorkerRuntime,
    guard: PinyinGuard,
    index: PinyinTokenIndex,
    request: Any,
) -> Dict[str, Any]:
    request_id, context, pinyin, candidates, max_characters = (
        validate_request(request)
    )
    syllables = guard.segment(candidates[0], pinyin)
    if syllables is None:
        syllables = [pinyin]
    seed_ids = runtime.tokenizer.encode(SEED_CONTEXT)
    if context:
        seed_ids = seed_ids + runtime.tokenizer.encode(context)
    scorer = make_scorer(runtime, seed_ids)
    result = ConstrainedGreedyDecoder.decode(
        scorer,
        syllables,
        index,
        max_characters=max_characters,
        fuzzy=True,
        beam_width=4,
    )
    if result.text and not fuzzy_segment_ok(guard, result.text, syllables):
        result = DecodeResult("", 0.0, result.consumed_syllables)
    return {
        "schema_version": 1,
        "request_id": request_id,
        "suggestion": result.text,
        "confidence": result.confidence,
        "model_artifact_id": runtime.artifact_id,
    }


def main() -> int:
    runtime = load_runtime()
    dictionary_path = Path(os.environ["RIMEAI_RIME_DICTIONARY"]).resolve()
    try:
        guard = PinyinGuard.from_rime_dictionary(dictionary_path)
    except (OSError, ValueError) as error:
        fail(str(error))
    started = monotonic()
    index = PinyinTokenIndex.build(runtime.tokenizer, guard)
    vocab_size = runtime.tokenizer.vocab_size
    print(
        f"constrained-qwen: pinyin token index built in "
        f"{monotonic() - started:.1f}s "
        f"({len(index.token_syllables)}/{vocab_size} tokens indexed, "
        f"{100.0 * len(index.token_syllables) / vocab_size:.1f}% of vocab)",
        file=sys.stderr,
        flush=True,
    )
    for line in sys.stdin:
        try:
            request = json.loads(line)
        except json.JSONDecodeError:
            fail("request is not valid JSON")
        write_response(handle_request(runtime, guard, index, request))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
