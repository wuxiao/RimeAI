"""Persistent local command protocol for constrained sentence suggestions."""

from dataclasses import dataclass
import json
from math import isfinite
from pathlib import Path
from queue import Empty, Queue
import subprocess
from threading import Thread
from time import perf_counter_ns
from typing import Any, Dict, Optional, Sequence


class SentenceDecoderConfigurationError(ValueError):
    pass


class SentenceDecoderProtocolError(RuntimeError):
    pass


@dataclass(frozen=True)
class SentenceSuggestion:
    text: str
    confidence: float


class CommandSentenceDecoder:
    def __init__(self, name: str, command: Sequence[str], timeout_ms: int):
        self.name = name
        self._command = list(command)
        self._timeout_seconds = timeout_ms / 1000
        self._process: Optional[subprocess.Popen[str]] = None
        self._responses: "Queue[Optional[str]]" = Queue()
        self._circuit_open = False
        self.model_artifact_id: Optional[str] = None
        self.attempted_samples = 0
        self.successful_samples = 0
        self.attempt_latencies_ms = []
        self.cold_start_ms: Optional[float] = None
        self.peak_rss_bytes: Optional[int] = None
        self._process_started_at_ns: Optional[int] = None

    @classmethod
    def from_config(cls, path: Path) -> "CommandSentenceDecoder":
        try:
            config = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise SentenceDecoderConfigurationError(
                f"cannot read decoder config '{path}': {error}"
            ) from error
        if not isinstance(config, dict) or config.get("schema_version") != 1:
            raise SentenceDecoderConfigurationError(
                "decoder config schema_version must be 1"
            )
        name = config.get("name")
        command = config.get("command")
        timeout_ms = config.get("timeout_ms")
        if not isinstance(name, str) or not name.strip():
            raise SentenceDecoderConfigurationError(
                "decoder config name must be a non-empty string"
            )
        if (
            not isinstance(command, list)
            or not command
            or any(not isinstance(item, str) or not item for item in command)
        ):
            raise SentenceDecoderConfigurationError(
                "decoder config command must be a non-empty string array"
            )
        if (
            not isinstance(timeout_ms, int)
            or isinstance(timeout_ms, bool)
            or not 1 <= timeout_ms <= 60_000
        ):
            raise SentenceDecoderConfigurationError(
                "decoder config timeout_ms must be an integer from 1 to 60000"
            )
        return cls(name, command, timeout_ms)

    def __enter__(self) -> "CommandSentenceDecoder":
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
            raise SentenceDecoderConfigurationError(
                f"cannot start decoder command: {error}"
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

    def suggest(self, sample: Dict[str, Any]) -> SentenceSuggestion:
        if self._circuit_open:
            raise SentenceDecoderProtocolError(
                "decoder circuit is open after an earlier failure"
            )
        self.attempted_samples += 1
        started_at = perf_counter_ns()
        try:
            suggestion = self._suggest_once(sample)
        except SentenceDecoderProtocolError:
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
        return suggestion

    def _suggest_once(self, sample: Dict[str, Any]) -> SentenceSuggestion:
        if self._process is None or self._process.stdin is None:
            raise SentenceDecoderProtocolError("decoder process is not running")
        request = {
            "schema_version": 1,
            "task": "generate_sentence",
            "request_id": sample["id"],
            "context": sample["context"],
            "pinyin": sample["pinyin"],
            "domain": sample["domain"],
            "candidates": sample["candidates"],
            "max_characters": 30,
        }
        try:
            self._process.stdin.write(
                json.dumps(
                    request,
                    ensure_ascii=False,
                    separators=(",", ":"),
                )
                + "\n"
            )
            self._process.stdin.flush()
        except (BrokenPipeError, OSError) as error:
            raise SentenceDecoderProtocolError(
                "decoder process closed its input"
            ) from error
        try:
            response_line = self._responses.get(timeout=self._timeout_seconds)
        except Empty as error:
            raise SentenceDecoderProtocolError(
                "decoder response timed out"
            ) from error
        if response_line is None:
            raise SentenceDecoderProtocolError(
                "decoder process exited before responding"
            )
        try:
            response = json.loads(response_line)
        except json.JSONDecodeError as error:
            raise SentenceDecoderProtocolError(
                "decoder returned invalid JSON"
            ) from error
        if not isinstance(response, dict):
            raise SentenceDecoderProtocolError(
                "decoder response must be an object"
            )
        if response.get("schema_version") != 1:
            raise SentenceDecoderProtocolError(
                "decoder response schema_version must be 1"
            )
        if response.get("request_id") != sample["id"]:
            raise SentenceDecoderProtocolError(
                "decoder response request_id does not match"
            )
        text = response.get("suggestion")
        if (
            not isinstance(text, str)
            or len(text) > 30
            or "\n" in text
            or "\r" in text
        ):
            raise SentenceDecoderProtocolError(
                "decoder suggestion must be a single line of at most 30 characters"
            )
        confidence = response.get("confidence")
        if (
            not isinstance(confidence, (int, float))
            or isinstance(confidence, bool)
            or not isfinite(confidence)
            or not 0 <= confidence <= 1
        ):
            raise SentenceDecoderProtocolError(
                "decoder confidence must be a finite number from 0 to 1"
            )
        artifact_id = response.get("model_artifact_id")
        if not isinstance(artifact_id, str) or not artifact_id.strip():
            raise SentenceDecoderProtocolError(
                "decoder model_artifact_id must be a non-empty string"
            )
        if (
            self.model_artifact_id is not None
            and artifact_id != self.model_artifact_id
        ):
            raise SentenceDecoderProtocolError(
                "decoder model_artifact_id changed during evaluation"
            )
        self.model_artifact_id = artifact_id
        return SentenceSuggestion(text, float(confidence))

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
        if process.stdout is not None and not process.stdout.closed:
            process.stdout.close()
        self._process = None
