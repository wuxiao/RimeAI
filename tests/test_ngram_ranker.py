import gzip
import json
import os
from pathlib import Path
import subprocess
import sys

from rimeai_eval.cli import main
from rimeai_eval.ngram_ranker import (
    load_ngram_model,
    train_ngram_model,
    write_ngram_model_atomic,
)


def _sample(
    sample_id: str,
    split: str,
    context: str,
    gold: str,
    candidates: list[str],
) -> dict:
    return {
        "schema_version": 1,
        "id": sample_id,
        "split": split,
        "domain": "general",
        "context": context,
        "pinyin": "fixture",
        "candidates": candidates,
        "gold_text": gold,
        "tags": [],
    }


def test_training_uses_train_and_validation_but_not_test_labels(tmp_path: Path):
    samples = [
        _sample(
            "train-1",
            "train",
            "请执行下面这条",
            "命令",
            ["明令", "命令"],
        ),
        _sample(
            "train-2",
            "train",
            "终端运行这条",
            "命令",
            ["明令", "命令"],
        ),
        _sample(
            "validation-1",
            "validation",
            "现在执行这条",
            "命令",
            ["明令", "命令"],
        ),
        _sample(
            "test-1",
            "test",
            "不要读取这个答案",
            "绝密",
            ["公开", "绝密"],
        ),
    ]

    model, report = train_ngram_model(samples, dataset_sha256="a" * 64)

    assert model.dataset_sha256 == "a" * 64
    assert model.split_counts == {"train": 2, "validation": 1}
    assert "绝密" not in model.candidate_frequencies
    assert report["test_samples_used"] == 0
    assert report["validation"]["covered_samples"] == 1


def test_model_artifact_round_trips_and_ranks_a_contextual_candidate(
    tmp_path: Path,
):
    samples = [
        _sample(
            "train-1",
            "train",
            "请执行下面这条",
            "命令",
            ["明令", "命令"],
        ),
        _sample(
            "train-2",
            "train",
            "终端运行这条",
            "命令",
            ["明令", "命令"],
        ),
        _sample(
            "validation-1",
            "validation",
            "现在执行这条",
            "命令",
            ["明令", "命令"],
        ),
    ]
    model, _ = train_ngram_model(samples, dataset_sha256="b" * 64)
    artifact = tmp_path / "ranker.json.gz"

    write_ngram_model_atomic(artifact, model)
    loaded = load_ngram_model(artifact)
    ranking, confidence = loaded.rank(
        context="请在终端执行这条",
        candidates=["明令", "命令", "明"],
    )

    assert ranking[0] == "命令"
    assert sorted(ranking) == ["命令", "明", "明令"]
    assert 0 <= confidence <= 1
    with gzip.open(artifact, "rt", encoding="utf-8") as file:
        serialized = json.load(file)
    assert serialized["schema_version"] == 1
    assert serialized["model_type"] == "char-ngram-ranker"


def test_train_ngram_cli_writes_an_artifact_and_provenance_report(
    tmp_path: Path, capsys
):
    dataset = tmp_path / "dataset.jsonl"
    samples = [
        _sample(
            "train-1",
            "train",
            "请执行下面这条",
            "命令",
            ["明令", "命令"],
        ),
        _sample(
            "validation-1",
            "validation",
            "终端执行这条",
            "命令",
            ["明令", "命令"],
        ),
        _sample(
            "test-1",
            "test",
            "测试保留",
            "结果",
            ["结果", "结国"],
        ),
    ]
    dataset.write_text(
        "".join(
            json.dumps(sample, ensure_ascii=False) + "\n"
            for sample in samples
        ),
        encoding="utf-8",
    )
    artifact = tmp_path / "model.json.gz"

    exit_code = main(
        ["train-ngram", str(dataset), "--output", str(artifact)]
    )

    assert exit_code == 0
    assert artifact.is_file()
    report = json.loads(capsys.readouterr().out)
    assert report["test_samples_used"] == 0
    assert report["artifact"]["sha256"]


def test_ngram_worker_implements_the_persistent_ranker_protocol(tmp_path: Path):
    samples = [
        _sample(
            "train-1",
            "train",
            "终端运行这条",
            "命令",
            ["明令", "命令"],
        ),
        _sample(
            "validation-1",
            "validation",
            "请执行这条",
            "命令",
            ["明令", "命令"],
        ),
    ]
    model, _ = train_ngram_model(samples, dataset_sha256="c" * 64)
    artifact = tmp_path / "ranker.json.gz"
    write_ngram_model_atomic(artifact, model)
    request = {
        "schema_version": 1,
        "task": "rerank",
        "request_id": "request-1",
        "context": "现在执行这条",
        "pinyin": "mingling",
        "candidates": [
            {"id": "c0", "text": "明令"},
            {"id": "c1", "text": "命令"},
        ],
    }
    project_root = Path(__file__).resolve().parent.parent
    environment = dict(os.environ)
    environment["RIMEAI_NGRAM_MODEL"] = str(artifact)

    process = subprocess.run(
        [sys.executable, str(project_root / "tools/ngram_ranker_worker.py")],
        input=json.dumps(request, ensure_ascii=False) + "\n",
        text=True,
        capture_output=True,
        env=environment,
        check=False,
    )

    assert process.returncode == 0, process.stderr
    response = json.loads(process.stdout)
    assert response["request_id"] == "request-1"
    assert response["ranking"][0] == "c1"
    assert response["model_artifact_id"].startswith("char-ngram-ranker:sha256-")
