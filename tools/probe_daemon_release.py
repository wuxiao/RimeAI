#!/usr/bin/env python3
"""Exercise a running release daemon through its public Unix socket protocol."""

import argparse
import json
import socket
import statistics
import time
from pathlib import Path
import sys
from typing import Any, Dict, Optional, Sequence


def _exchange(stream: Any, payload: Dict[str, Any]) -> Dict[str, Any]:
    stream.write(
        (
            json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
            + "\n"
        ).encode("utf-8")
    )
    response = stream.readline()
    if not response:
        raise OSError("daemon closed the socket")
    value = json.loads(response.decode("utf-8"))
    if not isinstance(value, dict):
        raise ValueError("daemon response is not an object")
    return value


def probe(
    socket_path: Path,
    *,
    expected_artifact_id: str,
    requests: int,
    timeout: float,
) -> Dict[str, Any]:
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(timeout)
    try:
        client.connect(str(socket_path))
        stream = client.makefile("rwb", buffering=0)
        hello = _exchange(
            stream,
            {
                "schema_version": 1,
                "type": "hello",
                "client_id": "release-validation",
                "capabilities": ["rerank", "sentence", "cancel"],
            },
        )
        if hello.get("status") != "ok":
            raise ValueError("daemon hello failed")
        if hello.get("offline_lock") is not True:
            raise ValueError("offline network lock is not active")
        if hello.get("model_artifact_id") != expected_artifact_id:
            raise ValueError("daemon is serving an unexpected model artifact")

        latencies = []
        last_response: Dict[str, Any] = {}
        for revision in range(1, requests + 1):
            request = {
                "schema_version": 1,
                "type": "infer",
                "request_id": "release-%d" % revision,
                "composition_id": "composition-%d" % revision,
                "revision": revision,
                "app_session_id": "release-validation",
                "context_policy": "standard",
                "context": "如果事件循环为空，则程序会",
                "pinyin": "tuichu",
                "candidates": ["推出", "退出", "退除"],
                "deadline_ms": 1000,
                "allow_sentence": False,
                "sensitive": False,
            }
            started = time.perf_counter()
            last_response = _exchange(stream, request)
            latencies.append((time.perf_counter() - started) * 1000)
            if last_response.get("status") != "ok":
                raise ValueError("daemon inference failed")
            if last_response.get("ranked_candidate") != "退出":
                raise ValueError("context correction regression")
        ablation_response = _exchange(
            stream,
            {
                "schema_version": 1,
                "type": "infer",
                "request_id": "release-context-ablation",
                "composition_id": "release-context-ablation",
                "revision": requests + 1,
                "app_session_id": "release-validation",
                "context_policy": "standard",
                "context": "",
                "pinyin": "tuichu",
                "candidates": ["推出", "退出", "退除"],
                "deadline_ms": 1000,
                "allow_sentence": False,
                "sensitive": False,
            },
        )
        if (
            ablation_response.get("status") != "ok"
            or ablation_response.get("decision") != "same_top_candidate"
            or ablation_response.get("ranked_candidate") not in {None, ""}
        ):
            raise ValueError("context ablation regression")
        return {
            "artifact_id": expected_artifact_id,
            "context_ablation": "passed",
            "last_confidence": last_response.get("confidence"),
            "last_decision": last_response.get("decision"),
            "maximum_ms": round(max(latencies), 3),
            "median_ms": round(statistics.median(latencies), 3),
            "requests": requests,
        }
    finally:
        client.close()


def main(arguments: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--socket", type=Path, required=True)
    parser.add_argument("--expected-artifact-id", required=True)
    parser.add_argument("--requests", type=int, default=20)
    parser.add_argument("--timeout", type=float, default=3.0)
    options = parser.parse_args(arguments)
    if options.requests < 1:
        parser.error("--requests must be positive")
    try:
        result = probe(
            options.socket,
            expected_artifact_id=options.expected_artifact_id,
            requests=options.requests,
            timeout=options.timeout,
        )
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print("error: %s" % error, file=sys.stderr)
        return 2
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
