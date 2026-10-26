"""Pinyin-aware listwise Cross-Encoder training and local inference.

The module keeps heavyweight neural dependencies optional. Importing dataset and
artifact helpers does not require a model download, and every runtime load uses
local files only so the daemon's Offline Lock remains enforceable.
"""

from __future__ import annotations

import gc
import hashlib
import json
import math
import os
import random
import sys
import tempfile
from collections import defaultdict
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from time import perf_counter
from typing import Any, Optional

from .candidate_policy import partition_full_length_candidates
from .pinyin_guard import PinyinGuard, generic_pinyin_segmentation
from .ranking import RankerError, Ranking

MODEL_TYPE = "rimeai-pinyin-listwise-cross-encoder"
BASE_MODEL_ID = "BAAI/bge-small-zh-v1.5"
EXPECTED_HIDDEN_SIZE = 512
EXPECTED_LAYERS = 4
EXPECTED_ATTENTION_HEADS = 8
DEFAULT_MAX_LENGTH = 128
CONTEXT_MARKER = "[CTX]"
PINYIN_MARKER = "[PY]"
CANDIDATE_MARKER = "[CAND]"
RANK_MARKERS = tuple(f"[RANK_{index}]" for index in range(1, 11))
FUSION_TYPE = "rimeai-neural-ngram-v1"
# v2: scores are affine-normalized with pooled validation statistics instead
# of per-sample z-scores, so two-candidate samples no longer collapse to a
# structural margin of exactly 2 or 4w-2.
FUSION_TYPE_GLOBAL_NORM = "rimeai-neural-ngram-v2"
FUSION_TYPES = (FUSION_TYPE, FUSION_TYPE_GLOBAL_NORM)
GLOBAL_NORM_METHOD = "validation-global-affine"


class NeuralRankerError(ValueError):
    pass


@dataclass(frozen=True)
class RankerExample:
    sample_id: str
    context: str
    pinyin: str
    candidates: tuple[str, ...]
    baseline_indices: tuple[int, ...]
    label: int
    context_ambiguous: bool


