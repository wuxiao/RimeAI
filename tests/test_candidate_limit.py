import json
from pathlib import Path

from rimeai_eval.cli import main


def test_evaluate_can_freeze_the_rime_top_ten_boundary(
    tmp_path: Path, capsys
):
    dataset = tmp_path / "dataset.jsonl"
    candidates = [f"候选{index}" for index in range(1, 12)]
    dataset.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "id": "sample-1",
                "split": "test",
                "domain": "general",
                "context": "上下文",
                "pinyin": "houxuan",
                "candidates": candidates,
                "gold_text": "候选11",
                "tags": [],
            },
            ensure_ascii=False,
        )
        + "\n",
        encoding="utf-8",
    )

    exit_code = main(
        ["evaluate", str(dataset), "--candidate-limit", "10"]
    )

    assert exit_code == 0
    report = json.loads(capsys.readouterr().out)
    assert report["dataset"]["candidate_limit"] == 10
    assert report["dataset"]["covered_samples"] == 0
    assert report["metrics"]["top1_accuracy"] == 0.0
