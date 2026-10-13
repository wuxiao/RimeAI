"""Classify constrained-decoder bake-off failures from an eval details file.

Buckets (per details row with ``applied_hit == false``):

- ``gate_fuzzy_mismatch``: the worker's fuzzy gate passed the suggestion
  but the harness's exact-pinyin gate rejected it (status
  ``fallback-pinyin``). ``gate_lost_wins`` counts rows where the rejected
  suggestion actually equaled the gold text.
- ``dict_recall_miss``: gold contains characters absent from the Rime
  dictionary, so the dictionary-bounded token index can never produce it.
- ``pinyin_mismatch``: gold readings cannot align to the typed pinyin
  (fuzzy matching and Rime abbreviated forms included); no decoder could
  reach gold on this input.
- ``index_recall_miss``: pinyin aligns, but the gold text cannot be tiled
  by indexed token texts (e.g. a character with a dictionary reading that
  has no token in the model vocabulary); a tokenizer-vocabulary recall
  boundary, not a pinyin failure.
- ``model_path_miss``: a producing path exists under the index; the
  beam/model chose a different one. This is the beam/SFT lever.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

os.environ.setdefault("HF_HUB_OFFLINE", "1")
os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")

from rimeai_runtime.constrained_decoder import (
    PinyinTokenIndex,
    gold_path_reachable,
)
from rimeai_runtime.pinyin_guard import PinyinGuard

GATE_MISMATCH = "gate_fuzzy_mismatch"
DICT_RECALL_MISS = "dict_recall_miss"
PINYIN_MISMATCH = "pinyin_mismatch"
INDEX_RECALL_MISS = "index_recall_miss"
MODEL_PATH_MISS = "model_path_miss"

ALL_BUCKETS = (GATE_MISMATCH, DICT_RECALL_MISS, PINYIN_MISMATCH, INDEX_RECALL_MISS, MODEL_PATH_MISS)

_EXAMPLE_FIELDS = ("id", "domain", "pinyin", "gold_text", "raw_suggestion", "status")


def classify_detail(
    guard: PinyinGuard,
    index: PinyinTokenIndex,
    detail: Dict[str, Any],
) -> Tuple[str, Dict[str, Any]]:
    if detail.get("status") == "fallback-pinyin":
        return GATE_MISMATCH, {
            "gate_lost_win": detail.get("raw_suggestion") == detail.get("gold_text"),
        }
    gold = detail.get("gold_text") or ""
    unknown = [c for c in gold if c not in guard.pronunciations]
    if unknown:
        return DICT_RECALL_MISS, {
            "unknown_characters": "".join(sorted(set(unknown))),
        }
    syllables = guard.segment(gold, detail.get("pinyin") or "")
    if syllables is None:
        return PINYIN_MISMATCH, {}
    if not gold_path_reachable(index, gold, syllables, fuzzy=True):
        return INDEX_RECALL_MISS, {}
    return MODEL_PATH_MISS, {}


def build_index(model_dir: Path, dictionary_path: Path) -> Tuple[PinyinGuard, PinyinTokenIndex]:
    from transformers import AutoTokenizer

    guard = PinyinGuard.from_rime_dictionary(dictionary_path)
    tokenizer = AutoTokenizer.from_pretrained(str(model_dir))
    return guard, PinyinTokenIndex.build(tokenizer, guard)


def load_t2s_table(path: Path) -> Dict[str, str]:
    """Char-level traditional->simplified mapping in OpenCC dictionary text
    format (``key<TAB>value [value...]``), e.g. TSCharacters.txt."""
    mapping: Dict[str, str] = {}
    with path.open(encoding="utf-8") as handle:
        for line in handle:
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) != 2:
                continue
            mapping[parts[0]] = parts[1].split()[0]
    return mapping


def run(
    details_path: Path,
    dictionary_path: Path,
    model_dir: Path,
    *,
    examples_per_bucket: int = 8,
    t2s_table_path: Optional[Path] = None,
) -> Dict[str, Any]:
    started = time.monotonic()
    guard, index = build_index(model_dir, dictionary_path)
    index_seconds = round(time.monotonic() - started, 3)

    t2s = load_t2s_table(t2s_table_path) if t2s_table_path is not None else None

    counts: Dict[str, int] = {bucket: 0 for bucket in ALL_BUCKETS}
    gate_lost_wins = 0
    examples: Dict[str, List[Dict[str, Any]]] = {bucket: [] for bucket in ALL_BUCKETS}
    total = 0
    failures = 0
    baseline_hits = 0
    fixed = 0
    regressions = 0
    simplified_equivalent_wins = 0
    with details_path.open(encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            detail = json.loads(line)
            total += 1
            gold = detail.get("gold_text")
            applied = detail.get("applied_text")
            baseline = detail.get("baseline_candidate")
            if baseline == gold:
                baseline_hits += 1
                if applied != gold:
                    regressions += 1
            elif applied == gold:
                fixed += 1
            if applied == gold:
                continue
            failures += 1
            if t2s is not None and "".join(t2s.get(c, c) for c in gold or "") == applied:
                simplified_equivalent_wins += 1
            bucket, extra = classify_detail(guard, index, detail)
            counts[bucket] += 1
            if extra.get("gate_lost_win"):
                gate_lost_wins += 1
            if len(examples[bucket]) < examples_per_bucket:
                examples[bucket].append(
                    {field: detail.get(field) for field in _EXAMPLE_FIELDS} | {"extra": extra}
                )
    return {
        "details_path": str(details_path),
        "dictionary_path": str(dictionary_path),
        "model_dir": str(model_dir),
        "index_build_seconds": index_seconds,
        "total_rows": total,
        "failures": failures,
        "counts": counts,
        "gate_lost_wins": gate_lost_wins,
        "cross_cutting": {
            "baseline_hits": baseline_hits,
            "fixed": fixed,
            "regressions": regressions,
            "simplified_equivalent_wins": simplified_equivalent_wins if t2s is not None else None,
            "t2s_method": (
                f"char-level OpenCC TSCharacters ({t2s_table_path}); t2s(gold) == applied_text, failures only"
                if t2s is not None
                else "unavailable: pass --t2s-table TSCharacters.txt"
            ),
        },
        "examples": examples,
    }


def main(argv: Optional[List[str]] = None) -> int:
    project_root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("details", type=Path)
    parser.add_argument(
        "--rime-dictionary",
        type=Path,
        default=project_root / ".rimeai/rime/shared/luna_pinyin.dict.yaml",
    )
    parser.add_argument(
        "--model-dir",
        type=Path,
        default=Path(
            os.environ.get(
                "RIMEAI_QWEN_MODEL_DIR",
                project_root / ".rimeai/models/qwen2.5-0.5b-base-060db64",
            )
        ),
    )
    parser.add_argument(
        "--t2s-table",
        type=Path,
        default=None,
        help="OpenCC TSCharacters.txt for simplified-equivalent-win counting "
        "(fetch: curl -sL https://raw.githubusercontent.com/BYVoid/OpenCC/master/data/dictionary/TSCharacters.txt)",
    )
    parser.add_argument("--output", type=Path, default=None)
    args = parser.parse_args(argv)

    if not args.details.is_file():
        print(f"error: details file not found: {args.details}", file=sys.stderr)
        return 2
    report = run(
        args.details, args.rime_dictionary, args.model_dir, t2s_table_path=args.t2s_table
    )
    payload = json.dumps(report, ensure_ascii=False, sort_keys=True, indent=2)
    if args.output is not None:
        args.output.write_text(payload + "\n", encoding="utf-8")
    else:
        print(payload)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
