#!/usr/bin/env python3
"""Collect a frozen RimeAI keyboard interaction observation set on macOS."""

from __future__ import annotations

import argparse
import contextlib
import json
import os
import subprocess
import sys
import tempfile
import time
from collections.abc import Sequence
from pathlib import Path
from typing import Any

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
        "left": "key code 123",
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


def type_composition(scenario: dict[str, Any]) -> None:
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


def read_panel_button_titles() -> list[str]:
    script = (
        'tell application "System Events"\n'
        'tell process "RimeAIInputMethod"\n'
        "if (count of windows) > 0 then\n"
        "set titles to {}\n"
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
    return [
        line.strip()
        for line in run_apple_script(script).splitlines()
        if line.strip()
    ]


def pool_slot_button(pool_text: str) -> str | None:
    """Return the numbered button whose candidate equals pool_text.

    Panel slot numbers are the ground truth for numeric selection: the
    semantic suggestion row occupies leading slots when the pipeline is
    active, shifting numbered candidates (the 2026-10-25 mix1 drift).
    Matching the exact numbered button avoids selecting the wrong
    candidate with a hardcoded key.
    """
    for title in read_panel_button_titles():
        match = NUMBERED_CANDIDATE.match(title)
        if match and match.group(2) == pool_text:
            return match.group(1)
    return None


def displayed_candidates() -> tuple[list[str], str]:
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
        candidates: list[str] = []
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


def undo_until_empty(max_attempts: int = 3) -> str:
    """Undo until the document is empty (bounded).

    macOS 26 TextEdit splits an IME commit into two undo steps (the
    marked-text insertion, then the commit replacement), so a single
    Cmd+Z restores the raw pinyin instead of clearing the document.
    The probe verifies that the accepted text is fully undoable,
    regardless of host undo granularity.
    """
    text = read_document()
    for _ in range(max_attempts):
        if text == "":
            return text
        undo()
        time.sleep(0.4)
        text = read_document()
    return text


def count_undo_steps_to_empty(max_steps: int = 5) -> int:
    """Count Cmd+Z presses needed to reach an empty document.

    Single-commit receipt for the repair probe (KBD-008): a commit
    that went through the retained-preedit path collapses in at most
    two undo steps on macOS 26 TextEdit (marked insertion + commit
    replacement), while the legacy fallback that commits the prefix
    to the document early leaves an extra undoable insertion behind
    (>= 3 steps).
    """
    steps = 0
    for _ in range(max_steps):
        if read_document() == "":
            return steps
        undo()
        steps += 1
        time.sleep(0.4)
    return steps


def evaluate_repair_outcome(
    scenario: dict[str, Any],
    *,
    pre_arrow: str,
    post_arrow: str,
    revised: str,
    restored: str,
    final_text: str,
    undo_steps: int,
) -> dict[str, bool]:
    """Classify the <-arrow repair-chain evidence (pure, testable).

    Discriminating evidence for the retained-preedit path (KBD-008):

    - focus_moved_left: the left arrow rewrote the marked text — the
      focused prefix segment returns to its pinyin form while the
      suffix is finalized as Chinese by the KBD-006 repush. On the
      legacy fallback (prefix already committed to the document)
      canMoveFocusLeft is false, the arrow passes through to TextEdit
      as a cursor move, and the visible text is unchanged.
    - suffix_repushed: the post-arrow text ends with the finalized
      suffix (expected_text minus the pool prefix), proving the suffix
      was re-derived as a committed segment rather than left as raw
      pinyin.
    - prefix_revised: the backspaces shrank the focused segment by
      exactly backspace_count characters and retyping restored the
      post-arrow text (revise-then-restore).
    - single_commit: the whole sentence collapses within two undo
      steps; an early prefix commit leaves an extra undoable
      insertion (>= 3 steps).
    - committed: the final text equals the expected full sentence.

    The checks are deliberately independent of the final string
    alone: a bypassed run whose final text happens to match still
    fails the behavioral checks above.
    """
    pool_text = scenario["pool_text"]
    suffix_text = scenario["expected_text"][len(pool_text):]
    backspace_count = int(scenario["backspace_count"])
    expected_revised_length = len(post_arrow) - backspace_count
    return {
        "repair_focus_moved_left": post_arrow != pre_arrow,
        "repair_suffix_repushed": post_arrow.endswith(suffix_text),
        "repair_prefix_revised": (
            len(revised) == expected_revised_length
            and restored == post_arrow
        ),
        "repair_single_commit": undo_steps <= 2,
        "repair_committed": final_text == scenario["expected_text"],
    }


def load_scenarios(path: Path) -> list[dict[str, Any]]:
    scenarios: list[dict[str, Any]] = []
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
        repair_probe = scenario.get("repair_probe", False)
        if not isinstance(repair_probe, bool):
            raise KeyboardCollectionError(
                f"{path}:{line_number}: repair_probe must be a boolean"
            )
        if repair_probe:
            # 回修链探针（KBD-008）：部分选词后 ← 回修。仅限
            # partial-selection 类别；回修次数与重打拼音必填。
            if scenario["category"] != "partial-selection":
                raise KeyboardCollectionError(
                    f"{path}:{line_number}: repair_probe requires the "
                    "partial-selection category"
                )
            count = scenario.get("backspace_count")
            if (
                not isinstance(count, int)
                or isinstance(count, bool)
                or count < 1
            ):
                raise KeyboardCollectionError(
                    f"{path}:{line_number}: scenario "
                    f"'{scenario['id']}' needs backspace_count >= 1 "
                    "for the repair probe"
                )
            retype = scenario.get("repair_retype")
            if not isinstance(retype, str) or not retype:
                raise KeyboardCollectionError(
                    f"{path}:{line_number}: scenario "
                    f"'{scenario['id']}' needs a non-empty repair_retype "
                    "for the repair probe"
                )
            if len(retype) != count:
                raise KeyboardCollectionError(
                    f"{path}:{line_number}: scenario "
                    f"'{scenario['id']}' repair_retype must retype "
                    "exactly backspace_count letters (revise-then-"
                    "restore semantics)"
                )
        identifiers.add(scenario["id"])
        scenarios.append(scenario)
    if {row["category"] for row in scenarios} != set(KEYBOARD_CATEGORIES):
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


def close_all_documents() -> None:
    """Close every TextEdit document so scenarios run on a fresh window.

    Leftover documents pollute reads: ``window 1`` resolves to the
    frontmost window, and a stale window (e.g. from a manual probe) makes
    the revert probe read stale text instead of the scenario result.
    """
    run_apple_script(
        'tell application "TextEdit"\n'
        "close every document saving no\n"
        "make new document\n"
        "activate\n"
        "end tell"
    )


def collect(
    scenarios_path: Path,
    output_path: Path,
) -> list[dict[str, Any]]:
    if output_path.resolve() == scenarios_path.resolve():
        raise KeyboardCollectionError("--output must not overwrite scenarios")
    if sys.platform != "darwin":
        raise KeyboardCollectionError("keyboard collection requires macOS")
    require_selected_input_method()
    close_all_documents()
    time.sleep(0.5)
    scenarios = load_scenarios(scenarios_path)
    observations: list[dict[str, Any]] = []
    for scenario in scenarios:
        clear_document()
        type_composition(scenario)
        candidates, pool_source = displayed_candidates()
        candidate_in_pool = scenario["pool_text"] in candidates
        candidate_rank: int | None = None
        keys = list(scenario["selection_keys"])
        if candidate_in_pool:
            candidate_rank = candidates.index(scenario["pool_text"]) + 1
            if scenario["category"] != "mixed-composition":
                # 面板按钮编号是数字选词的真实依据：语义行占据前导
                # 槽位时（10-25 mix1 后的漂移形态）固定键会选错候选，
                # 先按 pool 文本匹配真实编号槽位，匹配不到再退回
                # 翻页+槽位的固定键序列。
                slot_button = pool_slot_button(scenario["pool_text"])
                if slot_button is not None:
                    keys = [slot_button]
                else:
                    # 候选面板每页 5 项，数字键只映射页内槽位：目标在
                    # 后续页时先按 `=`（向后翻页）再按页内数字键。
                    page, slot = divmod(candidate_rank - 1, 5)
                    keys = ["="] * page + (
                        ["space"] if slot == 0 and page == 0 else [str(slot + 1)]
                    )
                if (
                    scenario["category"] == "partial-selection"
                    and not scenario.get("repair_probe", False)
                ):
                    # 回修探针场景保留部分选词中间态（不上屏），
                    # 由回修链接管后续提交。
                    keys.append("space")

        select_keys(keys)
        time.sleep(0.5)
        final_text = read_document()

        # KBD-008 回修链探针（← 焦点回移腿）：部分选词不上屏 →
        # ← 把焦点移回前缀段（后缀段由 KBD-006 定稿重推）→ 退格
        # 修正前缀 → 重打恢复 → space 定稿焦点段 → space 整句上屏。
        # 判别性证据：焦点回移改变 marked text（旧回退路径前缀已提
        # 交，← 透传不改文本）；后缀以定稿汉字重推；undo 粒度单次
        # 提交（≤2 步，旧路径 ≥3 步）。
        repair_probe = bool(scenario.get("repair_probe", False))
        repair_focus_moved_left = False
        repair_suffix_repushed = False
        repair_prefix_revised = False
        repair_single_commit = False
        repair_committed = False
        repair_pre_arrow_text: str | None = None
        repair_post_arrow_text: str | None = None
        repair_revised_text: str | None = None
        repair_restored_text: str | None = None
        repair_undo_steps: int | None = None
        if repair_probe:
            repair_pre_arrow_text = final_text
            send_key("left")
            time.sleep(0.8)
            repair_post_arrow_text = read_document()
            for _ in range(int(scenario["backspace_count"])):
                send_key("backspace")
                time.sleep(0.3)
            repair_revised_text = read_document()
            for char in scenario["repair_retype"]:
                send_key(char)
            time.sleep(0.5)
            repair_restored_text = read_document()
            send_key("space")
            time.sleep(0.5)
            send_key("space")
            time.sleep(0.5)
            final_text = read_document()
            repair_undo_steps = count_undo_steps_to_empty()
            outcome = evaluate_repair_outcome(
                scenario,
                pre_arrow=repair_pre_arrow_text,
                post_arrow=repair_post_arrow_text,
                revised=repair_revised_text,
                restored=repair_restored_text,
                final_text=final_text,
                undo_steps=repair_undo_steps,
            )
            repair_focus_moved_left = outcome["repair_focus_moved_left"]
            repair_suffix_repushed = outcome["repair_suffix_repushed"]
            repair_prefix_revised = outcome["repair_prefix_revised"]
            repair_single_commit = outcome["repair_single_commit"]
            repair_committed = outcome["repair_committed"]

        accepted = (
            scenario["category"] != "delete-composition"
            and final_text == scenario["expected_text"]
        )
        text_after_revert: str | None = None
        reverted = False
        if scenario["revert_probe"]:
            text_after_revert = undo_until_empty()
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

        record: dict[str, Any] = {
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
            "repair_probe": repair_probe,
        }
        if candidate_rank is not None:
            record["candidate_rank"] = candidate_rank
        if text_after_revert is not None:
            record["text_after_revert"] = text_after_revert
        if repair_probe:
            record["repair_focus_moved_left"] = repair_focus_moved_left
            record["repair_suffix_repushed"] = repair_suffix_repushed
            record["repair_prefix_revised"] = repair_prefix_revised
            record["repair_single_commit"] = repair_single_commit
            record["repair_committed"] = repair_committed
            record["repair_pre_arrow_text"] = repair_pre_arrow_text
            record["repair_post_arrow_text"] = repair_post_arrow_text
            record["repair_revised_text"] = repair_revised_text
            record["repair_restored_text"] = repair_restored_text
            record["repair_undo_steps"] = repair_undo_steps
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
        with contextlib.suppress(FileNotFoundError):
            os.unlink(temporary_name)
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
