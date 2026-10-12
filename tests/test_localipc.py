"""Unit tests for the shared Unix-domain socket IPC helpers."""

import asyncio
import os
from pathlib import Path
from types import SimpleNamespace
import socket
import stat
import tempfile

import pytest

import rimeai_runtime.localipc as localipc
from rimeai_runtime.localipc import (
    AlreadyListeningError,
    ExistingSocketUnverifiableError,
    NotASocketPathError,
    PeerIdentityError,
    RuntimeDirectoryIsSymlinkError,
    SocketPathTooLongError,
    peer_uid,
    prepare_unix_listener_socket,
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
