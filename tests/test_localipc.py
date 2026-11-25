"""Unit tests for the shared Unix-domain socket IPC helpers."""

import asyncio
import contextlib
import os
import socket
import stat
import tempfile
import time
import typing
from pathlib import Path
from types import SimpleNamespace

import pytest

import rimeai_runtime.localipc as localipc
from rimeai_runtime.localipc import (
    AlreadyListeningError,
    ClientSession,
    ExistingSocketUnverifiableError,
    NotASocketPathError,
    PeerIdentityError,
    RuntimeDirectoryIsSymlinkError,
    SocketPathTooLongError,
    disconnect_client_sessions,
    peer_uid,
    prepare_unix_listener_socket,
    shutdown_unix_listener,
)


async def _deny_handler(reader, writer):
    writer.close()
    await writer.wait_closed()


def _run(coro):
    return asyncio.run(coro)


def _stop(server, socket_path: Path):
    async def shutdown():
        server.close()
        await server.wait_closed()

    asyncio.run(shutdown())
    if socket_path.exists():
        socket_path.unlink()


def test_peer_uid_returns_the_connected_peer_uid():
    left, right = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        assert peer_uid(right.fileno()) == os.geteuid()
        assert peer_uid(left.fileno()) == os.geteuid()
    finally:
        left.close()
        right.close()


def test_peer_uid_raises_oserror_for_an_invalid_descriptor():
    with pytest.raises(OSError):
        peer_uid(-1)


def test_peer_uid_raises_when_the_platform_has_no_peer_api(monkeypatch):
    def unavailable(*args, **kwargs):
        raise AttributeError("getpeereid")

    monkeypatch.setattr(localipc.ctypes, "CDLL", unavailable)
    monkeypatch.delattr(socket, "SO_PEERCRED", raising=False)
    with pytest.raises(PeerIdentityError):
        peer_uid(0)


def test_bootstrap_creates_directory_and_socket_with_exact_modes():
    with tempfile.TemporaryDirectory() as directory:
        socket_path = Path(directory) / "runtime" / "rimeai.sock"
        server = _run(prepare_unix_listener_socket(socket_path, _deny_handler))
        try:
            assert stat.S_IMODE(socket_path.parent.stat().st_mode) == 0o700
            assert stat.S_IMODE(socket_path.stat().st_mode) == 0o600
        finally:
            _stop(server, socket_path)


def test_bootstrap_removes_a_stale_socket_and_binds_it_again():
    with tempfile.TemporaryDirectory() as directory:
        socket_path = Path(directory) / "runtime" / "rimeai.sock"
        socket_path.parent.mkdir(parents=True, mode=0o700)
        dead = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        dead.bind(str(socket_path))
        dead.close()
        assert socket_path.exists()

        server = _run(prepare_unix_listener_socket(socket_path, _deny_handler))
        try:

            async def connect_once():
                reader, writer = await asyncio.open_unix_connection(socket_path)
                writer.close()
                await writer.wait_closed()

            asyncio.run(connect_once())
        finally:
            _stop(server, socket_path)


def test_bootstrap_refuses_an_active_listener_and_keeps_it():
    with tempfile.TemporaryDirectory() as directory:
        socket_path = Path(directory) / "runtime" / "rimeai.sock"
        socket_path.parent.mkdir(parents=True, mode=0o700)
        live = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        live.bind(str(socket_path))
        live.listen(1)
        try:
            with pytest.raises(AlreadyListeningError):
                _run(prepare_unix_listener_socket(socket_path, _deny_handler))
            assert socket_path.exists()
        finally:
            live.close()
            if socket_path.exists():
                socket_path.unlink()


def test_bootstrap_refuses_to_replace_a_non_socket_path():
    with tempfile.TemporaryDirectory() as directory:
        socket_path = Path(directory) / "runtime" / "rimeai.sock"
        socket_path.parent.mkdir(parents=True, mode=0o700)
        socket_path.write_text("not a socket", encoding="utf-8")
        with pytest.raises(NotASocketPathError):
            _run(prepare_unix_listener_socket(socket_path, _deny_handler))
        assert socket_path.exists()
        socket_path.unlink()


def test_bootstrap_refuses_a_too_long_socket_path():
    with tempfile.TemporaryDirectory() as directory:
        socket_path = Path(directory) / ("x" * 104 + ".sock")
        with pytest.raises(SocketPathTooLongError):
            _run(prepare_unix_listener_socket(socket_path, _deny_handler))


def test_bootstrap_refuses_a_symbolic_linked_runtime_directory():
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        real = root / "real"
        real.mkdir()
        linked = root / "linked"
        linked.symlink_to(real)
        with pytest.raises(RuntimeDirectoryIsSymlinkError):
            _run(prepare_unix_listener_socket(linked / "rimeai.sock", _deny_handler))


def test_bootstrap_reports_an_unverifiable_existing_socket(monkeypatch):
    with tempfile.TemporaryDirectory() as directory:
        socket_path = Path(directory) / "runtime" / "rimeai.sock"
        socket_path.parent.mkdir(parents=True, mode=0o700)
        dead = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        dead.bind(str(socket_path))
        dead.close()

        class DeniedProbe:
            def __init__(self, *args, **kwargs):
                pass

            def settimeout(self, seconds):
                pass

            def connect(self, path):
                raise PermissionError("probe denied")

            def close(self):
                pass

        probe_module = SimpleNamespace(
            AF_UNIX=socket.AF_UNIX,
            SOCK_STREAM=socket.SOCK_STREAM,
            socket=DeniedProbe,
        )
        monkeypatch.setattr(localipc, "socket", probe_module)
        with pytest.raises(ExistingSocketUnverifiableError) as failure:
            _run(prepare_unix_listener_socket(socket_path, _deny_handler))
        assert isinstance(failure.value.cause, PermissionError)
        assert socket_path.exists()


