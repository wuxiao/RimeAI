import json
import subprocess
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[1]


def observation(**overrides):
    record = {
        "schema_version": 1,
        "id": "sample",
        "category": "exact",
        "pinyin": "ceshi",
        "expected_text": "测试",
        "final_text": "测试",
        "candidate_in_pool": True,
        "candidate_rank": 1,
        "accepted": True,
        "revert_probe": True,
        "reverted": True,
        "backspace_probe": False,
        "backspace_cleared": False,
    }
    record.update(overrides)
    return record


def write_observations(path: Path, records):
    path.write_text(
        "".join(
            json.dumps(record, ensure_ascii=False) + "\n"
            for record in records
        ),
        encoding="utf-8",
    )


def test_keyboard_report_separates_pool_accuracy_and_interaction_metrics(tmp_path):
    source = PROJECT_ROOT / "datasets/keyboard-interaction-v1.jsonl"
    records = []
    for line in source.read_text(encoding="utf-8").splitlines():
        scenario = json.loads(line)
        records.append(
            observation(
                id=scenario["id"],
                category=scenario["category"],
                pinyin=scenario["pinyin"],
                expected_text=scenario["expected_text"],
                final_text=scenario["expected_text"],
                candidate_in_pool=True,
                accepted=scenario["category"] != "delete-composition",
                revert_probe=scenario["revert_probe"],
                reverted=scenario["revert_probe"],
                backspace_probe=scenario["backspace_probe"],
                backspace_cleared=True,
            )
        )
    records[-2]["candidate_in_pool"] = False
    records[-2]["final_text"] = ""
    records[-2]["accepted"] = False
    output = tmp_path / "observations.jsonl"
    write_observations(output, records)

    result = subprocess.run(
        [
            sys.executable,
            "-m",
            "rimeai_eval",
            "evaluate-keyboard",
            str(output),
        ],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    report = json.loads(result.stdout)
    assert report["metrics"] == {
        "candidate_pool_inclusion": 0.833333,
        "conditional_accuracy": 1.0,
        "accepted": 0.833333,
        "reverted": 1.0,
        "backspace_cleared": 1.0,
        "repair_focus_moved_left": 0.0,
        "repair_suffix_repushed": 0.0,
        "repair_prefix_revised": 0.0,
        "repair_single_commit": 0.0,
        "repair_committed": 0.0,
    }
    assert report["interactions"] == {
        "selection_samples": 6,
        "revert_samples": 6,
        "backspace_samples": 1,
        "repair_samples": 0,
    }
    assert report["slices"]["mixed-composition"]["candidate_pool_inclusion"] == 0.0


def test_keyboard_report_includes_repair_chain_metrics(tmp_path):
    source = PROJECT_ROOT / "datasets/keyboard-interaction-v1.jsonl"
    records = []
    for line in source.read_text(encoding="utf-8").splitlines():
        scenario = json.loads(line)
        record = observation(
            id=scenario["id"],
            category=scenario["category"],
            pinyin=scenario["pinyin"],
            expected_text=scenario["expected_text"],
            final_text=scenario["expected_text"],
            candidate_in_pool=True,
            accepted=scenario["category"] != "delete-composition",
            revert_probe=scenario["revert_probe"],
            reverted=scenario["revert_probe"],
            backspace_probe=scenario["backspace_probe"],
            backspace_cleared=True,
        )
        if scenario["category"] == "partial-selection":
            record.update(
                repair_probe=True,
                repair_focus_moved_left=True,
                repair_suffix_repushed=True,
                repair_prefix_revised=True,
                repair_single_commit=True,
                repair_committed=True,
                repair_pre_arrow_text="明天tianqi",
                repair_post_arrow_text="mingtian天气",
                repair_revised_text="mingti天气",
                repair_restored_text="mingtian天气",
                repair_undo_steps=2,
            )
        records.append(record)
    repair_count = sum(
        1 for record in records if record.get("repair_probe")
    )
    output = tmp_path / "observations.jsonl"
    write_observations(output, records)

    result = subprocess.run(
        [
            sys.executable,
            "-m",
            "rimeai_eval",
            "evaluate-keyboard",
            str(output),
        ],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    report = json.loads(result.stdout)
    assert report["interactions"]["repair_samples"] == repair_count
    for metric in (
        "repair_focus_moved_left",
        "repair_suffix_repushed",
        "repair_prefix_revised",
        "repair_single_commit",
        "repair_committed",
    ):
        assert report["metrics"][metric] == 1.0
    partial_slice = report["slices"]["partial-selection"]
    for metric in (
        "repair_focus_moved_left",
        "repair_suffix_repushed",
        "repair_prefix_revised",
        "repair_single_commit",
        "repair_committed",
    ):
        assert partial_slice[metric] == 1.0


def test_keyboard_report_requires_repair_outcomes(tmp_path):
    output = tmp_path / "observations.jsonl"
    write_observations(output, [observation(repair_probe=True)])

    result = subprocess.run(
        [
            sys.executable,
            "-m",
            "rimeai_eval",
            "evaluate-keyboard",
            str(output),
        ],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 2
    assert "repair_focus_moved_left must be a boolean" in result.stderr


REPAIR_SCENARIO = {
    "id": "keyboard-partial-repair-mingtiantianqi",
    "category": "partial-selection",
    "pool_text": "明天",
    "expected_text": "明天天气",
    "backspace_count": 2,
}


def test_repair_outcome_discriminates_retained_preedit_from_legacy_commit():
    """The <-arrow evidence must separate the retained-preedit path
    from the legacy fallback that commits the prefix to the document
    early — even when the final string is identical (audit fix 2)."""
    import importlib.util

    spec = importlib.util.spec_from_file_location(
        "collect_keyboard_evaluation",
        PROJECT_ROOT / "tools" / "collect_keyboard_evaluation.py",
    )
    assert spec is not None and spec.loader is not None
    collector = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(collector)

    retained = collector.evaluate_repair_outcome(
        REPAIR_SCENARIO,
        pre_arrow="明天tianqi",
        post_arrow="mingtian天气",
        revised="mingti天气",
        restored="mingtian天气",
        final_text="明天天气",
        undo_steps=2,
    )
    assert retained == {
        "repair_focus_moved_left": True,
        "repair_suffix_repushed": True,
        "repair_prefix_revised": True,
        "repair_single_commit": True,
        "repair_committed": True,
    }

    # 旧回退路径：前缀已提前提交 → canMoveFocusLeft=false，← 透传仅
    # 移动光标（文本不变）；文档多一次插入（undo ≥ 3）；退格作用于
    # 文档而非焦点段拼音；但最终字符串仍可能是整句（最终提交补齐）。
    bypassed = collector.evaluate_repair_outcome(
        REPAIR_SCENARIO,
        pre_arrow="明天tianqi",
        post_arrow="明天tianqi",
        revised="明天tianq",
        restored="明天tianqi",
        final_text="明天天气",
        undo_steps=3,
    )
    assert bypassed == {
        "repair_focus_moved_left": False,
        "repair_suffix_repushed": False,
        "repair_prefix_revised": False,
        "repair_single_commit": False,
        "repair_committed": True,
    }


def test_keyboard_report_requires_every_frozen_category(tmp_path):
    output = tmp_path / "observations.jsonl"
    write_observations(output, [observation()])

    result = subprocess.run(
        [
            sys.executable,
            "-m",
            "rimeai_eval",
            "evaluate-keyboard",
            str(output),
        ],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 2
    assert result.stdout == ""
    assert "keyboard observations must cover:" in result.stderr
