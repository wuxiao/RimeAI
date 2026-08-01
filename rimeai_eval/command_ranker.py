import json
from math import isfinite
from pathlib import Path
from queue import Empty, Queue
import subprocess
from threading import Thread
from time import perf_counter_ns
from typing import Any, Dict, Optional, Sequence

from .evaluation import RankerError, Ranking


class RankerConfigurationError(ValueError):
    pass


class RankerProtocolError(RankerError):
    pass


class CommandRanker:
    def __init__(self, name: str, command: Sequence[str], timeout_ms: int):
        self.name = name
        self._command = list(command)
        self._timeout_seconds = timeout_ms / 1000
        self._process: Optional[subprocess.Popen[str]] = None
        self._responses: "Queue[Optional[str]]" = Queue()
        self.model_artifact_id: Optional[str] = None
        self._circuit_open = False
        self.attempted_samples = 0
        self.successful_samples = 0
        self.attempt_latencies_ms = []
        self.cold_start_ms: Optional[float] = None
        self.peak_rss_bytes: Optional[int] = None
        self._process_started_at_ns: Optional[int] = None

    @classmethod
    def from_config(cls, path: Path) -> "CommandRanker":
        try:
            config = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise RankerConfigurationError(
                f"cannot read ranker config '{path}': {error}"
            ) from error

        if not isinstance(config, dict) or config.get("schema_version") != 1:
            raise RankerConfigurationError("ranker config schema_version must be 1")
        name = config.get("name")
        if not isinstance(name, str) or not name.strip():
            raise RankerConfigurationError(
                "ranker config name must be a non-empty string"
            )
        command = config.get("command")
        if (
            not isinstance(command, list)
            or not command
            or any(not isinstance(item, str) or not item for item in command)
        ):
            raise RankerConfigurationError(
                "ranker config command must be a non-empty string array"
            )
        timeout_ms = config.get("timeout_ms")
        if (
            not isinstance(timeout_ms, int)
            or isinstance(timeout_ms, bool)
            or not 1 <= timeout_ms <= 60_000
        ):
            raise RankerConfigurationError(
                "ranker config timeout_ms must be an integer from 1 to 60000"
            )
        return cls(name=name, command=command, timeout_ms=timeout_ms)

    def __enter__(self) -> "CommandRanker":
        self._process_started_at_ns = perf_counter_ns()
        try:
            self._process = subprocess.Popen(
                self._command,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                encoding="utf-8",
                bufsize=1,
            )
        except OSError as error:
            raise RankerConfigurationError(
                f"cannot start ranker command: {error}"
            ) from error

        Thread(target=self._read_stdout, daemon=True).start()
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    def _read_stdout(self) -> None:
        assert self._process is not None
        assert self._process.stdout is not None
        for line in self._process.stdout:
            self._responses.put(line)
        self._responses.put(None)

    def rank(self, sample: Dict[str, Any]) -> Ranking:
        if self._circuit_open:
            raise RankerProtocolError(
                "ranker circuit is open after an earlier failure"
            )
        self.attempted_samples += 1
        started_at = perf_counter_ns()
        try:
            ranking = self._rank_once(sample)
        except RankerProtocolError:
            self._circuit_open = True
            raise
        finally:
            self.attempt_latencies_ms.append(
                (perf_counter_ns() - started_at) / 1_000_000
            )
        self.successful_samples += 1
        if self.cold_start_ms is None and self._process_started_at_ns is not None:
            self.cold_start_ms = (
                perf_counter_ns() - self._process_started_at_ns
            ) / 1_000_000
        self._sample_peak_rss()
        return ranking

    def _sample_peak_rss(self) -> None:
        process = self._process
        if process is None:
            return
        try:
            result = subprocess.run(
                ["/bin/ps", "-o", "rss=", "-p", str(process.pid)],
                capture_output=True,
                text=True,
                check=False,
                timeout=0.1,
            )
            resident_kilobytes = int(result.stdout.strip())
        except (OSError, subprocess.SubprocessError, ValueError):
            return
        resident_bytes = resident_kilobytes * 1024
        self.peak_rss_bytes = max(self.peak_rss_bytes or 0, resident_bytes)

    def _rank_once(self, sample: Dict[str, Any]) -> Ranking:
        if self._process is None or self._process.stdin is None:
            raise RankerProtocolError("ranker process is not running")

        candidates = [
            {"id": f"c{index}", "text": text, "baseline_rank": index + 1}
            for index, text in enumerate(sample["candidates"])
        ]
        request = {
            "schema_version": 1,
            "task": "rerank",
            "request_id": sample["id"],
            "context": sample["context"],
            "pinyin": sample["pinyin"],
            "domain": sample["domain"],
            "candidates": candidates,
        }
        try:
            self._process.stdin.write(
                json.dumps(request, ensure_ascii=False, separators=(",", ":")) + "\n"
            )
            self._process.stdin.flush()
        except (BrokenPipeError, OSError) as error:
            raise RankerProtocolError("ranker process closed its input") from error

        try:
            response_line = self._responses.get(timeout=self._timeout_seconds)
        except Empty as error:
            raise RankerProtocolError("ranker response timed out") from error
        if response_line is None:
            raise RankerProtocolError("ranker process exited before responding")

        try:
            response = json.loads(response_line)
        except json.JSONDecodeError as error:
            raise RankerProtocolError("ranker returned invalid JSON") from error
        if not isinstance(response, dict):
            raise RankerProtocolError("ranker response must be an object")
        if response.get("schema_version") != 1:
            raise RankerProtocolError("ranker response schema_version must be 1")
        if response.get("request_id") != sample["id"]:
            raise RankerProtocolError("ranker response request_id does not match")
        confidence = response.get("confidence")
        if (
            not isinstance(confidence, (int, float))
            or isinstance(confidence, bool)
            or not isfinite(confidence)
            or not 0 <= confidence <= 1
        ):
            raise RankerProtocolError(
                "ranker response confidence must be a finite number from 0 to 1"
            )
        model_artifact_id = response.get("model_artifact_id")
        if (
            not isinstance(model_artifact_id, str)
            or not model_artifact_id.strip()
        ):
            raise RankerProtocolError(
                "ranker response model_artifact_id must be a non-empty string"
            )
        if (
            self.model_artifact_id is not None
            and model_artifact_id != self.model_artifact_id
        ):
            raise RankerProtocolError(
                "ranker response model_artifact_id changed during evaluation"
            )

        ranking = response.get("ranking")
        expected_ids = [candidate["id"] for candidate in candidates]
        if (
            not isinstance(ranking, list)
            or len(ranking) != len(expected_ids)
            or set(ranking) != set(expected_ids)
        ):
            raise RankerProtocolError(
                "ranker response ranking must be a permutation of candidate ids"
            )
        self.model_artifact_id = model_artifact_id
        text_by_id = {
            candidate["id"]: candidate["text"] for candidate in candidates
        }
        return Ranking(
            tuple(text_by_id[candidate_id] for candidate_id in ranking),
            float(confidence),
        )

    def close(self) -> None:
        process = self._process
        if process is None:
            return
        if process.stdin is not None and not process.stdin.closed:
            process.stdin.close()
        try:
            process.wait(timeout=0.2)
        except subprocess.TimeoutExpired:
            process.terminate()
            try:
                process.wait(timeout=0.2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=0.2)
        self._process = None