# --------------------------------------------------------------------------
# Bounded client teardown (Python 3.12+ Server.wait_closed() regression).


class _FakeTransport:
    def __init__(self, pending: int = 0) -> None:
        self.pending = pending
        self.aborted = False

    def get_write_buffer_size(self) -> int:
        return self.pending

    def abort(self) -> None:
        self.aborted = True


class _FakeWriter:
    def __init__(self, pending: int = 0) -> None:
        self.transport = _FakeTransport(pending)
        self.closed = False

    def close(self) -> None:
        self.closed = True


def _session(writer: _FakeWriter, handler) -> ClientSession:
    return ClientSession(typing.cast("asyncio.StreamWriter", writer), handler)


def test_disconnect_client_sessions_returns_at_once_without_sessions():
    async def scenario():
        started = time.monotonic()
        await disconnect_client_sessions(
            set(), grace_seconds=5.0, timeout_seconds=5.0
        )
        assert time.monotonic() - started < 1.0

    asyncio.run(scenario())


def test_disconnect_client_sessions_closes_writers_and_waits_for_the_handlers():
    # 优雅阶段：关闭我方 writer 后 handler 自行收尾，不 abort、不取消。
    async def scenario():
        async def handler(writer):
            # Stands in for a read loop: it leaves once its writer closes.
            while not writer.closed:
                await asyncio.sleep(0)

        sessions = set()
        writers = []
        for _ in range(2):
            writer = _FakeWriter()
            sessions.add(_session(writer, asyncio.create_task(handler(writer))))
            writers.append(writer)

        await disconnect_client_sessions(
            sessions, grace_seconds=2.0, timeout_seconds=2.0
        )

        assert all(writer.closed for writer in writers)
        assert not any(writer.transport.aborted for writer in writers)
        assert all(session.handler.done() for session in sessions)

    asyncio.run(scenario())


def test_disconnect_client_sessions_aborts_a_transport_stuck_flushing():
    # 对端不再读取：优雅关闭的 flush 永远等不到。宽限期后 abort 掉仍
    # 持有未发字节的连接；helper 本身不取消 handler，且等待有上界。
    async def scenario():
        parked = asyncio.Event()

        async def wedged():
            await parked.wait()

        writer = _FakeWriter(pending=4096)
        task = asyncio.create_task(wedged())
        sessions = {_session(writer, task)}

        started = time.monotonic()
        await disconnect_client_sessions(
            sessions, grace_seconds=0.1, timeout_seconds=0.2
        )
        elapsed = time.monotonic() - started

        assert writer.closed
        assert writer.transport.aborted
        assert 0.1 <= elapsed < 1.5
        assert not task.done()
        parked.set()
        await asyncio.gather(task)

    asyncio.run(scenario())


def test_disconnect_client_sessions_leaves_a_drained_transport_alone():
    # 写缓冲已空的连接不会被再次 abort：已丢失的连接上再 abort 会出错，
    # 这类 handler 自己就会收尾。
    async def scenario():
        async def finishing():
            await asyncio.sleep(0.05)

        writer = _FakeWriter(pending=0)
        task = asyncio.create_task(finishing())
        sessions = {_session(writer, task)}

        await disconnect_client_sessions(
            sessions, grace_seconds=0.01, timeout_seconds=2.0
        )

        assert writer.closed
        assert not writer.transport.aborted
        assert task.done()

    asyncio.run(scenario())


def test_shutdown_unix_listener_returns_promptly_with_an_idle_client():
    # Python 3.12+ 的 Server.wait_closed() 会等所有 handler 返回：一条
    # 空闲连接就能让旧的 close() 永不返回。
    async def scenario(root: Path):
        socket_path = root / "runtime" / "idle.sock"
        sessions: set[ClientSession] = set()

        async def handler(reader, writer):
            session = ClientSession(writer, asyncio.current_task())
            sessions.add(session)
            try:
                while not reader.at_eof():
                    if not await reader.readline():
                        break
            finally:
                sessions.discard(session)
                writer.close()
                with contextlib.suppress(BrokenPipeError, ConnectionResetError):
                    await writer.wait_closed()

        server = await prepare_unix_listener_socket(socket_path, handler)
        reader, writer = await asyncio.open_unix_connection(socket_path)
        # Let the handler register itself before shutting down.
        await asyncio.sleep(0.01)
        try:
            assert len(sessions) == 1
            started = time.monotonic()
            await asyncio.wait_for(
                shutdown_unix_listener(
                    server,
                    sessions,
                    grace_seconds=0.1,
                    timeout_seconds=2.0,
                ),
                timeout=3.0,
            )
            assert time.monotonic() - started < 1.5
            assert server.is_serving() is False
            assert sessions == set()
            # The server closed its side: the client reads EOF.
            assert await asyncio.wait_for(reader.read(), timeout=1.0) == b""
        finally:
            writer.close()
            with contextlib.suppress(BrokenPipeError, ConnectionResetError):
                await writer.wait_closed()
            if socket_path.exists():
                socket_path.unlink()

    with tempfile.TemporaryDirectory(prefix="rai-", dir="/tmp") as root:
        asyncio.run(scenario(Path(root)))
