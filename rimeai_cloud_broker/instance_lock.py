"""Process-level single-instance guard for the cloud broker (P2-7).

`flock` on `<directory>/<name>.lock` is the exclusion mechanism — the
kernel releases it automatically when the holder dies, so a crashed
broker never blocks relaunch. The sidecar `<name>.pid` file is purely
diagnostic (launchd tooling, `ps` cross-checks); a stale pidfile left
behind by a crash must not block re-acquisition.
"""

from __future__ import annotations

import contextlib
import fcntl
import os
from pathlib import Path


class SingleInstanceLock:
    def __init__(self, directory: Path, *, name: str) -> None:
        self._lock_path = directory / f"{name}.lock"
        self._pid_path = directory / f"{name}.pid"
        self._handle = None

    def acquire(self) -> bool:
        """True when this process now holds the instance lock."""
        if self._handle is not None:
            return True
        self._lock_path.parent.mkdir(parents=True, exist_ok=True)
        handle = self._lock_path.open("a+b")
        try:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            handle.close()
            return False
        self._handle = handle
        # The lock file holds no secret, but it is diagnostic state in
        # the user's own Application Support directory: keep it
        # owner-only instead of inheriting the process umask.
        with contextlib.suppress(OSError):
            os.chmod(self._lock_path, 0o600)
        self._pid_path.write_text(
            f"{os.getpid()}\n", encoding="utf-8"
        )
        with contextlib.suppress(OSError):
            os.chmod(self._pid_path, 0o600)
        return True

    def release(self) -> None:
        """Idempotent: releasing an unheld lock is a no-op."""
        handle = self._handle
        self._handle = None
        if handle is None:
            return
        # Remove the diagnostic pidfile while the lock is still held:
        # unlinking it after the unlock would let a new holder write its
        # own pid and then have it deleted by this process.
        with contextlib.suppress(FileNotFoundError):
            self._pid_path.unlink()
        fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
        handle.close()
