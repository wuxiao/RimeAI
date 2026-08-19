"""Persistent 512-d embedding jobs and optional HNSW retrieval."""

from __future__ import annotations

from array import array
from pathlib import Path
import sqlite3
from typing import Any, Dict, List, Optional, Protocol, Sequence

from .hnsw_index import HNSWGraphIndex


EMBEDDING_MODEL = "text-embedding-v4"
EMBEDDING_DIMENSIONS = 512


class Embedder(Protocol):
    def embed_texts(self, texts: Sequence[str]) -> List[List[float]]: ...


class HistoryEmbeddingIndexer:
    def __init__(self, database_path: Path, index_path: Path):
        self.database_path = database_path
        self.index_path = index_path

    def generation(self) -> Optional[int]:
        if not self.database_path.exists():
            return None
        with sqlite3.connect(self.database_path) as database:
            row = database.execute(
                "SELECT generation FROM history_metadata WHERE id = 1"
            ).fetchone()
        return int(row[0]) if row else None

    def run_once(self, embedder: Embedder, batch_size: int = 16) -> int:
        if not self.database_path.exists():
            return 0
        with sqlite3.connect(self.database_path, timeout=1) as database:
            rows = database.execute(
                """
                SELECT j.id, c.id, c.pinyin, c.committed_text
                FROM embedding_jobs j
                JOIN history_commits c ON c.id = j.commit_id
                WHERE j.status IN ('pending', 'retry')
                  AND j.next_attempt_ms <= CAST(strftime('%s','now') AS INT) * 1000
                ORDER BY j.id
                LIMIT ?
                """,
                (max(1, min(batch_size, 32)),),
            ).fetchall()
        if not rows:
            return 0
        texts = [f"{row[2]}\n{row[3]}" for row in rows]
        try:
            vectors = embedder.embed_texts(texts)
        except Exception:
            self._mark_retry([int(row[0]) for row in rows])
            return 0
        if len(vectors) != len(rows):
            self._mark_retry([int(row[0]) for row in rows])
            return 0
        with sqlite3.connect(self.database_path, timeout=1) as database:
            database.execute("BEGIN IMMEDIATE")
            try:
                for row, vector in zip(rows, vectors):
                    if len(vector) != EMBEDDING_DIMENSIONS:
                        raise ValueError("embedding dimension mismatch")
                    blob = array("f", (float(value) for value in vector)).tobytes()
                    database.execute(
                        """
                        UPDATE history_commits
                        SET embedding_model = ?, embedding_dimension = ?,
                            embedding_state = 'ready', embedding = ?
                        WHERE id = ?
                        """,
                        (
                            EMBEDDING_MODEL,
                            EMBEDDING_DIMENSIONS,
                            blob,
                            row[1],
                        ),
                    )
                    database.execute(
                        "DELETE FROM embedding_jobs WHERE id = ?",
                        (row[0],),
                    )
                database.commit()
            except Exception:
                database.rollback()
                self._mark_retry([int(row[0]) for row in rows])
                return 0
        self._rebuild_hnsw()
        return len(rows)

    def augment_request(self, cloud_request: Dict[str, Any]) -> Dict[str, Any]:
        """Retrieve older history using recent-topic and pinyin seed vectors."""
        if not self.index_path.exists() or not self.database_path.exists():
            return cloud_request
        pinyin = cloud_request["pinyin"]
        with sqlite3.connect(self.database_path, timeout=0.05) as database:
            generation_row = database.execute(
                "SELECT generation FROM history_metadata WHERE id = 1"
            ).fetchone()
            generation = int(generation_row[0]) if generation_row else 0
            pinyin_seeds = database.execute(
                """
                SELECT rowid, embedding
                FROM history_commits
                WHERE embedding_state = 'ready'
                  AND pinyin LIKE ?
                ORDER BY committed_at_ms DESC
                LIMIT 4
                """,
                (f"%{pinyin}%",),
            ).fetchall()
            recent_seeds = database.execute(
                """
                SELECT rowid, embedding
                FROM history_commits
                WHERE embedding_state = 'ready'
                ORDER BY committed_at_ms DESC
                LIMIT 1
                """
            ).fetchall()
            seeds_by_rowid = {
                int(row[0]): row[1]
                for row in pinyin_seeds + recent_seeds
            }
            if not seeds_by_rowid:
                return cloud_request
            seed_vectors = [
                self._decode_vector(blob)
                for blob in seeds_by_rowid.values()
            ]
            query = [
                sum(vector[index] for vector in seed_vectors)
                / len(seed_vectors)
                for index in range(EMBEDDING_DIMENSIONS)
            ]
            vector_rows = database.execute(
                """
                SELECT rowid, embedding FROM history_commits
                WHERE embedding_state = 'ready'
                """
            ).fetchall()
            vectors = {
                int(row[0]): self._decode_vector(row[1])
                for row in vector_rows
            }
            index = HNSWGraphIndex.load(
                self.index_path,
                EMBEDDING_DIMENSIONS,
                expected_generation=generation,
            )
            neighbors = index.query(query, vectors, maximum_count=24)
            neighbors = [
                (label, distance)
                for label, distance in neighbors
                if label not in seeds_by_rowid
            ][:8]
            row_ids = [label for label, _ in neighbors]
            if not row_ids:
                return cloud_request
            placeholders = ",".join("?" for _ in row_ids)
            records = database.execute(
                f"""
                SELECT rowid, id, committed_text, bundle_id, committed_at_ms
                FROM history_commits
                WHERE rowid IN ({placeholders})
                """,
                row_ids,
            ).fetchall()
        by_rowid = {int(row[0]): row for row in records}
        vector_snippets = []
        for label, distance in neighbors:
            row = by_rowid.get(label)
            if row is None:
                continue
            vector_snippets.append(
                {
                    "id": row[1],
                    "text": row[2],
                    "bundle_id": row[3],
                    "committed_at_ms": int(row[4]),
                    "score": float(max(0, 1 - distance)),
                }
            )
        incoming = cloud_request.get("history_snippets", [])
        merged = []
        seen = set()
        for snippet in vector_snippets + incoming:
            if snippet["id"] not in seen:
                seen.add(snippet["id"])
                merged.append(snippet)
        augmented = dict(cloud_request)
        augmented["history_snippets"] = merged[:8]
        return augmented

    def _mark_retry(self, job_ids: Sequence[int]) -> None:
        if not job_ids or not self.database_path.exists():
            return
        with sqlite3.connect(self.database_path, timeout=1) as database:
            database.executemany(
                """
                UPDATE embedding_jobs
                SET status = 'retry', attempts = attempts + 1,
                    next_attempt_ms = CAST(strftime('%s','now') AS INT) * 1000
                        + MIN(60000, 1000 * (attempts + 1))
                WHERE id = ?
                """,
                [(job_id,) for job_id in job_ids],
            )

    def _rebuild_hnsw(self) -> None:
        with sqlite3.connect(self.database_path, timeout=1) as database:
            generation_row = database.execute(
                "SELECT generation FROM history_metadata WHERE id = 1"
            ).fetchone()
            generation = int(generation_row[0]) if generation_row else 0
            rows = database.execute(
                """
                SELECT rowid, embedding FROM history_commits
                WHERE embedding_state = 'ready'
                  AND embedding_model = ?
                  AND embedding_dimension = ?
                ORDER BY rowid
                """,
                (EMBEDDING_MODEL, EMBEDDING_DIMENSIONS),
            ).fetchall()
        if not rows:
            if self.index_path.exists():
                self.index_path.unlink()
            return
        vectors = {
            int(row[0]): self._decode_vector(row[1]) for row in rows
        }
        index = HNSWGraphIndex.load(
            self.index_path,
            EMBEDDING_DIMENSIONS,
            expected_generation=generation,
        )
        index.synchronize(vectors)
        index.save(self.index_path)
        # History clear and index rebuilding happen in different processes.
        # A clear racing between the database read and atomic rename must not
        # allow an old-generation graph to reappear after deletion.
        current_generation = self.generation()
        if current_generation is not None and current_generation != generation:
            try:
                self.index_path.unlink()
            except FileNotFoundError:
                pass

    @staticmethod
    def _decode_vector(blob: bytes) -> List[float]:
        values = array("f")
        values.frombytes(blob)
        if len(values) != EMBEDDING_DIMENSIONS:
            raise ValueError("stored embedding dimension mismatch")
        return values.tolist()
