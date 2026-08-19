from pathlib import Path
import tempfile

from rimeai_cloud_broker.hnsw_index import HNSWGraphIndex


def test_hnsw_graph_is_persistent_and_returns_nearest_vectors():
    vectors = {
        1: [1.0, 0.0, 0.0],
        2: [0.95, 0.05, 0.0],
        3: [0.0, 1.0, 0.0],
        4: [0.0, 0.0, 1.0],
    }
    with tempfile.TemporaryDirectory(dir="/tmp") as root:
        path = Path(root) / "history-hnsw-v1.bin"
        index = HNSWGraphIndex(
            dimension=3,
            maximum_neighbors=2,
            generation=7,
        )
        index.synchronize(vectors)
        index.save(path)

        restored = HNSWGraphIndex.load(
            path,
            dimension=3,
            expected_generation=7,
        )
        neighbors = restored.query(
            [1.0, 0.0, 0.0],
            vectors,
            maximum_count=2,
        )

        assert neighbors[0][0] == 1
        assert {label for label, _ in neighbors} == {1, 2}
        assert "海豚项目" not in path.read_text(encoding="utf-8")

        stale = HNSWGraphIndex.load(
            path,
            dimension=3,
            expected_generation=8,
        )
        assert stale.entry_label is None
        assert stale.nodes == {}
