"""Time-split evaluation for the language-profile learning layers (LP-008).

Measures what the L1 phrasebook and L2 user LM add on top of the frozen
P0 baseline, using the user's own committed history:

1. condition top-1 on a frozen candidate-rerank dataset, baseline vs
   baseline + L2 rerank (trained from the first `--train-ratio` of
   history, evaluated on the whole frozen set);
2. L1 phrase hit rate on the held-out tail of the history itself;
3. user-LM mean log-probability on train vs held-out tail.

The report is JSON and fully reproducible from the two inputs.
"""

from __future__ import annotations

import argparse
import json
import sqlite3
import sys
import time
from collections.abc import Sequence
from pathlib import Path

from rimeai_cloud_broker.profile import MAX_BATCH_CHARACTERS
from rimeai_daemon.user_lm import UserLanguageModel
from rimeai_runtime.ngram_ranker import NGramRankerModel, load_ngram_model

REPORT_SCHEMA_VERSION = 1


class LanguageProfileEvalError(RuntimeError):
    pass


def load_history_commits(
    history_db: Path, *, maximum_rows: int = 200_000
) -> list[dict[str, str]]:
    """Ordered (oldest first) commits from the plaintext history store."""
    try:
        with sqlite3.connect(
            f"file:{history_db}?mode=ro", uri=True
        ) as db:
            rows = db.execute(
                """
                SELECT committed_at_ms, bundle_id, pinyin, committed_text
                FROM history_commits
                ORDER BY committed_at_ms ASC, rowid ASC
                LIMIT ?
                """,
                (maximum_rows,),
            ).fetchall()
    except sqlite3.Error as error:
        raise LanguageProfileEvalError(
            f"cannot read history database '{history_db}'"
        ) from error
    return [
        {
            "committed_at_ms": str(row[0]),
            "bundle_id": row[1],
            "pinyin": row[2],
            "committed_text": row[3],
        }
        for row in rows
    ]


