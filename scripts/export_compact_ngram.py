#!/usr/bin/env python3
"""Export the approved P0 n-gram JSON as a memory-mappable iOS artifact."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import json
from pathlib import Path
import os
import struct
import tempfile
from typing import Dict, Mapping


MAGIC = b"RAINGRM1"
SCHEMA_VERSION = 1
TABLE_IDS = (0, 2, 3, 4, 5, 12, 13, 14, 15)
HEADER_SIZE = 176
DIRECTORY_ENTRY_SIZE = 24


def fnv1a64(value: str) -> int:
    result = 14_695_981_039_346_656_037
    for byte in value.encode("utf-8"):
        result ^= byte
        result = (result * 1_099_511_628_211) & 0xFFFFFFFFFFFFFFFF
    return result


def _hashed_records(values: Mapping[str, object], *, table_id: int) -> bytes:
    records: Dict[int, int] = {}
    keys: Dict[int, str] = {}
    for key, raw_count in values.items():
        if not isinstance(key, str) or isinstance(raw_count, bool):
            raise ValueError(f"table {table_id} contains an invalid entry")
        count = int(raw_count)
        if not 0 <= count <= 0xFFFFFFFF:
            raise ValueError(f"table {table_id} count is out of range")
        key_hash = fnv1a64(key)
        previous = keys.get(key_hash)
        if previous is not None and previous != key:
            raise ValueError(
                f"FNV-1a collision in table {table_id}: {previous!r}, {key!r}"
            )
        keys[key_hash] = key
        records[key_hash] = count
    return b"".join(
        struct.pack("<QI", key_hash, records[key_hash])
        for key_hash in sorted(records)
    )


def build_compact_artifact(source: Path) -> bytes:
    source_bytes = source.read_bytes()
    with gzip.open(source, "rt", encoding="utf-8") as model_file:
        model = json.load(model_file)
    if (
        not isinstance(model, dict)
        or model.get("schema_version") != 1
        or model.get("model_type") != "char-ngram-ranker"
    ):
        raise ValueError("unsupported n-gram source artifact")
    hyperparameters = model.get("hyperparameters")
    if not isinstance(hyperparameters, dict):
        raise ValueError("source hyperparameters are missing")
    if hyperparameters.get("orders") != [2, 3, 4, 5]:
        raise ValueError("source n-gram orders are incompatible")
    dataset_hash = model.get("dataset_sha256")
    if (
        not isinstance(dataset_hash, str)
        or len(dataset_hash) != 64
        or any(character not in "0123456789abcdef" for character in dataset_hash)
    ):
        raise ValueError("source dataset SHA-256 is invalid")

    tables = {
        0: model["candidate_frequencies"],
        **{
            order: model["ngram_counts"][str(order)]
            for order in (2, 3, 4, 5)
        },
        **{
            10 + order: model["prefix_counts"][str(order)]
            for order in (2, 3, 4, 5)
        },
    }
    encoded_tables = {
        table_id: _hashed_records(tables[table_id], table_id=table_id)
        for table_id in TABLE_IDS
    }
    header = bytearray()
    header.extend(MAGIC)
    header.extend(struct.pack("<II", SCHEMA_VERSION, len(TABLE_IDS)))
    header.extend(
        struct.pack(
            "<dddII",
            float(hyperparameters["rank_weight"]),
            float(hyperparameters["frequency_weight"]),
            float(hyperparameters["language_weight"]),
            int(hyperparameters["max_context_characters"]),
            int(hyperparameters["top_k"]),
        )
    )
    header.extend(dataset_hash.encode("ascii"))
    header.extend(hashlib.sha256(source_bytes).hexdigest().encode("ascii"))
    if len(header) != HEADER_SIZE:
        raise AssertionError(f"unexpected compact header size: {len(header)}")

    payload_offset = HEADER_SIZE + len(TABLE_IDS) * DIRECTORY_ENTRY_SIZE
    directory = bytearray()
    payload = bytearray()
    for table_id in TABLE_IDS:
        table = encoded_tables[table_id]
        directory.extend(
            struct.pack(
                "<IIQQ",
                table_id,
                0,
                payload_offset + len(payload),
                len(table) // 12,
            )
        )
        payload.extend(table)
    return bytes(header + directory + payload)


def write_compact_artifact(source: Path, output: Path) -> str:
    artifact = build_compact_artifact(source)
    output.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        dir=output.parent,
        prefix=f".{output.name}.",
        suffix=".tmp",
    )
    try:
        with os.fdopen(descriptor, "wb") as file:
            file.write(artifact)
            file.flush()
            os.fsync(file.fileno())
        os.replace(temporary_name, output)
    except BaseException:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass
        raise
    return hashlib.sha256(artifact).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    arguments = parser.parse_args()
    digest = write_compact_artifact(arguments.source, arguments.output)
    print(f"{arguments.output}: sha256={digest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
