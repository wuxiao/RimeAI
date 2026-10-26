#!/usr/bin/env python3
"""Closed-loop offline regression gates (LP-012).

Single command, three gates, one machine-readable report; any failure
blocks DONE-INTERNAL. Per-metric status is pass / fail / pending —
a gate verdict is the worst of its metrics (fail > pending > pass),
and the overall verdict is the worst of the gates.

Gate 1 — sidecar (外挂层): runs the LP-008 time-split evaluator
(``rimeai_eval language-profile``) and checks the learning signals that
evaluator's own caveat endorses. Field mapping (2026-10-22, evidence:
the frozen_top1_caveat in every sidecar report says frozen-corpus top1
deltas are leakage-dominated — the frozen baseline was trained on that
corpus — so the design doc's "conditional top1 net gain >= +2pt" is
recorded as a monitoring field, not a gate; the recorded 0.94
generalization-gap formula is unrecoverable, replaced by a defined
no-collapse check: held-out user log-prob must beat the baseline's;
the typing-path P95 latency regression needs a benchmark harness that
does not exist yet — pending, not failed).

Gate 2 — model layer: pending by default (heavy: torch extras). With
--run-model-gate it executes the frozen reproduce command
(evaluate-sentence, torch constrained decoder — the deployed MLX
artifact was proven 99.8% sample-consistent with fp16/torch by LM-001,
so the torch family stands in as the regression measure) and checks
LOOP regression floors: sentence accuracy >= 0.90 (frozen 0.922 minus
~2pp guard band) and p50 <= 1.5x the frozen 280.5ms. Promotion gates
(+2pp accuracy, model_path_miss bucket -50%) belong to LM-002, not to
this loop guard.

Gate 3 — end-to-end: verifies the real-keyboard frozen-set v3 report:
all five overall metrics == 1.0, and per slice every nonzero metric is
exactly 1.0 with at least one nonzero metric (vacuous 0.0 fields are
scenario semantics per KBD-001, e.g. backspace_cleared on non-delete
scenarios). --collect re-runs the collector first.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

VERSION = 1
PROJECT_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_HISTORY_DB = (
    Path.home()
    / "Library"
    / "Application Support"
    / "RimeAI"
    / "History"
    / "history.sqlite3"
)
DEFAULT_FROZEN_SAMPLES = (
    PROJECT_ROOT / ".rimeai/datasets/p0-librime-1.17.0-luna-simp.jsonl"
)
DEFAULT_HOLDOUT_SAMPLES = (
    PROJECT_ROOT / ".rimeai/datasets/real-holdout-v1.jsonl"
)
DEFAULT_BASELINE_MODEL = (
    PROJECT_ROOT / ".rimeai/models/p0-char-ngram-v2.json.gz"
)
DEFAULT_RIME_DICTIONARY = (
    PROJECT_ROOT / ".rimeai/rime/shared/luna_pinyin.dict.yaml"
)
DEFAULT_DECODER_CONFIG = (
    PROJECT_ROOT / "examples/constrained_qwen_decoder.json"
)
DEFAULT_E2E_REPORT = (
    PROJECT_ROOT / ".rimeai/reports/keyboard-interaction-v3.json"
)
DEFAULT_TYPING_PATH_REPORT = (
    PROJECT_ROOT / ".rimeai/reports/typing-path-benchmark.json"
)
DEFAULT_REPORT_OUT = PROJECT_ROOT / ".rimeai/reports/loop-gates-v1.json"
COLLECT_SCRIPT = PROJECT_ROOT / "script/collect_real_keyboard_evaluation.sh"

SIDECAR_MIN_PHRASE_HIT_RATE = 0.30
# Frozen v2 baseline (docs/baselines/constrained-qwen-v2.json): 0.921971
# accuracy, p50 280.534ms. Loop regression floors keep ~2pp accuracy and
# 1.5x latency of headroom; promotion thresholds live in LM-002.
MODEL_MIN_SENTENCE_ACCURACY = 0.90
# 留出集地板（reveal R3 P1 裁决）：真实用户分布的自身基线 0.8333
# 低于冻结集 0.9220，套用同一 0.90 地板会恒 fail——回归地板按各自
# 基线标定（0.8333 - 0.05 容差 ≈ 0.78，防回归不卡积累期）。
MODEL_HOLDOUT_MIN_SENTENCE_ACCURACY = 0.78
MODEL_FROZEN_P50_MS = 280.534
MODEL_MAX_P50_FACTOR = 1.5

EXIT_PASS = 0
EXIT_FAIL = 1
EXIT_PENDING = 3

_VERDICT_ORDER = {"pass": 0, "pending": 1, "fail": 2}


def _metric(
    name: str,
    value: Any,
    comparison: str,
    threshold: Any,
    status: str,
) -> dict[str, Any]:
    return {
        "name": name,
        "value": value,
        "comparison": comparison,
        "threshold": threshold,
        "status": status,
    }


def _gate(
    name: str, metrics: list[dict[str, Any]], notes: list[str]
) -> dict[str, Any]:
    verdict = "pass"
    for candidate in ("fail", "pending"):
        if any(metric["status"] == candidate for metric in metrics):
            verdict = candidate
            break
    return {
        "gate": name,
        "verdict": verdict,
        "metrics": metrics,
        "notes": notes,
    }


def check_sidecar(
    report: dict[str, Any],
    typing_path: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Gate 1 on a language-profile evaluator report dict, plus the
    optional A/B typing-path benchmark report."""
    metrics: list[dict[str, Any]] = []
    notes: list[str] = []
    gain = report.get("learning_gain_nats")
    if isinstance(gain, (int, float)):
        metrics.append(
            _metric(
                "learning_gain_nats",
                gain,
                ">",
                0,
                "pass" if gain > 0 else "fail",
            )
        )
    else:
        metrics.append(
            _metric("learning_gain_nats", None, ">", 0, "fail")
        )
    hit_rate = report.get("phrase_hit_rate")
    if isinstance(hit_rate, (int, float)):
        metrics.append(
            _metric(
                "phrase_hit_rate",
                hit_rate,
                ">=",
                SIDECAR_MIN_PHRASE_HIT_RATE,
                "pass"
                if hit_rate >= SIDECAR_MIN_PHRASE_HIT_RATE
                else "fail",
            )
        )
    else:
        metrics.append(
            _metric("phrase_hit_rate", None, ">=", 0.30, "fail")
        )
    user_test = report.get("user_lm_mean_log_prob_test")
    baseline_test = report.get("baseline_mean_log_prob_test")
    if (
        isinstance(user_test, (int, float))
        and isinstance(baseline_test, (int, float))
    ):
        metrics.append(
            _metric(
                "generalization_no_collapse(user_test>baseline_test)",
                user_test,
                ">",
                baseline_test,
                "pass" if user_test > baseline_test else "fail",
            )
        )
    else:
        metrics.append(
            _metric(
                "generalization_no_collapse(user_test>baseline_test)",
                None,
                ">",
                None,
                "fail",
            )
        )
    net_gain = report.get("net_gain_points")
    if isinstance(net_gain, (int, float)):
        notes.append(
            "net_gain_points="
            f"{net_gain} recorded as monitoring-only: "
            + str(
                report.get(
                    "frozen_top1_caveat",
                    "frozen-set top1 deltas are leakage-dominated",
                )
            )
        )
    if typing_path is not None:
        delta = typing_path.get("delta_p95_ms")
        budget = typing_path.get("regression_budget_ms", 1.0)
        if isinstance(delta, (int, float)):
            metrics.append(
                _metric(
                    "typing_path_p95_delta_ms",
                    delta,
                    "<=",
                    budget,
                    "pass" if delta <= budget else "fail",
                )
            )
        else:
            metrics.append(
                _metric(
                    "typing_path_p95_delta_ms", None, "<=", 1.0, "fail"
                )
            )
    else:
        notes.append(
            "typing_path_p95: pending — run tools/benchmark_typing_path.py "
            "to produce the A/B interleaved report this gate consumes"
        )
        metrics.append(
            _metric(
                "typing_path_p95_delta_ms", None, "<=", 1.0, "pending"
            )
        )
    return _gate("sidecar", metrics, notes)


