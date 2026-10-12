"""Tests for the language-profile evaluation pipeline (LP-008)."""

from __future__ import annotations

import json
from pathlib import Path
import sqlite3

import pytest

from rimeai_eval.language_profile_eval import (
    LanguageProfileEvalError,
    evaluate,
    load_history_commits,
    split_train_test,
)
from rimeai_runtime.ngram_ranker import (
    train_ngram_model,
    write_ngram_model_atomic,
)

HISTORY_DDL = """
CREATE TABLE history_metadata (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    generation INTEGER NOT NULL
);
INSERT INTO history_metadata(id, generation) VALUES (1, 0);
CREATE TABLE history_commits (
    id TEXT PRIMARY KEY NOT NULL,
    committed_at_ms INTEGER NOT NULL,
    bundle_id TEXT NOT NULL,
    pinyin TEXT NOT NULL,
    committed_text TEXT NOT NULL,
    source TEXT NOT NULL,
    embedding_model TEXT,
    embedding_dimension INTEGER,
    embedding_state TEXT NOT NULL DEFAULT 'pending',
    embedding BLOB,
    consolidation_state TEXT NOT NULL DEFAULT 'raw'
);
"""


def _commit(index: int, text: str) -> tuple:
    return (
        f"00000000-0000-0000-0000-{index:012d}",
        1_000_000 + index,
        "com.example.Editor",
        "pinyin",
        text,
        "rime_main",
    )


def _sample(index: int, context: str, candidates: list, gold: str) -> dict:
    return {
        "schema_version": 1,
        "id": f"sample-{index:03d}",
        "split": "test",
        "domain": "general",
        "context": context,
        "pinyin": "pinyin",
        "candidates": candidates,
        "gold_text": gold,
        "tags": [],
    }


def _train_samples() -> list:
    rows = [
        ("我们要给数据库建", ["索引", "所以"], "索引"),
        ("执行这条", ["命令", "明令"], "命令"),
        ("接口的", ["设计", "设记"], "设计"),
    ]
    samples = []
    for index, (context, candidates, gold) in enumerate(rows):
        for split in ("train", "validation"):
            samples.append(
                {
                    "schema_version": 1,
                    "id": f"train-{index}-{split}",
                    "split": split,
                    "domain": "general",
                    "context": context,
                    "pinyin": "pinyin",
                    "candidates": candidates,
                    "gold_text": gold,
                    "tags": [],
                }
            )
    return samples


def _make_history(tmp_path: Path, texts: list) -> Path:
    database = tmp_path / "history.sqlite3"
    with sqlite3.connect(database) as db:
        db.executescript(HISTORY_DDL)
        rows = [_commit(index, text) for index, text in enumerate(texts)]
        db.executemany(
            """
            INSERT INTO history_commits(
                id, committed_at_ms, bundle_id, pinyin,
                committed_text, source
            ) VALUES (?, ?, ?, ?, ?, ?)
            """,
            rows,
        )
    return database


def test_load_history_commits_orders_by_time(tmp_path: Path):
    database = _make_history(tmp_path, ["甲", "乙", "丙"])
    commits = load_history_commits(database)
    assert [commit["committed_text"] for commit in commits] == [
        "甲",
        "乙",
        "丙",
    ]


def test_split_train_test_rejects_bad_ratios():
    commits = [{"committed_text": str(index)} for index in range(100)]
    train, test = split_train_test(commits, train_ratio=0.8)
    assert len(train) == 80 and len(test) == 20
    with pytest.raises(LanguageProfileEvalError):
        split_train_test(commits, train_ratio=0.1)
    with pytest.raises(LanguageProfileEvalError):
        split_train_test(commits[:1], train_ratio=0.8)


def test_evaluate_reports_profiled_gain(tmp_path: Path):
    # 80% of history leans on the phrase "明令禁止", and the frozen set
    # rewards exactly that disambiguation.
    history = ["明令禁止"] * 10 + ["普通句子"] * 4
    database = _make_history(tmp_path, history)
    frozen = tmp_path / "frozen.jsonl"
    frozen.write_text(
        "\n".join(
            [
                json.dumps(
                    _sample(0, "请执行这条", ["命令", "明令"], "明令"),
                    ensure_ascii=False,
                ),
                json.dumps(
                    _sample(1, "给数据库建", ["索引", "所以"], "索引"),
                    ensure_ascii=False,
                ),
            ]
        ),
        encoding="utf-8",
    )
    model, _report = train_ngram_model(
        _train_samples(), dataset_sha256="test-dataset"
    )
    baseline_path = tmp_path / "baseline.json.gz"
    write_ngram_model_atomic(baseline_path, model)

    report = evaluate(
        history_db=database,
        frozen_samples_path=frozen,
        baseline_model_path=baseline_path,
        train_ratio=0.8,
    )

    assert report["train_commits"] == 11
    assert report["test_commits"] == 3
    assert report["frozen_samples"] == 2
    assert (
        0.0 <= float(report["baseline_top1_accuracy"]) <= 1.0
    )
    assert (
        0.0 <= float(report["profiled_top1_accuracy"]) <= 1.0
    )
    assert isinstance(report["net_gain_points"], float)
    assert 0.0 <= float(report["phrase_hit_rate"]) <= 1.0
    assert report["phrase_hits"] >= 0
    assert report["user_lm_mean_log_prob_train"] is not None


def test_evaluate_on_empty_history_fails_cleanly(tmp_path: Path):
    database = _make_history(tmp_path, [])
    frozen = tmp_path / "frozen.jsonl"
    frozen.write_text(
        json.dumps(_sample(0, "ctx", ["甲", "乙"], "甲")),
        encoding="utf-8",
    )
    model, _ = train_ngram_model(
        _train_samples(), dataset_sha256="test-dataset"
    )
    baseline_path = tmp_path / "baseline.json.gz"
    write_ngram_model_atomic(baseline_path, model)

    with pytest.raises(LanguageProfileEvalError):
        evaluate(
            history_db=database,
            frozen_samples_path=frozen,
            baseline_model_path=baseline_path,
        )
