import hashlib
import json
from pathlib import Path
import re
from typing import Any, Dict, List, Sequence


KEYBOARD_CATEGORIES = (
    "exact",
    "abbreviated",
    "near-sound",
    "missing-syllable",
    "partial-selection",
    "mixed-composition",
    "delete-composition",
)

NUMBERED_CANDIDATE = re.compile(r"^\s*(\d{1,2})\s+(.+)$")


class KeyboardEvaluationError(ValueError):
    pass


def _require_bool(record: Dict[str, Any], field: str, line_number: int) -> bool:
    value = record.get(field)
    if not isinstance(value, bool):
        raise KeyboardEvaluationError(
            f"line {line_number}: {field} must be a boolean"
        )
    return value


def _require_text(
    record: Dict[str, Any], field: str, line_number: int, *, allow_empty: bool = False
) -> str:
    value = record.get(field)
    if not isinstance(value, str) or (not allow_empty and not value):
        qualifier = "non-empty " if not allow_empty else ""
        raise KeyboardEvaluationError(
            f"line {line_number}: {field} must be a {qualifier}string"
        )
    return value


def load_keyboard_observations(path: Path) -> List[Dict[str, Any]]:
    observations: List[Dict[str, Any]] = []
    identifiers = set()
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        raise KeyboardEvaluationError(
            f"cannot read keyboard observations '{path}': {error}"
        ) from error

    for line_number, line in enumerate(lines, start=1):
        if not line.strip():
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError as error:
            raise KeyboardEvaluationError(
                f"{path}:{line_number}: invalid JSON: {error.msg}"
            ) from error
        if not isinstance(record, dict):
            raise KeyboardEvaluationError(
                f"{path}:{line_number}: observation must be an object"
            )
        if record.get("schema_version") != 1:
            raise KeyboardEvaluationError(
                f"{path}:{line_number}: schema_version must be 1"
            )
        identifier = _require_text(record, "id", line_number)
        if identifier in identifiers:
            raise KeyboardEvaluationError(
                f"{path}:{line_number}: duplicate observation id '{identifier}'"
            )
        identifiers.add(identifier)
        category = _require_text(record, "category", line_number)
        if category not in KEYBOARD_CATEGORIES:
            raise KeyboardEvaluationError(
                f"{path}:{line_number}: unsupported keyboard category '{category}'"
            )
        _require_text(record, "pinyin", line_number)
        _require_text(record, "expected_text", line_number, allow_empty=True)
        _require_text(record, "final_text", line_number, allow_empty=True)
        text_after_revert = record.get("text_after_revert")
        if text_after_revert is not None and not isinstance(
            text_after_revert, str
        ):
            raise KeyboardEvaluationError(
                f"{path}:{line_number}: text_after_revert must be a string"
            )
        _require_bool(record, "candidate_in_pool", line_number)
        _require_bool(record, "accepted", line_number)
        _require_bool(record, "revert_probe", line_number)
        _require_bool(record, "reverted", line_number)
        _require_bool(record, "backspace_probe", line_number)
        _require_bool(record, "backspace_cleared", line_number)
        repair_probe = record.get("repair_probe", False)
        if not isinstance(repair_probe, bool):
            raise KeyboardEvaluationError(
                f"line {line_number}: repair_probe must be a boolean"
            )
        if repair_probe:
            # 回修链探针（KBD-008 收集器增强）：三项行为结果必填——
            # 预编辑区前缀保留 / 剩余拼音回修（收缩且前缀未破）/ 最终
            # 整句上屏。
            _require_bool(
                record, "repair_prefix_preserved", line_number
            )
            _require_bool(
                record, "repair_remaining_shrunk", line_number
            )
            _require_bool(
                record, "repair_committed", line_number
            )
            for field in ("repair_mid_text_before", "repair_mid_text_after"):
                value = record.get(field)
                if value is not None and not isinstance(value, str):
                    raise KeyboardEvaluationError(
                        f"line {line_number}: {field} must be a string"
                    )
        candidate_rank = record.get("candidate_rank")
        if candidate_rank is not None and (
            not isinstance(candidate_rank, int)
            or isinstance(candidate_rank, bool)
            or candidate_rank < 1
            or candidate_rank > 20
        ):
            raise KeyboardEvaluationError(
                f"{path}:{line_number}: candidate_rank must be from 1 to 20"
            )
        observations.append(record)

    missing_categories = [
        category for category in KEYBOARD_CATEGORIES
        if category not in {row["category"] for row in observations}
    ]
    if missing_categories:
        raise KeyboardEvaluationError(
            "keyboard observations must cover: " + ", ".join(missing_categories)
        )
    return observations


