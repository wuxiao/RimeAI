"""SFT distillation dataset builder tests (tools/build_sft_dataset.py)."""

from __future__ import annotations

import importlib.util
import json
import sqlite3
import sys
from pathlib import Path

import pytest

TOOL_PATH = (
    Path(__file__).resolve().parent.parent / "tools" / "build_sft_dataset.py"
)
spec = importlib.util.spec_from_file_location("build_sft_dataset", TOOL_PATH)
assert spec is not None and spec.loader is not None
builder = importlib.util.module_from_spec(spec)
sys.modules.setdefault("build_sft_dataset", builder)
spec.loader.exec_module(builder)


def make_daemon_db(
    path: Path, rows: list[tuple[int, str, str, str, str, str]]
) -> Path:
    with sqlite3.connect(path) as db:
        db.executescript(
            """
            CREATE TABLE decisions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                created_at_ms INTEGER NOT NULL,
                source TEXT NOT NULL,
                request_id TEXT NOT NULL,
                pinyin TEXT NOT NULL,
                suggestion TEXT NOT NULL,
                outcome TEXT NOT NULL DEFAULT 'pending'
            );
            """
        )
        db.executemany(
            "INSERT INTO decisions(created_at_ms, source, request_id,"
            " pinyin, suggestion, outcome) VALUES (?, ?, ?, ?, ?, ?)",
            rows,
        )
    return path


def make_cloud_db(
    path: Path,
    rows: list[tuple[int, str, str, str, str, str, str]],
) -> Path:
    with sqlite3.connect(path) as db:
        db.executescript(
            """
            CREATE TABLE decisions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                created_at_ms INTEGER NOT NULL,
                model_id TEXT NOT NULL,
                request_id TEXT,
                pinyin TEXT NOT NULL,
                decision TEXT NOT NULL,
                text TEXT NOT NULL,
                outcome TEXT NOT NULL DEFAULT 'pending'
            );
            """
        )
        db.executemany(
            "INSERT INTO decisions(created_at_ms, model_id, request_id,"
            " pinyin, decision, text, outcome)"
            " VALUES (?, ?, ?, ?, ?, ?, ?)",
            rows,
        )
    return path


def make_history_db(
    path: Path, rows: list[tuple[int, str, str]]
) -> Path:
    with sqlite3.connect(path) as db:
        db.executescript(
            """
            CREATE TABLE history_commits (
                id TEXT PRIMARY KEY,
                committed_at_ms INTEGER NOT NULL,
                pinyin TEXT NOT NULL,
                committed_text TEXT NOT NULL
            );
            """
        )
        db.executemany(
            "INSERT INTO history_commits(id, committed_at_ms, pinyin,"
            " committed_text) VALUES (?, ?, ?, ?)",
            [
                (f"00000000-0000-0000-0000-{index:012d}", *row)
                for index, row in enumerate(rows)
            ],
        )
    return path


def make_eval_dataset(path: Path, *pinyin_by_split: tuple[str, str]) -> Path:
    lines = [
        json.dumps(
            {"schema_version": 1, "split": split, "pinyin": pinyin}
        )
        for split, pinyin in pinyin_by_split
    ]
    path.write_text("".join(line + "\n" for line in lines), encoding="utf-8")
    return path


def test_adopted_decision_becomes_chosen_only_pair(tmp_path: Path):
    daemon = make_daemon_db(
        tmp_path / "decision_log.db",
        [(1_000, "neural_late", "r1", "mingling", "命令", "adopted")],
    )
    pairs, stats = builder.build_pairs(
        builder.load_decision_rows(daemon), [], []
    )
    assert stats["rows"] == 1
    pair = pairs[0]
    assert pair["chosen"] == "命令"
    assert pair["rejected"] is None
    assert pair["weight"] == 1.0
    assert pair["source"] == "daemon/neural_late/adopted"


