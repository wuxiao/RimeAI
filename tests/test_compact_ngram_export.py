import gzip
import hashlib
import json
from pathlib import Path
import struct

import pytest

from scripts.export_compact_ngram import (
    HEADER_SIZE,
    MAGIC,
    SCHEMA_VERSION,
    TABLE_IDS,
    build_compact_artifact,
    fnv1a64,
)


def _write_source(tmp_path: Path, model: dict) -> Path:
    source = tmp_path / "model.json.gz"
    with source.open("wb") as raw_file:
        with gzip.GzipFile(
            filename="",
            mode="wb",
            fileobj=raw_file,
            mtime=0,
        ) as file:
            file.write(
                json.dumps(
                    model,
                    ensure_ascii=False,
                    separators=(",", ":"),
                    sort_keys=True,
                ).encode("utf-8")
            )
    return source


def _v2_model() -> dict:
    model = {
        "schema_version": 2,
        "model_type": "char-ngram-ranker",
        "dataset_sha256": "a" * 64,
        "split_counts": {"train": 1, "validation": 1},
        "hyperparameters": {
            "rank_weight": 0.1,
            "frequency_weight": 1.0,
            "language_weight": 2.0,
            "orders": [2, 3, 4, 5],
            "max_context_characters": 40,
            "top_k": 10,
            "smoothing": {
                "method": "stupid-backoff",
                "alpha": 0.4,
                "terminal_numerator": 0.1,
                "terminal_denominator": 1000.0,
            },
        },
        "candidate_frequencies": {"命令": 2},
        "ngram_counts": {str(order): {} for order in (2, 3, 4, 5)},
        "prefix_counts": {str(order): {} for order in (2, 3, 4, 5)},
    }
    model["ngram_counts"]["2"] = {"命令": 3}
    return model


def test_compact_export_is_deterministic_and_preserves_count_tables(
    tmp_path: Path,
):
    source = _write_source(tmp_path, _v2_model())

    first = build_compact_artifact(source)
    second = build_compact_artifact(source)

    assert first == second
    assert first[:8] == MAGIC
    assert MAGIC == b"RAINGRM2"
    assert struct.unpack_from("<II", first, 8) == (SCHEMA_VERSION, len(TABLE_IDS))
    assert SCHEMA_VERSION == 2
    assert HEADER_SIZE == 184
    assert struct.unpack_from("<ddd", first, 16) == (0.1, 1.0, 2.0)
    assert struct.unpack_from("<d", first, 40) == (0.4,)
    assert struct.unpack_from("<II", first, 48) == (40, 10)
    assert first[56:120] == b"a" * 64
    assert first[120:184] == hashlib.sha256(source.read_bytes()).hexdigest().encode()

    directories = {
        struct.unpack_from("<IIQQ", first, HEADER_SIZE + index * 24)[0]:
        struct.unpack_from("<IIQQ", first, HEADER_SIZE + index * 24)
        for index in range(len(TABLE_IDS))
    }
    _, _, offset, count = directories[0]
    assert count == 1
    assert struct.unpack_from("<QI", first, offset) == (fnv1a64("命令"), 2)
    _, _, offset, count = directories[2]
    assert count == 1
    assert struct.unpack_from("<QI", first, offset) == (fnv1a64("命令"), 3)


def test_compact_export_rejects_schema_v1_source(tmp_path: Path):
    model = _v2_model()
    model["schema_version"] = 1
    source = _write_source(tmp_path, model)

    with pytest.raises(ValueError) as excinfo:
        build_compact_artifact(source)

    assert "retrain" in str(excinfo.value)
