"""Persistent subprocess service for the async neural sentence arm.

Drives the MLX constrained worker (script/constrained_mlx_service.sh →
rimeai_runtime.mlx_worker) as one long-lived child process speaking the
schema_version-1 generate_sentence JSONL protocol. The service is the
server-side half of the sentence-late latency tier: sync infer responses
never wait on it; decoded sentences surface as late frames bound to the
request's composition/revision.

Fail-closed by construction: circuit opens after consecutive failures,
ineligible request shapes abstain without touching the worker, and any
protocol deviation drops the suggestion (never the connection).

Thread contract (reveal B-F4/C-F3): ``decode`` runs on the single
neural executor thread (or the test thread); ``close`` may be called
concurrently from the event loop (daemon shutdown) and from the
executor thread itself (circuit breaker). A blocked reader is released
by terminating the child first (pipe EOF wakes the read) and only then
closing the pipes; after ``close`` the service is terminally closed and
``decode`` abstains WITHOUT recording a failure (interruption is not a
worker failure). All shared attribute transitions happen under
``_state_lock``.
"""
from __future__ import annotations

import contextlib
import json
import logging
import os
import select
import subprocess
import threading
from pathlib import Path
from time import monotonic
from typing import Any

CONSECUTIVE_FAILURE_LIMIT = 3
COOLDOWN_SECONDS = 30.0
# Reveal C-F6: after this many full cooldown cycles without a single
# delivered sentence, the arm disables itself instead of oscillating
# (spawn → kill → cooldown) forever on an unattended LaunchAgent.
COOLDOWN_DISABLE_CYCLES = 5
# Reveal C-F6: a freshly spawned worker may legitimately spend seconds
# loading the model (measured cold start ~2.5s + dictionary index).
# The first read after a spawn gets this grace window; the delivery
# budget is unaffected (late frames still only leave within budget).
COLD_START_GRACE_SECONDS = 30.0
MAX_CANDIDATES = 10
MAX_CHARACTERS = 30
DEFAULT_TIMEOUT_MS = 10_000
DEFAULT_BUDGET_MS = 1_200
DEFAULT_MIN_CONFIDENCE = 0.0
# Reveal A-F3/B-F6: a response line longer than this without a newline
# is a protocol violation, not something to buffer unbounded.
MAX_RESPONSE_LINE_BYTES = 1 << 20
_READ_CHUNK_BYTES = 65536

logger = logging.getLogger(__name__)


class NeuralSentenceConfigurationError(ValueError):
    pass


def load_neural_sentence_config(path: Path) -> dict[str, Any]:
    """Reads and validates the decoder-style service config.

    Shared shape with the eval decoder config (schema_version, name,
    command, timeout_ms) plus daemon fields (budget_ms, min_confidence,
    model_type)."""
    try:
        config = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise NeuralSentenceConfigurationError(
            f"cannot read neural sentence config '{path}': {error}"
        ) from error
    if not isinstance(config, dict) or config.get("schema_version") != 1:
        raise NeuralSentenceConfigurationError(
            "neural sentence config schema_version must be 1"
        )
    name = config.get("name")
    command = config.get("command")
    timeout_ms = config.get("timeout_ms", DEFAULT_TIMEOUT_MS)
    if not isinstance(name, str) or not name.strip():
        raise NeuralSentenceConfigurationError(
            "neural sentence config name must be a non-empty string"
        )
    if (
        not isinstance(command, list)
        or not command
        or any(
            not isinstance(item, str) or not item for item in command
        )
    ):
        raise NeuralSentenceConfigurationError(
            "neural sentence config command must be a non-empty string array"
        )
    if (
        not isinstance(timeout_ms, int)
        or isinstance(timeout_ms, bool)
        or not 1 <= timeout_ms <= 60_000
    ):
        raise NeuralSentenceConfigurationError(
            "neural sentence timeout_ms must be an integer from 1 to 60000"
        )
    budget_ms = config.get("budget_ms", DEFAULT_BUDGET_MS)
    if (
        not isinstance(budget_ms, int)
        or isinstance(budget_ms, bool)
        or not 1 <= budget_ms <= 5_000
    ):
        raise NeuralSentenceConfigurationError(
            "neural sentence budget_ms must be an integer from 1 to 5000"
        )
    min_confidence = config.get("min_confidence", DEFAULT_MIN_CONFIDENCE)
    if (
        not isinstance(min_confidence, (int, float))
        or isinstance(min_confidence, bool)
        or not 0 <= min_confidence <= 1
    ):
        raise NeuralSentenceConfigurationError(
            "neural sentence config min_confidence must be a number from 0 to 1"
        )
    model_type = config.get("model_type")
    if model_type is not None and not isinstance(model_type, str):
        raise NeuralSentenceConfigurationError(
            "neural sentence config model_type must be a string when present"
        )
    return config


