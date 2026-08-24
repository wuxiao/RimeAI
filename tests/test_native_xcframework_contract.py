from __future__ import annotations

import hashlib
import json
import plistlib
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
CANONICAL_HEADERS = PROJECT_ROOT / "ios" / "Native" / "include"
PUBLIC_HEADERS = (
    "rime_api.h",
    "rime_api_deprecated.h",
    "rime_api_stdbool.h",
)


def test_checked_in_xcframework_slices_embed_canonical_public_headers() -> None:
    artifacts = {
        PROJECT_ROOT / "macos" / "Native" / "RimeAIMacRuntime.xcframework": {
            "macos-arm64"
        },
        PROJECT_ROOT / "ios" / "Native" / "RimeAINative.xcframework": {
            "ios-arm64",
            "ios-arm64-simulator",
        },
    }

    canonical = {
        name: (CANONICAL_HEADERS / name).read_bytes()
        for name in PUBLIC_HEADERS
    }
    assert not CANONICAL_HEADERS.is_symlink()

    for artifact, expected_slices in artifacts.items():
        assert artifact.is_dir()
        assert not artifact.is_symlink()
        with (artifact.parent / "artifact-lock.json").open(
            encoding="utf-8"
        ) as lock_file:
            artifact_lock = json.load(lock_file)
        assert artifact_lock["artifact"] == artifact.name
        locked_headers = {
            entry["path"]: entry["sha256"]
            for entry in artifact_lock["public_headers"].values()
        }
        assert set(locked_headers) == set(PUBLIC_HEADERS)
        for name, expected_bytes in canonical.items():
            assert not (CANONICAL_HEADERS / name).is_symlink()
            assert hashlib.sha256(expected_bytes).hexdigest() == locked_headers[name]

        info_plist = artifact / "Info.plist"
        assert info_plist.is_file()
        assert not info_plist.is_symlink()
        info_bytes = info_plist.read_bytes()
        assert hashlib.sha256(info_bytes).hexdigest() == artifact_lock[
            "info_plist_sha256"
        ]
        with info_plist.open("rb") as plist_file:
            metadata = plistlib.load(plist_file)

        libraries = metadata["AvailableLibraries"]
        identifiers = [entry["LibraryIdentifier"] for entry in libraries]
        assert len(identifiers) == len(set(identifiers))
        assert set(identifiers) == expected_slices

        for entry in libraries:
            slice_root = artifact / entry["LibraryIdentifier"]
            assert slice_root.is_dir()
            assert not slice_root.is_symlink()
            headers_path = entry.get("HeadersPath")
            assert headers_path == "Headers"

            headers_root = slice_root / headers_path
            assert headers_root.is_dir()
            assert not headers_root.is_symlink()
            for name, expected_bytes in canonical.items():
                header = headers_root / name
                assert header.is_file()
                assert not header.is_symlink()
                assert header.read_bytes() == expected_bytes

        if "library" in artifact_lock:
            slice_identifier = Path(artifact_lock["library"]["path"]).parts[0]
            locked_libraries = {
                slice_identifier: artifact_lock["library"]
            }
        else:
            locked_libraries = artifact_lock["libraries"]
        assert set(locked_libraries) == expected_slices
        for identifier, library_lock in locked_libraries.items():
            library = artifact / library_lock["path"]
            assert library.parent == artifact / identifier
            assert library.is_file()
            assert not library.is_symlink()
            library_bytes = library.read_bytes()
            assert len(library_bytes) == library_lock["size_bytes"]
            assert (
                hashlib.sha256(library_bytes).hexdigest()
                == library_lock["sha256"]
            )
