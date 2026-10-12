from pathlib import Path
from array import array
import sqlite3
import tempfile

from rimeai_cloud_broker import history_index as history_index_module
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
        # 历史向量只代入用户实际上屏的文本，不代入打的拼音。
        assert texts == ["海豚项目"]
        return [[0.25] * EMBEDDING_DIMENSIONS]


def test_embedding_jobs_persist_frozen_model_and_dimensions(monkeypatch):
    monkeypatch.setattr(history_index_module, "EMBEDDING_INDEXING_ENABLED", True)
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


class FailIfCalledEmbedder:
    def embed_texts(self, texts):
        raise AssertionError("embeddings must not be requested when disabled")


def test_embedding_indexing_is_off_by_default_and_drains_pending_jobs():
    # 本地 Ollama 没有任何 embedding 模型：索引循环对 /v1/embeddings 的
    # 重试只会产生连绵 404（见 EMBEDDING_INDEXING_ENABLED 注释）。
    # 默认关闭；排队中的任务永远无人处理，直接清空以免无限增长，
    # 已就绪的检索路径不受影响。
    assert history_index_module.EMBEDDING_INDEXING_ENABLED is False
    with tempfile.TemporaryDirectory(dir="/tmp") as root:
        database_path = Path(root) / "history.sqlite3"
        _database(database_path)
        indexer = HistoryEmbeddingIndexer(
            database_path,
            Path(root) / "history-hnsw-v1.bin",
        )

        assert indexer.run_once(FailIfCalledEmbedder()) == 1

        with sqlite3.connect(database_path) as database:
            jobs = database.execute(
                "SELECT COUNT(*) FROM embedding_jobs"
            ).fetchone()[0]
            state = database.execute(
                "SELECT embedding_state FROM history_commits"
                " WHERE id = 'commit-1'"
            ).fetchone()[0]
        assert jobs == 0
        assert state == "pending"
        # Draining is idempotent; nothing is left to remove.
        assert indexer.run_once(FailIfCalledEmbedder()) == 0


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

        # 正序：snippet 按提交时间从旧到新排列（不再按向量距离）。
        assert [
            snippet["id"] for snippet in augmented["history_snippets"]
        ] == ["older-unrelated", "older-related"]
        assert all(
            item["id"] != "recent-seed"
            for item in augmented["history_snippets"]
        )


def test_augmented_history_is_chronological_regardless_of_source_order():
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
                        400,
                        EMBEDDING_MODEL,
                        EMBEDDING_DIMENSIONS,
                        blob(1.0, 0.0),
                    ),
                    (
                        "latest",
                        "zuixin",
                        "海豚项目复盘",
                        300,
                        EMBEDDING_MODEL,
                        EMBEDDING_DIMENSIONS,
                        blob(0.9, 0.1),
                    ),
                    (
                        "earlier",
                        "zaoqi",
                        "海豚项目立项",
                        100,
                        EMBEDDING_MODEL,
                        EMBEDDING_DIMENSIONS,
                        blob(0.8, 0.2),
                    ),
                ],
            )
        indexer._rebuild_hnsw()

        # 客户端 snippet 按 bm25 相关度乱序到达：合并后仍必须正序。
        incoming = [
            {
                "id": "client-1",
                "text": "海豚项目周报",
                "bundle_id": "com.example.Editor",
                "committed_at_ms": 200,
                "score": 0.9,
            }
        ]
        augmented = indexer.augment_request(
            {"pinyin": "hai", "history_snippets": incoming}
        )

        timestamps = [
            snippet["committed_at_ms"]
            for snippet in augmented["history_snippets"]
        ]
        assert timestamps == sorted(timestamps)
        assert "client-1" in {
            snippet["id"] for snippet in augmented["history_snippets"]
        }


def test_augment_request_ignores_typed_pinyin():
    # 用户打的拼音不参与历史代入：带不带 pinyin 字段，种子与
    # 返回的 snippet 必须完全一致（旧实现会按 pinyin LIKE 追加
    # 种子向量，两条路径结果不同）。
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
                        400,
                        EMBEDDING_MODEL,
                        EMBEDDING_DIMENSIONS,
                        blob(1.0, 0.0),
                    ),
                    (
                        "pinyin-match",
                        "xinshuru",
                        "新输入测试",
                        100,
                        EMBEDDING_MODEL,
                        EMBEDDING_DIMENSIONS,
                        blob(0.0, 1.0),
                    ),
                ],
            )
        indexer._rebuild_hnsw()

        with_pinyin = indexer.augment_request(
            {"pinyin": "xinshuru", "history_snippets": []}
        )
        without_pinyin = indexer.augment_request(
            {"history_snippets": []}
        )

        assert with_pinyin["history_snippets"] == without_pinyin[
            "history_snippets"
        ]
        assert with_pinyin["history_snippets"]


def test_augment_request_tolerates_missing_pinyin_for_continuation(
    monkeypatch,
):
    # 续写请求没有拼音字段：历史增强只能按最近提交取种子，不得抛
    # KeyError（真实 broker 曾因此在 _prepare_continuation_request
    # 静默吞掉 continuation 响应）。
    monkeypatch.setattr(
        history_index_module, "EMBEDDING_INDEXING_ENABLED", True
    )
    with tempfile.TemporaryDirectory(dir="/tmp") as root:
        database_path = Path(root) / "history.sqlite3"
        _database(database_path)
        indexer = HistoryEmbeddingIndexer(
            database_path,
            Path(root) / "history-hnsw-v1.bin",
        )
        assert indexer.run_once(FakeEmbedder()) == 1

        augmented = indexer.augment_request(
            {
                "type": "continuation",
                "recent_context": "床前明月光",
                "history_snippets": [],
            }
        )

        assert augmented["recent_context"] == "床前明月光"
        assert isinstance(augmented["history_snippets"], list)


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
