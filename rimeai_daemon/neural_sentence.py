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
"""
from __future__ import annotations

import contextlib
import json
import os
import selectors
import subprocess
from pathlib import Path
from time import monotonic
from typing import Any

CONSECUTIVE_FAILURE_LIMIT = 3
COOLDOWN_SECONDS = 30.0
MAX_CANDIDATES = 10
MAX_CHARACTERS = 30
DEFAULT_TIMEOUT_MS = 10_000
DEFAULT_BUDGET_MS = 1_200
DEFAULT_MIN_CONFIDENCE = 0.0


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
            "neural sentence min_confidence must be a number from 0 to 1"
        )
    model_type = config.get("model_type")
    if model_type is not None and not isinstance(model_type, str):
        raise NeuralSentenceConfigurationError(
            "neural sentence model_type must be a string when present"
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
    """One long-lived worker subprocess behind a circuit breaker."""

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
        self._process: subprocess.Popen[bytes] | None = None
        self._selector: selectors.BaseSelector | None = None
        self._consecutive_failures = 0
        self._cooldown_until = 0.0
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

    def close(self) -> None:
        process = self._process
        self._process = None
        if self._selector is not None:
            self._selector.close()
            self._selector = None
        if process is not None:
            self._close_process(process)
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    process.kill()

    def _record_failure(self) -> None:
        self.stats["failures"] += 1
        self._consecutive_failures += 1
        if self._consecutive_failures >= CONSECUTIVE_FAILURE_LIMIT:
            self._cooldown_until = monotonic() + COOLDOWN_SECONDS
            self.close()

    def _worker(self) -> subprocess.Popen[bytes] | None:
        if monotonic() < self._cooldown_until:
            return None
        if self._process is not None and self._process.poll() is None:
            return self._process
        if self._process is not None:
            # A crashed worker's pipes must be closed before the
            # replacement spawns (ResourceWarning discipline); the old
            # selector leaks its kqueue fd otherwise.
            self._close_process(self._process)
            self._process = None
            if self._selector is not None:
                self._selector.close()
                self._selector = None
        try:
            self._process = subprocess.Popen(
                self._command,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                env=dict(os.environ),
                cwd=str(Path(self._command[0]).resolve().parent.parent),
            )
            self._selector = selectors.DefaultSelector()
            if self._process.stdout is None:
                self._record_failure()
                return None
            self._selector.register(
                self._process.stdout, selectors.EVENT_READ
            )
            self.stats["worker_restarts"] += 1
        except OSError:
            self._record_failure()
            return None
        return self._process

    def _readline(self, timeout_seconds: float) -> str | None:
        process = self._process
        selector = self._selector
        if process is None or selector is None or process.stdout is None:
            return None
        deadline = monotonic() + timeout_seconds
        while True:
            remaining = deadline - monotonic()
            if remaining <= 0:
                return None
            events = selector.select(timeout=remaining)
            if not events:
                return None
            line = process.stdout.readline()
            if not line:
                # Worker exited mid-request.
                return None
            return line.decode("utf-8", errors="strict").strip()

    def decode(self, request: dict[str, Any]) -> dict[str, Any] | None:
        """Runs one decode; returns the gated suggestion payload or None
        when the arm abstains. Never raises for expected failures."""
        self.stats["requests"] += 1
        if not request.get("allow_sentence") or not _eligible_request(
            request
        ):
            self.stats["abstained"] += 1
            return None
        worker_request = {
            "schema_version": 1,
            "task": "generate_sentence",
            "request_id": request["request_id"],
            "context": request.get("context", ""),
            "pinyin": request["pinyin"],
            "candidates": request["candidates"][:MAX_CANDIDATES],
            "max_characters": MAX_CHARACTERS,
            "stats": True,
        }
        process = self._worker()
        if process is None or process.stdin is None:
            self.stats["abstained"] += 1
            return None
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
            line = self._readline(self._timeout_seconds)
        except (OSError, ValueError):
            self._record_failure()
            self.stats["abstained"] += 1
            return None
        if line is None:
            self._record_failure()
            self.stats["abstained"] += 1
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
            return None
        artifact_id = response.get("model_artifact_id")
        if isinstance(artifact_id, str) and artifact_id:
            self.stats["model_artifact_id"] = artifact_id
        self.stats["delivered"] += 1
        payload: dict[str, Any] = {
            "suggestion": suggestion,
            "confidence": float(confidence),
            "model_artifact_id": self.stats.get("model_artifact_id"),
            "stats": response.get("stats"),
        }
        return payload
