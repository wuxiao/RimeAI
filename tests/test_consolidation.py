"""Tests for the idle consolidation pipeline (LP-004)."""

from __future__ import annotations

import contextlib
import sqlite3
import time
from collections.abc import Sequence
from pathlib import Path

import pytest

from rimeai_daemon.consolidation import (
    ConsolidationError,
    ConsolidationPaths,
    ConsolidationPipeline,
    ConsolidationReport,
    IdleConsolidationScheduler,
    RawCommit,
    phrase_entry_id,
)
from rimeai_daemon.user_lm import UserLanguageModel

DAY_MS = 86_400_000

HISTORY_DDL = """
PRAGMA journal_mode=WAL;
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
CREATE INDEX history_commits_time ON history_commits(committed_at_ms);
CREATE TABLE embedding_jobs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    commit_id TEXT NOT NULL UNIQUE
        REFERENCES history_commits(id) ON DELETE CASCADE,
    status TEXT NOT NULL DEFAULT 'pending',
    attempts INTEGER NOT NULL DEFAULT 0,
    next_attempt_ms INTEGER NOT NULL DEFAULT 0,
    created_at_ms INTEGER NOT NULL
);
CREATE TABLE consolidation_state (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    statistics_watermark INTEGER NOT NULL DEFAULT 0,
    semantic_watermark INTEGER NOT NULL DEFAULT 0,
    updated_at_ms INTEGER NOT NULL DEFAULT 0
);
INSERT INTO consolidation_state(id) VALUES (1);
CREATE TABLE history_metrics (
    key TEXT PRIMARY KEY NOT NULL,
    value INTEGER NOT NULL DEFAULT 0
);
"""

FTS_DDL = """
CREATE VIRTUAL TABLE history_fts USING fts5(
    commit_id UNINDEXED,
    committed_text,
    pinyin,
    tokenize='trigram'
);
"""

PHRASEBOOK_DDL = """
PRAGMA journal_mode=WAL;
CREATE TABLE phrasebook_metadata (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    generation INTEGER NOT NULL
);
INSERT INTO phrasebook_metadata(id, generation) VALUES (1, 0);
CREATE TABLE phrasebook_entries (
    id TEXT PRIMARY KEY NOT NULL,
    domain TEXT NOT NULL,
    text TEXT NOT NULL,
    pinyin_keys TEXT NOT NULL,
    count INTEGER NOT NULL,
    first_seen_ms INTEGER NOT NULL,
    last_used_ms INTEGER NOT NULL,
    source TEXT NOT NULL,
    protected INTEGER NOT NULL DEFAULT 0,
    UNIQUE(domain, text)
);
CREATE INDEX phrasebook_entries_domain_pinyin
ON phrasebook_entries(domain, pinyin_keys);
CREATE TABLE domain_map (
    bundle_id TEXT PRIMARY KEY NOT NULL,
    domain TEXT NOT NULL
);
CREATE TABLE domain_stats (
    domain TEXT PRIMARY KEY NOT NULL,
    commit_count INTEGER NOT NULL DEFAULT 0,
    updated_at_ms INTEGER NOT NULL DEFAULT 0
);
"""


def make_layout(tmp_path: Path) -> ConsolidationPaths:
    profile = tmp_path / "language_profile"
    profile.mkdir()
    history = tmp_path / "history.sqlite3"
    phrasebook = profile / "phrasebook.sqlite3"
    with sqlite3.connect(history) as db:
        db.executescript(HISTORY_DDL)
        with contextlib.suppress(sqlite3.OperationalError):
            db.executescript(FTS_DDL)
    with sqlite3.connect(phrasebook) as db:
        db.executescript(PHRASEBOOK_DDL)
    return ConsolidationPaths(
        history_db=history,
        phrasebook_db=phrasebook,
        user_lm=profile / "user-lm.json.gz",
    )


def insert_commit(
    paths: ConsolidationPaths,
    *,
    suffix: str,
    age_days: float,
    bundle: str = "com.example.Editor",
    pinyin: str = "ceshi",
    text: str = "测试",
) -> str:
    commit_id = f"00000000-0000-0000-0000-{suffix}"
    at_ms = int(time.time() * 1000 - age_days * DAY_MS)
    with sqlite3.connect(paths.history_db) as db:
        db.execute(
            """
            INSERT INTO history_commits(
                id, committed_at_ms, bundle_id, pinyin,
                committed_text, source
            ) VALUES (?, ?, ?, ?, ?, 'rime_main')
            """,
            (commit_id, at_ms, bundle, pinyin, text),
        )
        with contextlib.suppress(sqlite3.OperationalError):
            db.execute(
                "INSERT INTO history_fts(commit_id, committed_text, pinyin)"
                " VALUES (?, ?, ?)",
                (commit_id, text, pinyin),
            )
    return commit_id


