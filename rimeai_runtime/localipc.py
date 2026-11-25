"""Shared Unix-domain socket bootstrap and peer-identity helpers.

The daemon and the cloud broker previously hand-rolled identical copies
of this logic and the copies drifted in wording only. Where they
disagreed this module adopts the stricter, more portable choice and
documents it: the peer-identity failure keeps the daemon's more
descriptive message (both callers close the connection on any failure,
so the wording is the only observable difference), and the bootstrap
keeps the daemon's practice of chaining the underlying OSError so each
server can surface its own historical message. All permission bits,
the 103-byte sun_path limit, the 0.1-second liveness probe, and the
geteuid comparison stay exactly as both servers implemented them.
"""

from __future__ import annotations

import asyncio
import contextlib
import ctypes
import os
import socket
import stat
import struct
from collections.abc import Callable
from pathlib import Path
from typing import Any


class PeerIdentityError(ValueError):
    """The platform cannot verify a Unix socket peer's identity."""


def peer_uid(file_descriptor: int) -> int:
    """Return the UID of the peer connected to a Unix socket.

    Prefers getpeereid(3) (the BSD/macOS API) and falls back to the
    SO_PEERCRED socket option where getpeereid is unavailable. Raises
    OSError when the descriptor is invalid and PeerIdentityError when
    the platform offers neither API.
    """
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        getpeereid = libc.getpeereid
    except AttributeError as error:
        # typeshed declares SO_PEERCRED for Linux only, and the attribute
        # must be read here, at call time, so a platform without it is
        # detected however the module was imported.
        peer_credential_option = getattr(socket, "SO_PEERCRED", None)
        if peer_credential_option is None:
            raise PeerIdentityError(
                "this platform cannot verify Unix socket peer identity"
            ) from error
        peer_socket = socket.socket(fileno=os.dup(file_descriptor))
        try:
            credentials = peer_socket.getsockopt(
                socket.SOL_SOCKET,
                peer_credential_option,
                struct.calcsize("3i"),
            )
        finally:
            peer_socket.close()
        _, uid, _ = struct.unpack("3i", credentials)
        return uid
    uid = ctypes.c_uint()
    gid = ctypes.c_uint()
    if (
        getpeereid(
            ctypes.c_int(file_descriptor),
            ctypes.byref(uid),
            ctypes.byref(gid),
        )
        != 0
    ):
        error_number = ctypes.get_errno()
        raise OSError(error_number, os.strerror(error_number))
    return int(uid.value)


class UnixListenerError(ValueError):
    """A Unix listener socket path cannot be prepared for binding."""


class SocketPathTooLongError(UnixListenerError):
    """The socket path exceeds the portable 103-byte sun_path limit."""


class RuntimeDirectoryIsSymlinkError(UnixListenerError):
    """The socket's parent directory is a symbolic link."""


class NotASocketPathError(UnixListenerError):
    """The existing path is not a socket and must not be replaced."""


class ExistingSocketUnverifiableError(UnixListenerError):
    """An existing socket's liveness cannot be probed."""

    def __init__(self, cause: OSError):
        super().__init__(f"cannot verify existing socket: {cause}")
        self.cause = cause


class AlreadyListeningError(UnixListenerError):
    """Another live listener already owns the socket path."""


