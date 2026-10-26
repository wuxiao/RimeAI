"""Decision log (LM-003): the sensing-layer store and its server wiring."""

from __future__ import annotations

import asyncio
import sqlite3
import tempfile
from pathlib import Path

import pytest
from test_daemon_neural_late import (
    FakeEngine,
    StubNeuralService,
    _hello,
    _infer_message,
    _read_json,
    _write_json,
)

from rimeai_daemon.decision_log import DecisionLog, DecisionLogError
from rimeai_daemon.server import RimeAIDaemonServer


def test_record_writes_pending_row_and_is_idempotent(tmp_path: Path):
    log = DecisionLog(tmp_path / "decision_log.db")
    try:
        assert log.record(
            source="local_rank",
            request_id="req-1",
            composition_id="comp-1",
            revision=3,
            pinyin="mingling",
            suggestion="命令",
            confidence=0.9,
            model_artifact_id="fixture-engine-v1",
            created_at_ms=1_000,
        )
        assert log.flush()
        with sqlite3.connect(tmp_path / "decision_log.db") as db:
            row = db.execute(
                "SELECT source, request_id, outcome, pinyin, suggestion,"
                " confidence FROM decisions"
            ).fetchone()
            assert row == (
                "local_rank",
                "req-1",
                "pending",
                "mingling",
                "命令",
                0.9,
            )
            # Same (source, request_id) never duplicates.
            log.record(
                source="local_rank",
                request_id="req-1",
                composition_id="comp-1",
                revision=3,
                pinyin="mingling",
                suggestion="命令",
                confidence=0.9,
                model_artifact_id="fixture-engine-v1",
            )
            assert log.flush()
            assert db.execute("SELECT COUNT(*) FROM decisions").fetchone()[0] == 1
    finally:
        log.close()


def test_resolve_newest_gets_outcome_older_get_superseded(tmp_path: Path):
    log = DecisionLog(tmp_path / "decision_log.db")
    try:
        for source in ("local_sentence", "neural_late"):
            log.record(
                source=source,
                request_id="req-1",
                composition_id="comp-1",
                revision=3,
                pinyin="mingling",
                suggestion="请执行命令",
                confidence=0.9,
                model_artifact_id="stub:mlx-8bit:v3",
            )
            assert log.flush()
        assert log.resolve("req-1", "adopted", resolved_at_ms=2_000)
        assert log.flush()
        with sqlite3.connect(tmp_path / "decision_log.db") as db:
            # neural_late was recorded second: it is the newest pending
            # row and carries the reported outcome; the sync sentence row
            # was superseded — exactly what the user saw.
            assert db.execute(
                "SELECT outcome FROM decisions WHERE source = 'neural_late'"
            ).fetchone() == ("adopted",)
            assert db.execute(
                "SELECT outcome, outcome_at_ms FROM decisions"
                " WHERE source = 'local_sentence'"
            ).fetchone() == ("superseded", 2_000)
    finally:
        log.close()


def test_resolve_without_pending_rows_is_a_no_op(tmp_path: Path):
    log = DecisionLog(tmp_path / "decision_log.db")
    try:
        assert log.resolve("missing-request", "rejected")
        assert log.flush()
        with sqlite3.connect(tmp_path / "decision_log.db") as db:
            assert db.execute("SELECT COUNT(*) FROM decisions").fetchone()[0] == 0
    finally:
        log.close()


def test_invalid_arguments_raise(tmp_path: Path):
    log = DecisionLog(tmp_path / "decision_log.db")
    try:
        with pytest.raises(DecisionLogError):
            log.record(
                source="not_a_source",
                request_id="req-1",
                composition_id="comp-1",
                revision=1,
                pinyin="a",
                suggestion="x",
                confidence=None,
                model_artifact_id=None,
            )
        with pytest.raises(DecisionLogError):
            log.resolve("req-1", "pending")
    finally:
        log.close()


def test_purge_by_age_and_capacity(tmp_path: Path):
    log = DecisionLog(
        tmp_path / "decision_log.db",
        retention_days=1,
        capacity=2,
    )
    try:
        for index in range(4):
            log.record(
                source="local_rank",
                request_id=f"req-old-{index}",
                composition_id="comp",
                revision=1,
                pinyin="a",
                suggestion="x",
                confidence=None,
                model_artifact_id=None,
                created_at_ms=1000,
            )
        for index in range(3):
            log.record(
                source="local_rank",
                request_id=f"req-new-{index}",
                composition_id="comp",
                revision=1,
                pinyin="a",
                suggestion="x",
                confidence=None,
                model_artifact_id=None,
                created_at_ms=10_000_000_000_000,
            )
        assert log.flush()
        # Deterministic sweep through the private hook (the same code
        # path the writer calls every 1_024 records).
        removed = log._prune(now_ms=10_000_000_000_000)
        with sqlite3.connect(tmp_path / "decision_log.db") as db:
            remaining = db.execute(
                "SELECT request_id FROM decisions ORDER BY id"
            ).fetchall()
        # 4 age-deleted + 1 capacity-deleted (3 fresh rows, capacity 2
        # keeps the two newest).
        assert removed == 5
        assert remaining == [("req-new-1",), ("req-new-2",)]
    finally:
        log.close()