def check_model(
    summary: dict[str, Any],
    *,
    min_sentence_accuracy: float = MODEL_MIN_SENTENCE_ACCURACY,
) -> dict[str, Any]:
    """Gate 2 on an evaluate-sentence stdout summary dict. The floor
    is parameterized per dataset leg (frozen vs real holdout have
    different baselines; reveal 2026-10-24)."""
    metrics: list[dict[str, Any]] = []
    notes: list[str] = []
    sentence = (summary.get("metrics") or {}).get("sentence_accuracy")
    if isinstance(sentence, (int, float)):
        metrics.append(
            _metric(
                "sentence_accuracy",
                sentence,
                ">=",
                min_sentence_accuracy,
                "pass"
                if sentence >= min_sentence_accuracy
                else "fail",
            )
        )
    else:
        metrics.append(
            _metric("sentence_accuracy", None, ">=", 0.90, "fail")
        )
    p50 = (summary.get("latency_ms") or {}).get("p50")
    budget = MODEL_FROZEN_P50_MS * MODEL_MAX_P50_FACTOR
    if isinstance(p50, (int, float)):
        metrics.append(
            _metric(
                "latency_p50_ms",
                p50,
                "<=",
                round(budget, 3),
                "pass" if p50 <= budget else "fail",
            )
        )
    else:
        metrics.append(
            _metric("latency_p50_ms", None, "<=", budget, "fail")
        )
    notes.append(
        "loop regression floors only (frozen 0.921971 / p50 280.534ms); "
        "promotion gates (+2pp, model_path_miss -50%, dual dataset) "
        "belong to LM-002"
    )
    return _gate("model", metrics, notes)


