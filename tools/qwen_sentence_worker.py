#!/usr/bin/env python3

"""Pinned offline Qwen sentence decoder for P0 long-input experiments."""

import hashlib
import json
import math
import os
from pathlib import Path
import re
import sys
from typing import Any, Dict, List, Tuple

import torch
from transformers import AutoModelForCausalLM, AutoTokenizer

PROJECT_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT_ROOT))

from rimeai_eval.pinyin_guard import PinyinGuard


MODEL_REVISION = "7ae557604adf67be50417f59c2c2f167def9a775"
MODEL_SHA256 = "fdf756fa7fcbe7404d5c60e26bff1a0c8b8aa1f72ced49e7dd0210fe288fb7fe"
EXPECTED_TORCH = "2.8.0"
EXPECTED_TRANSFORMERS = "4.39.3"
PROMPT_VERSION = "syllable-decoder-v3"
HAN_ONLY = re.compile(r"^[\u3400-\u9fff]{1,30}$")


def fail(message: str) -> None:
    print(f"qwen-sentence: {message}", file=sys.stderr, flush=True)
    raise SystemExit(2)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        while chunk := file.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def load_runtime() -> Tuple[Any, Any, torch.device, str]:
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
        f"qwen2.5-0.5b-instruct@{MODEL_REVISION[:8]}:"
        f"sha256-{MODEL_SHA256[:12]}:{device_name}:"
        f"{'fp16' if dtype == torch.float16 else 'fp32'}:{PROMPT_VERSION}"
    )
    return tokenizer, model, device, artifact_id


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


def clean_suggestion(
    text: str,
    max_characters: int,
    expected_characters: int,
) -> str:
    text = text.strip().splitlines()[0] if text.strip() else ""
    for prefix in ("输出：", "答案：", "候选：", "输出:", "答案:", "候选:"):
        if text.startswith(prefix):
            text = text[len(prefix) :].strip()
    text = text.strip("`'\"“”‘’")
    if (
        len(text) > max_characters
        or len(text) != expected_characters
        or not HAN_ONLY.fullmatch(text)
    ):
        return ""
    return text


def generate(
    tokenizer: Any,
    model: Any,
    device: torch.device,
    *,
    context: str,
    pinyin: str,
    candidates: List[str],
    max_characters: int,
    syllables: List[str],
) -> Tuple[str, float]:
    messages = [
        {
            "role": "system",
            "content": (
                "把无声调拼音转换为符合前文的简体中文。"
                "每个空格分隔的音节对应一个汉字。"
                "只输出转换结果，不要解释、引号、标点或换行。"
            ),
        },
        {
            "role": "user",
            "content": (
                f"前文：{context}\n"
                f"拼音：{' '.join(syllables)}\n"
                f"请只输出{len(syllables)}个汉字："
            ),
        },
    ]
    input_ids = tokenizer.apply_chat_template(
        messages,
        add_generation_prompt=True,
        return_tensors="pt",
    ).to(device)
    attention_mask = torch.ones_like(input_ids, device=device)
    with torch.inference_mode():
        output = model.generate(
            input_ids=input_ids,
            attention_mask=attention_mask,
            do_sample=False,
            temperature=None,
            top_p=None,
            top_k=None,
            max_new_tokens=min(36, len(syllables) * 2 + 4),
            return_dict_in_generate=True,
            output_scores=True,
            use_cache=True,
            pad_token_id=tokenizer.eos_token_id,
            eos_token_id=tokenizer.eos_token_id,
        )
    generated_ids = output.sequences[0, input_ids.shape[-1] :]
    decoded = tokenizer.decode(generated_ids, skip_special_tokens=True)
    if os.environ.get("RIMEAI_QWEN_DEBUG") == "1":
        print(
            "qwen-sentence-debug: " + repr(decoded),
            file=sys.stderr,
            flush=True,
        )
    suggestion = clean_suggestion(
        decoded,
        max_characters,
        len(syllables),
    )
    token_probabilities: List[float] = []
    for index, logits in enumerate(output.scores):
        token_id = int(generated_ids[index].item())
        log_probability = torch.log_softmax(
            logits[0].float(), dim=-1
        )[token_id]
        token_probabilities.append(float(log_probability.exp().item()))
    if suggestion and token_probabilities:
        confidence = math.exp(
            sum(math.log(max(probability, 1e-12)) for probability in token_probabilities)
            / len(token_probabilities)
        )
    else:
        confidence = 0.0
    return suggestion, max(0.0, min(1.0, confidence))


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
    tokenizer, model, device, artifact_id = load_runtime()
    dictionary_path = Path(os.environ["RIMEAI_RIME_DICTIONARY"]).resolve()
    try:
        guard = PinyinGuard.from_rime_dictionary(dictionary_path)
    except (OSError, ValueError) as error:
        fail(str(error))
    for line in sys.stdin:
        try:
            request = json.loads(line)
        except json.JSONDecodeError:
            fail("request is not valid JSON")
        request_id, context, pinyin, candidates, max_characters = (
            validate_request(request)
        )
        syllables = guard.segment(candidates[0], pinyin)
        if syllables is None:
            syllables = [pinyin]
        suggestion, confidence = generate(
            tokenizer,
            model,
            device,
            context=context,
            pinyin=pinyin,
            candidates=candidates,
            max_characters=max_characters,
            syllables=syllables,
        )
        write_response(
            {
                "schema_version": 1,
                "request_id": request_id,
                "suggestion": suggestion,
                "confidence": confidence,
                "model_artifact_id": artifact_id,
            }
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
