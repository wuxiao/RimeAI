#!/usr/bin/env python3
"""Collect a frozen RimeAI keyboard interaction observation set on macOS."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
from typing import Any, Dict, List, Optional, Sequence, Tuple


PROJECT_ROOT = Path(__file__).resolve().parents[1]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from rimeai_eval.keyboard_evaluation import (  # noqa: E402
    KEYBOARD_CATEGORIES,
    NUMBERED_CANDIDATE,
)


class KeyboardCollectionError(RuntimeError):
    pass


def apple_script_escape(text: str) -> str:
    return text.replace("\\", "\\\\").replace('"', '\\"')


def run_apple_script(script: str) -> str:
    result = subprocess.run(
        ["/usr/bin/osascript", "-e", script],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise KeyboardCollectionError(
            f"AppleScript keyboard automation failed: {result.stderr.strip()}"
        )
    return result.stdout.rstrip("\n")


def read_document() -> str:
    return run_apple_script(
        'tell application "System Events" to tell process "TextEdit" '
        'to value of text area 1 of scroll area 1 of window 1'
    )


def clear_document() -> None:
    run_apple_script(
        'tell application "System Events"\n'
        'tell process "TextEdit"\n'
        "set frontmost to true\n"
        "end tell\n"
        "delay 0.2\n"
        "key code 53\n"
        "delay 0.2\n"
        "key code 0 using command down\n"
        "key code 51\n"
        "delay 0.2\n"
        "key code 53\n"
        "end tell"
    )


def send_key(key: str) -> None:
    normalized = key.lower()
    commands = {
        "space": "key code 49",
        "tab": "key code 48",
        "backspace": "key code 51",
        "return": "key code 36",
    }
    command = commands.get(normalized)
    if command is None:
        if len(normalized) != 1:
            raise KeyboardCollectionError(f"unsupported keyboard key '{key}'")
        command = f'keystroke "{apple_script_escape(normalized)}"'
    run_apple_script(
        'tell application "System Events"\n'
        'tell process "TextEdit"\n'
        "set frontmost to true\n"
        "end tell\n"
        "delay 0.1\n"
        f"{command}\n"
        "end tell"
    )


def type_composition(scenario: Dict[str, Any]) -> None:
    lines = [
        'tell application "System Events"',
        'tell process "TextEdit"',
        "set frontmost to true",
        "end tell",
        "delay 0.2",
        f'keystroke "{apple_script_escape(scenario["pinyin"])}"',
        f'delay {scenario["settle_ms"] / 1000:.3f}',
        "end tell",
    ]
    run_apple_script("\n".join(lines))


def select_keys(keys: Sequence[str]) -> None:
    for key in keys:
        send_key(key)


def displayed_candidates() -> Tuple[List[str], str]:
    script = (
        'tell application "System Events"\n'
        'tell process "RimeAIInputMethod"\n'
        "set titles to {}\n"
        "if (count of windows) > 0 then\n"
        "repeat with theButton in buttons of window 1\n"
        "try\n"
        "copy (title of theButton) to end of titles\n"
        "end try\n"
        "end repeat\n"
        "end if\n"
        "set output to \"\"\n"
        "repeat with theTitle in titles\n"
        "set output to output & theTitle & linefeed\n"
        "end repeat\n"
        "return output\n"
        "end tell\n"
        "end tell"
    )
    for _ in range(20):
        raw = run_apple_script(script)
        source = "displayed-panel-top10"
        candidates: List[str] = []
        for line in raw.splitlines():
            match = NUMBERED_CANDIDATE.match(line)
            if match:
                candidates.append(match.group(2))
            elif line.startswith("✦"):
                semantic = line[1:]
                if "：" in semantic:
                    semantic = semantic.split("：", 1)[1]
                semantic = semantic.split(" · ", 1)[0].strip()
                if semantic:
                    candidates.append(semantic)
                    source = "displayed-panel-semantic"
        if candidates:
            return candidates, source
        time.sleep(0.2)
    return [], "displayed-panel-unavailable"


def undo() -> None:
    run_apple_script(
        'tell application "System Events" to tell process "TextEdit" '
        'to key code 6 using command down'
    )


def load_scenarios(path: Path) -> List[Dict[str, Any]]:
    scenarios: List[Dict[str, Any]] = []
    identifiers = set()
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        raise KeyboardCollectionError(
            f"cannot read scenarios '{path}': {error}"
        ) from error
    for line_number, line in enumerate(lines, start=1):
        if not line.strip():
            continue
        try:
            scenario = json.loads(line)
        except json.JSONDecodeError as error:
            raise KeyboardCollectionError(
                f"{path}:{line_number}: invalid JSON: {error.msg}"
            ) from error
        required = {
            "schema_version",
            "id",
            "category",
            "pinyin",
            "pool_text",
            "expected_text",
            "selection_keys",
            "candidate_probe",
            "revert_probe",
            "backspace_probe",
            "settle_ms",
        }
        missing = sorted(required - scenario.keys())
        if missing:
            raise KeyboardCollectionError(
                f"{path}:{line_number}: missing fields: {', '.join(missing)}"
            )
        if scenario["schema_version"] != 1:
            raise KeyboardCollectionError(
                f"{path}:{line_number}: schema_version must be 1"
            )
        if scenario["category"] not in KEYBOARD_CATEGORIES:
            raise KeyboardCollectionError(
                f"{path}:{line_number}: unsupported category "
                f"'{scenario['category']}'"
            )
        if scenario["id"] in identifiers:
            raise KeyboardCollectionError(
                f"{path}:{line_number}: duplicate id '{scenario['id']}'"
            )
        identifiers.add(scenario["id"])
        scenarios.append(scenario)
    if set(row["category"] for row in scenarios) != set(KEYBOARD_CATEGORIES):
        raise KeyboardCollectionError("scenarios do not cover every category")
    return scenarios


def require_selected_input_method() -> None:
    result = subprocess.run(
        [
            "/usr/bin/defaults",
            "read",
            "com.apple.HIToolbox",
            "AppleSelectedInputSources",
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if (
        result.returncode != 0
        or "fun.wwcn.inputmethod.RimeAI" not in result.stdout
    ):
        raise KeyboardCollectionError(
            "RimeAI must be the selected input source before collection"
        )


def collect(
    scenarios_path: Path,
    output_path: Path,
) -> List[Dict[str, Any]]:
    if output_path.resolve() == scenarios_path.resolve():
        raise KeyboardCollectionError("--output must not overwrite scenarios")
    if sys.platform != "darwin":
        raise KeyboardCollectionError("keyboard collection requires macOS")
    require_selected_input_method()
    scenarios = load_scenarios(scenarios_path)
    observations: List[Dict[str, Any]] = []
    for scenario in scenarios:
        clear_document()
        type_composition(scenario)
        candidates, pool_source = displayed_candidates()
        candidate_in_pool = scenario["pool_text"] in candidates
        candidate_rank: Optional[int] = None
        keys = list(scenario["selection_keys"])
        if candidate_in_pool:
            candidate_rank = candidates.index(scenario["pool_text"]) + 1
            if scenario["category"] != "mixed-composition":
                keys = ["space" if candidate_rank == 1 else str(candidate_rank)]
                if scenario["category"] == "partial-selection":
                    keys.append("space")

        select_keys(keys)
        time.sleep(0.5)
        final_text = read_document()
        accepted = (
            scenario["category"] != "delete-composition"
            and final_text == scenario["expected_text"]
        )
        text_after_revert: Optional[str] = None
        reverted = False
        if scenario["revert_probe"]:
            undo()
            time.sleep(0.4)
            text_after_revert = read_document()
            reverted = text_after_revert == ""

        backspace_cleared = False
        if scenario["backspace_probe"]:
            count = int(scenario.get("backspace_count", 0))
            if count < 1:
                raise KeyboardCollectionError(
                    f"scenario '{scenario['id']}' has an invalid "
                    "backspace_count"
                )
            for _ in range(count):
                send_key("backspace")
            time.sleep(0.3)
            final_text = read_document()
            backspace_cleared = final_text == scenario["expected_text"]

        record: Dict[str, Any] = {
            "schema_version": 1,
            "id": scenario["id"],
            "category": scenario["category"],
            "pinyin": scenario["pinyin"],
            "expected_text": scenario["expected_text"],
            "final_text": final_text,
            "candidate_in_pool": candidate_in_pool,
            "candidate_pool_source": pool_source,
            "accepted": accepted,
            "revert_probe": scenario["revert_probe"],
            "reverted": reverted,
            "backspace_probe": scenario["backspace_probe"],
            "backspace_cleared": backspace_cleared,
        }
        if candidate_rank is not None:
            record["candidate_rank"] = candidate_rank
        if text_after_revert is not None:
            record["text_after_revert"] = text_after_revert
        observations.append(record)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    file_descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{output_path.name}.", dir=output_path.parent
    )
    try:
        with os.fdopen(file_descriptor, "w", encoding="utf-8") as output:
            for record in observations:
                output.write(
                    json.dumps(
                        record, ensure_ascii=False, separators=(",", ":")
                    )
                    + "\n"
                )
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary_name, output_path)
    except BaseException:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass
        raise
    return observations


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--scenarios",
        type=Path,
        default=PROJECT_ROOT / "datasets/keyboard-interaction-v1.jsonl",
    )
    parser.add_argument("--output", required=True, type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        collect(args.scenarios, args.output)
    except (KeyboardCollectionError, OSError, json.JSONDecodeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
