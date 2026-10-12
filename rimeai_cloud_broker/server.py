"""Same-user Unix socket broker with latest-request-wins cancellation."""

from __future__ import annotations

import asyncio
import contextlib
import json
import math
import os
import re
import sqlite3
import stat
import sys
from collections.abc import Callable, Sequence
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

from rimeai_daemon.segment_policy import (
    split_segmented_text,
    validate_pinyin_segments,
)

from .history_index import (
    EMBEDDING_INDEXING_ENABLED,
    HistoryEmbeddingIndexer,
)
from .qwen import (
    ALLOWED_MODELS,
    CONTINUATION_ALLOWED_MODELS,
    ENDPOINT,
    GENERATE_MAXIMUM_CHARACTERS,
    PROVIDER,
    _han_count,
)


class CandidateRanker(Protocol):
    def rank(
        self, cloud_request: dict[str, Any]
    ) -> dict[str, Any]: ...

    def rank_continuation(
        self, cloud_request: dict[str, Any]
    ) -> dict[str, Any]: ...

    def embed_texts(
        self, texts: Sequence[str]
    ) -> list[list[float]]: ...


class CloudBrokerConfigurationError(ValueError):
    pass


def _bounded_string(value: Any, maximum: int) -> bool:
    return isinstance(value, str) and 0 < len(value.encode()) <= maximum


def validate_request(message: Any) -> dict[str, Any]:
    if not isinstance(message, dict):
        raise ValueError("request must be an object")
    if message.get("type") != "inference":
        raise ValueError("request type is invalid")
    if not _bounded_string(message.get("api_key"), 512):
        raise ValueError("cloud credential is invalid")
    for field, maximum in {
        "request_id": 256,
        "composition_id": 64,
        "bundle_id": 512,
        "app_session_id": 512,
        "client_session_id": 256,
        "pinyin": 256,
    }.items():
        if not _bounded_string(message.get(field), maximum):
            raise ValueError(f"{field} is invalid")
    # The raw mixed composition (Chinese pinyin interleaved with English
    # words) is the input, so letters of both cases are accepted — mirror
    # of Swift CloudInferenceRequest.isValid (tier removal 2026-10-13).
    if re.fullmatch(r"[A-Za-z']+", message["pinyin"]) is None:
        raise ValueError("pinyin is invalid")
    if message.get("model_id") not in ALLOWED_MODELS:
        raise ValueError("model is not allowed")
    deadline = message.get("deadline_ms")
    if (
        not isinstance(deadline, int)
        or isinstance(deadline, bool)
        or not 1 <= deadline <= 30000
    ):
        raise ValueError("deadline must be from 1 to 30000 ms")
    revision = message.get("revision")
    generation = message.get("history_generation")
    if (
        not isinstance(revision, int)
        or isinstance(revision, bool)
        or revision < 0
        or not isinstance(generation, int)
        or isinstance(generation, bool)
        or generation < 0
    ):
        raise ValueError("revision or history generation is invalid")
    recent = message.get("recent_context")
    snippets = message.get("history_snippets")
    if (
        not isinstance(recent, str)
        or len(recent) > 600
        or "\x00" in recent
    ):
        raise ValueError("recent context is invalid")
    if not isinstance(snippets, list) or len(snippets) > 8:
        raise ValueError("history snippets are invalid")
    for snippet in snippets:
        if (
            not isinstance(snippet, dict)
            or not _bounded_string(snippet.get("id"), 128)
            or not _bounded_string(snippet.get("text"), 4096)
            or "\x00" in snippet["text"]
            or not _bounded_string(snippet.get("bundle_id"), 512)
            or not isinstance(snippet.get("committed_at_ms"), int)
            or isinstance(snippet.get("committed_at_ms"), bool)
            or not isinstance(snippet.get("score"), (int, float))
            or isinstance(snippet.get("score"), bool)
            or not math.isfinite(snippet["score"])
        ):
            raise ValueError("history snippet is invalid")
    # The generation contract never reads the candidate pool (product
    # decision 2026-10-12 removed choose/keep ranking): candidates and
    # candidate_pool_hash are accepted-but-ignored so a not-yet-rebuilt
    # client keeps working through the transition.
    if message.get("candidate_pool_hash") is not None and not (
        _bounded_string(message.get("candidate_pool_hash"), 128)
    ):
        raise ValueError("candidate pool hash is invalid")
    segments = message.get("segments")
    if segments is not None:
        # Canonicalize to the three known keys so the response echo and the
        # prompt stay byte-stable against the Swift mirror.
        message["segments"] = validate_pinyin_segments(
            segments, active_pinyin=message["pinyin"]
        )
    return message


