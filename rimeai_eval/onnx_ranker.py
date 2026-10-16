"""Quantized ONNX export for the RimeAI 24M ranker, plus the eval-side
adapter over the runtime ONNX ranker loader.

The runtime loader/inference lives in ``rimeai_runtime.onnx_ranker``
(daemon path, onnxruntime only, Python 3.9 toolchain); this module owns
the training-side export/quantization tooling and preserves the
historical evaluation contract (``RankerError``/``Ranking``) for the
evaluation harness.
"""

from __future__ import annotations

import hashlib
import json
import shutil
import tempfile
from collections.abc import Sequence
from pathlib import Path
from typing import Any

from rimeai_runtime.neural_ranker import (
    MODEL_TYPE,
    NeuralRankerArtifact,
    NeuralRankerError,
    _load_encoder_scorer,
)
from rimeai_runtime.onnx_ranker import (
    ONNX_MODEL_TYPE,
    OnnxNeuralListwiseRanker as RuntimeOnnxNeuralListwiseRanker,
    OnnxRankerArtifact,
    _canonical_json,
    _sha256_path,
)

from .evaluation import RankerError, Ranking


class OnnxNeuralListwiseRanker(RuntimeOnnxNeuralListwiseRanker):
    """Evaluation adapter: preserves the RankerError/Ranking contract."""

    def rank_candidates(
        self,
        *,
        context: str,
        pinyin: str,
        candidates: Sequence[str],
    ) -> tuple[list[str], float]:
        try:
            return super().rank_candidates(
                context=context,
                pinyin=pinyin,
                candidates=candidates,
            )
        except NeuralRankerError as error:
            raise RankerError(str(error)) from error

    def rank(self, sample: dict[str, Any]) -> Ranking:
        ranking, confidence = self.rank_candidates(
            context=sample["context"],
            pinyin=sample["pinyin"],
            candidates=sample["candidates"],
        )
        return Ranking(tuple(ranking), confidence)


def export_quantized_onnx_ranker(
    source_artifact_path: Path,
    output_path: Path,
    *,
    opset: int = 17,
) -> dict[str, Any]:
    if opset < 17:
        raise NeuralRankerError("ONNX opset must be at least 17")
    if output_path.exists() and (
        not output_path.is_dir() or any(output_path.iterdir())
    ):
        raise NeuralRankerError("ONNX output directory must be empty")
    try:
        import onnx
        import torch
        from importlib.metadata import version
        from onnxruntime.quantization import QuantType, quantize_dynamic
    except ImportError as error:
        raise NeuralRankerError(
            "ONNX export requires torch, onnx, onnxruntime, and tokenizers"
        ) from error

    onnx_version = version("onnx")
    onnxruntime_version = version("onnxruntime")
    tokenizers_version = version("tokenizers")
    source = NeuralRankerArtifact.load(source_artifact_path)
    tokenizer, scorer_model = _load_encoder_scorer(
        source_artifact_path / "encoder",
        source_artifact_path / "ranker_head.safetensors",
        device=torch.device("cpu"),
    )

    class ExportModel(torch.nn.Module):
        def __init__(self, encoder: Any, scorer: Any):
            super().__init__()
            self.encoder = encoder
            self.scorer = scorer

        def forward(self, input_ids, attention_mask, token_type_ids):
            output = self.encoder(
                input_ids=input_ids,
                attention_mask=attention_mask,
                token_type_ids=token_type_ids,
            )
            return self.scorer(output.last_hidden_state[:, 0]).squeeze(-1)

    export_model = ExportModel(scorer_model.encoder, scorer_model.scorer).eval()
    sample = tokenizer(
        [
            "[CTX] 数据库需要 [PY] [PY_suo] [PY_yin] [CAND] [RANK_1] 所以",
            "[CTX] 数据库需要 [PY] [PY_suo] [PY_yin] [CAND] [RANK_2] 索引",
        ],
        padding=True,
        return_tensors="pt",
    )
    temporary_root = Path(tempfile.mkdtemp(prefix="rimeai-onnx-export.", dir="/tmp"))
    try:
        float_model = temporary_root / "model.float.onnx"
        quantized_model = temporary_root / "model.int8.onnx"
        torch.onnx.export(
            export_model,
            (
                sample["input_ids"],
                sample["attention_mask"],
                sample["token_type_ids"],
            ),
            str(float_model),
            input_names=["input_ids", "attention_mask", "token_type_ids"],
            output_names=["scores"],
            dynamic_axes={
                "input_ids": {0: "batch", 1: "sequence"},
                "attention_mask": {0: "batch", 1: "sequence"},
                "token_type_ids": {0: "batch", 1: "sequence"},
                "scores": {0: "batch"},
            },
            do_constant_folding=True,
            opset_version=opset,
        )
        onnx.checker.check_model(str(float_model), full_check=True)
        quantize_dynamic(
            str(float_model),
            str(quantized_model),
            per_channel=True,
            reduce_range=False,
            weight_type=QuantType.QInt8,
            op_types_to_quantize=["MatMul", "Gemm"],
        )
        onnx.checker.check_model(str(quantized_model), full_check=True)

        staging = temporary_root / "artifact"
        staging.mkdir()
        shutil.copyfile(quantized_model, staging / "model.int8.onnx")
        shutil.copyfile(
            source_artifact_path / "encoder/tokenizer.json",
            staging / "tokenizer.json",
        )
        files = {
            relative: {
                "bytes": (staging / relative).stat().st_size,
                "sha256": _sha256_path(staging / relative),
            }
            for relative in ("model.int8.onnx", "tokenizer.json")
        }
        payload: dict[str, Any] = {
            "schema_version": 1,
            "model_type": ONNX_MODEL_TYPE,
            "source_model_type": MODEL_TYPE,
            "source_artifact_id": source.artifact_id,
            "source_manifest_sha256": _sha256_path(
                source_artifact_path / "manifest.json"
            ),
            "base_model": dict(source.manifest["base_model"]),
            "dataset_sha256": source.manifest["dataset_sha256"],
            "architecture": dict(source.manifest["architecture"]),
            "decision": dict(source.manifest["decision"]),
            "runtime": {
                "format": "onnx",
                "opset": opset,
                "quantization": "dynamic-int8",
                "onnx_version": onnx_version,
                "onnxruntime_version": onnxruntime_version,
                "tokenizers_version": tokenizers_version,
            },
            "files": files,
        }
        payload["artifact_id"] = "rimeai-ranker-s-24m-onnx:" + hashlib.sha256(
            _canonical_json(payload)
        ).hexdigest()[:16]
        (staging / "manifest.json").write_text(
            json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        OnnxRankerArtifact.load(staging)
        output_path.mkdir(parents=True, exist_ok=True)
        for source_file in sorted(staging.iterdir()):
            shutil.copyfile(source_file, output_path / source_file.name)
        OnnxRankerArtifact.load(output_path)
        return payload
    finally:
        shutil.rmtree(temporary_root)