def test_pinyin_and_suggestion_are_clipped(tmp_path: Path):
    log = DecisionLog(tmp_path / "decision_log.db")
    try:
        log.record(
            source="neural_late",
            request_id="req-1",
            composition_id="comp",
            revision=1,
            pinyin="a" * 400,
            suggestion="句" * 300,
            confidence=None,
            model_artifact_id=None,
        )
        assert log.flush()
        with sqlite3.connect(tmp_path / "decision_log.db") as db:
            pinyin, suggestion = db.execute(
                "SELECT pinyin, suggestion FROM decisions"
            ).fetchone()
        assert len(pinyin.encode("utf-8")) <= 256
        assert len(suggestion) <= 128
    finally:
        log.close()


# --------------------------------------------------------------------------
# Server wiring: display events land as pending rows; feedback resolves.


def test_server_records_sync_and_late_frames_and_resolves_feedback():
    async def scenario(runtime_root: Path):
        socket_path = runtime_root / "runtime" / "rimeai.sock"
        log_path = runtime_root / "decision_log.db"
        log = DecisionLog(log_path)
        service = StubNeuralService()
        server = RimeAIDaemonServer(
            socket_path,
            FakeEngine(),
            neural_sentence=service,
            decision_log=log,
        )
        await server.start()
        writer: asyncio.StreamWriter | None = None
        try:
            reader, writer = await asyncio.open_unix_connection(socket_path)
            hello = await _hello(reader, writer)
            assert "sentence-feedback" in hello["capabilities"]
            await _write_json(writer, _infer_message(1, "request-1"))
            result = await _read_json(reader)
            assert result["type"] == "result" and result["status"] == "ok"
            late = await _read_json(reader)
            assert late["type"] == "sentence_late"
            assert log.flush()
            with sqlite3.connect(log_path) as db:
                rows = dict(
                    db.execute(
                        "SELECT source, outcome FROM decisions"
                        " WHERE request_id = 'request-1'"
                    ).fetchall()
                )
            assert rows == {
                "local_rank": "pending",
                "neural_late": "pending",
            }
            await _write_json(
                writer,
                {
                    "schema_version": 1,
                    "type": "sentence_feedback",
                    "request_id": "request-1",
                    "outcome": "adopted",
                },
            )
            # Malformed outcome frames are silently ignored.
            await _write_json(
                writer,
                {
                    "schema_version": 1,
                    "type": "sentence_feedback",
                    "request_id": "request-1",
                    "outcome": "pending",
                },
            )
            # The server reads the frames asynchronously, so flush()
            # alone cannot observe the resolution — poll the database
            # with a bounded wait instead of racing the handler.
            await _wait_for_rows(
                log_path,
                "request-1",
                {"local_rank": "superseded", "neural_late": "adopted"},
            )
        finally:
            # The client must close before server.close(): the server's
            # bounded teardown waits for the handler loop, which parks
            # in readline() until the peer disconnects.
            if writer is not None:
                writer.close()
                await writer.wait_closed()
        await asyncio.wait_for(server.close(), timeout=10)

    with tempfile.TemporaryDirectory(prefix="rai-", dir="/tmp") as directory:
        asyncio.run(scenario(Path(directory)))


async def _wait_for_rows(
    log_path: Path,
    request_id: str,
    expected: dict[str, str],
    *,
    timeout: float = 2.0,
) -> None:
    import time as _time

    deadline = _time.monotonic() + timeout
    while True:
        with sqlite3.connect(log_path) as db:
            rows = dict(
                db.execute(
                    "SELECT source, outcome FROM decisions"
                    " WHERE request_id = ?",
                    (request_id,),
                ).fetchall()
            )
        if rows == expected:
            return
        if _time.monotonic() >= deadline:
            raise AssertionError(
                f"decision rows did not converge: {rows} != {expected}"
            )
        await asyncio.sleep(0.01)


def test_server_without_log_omits_capability_and_ignores_feedback():
    async def scenario(runtime_root: Path):
        socket_path = runtime_root / "runtime" / "rimeai.sock"
        server = RimeAIDaemonServer(socket_path, FakeEngine())
        await server.start()
        try:
            reader, writer = await asyncio.open_unix_connection(socket_path)
            hello = await _hello(reader, writer)
            assert "sentence-feedback" not in hello["capabilities"]
            # A feedback frame without a log is dropped without killing
            # the session: the next infer still answers normally.
            await _write_json(
                writer,
                {
                    "schema_version": 1,
                    "type": "sentence_feedback",
                    "request_id": "request-9",
                    "outcome": "rejected",
                },
            )
            await _write_json(writer, _infer_message(1, "request-1"))
            result = await _read_json(reader)
            assert result["type"] == "result" and result["status"] == "ok"
            writer.close()
            await writer.wait_closed()
        finally:
            await asyncio.wait_for(server.close(), timeout=10)

    with tempfile.TemporaryDirectory(prefix="rai-", dir="/tmp") as directory:
        asyncio.run(scenario(Path(directory)))


