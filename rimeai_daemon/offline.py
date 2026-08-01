"""Process-wide network guard for the Offline Lock execution mode."""

from contextlib import contextmanager
import errno
import socket
from threading import Lock
from typing import Iterator


_ORIGINAL_SOCKET = socket.socket
_guard_lock = Lock()
_guard_depth = 0


class _OfflineSocket(_ORIGINAL_SOCKET):
    def __init__(
        self,
        family: int = -1,
        type: int = -1,
        proto: int = -1,
        fileno=None,
    ):
        if fileno is None and family in (socket.AF_INET, socket.AF_INET6):
            raise PermissionError(
                errno.EPERM,
                "RimeAI Offline Lock denies internet sockets",
            )
        super().__init__(family, type, proto, fileno)


def install_offline_network_guard() -> None:
    """Deny new IPv4 and IPv6 sockets while preserving local Unix IPC."""
    global _guard_depth
    with _guard_lock:
        _guard_depth += 1
        socket.socket = _OfflineSocket


def remove_offline_network_guard() -> None:
    """Remove one guard registration; intended for isolated tests only."""
    global _guard_depth
    with _guard_lock:
        if _guard_depth == 0:
            return
        _guard_depth -= 1
        if _guard_depth == 0:
            socket.socket = _ORIGINAL_SOCKET


@contextmanager
def offline_network_guard() -> Iterator[None]:
    install_offline_network_guard()
    try:
        yield
    finally:
        remove_offline_network_guard()