def history_state(paths: ConsolidationPaths) -> dict[str, int]:
    with sqlite3.connect(paths.history_db) as db:
        rows = db.execute(
            "SELECT consolidation_state, COUNT(*) FROM history_commits"
            " GROUP BY consolidation_state"
        ).fetchall()
    return {row[0]: row[1] for row in rows}


def test_skip_path_consolidates_and_prunes(tmp_path: Path):
    paths = make_layout(tmp_path)
    insert_commit(paths, suffix="000000000001", age_days=8, text="接口设计")
    insert_commit(paths, suffix="000000000002", age_days=9, text="接口实现")

    report = ConsolidationPipeline(paths).run_once()

    assert report.considered == 2
    assert report.statistics_done == 2
    assert report.pruned == 2
    assert report.domains == {"global": 2}
    # Raw text is gone and generation advanced exactly once.
    assert history_state(paths) == {}
    with sqlite3.connect(paths.history_db) as db:
        generation = db.execute(
            "SELECT generation FROM history_metadata WHERE id = 1"
        ).fetchone()[0]
        fts_rows = db.execute("SELECT COUNT(*) FROM history_fts").fetchone()[0]
    assert generation == 1
    assert fts_rows == 0
    # L1 phrasebook received both phrases as auto entries.
    with sqlite3.connect(paths.phrasebook_db) as db:
        rows = db.execute(
            "SELECT text, domain, source, protected, count"
            " FROM phrasebook_entries ORDER BY text"
        ).fetchall()
        stats = db.execute(
            "SELECT domain, commit_count FROM domain_stats"
        ).fetchall()
    assert rows == [
        ("接口实现", "global", "auto", 0, 1),
        ("接口设计", "global", "auto", 0, 1),
    ]
    assert dict(stats) == {"global": 2}
    for text, domain, _, _, _ in rows:
        expected = phrase_entry_id(domain, text)
        with sqlite3.connect(paths.phrasebook_db) as db:
            stored = db.execute(
                "SELECT id FROM phrasebook_entries WHERE text = ?",
                (text,),
            ).fetchone()[0]
        assert stored == expected
    # L2 model persisted with both texts.
    model = UserLanguageModel.load(paths.user_lm)
    assert model.domains() == ["global"]
    assert (
        model._domains["global"].characters
        == len("接口设计") + len("接口实现")
    )


def test_recent_commits_stay_in_the_window(tmp_path: Path):
    paths = make_layout(tmp_path)
    insert_commit(paths, suffix="000000000001", age_days=1)

    report = ConsolidationPipeline(paths).run_once()

    assert report.considered == 0
    assert history_state(paths) == {"raw": 1}
    with sqlite3.connect(paths.phrasebook_db) as db:
        count = db.execute(
            "SELECT COUNT(*) FROM phrasebook_entries"
        ).fetchone()[0]
    assert count == 0


def test_cold_start_routes_small_domains_to_global(tmp_path: Path):
    paths = make_layout(tmp_path)
    with sqlite3.connect(paths.phrasebook_db) as db:
        db.execute(
            "INSERT INTO domain_map(bundle_id, domain)"
            " VALUES ('com.example.Work', 'work')"
        )
    for index in range(10):
        insert_commit(
            paths,
            suffix=f"0000000000{index:02d}",
            age_days=8,
            bundle="com.example.Work",
            text="工作术语",
        )

    report = ConsolidationPipeline(paths).run_once()

    # 10 commits < cold-start threshold of 50 -> folded into global.
    assert report.domains == {"global": 10}
    with sqlite3.connect(paths.phrasebook_db) as db:
        domains = db.execute(
            "SELECT DISTINCT domain FROM phrasebook_entries"
        ).fetchall()
        stats = dict(
            db.execute(
                "SELECT domain, commit_count FROM domain_stats"
            ).fetchall()
        )
    assert domains == [("global",)]
    # 短语进 global（冷启动回退），但 mapped 域的 commit 计数照常累加，
    # 否则慢速细流的域永远凑不满冷启动门槛。
    assert stats == {"work": 10}


