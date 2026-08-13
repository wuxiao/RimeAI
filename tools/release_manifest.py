#!/usr/bin/env python3
"""Create and verify deterministic manifests for self-contained releases."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import sys
from typing import Any, Dict, Iterable, List, Mapping, Sequence, Tuple


MANIFEST_NAME = "manifest.json"
CHECKSUMS_NAME = "SHA256SUMS"
EXCLUDED_FROM_MANIFEST = frozenset({MANIFEST_NAME, CHECKSUMS_NAME})


class ReleaseVerificationError(ValueError):
    """Raised when a release tree cannot be trusted."""


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _inside_root(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
    except ValueError:
        return False
    return True


def _validate_relative_path(relative_path: str) -> None:
    if not relative_path or relative_path.startswith("/"):
        raise ReleaseVerificationError("release paths must be relative")
    if any(character in relative_path for character in ("\n", "\r", "\\")):
        raise ReleaseVerificationError(
            "release paths cannot contain newlines or backslashes"
        )
    if any(part in {"", ".", ".."} for part in relative_path.split("/")):
        raise ReleaseVerificationError("release path is not normalized")


def _iter_tree(root: Path) -> Iterable[Tuple[str, Path]]:
    def walk(directory: Path, relative_directory: Path) -> Iterable[Tuple[str, Path]]:
        with os.scandir(directory) as entries:
            ordered_entries = sorted(entries, key=lambda entry: entry.name)
        for entry in ordered_entries:
            if entry.name.startswith("._") or entry.name == ".DS_Store":
                raise ReleaseVerificationError(
                    "macOS metadata is forbidden in releases: %s" % entry.name
                )
            relative = relative_directory / entry.name
            relative_string = relative.as_posix()
            _validate_relative_path(relative_string)
            entry_path = directory / entry.name
            if entry.is_symlink():
                yield relative_string, entry_path
            elif entry.is_dir(follow_symlinks=False):
                yield from walk(entry_path, relative)
            else:
                yield relative_string, entry_path

    yield from walk(root, Path())


def collect_release_entries(root: Path) -> List[Dict[str, Any]]:
    resolved_root = root.resolve(strict=True)
    if root.is_symlink() or not resolved_root.is_dir():
        raise ReleaseVerificationError("release root must be a real directory")

    records: List[Dict[str, Any]] = []
    for relative_path, entry_path in _iter_tree(resolved_root):
        if relative_path in EXCLUDED_FROM_MANIFEST:
            continue
        entry_stat = entry_path.lstat()
        mode = "%04o" % stat.S_IMODE(entry_stat.st_mode)
        if stat.S_ISLNK(entry_stat.st_mode):
            target = os.readlink(entry_path)
            if os.path.isabs(target):
                raise ReleaseVerificationError(
                    "absolute symlink is forbidden: %s" % relative_path
                )
            resolved_target = entry_path.resolve(strict=False)
            if not _inside_root(resolved_target, resolved_root):
                raise ReleaseVerificationError(
                    "symlink escapes the release: %s" % relative_path
                )
            if not resolved_target.exists():
                raise ReleaseVerificationError(
                    "dangling symlink is forbidden: %s" % relative_path
                )
            records.append(
                {
                    "kind": "symlink",
                    "mode": mode,
                    "path": relative_path,
                    "target": target,
                }
            )
        elif stat.S_ISREG(entry_stat.st_mode):
            records.append(
                {
                    "bytes": entry_stat.st_size,
                    "kind": "file",
                    "mode": mode,
                    "path": relative_path,
                    "sha256": _sha256(entry_path),
                }
            )
        else:
            raise ReleaseVerificationError(
                "special filesystem entry is forbidden: %s" % relative_path
            )
    return records


def _canonical_json(value: Mapping[str, Any]) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")


def _read_object(path: Path) -> Dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ReleaseVerificationError("expected a JSON object: %s" % path)
    return value


def build_manifest(
    root: Path,
    *,
    version: str,
    git_commit: str,
    git_dirty: bool,
    source_date_epoch: int,
    model_manifest: Path,
    fusion_config: Path,
    beam_config: Path,
    language_model: Path,
    dictionary: Path,
    python_version: str,
    pyinstaller_version: str,
) -> Dict[str, Any]:
    neural = _read_object(model_manifest)
    fusion = _read_object(fusion_config)
    beam = _read_object(beam_config)
    payload: Dict[str, Any] = {
        "artifact_type": "rimeai-daemon-release",
        "build": {
            "packager": "PyInstaller",
            "packager_version": pyinstaller_version,
            "python_version": python_version,
            "source_date_epoch": source_date_epoch,
        },
        "files": collect_release_entries(root),
        "models": {
            "beam_config_sha256": _sha256(beam_config),
            "beam_dataset_sha256": beam.get("dataset_sha256"),
            "dictionary_sha256": _sha256(dictionary),
            "fusion_artifact_id": fusion.get("artifact_id"),
            "language_model_sha256": _sha256(language_model),
            "neural_artifact_id": neural.get(
                "source_artifact_id", neural.get("artifact_id")
            ),
            "neural_runtime_artifact_id": neural.get("artifact_id"),
            "neural_runtime": neural.get("runtime"),
            "neural_base_model": neural.get("base_model"),
        },
        "schema_version": 1,
        "source": {
            "git_commit": git_commit,
            "git_dirty": git_dirty,
        },
        "target": {
            "architecture": "arm64",
            "minimum_macos_version": "14.0",
            "platform": "macos",
        },
        "version": version,
    }
    release_digest = hashlib.sha256(_canonical_json(payload)).hexdigest()
    payload["artifact_id"] = "rimeai-daemon-release:%s" % release_digest[:16]
    return payload


def write_manifest_and_checksums(root: Path, manifest: Mapping[str, Any]) -> None:
    manifest_path = root / MANIFEST_NAME
    checksums_path = root / CHECKSUMS_NAME
    if manifest_path.exists() or checksums_path.exists():
        raise ReleaseVerificationError(
            "refusing to overwrite an existing manifest or checksum file"
        )
    manifest_path.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )

    checksum_records = []
    for relative_path, entry_path in _iter_tree(root.resolve(strict=True)):
        if relative_path == CHECKSUMS_NAME or entry_path.is_symlink():
            continue
        if entry_path.is_file():
            checksum_records.append("%s  %s" % (_sha256(entry_path), relative_path))
    checksums_path.write_text("\n".join(checksum_records) + "\n", encoding="utf-8")


def _expected_manifest_artifact_id(manifest: Mapping[str, Any]) -> str:
    identity_payload = dict(manifest)
    identity_payload.pop("artifact_id", None)
    digest = hashlib.sha256(_canonical_json(identity_payload)).hexdigest()
    return "rimeai-daemon-release:%s" % digest[:16]


def _parse_checksums(path: Path) -> Dict[str, str]:
    records: Dict[str, str] = {}
    for line_number, raw_line in enumerate(
        path.read_text(encoding="utf-8").splitlines(), start=1
    ):
        if not raw_line:
            continue
        if len(raw_line) < 67 or raw_line[64:66] != "  ":
            raise ReleaseVerificationError(
                "invalid checksum line %d" % line_number
            )
        digest = raw_line[:64]
        relative_path = raw_line[66:]
        if any(character not in "0123456789abcdef" for character in digest):
            raise ReleaseVerificationError(
                "invalid checksum digest on line %d" % line_number
            )
        _validate_relative_path(relative_path)
        if relative_path in records:
            raise ReleaseVerificationError(
                "duplicate checksum path: %s" % relative_path
            )
        records[relative_path] = digest
    return records


def verify_release(root: Path) -> Dict[str, Any]:
    resolved_root = root.resolve(strict=True)
    manifest_path = resolved_root / MANIFEST_NAME
    checksums_path = resolved_root / CHECKSUMS_NAME
    if not manifest_path.is_file() or not checksums_path.is_file():
        raise ReleaseVerificationError("manifest.json or SHA256SUMS is missing")
    manifest = _read_object(manifest_path)
    if manifest.get("schema_version") != 1:
        raise ReleaseVerificationError("unsupported release manifest schema")
    if manifest.get("artifact_type") != "rimeai-daemon-release":
        raise ReleaseVerificationError("unexpected release artifact type")
    if manifest.get("artifact_id") != _expected_manifest_artifact_id(manifest):
        raise ReleaseVerificationError("release artifact ID does not match manifest")

    actual_entries = collect_release_entries(resolved_root)
    if manifest.get("files") != actual_entries:
        raise ReleaseVerificationError("release file inventory or content changed")

    expected_checksums = _parse_checksums(checksums_path)
    actual_checksums: Dict[str, str] = {}
    for relative_path, entry_path in _iter_tree(resolved_root):
        if relative_path == CHECKSUMS_NAME or entry_path.is_symlink():
            continue
        if entry_path.is_file():
            actual_checksums[relative_path] = _sha256(entry_path)
    if expected_checksums != actual_checksums:
        raise ReleaseVerificationError("SHA256SUMS does not match the release tree")
    return manifest


def _create_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    create_parser = subparsers.add_parser("create")
    create_parser.add_argument("--root", type=Path, required=True)
    create_parser.add_argument("--version", required=True)
    create_parser.add_argument("--git-commit", required=True)
    create_parser.add_argument("--git-dirty", choices=("true", "false"), required=True)
    create_parser.add_argument("--source-date-epoch", type=int, required=True)
    create_parser.add_argument("--model-manifest", type=Path, required=True)
    create_parser.add_argument("--fusion-config", type=Path, required=True)
    create_parser.add_argument("--beam-config", type=Path, required=True)
    create_parser.add_argument("--language-model", type=Path, required=True)
    create_parser.add_argument("--dictionary", type=Path, required=True)
    create_parser.add_argument("--python-version", required=True)
    create_parser.add_argument("--pyinstaller-version", required=True)

    verify_parser = subparsers.add_parser("verify")
    verify_parser.add_argument("--root", type=Path, required=True)
    return parser


def main(arguments: Sequence[str] = None) -> int:
    parser = _create_parser()
    options = parser.parse_args(arguments)
    try:
        if options.command == "create":
            root = options.root.resolve(strict=True)
            manifest = build_manifest(
                root,
                version=options.version,
                git_commit=options.git_commit,
                git_dirty=options.git_dirty == "true",
                source_date_epoch=options.source_date_epoch,
                model_manifest=options.model_manifest,
                fusion_config=options.fusion_config,
                beam_config=options.beam_config,
                language_model=options.language_model,
                dictionary=options.dictionary,
                python_version=options.python_version,
                pyinstaller_version=options.pyinstaller_version,
            )
            write_manifest_and_checksums(root, manifest)
        else:
            manifest = verify_release(options.root)
        print(json.dumps({"artifact_id": manifest["artifact_id"]}, sort_keys=True))
    except (OSError, ReleaseVerificationError, json.JSONDecodeError) as error:
        print("error: %s" % error, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