def check_e2e(report: dict[str, Any]) -> dict[str, Any]:
    """Gate 3 on a keyboard-interaction report dict."""
    metrics: list[dict[str, Any]] = []
    overall = report.get("metrics") or {}
    for name in (
        "candidate_pool_inclusion",
        "conditional_accuracy",
        "accepted",
        "reverted",
        "backspace_cleared",
        # KBD-008 回修链指标（← 焦点回移腿）：报告含该指标时必须为
        # 1.0；旧报告无此键则跳过（向后兼容）。
        "repair_focus_moved_left",
        "repair_suffix_repushed",
        "repair_prefix_revised",
        "repair_single_commit",
        "repair_committed",
    ):
        value = overall.get(name)
        if value is None:
            continue
        metrics.append(
            _metric(
                f"overall_{name}",
                value,
                "==",
                1.0,
                "pass" if value == 1.0 else "fail",
            )
        )
    slices = report.get("slices") or {}
    if not slices:
        metrics.append(
            _metric("slices_present", 0, ">=", 1, "fail")
        )
    for slice_name, slice_data in sorted(slices.items()):
        values = [
            value
            for key, value in slice_data.items()
            if key != "samples" and isinstance(value, (int, float))
        ]
        nonzero = [value for value in values if value > 0]
        status = "pass"
        if not nonzero or any(value != 1.0 for value in nonzero):
            status = "fail"
        metrics.append(
            _metric(
                f"slice[{slice_name}].nonzero_metrics_all_1.0",
                len(nonzero),
                "count-all-1.0",
                None,
                status,
            )
        )
    notes: list[str] = [
        "vacuous 0.0 fields are scenario semantics (KBD-001): only "
        "nonzero metrics must equal 1.0, and every slice needs at "
        "least one nonzero metric"
    ]
    return _gate("e2e", metrics, notes)


def aggregate(gates: dict[str, dict[str, Any]]) -> str:
    verdicts = [gate["verdict"] for gate in gates.values()]
    return max(verdicts, key=lambda verdict: _VERDICT_ORDER[verdict])


