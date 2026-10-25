"""Closed-loop regression gate checkers (tools/run_loop_gates.py)."""

from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path

TOOL_PATH = (
    Path(__file__).resolve().parent.parent / "tools" / "run_loop_gates.py"
)
spec = importlib.util.spec_from_file_location("run_loop_gates", TOOL_PATH)
assert spec is not None and spec.loader is not None
gates = importlib.util.module_from_spec(spec)
sys.modules.setdefault("run_loop_gates", gates)
spec.loader.exec_module(gates)

# Numbers shaped after the real first-eval report
# (.rimeai/reports/language-profile-first-eval.json, 2026-10-12).
SIDECAR_PASS = {
    "learning_gain_nats": 0.298756,
    "phrase_hit_rate": 0.522936,
    "baseline_mean_log_prob_test": -7.074577,
    "user_lm_mean_log_prob_test": -6.77582,
    "user_lm_mean_log_prob_train": -5.834088,
    "net_gain_points": -28.836,
    "frozen_top1_caveat": "regression monitor only",
}

# Shaped after the real v3 real-keyboard report: nonzero metrics are
# exactly 1.0; vacuous 0.0 fields are scenario semantics (KBD-001).
E2E_PASS = {
    "metrics": {
        "accepted": 1.0,
        "backspace_cleared": 1.0,
        "candidate_pool_inclusion": 1.0,
        "conditional_accuracy": 1.0,
        "reverted": 1.0,
    },
    "slices": {
        "exact": {
            "samples": 3,
            "accepted": 1.0,
            "conditional_accuracy": 1.0,
            "candidate_pool_inclusion": 1.0,
            "reverted": 1.0,
            "backspace_cleared": 0.0,
        },
        "delete-composition": {
            "samples": 2,
            "accepted": 0.0,
            "conditional_accuracy": 0.0,
            "candidate_pool_inclusion": 0.0,
            "reverted": 0.0,
            "backspace_cleared": 1.0,
        },
    },
}

MODEL_PASS = {
    "metrics": {
        "sentence_accuracy": 0.921971,
        "baseline_sentence_accuracy": 0.726899,
    },
    "latency_ms": {"samples": 974, "p50": 280.534, "p95": 568.79},
}


def statuses(gate: dict) -> dict[str, str]:
    return {
        metric["name"]: metric["status"] for metric in gate["metrics"]
    }


def test_sidecar_passes_on_first_eval_shape_except_pending_p95():
    gate = gates.check_sidecar(dict(SIDECAR_PASS))
    found = statuses(gate)
    assert found["learning_gain_nats"] == "pass"
    assert found["phrase_hit_rate"] == "pass"
    assert found["generalization_no_collapse(user_test>baseline_test)"] == "pass"
    # No typing-path benchmark report supplied: pending, not fail.
    assert found["typing_path_p95_delta_ms"] == "pending"
    assert gate["verdict"] == "pending"
    assert any("monitoring-only" in note for note in gate["notes"])


def test_sidecar_passes_with_typing_path_report_within_budget():
    typing_path = {
        "delta_p95_ms": 0.4,
        "delta_p50_ms": 0.1,
        "baseline_p95_ms": 4.2,
        "user_p95_ms": 4.6,
        "regression_budget_ms": 1.0,
    }
    gate = gates.check_sidecar(dict(SIDECAR_PASS), typing_path)
    found = statuses(gate)
    assert found["typing_path_p95_delta_ms"] == "pass"
    assert gate["verdict"] == "pass"


def test_sidecar_fails_when_typing_path_exceeds_budget():
    typing_path = {
        "delta_p95_ms": 1.5,
        "regression_budget_ms": 1.0,
    }
    gate = gates.check_sidecar(dict(SIDECAR_PASS), typing_path)
    assert gate["verdict"] == "fail"


def test_sidecar_fails_on_corrupt_typing_path_report():
    gate = gates.check_sidecar(dict(SIDECAR_PASS), {"delta_p95_ms": None})
    assert statuses(gate)["typing_path_p95_delta_ms"] == "fail"


def test_sidecar_fails_on_nonpositive_gain():
    report = dict(SIDECAR_PASS, learning_gain_nats=0.0)
    assert gates.check_sidecar(report)["verdict"] == "fail"


def test_sidecar_fails_on_low_phrase_hit_rate():
    report = dict(SIDECAR_PASS, phrase_hit_rate=0.29)
    assert gates.check_sidecar(report)["verdict"] == "fail"


def test_sidecar_fails_on_generalization_collapse():
    report = dict(
        SIDECAR_PASS,
        user_lm_mean_log_prob_test=-7.5,
    )
    assert gates.check_sidecar(report)["verdict"] == "fail"


def test_sidecar_fails_on_missing_fields():
    assert gates.check_sidecar({})["verdict"] == "fail"


def test_model_passes_on_frozen_baseline_shape():
    gate = gates.check_model(json.loads(json.dumps(MODEL_PASS)))
    assert gate["verdict"] == "pass"
    found = statuses(gate)
    assert found["sentence_accuracy"] == "pass"
    assert found["latency_p50_ms"] == "pass"


def test_model_fails_below_accuracy_floor():
    report = json.loads(json.dumps(MODEL_PASS))
    report["metrics"]["sentence_accuracy"] = 0.85
    assert gates.check_model(report)["verdict"] == "fail"


def test_model_fails_above_latency_budget():
    report = json.loads(json.dumps(MODEL_PASS))
    report["latency_ms"]["p50"] = (
        gates.MODEL_FROZEN_P50_MS * gates.MODEL_MAX_P50_FACTOR + 1
    )
    assert gates.check_model(report)["verdict"] == "fail"