def test_slow_trickle_domain_graduates_across_batches(tmp_path: Path):
    paths = make_layout(tmp_path)
    with sqlite3.connect(paths.phrasebook_db) as db:
        db.execute(
            "INSERT INTO domain_map(bundle_id, domain)"
            " VALUES ('com.example.Work', 'work')"
        )
    pipeline = ConsolidationPipeline(paths)

    report = ConsolidationReport()
    for round_index in range(5):
        for batch_index in range(10):
            insert_commit(
                paths,
                suffix=f"{round_index:02d}{batch_index:02d}aaaaaa",
                age_days=8,
                bundle="com.example.Work",
                text=f"工作术语{round_index}{batch_index}",
            )
        report = pipeline.run_once()
        if round_index < 4:
            # 累计 10/20/30/40 条仍未过冷启动门槛：全部回退 global。
            assert report.domains == {"global": 10}

    # 第 5 轮：mapped 计数 40 + 本批 10 = 50，不再低于门槛，域毕业。
    assert report.domains == {"work": 10}
    with sqlite3.connect(paths.phrasebook_db) as db:
        stats = dict(
            db.execute(
                "SELECT domain, commit_count FROM domain_stats"
            ).fetchall()
        )
        work_entries = db.execute(
            "SELECT COUNT(*) FROM phrasebook_entries WHERE domain = 'work'"
        ).fetchone()[0]
    assert stats == {"work": 50}
    assert work_entries == 10


def test_warm_domain_keeps_its_own_artifacts(tmp_path: Path):
    paths = make_layout(tmp_path)
    with sqlite3.connect(paths.phrasebook_db) as db:
        db.execute(
            "INSERT INTO domain_map(bundle_id, domain)"
            " VALUES ('com.example.Work', 'work')"
        )
        db.execute(
            "INSERT INTO domain_stats(domain, commit_count, updated_at_ms)"
            " VALUES ('work', 60, 0)"
        )
    insert_commit(
        paths,
        suffix="000000000001",
        age_days=8,
        bundle="com.example.Work",
        text="领域短语",
    )

    report = ConsolidationPipeline(paths).run_once()

    assert report.domains == {"work": 1}
    with sqlite3.connect(paths.phrasebook_db) as db:
        row = db.execute(
            "SELECT domain FROM phrasebook_entries WHERE text = '领域短语'"
        ).fetchone()
        stats = dict(
            db.execute(
                "SELECT domain, commit_count FROM domain_stats"
            ).fetchall()
        )
    assert row == ("work",)
    assert stats["work"] == 61
    model = UserLanguageModel.load(paths.user_lm)
    assert "work" in model.domains()


def test_semantic_consolidator_success_path(tmp_path: Path):
    paths = make_layout(tmp_path)
    insert_commit(paths, suffix="000000000001", age_days=8, text="语义批")

    seen: list[RawCommit] = []
    report = ConsolidationPipeline(paths).run_once(
        semantic_consolidator=lambda batch: bool(seen.extend(batch)) or True
    )

    assert report.semantic_done == 1
    assert report.pruned == 1
    assert [commit.committed_text for commit in seen] == ["语义批"]
    assert history_state(paths) == {}


def test_semantic_consolidator_refusal_keeps_raw_text(tmp_path: Path):
    paths = make_layout(tmp_path)
    insert_commit(paths, suffix="000000000001", age_days=8, text="保留批")

    report = ConsolidationPipeline(paths).run_once(
        semantic_consolidator=lambda batch: False
    )

    assert report.semantic_done == 0
    # Double-delete guard: statistics done but semantic refused, so the
    # raw text must survive for the next round.
    assert report.pruned == 0
    assert history_state(paths) == {"statistics_done": 1}
    with sqlite3.connect(paths.history_db) as db:
        text = db.execute(
            "SELECT committed_text FROM history_commits"
        ).fetchone()[0]
    assert text == "保留批"


def test_semantic_consolidator_failure_is_fail_closed(tmp_path: Path):
    paths = make_layout(tmp_path)
    insert_commit(paths, suffix="000000000001", age_days=8, text="失败批")

    def failing(batch: Sequence[RawCommit]) -> bool:
        del batch
        raise RuntimeError("LLM unavailable")

    with pytest.raises(ConsolidationError):
        ConsolidationPipeline(paths).run_once(
            semantic_consolidator=failing
        )

    # Nothing marked, nothing pruned; statistics may already be done from
    # this round, but raw text is intact and no watermark advanced to
    # semantic, so a later round can retry.
    assert "consolidated" not in history_state(paths)
    with sqlite3.connect(paths.history_db) as db:
        states = db.execute(
            "SELECT DISTINCT consolidation_state FROM history_commits"
        ).fetchall()
        watermark = db.execute(
            "SELECT semantic_watermark FROM consolidation_state WHERE id = 1"
        ).fetchone()[0]
    assert states != []
    assert watermark == 0


