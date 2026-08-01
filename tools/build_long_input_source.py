#!/usr/bin/env python3

import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile
from typing import Any, Dict, List

from pypinyin import Style, lazy_pinyin

PROJECT_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT_ROOT))

from rimeai_eval.long_input import derive_long_target


ASCII_PINYIN = re.compile(r"^[a-zv]+$")


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="derive a licensed long-input evaluation source"
    )
    parser.add_argument("source", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--samples", type=int, default=5000)
    return parser.parse_args()


def load_source(path: Path) -> List[Dict[str, Any]]:
    samples: List[Dict[str, Any]] = []
    with path.open(encoding="utf-8") as source:
        for line_number, line in enumerate(source, start=1):
            try:
                sample = json.loads(line)
            except json.JSONDecodeError as error:
                raise ValueError(
                    f"{path}:{line_number}: invalid JSON"
                ) from error
            if (
                not isinstance(sample, dict)
                or sample.get("schema_version") != 1
                or sample.get("split")
                not in {"train", "validation", "test"}
                or not isinstance(sample.get("context"), str)
                or not isinstance(sample.get("gold_text"), str)
                or not isinstance(sample.get("source"), dict)
            ):
                raise ValueError(
                    f"{path}:{line_number}: invalid capture source sample"
                )
            samples.append(sample)
    if not samples:
        raise ValueError(f"{path}: source contains no samples")
    return samples


def derive_sample(sample: Dict[str, Any]) -> Dict[str, Any] | None:
    derived = derive_long_target(sample["context"], sample["gold_text"])
    if derived is None:
        return None
    context, gold_text = derived
    pinyin_parts = lazy_pinyin(
        gold_text,
        style=Style.NORMAL,
        errors=lambda _: [],
    )
    if (
        len(pinyin_parts) != len(gold_text)
        or any(not ASCII_PINYIN.fullmatch(part) for part in pinyin_parts)
    ):
        return None
    digest = hashlib.sha256(
        (
            f"{sample['id']}\0{context}\0{gold_text}\0"
            "long-input-v1"
        ).encode("utf-8")
    ).hexdigest()
    tags = sorted(set(sample.get("tags", [])) | {"long-input"})
    return {
        "schema_version": 1,
        "id": f"long-{sample['domain']}-{digest[:16]}",
        "split": sample["split"],
        "domain": sample["domain"],
        "context": context,
        "pinyin": "".join(pinyin_parts),
        "gold_text": gold_text,
        "tags": tags,
        "source": sample["source"],
        "derivation": {
            "method": "context-suffix-plus-gold-v1",
            "source_sample_id": sample["id"],
        },
    }


def write_atomic(path: Path, samples: List[Dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        dir=path.parent,
        prefix=f".{path.name}.",
        suffix=".tmp",
    )
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            for sample in samples:
                output.write(
                    json.dumps(
                        sample,
                        ensure_ascii=False,
                        separators=(",", ":"),
                    )
                    + "\n"
                )
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary_name, path)
    except BaseException:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass
        raise


def main() -> int:
    arguments = parse_arguments()
    if arguments.samples < 2 or arguments.samples % 2:
        print("error: --samples must be a positive even number", file=sys.stderr)
        return 2
    try:
        source_samples = load_source(arguments.source)
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    by_domain: Dict[str, List[Dict[str, Any]]] = {}
    for source_sample in source_samples:
        derived = derive_sample(source_sample)
        if derived is not None:
            by_domain.setdefault(derived["domain"], []).append(derived)
    per_domain = arguments.samples // 2
    selected: List[Dict[str, Any]] = []
    for domain in ("developer", "general"):
        candidates = sorted(
            by_domain.get(domain, []),
            key=lambda sample: hashlib.sha256(
                sample["id"].encode("utf-8")
            ).hexdigest(),
        )
        if len(candidates) < per_domain:
            print(
                f"error: only derived {len(candidates)} {domain} samples",
                file=sys.stderr,
            )
            return 2
        selected.extend(candidates[:per_domain])
    selected.sort(key=lambda sample: sample["id"])
    write_atomic(arguments.output, selected)
    report = {
        "schema_version": 1,
        "samples": len(selected),
        "domains": dict(Counter(sample["domain"] for sample in selected)),
        "splits": dict(Counter(sample["split"] for sample in selected)),
        "sha256": hashlib.sha256(arguments.output.read_bytes()).hexdigest(),
    }
    print(json.dumps(report, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
