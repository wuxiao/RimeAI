"""Trainable character n-gram baseline for constrained Rime reranking."""

from collections import Counter
from dataclasses import dataclass
import gzip
import hashlib
import json
import math
import os
from pathlib import Path
import tempfile
from typing import Any, Dict, Iterable, List, Mapping, Optional, Sequence, Tuple

from .candidate_policy import partition_full_length_candidates


ORDERS = (2, 3, 4, 5)
TOP_K = 10
_RANK_WEIGHTS = (0.1, 0.25, 0.5, 1.0, 2.0)
_FREQUENCY_WEIGHTS = (0.0, 0.25, 0.5, 1.0, 2.0)
_LANGUAGE_WEIGHTS = (0.0, 0.25, 0.5, 1.0, 2.0)


class NGramModelError(ValueError):
    pass


@dataclass(frozen=True)
class NGramRankerModel:
    dataset_sha256: str
    split_counts: Dict[str, int]
    rank_weight: float
    frequency_weight: float
    language_weight: float
    candidate_frequencies: Dict[str, int]
    ngram_counts: Dict[int, Dict[str, int]]
    prefix_counts: Dict[int, Dict[str, int]]
    max_context_characters: int = 40
    top_k: int = TOP_K

    def _language_score(self, context: str, candidate: str) -> float:
        text = "^" + context[-self.max_context_characters :] + candidate
        candidate_start = len(text) - len(candidate)
        total = 0.0
        terms = 0
        for position in range(candidate_start, len(text)):
            for order in ORDERS:
                start = position - order + 1
                if start < 0:
                    continue
                gram = text[start : position + 1]
                prefix = gram[:-1]
                count = self.ngram_counts[order].get(gram, 0)
                prefix_count = self.prefix_counts[order].get(prefix, 0)
                total += math.log((count + 0.1) / (prefix_count + 1000.0))
                terms += 1
        return total / max(1, terms)

    def _candidate_score(
        self,
        context: str,
        candidate: str,
        baseline_index: int,
    ) -> float:
        return (
            -self.rank_weight * baseline_index
            + self.frequency_weight
            * math.log1p(self.candidate_frequencies.get(candidate, 0))
            + self.language_weight * self._language_score(context, candidate)
        )

    def rank(
        self,
        *,
        context: str,
        candidates: Sequence[str],
    ) -> Tuple[List[str], float]:
        semantic_window = [
            {"id": f"c{index}", "text": candidate}
            for index, candidate in enumerate(candidates[: self.top_k])
        ]
        eligible, preserved = partition_full_length_candidates(semantic_window)
        scored = [
            (
                self._candidate_score(
                    context,
                    candidate["text"],
                    int(candidate["id"][1:]),
                ),
                int(candidate["id"][1:]),
                candidate,
            )
            for candidate in eligible
        ]
        scored.sort(key=lambda item: (-item[0], item[1]))
        ranked_window = [item[2]["text"] for item in scored]
        ranked_window.extend(candidate["text"] for candidate in preserved)
        ranked_window.extend(candidates[self.top_k :])
        if len(scored) < 2:
            confidence = 1.0
        else:
            margin = scored[0][0] - scored[1][0]
            confidence = 1.0 / (1.0 + math.exp(-max(-30.0, min(30.0, margin))))
        return ranked_window, confidence

    def to_dict(self) -> Dict[str, Any]:
        return {
            "schema_version": 1,
            "model_type": "char-ngram-ranker",
            "dataset_sha256": self.dataset_sha256,
            "split_counts": self.split_counts,
            "hyperparameters": {
                "rank_weight": self.rank_weight,
                "frequency_weight": self.frequency_weight,
                "language_weight": self.language_weight,
                "orders": list(ORDERS),
                "max_context_characters": self.max_context_characters,
                "top_k": self.top_k,
                "smoothing": {
                    "numerator": 0.1,
                    "denominator": 1000.0,
                },
            },
            "candidate_frequencies": self.candidate_frequencies,
            "ngram_counts": {
                str(order): self.ngram_counts[order] for order in ORDERS
            },
            "prefix_counts": {
                str(order): self.prefix_counts[order] for order in ORDERS
            },
        }


def _build_counts(
    samples: Iterable[Dict[str, Any]],
) -> Tuple[
    Dict[str, int],
    Dict[int, Dict[str, int]],
    Dict[int, Dict[str, int]],
]:
    frequencies: Counter[str] = Counter()
    ngram_counters = {order: Counter() for order in ORDERS}
    prefix_counters = {order: Counter() for order in ORDERS}
    for sample in samples:
        gold = sample["gold_text"]
        frequencies[gold] += 1
        text = "^" + sample["context"][-40:] + gold + "$"
        for order in ORDERS:
            for start in range(len(text) - order + 1):
                gram = text[start : start + order]
                ngram_counters[order][gram] += 1
                prefix_counters[order][gram[:-1]] += 1
    return (
        dict(frequencies),
        {order: dict(counter) for order, counter in ngram_counters.items()},
        {order: dict(counter) for order, counter in prefix_counters.items()},
    )


def _validation_metrics(
    model: NGramRankerModel,
    samples: Sequence[Dict[str, Any]],
) -> Tuple[float, float, int]:
    covered = 0
    hits = 0
    reciprocal_rank = 0.0
    for sample in samples:
        candidates = sample["candidates"][: model.top_k]
        gold = sample["gold_text"]
        if gold not in candidates:
            continue
        covered += 1
        ranking, _ = model.rank(
            context=sample["context"],
            candidates=sample["candidates"],
        )
        if ranking[0] == gold:
            hits += 1
        reciprocal_rank += 1.0 / (ranking.index(gold) + 1)
    if covered == 0:
        raise NGramModelError(
            "validation split has no gold candidates in the Rime Top-10"
        )
    return hits / covered, reciprocal_rank / covered, covered