def test_failed_semantic_batch_is_retried_next_round(tmp_path: Path):
    """L3 失败的批次下一轮必须重新进入语义阶段，且统计不得重复计数。"""
    paths = make_layout(tmp_path)
    insert_commit(paths, suffix="00000000000a", age_days=9, text="失败重试甲")
    pipeline = ConsolidationPipeline(paths)

    def failing(batch: Sequence[RawCommit]) -> bool:
        del batch
        raise RuntimeError("LLM unavailable")

    with pytest.raises(ConsolidationError):
        pipeline.run_once(semantic_consolidator=failing)
    assert history_state(paths) == {"statistics_done": 1}

    seen: list[str] = []
    report = pipeline.run_once(
        semantic_consolidator=lambda batch: bool(
            seen.extend(c.committed_text for c in batch)
        )
        or True
    )

    assert seen == ["失败重试甲"]
    assert report.semantic_done == 1
    assert history_state(paths) == {}
    with sqlite3.connect(paths.phrasebook_db) as db:
        count = db.execute(
            "SELECT count FROM phrasebook_entries WHERE text = '失败重试甲'"
        ).fetchone()[0]
    assert count == 1


def test_poison_pill_batch_blocks_l3_but_never_leaks_to_prune(
    tmp_path: Path,
):
    """毒丸批连坐后续批次一起失败，但未过 L3 的原文绝不被越级剪枝。"""
    paths = make_layout(tmp_path)
    insert_commit(paths, suffix="00000000000b", age_days=9, text="毒丸")
    pipeline = ConsolidationPipeline(paths)

    def poisoned(batch: Sequence[RawCommit]) -> bool:
        if any(c.committed_text == "毒丸" for c in batch):
            raise RuntimeError("bad domain")
        return True

    with pytest.raises(ConsolidationError):
        pipeline.run_once(semantic_consolidator=poisoned)

    insert_commit(paths, suffix="00000000000c", age_days=8, text="正常批")
    with pytest.raises(ConsolidationError):
        pipeline.run_once(semantic_consolidator=poisoned)

    # 双删守卫回归锁：两轮后两行都未经 L3，必须全部存活。
    assert history_state(paths) == {"statistics_done": 2}
    with sqlite3.connect(paths.history_db) as db:
        texts = {
            row[0]
            for row in db.execute("SELECT committed_text FROM history_commits")
        }
    assert texts == {"毒丸", "正常批"}

    # 毒丸解除后下一轮全部完成并淘汰。
    recovered = pipeline.run_once(semantic_consolidator=lambda batch: True)
    assert recovered.semantic_done == 2
    assert history_state(paths) == {}


def test_repeated_runs_are_idempotent(tmp_path: Path):
    paths = make_layout(tmp_path)
    insert_commit(paths, suffix="000000000001", age_days=8, text="幂等")
    pipeline = ConsolidationPipeline(paths)

    first = pipeline.run_once()
    second = pipeline.run_once()

    assert first.pruned == 1
    assert second.considered == 0
    with sqlite3.connect(paths.phrasebook_db) as db:
        count = db.execute(
            "SELECT COUNT(*) FROM phrasebook_entries"
        ).fetchone()[0]
        frequency = db.execute(
            "SELECT count FROM phrasebook_entries"
        ).fetchone()[0]
    assert count == 1
    assert frequency == 1


def test_empty_rounds_do_not_bump_history_generation(tmp_path: Path):
    paths = make_layout(tmp_path)
    insert_commit(paths, suffix="000000000001", age_days=8, text="一次")
    pipeline = ConsolidationPipeline(paths)

    first = pipeline.run_once()
    second = pipeline.run_once()

    assert first.pruned == 1
    assert second.pruned == 0
    with sqlite3.connect(paths.history_db) as db:
        generation = db.execute(
            "SELECT generation FROM history_metadata WHERE id = 1"
        ).fetchone()[0]
    # generation 只在可见历史真正变化时前进：空轮不 bump，否则客户端
    # 的 history_generation 校验与 HNSW 索引匹配会被无谓失效。
    assert generation == 1


