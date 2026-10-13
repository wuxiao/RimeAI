import gzip
import json
import math
import os
from pathlib import Path
import subprocess
import sys

import pytest

from rimeai_eval.cli import main
from rimeai_runtime.ngram_ranker import (
    NGramModelError,
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
    assert serialized["schema_version"] == 2
    assert serialized["model_type"] == "char-ngram-ranker"
    smoothing = serialized["hyperparameters"]["smoothing"]
    assert smoothing == {
        "method": "stupid-backoff",
        "alpha": loaded.backoff_alpha,
        "terminal_numerator": 0.1,
        "terminal_denominator": 1000.0,
    }


def test_language_score_is_the_public_view_of_rank_scoring(tmp_path: Path):
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
            "终端运行这条",
            "命令",
            ["明令", "命令"],
        ),
    ]
    model, _ = train_ngram_model(samples, dataset_sha256="b" * 64)
    artifact = tmp_path / "ranker.json.gz"
    write_ngram_model_atomic(artifact, model)
    loaded = load_ngram_model(artifact)

    score = loaded.language_score("请在终端执行这条", "命令")
    assert score == loaded._language_score("请在终端执行这条", "命令")
    assert score > loaded.language_score("请在终端执行这条", "明令")


def _backoff_samples() -> list[dict]:
    return [
        _sample(
            "train-1",
            "train",
            "你",
            "好天气",
            ["明令", "好天气"],
        ),
        _sample(
            "train-2",
            "train",
            "他说你",
            "好天气",
            ["明令", "好天气"],
        ),
        _sample(
            "validation-1",
            "validation",
            "夸你",
            "好天气",
            ["明令", "好天气"],
        ),
    ]


def test_backoff_falls_to_lower_order_when_high_order_unseen():
    model, _ = train_ngram_model(_backoff_samples(), dataset_sha256="d" * 64)
    alpha = model.backoff_alpha

    # Scoring context "好" + candidate "天气" gives text "^好天气":
    # position 2 ("天"): 3/4/5-gram unseen, bigram "好天" seen -> MLE * alpha**3
    # position 3 ("气"): 4/5-gram unseen, trigram "好天气" seen -> MLE * alpha**2
    expected = (math.log(alpha ** 3) + math.log(alpha ** 2)) / 2

    assert model.language_score("好", "天气") == pytest.approx(expected)
    assert model.language_score("好", "天气") > model.language_score("好", "zz")


def test_unseen_everywhere_character_gets_finite_score():
    model, _ = train_ngram_model(_backoff_samples(), dataset_sha256="d" * 64)

    score = model.language_score("好", "qq")

    assert math.isfinite(score)
    assert score < model.language_score("好", "天气")


def test_short_context_uses_available_orders():
    samples = [
        _sample(
            "train-1",
            "train",
            "",
            "天气",
            ["明令", "天气"],
        ),
        _sample(
            "validation-1",
            "validation",
            "",
            "天气",
            ["明令", "天气"],
        ),
    ]
    model, _ = train_ngram_model(samples, dataset_sha256="e" * 64)

    # context "" + candidate "天" gives text "^天": only order 2 fits and
    # bigram "^天" was seen with prefix "^", so the score is log(alpha**3).
    score = model.language_score("", "天")

    assert score == pytest.approx(math.log(model.backoff_alpha ** 3))
    assert score > model.language_score("", "鸭")


def test_load_rejects_schema_v1_artifact(tmp_path: Path):
    model, _ = train_ngram_model(_backoff_samples(), dataset_sha256="d" * 64)
    payload = model.to_dict()
    payload["schema_version"] = 1
    artifact = tmp_path / "ranker-v1.json.gz"
    with gzip.open(artifact, "wt", encoding="utf-8") as file:
        json.dump(payload, file, ensure_ascii=False)

    with pytest.raises(NGramModelError) as excinfo:
        load_ngram_model(artifact)

    assert "retrain" in str(excinfo.value)


def test_train_reports_selected_alpha():
    model, report = train_ngram_model(
        _backoff_samples(), dataset_sha256="d" * 64
    )

    selected_alpha = report["selected_hyperparameters"]["backoff_alpha"]

    assert selected_alpha in {0.2, 0.4, 0.6, 0.8}
    assert model.backoff_alpha == selected_alpha


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
