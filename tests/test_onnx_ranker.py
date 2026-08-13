import hashlib
import json

import pytest

from rimeai_eval.onnx_ranker import OnnxRankerArtifact, _canonical_json


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