def validate_continuation_request(message: Any) -> dict[str, Any]:
    if not isinstance(message, dict):
        raise ValueError("request must be an object")
    if message.get("type") != "continuation":
        raise ValueError("request type is invalid")
    if not _bounded_string(message.get("api_key"), 512):
        raise ValueError("cloud credential is invalid")
    for field, maximum in {
        "request_id": 256,
        "client_session_id": 256,
        "bundle_id": 512,
        "model_id": 128,
    }.items():
        if not _bounded_string(message.get(field), maximum):
            raise ValueError(f"{field} is invalid")
    if message.get("model_id") not in CONTINUATION_ALLOWED_MODELS:
        raise ValueError("model is not allowed")
    deadline = message.get("deadline_ms")
    if (
        not isinstance(deadline, int)
        or isinstance(deadline, bool)
        or not 1 <= deadline <= 30000
    ):
        raise ValueError("deadline must be from 1 to 30000 ms")
    generation = message.get("history_generation")
    if generation is not None and (
        not isinstance(generation, int)
        or isinstance(generation, bool)
        or generation < 0
    ):
        raise ValueError("history generation is invalid")
    recent = message.get("recent_context")
    if (
        not isinstance(recent, str)
        or len(recent) > 400
        or "\x00" in recent
        or _han_count(recent) < 4
    ):
        raise ValueError("recent context is invalid")
    snippets = message.get("history_snippets")
    if not isinstance(snippets, list) or len(snippets) > 8:
        raise ValueError("history snippets are invalid")
    # Mirrors the inference-path snippet validation above deliberately:
    # both layers keep their own copy of the gate, like every other
    # duplicated check in this module.
    for snippet in snippets:
        if (
            not isinstance(snippet, dict)
            or not _bounded_string(snippet.get("id"), 128)
            or not _bounded_string(snippet.get("text"), 4096)
            or "\x00" in snippet["text"]
            or not _bounded_string(snippet.get("bundle_id"), 512)
            or not isinstance(snippet.get("committed_at_ms"), int)
            or isinstance(snippet.get("committed_at_ms"), bool)
            or not isinstance(snippet.get("score"), (int, float))
            or isinstance(snippet.get("score"), bool)
            or not math.isfinite(snippet["score"])
        ):
            raise ValueError("history snippet is invalid")
    return message


def validate_decision(
    decision: Any,
    cloud_request: dict[str, Any],
) -> dict[str, Any]:
    """Protocol-shape check for ranker decisions, mirroring the ranker's
    structural gates (deliberate duplication, like every gate in this
    module). The only decisions are generate and abstain (product decision
    2026-10-12 removed choose/keep ranking); pinyin alignment is the
    model's job, never checked here. Transitional exception: `_run`
    fabricates a `keep` decision for clients that did not advertise
    text-generation — that bypasses this validator on purpose and dies
    with the legacy client support."""
    if not isinstance(decision, dict):
        raise ValueError("decision must be an object")
    action = decision.get("decision")
    candidate_id = decision.get("candidate_id")
    confidence = decision.get("confidence")
    reason = decision.get("reason")
    if reason not in {
        "context_match",
        "history_match",
        "typo_match",
        "rime_rank",
        "uncertain",
    }:
        raise ValueError("decision reason is invalid")
    if action == "abstain":
        if candidate_id is not None or confidence is not None:
            raise ValueError("non-choice decision contains a candidate")
        if decision.get("text") is not None:
            raise ValueError("non-generate decision contains text")
        return decision
    text = decision.get("text")
    if (
        action != "generate"
        or candidate_id is not None
        or not isinstance(text, str)
        or not text
        or not isinstance(confidence, (int, float))
        or isinstance(confidence, bool)
        or not math.isfinite(confidence)
        or not 0 < confidence <= 1
    ):
        raise ValueError("generated sentence is invalid")
    segments = cloud_request.get("segments")
    if (
        len(text) > GENERATE_MAXIMUM_CHARACTERS
        or any(ord(char) < 0x20 or ord(char) == 0x7F for char in text)
        or (
            segments is not None
            and split_segmented_text(text, segments) is None
        )
    ):
        raise ValueError("generated sentence is invalid")
    return decision


