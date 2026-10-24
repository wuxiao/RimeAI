#!/usr/bin/env python3
"""Build the traditional→simplified mapping table for the daemon engine.

The beam decoder keeps scoring in the traditional space (dictionary +
n-gram + frequency table are all traditional), so script conversion is a
pure output-time transform. The runtime daemon must stay dependency-free
(the deployed interpreter is the stock macOS/Xcode python3), so this
script bakes the OpenCC t2s dictionaries into one compact JSON asset
consumed by rimeai_runtime.script_converter.

Sources (checked into script/assets/, from BYVoid/OpenCC master
data/dictionary/): TSPhrases.txt is the official disambiguation phrase
table (乾隆→乾隆 keeps 乾); TSCharacters.txt lists per-character
candidates (乾→"干 乾") whose FIRST value is the OpenCC default when no
phrase matches. The converter reproduces that exact semantics: longest
phrase match first, then first character candidate.

Run with the project venv (or any python3; no runtime deps needed):

    python3 script/build_t2s_table.py
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
ASSETS_DIR = PROJECT_ROOT / "script/assets"
OUTPUT_PATH = PROJECT_ROOT / ".rimeai/models/t2s-simplified.json"

MAX_PHRASE_LENGTH = 8


def _load_tsv(path: Path) -> dict[str, str]:
    """key→value TSV; comment lines skipped, multi-value rows keep the
    first (OpenCC default) candidate."""
    mapping: dict[str, str] = {}
    with path.open(encoding="utf-8") as file:
        for line in file:
            line = line.rstrip("\n")
            if not line or line.startswith("#") or "\t" not in line:
                continue
            key, value = line.split("\t", 1)
            if key and value:
                mapping.setdefault(
                    key, value.split()[0] if " " in value else value
                )
    return mapping


def main() -> int:
    phrases_file = ASSETS_DIR / "TSPhrases.txt"
    characters_file = ASSETS_DIR / "TSCharacters.txt"
    for path in (phrases_file, characters_file):
        if not path.is_file():
            print(f"error: missing OpenCC source: {path}", file=sys.stderr)
            return 2

    phrases = {
        key: value
        for key, value in _load_tsv(phrases_file).items()
        if 2 <= len(key) <= MAX_PHRASE_LENGTH
    }
    characters = _load_tsv(characters_file)
    payload = {
        "schema_version": 1,
        "name": "t2s-simplified",
        "max_phrase_length": MAX_PHRASE_LENGTH,
        "phrases": phrases,
        "characters": characters,
    }
    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT_PATH.write_text(
        json.dumps(payload, ensure_ascii=False, separators=(",", ":")),
        encoding="utf-8",
    )
    print(
        f"wrote {OUTPUT_PATH} "
        f"(phrases={len(phrases)}, characters={len(characters)}, "
        f"size={OUTPUT_PATH.stat().st_size})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
