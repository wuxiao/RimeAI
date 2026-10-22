#!/usr/bin/env python3
"""Typing-path latency benchmark for the learning layers (LP-012 P95).

Measures the daemon's synchronous rerank path (``engine.infer`` with
``allow_sentence=False`` — the per-keystroke surface where L2 user-LM
evidence applies) with the learning layer on vs off, interleaving both
engines over the same requests so thermal drift and machine noise
cancel. The regression metric is delta-P95: ``p95(user_lm_on) -
p95(user_lm_off)`` must stay within +1ms (LP-008 evaluation-plan
condition; consumed by ``tools/run_loop_gates.py``'s sidecar gate).

The neural ranker (24M) is intentionally optional and shared by both
configurations — whatever base components are configured apply
identically, so the delta isolates the L2 surface. Swift-side L1
lookup is an in-memory snapshot read (microseconds) and is covered by
the Swift suite, not this harness.
"""

from __future__ import annotations

import argparse
import json
import random
import time
from collections.abc import Callable
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

VERSION = 1
PROJECT_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_LANGUAGE_MODEL = (
    PROJECT_ROOT / ".rimeai/models/p0-char-ngram-v2.json.gz"
)
DEFAULT_BEAM_CONFIG = (
    PROJECT_ROOT / ".rimeai/models/p0-beam-sentence-v3.json"
)
DEFAULT_RIME_DICTIONARY = (
    PROJECT_ROOT / ".rimeai/rime/shared/luna_pinyin.dict.yaml"
)
DEFAULT_USER_LM = (
    Path.home()
    / "Library"
    / "Application Support"
    / "RimeAI"
    / "language_profile"
    / "user-lm.json.gz"
)
DEFAULT_FROZEN_SAMPLES = (
    PROJECT_ROOT / ".rimeai/datasets/p0-librime-1.17.0-luna-simp.jsonl"
)
DEFAULT_REPORT = (
    PROJECT_ROOT / ".rimeai/reports/typing-path-benchmark.json"
)
DEFAULT_SAMPLES = 300
WARMUP_CALLS = 20


def load_samples(path: Path, limit: int) -> list[dict[str, Any]]:
    """Frozen P0 samples shaped into typing-path infer requests."""
    requests: list[dict[str, Any]] = []
    with path.open(encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, start=1):
            if not line.strip():
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError as error:
                raise SystemExit(
                    f"{path}:{line_number}: sample file is not valid "
                    f"jsonl ({error}); refusing to benchmark against a "
                    "corrupted dataset"
                ) from error
            candidates = [
                candidate
                for candidate in row.get("candidates", [])
                if isinstance(candidate, str)
            ][:10]
            if not candidates:
                continue
            requests.append(
                {
                    "request_id": f"bench-{len(requests):06d}",
                    "composition_id": f"bench-composition-{len(requests):06d}",
                    "app_session_id": "bench-session",
                    "pinyin": row["pinyin"],
                    "context": (row.get("context") or "")[:100],
                    "candidates": candidates,
                    "revision": 1,
                    "deadline_ms": 400,
                    "allow_sentence": False,
                    "context_policy": "standard",
                    "sensitive": False,
                }
            )
            if len(requests) >= limit:
                break
    return requests


