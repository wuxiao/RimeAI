#!/usr/bin/env python3
"""Build the frozen SFT distillation dataset (LM-004).

Reads the local sensing databases decided on 2026-10-21 —
  * daemon  ``language_profile/decision_log.db``   (display events)
  * broker  ``language_profile/cloud-decisions.db`` (teacher decisions)
  * optional ``History/history.sqlite3`` (final committed text, used to
    resolve the chosen side of rejected suggestions: the user's actual
    commit for the same pinyin within a bounded time window)
and emits a frozen preference dataset
``{id, pinyin, chosen, rejected, weight, source}`` plus a lock file
binding the dataset sha256, generator version, source interval and
count/dedup statistics (design: CONTINUOUS_OPTIMIZATION_LOOP_DESIGN §4
phase A, LM-004).

Privacy contract: explicit user invocation only; the output files are
written 0600 (same posture as the language-profile export). Nothing is
uploaded — the jsonl is the local training asset.

Fail-closed leak check: pinyin keys that overlap the frozen evaluation
set's validation+test splits are DROPPED from the dataset (never
written), the drop is recorded in the lock's leak_check, and the build
continues. Real-use data inevitably contains high-frequency pinyin that
also occurs in the evaluation set (first production run: 14/227 rows);
dropping the rows keeps evaluation integrity intact while the rest of
the corpus stays usable. (v1 semantics — abort with exit 4 and write
nothing — was retired after that run; see the lock's leak_check policy
field.)

Minimum viable scale: when the deduplicated row count is below
--min-samples the build still writes the outputs for inspection but
marks ``usable: false`` in the lock and exits 3 — "insufficient data,
do not start training" is a report, not a hard error.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

VERSION = 2
DATASET_NAME = "sft-constrained-v1"
DEFAULT_EVAL_DATASET = (
    Path(__file__).resolve().parents[1]
    / ".rimeai"
    / "datasets"
    / "p0-librime-1.17.0-luna-simp.jsonl"
)
DEFAULT_MIN_SAMPLES = 1_000
# A rejected suggestion's "chosen" side comes from a history join, so
# its evidence is weaker than an explicit adoption.
WEIGHT_ADOPTED = 1.0
WEIGHT_REJECTED_WITH_HISTORY = 0.7
# The commit that answers a rejected suggestion lands within this
# window after the decision was recorded (compositions are short).
JOIN_WINDOW_MS = 60_000
DAEMON_SOURCES = ("local_rank", "local_sentence", "neural_late")
EXIT_OK = 0
EXIT_USABLE = 3  # built, but below the minimum-viable scale
EXIT_LEAK = 4  # evaluation-set overlap; nothing written


def load_decision_rows(path: Path) -> list[dict[str, Any]]:
    with sqlite3.connect(path) as db:
        rows = db.execute(
            "SELECT created_at_ms, source, request_id, pinyin,"
            " suggestion, outcome FROM decisions ORDER BY created_at_ms,"
            " id"
        ).fetchall()
    return [
        {
            "created_at_ms": row[0],
            "source": row[1],
            "request_id": row[2],
            "pinyin": row[3],
            "suggestion": row[4],
            "outcome": row[5],
        }
        for row in rows
    ]


def load_teacher_rows(path: Path) -> list[dict[str, Any]]:
    """Rows from tools/teacher_synthesis.py output (jsonl). Field
    validation happens in build_pairs so one bad line only drops
    itself, never the whole mix."""
    rows: list[dict[str, Any]] = []
    with path.open(encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
            except ValueError:
                continue
            if isinstance(record, dict):
                rows.append(record)
    return rows


def load_cloud_rows(path: Path) -> list[dict[str, Any]]:
    with sqlite3.connect(path) as db:
        rows = db.execute(
            "SELECT created_at_ms, model_id, request_id, pinyin,"
            " decision, text, outcome FROM decisions"
            " ORDER BY created_at_ms, id"
        ).fetchall()
    return [
        {
            "created_at_ms": row[0],
            "model_id": row[1],
            "request_id": row[2],
            "pinyin": row[3],
            "decision": row[4],
            "text": row[5],
            "outcome": row[6],
        }
        for row in rows
    ]


def load_history_commits(path: Path) -> list[dict[str, Any]]:
    with sqlite3.connect(path) as db:
        rows = db.execute(
            "SELECT committed_at_ms, pinyin, committed_text"
            " FROM history_commits ORDER BY committed_at_ms"
        ).fetchall()
    return [
        {
            "committed_at_ms": row[0],
            "pinyin": row[1],
            "committed_text": row[2],
        }
        for row in rows
    ]


def eval_pinyin_set(path: Path) -> set[str]:
    """Pinyin keys of the validation+test splits of the frozen
    evaluation set — train-split overlap is training data, not a
    leak."""
    keys: set[str] = set()
    with path.open(encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, start=1):
            if not line.strip():
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError as error:
                raise SystemExit(
                    f"{path}:{line_number}: frozen evaluation set is "
                    f"not valid jsonl ({error}); refusing to leak-check "
                    "against a corrupted file"
                ) from error
            if row.get("split") in {"validation", "test"}:
                pinyin = row.get("pinyin")
                if isinstance(pinyin, str) and pinyin:
                    keys.add(pinyin)
    return keys


def _history_lookup_index(
    commits: list[dict[str, Any]],
) -> dict[str, list[int]]:
    index: dict[str, list[int]] = {}
    for position, commit in enumerate(commits):
        index.setdefault(commit["pinyin"], []).append(position)
    return index


def _resolve_chosen(
    commit_index: dict[str, list[int]],
    commits: list[dict[str, Any]],
    pinyin: str,
    created_at_ms: int,
) -> str | None:
    """Nearest commit with the same pinyin inside the join window."""
    for position in commit_index.get(pinyin, ()):
        delta = commits[position]["committed_at_ms"] - created_at_ms
        if 0 <= delta <= JOIN_WINDOW_MS:
            return commits[position]["committed_text"]
    return None


def build_pairs(
    decision_rows: list[dict[str, Any]],
    cloud_rows: list[dict[str, Any]],
    history_rows: list[dict[str, Any]],
    teacher_rows: list[dict[str, Any]] | None = None,
) -> tuple[list[dict[str, Any]], dict[str, int]]:
    """Builds (pairs, stats); pairs carry a private ``_created_at_ms``
    for deterministic ordering, stripped before writing."""
    commit_index = _history_lookup_index(history_rows)
    stats: dict[str, int] = {
        "pending_skipped": 0,
        "superseded_skipped": 0,
        "unresolved_rejected": 0,
        "cloud_abstain_skipped": 0,
        "cloud_unadopted_skipped": 0,
        "unsupported_source_skipped": 0,
        "duplicates_dropped": 0,
        "teacher_rows_loaded": 0,
        "teacher_invalid_dropped": 0,
    }
    candidates: list[dict[str, Any]] = []

    def emit(
        *, pinyin: str, chosen: str, rejected: str | None,
        weight: float, source: str, created_at_ms: int,
    ) -> None:
        candidates.append(
            {
                "pinyin": pinyin,
                "chosen": chosen,
                "rejected": rejected,
                "weight": weight,
                "source": source,
                "_created_at_ms": created_at_ms,
            }
        )

    for row in decision_rows:
        source, outcome = row["source"], row["outcome"]
        if source not in DAEMON_SOURCES:
            stats["unsupported_source_skipped"] += 1
            continue
        if outcome == "pending":
            stats["pending_skipped"] += 1
            continue
        if outcome == "superseded":
            # Display-order artifact, not a preference signal.
            stats["superseded_skipped"] += 1
            continue
        if outcome == "adopted":
            emit(
                pinyin=row["pinyin"],
                chosen=row["suggestion"],
                rejected=None,
                weight=WEIGHT_ADOPTED,
                source=f"daemon/{source}/adopted",
                created_at_ms=row["created_at_ms"],
            )
            continue
        # rejected / expired / ignored: the chosen side is whatever the
        # user actually committed for the same pinyin nearby.
        chosen = _resolve_chosen(
            commit_index, history_rows, row["pinyin"], row["created_at_ms"]
        )
        if chosen is None:
            stats["unresolved_rejected"] += 1
            continue
        emit(
            pinyin=row["pinyin"],
            chosen=chosen,
            rejected=row["suggestion"],
            weight=WEIGHT_REJECTED_WITH_HISTORY,
            source=f"daemon/{source}/{outcome}",
            created_at_ms=row["created_at_ms"],
        )

    for row in cloud_rows:
        if row["decision"] != "generate":
            stats["cloud_abstain_skipped"] += 1
            continue
        if row["outcome"] != "adopted":
            # Teacher positives only in v1: an unadopted generate is a
            # weak negative whose chosen side is ambiguous.
            stats["cloud_unadopted_skipped"] += 1
            continue
        emit(
            pinyin=row["pinyin"],
            chosen=row["text"],
            rejected=None,
            weight=WEIGHT_ADOPTED,
            source="broker/cloud/adopted",
            created_at_ms=row["created_at_ms"],
        )

    # 教师合成行（glm-5.3 序列级，对齐过滤器已在 teacher_synthesis 把
    # 关）：同键与真实数据冲突时真实数据优先（排序第二键，真实在前）。
    for row in teacher_rows or []:
        pinyin, chosen, weight = (
            row.get("pinyin"), row.get("chosen"), row.get("weight"),
        )
        if (
            not isinstance(pinyin, str) or not pinyin
            or not isinstance(chosen, str) or not chosen
            or not isinstance(weight, (int, float))
        ):
            stats["teacher_invalid_dropped"] += 1
            continue
        stats["teacher_rows_loaded"] += 1
        emit(
            pinyin=pinyin,
            chosen=chosen,
            rejected=None,
            weight=float(weight),
            source="teacher_synthesis",
            created_at_ms=int(row.get("created_at_ms", 0)),
        )

    candidates.sort(
        key=lambda pair: (
            pair["_created_at_ms"],
            1 if pair["source"] == "teacher_synthesis" else 0,
        )
    )
    seen: set[tuple[str, str, str | None]] = set()
    pairs: list[dict[str, Any]] = []
    by_source: dict[str, int] = {}
    for pair in candidates:
        key = (pair["pinyin"], pair["chosen"], pair["rejected"])
        if key in seen:
            stats["duplicates_dropped"] += 1
            continue
        seen.add(key)
        by_source[pair["source"]] = by_source.get(pair["source"], 0) + 1
        pairs.append(pair)
    stats["rows"] = len(pairs)
    stats["unique_pinyin"] = len({pair["pinyin"] for pair in pairs})
    stats["by_source"] = by_source  # type: ignore[assignment]
    return pairs, stats


def leak_pinyin(
    pairs: list[dict[str, Any]], eval_keys: set[str]
) -> set[str]:
    return {pair["pinyin"] for pair in pairs} & eval_keys


def _write_private(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8")
    os.chmod(path, 0o600)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 16), b""):
            digest.update(chunk)
    return digest.hexdigest()


def build_outputs(
    pairs: list[dict[str, Any]],
    stats: dict[str, int],
    *,
    output_dir: Path,
    decision_log: Path,
    cloud_decisions: Path | None,
    history_db: Path | None,
    teacher_synthesis: Path | None,
    eval_dataset: Path,
    min_samples: int,
    overlapped: set[str],
) -> dict[str, Any]:
    jsonl_path = output_dir / f"{DATASET_NAME}.jsonl"
    lock_path = output_dir / f"{DATASET_NAME}.lock.json"
    lines = [
        json.dumps(
            {
                "id": f"sft-{index:06d}",
                "pinyin": pair["pinyin"],
                "chosen": pair["chosen"],
                "rejected": pair["rejected"],
                "weight": pair["weight"],
                "source": pair["source"],
            },
            ensure_ascii=False,
            sort_keys=True,
        )
        for index, pair in enumerate(pairs, start=1)
    ]
    _write_private(jsonl_path, "".join(line + "\n" for line in lines))
    timestamps = [pair["_created_at_ms"] for pair in pairs]
    lock: dict[str, Any] = {
        "schema_version": 1,
        "dataset": DATASET_NAME,
        "path": str(jsonl_path),
        "sha256": sha256_file(jsonl_path),
        "generator": {
            "tool": "tools/build_sft_dataset.py",
            "version": VERSION,
        },
        "sources": {
            "decision_log": str(decision_log),
            "cloud_decisions": (
                str(cloud_decisions) if cloud_decisions else None
            ),
            "history_db": str(history_db) if history_db else None,
            "teacher_synthesis": (
                str(teacher_synthesis) if teacher_synthesis else None
            ),
        },
        "interval": {
            "from_created_at_ms": min(timestamps) if timestamps else None,
            "to_created_at_ms": max(timestamps) if timestamps else None,
        },
        "counts": stats,
        "min_samples": min_samples,
        "usable": stats["rows"] >= min_samples,
        "leak_check": {
            "eval_dataset": str(eval_dataset),
            "splits": ["validation", "test"],
            "policy": "dropped",
            "dropped_rows": stats.get("leak_dropped", 0),
            "overlapped_pinyin": sorted(overlapped),
        },
        "generated_at": datetime.now(timezone.utc).isoformat(),
    }
    _write_private(
        lock_path,
        json.dumps(lock, ensure_ascii=False, indent=2, sort_keys=True)
        + "\n",
    )
    return lock


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="build-sft-dataset",
        description="Freeze the LM-002 distillation dataset (LM-004).",
    )
    parser.add_argument(
        "--decision-log", type=Path, required=True,
        help="daemon language_profile/decision_log.db",
    )
    parser.add_argument(
        "--cloud-decisions", type=Path, default=None,
        help="broker language_profile/cloud-decisions.db",
    )
    parser.add_argument(
        "--history-db", type=Path, default=None,
        help="History/history.sqlite3 — resolves the chosen side of "
        "rejected suggestions (same pinyin within the join window)",
    )
    parser.add_argument(
        "--teacher-synthesis", type=Path, default=None,
        help="teacher_synthesis.py jsonl — glm-5.3 sequence-level "
        "teacher rows mixed in (weight from the row, real data wins "
        "on key collision)",
    )
    parser.add_argument(
        "--eval-dataset", type=Path, default=DEFAULT_EVAL_DATASET,
        help="frozen evaluation jsonl for the leak check",
    )
    parser.add_argument(
        "--output-dir", type=Path, default=None,
        help="default: alongside --decision-log",
    )
    parser.add_argument(
        "--min-samples", type=int, default=DEFAULT_MIN_SAMPLES,
        help="minimum viable deduplicated row count (provisional "
        "default; the LM-002 recipe owns the final number)",
    )
    args = parser.parse_args(argv)
    output_dir = args.output_dir or args.decision_log.parent
    output_dir.mkdir(parents=True, exist_ok=True)

    decision_rows = load_decision_rows(args.decision_log)
    cloud_rows = (
        load_cloud_rows(args.cloud_decisions)
        if args.cloud_decisions
        else []
    )
    history_rows = (
        load_history_commits(args.history_db) if args.history_db else []
    )
    teacher_rows = (
        load_teacher_rows(args.teacher_synthesis)
        if args.teacher_synthesis
        else []
    )
    pairs, stats = build_pairs(
        decision_rows, cloud_rows, history_rows, teacher_rows
    )

    eval_keys = eval_pinyin_set(args.eval_dataset)
    overlapped = leak_pinyin(pairs, eval_keys)
    if overlapped:
        # 泄漏防护改为剔除而非整体拒绝：真实使用数据必然含评测集
        # 高频拼音（首跑 14/227），零重叠门在真实数据上永不可过。
        # 剔除保证重叠样本一个不进训练集，评测完整性目标不变。
        dropped = len(overlapped)
        pairs = [p for p in pairs if p["pinyin"] not in overlapped]
        stats["rows"] = len(pairs)
        stats["unique_pinyin"] = len({p["pinyin"] for p in pairs})
        stats["leak_dropped"] = dropped
        print(
            f"leak check: dropped {dropped} rows whose pinyin overlap "
            f"the frozen evaluation set ({args.eval_dataset}) — "
            "examples: " + ", ".join(sorted(overlapped)[:10]),
            file=sys.stderr,
        )

    lock = build_outputs(
        pairs,
        stats,
        output_dir=output_dir,
        decision_log=args.decision_log,
        cloud_decisions=args.cloud_decisions,
        history_db=args.history_db,
        teacher_synthesis=args.teacher_synthesis,
        eval_dataset=args.eval_dataset,
        min_samples=args.min_samples,
        overlapped=overlapped,
    )
    print(
        f"{lock['dataset']}: {stats['rows']} rows "
        f"({stats['unique_pinyin']} unique pinyin) -> "
        f"{lock['path']} (usable={lock['usable']})"
    )
    if not lock["usable"]:
        print(
            f"数据不足：去重后 {stats['rows']} 行 < 最小可用规模 "
            f"{args.min_samples} 行，不启动训练（lock 已标记 "
            "usable=false）",
            file=sys.stderr,
        )
        return EXIT_USABLE
    return EXIT_OK


if __name__ == "__main__":
    raise SystemExit(main())
