"""Versioned Unix Domain Socket server with fail-closed request scheduling."""
from __future__ import annotations

import asyncio
import contextlib
import functools
import json
import math
import os
import re
import stat
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from time import monotonic
from typing import Any, Protocol

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

from .neural_sentence import NeuralSentenceService
from .segment_policy import validate_pinyin_segments

# Shared domain charset contract with the broker profile store and the
# Swift PhraseBookStore: [a-z0-9-]{1,64} (locked by cross-layer tests).
DOMAIN_PATTERN = re.compile(r"[a-z0-9-]{1,64}")


def is_valid_domain(domain: object) -> bool:
    return isinstance(domain, str) and DOMAIN_PATTERN.fullmatch(domain) is not None


class InferenceEngine(Protocol):
    artifact_id: str

    def infer(self, request: dict[str, Any]) -> dict[str, Any]:
        ...


class DaemonConfigurationError(ValueError):
    pass


def _error_response(
    *,
    status: str,
    request_id: str | None = None,
    reason: str | None = None,
) -> dict[str, Any]:
    response: dict[str, Any] = {
        "schema_version": 1,
        "type": "result",
        "status": status,
    }
    if request_id is not None:
        response["request_id"] = request_id
    if reason is not None:
        response["reason"] = reason
    return response


def _validate_inference_request(message: Any) -> dict[str, Any]:
    if not isinstance(message, dict):
        raise ValueError("message must be an object")
    required_strings = (
        "request_id",
        "composition_id",
        "app_session_id",
        "pinyin",
    )
    if any(
        not isinstance(message.get(field), str)
        or not message[field]
        or len(message[field]) > 256
        for field in required_strings
    ):
        raise ValueError("request identifiers and pinyin must be bounded strings")
    revision = message.get("revision")
    deadline_ms = message.get("deadline_ms")
    if (
        not isinstance(revision, int)
        or isinstance(revision, bool)
        or revision < 0
        or not isinstance(deadline_ms, int)
        or isinstance(deadline_ms, bool)
        or not 1 <= deadline_ms <= 5000
    ):
        raise ValueError("revision or deadline is invalid")
    if re.fullmatch(r"[a-z]+(?:'[a-z]+)*", message["pinyin"]) is None:
        raise ValueError("pinyin must contain lowercase ASCII syllables")
    context_policy = message.get("context_policy")
    context = message.get("context")
    if (
        not isinstance(context_policy, str)
        or context_policy not in {"strict", "standard", "smart"}
        or not isinstance(context, str)
    ):
        raise ValueError("context policy is invalid")
    context_limit = {"strict": 0, "standard": 100, "smart": 400}[
        context_policy
    ]
    if len(context) > context_limit:
        raise ValueError("context exceeds the selected policy")
    candidates = message.get("candidates")
    if (
        not isinstance(candidates, list)
        or not 1 <= len(candidates) <= 10
        or any(
            not isinstance(candidate, str)
            or not candidate
            or len(candidate) > 128
            for candidate in candidates
        )
        or len(candidates) != len(set(candidates))
    ):
        raise ValueError("candidates must contain 1 to 10 unique strings")
    if not isinstance(message.get("allow_sentence"), bool) or not isinstance(
        message.get("sensitive"), bool
    ):
        raise ValueError("request policy flags must be booleans")
    domain = message.get("domain")
    if domain is not None and not is_valid_domain(domain):
        raise ValueError("domain must be a bounded lowercase identifier")
    segments = message.get("segments")
    if segments is not None:
        segments = validate_pinyin_segments(
            segments, active_pinyin=message["pinyin"]
        )
    result = {
        field: message[field]
        for field in (
            "request_id",
            "composition_id",
            "revision",
            "app_session_id",
            "context_policy",
            "context",
            "pinyin",
            "candidates",
            "deadline_ms",
            "allow_sentence",
            "sensitive",
        )
    }
    if domain is not None:
        result["domain"] = domain
    if segments is not None:
        result["segments"] = segments
    return result


BASE_CAPABILITIES = [
    "rerank",
    "sentence",
    "cancel",
    "deadline",
    "latest-request-wins",
    "offline-lock",
    "decision-reasons",
    "long-input-reasons",
]
NEURAL_LATE_CAPABILITY = "sentence-late"
# Daemon shutdown is bounded: a wedged client handler (e.g. a peer that
# vanishes mid-teardown) must never block close() forever.
CLOSE_TEARDOWN_TIMEOUT_SECONDS = 5.0


