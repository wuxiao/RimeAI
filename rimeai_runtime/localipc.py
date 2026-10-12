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

import asyncio
import ctypes
import os
from pathlib import Path
import socket
import stat
import struct
from typing import Any, Callable


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
        if not hasattr(socket, "SO_PEERCRED"):
            raise PeerIdentityError(
                "this platform cannot verify Unix socket peer identity"
            ) from error
        peer_socket = socket.socket(fileno=os.dup(file_descriptor))
        try:
            credentials = peer_socket.getsockopt(
                socket.SOL_SOCKET,
                socket.SO_PEERCRED,
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