def _run_model_gate_with_stub(
    monkeypatch, tmp_path, *, frozen, holdout, holdout_exists=True
):
    """stub 两次 evaluate-sentence 子进程（frozen/holdout 各一次）。"""
    frozen_samples = tmp_path / "frozen.jsonl"
    frozen_samples.write_text("{}\n", encoding="utf-8")
    holdout_samples = tmp_path / "holdout.jsonl"
    if holdout_exists:
        holdout_samples.write_text("{}\n", encoding="utf-8")
    outputs = iter(
        [
            __import__("subprocess").CompletedProcess(
                [], 0, stdout=json.dumps(frozen), stderr=""
            ),
            __import__("subprocess").CompletedProcess(
                [], 0, stdout=json.dumps(holdout), stderr=""
            ),
        ]
    )

    def fake_run(command):
        return next(outputs)

    monkeypatch.setattr(gates, "_run_command", fake_run)
    return gates.run_model_gate(
        run=True,
        model_summary=None,
        frozen_samples=frozen_samples,
        decoder_config=tmp_path / "decoder.json",
        rime_dictionary=tmp_path / "dict.yaml",
        holdout_samples=holdout_samples if holdout_exists else holdout_samples,
    )


def test_model_gate_merges_holdout_worst_of_both(monkeypatch, tmp_path):
    gate = _run_model_gate_with_stub(
        monkeypatch, tmp_path,
        frozen=MODEL_PASS,
        holdout=MODEL_PASS,
    )
    assert gate["verdict"] == "pass"
    names = [m["name"] for m in gate["metrics"]]
    assert "frozen_sentence_accuracy" in names
    assert "holdout_sentence_accuracy" in names
    # 留出集挂掉时整体 fail（双数据集最差语义）。
    bad_holdout = json.loads(json.dumps(MODEL_PASS))
    bad_holdout["metrics"]["sentence_accuracy"] = 0.5
    gate = _run_model_gate_with_stub(
        monkeypatch, tmp_path,
        frozen=MODEL_PASS, holdout=bad_holdout,
    )
    assert gate["verdict"] == "fail"
    found = {m["name"]: m["status"] for m in gate["metrics"]}
    assert found["frozen_sentence_accuracy"] == "pass"
    assert found["holdout_sentence_accuracy"] == "fail"


def test_model_gate_missing_holdout_stays_pending(monkeypatch, tmp_path):
    gate = _run_model_gate_with_stub(
        monkeypatch, tmp_path,
        frozen=MODEL_PASS, holdout=None, holdout_exists=False,
    )
    assert gate["verdict"] == "pending"
    names = [m["name"] for m in gate["metrics"]]
    assert "holdout_dataset_present" in names


def test_e2e_passes_on_real_v3_shape():
    gate = gates.check_e2e(json.loads(json.dumps(E2E_PASS)))
    assert gate["verdict"] == "pass"


def test_e2e_fails_on_partial_slice_metric():
    report = json.loads(json.dumps(E2E_PASS))
    report["slices"]["exact"]["conditional_accuracy"] = 0.83
    assert gates.check_e2e(report)["verdict"] == "fail"


def test_e2e_fails_on_all_zero_slice():
    report = json.loads(json.dumps(E2E_PASS))
    report["slices"]["exact"] = {
        key: 0.0
        for key in report["slices"]["exact"]
        if key != "samples"
    } | {"samples": 3}
    assert gates.check_e2e(report)["verdict"] == "fail"


def test_e2e_fails_on_nonunity_overall_metric():
    report = json.loads(json.dumps(E2E_PASS))
    report["metrics"]["accepted"] = 0.95
    assert gates.check_e2e(report)["verdict"] == "fail"


def test_aggregate_takes_the_worst_verdict():
    passing = {"verdict": "pass", "metrics": [], "notes": []}
    pending = {"verdict": "pending", "metrics": [], "notes": []}
    failing = {"verdict": "fail", "metrics": [], "notes": []}
    assert gates.aggregate({"a": passing}) == "pass"
    assert gates.aggregate({"a": passing, "b": pending}) == "pending"
    assert (
        gates.aggregate({"a": pending, "b": failing, "c": passing})
        == "fail"
    )


def test_main_verify_mode_e2e_pass(tmp_path: Path, capsys):
    report_file = tmp_path / "e2e.json"
    report_file.write_text(
        json.dumps(E2E_PASS, ensure_ascii=False), encoding="utf-8"
    )
    out = tmp_path / "loop-gates.json"
    code = gates.main(
        [
            "--only",
            "e2e",
            "--e2e-report",
            str(report_file),
            "--report-out",
            str(out),
        ]
    )
    assert code == 0
    payload = json.loads(out.read_text(encoding="utf-8"))
    assert payload["overall"] == "pass"
    assert payload["gates"]["e2e"]["verdict"] == "pass"
    assert "overall=pass" in capsys.readouterr().out


def test_main_missing_e2e_report_is_pending(tmp_path: Path):
    out = tmp_path / "loop-gates.json"
    code = gates.main(
        [
            "--only",
            "e2e",
            "--e2e-report",
            str(tmp_path / "missing.json"),
            "--report-out",
            str(out),
        ]
    )
    assert code == gates.EXIT_PENDING
    payload = json.loads(out.read_text(encoding="utf-8"))
    assert payload["overall"] == "pending"


def test_main_corrupt_report_file_fails_cleanly(tmp_path: Path):
    corrupt = tmp_path / "e2e.json"
    corrupt.write_text("not json", encoding="utf-8")
    out = tmp_path / "loop-gates.json"
    code = gates.main(
        [
            "--only",
            "e2e",
            "--e2e-report",
            str(corrupt),
            "--report-out",
            str(out),
        ]
    )
    assert code == gates.EXIT_FAIL