class CloudBrokerServer:
    def __init__(
        self,
        socket_path: Path,
        ranker: CandidateRanker,
        history_indexer: HistoryEmbeddingIndexer | None = None,
        activity_notifier: Callable[[], None] | None = None,
    ):
        self.socket_path = socket_path
        self.ranker = ranker
        self.history_indexer = history_indexer
        # Mirrors the daemon server: called for every accepted inference /
        # continuation request so a co-located idle scheduler (consolidation)
        # can tell "user is typing" from "process has merely been up".
        self._activity_notifier = activity_notifier
        self._server: asyncio.AbstractServer | None = None
        self._tasks: set[asyncio.Task[Any]] = set()
        self._index_task: asyncio.Task[Any] | None = None
        # Cancellation cannot interrupt a blocking urllib call already in a
        # thread. A single worker ensures obsolete calls cannot fan out into
        # concurrent paid requests while latest-request-wins suppresses them.
        self._rank_executor = ThreadPoolExecutor(
            max_workers=1,
            thread_name_prefix="rimeai-cloud-rank",
        )

    async def start(self) -> None:
        try:
            self._server = await prepare_unix_listener_socket(
                self.socket_path,
                self._handle_client,
            )
        except SocketPathTooLongError as failure:
            raise CloudBrokerConfigurationError(
                "socket path is too long"
            ) from failure
        except RuntimeDirectoryIsSymlinkError as failure:
            raise CloudBrokerConfigurationError(
                "runtime path is a symlink"
            ) from failure
        except NotASocketPathError as failure:
            raise CloudBrokerConfigurationError(
                "refusing non-socket path"
            ) from failure
        except ExistingSocketUnverifiableError as failure:
            raise CloudBrokerConfigurationError(
                "cannot verify existing cloud socket"
            ) from failure.cause
        except AlreadyListeningError as failure:
            raise CloudBrokerConfigurationError(
                "another cloud broker is already running"
            ) from failure
        if self.history_indexer is not None:
            self._index_task = asyncio.create_task(self._index_loop())

    async def close(self) -> None:
        if self._index_task is not None:
            self._index_task.cancel()
            await asyncio.gather(self._index_task, return_exceptions=True)
            self._index_task = None
        if self._server is not None:
            self._server.close()
            await self._server.wait_closed()
            self._server = None
        for task in tuple(self._tasks):
            task.cancel()
        if self._tasks:
            await asyncio.gather(*self._tasks, return_exceptions=True)
        if self.socket_path.exists() and stat.S_ISSOCK(
            self.socket_path.lstat().st_mode
        ):
            self.socket_path.unlink()
        self._rank_executor.shutdown(wait=False, cancel_futures=True)

    async def serve_forever(self) -> None:
        if self._server is None:
            raise CloudBrokerConfigurationError("broker is not started")
        async with self._server:
            await self._server.serve_forever()

    async def _index_loop(self) -> None:
        if self.history_indexer is None:
            return
        indexer = self.history_indexer
        # With indexing disabled, run_once only drains stale pending jobs;
        # no reason to wake every 5s — an hourly sweep keeps new rows from
        # piling up while the kill switch stays off.
        interval = 5 if EMBEDDING_INDEXING_ENABLED else 3600
        while True:
            try:
                await asyncio.to_thread(indexer.run_once, self.ranker)
            except Exception as error:
                sys.stderr.write(
                    f"[cloud] index loop error "
                    f"{type(error).__name__}: {error}\n"
                )
                sys.stderr.flush()
            await asyncio.sleep(interval)

    async def _write(
        self,
        writer: asyncio.StreamWriter,
        lock: asyncio.Lock,
        payload: dict[str, Any],
    ) -> None:
        encoded = (
            json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
            + "\n"
        ).encode()
        async with lock:
            writer.write(encoded)
            await writer.drain()

    async def _handle_client(
        self,
        reader: asyncio.StreamReader,
        writer: asyncio.StreamWriter,
    ) -> None:
        peer = writer.get_extra_info("socket")
        try:
            if peer is None or peer_uid(peer.fileno()) != os.geteuid():
                return
        except (OSError, PeerIdentityError):
            return
        lock = asyncio.Lock()
        hello = False
        client_capabilities: set[str] = set()
        pending: dict[str, asyncio.Task[Any]] = {}
        pending_continuations: dict[str, asyncio.Task[Any]] = {}
        latest: dict[tuple[str, str], int] = {}
        try:
            while not reader.at_eof():
                try:
                    line = await reader.readline()
                except (ValueError, asyncio.LimitOverrunError):
                    # Overlong line: the reader's limit was exceeded, not a
                    # decode failure; drop the connection without a frame.
                    break
                if not line:
                    break
                try:
                    message = json.loads(line)
                except (UnicodeDecodeError, json.JSONDecodeError):
                    break
                if not isinstance(message, dict) or message.get(
                    "schema_version"
                ) != 1:
                    break
                message_type = message.get("type")
                if not hello:
                    if message_type != "hello" or not _bounded_string(
                        message.get("client_id"), 256
                    ):
                        break
                    advertised = message.get("capabilities")
                    if isinstance(advertised, list):
                        client_capabilities = {
                            item
                            for item in advertised
                            if isinstance(item, str) and 0 < len(item) <= 64
                        }
                    hello = True
                    capabilities = [
                        "candidate-id-only",
                        "cancel",
                        "latest-request-wins",
                        "history-generation",
                        "text-generation",
                        "continuation-generation",
                    ]
                    await self._write(
                        writer,
                        lock,
                        {
                            "schema_version": 1,
                            "type": "hello",
                            "status": "ok",
                            "protocol_version": 1,
                            "provider": PROVIDER,
                            "endpoint": ENDPOINT,
                            "models": sorted(ALLOWED_MODELS),
                            "capabilities": capabilities,
                        },
                    )
                    continue
                if message_type == "cancel":
                    request_id = message.get("request_id")
                    if isinstance(request_id, str):
                        task = pending.get(request_id)
                        if task is None:
                            task = pending_continuations.get(request_id)
                        if task is not None:
                            task.cancel()
                    continue
                if message_type == "continuation":
                    try:
                        continuation_request = validate_continuation_request(
                            message
                        )
                    except ValueError:
                        continue
                    if self._activity_notifier is not None:
                        self._activity_notifier()
                    # Latest-wins: a new continuation supersedes any
                    # in-flight one; the client only ever wants the
                    # suggestion for the most recent commit.
                    for old_id, old_task in tuple(
                        pending_continuations.items()
                    ):
                        if not old_task.done():
                            old_task.cancel()
                        pending_continuations.pop(old_id, None)
                    task = asyncio.create_task(
                        self._run_continuation(
                            continuation_request,
                            writer,
                            lock,
                            client_capabilities,
                        )
                    )
                    pending_continuations[
                        continuation_request["request_id"]
                    ] = task
                    self._tasks.add(task)
                    task.add_done_callback(self._tasks.discard)
                    continue
                if message_type != "inference":
                    continue
                try:
                    cloud_request = validate_request(message)
                except ValueError:
                    continue
                if self._activity_notifier is not None:
                    self._activity_notifier()
                key = (
                    cloud_request["app_session_id"],
                    cloud_request["composition_id"],
                )
                if cloud_request["revision"] <= latest.get(key, -1):
                    continue
                latest[key] = cloud_request["revision"]
                if len(latest) > 1_024:
                    latest.pop(next(iter(latest)))
                for old_id, old_task in tuple(pending.items()):
                    if not old_task.done():
                        old_task.cancel()
                    pending.pop(old_id, None)
                task = asyncio.create_task(
                    self._run(
                        cloud_request,
                        key,
                        latest,
                        writer,
                        lock,
                        client_capabilities,
                    )
                )
                pending[cloud_request["request_id"]] = task
                self._tasks.add(task)
                task.add_done_callback(self._tasks.discard)
        finally:
            for task in pending.values():
                task.cancel()
            for task in pending_continuations.values():
                task.cancel()
            writer.close()
            with contextlib.suppress(BrokenPipeError, ConnectionResetError):
                await writer.wait_closed()

    async def _run(
        self,
        cloud_request: dict[str, Any],
        key: tuple[str, str],
        latest: dict[tuple[str, str], int],
        writer: asyncio.StreamWriter,
        lock: asyncio.Lock,
        client_capabilities: set[str],
    ) -> None:
        started = monotonic()
        budget_seconds = cloud_request["deadline_ms"] / 1000
        remaining = budget_seconds
        revision = cloud_request["revision"]
        try:
            if self.history_indexer is not None:
                remaining = budget_seconds - (monotonic() - started)
                if remaining <= 0:
                    return
                prepared = await asyncio.wait_for(
                    asyncio.to_thread(
                        self._prepare_history_request,
                        cloud_request,
                    ),
                    timeout=remaining,
                )
                if prepared is None:
                    return
                cloud_request = prepared
            remaining = budget_seconds - (monotonic() - started)
            if remaining <= 0:
                return
            raw_decision = await asyncio.wait_for(
                asyncio.get_running_loop().run_in_executor(
                    self._rank_executor,
                    self.ranker.rank,
                    cloud_request,
                ),
                timeout=remaining,
            )
            decision = validate_decision(raw_decision, cloud_request)
        except asyncio.TimeoutError:
            sys.stderr.write(
                f"[cloud] timeout revision={revision} "
                f"remaining={remaining:.2f}s\n"
            )
            sys.stderr.flush()
            return
        except asyncio.CancelledError:
            sys.stderr.write(f"[cloud] cancelled revision={revision}\n")
            sys.stderr.flush()
            return
        except Exception as exc:
            sys.stderr.write(
                f"[cloud] error revision={revision} "
                f"{type(exc).__name__}: {exc}\n"
            )
            sys.stderr.flush()
            return
        if latest.get(key) != cloud_request["revision"]:
            return
        if self.history_indexer is not None:
            generation = await asyncio.to_thread(
                self.history_indexer.generation
            )
            if (
                generation is not None
                and generation != cloud_request["history_generation"]
            ):
                return
        elapsed = (monotonic() - started) * 1000
        if elapsed > cloud_request["deadline_ms"]:
            return
        # Decision observability: the log is a 0600 local file and never
        # records pinyin or generated text, only the decision shape.
        sys.stderr.write(
            f"[cloud] decision={decision['decision']} "
            f"segments={len(cloud_request.get('segments') or ())} "
            f"elapsed={elapsed:.0f}ms\n"
        )
        sys.stderr.flush()
        if (
            decision["decision"] == "generate"
            and "text-generation" not in client_capabilities
        ):
            # Clients that did not advertise text-generation cannot decode a
            # generate decision; a decode failure tears down their whole
            # connection, so downgrade to keep instead.
            decision = {
                "decision": "keep",
                "candidate_id": None,
                "confidence": None,
                "reason": "rime_rank",
            }
        response: dict[str, Any] = {
            "schema_version": 1,
            "type": "result",
            "status": "ok",
            "request_id": cloud_request["request_id"],
            "composition_id": cloud_request["composition_id"],
            "revision": cloud_request["revision"],
            "app_session_id": cloud_request["app_session_id"],
            "client_session_id": cloud_request["client_session_id"],
            "history_generation": cloud_request["history_generation"],
            "decision": decision["decision"],
            "candidate_id": decision["candidate_id"],
            "confidence": decision["confidence"],
            "reason": decision["reason"],
            "model_id": cloud_request["model_id"],
            "elapsed_ms": round(elapsed, 3),
        }
        # Transitional echo: clients rebuilt after the candidate-pool
        # removal no longer send candidate_pool_hash; older clients still
        # compare it byte for byte, so echo it only when present.
        if cloud_request.get("candidate_pool_hash") is not None:
            response["candidate_pool_hash"] = cloud_request[
                "candidate_pool_hash"
            ]
        if decision["decision"] == "generate":
            response["generated_text"] = decision["text"]
            # Echo the request pinyin verbatim: the client compares byte
            # for byte, and normalization would strip apostrophes.
            response["generated_pinyin"] = cloud_request["pinyin"]
            segments = cloud_request.get("segments")
            if segments is not None:
                # Canonical JSON echo of the validated segments; the client
                # compares this string byte for byte.
                response["generated_segments"] = json.dumps(
                    segments,
                    sort_keys=True,
                    ensure_ascii=False,
                    separators=(",", ":"),
                )
        await self._write(writer, lock, response)

    async def _run_continuation(
        self,
        cloud_request: dict[str, Any],
        writer: asyncio.StreamWriter,
        lock: asyncio.Lock,
        client_capabilities: set[str],
    ) -> None:
        started = monotonic()
        budget_seconds = cloud_request["deadline_ms"] / 1000
        request_id = cloud_request["request_id"]

        async def respond(
            decision: str,
            generated_text: str | None,
            confidence: float | None,
            reason: str | None,
        ) -> None:
            response: dict[str, Any] = {
                "schema_version": 1,
                "type": "result",
                "status": "ok",
                "request_id": request_id,
                "decision": decision,
                "confidence": confidence,
                "reason": reason,
                "model_id": cloud_request["model_id"],
                "elapsed_ms": round((monotonic() - started) * 1000, 3),
            }
            if decision == "generate":
                response["generated_text"] = generated_text
            await self._write(writer, lock, response)

        if "continuation-generation" not in client_capabilities:
            # Old clients cannot decode a suggestion; answer abstain so
            # they degrade silently instead of tearing down the
            # connection on an unknown frame.
            await respond("abstain", None, None, "capability_absent")
            return
        remaining = budget_seconds
        try:
            remaining = budget_seconds - (monotonic() - started)
            if remaining <= 0:
                return
            decision = await asyncio.wait_for(
                asyncio.get_running_loop().run_in_executor(
                    self._rank_executor,
                    self.ranker.rank_continuation,
                    cloud_request,
                ),
                timeout=remaining,
            )
        except asyncio.TimeoutError:
            sys.stderr.write(
                f"[cloud] continuation timeout request={request_id}\n"
            )
            sys.stderr.flush()
            return
        except asyncio.CancelledError:
            sys.stderr.write(
                f"[cloud] continuation cancelled request={request_id}\n"
            )
            sys.stderr.flush()
            return
        except Exception as exc:
            sys.stderr.write(
                f"[cloud] continuation error request={request_id} "
                f"{type(exc).__name__}: {exc}\n"
            )
            sys.stderr.flush()
            return
        elapsed = (monotonic() - started) * 1000
        if elapsed > cloud_request["deadline_ms"]:
            return
        sys.stderr.write(
            f"[cloud] continuation decision={decision['decision']} "
            f"elapsed={elapsed:.0f}ms\n"
        )
        sys.stderr.flush()
        await respond(
            decision["decision"],
            decision.get("generated_text"),
            decision.get("confidence"),
            decision.get("reason"),
        )

    def _prepare_history_request(
        self,
        cloud_request: dict[str, Any],
    ) -> dict[str, Any] | None:
        """Generation-drift gate: drop the request when the visible history
        generation moved under the client's feet.

        Purely optional bookkeeping — a transient storage failure degrades
        to serving the request unchecked instead of dropping the response
        (the prompt carries no history content, so nothing else depends on
        this read)."""
        assert self.history_indexer is not None
        try:
            generation = self.history_indexer.generation()
        except (OSError, sqlite3.Error):
            return cloud_request
        if (
            generation is not None
            and generation != cloud_request["history_generation"]
        ):
            return None
        return cloud_request
