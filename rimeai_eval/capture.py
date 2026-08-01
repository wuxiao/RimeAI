from dataclasses import dataclass
import hashlib
import json
from math import ceil
import os
from pathlib import Path
from queue import Empty, Queue
import re
import subprocess
import tempfile
from threading import Thread
from time import perf_counter_ns
from typing import Any, Dict, List, Optional, Sequence, Tuple


class CaptureError(ValueError):
    pass


@dataclass(frozen=True)
class CaptureSource:
    samples: List[Dict[str, Any]]
    sha256: str


@dataclass(frozen=True)
class CandidateSourceConfig:
    name: str
    command: Tuple[str, ...]
    timeout_ms: int


def _source_error(path: Path, line_number: Optional[int], message: str) -> CaptureError:
    location = str(path) if line_number is None else f"{path}:{line_number}"
    return CaptureError(f"{location}: {message}")


def load_capture_source(path: Path) -> CaptureSource:
    samples: List[Dict[str, Any]] = []
    sample_ids = set()
    source_hash = hashlib.sha256()
    try:
        source_file = path.open("rb")
    except OSError as error:
        raise _source_error(path, None, "cannot read capture source") from error

    with source_file:
        for line_number, raw_line in enumerate(source_file, start=1):
            source_hash.update(raw_line)
            try:
                line = raw_line.decode("utf-8")
            except UnicodeDecodeError as error:
                raise _source_error(
                    path, line_number, "line must be valid UTF-8"
                ) from error
            if not line.strip():
                continue
            try:
                sample = json.loads(line)
            except json.JSONDecodeError as error:
                raise _source_error(
                    path, line_number, f"invalid JSON: {error.msg}"
                ) from error
            if not isinstance(sample, dict):
                raise _source_error(path, line_number, "sample must be a JSON object")
            if sample.get("schema_version") != 1:
                raise _source_error(path, line_number, "schema_version must be 1")
            sample_id = sample.get("id")
            if not isinstance(sample_id, str) or not sample_id.strip():
                raise _source_error(path, line_number, "id must be a non-empty string")
            if sample_id in sample_ids:
                raise _source_error(
                    path, line_number, f"duplicate sample id '{sample_id}'"
                )
            if sample.get("split") not in {"train", "validation", "test"}:
                raise _source_error(
                    path,
                    line_number,
                    "split must be one of train, validation, or test",
                )
            domain = sample.get("domain")
            if not isinstance(domain, str) or not domain.strip():
                raise _source_error(
                    path, line_number, "domain must be a non-empty string"
                )
            if not isinstance(sample.get("context"), str):
                raise _source_error(path, line_number, "context must be a string")
            pinyin = sample.get("pinyin")
            if not isinstance(pinyin, str) or not pinyin.strip():
                raise _source_error(
                    path, line_number, "pinyin must be a non-empty string"
                )
            gold_text = sample.get("gold_text")
            if not isinstance(gold_text, str) or not gold_text:
                raise _source_error(
                    path, line_number, "gold_text must be a non-empty string"
                )
            tags = sample.get("tags", [])
            if (
                not isinstance(tags, list)
                or any(not isinstance(tag, str) or not tag for tag in tags)
                or len(tags) != len(set(tags))
            ):
                raise _source_error(
                    path,
                    line_number,
                    "tags must contain unique non-empty strings",
                )
            sample_ids.add(sample_id)
            samples.append(sample)

    if not samples:
        raise _source_error(path, None, "capture source contains no samples")
    return CaptureSource(samples=samples, sha256=source_hash.hexdigest())


def load_candidate_source_config(path: Path) -> CandidateSourceConfig:
    try:
        config = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise CaptureError(f"cannot read candidate config '{path}': {error}") from error
    if not isinstance(config, dict) or config.get("schema_version") != 1:
        raise CaptureError("candidate config schema_version must be 1")
    name = config.get("name")
    if not isinstance(name, str) or not name.strip():
        raise CaptureError("candidate config name must be a non-empty string")
    command = config.get("command")
    if (
        not isinstance(command, list)
        or not command
        or any(not isinstance(item, str) or not item for item in command)
    ):
        raise CaptureError("candidate config command must be a non-empty string array")
    timeout_ms = config.get("timeout_ms")
    if (
        not isinstance(timeout_ms, int)
        or isinstance(timeout_ms, bool)
        or not 1 <= timeout_ms <= 60_000
    ):
        raise CaptureError(
            "candidate config timeout_ms must be an integer from 1 to 60000"
        )
    return CandidateSourceConfig(name, tuple(command), timeout_ms)


