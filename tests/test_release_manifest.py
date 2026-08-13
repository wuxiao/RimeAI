import json
from pathlib import Path

import pytest

from tools.release_manifest import build_manifest
from tools.release_manifest import ReleaseVerificationError
from tools.release_manifest import verify_release
from tools.release_manifest import write_manifest_and_checksums


def _write_json(path: Path, value):
    path.write_text(json.dumps(value), encoding="utf-8")


def _make_release(tmp_path: Path):
    root = tmp_path / "release"
    runtime = root / "runtime"
    models = root / "models"
    runtime.mkdir(parents=True)
    models.mkdir()
    executable = runtime / "rimeai-daemon"
    executable.write_bytes(b"frozen-daemon")
    executable.chmod(0o755)
    (runtime / "daemon-link").symlink_to("rimeai-daemon")
    language_model = models / "language-model.json.gz"
    dictionary = models / "dictionary.yaml"
    language_model.write_bytes(b"ngram")
    dictionary.write_text("dict", encoding="utf-8")
    model_manifest = models / "model-manifest.json"
    fusion_config = models / "fusion.json"
    beam_config = models / "beam.json"
    _write_json(
        model_manifest,
        {
            "artifact_id": "neural:test",
            "base_model": {"id": "base", "revision": "abc", "license": "MIT"},
        },
    )
    _write_json(fusion_config, {"artifact_id": "fusion:test"})
    _write_json(beam_config, {"dataset_sha256": "dataset"})
    manifest = build_manifest(
        root,
        version="test-v1",
        git_commit="deadbeef",
        git_dirty=False,
        source_date_epoch=123456,
        model_manifest=model_manifest,
        fusion_config=fusion_config,
        beam_config=beam_config,
        language_model=language_model,
        dictionary=dictionary,
        python_version="3.9.6",
        pyinstaller_version="6.21.0",
    )
    write_manifest_and_checksums(root, manifest)
    return root, manifest


def test_manifest_round_trip_is_deterministic(tmp_path):
    root, manifest = _make_release(tmp_path)

    verified = verify_release(root)

    assert verified == manifest
    assert verified["artifact_id"].startswith("rimeai-daemon-release:")
    assert verified["target"]["minimum_macos_version"] == "14.0"
    assert verified["models"]["neural_artifact_id"] == "neural:test"
    assert verified["models"]["neural_runtime_artifact_id"] == "neural:test"
    assert "manifest.json" in (root / "SHA256SUMS").read_text(encoding="utf-8")


def test_manifest_detects_modified_file(tmp_path):
    root, _ = _make_release(tmp_path)
    (root / "runtime" / "rimeai-daemon").write_bytes(b"tampered")

    with pytest.raises(ReleaseVerificationError, match="inventory or content"):
        verify_release(root)


def test_manifest_detects_extra_file(tmp_path):
    root, _ = _make_release(tmp_path)
    (root / "unexpected.txt").write_text("extra", encoding="utf-8")

    with pytest.raises(ReleaseVerificationError, match="inventory or content"):
        verify_release(root)


def test_manifest_rejects_symlink_that_escapes_release(tmp_path):
    root, _ = _make_release(tmp_path)
    (root / "runtime" / "daemon-link").unlink()
    (root / "runtime" / "daemon-link").symlink_to("../../../outside")

    with pytest.raises(ReleaseVerificationError, match="symlink escapes"):
        verify_release(root)