class RimeAIDaemonServer:
    def __init__(
        self,
        socket_path: Path,
        engine: InferenceEngine,
        *,
        activity_notifier: Callable[[], None] | None = None,
        neural_sentence: NeuralSentenceService | None = None,
    ):
        self.socket_path = socket_path
        self.engine = engine
        self._activity_notifier = activity_notifier
        self.neural_sentence = neural_sentence
        self._server: asyncio.AbstractServer | None = None
        self._inference_executor = ThreadPoolExecutor(
            max_workers=1,
            thread_name_prefix="rimeai-inference",
        )
        self._neural_executor = ThreadPoolExecutor(
            max_workers=1,
            thread_name_prefix="rimeai-neural-sentence",
        )
        self._all_tasks: set[asyncio.Task[Any]] = set()
        self._consecutive_failures = 0
        self._circuit_open_until = 0.0

    def _record_engine_failure(self) -> None:
        self._consecutive_failures += 1
        if self._consecutive_failures >= 3:
            self._circuit_open_until = monotonic() + 30

    async def start(self) -> None:
        try:
            self._server = await prepare_unix_listener_socket(
                self.socket_path,
                self._handle_client,
            )
        except SocketPathTooLongError as error:
            raise DaemonConfigurationError(
                "Unix socket path exceeds the macOS 103-byte limit"
            ) from error
        except RuntimeDirectoryIsSymlinkError as error:
            raise DaemonConfigurationError(
                "runtime directory must not be a symbolic link"
            ) from error
        except NotASocketPathError as error:
            raise DaemonConfigurationError(
                "refusing to replace a non-socket runtime path"
            ) from error
        except ExistingSocketUnverifiableError as failure:
            raise DaemonConfigurationError(
                f"cannot verify existing runtime socket: {failure.cause}"
            ) from failure.cause
        except AlreadyListeningError as error:
            raise DaemonConfigurationError(
                "another RimeAI daemon is already running"
            ) from error

    async def close(self) -> None:
        if self._server is not None:
            self._server.close()
            await self._server.wait_closed()
            self._server = None
        for task in list(self._all_tasks):
            task.cancel()
        if self._all_tasks:
            with contextlib.suppress(asyncio.TimeoutError):
                await asyncio.wait_for(
                    asyncio.gather(
                        *self._all_tasks, return_exceptions=True
                    ),
                    timeout=CLOSE_TEARDOWN_TIMEOUT_SECONDS,
                )
        if self.neural_sentence is not None:
            self.neural_sentence.close()
        if self.socket_path.exists():
            mode = self.socket_path.lstat().st_mode
            if stat.S_ISSOCK(mode):
                self.socket_path.unlink()
        # A stuck engine call cannot be interrupted mid-inference; waiting
        # here would block the event loop up to the request deadline. The
        # interpreter joins the worker at exit (bounded by that deadline).
        self._inference_executor.shutdown(wait=False, cancel_futures=True)
        self._neural_executor.shutdown(wait=False, cancel_futures=True)

    async def serve_forever(self) -> None:
        if self._server is None:
            raise DaemonConfigurationError("daemon server has not started")
        async with self._server:
            await self._server.serve_forever()

    async def _write(
        self,
        writer: asyncio.StreamWriter,
        lock: asyncio.Lock,
        payload: dict[str, Any],
    ) -> None:
        encoded = (
            json.dumps(
                payload,
                ensure_ascii=False,
                separators=(",", ":"),
                sort_keys=True,
            )
            + "\n"
        ).encode("utf-8")
        async with lock:
            writer.write(encoded)
            await writer.drain()

    async def _handle_client(
        self,
        reader: asyncio.StreamReader,
        writer: asyncio.StreamWriter,
    ) -> None:
        peer_socket = writer.get_extra_info("socket")
        if peer_socket is None:
            writer.close()
            await writer.wait_closed()
            return
        try:
            if peer_uid(peer_socket.fileno()) != os.geteuid():
                writer.close()
                await writer.wait_closed()
                return
        except (OSError, PeerIdentityError):
            writer.close()
            await writer.wait_closed()
            return

        write_lock = asyncio.Lock()
        hello_complete = False
        client_wants_late_sentences = False
        pending_by_key: dict[tuple[str, str], asyncio.Task[Any]] = {}
        pending_by_id: dict[str, asyncio.Task[Any]] = {}
        neural_by_key: dict[tuple[str, str], asyncio.Task[Any]] = {}
        neural_by_id: dict[str, asyncio.Task[Any]] = {}
        latest_revision: dict[tuple[str, str], int] = {}
        try:
            while not reader.at_eof():
                try:
                    line = await reader.readline()
                except (ValueError, asyncio.LimitOverrunError):
                    break
                if not line:
                    break
                try:
                    message = json.loads(line)
                except (UnicodeDecodeError, json.JSONDecodeError):
                    await self._write(
                        writer,
                        write_lock,
                        _error_response(status="protocol_error"),
                    )
                    break
                if (
                    not isinstance(message, dict)
                    or message.get("schema_version") != 1
                ):
                    await self._write(
                        writer,
                        write_lock,
                        _error_response(status="incompatible_protocol"),
                    )
                    break
                message_type = message.get("type")
                if not hello_complete:
                    if (
                        message_type != "hello"
                        or not isinstance(message.get("client_id"), str)
                        or not message["client_id"]
                        or not isinstance(message.get("capabilities"), list)
                    ):
                        await self._write(
                            writer,
                            write_lock,
                            _error_response(status="hello_required"),
                        )
                        break
                    hello_complete = True
                    client_capabilities = message["capabilities"]
                    client_wants_late_sentences = (
                        self.neural_sentence is not None
                        and isinstance(client_capabilities, list)
                        and NEURAL_LATE_CAPABILITY in client_capabilities
                    )
                    capabilities = list(BASE_CAPABILITIES)
                    model_artifacts = list(
                        getattr(self.engine, "artifacts", [])
                    )
                    if self.neural_sentence is not None:
                        capabilities.append(NEURAL_LATE_CAPABILITY)
                        model_artifacts.extend(
                            self.neural_sentence.artifacts()
                        )
                    await self._write(
                        writer,
                        write_lock,
                        {
                            "schema_version": 1,
                            "type": "hello",
                            "status": "ok",
                            "protocol_version": 1,
                            "capabilities": capabilities,
                            "offline_lock": True,
                            "model_artifact_id": self.engine.artifact_id,
                            "model_artifacts": model_artifacts,
                        },
                    )
                    continue
                if message_type == "cancel":
                    request_id = message.get("request_id")
                    task = (
                        pending_by_id.get(request_id)
                        if isinstance(request_id, str)
                        else None
                    )
                    if task is not None:
                        task.cancel()
                    neural_task = (
                        neural_by_id.get(request_id)
                        if isinstance(request_id, str)
                        else None
                    )
                    if neural_task is not None:
                        neural_task.cancel()
                    await self._write(
                        writer,
                        write_lock,
                        {
                            "schema_version": 1,
                            "type": "cancelled",
                            "request_id": request_id,
                            "status": "ok",
                        },
                    )
                    continue
                if message_type != "infer":
                    await self._write(
                        writer,
                        write_lock,
                        _error_response(status="unsupported_message"),
                    )
                    continue
                if self._activity_notifier is not None:
                    self._activity_notifier()
                try:
                    request = _validate_inference_request(message)
                except ValueError:
                    request_id = (
                        message.get("request_id")
                        if isinstance(message.get("request_id"), str)
                        else None
                    )
                    await self._write(
                        writer,
                        write_lock,
                        _error_response(
                            status="invalid_request",
                            request_id=request_id,
                        ),
                    )
                    continue
                request_id = request["request_id"]
                if request["sensitive"]:
                    await self._write(
                        writer,
                        write_lock,
                        _error_response(
                            status="privacy_blocked",
                            request_id=request_id,
                        ),
                    )
                    continue
                if monotonic() < self._circuit_open_until:
                    await self._write(
                        writer,
                        write_lock,
                        _error_response(
                            status="circuit_open",
                            request_id=request_id,
                        ),
                    )
                    continue
                key = (
                    request["app_session_id"],
                    request["composition_id"],
                )
                previous_revision = latest_revision.get(key, -1)
                if request["revision"] <= previous_revision:
                    await self._write(
                        writer,
                        write_lock,
                        _error_response(
                            status="stale",
                            request_id=request_id,
                        ),
                    )
                    continue
                latest_revision[key] = request["revision"]
                if len(latest_revision) > 1_024:
                    latest_revision.pop(next(iter(latest_revision)))
                previous_task = pending_by_key.get(key)
                if previous_task is not None:
                    previous_task.cancel()
                task = asyncio.create_task(
                    self._run_inference(
                        request,
                        key,
                        latest_revision,
                        writer,
                        write_lock,
                    )
                )
                pending_by_key[key] = task
                pending_by_id[request_id] = task
                self._all_tasks.add(task)

                def cleanup(
                    completed: asyncio.Task[Any],
                    *,
                    current_key: tuple[str, str] = key,
                    current_id: str = request_id,
                ) -> None:
                    self._all_tasks.discard(completed)
                    if pending_by_key.get(current_key) is completed:
                        pending_by_key.pop(current_key, None)
                    if pending_by_id.get(current_id) is completed:
                        pending_by_id.pop(current_id, None)

                task.add_done_callback(cleanup)
                if (
                    client_wants_late_sentences
                    and request["allow_sentence"]
                ):
                    previous_neural = neural_by_key.get(key)
                    if previous_neural is not None:
                        previous_neural.cancel()
                    neural_task = asyncio.create_task(
                        self._run_neural_sentence(
                            request,
                            key,
                            latest_revision,
                            writer,
                            write_lock,
                        )
                    )
                    neural_by_key[key] = neural_task
                    neural_by_id[request_id] = neural_task
                    self._all_tasks.add(neural_task)

                    def neural_cleanup(
                        completed: asyncio.Task[Any],
                        *,
                        current_key: tuple[str, str] = key,
                        current_id: str = request_id,
                    ) -> None:
                        self._all_tasks.discard(completed)
                        if neural_by_key.get(current_key) is completed:
                            neural_by_key.pop(current_key, None)
                        if neural_by_id.get(current_id) is completed:
                            neural_by_id.pop(current_id, None)

                    neural_task.add_done_callback(neural_cleanup)
        finally:
            for task in list(pending_by_id.values()):
                task.cancel()
            for task in list(neural_by_id.values()):
                task.cancel()
            writer.close()
            with contextlib.suppress(BrokenPipeError, ConnectionResetError):
                await writer.wait_closed()

    async def _run_inference(
        self,
        request: dict[str, Any],
        key: tuple[str, str],
        latest_revision: dict[tuple[str, str], int],
        writer: asyncio.StreamWriter,
        write_lock: asyncio.Lock,
    ) -> None:
        loop = asyncio.get_running_loop()
        started_at = monotonic()
        try:
            future = loop.run_in_executor(
                self._inference_executor,
                self.engine.infer,
                request,
            )
            result = await asyncio.wait_for(
                future,
                timeout=request["deadline_ms"] / 1000,
            )
        except asyncio.CancelledError:
            return
        except asyncio.TimeoutError:
            self._record_engine_failure()
            await self._write(
                writer,
                write_lock,
                _error_response(
                    status="timeout",
                    request_id=request["request_id"],
                ),
            )
            return
        except Exception:
            self._record_engine_failure()
            await self._write(
                writer,
                write_lock,
                _error_response(
                    status="engine_error",
                    request_id=request["request_id"],
                ),
            )
            return
        if latest_revision.get(key) != request["revision"]:
            return
        confidence = result.get("confidence") if isinstance(result, dict) else None
        decision = result.get("decision") if isinstance(result, dict) else None
        ranked_candidate = (
            result.get("ranked_candidate")
            if isinstance(result, dict)
            else None
        )
        sentence_suggestion = (
            result.get("sentence_suggestion")
            if isinstance(result, dict)
            else None
        )
        if (
            not isinstance(result, dict)
            or decision
            not in {
                "ranked_candidate",
                "sentence_suggestion",
                "same_top_candidate",
                "insufficient_candidates",
                "below_confidence",
                "no_candidate",
                "sentence_too_long",
                "sentence_incomplete",
            }
            or not isinstance(ranked_candidate, str)
            or not isinstance(sentence_suggestion, str)
            or not isinstance(confidence, (int, float))
            or isinstance(confidence, bool)
            or not math.isfinite(confidence)
            or not 0 <= confidence <= 1
            or (
                ranked_candidate
                and ranked_candidate not in request["candidates"]
            )
            or len(ranked_candidate) > 128
            or "\n" in ranked_candidate
            or "\r" in ranked_candidate
            or len(sentence_suggestion) > 30
            or "\n" in sentence_suggestion
            or "\r" in sentence_suggestion
            or (
                decision == "ranked_candidate"
                and (not ranked_candidate or sentence_suggestion)
            )
            or (
                decision == "sentence_suggestion"
                and (
                    not request["allow_sentence"]
                    or not sentence_suggestion
                    or ranked_candidate
                )
            )
            or (
                decision
                in {
                    "same_top_candidate",
                    "insufficient_candidates",
                    "below_confidence",
                    "no_candidate",
                    "sentence_too_long",
                    "sentence_incomplete",
                }
                and (ranked_candidate or sentence_suggestion)
            )
        ):
            self._record_engine_failure()
            await self._write(
                writer,
                write_lock,
                _error_response(
                    status="engine_error",
                    request_id=request["request_id"],
                ),
            )
            return
        self._consecutive_failures = 0
        await self._write(
            writer,
            write_lock,
            {
                "schema_version": 1,
                "type": "result",
                "status": "ok",
                "request_id": request["request_id"],
                "composition_id": request["composition_id"],
                "revision": request["revision"],
                "app_session_id": request["app_session_id"],
                "decision": decision,
                "ranked_candidate": ranked_candidate,
                "sentence_suggestion": (
                    sentence_suggestion
                    if request["allow_sentence"]
                    else ""
                ),
                "confidence": float(confidence),
                "model_artifact_id": self.engine.artifact_id,
                "elapsed_ms": round((monotonic() - started_at) * 1000, 3),
            },
        )

    async def _run_neural_sentence(
        self,
        request: dict[str, Any],
        key: tuple[str, str],
        latest_revision: dict[tuple[str, str], int],
        writer: asyncio.StreamWriter,
        write_lock: asyncio.Lock,
    ) -> None:
        """Async neural sentence tier: decode off the sync executor and
        deliver a `sentence_late` frame bound to the request, but only
        while that revision is still the latest for the key and within
        the configured budget. Failures never surface as errors — the
        tier simply abstains."""
        service = self.neural_sentence
        if service is None:
            return
        if latest_revision.get(key) != request["revision"]:
            # Reveal B-F5/C-F2: drop the request BEFORE occupying the
            # single-thread neural executor — keystrokes already
            # advanced the revision, so decoding it would be pure
            # wasted GPU work queued ahead of the live request.
            return
        loop = asyncio.get_running_loop()
        started_at = monotonic()
        try:
            future = loop.run_in_executor(
                self._neural_executor,
                functools.partial(
                    service.decode,
                    request,
                    deadline=monotonic() + service.budget_ms / 1000,
                ),
            )
            payload = await asyncio.wait_for(
                future,
                timeout=service.budget_ms / 1000,
            )
        except (asyncio.CancelledError, asyncio.TimeoutError):
            return
        except Exception:
            return
        if payload is None:
            return
        if latest_revision.get(key) != request["revision"]:
            return
        suggestion = payload.get("suggestion")
        confidence = payload.get("confidence")
        artifact_id = payload.get("model_artifact_id")
        if (
            not isinstance(suggestion, str)
            or not suggestion
            or len(suggestion) > 30
            or "\n" in suggestion
            or "\r" in suggestion
            or not isinstance(confidence, (int, float))
            or isinstance(confidence, bool)
            or not math.isfinite(confidence)
            or not 0 <= confidence <= 1
            or confidence < service.min_confidence
        ):
            return
        await self._write(
            writer,
            write_lock,
            {
                "schema_version": 1,
                "type": "sentence_late",
                "status": "ok",
                "request_id": request["request_id"],
                "composition_id": request["composition_id"],
                "revision": request["revision"],
                "app_session_id": request["app_session_id"],
                "sentence_suggestion": suggestion,
                "confidence": float(confidence),
                "model_artifact_id": (
                    artifact_id
                    if isinstance(artifact_id, str) and artifact_id
                    else self.engine.artifact_id
                ),
                "elapsed_ms": round(
                    (monotonic() - started_at) * 1000, 3
                ),
            },
        )