def _sha256_path(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        while True:
            chunk = file.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def build_special_tokens(guard: PinyinGuard) -> list[str]:
    syllables = sorted(
        {
            pronunciation
            for text, pronunciations in guard.pronunciations.items()
            if len(text) == 1
            for pronunciation in pronunciations
        }
    )
    return [
        CONTEXT_MARKER,
        PINYIN_MARKER,
        CANDIDATE_MARKER,
        *[f"[PY_{syllable}]" for syllable in syllables],
        *RANK_MARKERS,
    ]


def _generic_pinyin_segmentation(
    pinyin: str,
    guard: PinyinGuard,
) -> list[str]:
    # Moved to pinyin_guard.generic_pinyin_segmentation (with a cached
    # syllable table) so the MLX worker's decode fallback can share it;
    # this thin alias keeps existing imports and tests working.
    return generic_pinyin_segmentation(pinyin, guard)


def format_ranker_input(
    *,
    context: str,
    pinyin: str,
    candidate: str,
    baseline_index: int,
    guard: PinyinGuard,
) -> str:
    syllables = guard.segment(
        candidate,
        pinyin,
        maximum_characters=128,
    )
    if syllables is None:
        syllables = _generic_pinyin_segmentation(pinyin, guard)
    pinyin_tokens = " ".join(f"[PY_{part}]" for part in syllables)
    rank_index = max(0, min(baseline_index, len(RANK_MARKERS) - 1))
    return " ".join(
        part
        for part in (
            CONTEXT_MARKER,
            context[-100:],
            PINYIN_MARKER,
            pinyin_tokens,
            CANDIDATE_MARKER,
            RANK_MARKERS[rank_index],
            candidate,
        )
        if part
    )


def build_ranker_examples(
    samples: Sequence[Mapping[str, Any]],
    *,
    split: str,
) -> list[RankerExample]:
    selected = [sample for sample in samples if sample.get("split") == split]
    golds_by_pinyin: dict[str, set[str]] = defaultdict(set)
    for sample in selected:
        golds_by_pinyin[str(sample["pinyin"])].add(str(sample["gold_text"]))

    examples: list[RankerExample] = []
    for sample in selected:
        semantic_window = [
            {"id": str(index), "text": str(candidate)}
            for index, candidate in enumerate(sample["candidates"][:10])
        ]
        eligible, _ = partition_full_length_candidates(semantic_window)
        candidates = tuple(candidate["text"] for candidate in eligible)
        gold_text = str(sample["gold_text"])
        if len(candidates) < 2 or gold_text not in candidates:
            continue
        baseline_indices = tuple(int(candidate["id"]) for candidate in eligible)
        examples.append(
            RankerExample(
                sample_id=str(sample["id"]),
                context=str(sample["context"]),
                pinyin=str(sample["pinyin"]),
                candidates=candidates,
                baseline_indices=baseline_indices,
                label=candidates.index(gold_text),
                context_ambiguous=len(golds_by_pinyin[str(sample["pinyin"])]) > 1,
            )
        )
    return examples


def calibrate_change_threshold(
    records: Sequence[Mapping[str, Any]],
    *,
    target_precision: float = 0.90,
) -> dict[str, Any]:
    if not 0 < target_precision <= 1:
        raise NeuralRankerError("target precision must be from 0 (exclusive) to 1")
    if not records:
        return {
            "margin_threshold": 1.0,
            "target_precision": target_precision,
            "changed_samples": 0,
            "wins": 0,
            "losses": 0,
            "precision": 0.0,
        }
    thresholds = sorted({float(record["margin"]) for record in records})
    best: dict[str, Any] | None = None
    for threshold in thresholds:
        selected = [
            record
            for record in records
            if float(record["margin"]) >= threshold
        ]
        wins = sum(
            not bool(record["baseline_correct"])
            and bool(record["model_correct"])
            for record in selected
        )
        losses = sum(
            bool(record["baseline_correct"])
            and not bool(record["model_correct"])
            for record in selected
        )
        correct = sum(bool(record["model_correct"]) for record in selected)
        precision = correct / len(selected)
        if precision < target_precision or wins <= losses:
            continue
        candidate = {
            "margin_threshold": threshold,
            "target_precision": target_precision,
            "changed_samples": len(selected),
            "wins": wins,
            "losses": losses,
            "precision": precision,
        }
        if best is None or candidate["changed_samples"] > best["changed_samples"]:
            best = candidate
    if best is not None:
        return best
    return {
        "margin_threshold": max(thresholds) + 1.0,
        "target_precision": target_precision,
        "changed_samples": 0,
        "wins": 0,
        "losses": 0,
        "precision": 0.0,
    }


def standardize_scores(scores: Sequence[float]) -> list[float]:
    if not scores:
        return []
    mean = sum(scores) / len(scores)
    deviation = math.sqrt(
        sum((score - mean) ** 2 for score in scores) / len(scores)
    )
    if deviation == 0:
        return [0.0 for _ in scores]
    return [(score - mean) / deviation for score in scores]


def _finite_float(value: Any) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    number = float(value)
    return number if math.isfinite(number) else None


def pooled_affine_stats(scores: Sequence[float]) -> tuple[float, float]:
    """Mean and population deviation over pooled candidate scores."""
    if not scores:
        raise NeuralRankerError("cannot normalize with no pooled scores")
    mean = sum(scores) / len(scores)
    deviation = math.sqrt(
        sum((score - mean) ** 2 for score in scores) / len(scores)
    )
    if deviation <= 0:
        raise NeuralRankerError("pooled score statistics are degenerate")
    return mean, deviation


@dataclass(frozen=True)
class FusionConfig:
    path: Path
    artifact_id: str
    neural_weight: float
    neural_artifact_id: str
    ngram_dataset_sha256: str
    validation_dataset_sha256: str
    margin_threshold: float
    target_precision: float
    # v2 (global-affine) extensions. Absent on v1 configs, which keep the
    # per-sample z-score semantics bit-for-bit.
    fusion_type: str = FUSION_TYPE
    neural_mean: float | None = None
    neural_std: float | None = None
    ngram_mean: float | None = None
    ngram_std: float | None = None

    @classmethod
    def _load_global_normalization(
        cls,
        payload: Mapping[str, Any],
    ) -> dict[str, float]:
        section = payload.get("score_normalization")
        if (
            not isinstance(section, dict)
            or section.get("method") != GLOBAL_NORM_METHOD
        ):
            raise NeuralRankerError(
                "fusion config score normalization is missing or unsupported"
            )
        stats: dict[str, float] = {}
        for key in ("neural_mean", "neural_std", "ngram_mean", "ngram_std"):
            value = _finite_float(section.get(key))
            if value is None:
                raise NeuralRankerError(
                    f"fusion config score normalization '{key}' is invalid"
                )
            stats[key] = value
        if stats["neural_std"] <= 0 or stats["ngram_std"] <= 0:
            raise NeuralRankerError(
                "fusion config score normalization deviations must be positive"
            )
        return stats

    @classmethod
    def load(
        cls,
        path: Path,
        *,
        neural_artifact_id: Optional[str] = None,
        ngram_dataset_sha256: Optional[str] = None,
    ) -> FusionConfig:
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise NeuralRankerError(f"cannot read fusion config '{path}'") from error
        decision = payload.get("decision") if isinstance(payload, dict) else None
        fusion_type = payload.get("fusion_type") if isinstance(payload, dict) else None
        if (
            not isinstance(payload, dict)
            or payload.get("schema_version") != 1
            or not isinstance(fusion_type, str)
            or fusion_type not in FUSION_TYPES
            or not isinstance(decision, dict)
        ):
            raise NeuralRankerError("unsupported neural fusion config")
        normalization = (
            cls._load_global_normalization(payload)
            if fusion_type == FUSION_TYPE_GLOBAL_NORM
            else {}
        )
        try:
            config = cls(
                path=path,
                artifact_id=str(payload["artifact_id"]),
                neural_weight=float(payload["neural_weight"]),
                neural_artifact_id=str(payload["neural_artifact_id"]),
                ngram_dataset_sha256=str(payload["ngram_dataset_sha256"]),
                validation_dataset_sha256=str(payload["validation_dataset_sha256"]),
                margin_threshold=float(decision["margin_threshold"]),
                target_precision=float(decision["target_precision"]),
                fusion_type=fusion_type,
                **normalization,
            )
        except (KeyError, TypeError, ValueError) as error:
            raise NeuralRankerError("neural fusion fields are invalid") from error
        if (
            not 0 <= config.neural_weight <= 1
            or config.margin_threshold < 0
            or not 0 < config.target_precision <= 1
        ):
            raise NeuralRankerError("neural fusion parameters are invalid")
        if neural_artifact_id is not None and (
            config.neural_artifact_id != neural_artifact_id
        ):
            raise NeuralRankerError("fusion config neural artifact mismatch")
        if ngram_dataset_sha256 is not None and (
            config.ngram_dataset_sha256 != ngram_dataset_sha256
        ):
            raise NeuralRankerError("fusion config n-gram artifact mismatch")
        return config

    def fuse_scores(
        self,
        neural_scores: Sequence[float],
        ngram_scores: Sequence[float],
    ) -> list[float]:
        """Normalize both score sources then apply the weighted fusion.

        v1 configs keep the legacy per-sample z-score path verbatim; v2
        configs affine-normalize raw scores with pooled validation statistics,
        so the fused margin for two-candidate samples is no longer structurally
        pinned to 2 or 4w-2.
        """
        if self.fusion_type == FUSION_TYPE_GLOBAL_NORM:
            neural_mean = self.neural_mean
            neural_std = self.neural_std
            ngram_mean = self.ngram_mean
            ngram_std = self.ngram_std
            if (
                neural_mean is None
                or neural_std is None
                or ngram_mean is None
                or ngram_std is None
            ):
                raise NeuralRankerError(
                    "fusion config global normalization parameters are missing"
                )
            neural = [
                (score - neural_mean) / neural_std
                for score in neural_scores
            ]
            ngram = [
                (score - ngram_mean) / ngram_std
                for score in ngram_scores
            ]
        else:
            neural = standardize_scores(neural_scores)
            ngram = standardize_scores(ngram_scores)
        weight = self.neural_weight
        return [
            weight * neural[index] + (1.0 - weight) * ngram[index]
            for index in range(len(neural))
        ]


@dataclass(frozen=True)
class NeuralRankerArtifact:
    root: Path
    manifest: dict[str, Any]

    @classmethod
    def load(cls, root: Path) -> NeuralRankerArtifact:
        manifest_path = root / "manifest.json"
        try:
            payload = json.loads(manifest_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise NeuralRankerError(
                f"cannot read neural ranker manifest '{manifest_path}'"
            ) from error
        if (
            not isinstance(payload, dict)
            or payload.get("schema_version") != 1
            or payload.get("model_type") != MODEL_TYPE
        ):
            raise NeuralRankerError("unsupported neural ranker artifact")
        architecture = payload.get("architecture")
        if not isinstance(architecture, dict) or (
            architecture.get("hidden_size") != EXPECTED_HIDDEN_SIZE
            or architecture.get("layers") != EXPECTED_LAYERS
            or architecture.get("attention_heads") != EXPECTED_ATTENTION_HEADS
        ):
            raise NeuralRankerError("artifact does not match the planned 24M architecture")
        decision = payload.get("decision")
        if (
            not isinstance(decision, dict)
            or not isinstance(decision.get("margin_threshold"), (int, float))
            or not math.isfinite(float(decision["margin_threshold"]))
        ):
            raise NeuralRankerError("neural ranker decision calibration is invalid")
        files = payload.get("files")
        if not isinstance(files, dict):
            raise NeuralRankerError("neural ranker file manifest is invalid")
        for relative, expected in files.items():
            if not isinstance(relative, str) or not isinstance(expected, dict):
                raise NeuralRankerError("neural ranker file entry is invalid")
            path = root / relative
            if not path.is_file():
                raise NeuralRankerError(f"neural ranker file is missing: {relative}")
            if path.stat().st_size != expected.get("bytes"):
                raise NeuralRankerError(f"neural ranker file size mismatch: {relative}")
            if _sha256_path(path) != expected.get("sha256"):
                raise NeuralRankerError(f"neural ranker SHA-256 mismatch: {relative}")
        return cls(root=root, manifest=payload)

    @property
    def artifact_id(self) -> str:
        return str(self.manifest.get("artifact_id", ""))

    @property
    def margin_threshold(self) -> float:
        return float(self.manifest["decision"]["margin_threshold"])

    @property
    def target_precision(self) -> float:
        return float(self.manifest["decision"].get("target_precision", 0.90))

    @property
    def max_length(self) -> int:
        return int(self.manifest["architecture"].get("max_length", 128))


def _neural_dependencies():
    try:
        import torch
        from safetensors.torch import load_file, save_file
        from transformers import AutoModel, AutoTokenizer
    except ImportError as error:
        raise NeuralRankerError(
            "neural ranker requires torch, transformers, and safetensors"
        ) from error
    return torch, load_file, save_file, AutoModel, AutoTokenizer


class _EncoderScorer:
    def __init__(self, encoder: Any, scorer: Any, dropout: Any):
        self.encoder = encoder
        self.scorer = scorer
        self.dropout = dropout

    def parameters(self):
        yield from self.encoder.parameters()
        yield from self.scorer.parameters()

    def train(self):
        self.encoder.train()
        self.scorer.train()

    def eval(self):
        self.encoder.eval()
        self.scorer.eval()

    def to(self, device: Any):
        self.encoder.to(device)
        self.scorer.to(device)
        self.dropout.to(device)
        return self

    def score(self, batch: Mapping[str, Any]):
        output = self.encoder(**batch)
        pooled = output.last_hidden_state[:, 0]
        return self.scorer(self.dropout(pooled)).squeeze(-1)


def _load_encoder_scorer(
    encoder_path: Path,
    head_path: Path,
    *,
    device: Any,
) -> tuple[Any, Any]:
    torch, load_file, _, AutoModel, AutoTokenizer = _neural_dependencies()
    tokenizer = AutoTokenizer.from_pretrained(
        str(encoder_path),
        local_files_only=True,
    )
    encoder = AutoModel.from_pretrained(
        str(encoder_path),
        local_files_only=True,
    )
    scorer = torch.nn.Linear(encoder.config.hidden_size, 1)
    scorer.load_state_dict(load_file(str(head_path)))
    model = _EncoderScorer(encoder, scorer, torch.nn.Dropout(0.1)).to(device)
    model.eval()
    return tokenizer, model


def _select_device(torch: Any, requested: str) -> Any:
    if requested == "auto":
        if torch.backends.mps.is_available():
            return torch.device("mps")
        return torch.device("cpu")
    if requested == "mps" and not torch.backends.mps.is_available():
        raise NeuralRankerError("MPS was requested but is unavailable")
    if requested not in {"cpu", "mps"}:
        raise NeuralRankerError("device must be auto, cpu, or mps")
    return torch.device(requested)


class NeuralListwiseRanker:
    name = "rimeai-ranker-s-24m"

    def __init__(
        self,
        artifact_path: Path,
        guard: PinyinGuard,
        *,
        device: str = "auto",
    ):
        started_at = perf_counter()
        torch, _, _, _, _ = _neural_dependencies()
        self.artifact = NeuralRankerArtifact.load(artifact_path)
        self.guard = guard
        self.device = _select_device(torch, device)
        self.tokenizer, self.model = _load_encoder_scorer(
            artifact_path / "encoder",
            artifact_path / "ranker_head.safetensors",
            device=self.device,
        )
        self.torch = torch
        # Materialize lazy backend kernels before the daemon begins accepting
        # requests. Otherwise the first user request can exceed its deadline,
        # while its uncancellable native inference is still running.
        self._scores(
            context="",
            pinyin="shi",
            candidates=("是", "时"),
            baseline_indices=(0, 1),
        )
        self.model_artifact_id = self.artifact.artifact_id
        self.cold_start_ms = (perf_counter() - started_at) * 1000
        self.attempt_latencies_ms: list[float] = []
        self.attempted_samples = 0
        self.successful_samples = 0

    def _scores(
        self,
        *,
        context: str,
        pinyin: str,
        candidates: Sequence[str],
        baseline_indices: Sequence[int],
    ) -> list[float]:
        texts = [
            format_ranker_input(
                context=context,
                pinyin=pinyin,
                candidate=candidate,
                baseline_index=baseline_index,
                guard=self.guard,
            )
            for candidate, baseline_index in zip(candidates, baseline_indices)
        ]
        batch = self.tokenizer(
            texts,
            padding=True,
            truncation=True,
            max_length=self.artifact.max_length,
            return_tensors="pt",
        )
        batch = {key: value.to(self.device) for key, value in batch.items()}
        with self.torch.inference_mode():
            scores = self.model.score(batch)
            if self.device.type == "mps":
                self.torch.mps.synchronize()
        return [float(value) for value in scores.detach().cpu().tolist()]

    def rank_candidates(
        self,
        *,
        context: str,
        pinyin: str,
        candidates: Sequence[str],
    ) -> tuple[list[str], float]:
        started_at = perf_counter()
        self.attempted_samples += 1
        semantic_window = [
            {"id": str(index), "text": candidate}
            for index, candidate in enumerate(candidates[:10])
        ]
        eligible, preserved = partition_full_length_candidates(semantic_window)
        if len(eligible) < 2:
            return list(candidates), 1.0
        texts = [candidate["text"] for candidate in eligible]
        baseline_indices = [int(candidate["id"]) for candidate in eligible]
        try:
            scores = self._scores(
                context=context,
                pinyin=pinyin,
                candidates=texts,
                baseline_indices=baseline_indices,
            )
        except Exception as error:
            raise RankerError("neural ranker inference failed") from error
        indexed = list(enumerate(zip(texts, scores)))
        indexed.sort(key=lambda item: (-item[1][1], item[0]))
        ranking = [item[1][0] for item in indexed]
        ranking.extend(candidate["text"] for candidate in preserved)
        ranking.extend(candidates[10:])
        ordered_scores = [item[1][1] for item in indexed]
        margin = ordered_scores[0] - ordered_scores[1]
        threshold = self.artifact.margin_threshold
        if ranking[0] == candidates[0]:
            confidence = 1.0
        elif margin >= threshold:
            excess = max(0.0, margin - threshold)
            confidence = self.artifact.target_precision + (
                1.0 - self.artifact.target_precision
            ) * (1.0 - math.exp(-excess))
        else:
            ratio = 0.0 if threshold <= 0 else max(0.0, margin / threshold)
            confidence = min(0.899, 0.5 + 0.399 * ratio)
        self.successful_samples += 1
        self.attempt_latencies_ms.append((perf_counter() - started_at) * 1000)
        return ranking, confidence

    def rank(self, sample: dict[str, Any]) -> Ranking:
        ranking, confidence = self.rank_candidates(
            context=sample["context"],
            pinyin=sample["pinyin"],
            candidates=sample["candidates"],
        )
        return Ranking(tuple(ranking), confidence)


def load_neural_ranker(
    artifact_path: Path,
    guard: PinyinGuard,
    *,
    device: str = "auto",
) -> Any:
    """Load either the training checkpoint or its locked ONNX derivative."""
    manifest_path = artifact_path / "manifest.json"
    try:
        payload = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise NeuralRankerError(
            f"cannot read neural ranker manifest '{manifest_path}'"
        ) from error
    model_type = payload.get("model_type") if isinstance(payload, dict) else None
    if model_type == MODEL_TYPE:
        return NeuralListwiseRanker(artifact_path, guard, device=device)
    from .onnx_ranker import ONNX_MODEL_TYPE, OnnxNeuralListwiseRanker

    if model_type == ONNX_MODEL_TYPE:
        return OnnxNeuralListwiseRanker(artifact_path, guard, device=device)
    raise NeuralRankerError("unsupported neural ranker artifact type")


class HybridSemanticRanker:
    """Validation-calibrated fusion of the neural and deterministic rankers."""

    name = "rimeai-ranker-s-24m-fusion"

    def __init__(
        self,
        neural_ranker: Any,
        ngram_ranker: Any,
        config_path: Path,
    ):
        self.neural_ranker = neural_ranker
        self.ngram_ranker = ngram_ranker
        self.config = FusionConfig.load(
            config_path,
            neural_artifact_id=neural_ranker.model_artifact_id,
            ngram_dataset_sha256=ngram_ranker.dataset_sha256,
        )
        self.model_artifact_id = self.config.artifact_id
        self.cold_start_ms = neural_ranker.cold_start_ms
        self.attempt_latencies_ms: list[float] = []
        self.attempted_samples = 0
        self.successful_samples = 0

    def rank_candidates(
        self,
        *,
        context: str,
        pinyin: str,
        candidates: Sequence[str],
    ) -> tuple[list[str], float]:
        started_at = perf_counter()
        self.attempted_samples += 1
        semantic_window = [
            {"id": str(index), "text": candidate}
            for index, candidate in enumerate(candidates[:10])
        ]
        eligible, preserved = partition_full_length_candidates(semantic_window)
        if len(eligible) < 2:
            return list(candidates), 1.0
        texts = [candidate["text"] for candidate in eligible]
        baseline_indices = [int(candidate["id"]) for candidate in eligible]
        try:
            neural_scores = self.neural_ranker._scores(
                context=context,
                pinyin=pinyin,
                candidates=texts,
                baseline_indices=baseline_indices,
            )
            ngram_scores = [
                self.ngram_ranker._candidate_score(
                    context,
                    candidate,
                    baseline_index,
                )
                for candidate, baseline_index in zip(texts, baseline_indices)
            ]
            fused_scores = self.config.fuse_scores(neural_scores, ngram_scores)
        except Exception as error:
            raise RankerError("hybrid semantic inference failed") from error
        ranked_indices = sorted(
            range(len(texts)),
            key=lambda index: (-fused_scores[index], index),
        )
        ranking = [texts[index] for index in ranked_indices]
        ranking.extend(candidate["text"] for candidate in preserved)
        ranking.extend(candidates[10:])
        margin = (
            fused_scores[ranked_indices[0]] - fused_scores[ranked_indices[1]]
        )
        if ranking[0] == candidates[0]:
            confidence = 1.0
        elif margin >= self.config.margin_threshold:
            excess = margin - self.config.margin_threshold
            confidence = self.config.target_precision + (
                1.0 - self.config.target_precision
            ) * (1.0 - math.exp(-excess))
        else:
            ratio = (
                0.0
                if self.config.margin_threshold <= 0
                else max(0.0, margin / self.config.margin_threshold)
            )
            confidence = min(0.899, 0.5 + 0.399 * ratio)
        self.successful_samples += 1
        self.attempt_latencies_ms.append((perf_counter() - started_at) * 1000)
        return ranking, confidence

    def rank(self, sample: dict[str, Any]) -> Ranking:
        ranking, confidence = self.rank_candidates(
            context=sample["context"],
            pinyin=sample["pinyin"],
            candidates=sample["candidates"],
        )
        return Ranking(tuple(ranking), confidence)


def train_fusion_config(
    samples: Sequence[Mapping[str, Any]],
    *,
    dataset_sha256: str,
    neural_ranker: Any,
    ngram_ranker: Any,
    output_path: Path,
    target_precision: float = 0.90,
) -> dict[str, Any]:
    """Jointly calibrate the fusion weight and change threshold.

    Scores are affine-normalized with pooled validation statistics (v2),
    and each weight is evaluated together with its calibrated threshold.
    The fixed selection order is: among weights whose calibrated threshold
    meets the target precision with wins > losses, maximize net gain
    (wins - losses), then calibrated changed_samples, then raw top-1
    accuracy, then the lower weight. If no weight calibrates, every entry
    has zero net gain and the raw top-1 tie-break decides while the
    threshold stays at its unreachable fallback.
    """
    validation = build_ranker_examples(samples, split="validation")
    if not validation:
        raise NeuralRankerError("dataset has no covered validation examples")
    cached: list[tuple[RankerExample, list[float], list[float]]] = []
    for example in validation:
        neural_scores = neural_ranker._scores(
            context=example.context,
            pinyin=example.pinyin,
            candidates=example.candidates,
            baseline_indices=example.baseline_indices,
        )
        ngram_scores = [
            ngram_ranker._candidate_score(
                example.context,
                candidate,
                baseline_index,
            )
            for candidate, baseline_index in zip(
                example.candidates,
                example.baseline_indices,
            )
        ]
        cached.append((example, neural_scores, ngram_scores))

    neural_mean, neural_std = pooled_affine_stats(
        [score for _, scores, _ in cached for score in scores]
    )
    ngram_mean, ngram_std = pooled_affine_stats(
        [score for _, _, scores in cached for score in scores]
    )
    normalized: list[tuple[RankerExample, list[float], list[float]]] = [
        (
            example,
            [(score - neural_mean) / neural_std for score in neural_scores],
            [(score - ngram_mean) / ngram_std for score in ngram_scores],
        )
        for example, neural_scores, ngram_scores in cached
    ]

    weight_table: list[dict[str, Any]] = []
    for step in range(21):
        weight = step / 20
        records: list[dict[str, Any]] = []
        for example, neural_scores, ngram_scores in normalized:
            scores = [
                weight * neural + (1.0 - weight) * ngram
                for neural, ngram in zip(neural_scores, ngram_scores)
            ]
            order = sorted(
                range(len(scores)),
                key=lambda index: (-scores[index], index),
            )
            predicted = order[0]
            records.append(
                {
                    "margin": scores[order[0]] - scores[order[1]],
                    "baseline_correct": example.label == 0,
                    "model_correct": predicted == example.label,
                    "changed": predicted != 0,
                }
            )
        hits = sum(bool(record["model_correct"]) for record in records)
        raw_changed = sum(bool(record["changed"]) for record in records)
        calibration = calibrate_change_threshold(
            [record for record in records if record["changed"]],
            target_precision=target_precision,
        )
        net_gain = calibration["wins"] - calibration["losses"]
        weight_table.append(
            {
                "weight": weight,
                "raw_top1_accuracy": hits / len(records),
                "raw_changed_samples": raw_changed,
                "calibrated": calibration["changed_samples"] > 0,
                "margin_threshold": calibration["margin_threshold"],
                "wins": calibration["wins"],
                "losses": calibration["losses"],
                "changed_samples": calibration["changed_samples"],
                "precision": calibration["precision"],
                "net_gain": net_gain,
            }
        )

    calibrated_rows = [row for row in weight_table if row["calibrated"]]
    selection_pool = calibrated_rows or weight_table
    best_row = max(
        selection_pool,
        key=lambda row: (
            row["net_gain"],
            row["changed_samples"],
            row["raw_top1_accuracy"],
            -row["weight"],
        ),
    )
    weight = best_row["weight"]
    calibration = {
        "margin_threshold": best_row["margin_threshold"],
        "target_precision": target_precision,
        "changed_samples": best_row["changed_samples"],
        "wins": best_row["wins"],
        "losses": best_row["losses"],
        "precision": best_row["precision"],
    }
    seed = (
        f"v2:{dataset_sha256}:{neural_ranker.model_artifact_id}:"
        f"{ngram_ranker.dataset_sha256}:{weight:.2f}:"
        f"{calibration['margin_threshold']:.12f}:"
        f"{neural_mean:.9f}:{neural_std:.9f}:"
        f"{ngram_mean:.9f}:{ngram_std:.9f}"
    ).encode("utf-8")
    payload = {
        "schema_version": 1,
        "fusion_type": FUSION_TYPE_GLOBAL_NORM,
        "artifact_id": "rimeai-24m-fusion:" + hashlib.sha256(seed).hexdigest()[:16],
        "neural_weight": weight,
        "neural_artifact_id": neural_ranker.model_artifact_id,
        "ngram_dataset_sha256": ngram_ranker.dataset_sha256,
        "validation_dataset_sha256": dataset_sha256,
        "score_normalization": {
            "method": GLOBAL_NORM_METHOD,
            "statistic": "pooled-validation-candidate-mean-std",
            "neural_mean": neural_mean,
            "neural_std": neural_std,
            "ngram_mean": ngram_mean,
            "ngram_std": ngram_std,
        },
        "validation": {
            "samples": len(normalized),
            "baseline_top1_accuracy": (
                sum(example.label == 0 for example in validation) / len(validation)
            ),
            "raw_top1_accuracy": best_row["raw_top1_accuracy"],
            "net_gain": best_row["net_gain"],
            "changed_samples": best_row["changed_samples"],
            "wins": best_row["wins"],
            "losses": best_row["losses"],
            "precision": best_row["precision"],
            "selection_criterion": (
                "joint weight/threshold: among weights whose calibrated "
                "threshold meets target precision with wins > losses, "
                "maximize net gain (wins - losses), then calibrated "
                "changed_samples, then raw top-1 accuracy, then the lower "
                "weight; with no calibratable weight the raw top-1 "
                "tie-break decides and the threshold stays disabled"
            ),
            "weight_grid": [row["weight"] for row in weight_table],
            "weight_table": weight_table,
            "test_samples_used": 0,
        },
        "decision": calibration,
    }
    _atomic_json(output_path, payload)
    FusionConfig.load(
        output_path,
        neural_artifact_id=neural_ranker.model_artifact_id,
        ngram_dataset_sha256=ngram_ranker.dataset_sha256,
    )
    return payload


def _flatten_batch_inputs(
    examples: Sequence[RankerExample],
    guard: PinyinGuard,
) -> tuple[list[str], list[int], list[int]]:
    texts: list[str] = []
    counts: list[int] = []
    labels: list[int] = []
    for example in examples:
        counts.append(len(example.candidates))
        labels.append(example.label)
        texts.extend(
            format_ranker_input(
                context=example.context,
                pinyin=example.pinyin,
                candidate=candidate,
                baseline_index=baseline_index,
                guard=guard,
            )
            for candidate, baseline_index in zip(
                example.candidates,
                example.baseline_indices,
            )
        )
    return texts, counts, labels


def _score_examples(
    examples: Sequence[RankerExample],
    *,
    tokenizer: Any,
    model: _EncoderScorer,
    guard: PinyinGuard,
    device: Any,
    max_length: int,
    batch_size: int,
    torch: Any,
) -> list[dict[str, Any]]:
    model.eval()
    records: list[dict[str, Any]] = []
    with torch.inference_mode():
        for start in range(0, len(examples), batch_size):
            chunk = examples[start : start + batch_size]
            texts, counts, _ = _flatten_batch_inputs(chunk, guard)
            tokens = tokenizer(
                texts,
                padding=True,
                truncation=True,
                max_length=max_length,
                return_tensors="pt",
            )
            tokens = {key: value.to(device) for key, value in tokens.items()}
            flat_scores = model.score(tokens).detach().cpu().tolist()
            offset = 0
            for example, count in zip(chunk, counts):
                scores = [float(value) for value in flat_scores[offset : offset + count]]
                offset += count
                ranked_indices = sorted(
                    range(count),
                    key=lambda index: (-scores[index], index),
                )
                predicted = ranked_indices[0]
                ordered = [scores[index] for index in ranked_indices]
                records.append(
                    {
                        "sample_id": example.sample_id,
                        "baseline_correct": example.label == 0,
                        "model_correct": predicted == example.label,
                        "changed": predicted != 0,
                        "margin": ordered[0] - ordered[1],
                        "predicted": predicted,
                        "label": example.label,
                    }
                )
    return records


def _validation_summary(records: Sequence[Mapping[str, Any]]) -> dict[str, Any]:
    samples = len(records)
    changed = [record for record in records if record["changed"]]
    return {
        "samples": samples,
        "baseline_top1_accuracy": (
            sum(bool(record["baseline_correct"]) for record in records) / samples
            if samples
            else 0.0
        ),
        "raw_top1_accuracy": (
            sum(bool(record["model_correct"]) for record in records) / samples
            if samples
            else 0.0
        ),
        "changed_samples": len(changed),
        "wins": sum(
            not bool(record["baseline_correct"])
            and bool(record["model_correct"])
            for record in changed
        ),
        "losses": sum(
            bool(record["baseline_correct"])
            and not bool(record["model_correct"])
            for record in changed
        ),
    }


def _atomic_json(path: Path, payload: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        dir=path.parent,
        prefix=f".{path.name}.",
        suffix=".tmp",
    )
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as file:
            json.dump(payload, file, ensure_ascii=False, indent=2, sort_keys=True)
            file.write("\n")
            file.flush()
            os.fsync(file.fileno())
        os.replace(temporary_name, path)
    except BaseException:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass
        raise


def _artifact_files(root: Path) -> dict[str, dict[str, Any]]:
    files: dict[str, dict[str, Any]] = {}
    for path in sorted(root.rglob("*")):
        if (
            not path.is_file()
            or path.name == "manifest.json"
            or path.name.startswith("._")
        ):
            continue
        relative = str(path.relative_to(root))
        files[relative] = {
            "bytes": path.stat().st_size,
            "sha256": _sha256_path(path),
        }
    return files


def train_neural_ranker(
    samples: Sequence[Mapping[str, Any]],
    *,
    dataset_sha256: str,
    base_model_path: Path,
    base_model_revision: str,
    dictionary_path: Path,
    output_path: Path,
    epochs: int = 3,
    batch_size: int = 4,
    learning_rate: float = 2e-5,
    ambiguous_repetitions: int = 3,
    max_length: int = DEFAULT_MAX_LENGTH,
    target_precision: float = 0.90,
    device: str = "auto",
    seed: int = 20260729,
) -> dict[str, Any]:
    if epochs < 1 or batch_size < 1 or ambiguous_repetitions < 1:
        raise NeuralRankerError("training counts must be positive")
    checkpoint_path = output_path / ".checkpoint"
    checkpoint_state_path = checkpoint_path / "state.json"
    existing_entries = list(output_path.iterdir()) if output_path.exists() else []
    if existing_entries and any(
        path.name != ".checkpoint" and not path.name.startswith("._")
        for path in existing_entries
    ):
        raise NeuralRankerError("output directory must be empty or contain a training checkpoint")
    torch, _, save_file, AutoModel, AutoTokenizer = _neural_dependencies()
    random.seed(seed)
    torch.manual_seed(seed)
    if torch.backends.mps.is_available():
        torch.mps.manual_seed(seed)
    selected_device = _select_device(torch, device)
    guard = PinyinGuard.from_rime_dictionary(dictionary_path)
    training = build_ranker_examples(samples, split="train")
    validation = build_ranker_examples(samples, split="validation")
    if not training or not validation:
        raise NeuralRankerError("dataset has no covered train/validation examples")
    expanded_training = list(training)
    ambiguous = [example for example in training if example.context_ambiguous]
    for _ in range(ambiguous_repetitions - 1):
        expanded_training.extend(ambiguous)

    tokenizer = AutoTokenizer.from_pretrained(
        str(base_model_path),
        local_files_only=True,
    )
    special_tokens = build_special_tokens(guard)
    tokenizer.add_special_tokens({"additional_special_tokens": special_tokens})
    encoder = AutoModel.from_pretrained(
        str(base_model_path),
        local_files_only=True,
    )
    config = encoder.config
    if (
        config.hidden_size != EXPECTED_HIDDEN_SIZE
        or config.num_hidden_layers != EXPECTED_LAYERS
        or config.num_attention_heads != EXPECTED_ATTENTION_HEADS
    ):
        raise NeuralRankerError("base checkpoint does not match the planned 24M architecture")
    encoder.resize_token_embeddings(len(tokenizer))
    scorer = torch.nn.Linear(config.hidden_size, 1)
    model = _EncoderScorer(encoder, scorer, torch.nn.Dropout(0.1)).to(selected_device)
    start_epoch = 1
    best_accuracy = -1.0
    best_state: tuple[dict[str, Any], dict[str, Any]] | None = None
    history: list[dict[str, Any]] = []
    if checkpoint_state_path.is_file():
        try:
            checkpoint_state = json.loads(
                checkpoint_state_path.read_text(encoding="utf-8")
            )
        except (OSError, json.JSONDecodeError) as error:
            raise NeuralRankerError(
                "cannot read the neural ranker training checkpoint"
            ) from error
        if (
            checkpoint_state.get("dataset_sha256") != dataset_sha256
            or checkpoint_state.get("base_model_revision") != base_model_revision
            or checkpoint_state.get("seed") != seed
        ):
            raise NeuralRankerError("training checkpoint does not match this run")
        encoder_state_path = checkpoint_path / "encoder.safetensors"
        head_state_path = checkpoint_path / "ranker_head.safetensors"
        from safetensors.torch import load_file as load_checkpoint

        encoder.load_state_dict(load_checkpoint(str(encoder_state_path)))
        scorer.load_state_dict(load_checkpoint(str(head_state_path)))
        start_epoch = int(checkpoint_state["completed_epoch"]) + 1
        best_accuracy = float(checkpoint_state["best_accuracy"])
        history = list(checkpoint_state.get("history", []))
        best_state = (
            {key: value.detach().cpu().clone() for key, value in encoder.state_dict().items()},
            {key: value.detach().cpu().clone() for key, value in scorer.state_dict().items()},
        )
        print(
            f"neural-ranker resumed after epoch={start_epoch - 1}",
            file=sys.stderr,
            flush=True,
        )
    optimizer = torch.optim.AdamW(
        model.parameters(),
        lr=learning_rate,
        weight_decay=0.01,
    )
    total_steps = epochs * math.ceil(len(expanded_training) / batch_size)
    warmup_steps = max(1, int(total_steps * 0.1))

    def learning_rate_multiplier(step: int) -> float:
        if step < warmup_steps:
            return (step + 1) / warmup_steps
        remaining = max(0, total_steps - step)
        return remaining / max(1, total_steps - warmup_steps)

    scheduler = torch.optim.lr_scheduler.LambdaLR(
        optimizer,
        lr_lambda=learning_rate_multiplier,
    )
    global_step = 0
    for epoch in range(start_epoch, epochs + 1):
        random.Random(seed + epoch).shuffle(expanded_training)
        model.train()
        losses: list[float] = []
        for start in range(0, len(expanded_training), batch_size):
            chunk = expanded_training[start : start + batch_size]
            texts, counts, labels = _flatten_batch_inputs(chunk, guard)
            tokens = tokenizer(
                texts,
                padding=True,
                truncation=True,
                max_length=max_length,
                return_tensors="pt",
            )
            tokens = {key: value.to(selected_device) for key, value in tokens.items()}
            flat_scores = model.score(tokens)
            max_candidates = max(counts)
            score_rows = []
            offset = 0
            for count in counts:
                row = flat_scores[offset : offset + count]
                offset += count
                if count < max_candidates:
                    row = torch.cat(
                        [
                            row,
                            torch.full(
                                (max_candidates - count,),
                                -1e9,
                                device=selected_device,
                            ),
                        ]
                    )
                score_rows.append(row)
            logits = torch.stack(score_rows)
            target = torch.tensor(labels, dtype=torch.long, device=selected_device)
            loss = torch.nn.functional.cross_entropy(logits, target)
            optimizer.zero_grad(set_to_none=True)
            loss.backward()
            torch.nn.utils.clip_grad_norm_(list(model.parameters()), 1.0)
            optimizer.step()
            scheduler.step()
            global_step += 1
            losses.append(float(loss.detach().cpu()))
            del loss, logits, target, flat_scores, score_rows, tokens
            if selected_device.type == "mps" and global_step % 10 == 0:
                gc.collect()
                torch.mps.empty_cache()
            if global_step % 100 == 0:
                print(
                    "neural-ranker "
                    f"epoch={epoch}/{epochs} step={global_step}/{total_steps} "
                    f"loss={losses[-1]:.6f}",
                    file=sys.stderr,
                    flush=True,
                )
        validation_records = _score_examples(
            validation,
            tokenizer=tokenizer,
            model=model,
            guard=guard,
            device=selected_device,
            max_length=max_length,
            batch_size=batch_size,
            torch=torch,
        )
        summary = _validation_summary(validation_records)
        summary.update(
            {
                "epoch": epoch,
                "training_loss": sum(losses) / len(losses),
                "learning_rate": scheduler.get_last_lr()[0],
            }
        )
        history.append(summary)
        if selected_device.type == "mps":
            gc.collect()
            torch.mps.empty_cache()
        print(
            "neural-ranker "
            f"epoch={epoch}/{epochs} validation_top1="
            f"{summary['raw_top1_accuracy']:.6f} "
            f"baseline={summary['baseline_top1_accuracy']:.6f} "
            f"changed={summary['changed_samples']}",
            file=sys.stderr,
            flush=True,
        )
        if summary["raw_top1_accuracy"] > best_accuracy:
            best_accuracy = summary["raw_top1_accuracy"]
            best_state = (
                {
                    key: value.detach().cpu().clone()
                    for key, value in encoder.state_dict().items()
                },
                {
                    key: value.detach().cpu().clone()
                    for key, value in scorer.state_dict().items()
                },
            )
            checkpoint_path.mkdir(parents=True, exist_ok=True)
            save_file(best_state[0], str(checkpoint_path / "encoder.safetensors"))
            save_file(best_state[1], str(checkpoint_path / "ranker_head.safetensors"))
        _atomic_json(
            checkpoint_state_path,
            {
                "schema_version": 1,
                "dataset_sha256": dataset_sha256,
                "base_model_revision": base_model_revision,
                "seed": seed,
                "completed_epoch": epoch,
                "best_accuracy": best_accuracy,
                "history": history,
            },
        )
    if best_state is None:
        raise NeuralRankerError("training produced no checkpoint")
    encoder.load_state_dict(best_state[0])
    scorer.load_state_dict(best_state[1])
    model.to(selected_device)
    final_records = _score_examples(
        validation,
        tokenizer=tokenizer,
        model=model,
        guard=guard,
        device=selected_device,
        max_length=max_length,
        batch_size=batch_size,
        torch=torch,
    )
    changed_records = [record for record in final_records if record["changed"]]
    calibration = calibrate_change_threshold(
        changed_records,
        target_precision=target_precision,
    )

    output_path.mkdir(parents=True, exist_ok=True)
    encoder_path = output_path / "encoder"
    model.to(torch.device("cpu"))
    encoder.save_pretrained(str(encoder_path), safe_serialization=True)
    tokenizer.save_pretrained(str(encoder_path))
    save_file(scorer.state_dict(), str(output_path / "ranker_head.safetensors"))
    parameter_count = sum(parameter.numel() for parameter in model.parameters())
    artifact_seed = (
        f"{dataset_sha256}:{base_model_revision}:{parameter_count}:"
        f"{calibration['margin_threshold']:.12f}"
    ).encode("utf-8")
    artifact_id = "rimeai-ranker-s-24m:" + hashlib.sha256(artifact_seed).hexdigest()[:16]
    manifest: dict[str, Any] = {
        "schema_version": 1,
        "model_type": MODEL_TYPE,
        "artifact_id": artifact_id,
        "base_model": {
            "id": BASE_MODEL_ID,
            "revision": base_model_revision,
            "license": "MIT",
        },
        "architecture": {
            "hidden_size": config.hidden_size,
            "layers": config.num_hidden_layers,
            "attention_heads": config.num_attention_heads,
            "max_length": max_length,
            "parameters": parameter_count,
            "pinyin_tokens": sum(token.startswith("[PY_") for token in special_tokens),
            "candidate_markers": 1,
            "rank_markers": len(RANK_MARKERS),
        },
        "dataset_sha256": dataset_sha256,
        "training": {
            "seed": seed,
            "epochs": epochs,
            "batch_size": batch_size,
            "learning_rate": learning_rate,
            "train_examples": len(training),
            "context_ambiguous_examples": len(ambiguous),
            "expanded_train_examples": len(expanded_training),
            "validation_examples": len(validation),
            "test_samples_used": 0,
            "history": history,
        },
        "validation": _validation_summary(final_records),
        "decision": calibration,
        "files": {},
    }
    if checkpoint_path.exists():
        for checkpoint_file in checkpoint_path.iterdir():
            if checkpoint_file.is_file():
                checkpoint_file.unlink()
        checkpoint_path.rmdir()
    manifest["files"] = _artifact_files(output_path)
    _atomic_json(output_path / "manifest.json", manifest)
    NeuralRankerArtifact.load(output_path)
    return manifest