def _eligible_request(request: dict[str, Any]) -> bool:
    """The neural arm serves single-segment requests only: multi-segment
    layouts keep the sync beam path (frozen decision, TECHNICAL_DESIGN
    §4.3)."""
    segments = request.get("segments")
    if segments is not None and len(segments) > 1:
        return False
    pinyin = request.get("pinyin")
    candidates = request.get("candidates")
    return (
        isinstance(pinyin, str)
        and 0 < len(pinyin) <= 256
        and isinstance(candidates, list)
        and 1 <= len(candidates) <= MAX_CANDIDATES
    )


class NeuralSentenceService:
    """One long-lived worker subprocess behind a circuit breaker.

    ``timeout_ms`` bounds a single worker read (the deployment config
    keeps it in the low seconds); ``budget_ms`` is the delivery deadline
    the daemon passes down so a slow decode releases the executor slot
    at the budget instead of occupying it for ``timeout_ms``."""

    def __init__(
        self,
        config: dict[str, Any],
        *,
        project_root: Path,
    ) -> None:
        self.name = config["name"]
        self._command = [
            item if Path(item).is_absolute() else str(project_root / item)
            for item in config["command"]
        ]
        self._timeout_seconds = config["timeout_ms"] / 1000
        self.budget_ms: int = config.get("budget_ms", DEFAULT_BUDGET_MS)
        self.min_confidence: float = float(
            config.get("min_confidence", DEFAULT_MIN_CONFIDENCE)
        )
        self.model_type: str | None = config.get("model_type")
        self._state_lock = threading.Lock()
        self._process: subprocess.Popen[bytes] | None = None
        self._read_buffer = bytearray()
        # Worker is "warm" once it answered once since spawning; the
        # first read after a spawn gets the cold-start grace window.
        self._warm = False
        self._cold_start_until = 0.0
        self._closing = False
        self._closed = False
        self._disabled = False
        self._consecutive_failures = 0
        self._cooldown_until = 0.0
        self._cooldown_cycles = 0
        self.stats: dict[str, Any] = {
            "requests": 0,
            "abstained": 0,
            "delivered": 0,
            "failures": 0,
            "worker_restarts": 0,
        }

    def artifacts(self) -> list[dict[str, Any]]:
        entry: dict[str, Any] = {
            "role": "neural_sentence",
            "path": self._command[0],
            "name": self.name,
        }
        if self.model_type is not None:
            entry["model_type"] = self.model_type
        if self._model_artifact_id is not None:
            entry["model_artifact_id"] = self._model_artifact_id
        return [entry]

    @property
    def _model_artifact_id(self) -> str | None:
        return self.stats.get("model_artifact_id")

    def _close_process(self, process: subprocess.Popen[bytes]) -> None:
        if process.stdin is not None:
            with contextlib.suppress(OSError):
                process.stdin.close()
        if process.stdout is not None:
            with contextlib.suppress(OSError):
                process.stdout.close()

    def _terminate_process(
        self, process: subprocess.Popen[bytes]
    ) -> None:
        """Terminate → bounded wait → kill → reap (reveal B-F4/C-F3:
        SIGTERM makes the child exit, the pipe EOF wakes a reader
        blocked on the fd, and the post-kill wait() prevents zombies)."""
        if process.poll() is None:
            with contextlib.suppress(OSError):
                process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                with contextlib.suppress(OSError):
                    process.kill()
                with contextlib.suppress(subprocess.TimeoutExpired):
                    process.wait(timeout=2)
        self._close_process(process)

    def _recycle(self) -> None:
        """Breaker path: tear down the current worker but keep the
        service OPEN for a later respawn after cooldown (close() is the
        terminal shutdown; recycling must not latch it)."""
        with self._state_lock:
            process = self._process
            self._process = None
        if process is not None:
            self._terminate_process(process)

    def close(self) -> None:
        """Idempotent terminal teardown; safe to call from any thread
        while a decode is blocked on the worker pipe."""
        with self._state_lock:
            if self._closed:
                return
            self._closed = True
            self._closing = True
            process = self._process
            self._process = None
        if process is not None:
            self._terminate_process(process)

    def _record_failure(self) -> None:
        self.stats["failures"] += 1
        self._consecutive_failures += 1
        if self._consecutive_failures >= CONSECUTIVE_FAILURE_LIMIT:
            self._cooldown_until = monotonic() + COOLDOWN_SECONDS
            self._cooldown_cycles += 1
            self._consecutive_failures = 0
            if self._cooldown_cycles >= COOLDOWN_DISABLE_CYCLES:
                # Reveal C-F6: permanent abstain after enough unanswered
                # cooldown cycles; the daemon keeps serving sync results.
                self._disabled = True
                self._recycle()
                logger.warning(
                    "neural arm disabled after %d cooldown cycles",
                    self._cooldown_cycles,
                )
            else:
                self._recycle()
                logger.warning(
                    "neural arm cooldown #%d (%ss); worker recycled",
                    self._cooldown_cycles,
                    COOLDOWN_SECONDS,
                )
        else:
            logger.warning(
                "neural worker failure #%d/%d",
                self._consecutive_failures,
                CONSECUTIVE_FAILURE_LIMIT,
            )

    def _worker(self) -> subprocess.Popen[bytes] | None:
        spawn_failed = False
        process: subprocess.Popen[bytes] | None = None
        with self._state_lock:
            if self._closed or self._disabled:
                return None
            if monotonic() < self._cooldown_until:
                return None
            if self._process is not None and self._process.poll() is None:
                return self._process
            if self._process is not None:
                # A crashed worker's pipes must be closed before the
                # replacement spawns (ResourceWarning discipline).
                self._close_process(self._process)
                self._process = None
            try:
                process = subprocess.Popen(
                    self._command,
                    stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE,
                    # Reveal B-F6/C-F4: keep worker diagnostics (cold
                    # start timing, engine errors) on the daemon's own
                    # stderr instead of discarding them. DEVNULL also
                    # deadlocks a chatty worker; inherit never does.
                    stderr=None,
                    env=dict(os.environ),
                    cwd=str(
                        Path(self._command[0]).resolve().parent.parent
                    ),
                )
            except OSError:
                spawn_failed = True
            else:
                self._process = process
                self._read_buffer = bytearray()
                self._warm = False
                self._cold_start_until = (
                    monotonic() + COLD_START_GRACE_SECONDS
                )
                self.stats["worker_restarts"] += 1
        # Failure recording (which may call close()) stays outside the
        # state lock: threading.Lock is not reentrant.
        if spawn_failed:
            logger.warning("neural worker spawn failed command=%s", self._command[0])
            self._record_failure()
            return None
        logger.info(
            "neural worker started restarts=%d command=%s",
            self.stats["worker_restarts"],
            self._command[0],
        )
        return process

    def _read_response_line(
        self,
        process: subprocess.Popen[bytes],
        deadline: float,
    ) -> str | None:
        """Bounded line read (reveal A-F3): os.read + line accumulator,
        bounded by ``deadline`` and ``MAX_RESPONSE_LINE_BYTES``. Never
        calls the unbounded blocking ``readline`` after ``select``.

        Returns the stripped line, or None on timeout / worker exit /
        overlong line / interruption. Raises no exceptions; callers
        classify timeout/EOF as worker failure, closed-service as
        interruption."""
        if process.stdout is None:
            return None
        fd = process.stdout.fileno()
        buffer = self._read_buffer
        while True:
            newline = buffer.find(b"\n")
            if newline >= 0:
                line = bytes(buffer[:newline])
                del buffer[: newline + 1]
                return line.decode("utf-8", errors="strict").strip()
            if len(buffer) > MAX_RESPONSE_LINE_BYTES:
                return None
            remaining = deadline - monotonic()
            if remaining <= 0:
                return None
            try:
                ready, _, _ = select.select([fd], [], [], remaining)
            except (OSError, ValueError):
                return None
            if not ready:
                return None
            try:
                chunk = os.read(fd, _READ_CHUNK_BYTES)
            except (OSError, ValueError):
                return None
            if not chunk:
                # Worker exited mid-request.
                return None
            buffer.extend(chunk)

    def _is_interruption(
        self, process: subprocess.Popen[bytes]
    ) -> bool:
        """A read/write failure while the service is closing (or the
        process was swapped) is an interruption, not a worker failure
        (reveal B-F4: miscounting interruptions trips the breaker)."""
        with self._state_lock:
            return (
                self._closing
                or self._closed
                or self._process is not process
            )

    def decode(
        self,
        request: dict[str, Any],
        *,
        deadline: float | None = None,
    ) -> dict[str, Any] | None:
        """Runs one decode; returns the gated suggestion payload or None
        when the arm abstains. Never raises for expected failures.

        ``deadline`` (monotonic seconds) is the daemon's delivery
        budget: the worker read stops at the deadline so a slow decode
        releases the executor slot at budget time instead of occupying
        it for the full ``timeout_ms`` (reveal B-F5/C-F2). A cold
        worker's first read may exceed the deadline up to the cold-start
        grace window (loading the model is not a decode failure)."""
        self.stats["requests"] += 1
        if not request.get("allow_sentence") or not _eligible_request(
            request
        ):
            self.stats["abstained"] += 1
            logger.debug("neural decode abstained: request ineligible")
            return None
        worker_request = {
            "schema_version": 1,
            "task": "generate_sentence",
            "request_id": request["request_id"],
            "context": request.get("context", ""),
            # The server already validates 1..MAX_CANDIDATES entries;
            # the worker protocol's own bound (20, frozen torch-worker
            # compatibility) is deliberately looser.
            "pinyin": request["pinyin"],
            "candidates": request["candidates"],
            "max_characters": MAX_CHARACTERS,
        }
        process = self._worker()
        if process is None or process.stdin is None:
            self.stats["abstained"] += 1
            logger.debug(
                "neural decode abstained: no worker (cooldown/disabled/spawn)"
            )
            return None
        now = monotonic()
        read_deadline = (
            deadline if deadline is not None
            else now + self._timeout_seconds
        )
        if not self._warm:
            read_deadline = max(
                read_deadline, self._cold_start_until
            )
        try:
            process.stdin.write(
                (
                    json.dumps(
                        worker_request,
                        ensure_ascii=False,
                        separators=(",", ":"),
                        sort_keys=True,
                    )
                    + "\n"
                ).encode("utf-8")
            )
            process.stdin.flush()
            line = self._read_response_line(process, read_deadline)
        except (OSError, ValueError):
            if self._is_interruption(process):
                self.stats["abstained"] += 1
                return None
            self._record_failure()
            self.stats["abstained"] += 1
            return None
        if line is None:
            if self._is_interruption(process):
                self.stats["abstained"] += 1
                logger.debug("neural decode interrupted during read")
                return None
            self._record_failure()
            self.stats["abstained"] += 1
            logger.warning("neural worker read timed out or exited")
            return None
        try:
            response = json.loads(line)
        except json.JSONDecodeError:
            self._record_failure()
            self.stats["abstained"] += 1
            return None
        if not isinstance(response, dict) or response.get(
            "request_id"
        ) != request["request_id"]:
            self._record_failure()
            self.stats["abstained"] += 1
            return None
        self._warm = True
        self._consecutive_failures = 0
        suggestion = response.get("suggestion")
        confidence = response.get("confidence")
        if (
            not isinstance(suggestion, str)
            or not suggestion
            or len(suggestion) > MAX_CHARACTERS
            or "\n" in suggestion
            or "\r" in suggestion
            or not isinstance(confidence, (int, float))
            or isinstance(confidence, bool)
            or not 0 <= confidence <= 1
            or confidence < self.min_confidence
        ):
            self.stats["abstained"] += 1
            logger.debug(
                "neural decode abstained: response below gate"
                " confidence=%r min_confidence=%.3f",
                confidence,
                self.min_confidence,
            )
            return None
        artifact_id = response.get("model_artifact_id")
        if isinstance(artifact_id, str) and artifact_id:
            self.stats["model_artifact_id"] = artifact_id
        self.stats["delivered"] += 1
        payload: dict[str, Any] = {
            "suggestion": suggestion,
            "confidence": float(confidence),
            "model_artifact_id": self.stats.get("model_artifact_id"),
        }
        return payload
