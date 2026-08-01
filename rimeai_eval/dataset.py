from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
from typing import Any, Dict, List, Optional


@dataclass(frozen=True)
class LoadedDataset:
    samples: List[Dict[str, Any]]
    sha256: str


class DatasetValidationError(ValueError):
    def __init__(
        self, path: Path, line_number: Optional[int], message: str
    ):
        super().__init__(message)
        self.path = path
        self.line_number = line_number
        self.message = message

    def __str__(self) -> str:
        if self.line_number is None:
            return f"{self.path}: {self.message}"
        return f"{self.path}:{self.line_number}: {self.message}"


def load_dataset(path: Path) -> LoadedDataset:
    samples: List[Dict[str, Any]] = []
    sample_ids = set()
    dataset_hash = hashlib.sha256()
    try:
        dataset_file = path.open("rb")
    except OSError as error:
        raise DatasetValidationError(path, None, "cannot read dataset") from error

    with dataset_file:
        for line_number, raw_line in enumerate(dataset_file, start=1):
            dataset_hash.update(raw_line)
            try:
                line = raw_line.decode("utf-8")
            except UnicodeDecodeError as error:
                raise DatasetValidationError(
                    path, line_number, "line must be valid UTF-8"
                ) from error
            if not line.strip():
                continue
            try:
                sample = json.loads(line)
            except json.JSONDecodeError as error:
                raise DatasetValidationError(
                    path, line_number, f"invalid JSON: {error.msg}"
                ) from error
            if not isinstance(sample, dict):
                raise DatasetValidationError(
                    path, line_number, "sample must be a JSON object"
                )
            if sample.get("schema_version") != 1:
                raise DatasetValidationError(
                    path, line_number, "schema_version must be 1"
                )
            sample_id = sample.get("id")
            if not isinstance(sample_id, str) or not sample_id.strip():
                raise DatasetValidationError(
                    path, line_number, "id must be a non-empty string"
                )
            if sample_id in sample_ids:
                raise DatasetValidationError(
                    path, line_number, f"duplicate sample id '{sample_id}'"
                )
            domain = sample.get("domain")
            if not isinstance(domain, str) or not domain.strip():
                raise DatasetValidationError(
                    path, line_number, "domain must be a non-empty string"
                )
            if sample.get("split") not in {"train", "validation", "test"}:
                raise DatasetValidationError(
                    path,
                    line_number,
                    "split must be one of train, validation, or test",
                )
            if not isinstance(sample.get("context"), str):
                raise DatasetValidationError(
                    path, line_number, "context must be a string"
                )
            pinyin = sample.get("pinyin")
            if not isinstance(pinyin, str) or not pinyin.strip():
                raise DatasetValidationError(
                    path, line_number, "pinyin must be a non-empty string"
                )
            candidates = sample.get("candidates")
            if (
                not isinstance(candidates, list)
                or not 1 <= len(candidates) <= 20
                or any(
                    not isinstance(candidate, str) or not candidate
                    for candidate in candidates
                )
            ):
                raise DatasetValidationError(
                    path,
                    line_number,
                    "candidates must contain 1 to 20 non-empty strings",
                )
            if len(candidates) != len(set(candidates)):
                raise DatasetValidationError(
                    path, line_number, "candidates must contain unique values"
                )
            gold_text = sample.get("gold_text")
            if not isinstance(gold_text, str) or not gold_text:
                raise DatasetValidationError(
                    path, line_number, "gold_text must be a non-empty string"
                )
            tags = sample.get("tags", [])
            if (
                not isinstance(tags, list)
                or any(not isinstance(tag, str) or not tag for tag in tags)
                or len(tags) != len(set(tags))
            ):
                raise DatasetValidationError(
                    path,
                    line_number,
                    "tags must contain unique non-empty strings",
                )
            samples.append(sample)
            sample_ids.add(sample_id)
    if not samples:
        raise DatasetValidationError(path, None, "dataset contains no samples")
    return LoadedDataset(samples=samples, sha256=dataset_hash.hexdigest())