def load_frozen_samples(path: Path) -> list[dict[str, object]]:
    samples: list[dict[str, object]] = []
    try:
        with path.open(encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                samples.append(json.loads(line))
    except (OSError, json.JSONDecodeError) as error:
        raise LanguageProfileEvalError(
            f"cannot read frozen samples '{path}'"
        ) from error
    if not samples:
        raise LanguageProfileEvalError("frozen sample set is empty")
    return samples


def split_train_test(
    commits: Sequence[dict[str, str]],
    *,
    train_ratio: float,
) -> tuple[list[dict[str, str]], list[dict[str, str]]]:
    if not 0.5 <= train_ratio < 1.0:
        raise LanguageProfileEvalError(
            "train ratio must be within [0.5, 1.0)"
        )
    boundary = int(len(commits) * train_ratio)
    if boundary <= 0 or boundary >= len(commits):
        raise LanguageProfileEvalError(
            "history is too small for the requested split"
        )
    return list(commits[:boundary]), list(commits[boundary:])


def train_user_lm(
    train_commits: Sequence[dict[str, str]],
) -> UserLanguageModel:
    model = UserLanguageModel()
    for commit in train_commits:
        # The cold-start threshold lives in the consolidation loop; the
        # evaluation measures the global upper bound, so all evidence
        # folds into the global pseudo-domain.
        model.update(None, [commit["committed_text"]])
    return model


def train_phrasebook(
    train_commits: Sequence[dict[str, str]],
) -> dict[tuple[str, str], int]:
    phrasebook: dict[tuple[str, str], int] = {}
    for commit in train_commits:
        key = ("global", commit["committed_text"])
        phrasebook[key] = phrasebook.get(key, 0) + 1
    return phrasebook


def _top1_accuracy(
    ranker: NGramRankerModel,
    samples: Sequence[dict[str, object]],
    *,
    user_lm: UserLanguageModel | None,
) -> tuple[float, int, int]:
    hits = 0
    covered = 0
    changes = 0
    for sample in samples:
        candidates = sample.get("candidates")
        gold = sample.get("gold_text")
        context = sample.get("context") or ""
        if not isinstance(candidates, list) or not candidates:
            continue
        if gold not in candidates:
            continue
        covered += 1
        ranking, _ = ranker.rank(
            context=str(context), candidates=list(candidates)
        )
        if user_lm is not None:
            ranking, _ = user_lm.rerank(
                str(context), ranking, domain=UserLanguageModel.GLOBAL_DOMAIN
            )
            if ranking and ranking[0] != next(iter(candidates)):
                changes += 1
        if ranking and ranking[0] == gold:
            hits += 1
    return (hits / covered if covered else 0.0), covered, changes


def _phrase_hit_rate(
    test_commits: Sequence[dict[str, str]],
    phrasebook: dict[tuple[str, str], int],
) -> tuple[float, int]:
    if not test_commits:
        return (0.0, 0)
    hits = sum(
        1
        for commit in test_commits
        if ("global", commit["committed_text"]) in phrasebook
    )
    return hits / len(test_commits), hits


def _mean_log_prob(
    model: UserLanguageModel, commits: Sequence[dict[str, str]]
) -> float | None:
    scores = [
        model.mean_log_prob(
            "", commit["committed_text"], domain=UserLanguageModel.GLOBAL_DOMAIN
        )
        for commit in commits
    ]
    values = [value for value in scores if value is not None]
    if not values:
        return None
    return sum(values) / len(values)


def _baseline_mean_log_prob(
    ranker: NGramRankerModel, commits: Sequence[dict[str, str]]
) -> float | None:
    """Held-out mean log-probability under the frozen P0 model."""
    values = []
    for commit in commits:
        try:
            score = ranker.language_score("", commit["committed_text"])
        except (TypeError, ValueError, ArithmeticError):
            continue
        if score is not None:
            values.append(score)
    if not values:
        return None
    return sum(values) / len(values)


def evaluate(
    *,
    history_db: Path,
    frozen_samples_path: Path,
    baseline_model_path: Path,
    train_ratio: float = 0.8,
) -> dict[str, object]:
    started = time.monotonic()
    commits = load_history_commits(history_db)
    samples = load_frozen_samples(frozen_samples_path)
    train_commits, test_commits = split_train_test(
        commits, train_ratio=train_ratio
    )
    baseline = load_ngram_model(baseline_model_path)

    baseline_top1, covered, _ = _top1_accuracy(
        baseline, samples, user_lm=None
    )
    user_lm = train_user_lm(train_commits)
    phrasebook = train_phrasebook(train_commits)
    profiled_top1, _, rerank_changes = _top1_accuracy(
        baseline, samples, user_lm=user_lm
    )
    hit_rate, hit_count = _phrase_hit_rate(test_commits, phrasebook)
    train_prob = _mean_log_prob(user_lm, train_commits)
    test_prob = _mean_log_prob(user_lm, test_commits)
    baseline_test_prob = _baseline_mean_log_prob(baseline, test_commits)
    learning_gain_nats = (
        test_prob - baseline_test_prob
        if test_prob is not None and baseline_test_prob is not None
        else None
    )
    # L3 云压缩预算对照：评测用的训练语料若存在单条即超批量预算的
    # 上屏文本，生产端会走尾部截断路径；在报告里显式计数，避免评测
    # 结论建立在生产端根本不会原样发送的数据形态上。
    oversized_commits = sum(
        1
        for commit in train_commits
        if len(str(commit["committed_text"])) > MAX_BATCH_CHARACTERS
    )

    return {
        "schema_version": REPORT_SCHEMA_VERSION,
        "history_total_commits": len(commits),
        "train_commits": len(train_commits),
        "test_commits": len(test_commits),
        "frozen_samples": len(samples),
        "train_ratio": train_ratio,
        "baseline_top1_accuracy": round(baseline_top1, 6),
        "profiled_top1_accuracy": round(profiled_top1, 6),
        "net_gain_points": round((profiled_top1 - baseline_top1) * 100, 4),
        "frozen_top1_caveat": (
            "regression monitor only: the P0 baseline was trained on the "
            "frozen corpus, so frozen-set deltas are leakage-dominated; "
            "the learning signal is learning_gain_nats and "
            "phrase_hit_rate on held-out user history"
        ),
        "rerank_order_changes": rerank_changes,
        "covered_samples": covered,
        "phrase_hit_rate": round(hit_rate, 6),
        "phrase_hits": hit_count,
        "user_lm_mean_log_prob_train": (
            round(train_prob, 6) if train_prob is not None else None
        ),
        "user_lm_mean_log_prob_test": (
            round(test_prob, 6) if test_prob is not None else None
        ),
        "baseline_mean_log_prob_test": (
            round(baseline_test_prob, 6)
            if baseline_test_prob is not None
            else None
        ),
        "learning_gain_nats": (
            round(learning_gain_nats, 6)
            if learning_gain_nats is not None
            else None
        ),
        "l3_batch_budget_characters": MAX_BATCH_CHARACTERS,
        "train_commits_exceeding_l3_budget": oversized_commits,
        "elapsed_ms": round((time.monotonic() - started) * 1000, 3),
    }


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="rimeai-language-profile-eval"
    )
    parser.add_argument("--history-db", type=Path, required=True)
    parser.add_argument(
        "--frozen-samples", type=Path, required=True,
        help="P0-format JSONL dataset with candidates and gold_text",
    )
    parser.add_argument("--baseline-model", type=Path, required=True)
    parser.add_argument("--train-ratio", type=float, default=0.8)
    parser.add_argument("--report", type=Path, default=None)
    args = parser.parse_args(argv)
    try:
        report = evaluate(
            history_db=args.history_db,
            frozen_samples_path=args.frozen_samples,
            baseline_model_path=args.baseline_model,
            train_ratio=args.train_ratio,
        )
    except (LanguageProfileEvalError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    payload = json.dumps(
        report, ensure_ascii=False, indent=2, sort_keys=True
    )
    if args.report is not None:
        args.report.write_text(payload + "\n", encoding="utf-8")
    else:
        print(payload)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