def test_rejected_joins_history_for_the_chosen_side(tmp_path: Path):
    daemon = make_daemon_db(
        tmp_path / "decision_log.db",
        [(1_000, "local_sentence", "r1", "mingling", "明令", "rejected")],
    )
    history = make_history_db(
        tmp_path / "history.sqlite3",
        [(30_000, "mingling", "命令")],
    )
    pairs, stats = builder.build_pairs(
        builder.load_decision_rows(daemon),
        [],
        builder.load_history_commits(history),
    )
    assert stats["rows"] == 1
    pair = pairs[0]
    assert pair["chosen"] == "命令"
    assert pair["rejected"] == "明令"
    assert pair["weight"] == builder.WEIGHT_REJECTED_WITH_HISTORY


def test_rejected_outside_window_is_unresolved(tmp_path: Path):
    daemon = make_daemon_db(
        tmp_path / "decision_log.db",
        [(1_000, "local_rank", "r1", "mingling", "明令", "rejected")],
    )
    history = make_history_db(
        tmp_path / "history.sqlite3",
        # 61s later: outside the 60s join window.
        [(1_000 + builder.JOIN_WINDOW_MS + 1_000, "mingling", "命令")],
    )
    pairs, stats = builder.build_pairs(
        builder.load_decision_rows(daemon),
        [],
        builder.load_history_commits(history),
    )
    assert pairs == []
    assert stats["unresolved_rejected"] == 1


def test_pending_and_superseded_rows_are_skipped(tmp_path: Path):
    daemon = make_daemon_db(
        tmp_path / "decision_log.db",
        [
            (1_000, "local_rank", "r1", "a", "甲", "pending"),
            (2_000, "local_sentence", "r2", "b", "乙", "superseded"),
        ],
    )
    pairs, stats = builder.build_pairs(
        builder.load_decision_rows(daemon), [], []
    )
    assert pairs == []
    assert stats["pending_skipped"] == 1
    assert stats["superseded_skipped"] == 1


def test_cloud_rows_only_emit_adopted_generates(tmp_path: Path):
    cloud = make_cloud_db(
        tmp_path / "cloud-decisions.db",
        [
            (1_000, "glm-5.3-flash", "c1", "niihao", "generate", "你好", "adopted"),
            (2_000, "glm-5.3-flash", "c2", "ta", "abstain", "", "expired"),
            (3_000, "glm-5.3-flash", "c3", "ma", "generate", "吗", "rejected"),
        ],
    )
    pairs, stats = builder.build_pairs(
        [], builder.load_cloud_rows(cloud), []
    )
    assert stats["rows"] == 1
    assert pairs[0]["chosen"] == "你好"
    assert pairs[0]["source"] == "broker/cloud/adopted"
    assert stats["cloud_abstain_skipped"] == 1
    assert stats["cloud_unadopted_skipped"] == 1


def test_unsupported_daemon_sources_are_skipped(tmp_path: Path):
    daemon = make_daemon_db(
        tmp_path / "decision_log.db",
        [(1_000, "continuation", "r1", "a", "甲", "adopted")],
    )
    _, stats = builder.build_pairs(
        builder.load_decision_rows(daemon), [], []
    )
    assert stats["unsupported_source_skipped"] == 1


def test_duplicates_collapse_and_counts_land_in_stats(tmp_path: Path):
    daemon = make_daemon_db(
        tmp_path / "decision_log.db",
        [
            (1_000, "local_rank", "r1", "mingling", "命令", "adopted"),
            (2_000, "neural_late", "r2", "mingling", "命令", "adopted"),
        ],
    )
    _, stats = builder.build_pairs(
        builder.load_decision_rows(daemon), [], []
    )
    assert stats["rows"] == 1
    assert stats["duplicates_dropped"] == 1
    assert stats["unique_pinyin"] == 1
    assert stats["by_source"] == {"daemon/local_rank/adopted": 1}


def test_leak_check_detects_validation_and_test_overlap(tmp_path: Path):
    pairs = [
        {"pinyin": "shangxiawen", "chosen": "上下文",
         "rejected": None, "weight": 1.0, "source": "x",
         "_created_at_ms": 1},
    ]
    keys = {"shangxiawen"}
    assert builder.leak_pinyin(pairs, keys) == {"shangxiawen"}