def test_transient_semantic_failure_keeps_backlog_and_retries(
    tmp_path: Path,
):
    # 凭据临时故障（语义阶段本轮不可用）不得把 L3 积压判成终态：
    # 原文不删、语义水位线不推进，统计照常；凭据恢复后的下一轮补做
    # L3 摘要并清掉原文。
    paths = make_layout(tmp_path)
    insert_commit(paths, suffix="000000000001", age_days=8, text="待摘要")

    pipeline = ConsolidationPipeline(paths)
    report = pipeline.run_once(semantic_permanently_unavailable=False)

    assert report.statistics_done == 1
    assert report.semantic_done == 0
    assert report.pruned == 0
    # 原文仍在，状态停在 statistics_done（可重试），没有被判终态。
    assert history_state(paths) == {"statistics_done": 1}
    with sqlite3.connect(paths.phrasebook_db) as db:
        entries = db.execute(
            "SELECT COUNT(*) FROM phrasebook_entries"
        ).fetchone()[0]
    # 统计固化仍然发生（L1 已学到）。
    assert entries == 1

    recovered = pipeline.run_once(
        semantic_consolidator=lambda batch: True
    )
    assert recovered.semantic_done == 1
    assert history_state(paths) == {}


def test_permanent_semantic_unavailability_marks_backlog_terminal(
    tmp_path: Path,
):
    # 永久不可用（用户未开启云压缩 / 显式 --no-consolidation）：L3 积压
    # 判终态（skipped）并随原文一起清理，历史库不会无限增长。
    paths = make_layout(tmp_path)
    insert_commit(paths, suffix="000000000001", age_days=8, text="永久跳过")

    report = ConsolidationPipeline(paths).run_once(
        semantic_permanently_unavailable=True
    )

    assert report.pruned == 1
    assert history_state(paths) == {}


def test_fetch_batch_claims_exclusively_across_processes(tmp_path: Path):
    paths = make_layout(tmp_path)
    insert_commit(paths, suffix="000000000001", age_days=8, text="独占")
    insert_commit(paths, suffix="000000000002", age_days=8, text="领取")
    first = ConsolidationPipeline(paths)
    second = ConsolidationPipeline(paths)

    claimed = first._fetch_batch()
    assert len(claimed) == 2
    # 同一批行已被领取：即使另一个进程（误配置双调度器）立即取批，
    # 也拿不到任何行，不可能双重处理。
    assert second._fetch_batch() == []
    assert first._fetch_batch() == []

    # 领取随统计阶段释放：状态推进后不再依赖租约。
    first._mark_statistics(claimed)
    with sqlite3.connect(paths.history_db) as db:
        claims = db.execute(
            "SELECT COUNT(*) FROM consolidation_claims"
        ).fetchone()[0]
    assert claims == 0


def test_expired_claims_become_fetchable_again(tmp_path: Path):
    paths = make_layout(tmp_path)
    insert_commit(paths, suffix="000000000001", age_days=8, text="过期")
    pipeline = ConsolidationPipeline(paths)
    claimed = pipeline._fetch_batch()
    assert len(claimed) == 1

    # 崩溃残留的领取在租约过期后可被下一轮重新领取。
    with sqlite3.connect(paths.history_db) as db:
        db.execute(
            "UPDATE consolidation_claims SET claimed_at_ms = 0"
        )
        db.commit()
    reclaimed = pipeline._fetch_batch()
    assert [commit.id for commit in reclaimed] == [
        commit.id for commit in claimed
    ]


def test_scheduler_idle_gate_defers_rounds_while_activity_recent():
    # broker 的推理流量经 note_activity 刷新空闲期限：键盘活跃时不出轮，
    # 空闲与最小轮间隔同时满足才真正执行固化轮。
    class StubPipeline(ConsolidationPipeline):
        def __init__(self):
            self.rounds = 0

        def run_once(self, *, semantic_consolidator=None, **_kwargs):
            self.rounds += 1
            return ConsolidationReport()

    class FakeClock:
        def __init__(self):
            self.now = 1_000.0

        def __call__(self):
            return self.now

    clock = FakeClock()
    pipeline = StubPipeline()
    scheduler = IdleConsolidationScheduler(
        pipeline,
        idle_seconds=600.0,
        min_round_interval=60.0,
        clock=clock,
    )

    # 未到空闲阈值：不运行。
    assert scheduler.should_run() is False
    clock.now += 599.0
    assert scheduler.should_run() is False

    # 空闲达标后一条推理流量即重置空闲期限。
    clock.now += 2.0
    assert scheduler.should_run() is True
    scheduler.note_activity()
    assert scheduler.should_run() is False

    # 流量之后再次空闲：空闲与最小轮间隔都满足，出轮。
    clock.now += 601.0
    assert scheduler.should_run() is True
    report = scheduler.run_round()
    assert isinstance(report, ConsolidationReport)
    assert pipeline.rounds == 1

    # 轮后最小间隔内不再出轮；新的活动再次推迟空闲窗口。
    clock.now += 610.0
    assert scheduler.should_run() is True
    scheduler.note_activity()
    assert scheduler.should_run() is False
    scheduler.run_round()
    assert pipeline.rounds == 2