async def prepare_unix_listener_socket(
    socket_path: Path,
    client_handler: Callable[..., Any],
    limit: int = 1024 * 1024,
) -> asyncio.AbstractServer:
    """Prepare a private Unix listener socket and start serving on it.

    Creates the parent directory with mode 0o700 (mkdir plus chmod so
    the mode is exact regardless of umask), refuses symlinked parents
    and non-socket leftovers, probes an existing socket for 0.1 seconds
    and unlinks it only when it is provably stale, binds the listener,
    and finally chmods the socket file to 0o600. Callers translate the
    UnixListenerError subclasses into their own configuration error
    types so each server keeps its historical failure messages.
    """
    if len(os.fsencode(socket_path)) > 103:
        raise SocketPathTooLongError(
            "Unix socket path exceeds the 103-byte limit"
        )
    parent = socket_path.parent
    if parent.exists() and parent.is_symlink():
        raise RuntimeDirectoryIsSymlinkError(
            "runtime directory must not be a symbolic link"
        )
    parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(parent, 0o700)
    if socket_path.exists() or socket_path.is_symlink():
        mode = socket_path.lstat().st_mode
        if not stat.S_ISSOCK(mode):
            raise NotASocketPathError(
                "refusing to replace a non-socket runtime path"
            )
        probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        probe.settimeout(0.1)
        try:
            probe.connect(str(socket_path))
        except (ConnectionRefusedError, FileNotFoundError):
            pass
        except OSError as error:
            raise ExistingSocketUnverifiableError(error) from error
        else:
            raise AlreadyListeningError(
                "another listener is already running"
            )
        finally:
            probe.close()
        socket_path.unlink()
    server = await asyncio.start_unix_server(
        client_handler,
        path=str(socket_path),
        limit=limit,
    )
    os.chmod(socket_path, 0o600)
    return server


class ClientSession:
    """One live client connection of a Unix-socket server.

    The client handler registers a session as soon as it starts and
    discards it in a ``finally`` when it returns, so
    ``shutdown_unix_listener`` always knows which connections are open.
    """

    __slots__ = ("handler", "writer")

    def __init__(
        self,
        writer: asyncio.StreamWriter,
        handler: asyncio.Task[Any] | None,
    ) -> None:
        self.writer = writer
        self.handler = handler


async def disconnect_client_sessions(
    sessions: set[ClientSession],
    *,
    grace_seconds: float,
    timeout_seconds: float,
) -> None:
    """Bring every live client handler down, gracefully first.

    Closing our writer flushes what is still queued and then feeds EOF
    into the handler's own reader, so an idle handler leaves its read
    loop by itself. A peer that stopped reading would hold that flush —
    and with it the server's ``close()`` — forever, so after
    ``grace_seconds`` whatever is still open is aborted (its unsent
    bytes are dropped). Never waits longer than the grace period plus
    ``timeout_seconds``.
    """
    for session in list(sessions):
        session.writer.close()
    handlers = {
        session.handler for session in sessions if session.handler is not None
    }
    if not handlers:
        return
    _, stuck = await asyncio.wait(handlers, timeout=grace_seconds)
    if not stuck:
        return
    for session in list(sessions):
        transport = session.writer.transport
        # Abort only a transport still holding unsent bytes: that is the
        # one case graceful close cannot finish, and it is safe here (a
        # transport that already lost its connection must never be
        # aborted again).
        if transport is not None and transport.get_write_buffer_size() > 0:
            transport.abort()
    await asyncio.wait(stuck, timeout=timeout_seconds)


async def shutdown_unix_listener(
    server: asyncio.AbstractServer,
    sessions: set[ClientSession],
    *,
    grace_seconds: float,
    timeout_seconds: float,
) -> None:
    """Stop a Unix listener and bring its clients down within a bounded budget.

    On Python 3.12+ ``Server.wait_closed()`` also waits for every client
    handler to return, so one idle client that simply keeps its socket
    open would pin the server's ``close()`` forever. This closes the
    listener, tears its clients down (see ``disconnect_client_sessions``)
    and then waits for the server — for at most ``timeout_seconds``, so
    the caller's ``close()`` always completes. Callers stop accepting
    new work (and cancel their in-flight request tasks) *before* calling
    this, so no handler starts another round of work while it is being
    torn down.
    """
    server.close()
    await disconnect_client_sessions(
        sessions,
        grace_seconds=grace_seconds,
        timeout_seconds=timeout_seconds,
    )
    with contextlib.suppress(asyncio.TimeoutError):
        await asyncio.wait_for(server.wait_closed(), timeout=timeout_seconds)
