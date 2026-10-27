import hashlib
import json
import math
from types import SimpleNamespace

import pytest

from rimeai_eval.onnx_ranker import OnnxRankerArtifact, _canonical_json
from rimeai_runtime.onnx_ranker import OnnxNeuralListwiseRanker


def _write_artifact(root):
    root.mkdir()
    (root / "model.int8.onnx").write_bytes(b"onnx-model")
    (root / "tokenizer.json").write_text("{}", encoding="utf-8")
    files = {}
    for name in ("model.int8.onnx", "tokenizer.json"):
        content = (root / name).read_bytes()
        files[name] = {
            "bytes": len(content),
            "sha256": hashlib.sha256(content).hexdigest(),
        }
    manifest = {
        "schema_version": 1,
        "model_type": "rimeai-pinyin-listwise-cross-encoder-onnx",
        "source_model_type": "rimeai-pinyin-listwise-cross-encoder",
        "source_artifact_id": "rimeai-ranker-s-24m:test",
        "source_manifest_sha256": "a" * 64,
        "architecture": {
            "attention_heads": 8,
            "candidate_markers": 1,
            "hidden_size": 512,
            "layers": 4,
            "max_length": 128,
            "parameters": 24_176_129,
            "pinyin_tokens": 420,
            "rank_markers": 10,
        },
        "decision": {"margin_threshold": 0.5, "target_precision": 0.9},
        "runtime": {
            "format": "onnx",
            "opset": 17,
            "quantization": "dynamic-int8",
        },
        "files": files,
    }
    manifest["artifact_id"] = "rimeai-ranker-s-24m-onnx:" + hashlib.sha256(
        _canonical_json(manifest)
    ).hexdigest()[:16]
    (root / "manifest.json").write_text(
        json.dumps(manifest), encoding="utf-8"
    )
    return manifest


def test_onnx_artifact_verifies_identity_and_exact_runtime_files(tmp_path):
    root = tmp_path / "ranker"
    expected = _write_artifact(root)

    artifact = OnnxRankerArtifact.load(root)

    assert artifact.artifact_id == expected["artifact_id"]
    assert artifact.source_artifact_id == "rimeai-ranker-s-24m:test"
    assert artifact.max_length == 128


def test_onnx_artifact_rejects_tampered_model(tmp_path):
    root = tmp_path / "ranker"
    _write_artifact(root)
    (root / "model.int8.onnx").write_bytes(b"tampered")

    with pytest.raises(ValueError, match="does not match manifest"):
        OnnxRankerArtifact.load(root)


@pytest.mark.parametrize(
    ("mutation", "message"),
    [
        (lambda manifest: manifest["files"].update({"../escape": {}}), "inventory"),
        (
            lambda manifest: manifest["architecture"].update({"hidden_size": 256}),
            "architecture",
        ),
        (
            lambda manifest: manifest["decision"].update(
                {"margin_threshold": float("nan")}
            ),
            "decision policy",
        ),
    ],
)
def test_onnx_artifact_rejects_invalid_contract(tmp_path, mutation, message):
    root = tmp_path / "ranker"
    manifest = _write_artifact(root)
    mutation(manifest)
    manifest.pop("artifact_id")
    manifest["artifact_id"] = "rimeai-ranker-s-24m-onnx:" + hashlib.sha256(
        _canonical_json(manifest)
    ).hexdigest()[:16]
    (root / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")

    with pytest.raises(ValueError, match=message):
        OnnxRankerArtifact.load(root)


class _PatchedOnnxRanker(OnnxNeuralListwiseRanker):
    """绕开 onnxruntime/模型加载：固定 _scores，仅驱动门语义。"""

    def __init__(self, scores, *, margin_threshold=0.3, target_precision=0.9):
        self.artifact = SimpleNamespace(
            margin_threshold=margin_threshold,
            target_precision=target_precision,
            rank_markers=10,  # B-F6: rerank_window 从制品契约取
        )
        self._fixed_scores = list(scores)
        self.attempt_latencies_ms = []
        self.attempted_samples = 0
        self.successful_samples = 0

    def _scores(self, **kwargs):
        return list(self._fixed_scores)


@pytest.mark.parametrize("ratio", [0.0001, 0.13, 0.5, 0.9, 0.999])
def test_onnx_below_threshold_flip_maps_under_daemon_gate(ratio):
    # reveal B-F1：calibrated threshold 即放行门。Release 路径与训练侧
    # NeuralListwiseRanker / HybridSemanticRanker 同款语义——
    # margin ∈ [0.1253τ, τ) 的翻转（旧公式以 0.55~0.899 放行）现在必须
    # 落在 below_confidence（confidence < 0.55）；ratio→0 同时覆盖
    # max(0, margin/τ) 的 clamp 面（margin<0 结构性不可出现，防御保留）。
    threshold = 0.3
    ranker = _PatchedOnnxRanker(
        [1.0, 1.0 + ratio * threshold], margin_threshold=threshold
    )

    ranking, confidence = ranker.rank_candidates(
        context="上下文", pinyin="mingling", candidates=["明令", "命令"]
    )

    assert ranking == ["命令", "明令"]
    assert confidence == pytest.approx(0.55 * ratio)
    assert confidence < 0.55
    if ratio >= 0.05 / 0.399:  # 旧口径越过 0.55 门的临界 ≈ 0.1253
        assert min(0.899, 0.5 + 0.399 * ratio) >= 0.55


@pytest.mark.parametrize("excess", [0.0, 0.15])
def test_onnx_at_or_above_threshold_flip_still_admitted(excess):
    threshold = 0.3
    ranker = _PatchedOnnxRanker(
        [1.0, 1.0 + threshold + excess], margin_threshold=threshold
    )

    ranking, confidence = ranker.rank_candidates(
        context="上下文", pinyin="mingling", candidates=["明令", "命令"]
    )

    assert ranking == ["命令", "明令"]
    assert confidence == pytest.approx(0.9 + 0.1 * (1.0 - math.exp(-excess)))
    assert confidence >= 0.55


def test_onnx_same_top_keeps_full_confidence():
    ranker = _PatchedOnnxRanker([2.0, 1.0])

    ranking, confidence = ranker.rank_candidates(
        context="上下文", pinyin="mingling", candidates=["明令", "命令"]
    )

    assert ranking == ["明令", "命令"]
    assert confidence == 1.0


def test_onnx_rerank_window_comes_from_artifact(tmp_path):
    # B-F6：重排窗口是制品字段（architecture.rank_markers，加载时
    # 经 EXPECTED_ARCHITECTURE 逐字段校验），不是运行时硬编码。
    from rimeai_runtime.onnx_ranker import OnnxRankerArtifact as RuntimeArtifact

    root = tmp_path / "ranker"
    _write_artifact(root)

    artifact = RuntimeArtifact.load(root)

    assert artifact.rank_markers == 10

    ranker = _PatchedOnnxRanker([2.0, 1.0])
    assert ranker.rerank_window == 10


def test_onnx_window_tail_keeps_original_order():
    # 窗口外候选原样拼接：ONNX 会话只对窗口内 eligible 打分，
    # 尾巴不参与重排也不丢失。
    scores = [float(index) for index in range(10)]
    ranker = _PatchedOnnxRanker(scores)
    candidates = [f"候选{index:02d}" for index in range(12)]

    ranking, _confidence = ranker.rank_candidates(
        context="上下文", pinyin="houxuan", candidates=candidates
    )

    assert ranking[10:] == candidates[10:]
    assert sorted(ranking[:10]) == sorted(candidates[:10])
    assert ranking[0] == candidates[9]