def percentile(values: list[float], fraction: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    index = min(
        len(ordered) - 1, max(0, round(fraction * (len(ordered) - 1)))
    )
    return ordered[index]


def measure_interleaved(
    baseline_call: Callable[[dict[str, Any]], Any],
    user_call: Callable[[dict[str, Any]], Any],
    requests: list[dict[str, Any]],
    *,
    seed: int = 42,
) -> dict[str, Any]:
    """Runs both callables over the same requests in one interleaved
    shuffled pass; per-call wall time in milliseconds."""
    order = list(range(len(requests)))
    random.Random(seed).shuffle(order)
    baseline_ms: list[float] = []
    user_ms: list[float] = []
    for index in order:
        request = requests[index]
        started = time.perf_counter()
        baseline_call(request)
        baseline_ms.append((time.perf_counter() - started) * 1000.0)
        started = time.perf_counter()
        user_call(request)
        user_ms.append((time.perf_counter() - started) * 1000.0)
    return {
        "samples": len(requests),
        "seed": seed,
        "baseline_p50_ms": round(percentile(baseline_ms, 0.5), 3),
        "baseline_p95_ms": round(percentile(baseline_ms, 0.95), 3),
        "user_p50_ms": round(percentile(user_ms, 0.5), 3),
        "user_p95_ms": round(percentile(user_ms, 0.95), 3),
        "delta_p50_ms": round(
            percentile(user_ms, 0.5) - percentile(baseline_ms, 0.5), 3
        ),
        "delta_p95_ms": round(
            percentile(user_ms, 0.95) - percentile(baseline_ms, 0.95), 3
        ),
    }


def build_report(
    measurements: dict[str, Any],
    *,
    user_lm_path: Path,
    neural_ranker: bool,
) -> dict[str, Any]:
    return {
        "schema_version": 1,
        "generator": {
            "tool": "tools/benchmark_typing_path.py",
            "version": VERSION,
        },
        "configuration": {
            "path": "engine.infer(allow_sentence=False)",
            "user_lm": str(user_lm_path),
            "neural_ranker": neural_ranker,
            "warmup_calls": WARMUP_CALLS,
        },
        **measurements,
        "regression_budget_ms": 1.0,
        "generated_at": datetime.now(timezone.utc).isoformat(),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="benchmark-typing-path",
        description=(
            "A/B-interleaved P50/P95 for the sync rerank path with the "
            "L2 user LM on vs off (LP-012 P95 regression metric)."
        ),
    )
    parser.add_argument("--language-model", type=Path, default=DEFAULT_LANGUAGE_MODEL)
    parser.add_argument("--beam-config", type=Path, default=DEFAULT_BEAM_CONFIG)
    parser.add_argument("--rime-dictionary", type=Path, default=DEFAULT_RIME_DICTIONARY)
    parser.add_argument("--user-lm", type=Path, default=DEFAULT_USER_LM)
    parser.add_argument("--frozen-samples", type=Path, default=DEFAULT_FROZEN_SAMPLES)
    parser.add_argument("--samples", type=int, default=DEFAULT_SAMPLES)
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT)
    parser.add_argument(
        "--neural-ranker",
        type=Path,
        default=None,
        help="optional 24M ranker artifact shared by both configurations",
    )
    args = parser.parse_args(argv)
    if not args.user_lm.exists():
        print(
            f"error: user LM artifact missing: {args.user_lm} "
            "(the benchmark needs a real learning layer to measure)",
            file=sys.stderr,
        )
        return 2

    from rimeai_daemon.engine import LocalInferenceEngine

    engine_kwargs: dict[str, Any] = (
        {"neural_model_path": args.neural_ranker}
        if args.neural_ranker is not None
        else {}
    )
    baseline_engine = LocalInferenceEngine(
        language_model_path=args.language_model,
        beam_config_path=args.beam_config,
        rime_dictionary_path=args.rime_dictionary,
        user_lm_path=None,
        **engine_kwargs,
    )
    user_engine = LocalInferenceEngine(
        language_model_path=args.language_model,
        beam_config_path=args.beam_config,
        rime_dictionary_path=args.rime_dictionary,
        user_lm_path=args.user_lm,
        **engine_kwargs,
    )
    requests = load_samples(args.frozen_samples, args.samples)
    if not requests:
        print(
            f"error: no usable samples in {args.frozen_samples}",
            file=sys.stderr,
        )
        return 2
    # Warmup covers lazy loads (dictionary grams, first-touch caches) so
    # the measured pass reflects steady-state typing, not cold start.
    warmup = load_samples(args.frozen_samples, WARMUP_CALLS)
    for request in warmup:
        baseline_engine.infer(request)
        user_engine.infer(request)

    measurements = measure_interleaved(
        baseline_engine.infer, user_engine.infer, requests
    )
    report = build_report(
        measurements,
        user_lm_path=args.user_lm,
        neural_ranker=args.neural_ranker is not None,
    )
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(
        json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True)
        + "\n",
        encoding="utf-8",
    )
    print(
        f"typing path: p95 {report['baseline_p95_ms']}ms -> "
        f"{report['user_p95_ms']}ms (delta {report['delta_p95_ms']}ms, "
        f"budget +{report['regression_budget_ms']}ms) -> {args.report}"
    )
    return 0


if __name__ == "__main__":
    import sys

    raise SystemExit(main(sys.argv[1:]))