def _ratio(numerator: int, denominator: int) -> float:
    if denominator == 0:
        return 0.0
    return round(numerator / denominator, 6)


def _slice_metrics(observations: Sequence[Dict[str, Any]]) -> Dict[str, Any]:
    samples = len(observations)
    selection_observations = [
        row for row in observations if row["category"] != "delete-composition"
    ]
    included = [
        row
        for row in selection_observations
        if row["candidate_in_pool"]
    ]
    accepted = sum(row["accepted"] for row in selection_observations)
    accurate = sum(
        row["final_text"] == row["expected_text"] for row in included
    )
    revert_samples = sum(row["revert_probe"] for row in observations)
    reverted = sum(row["reverted"] for row in observations if row["revert_probe"])
    backspace_samples = sum(row["backspace_probe"] for row in observations)
    backspace_cleared = sum(
        row["backspace_cleared"]
        for row in observations
        if row["backspace_probe"]
    )
    repair_rows = [
        row for row in observations if row.get("repair_probe")
    ]
    repair_prefix_preserved = sum(
        row["repair_prefix_preserved"] for row in repair_rows
    )
    repair_remaining_shrunk = sum(
        row["repair_remaining_shrunk"] for row in repair_rows
    )
    repair_committed = sum(
        row["repair_committed"] for row in repair_rows
    )
    return {
        "samples": samples,
        "candidate_pool_inclusion": _ratio(
            len(included), len(selection_observations)
        ),
        "conditional_accuracy": _ratio(accurate, len(included)),
        "accepted": _ratio(accepted, len(selection_observations)),
        "reverted": _ratio(reverted, revert_samples),
        "backspace_cleared": _ratio(backspace_cleared, backspace_samples),
        "repair_prefix_preserved": _ratio(
            repair_prefix_preserved, len(repair_rows)
        ),
        "repair_remaining_pinyin": _ratio(
            repair_remaining_shrunk, len(repair_rows)
        ),
        "repair_committed": _ratio(
            repair_committed, len(repair_rows)
        ),
    }


def evaluate_keyboard_observations(
    observations: Sequence[Dict[str, Any]],
    *,
    dataset_path: Path,
) -> Dict[str, Any]:
    if not observations:
        raise KeyboardEvaluationError("keyboard observations are empty")
    by_category = {
        category: [row for row in observations if row["category"] == category]
        for category in KEYBOARD_CATEGORIES
    }
    overall = _slice_metrics(observations)
    interaction_samples = [
        row for row in observations if row["category"] != "delete-composition"
    ]
    return {
        "schema_version": 1,
        "dataset": {
            "kind": "real-keyboard-interaction",
            "samples": overall.pop("samples"),
            "sha256": hashlib.sha256(dataset_path.read_bytes()).hexdigest(),
        },
        "metrics": overall,
        "interactions": {
            "selection_samples": len(interaction_samples),
            "revert_samples": sum(row["revert_probe"] for row in observations),
            "backspace_samples": sum(
                row["backspace_probe"] for row in observations
            ),
            "repair_samples": sum(
                1 for row in observations if row.get("repair_probe")
            ),
        },
        "slices": {
            category: _slice_metrics(rows)
            for category, rows in by_category.items()
        },
    }