class CandidateProcess:
    def __init__(self, config: CandidateSourceConfig):
        self.config = config
        self._process: Optional[subprocess.Popen[str]] = None
        self._responses: "Queue[Optional[str]]" = Queue()
        self.latencies_ms: List[float] = []

    def __enter__(self) -> "CandidateProcess":
        try:
            self._process = subprocess.Popen(
                self.config.command,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                encoding="utf-8",
                bufsize=1,
            )
        except OSError as error:
            raise CaptureError(f"cannot start candidate command: {error}") from error
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

    def candidates_for(
        self, sample: Dict[str, Any], limit: int
    ) -> Tuple[List[str], Dict[str, str]]:
        started_at = perf_counter_ns()
        if self._process is None or self._process.stdin is None:
            raise CaptureError("candidate process is not running")
        request = {
            "schema_version": 1,
            "task": "candidates",
            "request_id": sample["id"],
            "pinyin": sample["pinyin"],
            "limit": limit,
        }
        try:
            self._process.stdin.write(
                json.dumps(request, ensure_ascii=False, separators=(",", ":")) + "\n"
            )
            self._process.stdin.flush()
        except (BrokenPipeError, OSError) as error:
            raise CaptureError("candidate process closed its input") from error
        try:
            response_line = self._responses.get(
                timeout=self.config.timeout_ms / 1000
            )
        except Empty as error:
            raise CaptureError(
                f"candidate response timed out for sample '{sample['id']}'"
            ) from error
        if response_line is None:
            raise CaptureError("candidate process exited before responding")
        try:
            response = json.loads(response_line)
        except json.JSONDecodeError as error:
            raise CaptureError("candidate process returned invalid JSON") from error
        if not isinstance(response, dict):
            raise CaptureError("candidate response must be an object")
        if response.get("schema_version") != 1:
            raise CaptureError("candidate response schema_version must be 1")
        if response.get("request_id") != sample["id"]:
            raise CaptureError("candidate response request_id does not match")
        candidates = response.get("candidates")
        if (
            not isinstance(candidates, list)
            or not 1 <= len(candidates) <= limit
            or any(not isinstance(candidate, str) or not candidate for candidate in candidates)
            or len(candidates) != len(set(candidates))
        ):
            raise CaptureError(
                f"candidate response must contain 1 to {limit} unique non-empty strings"
            )
        engine = response.get("engine")
        if not isinstance(engine, dict):
            raise CaptureError("candidate response engine must be an object")
        required_engine_fields = ("name", "version", "schema_id", "data_sha256")
        if any(
            not isinstance(engine.get(field), str) or not engine[field].strip()
            for field in required_engine_fields
        ):
            raise CaptureError(
                "candidate response engine fields must be non-empty strings"
            )
        if not re.fullmatch(r"[0-9a-f]{64}", engine["data_sha256"]):
            raise CaptureError(
                "candidate response engine data_sha256 must be lowercase SHA-256"
            )
        self.latencies_ms.append(
            (perf_counter_ns() - started_at) / 1_000_000
        )
        return candidates, {field: engine[field] for field in required_engine_fields}

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


def _atomic_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    file_descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", dir=path.parent
    )
    try:
        with os.fdopen(file_descriptor, "wb") as temporary_file:
            temporary_file.write(data)
            temporary_file.flush()
            os.fsync(temporary_file.fileno())
        os.replace(temporary_name, path)
    except BaseException:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass
        raise


def _percentile(values: List[float], percentile: float) -> float:
    ordered = sorted(values)
    index = max(0, ceil(percentile * len(ordered)) - 1)
    return round(ordered[index], 6)


def capture_dataset(
    source_path: Path,
    candidate_config_path: Path,
    output_path: Path,
    provenance_output_path: Path,
    limit: int = 20,
) -> Dict[str, Any]:
    if source_path.resolve() in {
        output_path.resolve(),
        provenance_output_path.resolve(),
    }:
        raise CaptureError("capture outputs must not overwrite the source")
    if output_path.resolve() == provenance_output_path.resolve():
        raise CaptureError("dataset and provenance outputs must be different files")

    source = load_capture_source(source_path)
    config = load_candidate_source_config(candidate_config_path)
    records = []
    engine_metadata: Optional[Dict[str, str]] = None
    with CandidateProcess(config) as candidate_process:
        for source_sample in source.samples:
            candidates, engine = candidate_process.candidates_for(source_sample, limit)
            if engine_metadata is None:
                engine_metadata = engine
            elif engine != engine_metadata:
                raise CaptureError(
                    "candidate engine metadata changed during capture"
                )
            records.append({**source_sample, "candidates": candidates})
        capture_latencies_ms = list(candidate_process.latencies_ms)

    assert engine_metadata is not None
    dataset_bytes = "".join(
        json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n"
        for record in records
    ).encode("utf-8")
    dataset_sha256 = hashlib.sha256(dataset_bytes).hexdigest()
    provenance = {
        "schema_version": 1,
        "candidate_source": config.name,
        "samples": len(records),
        "source_sha256": source.sha256,
        "dataset_sha256": dataset_sha256,
        "engine": engine_metadata,
        "latency_ms": {
            "samples": len(capture_latencies_ms),
            "p50": _percentile(capture_latencies_ms, 0.5),
            "p95": _percentile(capture_latencies_ms, 0.95),
        },
    }
    provenance_bytes = (
        json.dumps(
            provenance,
            ensure_ascii=False,
            indent=2,
            sort_keys=True,
        )
        + "\n"
    ).encode("utf-8")
    _atomic_write(output_path, dataset_bytes)
    _atomic_write(provenance_output_path, provenance_bytes)
    return {
        "schema_version": 1,
        "candidate_source": config.name,
        "captured_samples": len(records),
        "engine": engine_metadata,
    }
