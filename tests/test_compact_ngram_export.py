import gzip
import hashlib
import json
from pathlib import Path
import struct

from scripts.export_compact_ngram import (
    HEADER_SIZE,
    MAGIC,
    TABLE_IDS,
    build_compact_artifact,
    fnv1a64,
)


def test_compact_export_is_deterministic_and_preserves_count_tables(
    tmp_path: Path,
):
    model = {
        "schema_version": 1,
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
            "smoothing": {"numerator": 0.1, "denominator": 1000.0},
        },
        "candidate_frequencies": {"命令": 2},
        "ngram_counts": {str(order): {} for order in (2, 3, 4, 5)},
        "prefix_counts": {str(order): {} for order in (2, 3, 4, 5)},
    }
    model["ngram_counts"]["2"] = {"命令": 3}
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

    first = build_compact_artifact(source)
    second = build_compact_artifact(source)

    assert first == second
    assert first[:8] == MAGIC
    assert struct.unpack_from("<II", first, 8) == (1, len(TABLE_IDS))
    assert first[48:112] == b"a" * 64
    assert first[112:176] == hashlib.sha256(source.read_bytes()).hexdigest().encode()

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
