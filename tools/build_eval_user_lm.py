#!/usr/bin/env python3
"""Build an evaluation-only user-LM artifact from a P0 dataset split.

Simulates "the user's committed history" for the L2 shallow-fusion
ablation: folds each train sample's ``context + gold_text`` into the
daemon's UserLanguageModel under the sample's domain (the user typed
the context before committing the gold continuation, so both carry
user evidence). Uses the daemon implementation — the single writer —
and only READS the dataset; validation/test splits are never folded,
so the λ sweep on validation and the final test run stay leak-free.

Output: user-lm.json.gz (schema v2) loadable by both the daemon and
rimeai_runtime.user_lm_view (the MLX worker fusion path).
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from collections.abc import Iterator
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parent.parent


def _iter_split(dataset: Path, split: str) -> Iterator[dict]:
    """Yields dataset rows for `split`; fails loud on malformed lines."""
    with dataset.open("r", encoding="utf-8") as handle:
        for number, line in enumerate(handle, start=1):
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError as error:
                raise SystemExit(
                    f"error: {dataset}:{number}: invalid JSON: {error}"
                ) from error
            if not isinstance(row, dict):
                raise SystemExit(
                    f"error: {dataset}:{number}: row must be an object"
                )
            if row.get("split") == split:
                yield row


def main() -> int:
    # Imported after _REPO_ROOT is known so the script runs from any CWD.
    sys.path.insert(0, str(_REPO_ROOT))
    from rimeai_daemon.user_lm import UserLanguageModel

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "dataset",
        nargs="?",
        type=Path,
        default=_REPO_ROOT
        / ".rimeai/datasets/p0-librime-1.17.0-luna-simp.jsonl",
        help="P0-format JSONL dataset",
    )
    parser.add_argument(
        "--split",
        default="train",
        help="dataset split to fold (default: train)",
    )
    parser.add_argument(
        "--output",
        type=Path,
        required=True,
        help="output user-lm.json.gz path",
    )
    parser.add_argument(
        "--include-context",
        action="store_true",
        default=True,
        help="fold context+gold_text (default) — the committed history",
    )
    parser.add_argument(
        "--gold-only",
        dest="include_context",
        action="store_false",
        help="fold only gold_text (ablation knob)",
    )
    parser.add_argument(
        "--fold-to-global",
        action="store_true",
        help=(
            "fold everything into the global pseudo-domain (the neural "
            "arm's worker protocol carries no domain, so its fusion "
            "scorer reads global — matching production commits whose "
            "bundle maps to no domain)"
        ),
    )
    args = parser.parse_args()

    folded = 0
    domains: Counter[str] = Counter()
    model = UserLanguageModel()
    for row in _iter_split(args.dataset, args.split):
        text = row.get("gold_text") or ""
        if args.include_context and row.get("context"):
            text = row["context"] + text
        if not text:
            continue
        domain = None if args.fold_to_global else (row.get("domain") or None)
        model.update(domain, [text[:256]])
        domains[domain or "global"] += 1
        folded += 1

    args.output.parent.mkdir(parents=True, exist_ok=True)
    model.save(args.output)
    summary = {
        "dataset": str(args.dataset),
        "split": args.split,
        "samples_folded": folded,
        "domains": dict(domains),
        "include_context": args.include_context,
        "output": str(args.output),
        "view_domains": model.domains(),
    }
    print(json.dumps(summary, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
