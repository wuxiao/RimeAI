"""Broker single-instance lock (flock + pidfile) and per-round semantic
provider tests (P2-7 / P2-1 / P3-3)."""

from __future__ import annotations

import os
from pathlib import Path

import pytest

from rimeai_cloud_broker.instance_lock import SingleInstanceLock


def test_second_instance_cannot_acquire_held_lock(tmp_path: Path):
    first = SingleInstanceLock(tmp_path, name="rimeai-cloud")
    assert first.acquire()
    second = SingleInstanceLock(tmp_path, name="rimeai-cloud")
    assert not second.acquire()
    second.release()  # 未持有锁时 release 必须无害
    first.release()
    third = SingleInstanceLock(tmp_path, name="rimeai-cloud")
    assert third.acquire()
    third.release()


def test_pidfile_records_owner_and_is_removed_on_release(tmp_path: Path):
    lock = SingleInstanceLock(tmp_path, name="rimeai-cloud")
    assert lock.acquire()
    pidfile = tmp_path / "rimeai-cloud.pid"
    assert pidfile.exists()
    assert int(pidfile.read_text(encoding="utf-8").strip()) == os.getpid()
    lock.release()
    assert not pidfile.exists()


def test_stale_pidfile_does_not_block_reclaim(tmp_path: Path):
    # 崩溃留下的 pidfile 不得阻塞重新获取：flock 语义随进程消亡释放，
    # pidfile 只是诊断产物。
    (tmp_path / "rimeai-cloud.pid").write_text("99999999\n")
    lock = SingleInstanceLock(tmp_path, name="rimeai-cloud")
    assert lock.acquire()
    lock.release()


def test_scheduler_evaluates_semantic_provider_each_round():
    # P2-1 + P3-3：语义 consolidator 由 provider 逐轮给出，凭据/域映射
    # 变化在下一轮即生效，不再沿用进程启动时的一次性决定。
    from collections.abc import Sequence

    from rimeai_daemon.consolidation import (
        ConsolidationPipeline,
        ConsolidationReport,
        IdleConsolidationScheduler,
        RawCommit,
        SemanticConsolidator,
    )

    calls = 0
    consolidators_seen: list[SemanticConsolidator | None] = []

    class StubPipeline(ConsolidationPipeline):
        def __init__(self) -> None:
            self.rounds = 0

        def run_once(self, *, semantic_consolidator=None):
            self.rounds += 1
            consolidators_seen.append(semantic_consolidator)
            return ConsolidationReport()

    class FakeClock:
        def __init__(self) -> None:
            self.now = 0.0

        def __call__(self) -> float:
            return self.now

    def provider() -> SemanticConsolidator | None:
        nonlocal calls
        calls += 1

        def consolidator(batch: Sequence[RawCommit]) -> bool:
            return True

        return consolidator  # 每轮一个新对象，证明不是缓存复用

    clock = FakeClock()
    pipeline = StubPipeline()
    scheduler = IdleConsolidationScheduler(
        pipeline,
        idle_seconds=0.1,
        min_round_interval=0.1,
        clock=clock,
        semantic_consolidator_provider=provider,
    )
    clock.now += 1.0
    scheduler.run_round()
    clock.now += 1.0
    scheduler.run_round()
    assert calls == 2
    assert consolidators_seen[0] is not consolidators_seen[1]


def _phrasebook_db(path: Path) -> None:
    import sqlite3

    with sqlite3.connect(path) as db:
        db.execute(
            "CREATE TABLE domain_map ("
            " bundle_id TEXT PRIMARY KEY, domain TEXT NOT NULL)"
        )
        db.execute(
            "INSERT INTO domain_map(bundle_id, domain)"
            " VALUES('com.example.app', 'work')"
        )


def test_provider_reevaluates_credentials_each_round(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
):
    # P3-3：运行中加入/修复 cloud.env，下一轮即生效，无需重启 broker。
    import rimeai_cloud_broker.__main__ as broker_main

    state = {"key": ""}
    monkeypatch.setattr(
        broker_main, "_usable_cloud_api_key", lambda: state["key"]
    )
    phrasebook = tmp_path / "phrasebook.sqlite3"
    _phrasebook_db(phrasebook)
    transport = lambda *a, **k: {}  # noqa: E731
    provider = broker_main._semantic_consolidator_provider(
        transport,
        enabled=True,
        profile_directory=tmp_path / "profiles",
        phrasebook_db=phrasebook,
    )
    assert provider() is None
    state["key"] = "sk-live"
    assert provider() is not None
    state["key"] = ""
    assert provider() is None


def test_provider_rebuilds_domain_resolver_each_round(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
):
    # P2-1：改名/新增映射下一轮生效——provider 每轮重建 resolver 缓存。
    import sqlite3

    import rimeai_cloud_broker.__main__ as broker_main

    monkeypatch.setattr(
        broker_main, "_usable_cloud_api_key", lambda: "sk-live"
    )
    phrasebook = tmp_path / "phrasebook.sqlite3"
    _phrasebook_db(phrasebook)
    completion = {
        "choices": [
            {
                "message": {
                    "role": "assistant",
                    "content": '{"register":["casual"]}',
                },
                "finish_reason": "stop",
            }
        ]
    }

    def transport(*args, **kwargs):
        return completion

    provider = broker_main._semantic_consolidator_provider(
        transport,
        enabled=True,
        profile_directory=tmp_path / "profiles",
        phrasebook_db=phrasebook,
    )

    class Commit:
        bundle_id = "com.example.app"
        committed_text = "口径先对齐"

    consolidator = provider()
    assert consolidator is not None
    assert consolidator([Commit()])
    assert (tmp_path / "profiles" / "profile-work.json").exists()

    with sqlite3.connect(phrasebook) as db:
        db.execute(
            "UPDATE domain_map SET domain = 'chat'"
            " WHERE bundle_id = 'com.example.app'"
        )
    consolidator = provider()
    assert consolidator is not None
    assert consolidator([Commit()])
    assert (tmp_path / "profiles" / "profile-chat.json").exists()