def train_ngram_model(
    samples: Sequence[Dict[str, Any]],
    *,
    dataset_sha256: str,
) -> Tuple[NGramRankerModel, Dict[str, Any]]:
    train_samples = [sample for sample in samples if sample["split"] == "train"]
    validation_samples = [
        sample for sample in samples if sample["split"] == "validation"
    ]
    if not train_samples:
        raise NGramModelError("dataset has no training samples")
    if not validation_samples:
        raise NGramModelError("dataset has no validation samples")
    frequencies, ngram_counts, prefix_counts = _build_counts(train_samples)
    split_counts = {
        "train": len(train_samples),
        "validation": len(validation_samples),
    }

    best: Optional[
        Tuple[float, float, float, float, float, NGramRankerModel]
    ] = None
    for rank_weight in _RANK_WEIGHTS:
        for frequency_weight in _FREQUENCY_WEIGHTS:
            for language_weight in _LANGUAGE_WEIGHTS:
                model = NGramRankerModel(
                    dataset_sha256=dataset_sha256,
                    split_counts=split_counts,
                    rank_weight=rank_weight,
                    frequency_weight=frequency_weight,
                    language_weight=language_weight,
                    candidate_frequencies=frequencies,
                    ngram_counts=ngram_counts,
                    prefix_counts=prefix_counts,
                )
                accuracy, mrr, covered = _validation_metrics(
                    model, validation_samples
                )
                selection = (
                    accuracy,
                    mrr,
                    -frequency_weight - language_weight,
                    rank_weight,
                    -language_weight,
                    model,
                )
                if best is None or selection[:-1] > best[:-1]:
                    best = selection
    assert best is not None
    selected_model = best[-1]
    validation_accuracy, validation_mrr, covered = _validation_metrics(
        selected_model, validation_samples
    )
    report = {
        "schema_version": 1,
        "model_type": "char-ngram-ranker",
        "dataset_sha256": dataset_sha256,
        "train_samples": len(train_samples),
        "validation_samples": len(validation_samples),
        "test_samples_used": 0,
        "validation": {
            "covered_samples": covered,
            "conditional_top1_accuracy": round(validation_accuracy, 6),
            "conditional_mrr": round(validation_mrr, 6),
        },
        "selected_hyperparameters": {
            "rank_weight": selected_model.rank_weight,
            "frequency_weight": selected_model.frequency_weight,
            "language_weight": selected_model.language_weight,
        },
    }
    return selected_model, report


def write_ngram_model_atomic(path: Path, model: NGramRankerModel) -> str:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        dir=path.parent,
        prefix=f".{path.name}.",
        suffix=".tmp",
    )
    try:
        with os.fdopen(descriptor, "wb") as raw_file:
            with gzip.GzipFile(
                filename="",
                mode="wb",
                fileobj=raw_file,
                mtime=0,
            ) as compressed:
                payload = json.dumps(
                    model.to_dict(),
                    ensure_ascii=False,
                    separators=(",", ":"),
                    sort_keys=True,
                ).encode("utf-8")
                compressed.write(payload)
            raw_file.flush()
            os.fsync(raw_file.fileno())
        os.replace(temporary_name, path)
    except BaseException:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass
        raise
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_ngram_model(path: Path) -> NGramRankerModel:
    try:
        with gzip.open(path, "rt", encoding="utf-8") as model_file:
            payload = json.load(model_file)
    except (OSError, json.JSONDecodeError) as error:
        raise NGramModelError(f"cannot read model artifact '{path}'") from error
    if (
        not isinstance(payload, dict)
        or payload.get("schema_version") != 1
        or payload.get("model_type") != "char-ngram-ranker"
    ):
        raise NGramModelError("unsupported n-gram model artifact")
    hyperparameters = payload.get("hyperparameters")
    if not isinstance(hyperparameters, dict):
        raise NGramModelError("model hyperparameters are missing")
    if hyperparameters.get("orders") != list(ORDERS):
        raise NGramModelError("model n-gram orders are incompatible")
    try:
        return NGramRankerModel(
            dataset_sha256=payload["dataset_sha256"],
            split_counts={
                str(key): int(value)
                for key, value in payload["split_counts"].items()
            },
            rank_weight=float(hyperparameters["rank_weight"]),
            frequency_weight=float(hyperparameters["frequency_weight"]),
            language_weight=float(hyperparameters["language_weight"]),
            candidate_frequencies={
                str(key): int(value)
                for key, value in payload["candidate_frequencies"].items()
            },
            ngram_counts={
                order: {
                    str(key): int(value)
                    for key, value in payload["ngram_counts"][str(order)].items()
                }
                for order in ORDERS
            },
            prefix_counts={
                order: {
                    str(key): int(value)
                    for key, value in payload["prefix_counts"][str(order)].items()
                }
                for order in ORDERS
            },
            max_context_characters=int(
                hyperparameters["max_context_characters"]
            ),
            top_k=int(hyperparameters["top_k"]),
        )
    except (KeyError, TypeError, ValueError, AttributeError) as error:
        raise NGramModelError("model artifact fields are invalid") from error