def _run_command(command: list[str]) -> subprocess.CompletedProcess:
    return subprocess.run(
        command,
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )


def _load_json(path: Path) -> tuple[dict[str, Any] | None, str | None]:
    """Loads a report file; returns (payload, error). A corrupt or
    unreadable report is a failed gate, never a traceback."""
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        return None, f"{path}: {error}"
    if not isinstance(payload, dict):
        return None, f"{path}: report is not a JSON object"
    return payload, None


def run_sidecar_gate(
    *,
    history_db: Path,
    frozen_samples: Path,
    baseline_model: Path,
    sidecar_report: Path | None,
    typing_path_report: Path,
    report_out: Path,
) -> dict[str, Any]:
    if sidecar_report is not None:
        report, error = _load_json(sidecar_report)
        if report is None:
            return _gate(
                "sidecar",
                [_metric("sidecar_report_json", None, "json", None, "fail")],
                [error or "unreadable sidecar report"],
            )
    else:
        if not history_db.exists():
            return _gate(
                "sidecar",
                [
                    _metric(
                        "history_db_present", False, "==", True, "pending"
                    )
                ],
                [f"history database missing: {history_db}"],
            )
        target = report_out.parent / "loop-gates-sidecar-latest.json"
        completed = _run_command(
            [
                sys.executable,
                "-m",
                "rimeai_eval",
                "language-profile",
                "--history-db",
                str(history_db),
                "--frozen-samples",
                str(frozen_samples),
                "--baseline-model",
                str(baseline_model),
                "--report",
                str(target),
            ]
        )
        if completed.returncode != 0 or not target.exists():
            return _gate(
                "sidecar",
                [_metric("evaluator_run", completed.returncode, "==", 0, "fail")],
                [completed.stderr[-2000:]],
            )
        report, error = _load_json(target)
        if report is None:
            return _gate(
                "sidecar",
                [_metric("evaluator_report_json", None, "json", None, "fail")],
                [error or "unreadable evaluator report"],
            )
    typing_path: dict[str, Any] | None = None
    if typing_path_report.exists():
        loaded, load_error = _load_json(typing_path_report)
        if loaded is None:
            return _gate(
                "sidecar",
                [_metric("typing_path_json", None, "json", None, "fail")],
                [load_error or "unreadable typing-path report"],
            )
        typing_path = loaded
    return check_sidecar(report, typing_path)


