from pathlib import Path
from array import array
import sqlite3
import tempfile

from rimeai_cloud_broker.history_index import (
    EMBEDDING_DIMENSIONS,
    EMBEDDING_MODEL,
    HistoryEmbeddingIndexer,
)
from rimeai_cloud_broker.hnsw_index import HNSWGraphIndex


def _database(path: Path) -> None:
    with sqlite3.connect(path) as database:
        database.executescript(
            """
            CREATE TABLE history_metadata(
                id INTEGER PRIMARY KEY,
                generation INTEGER NOT NULL
            );
            INSERT INTO history_metadata VALUES(1, 7);
            CREATE TABLE history_commits(
                id TEXT PRIMARY KEY,
                pinyin TEXT NOT NULL,
                committed_text TEXT NOT NULL,
                bundle_id TEXT NOT NULL DEFAULT 'com.example.Editor',
                committed_at_ms INTEGER NOT NULL DEFAULT 0,
                embedding_model TEXT,
                embedding_dimension INTEGER,
                embedding_state TEXT NOT NULL DEFAULT 'pending',
                embedding BLOB
            );
            CREATE TABLE embedding_jobs(
                id INTEGER PRIMARY KEY,
                commit_id TEXT NOT NULL,
                status TEXT NOT NULL,
                attempts INTEGER NOT NULL DEFAULT 0,
                next_attempt_ms INTEGER NOT NULL DEFAULT 0
            );
            INSERT INTO history_commits(id, pinyin, committed_text)
            VALUES('commit-1', 'xiangmu', '海豚项目');
            INSERT INTO embedding_jobs(id, commit_id, status)
            VALUES(1, 'commit-1', 'pending');
            """
        )


class FakeEmbedder:
    def embed_texts(self, texts):
        assert texts == ["xiangmu\n海豚项目"]
        return [[0.25] * EMBEDDING_DIMENSIONS]


def test_embedding_jobs_persist_frozen_model_and_dimensions():
    with tempfile.TemporaryDirectory(dir="/tmp") as root:
        database_path = Path(root) / "history.sqlite3"
        _database(database_path)
        indexer = HistoryEmbeddingIndexer(
            database_path,
            Path(root) / "history-hnsw-v1.bin",
        )

        assert indexer.generation() == 7
        assert indexer.run_once(FakeEmbedder()) == 1
        assert indexer.index_path.exists()

        with sqlite3.connect(database_path) as database:
            row = database.execute(
                """
                SELECT embedding_model, embedding_dimension,
                       embedding_state, length(embedding)
                FROM history_commits WHERE id = 'commit-1'
                """
            ).fetchone()
            jobs = database.execute(
                "SELECT COUNT(*) FROM embedding_jobs"
            ).fetchone()[0]
        assert row == (
            EMBEDDING_MODEL,
            EMBEDDING_DIMENSIONS,
            "ready",
            EMBEDDING_DIMENSIONS * 4,
        )
        assert jobs == 0


def test_vector_retrieval_uses_recent_topic_and_excludes_seed_rows():
    with tempfile.TemporaryDirectory(dir="/tmp") as root:
        database_path = Path(root) / "history.sqlite3"
        _database(database_path)
        indexer = HistoryEmbeddingIndexer(
            database_path,
            Path(root) / "history-hnsw-v1.bin",
        )

        def blob(first, second):
            return array(
                "f",
                [first, second] + [0.0] * (EMBEDDING_DIMENSIONS - 2),
            ).tobytes()

        with sqlite3.connect(database_path) as database:
            database.execute("DELETE FROM embedding_jobs")
            database.execute("DELETE FROM history_commits")
            database.executemany(
                """
                INSERT INTO history_commits(
                    id, pinyin, committed_text, bundle_id, committed_at_ms,
                    embedding_model, embedding_dimension, embedding_state,
                    embedding
                ) VALUES (?, ?, ?, 'com.example.Editor', ?, ?, ?, 'ready', ?)
                """,
                [
                    (
                        "recent-seed",
                        "zuijin",
                        "海豚项目进展",
                        300,
                        EMBEDDING_MODEL,
                        EMBEDDING_DIMENSIONS,
                        blob(1.0, 0.0),
                    ),
                    (
                        "older-related",
                        "lishi",
                        "海豚项目计划",
                        200,
                        EMBEDDING_MODEL,
                        EMBEDDING_DIMENSIONS,
                        blob(0.95, 0.05),
                    ),
                    (
                        "older-unrelated",
                        "qita",
                        "晚餐安排",
                        100,
                        EMBEDDING_MODEL,
                        EMBEDDING_DIMENSIONS,
                        blob(0.0, 1.0),
                    ),
                ],
            )
        indexer._rebuild_hnsw()

        augmented = indexer.augment_request(
            {
                "pinyin": "xinshuru",
                "history_snippets": [],
            }
        )

        assert augmented["history_snippets"][0]["id"] == "older-related"
        assert all(
            item["id"] != "recent-seed"
            for item in augmented["history_snippets"]
        )


def test_generation_change_during_index_save_removes_stale_graph(monkeypatch):
    with tempfile.TemporaryDirectory(dir="/tmp") as root:
        database_path = Path(root) / "history.sqlite3"
        _database(database_path)
        indexer = HistoryEmbeddingIndexer(
            database_path,
            Path(root) / "history-hnsw-v1.bin",
        )
        vector = array("f", [0.25] * EMBEDDING_DIMENSIONS).tobytes()
        with sqlite3.connect(database_path) as database:
            database.execute(
                """
                UPDATE history_commits
                SET embedding_model = ?, embedding_dimension = ?,
                    embedding_state = 'ready', embedding = ?
                """,
                (EMBEDDING_MODEL, EMBEDDING_DIMENSIONS, vector),
            )

        original_save = HNSWGraphIndex.save

        def save_then_clear_generation(graph, path):
            original_save(graph, path)
            with sqlite3.connect(database_path) as database:
                database.execute(
                    "UPDATE history_metadata SET generation = generation + 1"
                )

        monkeypatch.setattr(HNSWGraphIndex, "save", save_then_clear_generation)

        indexer._rebuild_hnsw()

        assert not indexer.index_path.exists()
