import json
from pathlib import Path
import sys

from rimeai_eval.cli import main


def test_sentence_evaluation_applies_only_pinyin_consistent_suggestions(
    tmp_path: Path, capsys
):
    dictionary = tmp_path / "fixture.dict.yaml"
    dictionary.write_text(
        "---\nname: fixture\n...\n"
        "命\tming\n令\tling\n明\tming\n"
        "结\tjie\n果\tguo\n国\tguo\n",
        encoding="utf-8",
    )
    samples = [
        {
            "schema_version": 1,
            "id": "sample-1",
            "split": "test",
            "domain": "developer",
            "context": "请在终端执行这条",
            "pinyin": "mingling",
            "candidates": ["明令", "命令"],
            "gold_text": "命令",
            "tags": ["long-input"],
        },
        {
            "schema_version": 1,
            "id": "sample-2",
            "split": "test",
            "domain": "general",
            "context": "最终",
            "pinyin": "jieguo",
            "candidates": ["结果", "结国"],
            "gold_text": "结果",
            "tags": ["long-input"],
        },
    ]
    dataset = tmp_path / "dataset.jsonl"
    dataset.write_text(
        "".join(
            json.dumps(sample, ensure_ascii=False) + "\n"
            for sample in samples
        ),
        encoding="utf-8",
    )
    worker = tmp_path / "worker.py"
    worker.write_text(
        "import json,sys\n"
        "for line in sys.stdin:\n"
        " request=json.loads(line)\n"
        " suggestion='命令' if request['request_id']=='sample-1' else '命令'\n"
        " print(json.dumps({'schema_version':1,"
        "'request_id':request['request_id'],'suggestion':suggestion,"
        "'confidence':0.9,'model_artifact_id':'fixture-v1'},"
        "ensure_ascii=False),flush=True)\n",
        encoding="utf-8",
    )
    config = tmp_path / "decoder.json"
    config.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "name": "fixture-decoder",
                "command": [sys.executable, str(worker)],
                "timeout_ms": 1000,
            }
        ),
        encoding="utf-8",
    )

    exit_code = main(
        [
            "evaluate-sentence",
            str(dataset),
            "--decoder-config",
            str(config),
            "--rime-dictionary",
            str(dictionary),
        ]
    )

    assert exit_code == 0
    report = json.loads(capsys.readouterr().out)
    assert report["metrics"]["baseline_sentence_accuracy"] == 0.5
    assert report["metrics"]["sentence_accuracy"] == 1.0
    assert report["metrics"]["relative_lift"] == 1.0
    assert report["decoder"]["valid_suggestions"] == 1
    assert report["decoder"]["pinyin_rejections"] == 1
