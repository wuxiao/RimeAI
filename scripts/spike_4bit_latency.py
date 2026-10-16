#!/usr/bin/env python3
"""Phase 2 latency spike: Qwen2.5-0.5B base under a constrained-decode cost
profile (one context prefill per request + single-token decode steps with a
prompt cache).

Requires an ISOLATED venv with mlx-lm (the repo's locked torch/transformers
must not be touched):

    .venv/bin/python -m venv /tmp/mlx-spike-venv
    /tmp/mlx-spike-venv/bin/pip install mlx-lm
    /tmp/mlx-spike-venv/bin/mlx_lm.convert --hf-path \
        .rimeai/models/qwen2.5-0.5b-base-060db64 -q --mlx-path /tmp/qwen05b-4bit

Run:
    /tmp/mlx-spike-venv/bin/python scripts/spike_4bit_latency.py --engine mlx
    /tmp/mlx-spike-venv/bin/python scripts/spike_4bit_latency.py --engine torch
(torch mode runs against the repo .venv interpreter instead).
"""

import argparse
import json
import time

STEP_COUNTS = (4, 10, 20, 30)
ROUNDS = 12
CONTEXT = "请在终端执行这条命令然后观察输出结果的变化情况以便确认"


def percentile(values, fraction):
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, round(fraction * (len(ordered) - 1)))]


def profile(step_counts, rounds, load_ms, run_once, context_tokens):
    profiles = {}
    for steps in step_counts:
        end_to_end = []
        for round_index in range(rounds):
            elapsed = run_once(steps)
            if round_index == 0:  # warm-up round
                continue
            end_to_end.append(elapsed)
        profiles[str(steps)] = {
            "prefill_plus_steps_ms": {
                "p50": round(percentile(end_to_end, 0.50), 3),
                "p95": round(percentile(end_to_end, 0.95), 3),
            }
        }
    return {"load_ms": load_ms, "context_tokens": context_tokens, "profiles": profiles}


def run_mlx(model_path):
    import mlx.core as mx
    from mlx_lm import load
    from mlx_lm.models.cache import make_prompt_cache

    start = time.perf_counter()
    model, tokenizer = load(model_path)
    load_ms = round((time.perf_counter() - start) * 1000.0, 1)
    tokens = tokenizer.encode(CONTEXT)

    def run_once(steps):
        cache = make_prompt_cache(model)
        t0 = time.perf_counter()
        logits = model(mx.array([tokens]), cache=cache)
        mx.eval(logits)
        token = int(mx.argmax(logits[0, -1, :]).item())
        for _ in range(steps):
            logits = model(mx.array([[token]]), cache=cache)
            mx.eval(logits)
            token = int(mx.argmax(logits[0, -1, :]).item())
        return (time.perf_counter() - t0) * 1000.0

    return profile(STEP_COUNTS, ROUNDS, load_ms, run_once, len(tokens))


def run_torch(model_path):
    import torch
    from transformers import AutoModelForCausalLM, AutoTokenizer

    start = time.perf_counter()
    tokenizer = AutoTokenizer.from_pretrained(model_path, local_files_only=True)
    model = (
        AutoModelForCausalLM.from_pretrained(
            model_path, local_files_only=True, torch_dtype=torch.float16
        )
        .to("mps")
        .eval()
    )
    load_ms = round((time.perf_counter() - start) * 1000.0, 1)
    tokens = tokenizer.encode(CONTEXT)

    def run_once(steps):
        with torch.inference_mode():
            t0 = time.perf_counter()
            out = model(torch.tensor([tokens], device="mps"), use_cache=True)
            token = int(out.logits[0, -1].argmax().item())
            for _ in range(steps):
                out = model(
                    torch.tensor([[token]], device="mps"),
                    past_key_values=out.past_key_values,
                    use_cache=True,
                )
                token = int(out.logits[0, -1].argmax().item())
            torch.mps.synchronize()
            return (time.perf_counter() - t0) * 1000.0

    return profile((4, 10, 30), ROUNDS, load_ms, run_once, len(tokens))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("engine", choices=("mlx", "torch"))
    parser.add_argument(
        "--mlx-model", default="/tmp/qwen05b-4bit",
        help="4-bit MLX model dir from mlx_lm.convert -q",
    )
    parser.add_argument(
        "--torch-model", default=".rimeai/models/qwen2.5-0.5b-base-060db64"
    )
    arguments = parser.parse_args()
    if arguments.engine == "mlx":
        report = run_mlx(arguments.mlx_model)
    else:
        report = run_torch(arguments.torch_model)
    print(json.dumps(report, ensure_ascii=False, indent=1, sort_keys=True))


if __name__ == "__main__":
    main()