def run_model_gate(
    *,
    run: bool,
    model_summary: Path | None,
    frozen_samples: Path,
    decoder_config: Path,
    rime_dictionary: Path,
    holdout_samples: Path | None = None,
) -> dict[str, Any]:
    """Model-layer gate. The frozen set always runs; when a real
    holdout dataset exists (LM-004 accumulation, per the loop design)
    it runs additionally with the same floors — the gate takes the
    worst of both, matching the LM-002 dual-dataset posture."""
    if model_summary is not None:
        summary, error = _load_json(model_summary)
        if summary is None:
            return _gate(
                "model",
                [_metric("model_summary_json", None, "json", None, "fail")],
                [error or "unreadable model summary"],
            )
        # 单一 summary 只覆盖一条腿（reveal R3 P1：model-summary 路径
        # 曾完全绕过留出集）——另一条腿显式 pending，不冒充双集通过。
        frozen_gate = check_model(summary)
        metrics = [
            _metric(
                f"frozen_{m['name']}", m["value"],
                m["comparison"], m["threshold"], m["status"],
            )
            for m in frozen_gate["metrics"]
        ]
        metrics.append(
            _metric(
                "holdout_sentence_accuracy", None, ">=",
                MODEL_HOLDOUT_MIN_SENTENCE_ACCURACY, "pending",
            )
        )
        return _gate(
            "model",
            metrics,
            frozen_gate["notes"]
            + [
                "--model-summary covers the frozen leg only; the "
                "holdout leg is pending until --run-model-gate",
            ],
        )
    if not run:
        return _gate(
            "model",
            [
                _metric(
                    "evaluate_sentence_run",
                    None,
                    "==",
                    0,
                    "pending",
                )
            ],
            [
                "pending: pass --run-model-gate (torch extras; minutes) "
                "or --model-summary to verify an existing run"
            ],
        )
    completed = _run_command(
        [
            sys.executable,
            "-m",
            "rimeai_eval",
            "evaluate-sentence",
            str(frozen_samples),
            "--decoder-config",
            str(decoder_config),
            "--rime-dictionary",
            str(rime_dictionary),
            "--split",
            "test",
        ]
    )
    if completed.returncode != 0:
        return _gate(
            "model",
            [_metric("evaluate_sentence_run", completed.returncode, "==", 0, "fail")],
            [completed.stderr[-2000:]],
        )
    try:
        summary = json.loads(completed.stdout)
    except json.JSONDecodeError:
        return _gate(
            "model",
            [_metric("evaluate_sentence_stdout", None, "json", None, "fail")],
            [completed.stdout[-2000:]],
        )
    frozen_gate = check_model(summary)
    if holdout_samples is None:
        return frozen_gate
    if not holdout_samples.is_file():
        metrics = list(frozen_gate["metrics"])
        metrics.append(
            _metric("holdout_dataset_present", False, "==", True, "pending")
        )
        return _gate(
            "model",
            metrics,
            frozen_gate["notes"]
            + [f"real holdout missing: {holdout_samples} (pending until "
               "LM-004 accumulation rebuilds it)"],
        )
    holdout_completed = _run_command(
        [
            sys.executable,
            "-m",
            "rimeai_eval",
            "evaluate-sentence",
            str(holdout_samples),
            "--decoder-config",
            str(decoder_config),
            "--rime-dictionary",
            str(rime_dictionary),
            "--split",
            "test",
        ]
    )
    if holdout_completed.returncode != 0:
        metrics = list(frozen_gate["metrics"])
        metrics.append(
            _metric(
                "holdout_evaluate_run",
                holdout_completed.returncode,
                "==",
                0,
                "fail",
            )
        )
        return _gate(
            "model", metrics,
            frozen_gate["notes"] + [holdout_completed.stderr[-2000:]],
        )
    try:
        holdout_summary = json.loads(holdout_completed.stdout)
    except json.JSONDecodeError:
        metrics = list(frozen_gate["metrics"])
        metrics.append(
            _metric("holdout_stdout", None, "json", None, "fail")
        )
        return _gate(
            "model", metrics,
            frozen_gate["notes"] + [holdout_completed.stdout[-2000:]],
        )
    holdout_gate = check_model(
        holdout_summary,
        min_sentence_accuracy=MODEL_HOLDOUT_MIN_SENTENCE_ACCURACY,
    )
    # 双数据集最差语义：指标带前缀合并（_gate 取最差状态），notes 合并。
    merged_metrics = [
        _metric(
            f"frozen_{m['name']}", m["value"],
            m["comparison"], m["threshold"], m["status"],
        )
        for m in frozen_gate["metrics"]
    ] + [
        _metric(
            f"holdout_{m['name']}", m["value"],
            m["comparison"], m["threshold"], m["status"],
        )
        for m in holdout_gate["metrics"]
    ]
    return _gate(
        "model",
        merged_metrics,
        list(dict.fromkeys(frozen_gate["notes"] + holdout_gate["notes"])),
    )


