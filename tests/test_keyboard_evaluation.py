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
        "repair_prefix_preserved": 0.0,
        "repair_remaining_pinyin": 0.0,
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
                repair_prefix_preserved=True,
                repair_remaining_shrunk=True,
                repair_committed=True,
                repair_mid_text_before="明天tianqi",
                repair_mid_text_after="明天tian",
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
    assert report["metrics"]["repair_prefix_preserved"] == 1.0
    assert report["metrics"]["repair_remaining_pinyin"] == 1.0
    assert report["metrics"]["repair_committed"] == 1.0
    partial_slice = report["slices"]["partial-selection"]
    assert partial_slice["repair_prefix_preserved"] == 1.0
    assert partial_slice["repair_remaining_pinyin"] == 1.0
    assert partial_slice["repair_committed"] == 1.0


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
    assert "repair_prefix_preserved must be a boolean" in result.stderr


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
