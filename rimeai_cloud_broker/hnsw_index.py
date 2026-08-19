"""Small dependency-free HNSW graph persisted without plaintext history."""

from __future__ import annotations

import hashlib
import heapq
import json
import math
import os
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence, Tuple


Vector = Sequence[float]


def cosine_distance(left: Vector, right: Vector) -> float:
    dot = 0.0
    left_norm = 0.0
    right_norm = 0.0
    for a, b in zip(left, right):
        dot += a * b
        left_norm += a * a
        right_norm += b * b
    if left_norm <= 0 or right_norm <= 0:
        return 1.0
    similarity = dot / math.sqrt(left_norm * right_norm)
    return max(0.0, min(2.0, 1.0 - similarity))


class HNSWGraphIndex:
    SCHEMA_VERSION = 2

    def __init__(
        self,
        dimension: int,
        maximum_neighbors: int = 16,
        generation: Optional[int] = None,
    ):
        self.dimension = dimension
        self.maximum_neighbors = maximum_neighbors
        self.generation = generation
        self.entry_label: Optional[int] = None
        self.nodes: Dict[int, Dict[str, object]] = {}

    @classmethod
    def load(
        cls,
        path: Path,
        dimension: int,
        expected_generation: Optional[int] = None,
    ) -> "HNSWGraphIndex":
        index = cls(dimension, generation=expected_generation)
        if not path.exists():
            return index
        try:
            value = json.loads(path.read_text(encoding="utf-8"))
            if (
                value.get("schema_version") != cls.SCHEMA_VERSION
                or value.get("dimension") != dimension
                or (
                    expected_generation is not None
                    and value.get("generation") != expected_generation
                )
            ):
                return index
            index.generation = value.get("generation")
            index.entry_label = value.get("entry_label")
            index.nodes = {
                int(label): {
                    "level": int(node["level"]),
                    "neighbors": [
                        [int(neighbor) for neighbor in layer]
                        for layer in node["neighbors"]
                    ],
                }
                for label, node in value["nodes"].items()
            }
        except (OSError, ValueError, TypeError, KeyError, json.JSONDecodeError):
            return cls(dimension, generation=expected_generation)
        return index

    def save(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        payload = {
            "schema_version": self.SCHEMA_VERSION,
            "dimension": self.dimension,
            "generation": self.generation,
            "maximum_neighbors": self.maximum_neighbors,
            "entry_label": self.entry_label,
            "nodes": {
                str(label): node for label, node in sorted(self.nodes.items())
            },
        }
        temporary = path.with_suffix(".tmp")
        temporary.write_text(
            json.dumps(payload, separators=(",", ":"), sort_keys=True),
            encoding="utf-8",
        )
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)

    def synchronize(self, vectors: Dict[int, Vector]) -> None:
        live = set(vectors)
        if set(self.nodes) - live:
            # Product history supports clear-all, not individual deletion. A
            # mismatch means an interrupted clear or corrupt graph: rebuild.
            self.nodes.clear()
            self.entry_label = None
        for label in sorted(live - set(self.nodes)):
            self._insert(label, vectors[label], vectors)

    def query(
        self,
        vector: Vector,
        vectors: Dict[int, Vector],
        maximum_count: int = 8,
        ef_search: int = 64,
    ) -> List[Tuple[int, float]]:
        if self.entry_label is None or self.entry_label not in vectors:
            return []
        current = self.entry_label
        current_distance = cosine_distance(vector, vectors[current])
        maximum_level = int(self.nodes[current]["level"])
        for level in range(maximum_level, 0, -1):
            changed = True
            while changed:
                changed = False
                for neighbor in self._neighbors(current, level):
                    if neighbor not in vectors:
                        continue
                    distance = cosine_distance(vector, vectors[neighbor])
                    if distance < current_distance:
                        current = neighbor
                        current_distance = distance
                        changed = True
        candidates = [(current_distance, current)]
        best = [(-current_distance, current)]
        visited = {current}
        while candidates:
            candidate_distance, candidate = heapq.heappop(candidates)
            worst_best = -best[0][0]
            if len(best) >= ef_search and candidate_distance > worst_best:
                break
            for neighbor in self._neighbors(candidate, 0):
                if neighbor in visited or neighbor not in vectors:
                    continue
                visited.add(neighbor)
                distance = cosine_distance(vector, vectors[neighbor])
                if len(best) < ef_search or distance < -best[0][0]:
                    heapq.heappush(candidates, (distance, neighbor))
                    heapq.heappush(best, (-distance, neighbor))
                    if len(best) > ef_search:
                        heapq.heappop(best)
        ordered = sorted(
            ((label, -negative) for negative, label in best),
            key=lambda item: (item[1], item[0]),
        )
        return ordered[: max(1, maximum_count)]

    def _insert(
        self,
        label: int,
        vector: Vector,
        vectors: Dict[int, Vector],
    ) -> None:
        level = self._deterministic_level(label)
        self.nodes[label] = {
            "level": level,
            "neighbors": [[] for _ in range(level + 1)],
        }
        existing = [value for value in self.nodes if value != label]
        for layer in range(level, -1, -1):
            eligible = [
                value
                for value in existing
                if int(self.nodes[value]["level"]) >= layer
                and value in vectors
            ]
            nearest = sorted(
                eligible,
                key=lambda value: (
                    cosine_distance(vector, vectors[value]),
                    value,
                ),
            )[: self.maximum_neighbors]
            self.nodes[label]["neighbors"][layer] = nearest
            for neighbor in nearest:
                layer_neighbors = self.nodes[neighbor]["neighbors"][layer]
                if label not in layer_neighbors:
                    layer_neighbors.append(label)
                if len(layer_neighbors) > self.maximum_neighbors:
                    layer_neighbors.sort(
                        key=lambda value: (
                            cosine_distance(
                                vectors[neighbor],
                                vectors[value],
                            ),
                            value,
                        )
                    )
                    del layer_neighbors[self.maximum_neighbors :]
        if self.entry_label is None or level > int(
            self.nodes[self.entry_label]["level"]
        ):
            self.entry_label = label

    def _neighbors(self, label: int, level: int) -> Iterable[int]:
        layers = self.nodes[label]["neighbors"]
        if level >= len(layers):
            return ()
        return layers[level]

    @staticmethod
    def _deterministic_level(label: int) -> int:
        digest = hashlib.sha256(str(label).encode()).digest()
        level = 0
        for value in digest:
            if value >= 64 or level >= 8:
                break
            level += 1
        return level
