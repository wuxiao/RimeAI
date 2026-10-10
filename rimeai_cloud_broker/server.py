"""Same-user Unix socket broker with latest-request-wins cancellation."""

from __future__ import annotations

import asyncio
from concurrent.futures import ThreadPoolExecutor
import ctypes
import json
import math
import os
from pathlib import Path
import re
import socket
import stat
import sys
import struct
from time import monotonic
from typing import Any, Dict, Optional, Protocol, Set, Tuple

from .qwen import ALLOWED_MODELS, ENDPOINT, PROVIDER
from .history_index import HistoryEmbeddingIndexer


class CandidateRanker(Protocol):
    def rank(self, request: Dict[str, Any]) -> Dict[str, Any]: ...


class CloudBrokerConfigurationError(ValueError):
    pass


def _peer_uid(file_descriptor: int) -> int:
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        getpeereid = libc.getpeereid
    except AttributeError:
        if not hasattr(socket, "SO_PEERCRED"):
            raise CloudBrokerConfigurationError("peer identity is unavailable")
        peer = socket.socket(fileno=os.dup(file_descriptor))
        try:
            raw = peer.getsockopt(
                socket.SOL_SOCKET,
                socket.SO_PEERCRED,
                struct.calcsize("3i"),
            )
        finally:
            peer.close()
        _, uid, _ = struct.unpack("3i", raw)
        return uid
    uid = ctypes.c_uint()
    gid = ctypes.c_uint()
    if getpeereid(file_descriptor, ctypes.byref(uid), ctypes.byref(gid)) != 0:
        number = ctypes.get_errno()
        raise OSError(number, os.strerror(number))
    return int(uid.value)


def _bounded_string(value: Any, maximum: int) -> bool:
    return isinstance(value, str) and 0 < len(value.encode()) <= maximum


def validate_request(message: Any) -> Dict[str, Any]:
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
        "candidate_pool_hash": 128,
        "pinyin": 256,
    }.items():
        if not _bounded_string(message.get(field), maximum):
            raise ValueError(f"{field} is invalid")
    if re.fullmatch(r"[a-z']+", message["pinyin"]) is None:
        raise ValueError("pinyin is invalid")
    if message.get("model_id") not in ALLOWED_MODELS:
        raise ValueError("model is not allowed")
    deadline = message.get("deadline_ms")
    if (
        not isinstance(deadline, int)
        or isinstance(deadline, bool)
        or not 1 <= deadline <= 4000
    ):
        raise ValueError("deadline must be from 1 to 4000 ms")
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
    candidates = message.get("candidates")
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
    if not isinstance(candidates, list) or not 1 <= len(candidates) <= 50:
        raise ValueError("candidate count is invalid")
    candidate_ids = set()
    for candidate in candidates:
        if (
            not isinstance(candidate, dict)
            or not _bounded_string(candidate.get("id"), 128)
            or not _bounded_string(candidate.get("text"), 512)
            or "\n" in candidate["text"]
            or candidate.get("source")
            not in {"rime_exact", "rime_fuzzy", "user_term"}
            or candidate.get("consumed_start") != 0
            or candidate.get("consumed_length") != len(message["pinyin"])
            or not _bounded_string(candidate.get("aligned_pinyin"), 256)
            or re.fullmatch(r"[a-z']+", candidate["aligned_pinyin"]) is None
            or not isinstance(candidate.get("edit_cost"), (int, float))
            or isinstance(candidate.get("edit_cost"), bool)
            or not math.isfinite(candidate["edit_cost"])
            or not 0 <= candidate["edit_cost"] <= 1
            or (
                candidate["source"] == "rime_exact"
                and candidate["edit_cost"] != 0
            )
            or (
                candidate.get("rime_index") is not None
                and (
                    not isinstance(candidate["rime_index"], int)
                    or isinstance(candidate["rime_index"], bool)
                    or not 0 <= candidate["rime_index"] < 50
                )
            )
        ):
            raise ValueError("candidate is invalid")
        candidate_ids.add(candidate["id"])
    if len(candidate_ids) != len(candidates):
        raise ValueError("candidate IDs must be unique")
    return message


def validate_decision(
    decision: Any,
    cloud_request: Dict[str, Any],
) -> Dict[str, Any]:
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
    if action in {"keep", "abstain"}:
        if candidate_id is not None or confidence is not None:
            raise ValueError("non-choice decision contains a candidate")
        if decision.get("text") is not None:
            raise ValueError("non-generate decision contains text")
        return decision
    if action == "generate":
        text = decision.get("text")
        if (
            candidate_id is not None
            or not isinstance(text, str)
            or not text
            or len(text.encode()) > 120
            or not isinstance(confidence, (int, float))
            or isinstance(confidence, bool)
            or not math.isfinite(confidence)
            or not 0.60 <= confidence <= 1
        ):
            raise ValueError("generated sentence is invalid")
        # Pinyin alignment was already enforced by the ranker's dictionary
        # guard; this layer mirrors its structural bounds only.
        return decision
    candidate_ids = {item["id"] for item in cloud_request["candidates"]}
    if (
        action != "choose"
        or candidate_id not in candidate_ids
        or decision.get("text") is not None
        or not isinstance(confidence, (int, float))
        or isinstance(confidence, bool)
        or not math.isfinite(confidence)
        or not 0 <= confidence <= 1
    ):
        raise ValueError("choice is not constrained to the candidate pool")
    candidate = next(
        item
        for item in cloud_request["candidates"]
        if item["id"] == candidate_id
    )
    minimum_confidence = (
        0.98 if candidate["source"] == "rime_fuzzy" else 0.85
    )
    if confidence < minimum_confidence:
        raise ValueError("choice is below the product confidence threshold")
    return decision