def test_close_is_idempotent_and_flushes(tmp_path: Path):
    log = DecisionLog(tmp_path / "decision_log.db")
    log.record(
        source="local_rank",
        request_id="req-1",
        composition_id="comp",
        revision=1,
        pinyin="a",
        suggestion="x",
        confidence=None,
        model_artifact_id=None,
    )
    log.close()
    log.close()
    with sqlite3.connect(tmp_path / "decision_log.db") as db:
        assert db.execute("SELECT COUNT(*) FROM decisions").fetchone()[0] == 1


def test_expire_pending_older_than_resolves_only_overdue(tmp_path: Path):
    log = DecisionLog(tmp_path / "decision_log.db")
    try:
        for index in range(3):
            log.record(
                source="neural_late",
                request_id=f"req-orphan-{index}",
                composition_id="comp",
                revision=1,
                pinyin="a",
                suggestion="x",
                confidence=None,
                model_artifact_id=None,
                created_at_ms=1_000,
            )
        log.record(
            source="neural_late",
            request_id="req-fresh",
            composition_id="comp",
            revision=1,
            pinyin="a",
            suggestion="x",
            confidence=None,
            model_artifact_id=None,
            created_at_ms=10_000_000_000_000,
        )
        log.record(
            source="neural_late",
            request_id="req-adopted-old",
            composition_id="comp",
            revision=1,
            pinyin="a",
            suggestion="x",
            confidence=None,
            model_artifact_id=None,
            created_at_ms=1_000,
        )
        log.resolve(
            request_id="req-adopted-old",
            outcome="adopted",
        )
        assert log.flush()
        resolved = log._expire_pending_older_than(
            5_000, now_ms=20_000_000_000_000
        )
        assert resolved == 3
        with sqlite3.connect(tmp_path / "decision_log.db") as db:
            rows = dict(
                db.execute(
                    "SELECT request_id, outcome FROM decisions"
                ).fetchall()
            )
        assert rows["req-orphan-0"] == "expired"
        assert rows["req-orphan-1"] == "expired"
        assert rows["req-orphan-2"] == "expired"
        # 活跃（新）pending 与非 pending 旧行都不动。
        assert rows["req-fresh"] == "pending"
        assert rows["req-adopted-old"] == "adopted"
        # 幂等：第二次无匹配。
        assert (
            log._expire_pending_older_than(
                5_000, now_ms=20_000_000_000_001
            )
            == 0
        )
    finally:
        log.close()


def test_expire_pending_cli_dry_run_and_apply(tmp_path: Path):
    import subprocess
    import sys as _sys

    db_path = tmp_path / "decision_log.db"
    log = DecisionLog(db_path)
    log.record(
        source="neural_late",
        request_id="req-orphan",
        composition_id="comp",
        revision=1,
        pinyin="a",
        suggestion="x",
        confidence=None,
        model_artifact_id=None,
        created_at_ms=1,
    )
    log.close()
    project_root = Path(__file__).resolve().parents[1]
    dry = subprocess.run(
        [
            _sys.executable,
            "-m",
            "rimeai_daemon.decision_log",
            "--db",
            str(db_path),
            "--expire-pending-older-than-minutes",
            "1",
            "--dry-run",
        ],
        cwd=project_root,
        capture_output=True,
        text=True,
    )
    assert dry.returncode == 0, dry.stderr
    assert '"would_resolve": 1' in dry.stdout
    with sqlite3.connect(db_path) as db:
        assert (
            db.execute(
                "SELECT outcome FROM decisions WHERE request_id = 'req-orphan'"
            ).fetchone()[0]
            == "pending"
        )
    applied = subprocess.run(
        [
            _sys.executable,
            "-m",
            "rimeai_daemon.decision_log",
            "--db",
            str(db_path),
            "--expire-pending-older-than-minutes",
            "1",
        ],
        cwd=project_root,
        capture_output=True,
        text=True,
    )
    assert applied.returncode == 0, applied.stderr
    assert '"resolved": 1' in applied.stdout
    with sqlite3.connect(db_path) as db:
        assert (
            db.execute(
                "SELECT outcome FROM decisions WHERE request_id = 'req-orphan'"
            ).fetchone()[0]
            == "expired"
        )
    # 幂等：重跑 resolved=0。
    rerun = subprocess.run(
        [
            _sys.executable,
            "-m",
            "rimeai_daemon.decision_log",
            "--db",
            str(db_path),
            "--expire-pending-older-than-minutes",
            "1",
        ],
        cwd=project_root,
        capture_output=True,
        text=True,
    )
    assert '"resolved": 0' in rerun.stdout
