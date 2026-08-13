"""Quantized ONNX export and inference for the RimeAI 24M ranker."""

from dataclasses import dataclass
import hashlib
import json
import math
from pathlib import Path
import shutil
import tempfile
from time import perf_counter
from typing import Any, Dict, List, Mapping, Sequence, Tuple

from .candidate_policy import partition_full_length_candidates
from .evaluation import RankerError
from .neural_ranker import (
    MODEL_TYPE,
    NeuralRankerArtifact,
    NeuralRankerError,
    _load_encoder_scorer,
    format_ranker_input,
)
from .pinyin_guard import PinyinGuard


ONNX_MODEL_TYPE = "rimeai-pinyin-listwise-cross-encoder-onnx"
EXPECTED_RUNTIME_FILES = {"model.int8.onnx", "tokenizer.json"}
EXPECTED_ARCHITECTURE = {
    "attention_heads": 8,
    "candidate_markers": 1,
    "hidden_size": 512,
    "layers": 4,
    "max_length": 128,
    "parameters": 24_176_129,
    "pinyin_tokens": 420,
    "rank_markers": 10,
}


def _sha256_path(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _canonical_json(value: Mapping[str, Any]) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")


@dataclass(frozen=True)
class OnnxRankerArtifact:
    root: Path
    manifest: Dict[str, Any]

    @classmethod
    def load(cls, root: Path) -> "OnnxRankerArtifact":
        manifest_path = root / "manifest.json"
        try:
            payload = json.loads(manifest_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise NeuralRankerError(
                f"cannot read ONNX ranker manifest '{manifest_path}'"
            ) from error
        if not isinstance(payload, dict):
            raise NeuralRankerError("ONNX ranker manifest must be an object")
        identity_payload = dict(payload)
        artifact_id = identity_payload.pop("artifact_id", None)
        expected_id = "rimeai-ranker-s-24m-onnx:" + hashlib.sha256(
            _canonical_json(identity_payload)
        ).hexdigest()[:16]
        runtime = payload.get("runtime")
        decision = payload.get("decision")
        architecture = payload.get("architecture")
        files = payload.get("files")
        if (
            payload.get("schema_version") != 1
            or payload.get("model_type") != ONNX_MODEL_TYPE
            or payload.get("source_model_type") != MODEL_TYPE
            or artifact_id != expected_id
            or not isinstance(runtime, dict)
            or runtime.get("format") != "onnx"
            or runtime.get("quantization") != "dynamic-int8"
            or not isinstance(runtime.get("opset"), int)
            or runtime["opset"] < 17
            or not isinstance(decision, dict)
            or not isinstance(architecture, dict)
            or not isinstance(files, dict)
        ):
            raise NeuralRankerError("unsupported or invalid ONNX ranker artifact")
        source_artifact_id = payload.get("source_artifact_id")
        source_manifest_sha256 = payload.get("source_manifest_sha256")
        if (
            not isinstance(source_artifact_id, str)
            or not source_artifact_id.startswith("rimeai-ranker-s-24m:")
            or not isinstance(source_manifest_sha256, str)
            or len(source_manifest_sha256) != 64
            or any(
                character not in "0123456789abcdef"
                for character in source_manifest_sha256
            )
        ):
            raise NeuralRankerError("invalid ONNX source checkpoint identity")
        if any(
            architecture.get(key) != value
            for key, value in EXPECTED_ARCHITECTURE.items()
        ):
            raise NeuralRankerError("unexpected ONNX ranker architecture")
        margin_threshold = decision.get("margin_threshold")
        target_precision = decision.get("target_precision")
        if (
            isinstance(margin_threshold, bool)
            or not isinstance(margin_threshold, (int, float))
            or not math.isfinite(margin_threshold)
            or margin_threshold < 0
            or isinstance(target_precision, bool)
            or not isinstance(target_precision, (int, float))
            or not math.isfinite(target_precision)
            or not 0.5 <= target_precision <= 1.0
        ):
            raise NeuralRankerError("invalid ONNX ranker decision policy")
        if set(files) != EXPECTED_RUNTIME_FILES:
            raise NeuralRankerError("ONNX ranker file inventory is invalid")
        for relative, expected in files.items():
            if not isinstance(relative, str) or not isinstance(expected, dict):
                raise NeuralRankerError("invalid ONNX ranker file entry")
            expected_bytes = expected.get("bytes")
            expected_sha256 = expected.get("sha256")
            if (
                isinstance(expected_bytes, bool)
                or not isinstance(expected_bytes, int)
                or expected_bytes <= 0
                or not isinstance(expected_sha256, str)
                or len(expected_sha256) != 64
                or any(
                    character not in "0123456789abcdef"
                    for character in expected_sha256
                )
            ):
                raise NeuralRankerError("invalid ONNX ranker file metadata")
            path = root / relative
            if (
                not path.is_file()
                or path.stat().st_size != expected_bytes
                or _sha256_path(path) != expected_sha256
            ):
                raise NeuralRankerError(
                    f"ONNX ranker file does not match manifest: {relative}"
                )
        return cls(root=root, manifest=payload)

    @property
    def artifact_id(self) -> str:
        return str(self.manifest["artifact_id"])

    @property
    def source_artifact_id(self) -> str:
        return str(self.manifest["source_artifact_id"])

    @property
    def max_length(self) -> int:
        return int(self.manifest["architecture"]["max_length"])

    @property
    def margin_threshold(self) -> float:
        return float(self.manifest["decision"]["margin_threshold"])

    @property
    def target_precision(self) -> float:
        return float(self.manifest["decision"]["target_precision"])


def _runtime_dependencies() -> Tuple[Any, Any, Any]:
    try:
        import numpy
        import onnxruntime
        from tokenizers import Tokenizer
    except ImportError as error:
        raise NeuralRankerError(
            "ONNX ranker requires numpy, onnxruntime, and tokenizers"
        ) from error
    return numpy, onnxruntime, Tokenizer


class OnnxNeuralListwiseRanker:
    name = "rimeai-ranker-s-24m-onnx-int8"

    def __init__(self, artifact_path: Path, guard: PinyinGuard, *, device: str = "cpu"):
        if device not in {"auto", "cpu"}:
            raise NeuralRankerError("quantized ONNX ranker currently supports CPU only")
        started_at = perf_counter()
        numpy, onnxruntime, Tokenizer = _runtime_dependencies()
        self.artifact = OnnxRankerArtifact.load(artifact_path)
        self.guard = guard
        self.numpy = numpy
        self.tokenizer = Tokenizer.from_file(str(artifact_path / "tokenizer.json"))
        self.tokenizer.enable_truncation(max_length=self.artifact.max_length)
        self.tokenizer.enable_padding(pad_id=0, pad_token="[PAD]")
        options = onnxruntime.SessionOptions()
        options.execution_mode = onnxruntime.ExecutionMode.ORT_SEQUENTIAL
        options.graph_optimization_level = (
            onnxruntime.GraphOptimizationLevel.ORT_ENABLE_ALL
        )
        # Let ORT size its intra-op pool for the host. The daemon serializes
        # requests, so the model can use performance cores without competing
        # with another inference in the same process.
        options.intra_op_num_threads = 0
        options.inter_op_num_threads = 1
        options.log_severity_level = 3
        self.session = onnxruntime.InferenceSession(
            str(artifact_path / "model.int8.onnx"),
            sess_options=options,
            providers=["CPUExecutionProvider"],
        )
        input_names = {value.name for value in self.session.get_inputs()}
        if input_names != {"input_ids", "attention_mask", "token_type_ids"}:
            raise NeuralRankerError("ONNX ranker inputs do not match runtime contract")
        self._scores(
            context="",
            pinyin="shi",
            candidates=("是", "时"),
            baseline_indices=(0, 1),
        )
        # Fusion calibration belongs to the source checkpoint, while the runtime
        # artifact has its own identity for supply-chain and rollback purposes.
        self.model_artifact_id = self.artifact.source_artifact_id
        self.runtime_artifact_id = self.artifact.artifact_id
        self.cold_start_ms = (perf_counter() - started_at) * 1000
        self.attempt_latencies_ms: List[float] = []
        self.attempted_samples = 0
        self.successful_samples = 0

    def _scores(
        self,
        *,
        context: str,
        pinyin: str,
        candidates: Sequence[str],
        baseline_indices: Sequence[int],
    ) -> List[float]:
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
        encodings = self.tokenizer.encode_batch(texts)
        inputs = {
            "input_ids": self.numpy.asarray(
                [encoding.ids for encoding in encodings], dtype=self.numpy.int64
            ),
            "attention_mask": self.numpy.asarray(
                [encoding.attention_mask for encoding in encodings],
                dtype=self.numpy.int64,
            ),
            "token_type_ids": self.numpy.asarray(
                [encoding.type_ids for encoding in encodings],
                dtype=self.numpy.int64,
            ),
        }
        scores = self.session.run(["scores"], inputs)[0]
        return [float(value) for value in scores.reshape(-1).tolist()]

    def rank_candidates(
        self,
        *,
        context: str,
        pinyin: str,
        candidates: Sequence[str],
    ) -> Tuple[List[str], float]:
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
            raise RankerError("ONNX ranker inference failed") from error
        ranked_indices = sorted(
            range(len(texts)), key=lambda index: (-scores[index], index)
        )
        ranking = [texts[index] for index in ranked_indices]
        ranking.extend(candidate["text"] for candidate in preserved)
        ranking.extend(candidates[10:])
        margin = scores[ranked_indices[0]] - scores[ranked_indices[1]]
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

    def rank(self, sample: Dict[str, Any]):
        from .evaluation import Ranking

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
) -> Dict[str, Any]:
    if opset < 17:
        raise NeuralRankerError("ONNX opset must be at least 17")
    if output_path.exists():
        if not output_path.is_dir() or any(output_path.iterdir()):
            raise NeuralRankerError("ONNX output directory must be empty")
    try:
        import onnx
        from onnxruntime import __version__ as onnxruntime_version
        from onnxruntime.quantization import QuantType, quantize_dynamic
        import torch
        from tokenizers import __version__ as tokenizers_version
    except ImportError as error:
        raise NeuralRankerError(
            "ONNX export requires torch, onnx, onnxruntime, and tokenizers"
        ) from error

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
        payload: Dict[str, Any] = {
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
                "onnx_version": onnx.__version__,
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