def run_e2e_gate(
    *,
    e2e_report: Path,
    collect: bool,
) -> dict[str, Any]:
    if collect:
        completed = _run_command([str(COLLECT_SCRIPT)])
        if completed.returncode != 0:
            return _gate(
                "e2e",
                [_metric("collector_run", completed.returncode, "==", 0, "fail")],
                [completed.stderr[-2000:]],
            )
    if not e2e_report.exists():
        return _gate(
            "e2e",
            [_metric("report_present", False, "==", True, "pending")],
            [
                f"real-keyboard report missing: {e2e_report} "
                "(re-run with --collect on a GUI session)"
            ],
        )
    report, error = _load_json(e2e_report)
    if report is None:
        return _gate(
            "e2e",
            [_metric("report_json", None, "json", None, "fail")],
            [error or "unreadable e2e report"],
        )
    return check_e2e(report)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="run-loop-gates",
        description="LP-012 closed-loop offline regression gates.",
    )
    parser.add_argument(
        "--only",
        choices=("sidecar", "model", "e2e"),
        action="append",
        dest="only",
        help="run a subset (repeatable); default: all three",
    )
    parser.add_argument("--report-out", type=Path, default=DEFAULT_REPORT_OUT)
    parser.add_argument(
        "--sidecar-report",
        type=Path,
        default=None,
        help="verify an existing language-profile report instead of running",
    )
    parser.add_argument(
        "--run-model-gate",
        action="store_true",
        help="execute evaluate-sentence (torch extras; minutes)",
    )
    parser.add_argument(
        "--model-summary",
        type=Path,
        default=None,
        help="verify an existing evaluate-sentence stdout JSON",
    )
    parser.add_argument(
        "--holdout-samples",
        type=Path,
        default=DEFAULT_HOLDOUT_SAMPLES,
        help="real-history holdout jsonl run additionally in the model "
        "gate (worst-of-both floors; missing file keeps the metric "
        "pending), pass an empty path value to disable",
    )
    parser.add_argument(
        "--e2e-report", type=Path, default=DEFAULT_E2E_REPORT
    )
    parser.add_argument(
        "--collect",
        action="store_true",
        help="re-run the real-keyboard collector before the e2e gate",
    )
    parser.add_argument(
        "--typing-path-report",
        type=Path,
        default=DEFAULT_TYPING_PATH_REPORT,
        help="A/B interleaved typing-path benchmark report "
        "(tools/benchmark_typing_path.py); a missing file keeps the "
        "metric pending",
    )
    args = parser.parse_args(argv)
    selected = args.only or ["sidecar", "model", "e2e"]

    gates: dict[str, dict[str, Any]] = {}
    if "sidecar" in selected:
        gates["sidecar"] = run_sidecar_gate(
            history_db=DEFAULT_HISTORY_DB,
            frozen_samples=DEFAULT_FROZEN_SAMPLES,
            baseline_model=DEFAULT_BASELINE_MODEL,
            sidecar_report=args.sidecar_report,
            typing_path_report=args.typing_path_report,
            report_out=args.report_out,
        )
    if "model" in selected:
        gates["model"] = run_model_gate(
            run=args.run_model_gate,
            model_summary=args.model_summary,
            frozen_samples=DEFAULT_FROZEN_SAMPLES,
            decoder_config=DEFAULT_DECODER_CONFIG,
            rime_dictionary=DEFAULT_RIME_DICTIONARY,
            holdout_samples=(
                args.holdout_samples
                if args.holdout_samples is not None
                and str(args.holdout_samples) not in ("", "none", ".")
                else None
            ),
        )
    if "e2e" in selected:
        gates["e2e"] = run_e2e_gate(
            e2e_report=args.e2e_report, collect=args.collect
        )

    overall = aggregate(gates)
    payload = {
        "schema_version": 1,
        "generator": {
            "tool": "tools/run_loop_gates.py",
            "version": VERSION,
        },
        "gates": gates,
        "overall": overall,
        "generated_at": datetime.now(timezone.utc).isoformat(),
    }
    args.report_out.parent.mkdir(parents=True, exist_ok=True)
    args.report_out.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True)
        + "\n",
        encoding="utf-8",
    )
    print(
        f"loop gates: overall={overall} -> "
        f"{args.report_out} ("
        + ", ".join(
            f"{name}:{gate['verdict']}"
            for name, gate in sorted(gates.items())
        )
        + ")"
    )
    if overall == "fail":
        return EXIT_FAIL
    if overall == "pending":
        return EXIT_PENDING
    return EXIT_PASS


if __name__ == "__main__":
    raise SystemExit(main())