class CloudBrokerServer:
    def __init__(
        self,
        socket_path: Path,
        ranker: CandidateRanker,
        history_indexer: Optional[HistoryEmbeddingIndexer] = None,
        text_generation_enabled: bool = False,
    ):
        self.socket_path = socket_path
        self.ranker = ranker
        self.history_indexer = history_indexer
        self.text_generation_enabled = text_generation_enabled
        self._server: Optional[asyncio.AbstractServer] = None
        self._tasks: Set[asyncio.Task[Any]] = set()
        self._index_task: Optional[asyncio.Task[Any]] = None
        # Cancellation cannot interrupt a blocking urllib call already in a
        # thread. A single worker ensures obsolete calls cannot fan out into
        # concurrent paid requests while latest-request-wins suppresses them.
        self._rank_executor = ThreadPoolExecutor(
            max_workers=1,
            thread_name_prefix="rimeai-cloud-rank",
        )

    async def start(self) -> None:
        if len(os.fsencode(self.socket_path)) > 103:
            raise CloudBrokerConfigurationError("socket path is too long")
        parent = self.socket_path.parent
        if parent.exists() and parent.is_symlink():
            raise CloudBrokerConfigurationError("runtime path is a symlink")
        parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(parent, 0o700)
        if self.socket_path.exists() or self.socket_path.is_symlink():
            mode = self.socket_path.lstat().st_mode
            if not stat.S_ISSOCK(mode):
                raise CloudBrokerConfigurationError("refusing non-socket path")
            probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            probe.settimeout(0.1)
            try:
                probe.connect(str(self.socket_path))
            except (ConnectionRefusedError, FileNotFoundError):
                pass
            except OSError as exc:
                raise CloudBrokerConfigurationError(
                    "cannot verify existing cloud socket"
                ) from exc
            else:
                raise CloudBrokerConfigurationError(
                    "another cloud broker is already running"
                )
            finally:
                probe.close()
            self.socket_path.unlink()
        self._server = await asyncio.start_unix_server(
            self._handle_client,
            path=str(self.socket_path),
            limit=1_048_576,
        )
        os.chmod(self.socket_path, 0o600)
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
        while True:
            try:
                await asyncio.to_thread(
                    self.history_indexer.run_once,
                    self.ranker,
                )
            except Exception:
                pass
            await asyncio.sleep(5)

    async def _write(
        self,
        writer: asyncio.StreamWriter,
        lock: asyncio.Lock,
        payload: Dict[str, Any],
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
            if peer is None or _peer_uid(peer.fileno()) != os.geteuid():
                return
        except (OSError, CloudBrokerConfigurationError):
            return
        lock = asyncio.Lock()
        hello = False
        client_capabilities: Set[str] = set()
        pending: Dict[str, asyncio.Task[Any]] = {}
        latest: Dict[Tuple[str, str], int] = {}
        try:
            while not reader.at_eof():
                line = await reader.readline()
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
                    ]
                    if self.text_generation_enabled:
                        capabilities.append("text-generation")
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
                    if isinstance(request_id, str) and request_id in pending:
                        pending[request_id].cancel()
                    continue
                if message_type != "inference":
                    continue
                try:
                    cloud_request = validate_request(message)
                except ValueError:
                    continue
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
            writer.close()
            try:
                await writer.wait_closed()
            except (BrokenPipeError, ConnectionResetError):
                pass

    async def _run(
        self,
        cloud_request: Dict[str, Any],
        key: Tuple[str, str],
        latest: Dict[Tuple[str, str], int],
        writer: asyncio.StreamWriter,
        lock: asyncio.Lock,
        client_capabilities: Set[str],
    ) -> None:
        sys.stderr.write(
            f"[cloud] enter revision={cloud_request['revision']}\n"
        )
        sys.stderr.flush()
        started = monotonic()
        budget_seconds = cloud_request["deadline_ms"] / 1000
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
                f"[cloud] timeout remaining={remaining:.2f}s\n"
            )
            sys.stderr.flush()
            return
        except asyncio.CancelledError:
            sys.stderr.write("[cloud] cancelled\n")
            sys.stderr.flush()
            return
        except Exception as exc:
            sys.stderr.write(f"[cloud] error {type(exc).__name__}: {exc}\n")
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
        response: Dict[str, Any] = {
            "schema_version": 1,
            "type": "result",
            "status": "ok",
            "request_id": cloud_request["request_id"],
            "composition_id": cloud_request["composition_id"],
            "revision": cloud_request["revision"],
            "app_session_id": cloud_request["app_session_id"],
            "client_session_id": cloud_request["client_session_id"],
            "candidate_pool_hash": cloud_request["candidate_pool_hash"],
            "history_generation": cloud_request["history_generation"],
            "decision": decision["decision"],
            "candidate_id": decision["candidate_id"],
            "confidence": decision["confidence"],
            "reason": decision["reason"],
            "model_id": cloud_request["model_id"],
            "elapsed_ms": round(elapsed, 3),
        }
        if decision["decision"] == "generate":
            response["generated_text"] = decision["text"]
            # Echo the request pinyin verbatim: the client compares byte
            # for byte, and normalization would strip apostrophes.
            response["generated_pinyin"] = cloud_request["pinyin"]
        await self._write(writer, lock, response)

    def _prepare_history_request(
        self,
        cloud_request: Dict[str, Any],
    ) -> Optional[Dict[str, Any]]:
        assert self.history_indexer is not None
        generation = self.history_indexer.generation()
        if (
            generation is not None
            and generation != cloud_request["history_generation"]
        ):
            return None
        return self.history_indexer.augment_request(cloud_request)