def test_eval_pinyin_set_covers_validation_and_test_only(tmp_path: Path):
    eval_path = make_eval_dataset(
        tmp_path / "eval.jsonl",
        ("train", "xunlian"),
        ("validation", "yanzheng"),
        ("test", "ceshi"),
    )
    keys = builder.eval_pinyin_set(eval_path)
    assert keys == {"yanzheng", "ceshi"}


def test_eval_pinyin_set_rejects_corrupt_files(tmp_path: Path):
    corrupt = tmp_path / "eval.jsonl"
    corrupt.write_text("not json\n", encoding="utf-8")
    with pytest.raises(SystemExit, match="not valid jsonl"):
        builder.eval_pinyin_set(corrupt)


def test_main_writes_private_files_and_lock(tmp_path: Path):
    daemon = make_daemon_db(
        tmp_path / "decision_log.db",
        [(1_000, "local_rank", "r1", "mingling", "命令", "adopted")],
    )
    eval_path = make_eval_dataset(
        tmp_path / "eval.jsonl", ("test", "wuguan")
    )
    output = tmp_path / "out"
    code = builder.main(
        [
            "--decision-log", str(daemon),
            "--eval-dataset", str(eval_path),
            "--output-dir", str(output),
            "--min-samples", "1",
        ]
    )
    assert code == 0
    jsonl = output / "sft-constrained-v1.jsonl"
    lock_path = output / "sft-constrained-v1.lock.json"
    rows = [
        json.loads(line)
        for line in jsonl.read_text(encoding="utf-8").splitlines()
    ]
    assert rows == [
        {
            "id": "sft-000001",
            "pinyin": "mingling",
            "chosen": "命令",
            "rejected": None,
            "weight": 1.0,
            "source": "daemon/local_rank/adopted",
        }
    ]
    lock = json.loads(lock_path.read_text(encoding="utf-8"))
    assert lock["usable"] is True
    assert lock["sha256"] == builder.sha256_file(jsonl)
    assert lock["counts"]["rows"] == 1
    assert lock["generator"]["version"] == builder.VERSION
    assert lock["leak_check"]["overlapped_pinyin"] == []
    assert oct(jsonl.stat().st_mode & 0o777) == "0o600"
    assert oct(lock_path.stat().st_mode & 0o777) == "0o600"


def test_main_below_min_samples_reports_and_marks_unusable(tmp_path: Path):
    daemon = make_daemon_db(
        tmp_path / "decision_log.db",
        [(1_000, "local_rank", "r1", "mingling", "命令", "adopted")],
    )
    eval_path = make_eval_dataset(
        tmp_path / "eval.jsonl", ("test", "wuguan")
    )
    output = tmp_path / "out"
    code = builder.main(
        [
            "--decision-log", str(daemon),
            "--eval-dataset", str(eval_path),
            "--output-dir", str(output),
            "--min-samples", "10",
        ]
    )
    assert code == builder.EXIT_USABLE
    lock = json.loads(
        (output / "sft-constrained-v1.lock.json").read_text(encoding="utf-8")
    )
    assert lock["usable"] is False
    assert lock["min_samples"] == 10


def test_main_aborts_on_leak_without_writing(tmp_path: Path):
    daemon = make_daemon_db(
        tmp_path / "decision_log.db",
        [(1_000, "local_rank", "r1", "ceshi", "测试", "adopted")],
    )
    eval_path = make_eval_dataset(
        tmp_path / "eval.jsonl", ("test", "ceshi")
    )
    output = tmp_path / "out"
    code = builder.main(
        [
            "--decision-log", str(daemon),
            "--eval-dataset", str(eval_path),
            "--output-dir", str(output),
            "--min-samples", "1",
        ]
    )
    assert code == builder.EXIT_LEAK
    assert not (output / "sft-constrained-v1.jsonl").exists()
    assert not (output / "sft-constrained-v1.lock.json").exists()
