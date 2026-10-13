"""Fail-closed intake for the frozen evaluation-only sherpa-onnx model.

This module never downloads an archive, runs a vocabulary exporter, writes a
manifest, or promotes an artifact.  Its only public operation audits one
already-downloaded frozen archive and materializes its fixed runtime payloads
inside an empty staging directory supplied by the caller.
"""

from __future__ import annotations

import ctypes
from dataclasses import dataclass
import errno
import hashlib
import os
from pathlib import Path
import stat
import sys
import tarfile
from typing import BinaryIO, Dict, Iterable, List, Optional, Set, Tuple, Union
import unicodedata


FROZEN_ARCHIVE_URL = (
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/"
    "sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20.tar.bz2"
)
FROZEN_ARCHIVE_BYTES = 511_274_346
FROZEN_ARCHIVE_SHA256 = (
    "27ffbd9ee24ad186d99acc2f6354d7992b27bcab490812510665fa8f9389c5f8"
)
FROZEN_ARCHIVE_ROOT = (
    "sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20"
)

# The zipformer archive has 17 members, 556,522,064 declared regular-file
# bytes, and a largest member of 330,083,505 bytes.  The paraformer archive
# has 13 members, about 1,103,215,837 declared bytes, and a largest member of
# 636,348,877 bytes (fp32 encoder, audited but never staged).  These ceilings
# bound decompression work before allowlist selection for both cohorts.
MAX_ARCHIVE_MEMBERS = 64
MAX_REGULAR_MEMBER_BYTES = 768 * 1024 * 1024
MAX_TOTAL_DECLARED_BYTES = 1280 * 1024 * 1024

# Source names and target paths are a single frozen cohort.  In particular,
# the archive's alternate-precision ONNX files are never selected.
FROZEN_MEMBER_TARGETS: Tuple[Tuple[str, str, int], ...] = (
    (
        f"{FROZEN_ARCHIVE_ROOT}/encoder-epoch-99-avg-1.int8.onnx",
        "model/encoder.onnx",
        192 * 1024 * 1024,
    ),
    (
        f"{FROZEN_ARCHIVE_ROOT}/decoder-epoch-99-avg-1.onnx",
        "model/decoder.onnx",
        16 * 1024 * 1024,
    ),
    (
        f"{FROZEN_ARCHIVE_ROOT}/joiner-epoch-99-avg-1.int8.onnx",
        "model/joiner.onnx",
        4 * 1024 * 1024,
    ),
    (f"{FROZEN_ARCHIVE_ROOT}/tokens.txt", "model/tokens.txt", 128 * 1024),
    (f"{FROZEN_ARCHIVE_ROOT}/bpe.model", "generator/bpe.model", 512 * 1024),
    (
        f"{FROZEN_ARCHIVE_ROOT}/bpe.vocab",
        "generator/archive-bpe.vocab",
        64 * 1024,
    ),
)

_COPY_CHUNK_BYTES = 1024 * 1024


@dataclass(frozen=True)
class FrozenCohort:
    """One pinned archive: identity, root member and staged member list."""

    archive_url: str
    archive_bytes: int
    archive_sha256: str
    archive_root: str
    member_targets: Tuple[Tuple[str, str, int], ...]


# Frozen from the official asr-models release (archive SHA-256 above) on
# 2026-10-13.  The staged combination follows the upstream real-time example:
# int8 encoder + int8 decoder + tokens; the fp32 files stay audited-only.
# Upstream model card:
# https://k2-fsa.github.io/sherpa/onnx/pretrained_models/online-paraformer/paraformer-models.html
FROZEN_PARAFORMER_COHORT = FrozenCohort(
    archive_url=(
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/"
        "sherpa-onnx-streaming-paraformer-bilingual-zh-en.tar.bz2"
    ),
    archive_bytes=1_047_319_737,
    archive_sha256=(
        "5462a1fce42693deae572af1e8c4687124b12aa85fe61ff4d3168bb5280e205f"
    ),
    archive_root="sherpa-onnx-streaming-paraformer-bilingual-zh-en",
    member_targets=(
        (
            "sherpa-onnx-streaming-paraformer-bilingual-zh-en/encoder.int8.onnx",
            "model/encoder.onnx",
            192 * 1024 * 1024,
        ),
        (
            "sherpa-onnx-streaming-paraformer-bilingual-zh-en/decoder.int8.onnx",
            "model/decoder.onnx",
            96 * 1024 * 1024,
        ),
        (
            "sherpa-onnx-streaming-paraformer-bilingual-zh-en/tokens.txt",
            "model/tokens.txt",
            128 * 1024,
        ),
    ),
)


def frozen_cohort(name: str) -> FrozenCohort:
    if name == "zipformer-bilingual-zh-en":
        # Read the module constants at call time so audited callers (and
        # tests) that pin them per-run keep controlling the freeze.
        return FrozenCohort(
            archive_url=FROZEN_ARCHIVE_URL,
            archive_bytes=FROZEN_ARCHIVE_BYTES,
            archive_sha256=FROZEN_ARCHIVE_SHA256,
            archive_root=FROZEN_ARCHIVE_ROOT,
            member_targets=FROZEN_MEMBER_TARGETS,
        )
    if name == "paraformer-bilingual-zh-en":
        return FROZEN_PARAFORMER_COHORT
    raise ValueError(f"unknown frozen cohort: {name}")


class VoiceArtifactIntakeError(ValueError):
    """The frozen archive or caller-owned staging boundary is invalid."""


@dataclass(frozen=True)
class VoiceArtifactIntakeResult:
    archive_sha256: str
    extracted_files: Tuple[str, ...]
    extracted_bytes: int


@dataclass(frozen=True)
class _ArchiveIdentity:
    device: int
    inode: int
    size: int
    modified_ns: int
    changed_ns: int


@dataclass
class _CreatedDirectory:
    name: str
    device: Optional[int] = None
    inode: Optional[int] = None


@dataclass
class _CreatedFile:
    parent_name: str
    name: str
    expected_size: int
    device: Optional[int] = None
    inode: Optional[int] = None
    modified_ns: Optional[int] = None
    changed_ns: Optional[int] = None


def materialize_frozen_voice_evaluation_artifact(
    archive_path: Union[str, Path],
    staging_root: Union[str, Path],
    cohort_name: str = "zipformer-bilingual-zh-en",
) -> VoiceArtifactIntakeResult:
    """Audit and stage the fixed evaluation cohort without promoting it."""

    cohort = frozen_cohort(cohort_name)
    archive = Path(archive_path)
    staging = Path(staging_root)
    root_fd = _open_empty_staging_root(staging)
    archive_fd = -1
    created_directories = []  # type: List[_CreatedDirectory]
    created_files = []  # type: List[_CreatedFile]
    try:
        archive_fd, archive_identity = _open_and_verify_archive(archive, cohort)
        extracted_bytes = _stream_audit_and_materialize(
            archive_fd,
            root_fd,
            created_directories,
            created_files,
            cohort,
        )
        _verify_materialized_tree(
            root_fd, created_directories, created_files, cohort
        )
        os.fsync(root_fd)
        _verify_archive_unchanged(archive_fd, archive_identity, cohort)
        # The second archive hash is intentionally long.  Recheck the staged
        # names after it so a same-UID path swap cannot silently become the
        # returned cohort.
        _verify_materialized_tree(
            root_fd, created_directories, created_files, cohort
        )
        return VoiceArtifactIntakeResult(
            archive_sha256=cohort.archive_sha256,
            extracted_files=tuple(
                target for _, target, _ in cohort.member_targets
            ),
            extracted_bytes=extracted_bytes,
        )
    except Exception as error:
        try:
            _cleanup_created_entries(root_fd, created_files, created_directories)
        except Exception as cleanup_error:
            raise VoiceArtifactIntakeError(
                "voice artifact intake failed and staging cleanup could not be confirmed"
            ) from cleanup_error
        if isinstance(error, VoiceArtifactIntakeError):
            raise
        raise VoiceArtifactIntakeError("voice artifact intake failed") from error
    finally:
        if archive_fd >= 0:
            os.close(archive_fd)
        os.close(root_fd)


def _open_empty_staging_root(path: Path) -> int:
    flags = (
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_CLOEXEC", 0)
    )
    try:
        root_fd = _open_absolute_path_without_symlinks(path, flags)
    except OSError as error:
        raise VoiceArtifactIntakeError("staging root is not a safe directory") from error

    try:
        metadata = os.fstat(root_fd)
        if not stat.S_ISDIR(metadata.st_mode):
            raise VoiceArtifactIntakeError("staging root is not a directory")
        if metadata.st_uid != os.geteuid():
            raise VoiceArtifactIntakeError("staging root has the wrong owner")
        if stat.S_IMODE(metadata.st_mode) != 0o700:
            raise VoiceArtifactIntakeError("staging root mode must be 0700")
        _validate_no_extended_acl(root_fd, "staging root")
        if os.listdir(root_fd):
            raise VoiceArtifactIntakeError("staging root must be empty")
        return root_fd
    except Exception:
        os.close(root_fd)
        raise


def _open_and_verify_archive(
    path: Path,
    cohort: FrozenCohort,
) -> Tuple[int, _ArchiveIdentity]:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    try:
        archive_fd = _open_absolute_path_without_symlinks(path, flags)
    except OSError as error:
        raise VoiceArtifactIntakeError("archive cannot be opened safely") from error

    try:
        metadata = os.fstat(archive_fd)
        _validate_archive_metadata(archive_fd, metadata, cohort)
        identity = _archive_identity(metadata)
        if _hash_file_descriptor(archive_fd) != cohort.archive_sha256:
            raise VoiceArtifactIntakeError("archive SHA-256 does not match the freeze")
        if _archive_identity(os.fstat(archive_fd)) != identity:
            raise VoiceArtifactIntakeError("archive changed during initial verification")
        os.lseek(archive_fd, 0, os.SEEK_SET)
        return archive_fd, identity
    except Exception:
        os.close(archive_fd)
        raise


def _validate_archive_metadata(
    file_descriptor: int,
    metadata: os.stat_result,
    cohort: FrozenCohort,
) -> None:
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
        raise VoiceArtifactIntakeError("archive must be a singly linked regular file")
    if metadata.st_uid != os.geteuid():
        raise VoiceArtifactIntakeError("archive has the wrong owner")
    if stat.S_IMODE(metadata.st_mode) != 0o600:
        raise VoiceArtifactIntakeError("archive mode must be 0600")
    if metadata.st_size != cohort.archive_bytes:
        raise VoiceArtifactIntakeError("archive byte count does not match the freeze")
    _validate_no_extended_acl(file_descriptor, "archive")


def _archive_identity(metadata: os.stat_result) -> _ArchiveIdentity:
    return _ArchiveIdentity(
        device=metadata.st_dev,
        inode=metadata.st_ino,
        size=metadata.st_size,
        modified_ns=metadata.st_mtime_ns,
        changed_ns=metadata.st_ctime_ns,
    )


def _hash_file_descriptor(file_descriptor: int) -> str:
    os.lseek(file_descriptor, 0, os.SEEK_SET)
    digest = hashlib.sha256()
    while True:
        chunk = os.read(file_descriptor, _COPY_CHUNK_BYTES)
        if not chunk:
            return digest.hexdigest()
        digest.update(chunk)


def _verify_archive_unchanged(
    file_descriptor: int,
    expected: _ArchiveIdentity,
    cohort: FrozenCohort,
) -> None:
    before = os.fstat(file_descriptor)
    _validate_archive_metadata(file_descriptor, before, cohort)
    if _archive_identity(before) != expected:
        raise VoiceArtifactIntakeError("archive identity changed during intake")
    if _hash_file_descriptor(file_descriptor) != cohort.archive_sha256:
        raise VoiceArtifactIntakeError("archive SHA-256 changed during intake")
    after = os.fstat(file_descriptor)
    _validate_archive_metadata(file_descriptor, after, cohort)
    if _archive_identity(after) != expected:
        raise VoiceArtifactIntakeError("archive changed during final verification")


def _open_absolute_path_without_symlinks(path: Path, leaf_flags: int) -> int:
    nofollow = getattr(os, "O_NOFOLLOW", 0)
    directory = getattr(os, "O_DIRECTORY", 0)
    cloexec = getattr(os, "O_CLOEXEC", 0)
    if not nofollow or not directory:
        raise VoiceArtifactIntakeError("safe openat flags are unavailable")

    parts = path.parts
    if len(parts) < 2 or parts[0] != "/":
        raise VoiceArtifactIntakeError("intake paths must be absolute")
    for component in parts[1:]:
        if (
            component in ("", ".", "..")
            or component != unicodedata.normalize("NFC", component)
            or "/" in component
            or "\x00" in component
        ):
            raise VoiceArtifactIntakeError("intake path is not canonical")

    current_fd = os.open("/", os.O_RDONLY | directory | cloexec | nofollow)
    try:
        for component in parts[1:-1]:
            next_fd = os.open(
                component,
                os.O_RDONLY | directory | cloexec | nofollow,
                dir_fd=current_fd,
            )
            os.close(current_fd)
            current_fd = next_fd
        return os.open(
            parts[-1],
            leaf_flags | cloexec | nofollow,
            dir_fd=current_fd,
        )
    finally:
        os.close(current_fd)


def _cohort_output_directories(cohort: FrozenCohort) -> Tuple[str, ...]:
    return tuple(
        sorted({target.split("/", 1)[0] for _, target, _ in cohort.member_targets})
    )


def _stream_audit_and_materialize(
    archive_fd: int,
    root_fd: int,
    created_directories: List[_CreatedDirectory],
    created_files: List[_CreatedFile],
    cohort: FrozenCohort,
) -> int:
    output_directories = _cohort_output_directories(cohort)
    directory_fds = _create_output_directories(
        root_fd, created_directories, output_directories
    )
    target_by_source = {
        source: (target, size_ceiling)
        for source, target, size_ceiling in cohort.member_targets
    }
    seen_names = set()  # type: Set[str]
    staged_sources = set()  # type: Set[str]
    member_count = 0
    total_declared_bytes = 0
    extracted_bytes = 0
    saw_root_directory = False
    try:
        os.lseek(archive_fd, 0, os.SEEK_SET)
        with os.fdopen(os.dup(archive_fd), "rb", closefd=True) as archive_file:
            with tarfile.open(fileobj=archive_file, mode="r|bz2") as tar:
                if tar.pax_headers:
                    raise VoiceArtifactIntakeError(
                        "archive contains forbidden global PAX headers"
                    )
                for member in tar:
                    member_count += 1
                    if member_count > MAX_ARCHIVE_MEMBERS:
                        raise VoiceArtifactIntakeError(
                            "archive exceeds the member-count ceiling"
                        )
                    _audit_stream_member(member, seen_names, cohort.archive_root)
                    if tar.pax_headers:
                        raise VoiceArtifactIntakeError(
                            "archive contains forbidden global PAX headers"
                        )

                    if member.type in (tarfile.REGTYPE, tarfile.AREGTYPE):
                        total_declared_bytes += member.size
                        if total_declared_bytes > MAX_TOTAL_DECLARED_BYTES:
                            raise VoiceArtifactIntakeError(
                                "archive exceeds the total declared-byte ceiling"
                            )
                    elif member.name == cohort.archive_root:
                        saw_root_directory = True

                    target_specification = target_by_source.get(member.name)
                    if target_specification is None:
                        continue
                    target, size_ceiling = target_specification
                    if member.type not in (tarfile.REGTYPE, tarfile.AREGTYPE):
                        raise VoiceArtifactIntakeError(
                            "frozen cohort member is not a regular file"
                        )
                    if member.size <= 0 or member.size > size_ceiling:
                        raise VoiceArtifactIntakeError(
                            "frozen cohort member exceeds its size ceiling"
                        )
                    source_file = tar.extractfile(member)
                    if source_file is None:
                        raise VoiceArtifactIntakeError(
                            "frozen cohort payload cannot be read"
                        )
                    parent, filename = target.split("/", 1)
                    try:
                        extracted_bytes += _copy_member_to_new_file(
                            source_file,
                            member.size,
                            size_ceiling,
                            directory_fds[parent],
                            parent,
                            filename,
                            created_files,
                        )
                    finally:
                        source_file.close()
                    staged_sources.add(member.name)

                if tar.pax_headers:
                    raise VoiceArtifactIntakeError(
                        "archive contains forbidden global PAX headers"
                    )

        expected_sources = set(target_by_source)
        if staged_sources != expected_sources or not saw_root_directory:
            raise VoiceArtifactIntakeError(
                "archive is missing a frozen cohort member or root directory"
            )
        for directory_fd in directory_fds.values():
            os.fsync(directory_fd)
        return extracted_bytes
    finally:
        for directory_fd in directory_fds.values():
            os.close(directory_fd)


def _audit_stream_member(
    member: tarfile.TarInfo,
    seen_names: Set[str],
    archive_root: str,
) -> None:
    _validate_member_name(member.name, archive_root)
    if member.name in seen_names:
        raise VoiceArtifactIntakeError("archive contains a duplicate member name")
    seen_names.add(member.name)
    if member.pax_headers:
        raise VoiceArtifactIntakeError("archive contains forbidden PAX headers")
    if getattr(member, "sparse", None) is not None:
        raise VoiceArtifactIntakeError("archive contains a sparse member")
    if member.type not in (tarfile.REGTYPE, tarfile.AREGTYPE, tarfile.DIRTYPE):
        raise VoiceArtifactIntakeError("archive contains a forbidden member type")
    if member.linkname:
        raise VoiceArtifactIntakeError("archive member has forbidden link metadata")
    if member.size < 0:
        raise VoiceArtifactIntakeError("archive member has a negative size")
    if member.type == tarfile.DIRTYPE:
        if member.size != 0:
            raise VoiceArtifactIntakeError("archive directory has a nonzero size")
        return
    if member.size > MAX_REGULAR_MEMBER_BYTES:
        raise VoiceArtifactIntakeError("archive member exceeds its size ceiling")


def _validate_member_name(name: str, archive_root: str) -> None:
    if not name or name.startswith("/") or "\\" in name:
        raise VoiceArtifactIntakeError("archive member path is not canonical")
    if name != unicodedata.normalize("NFC", name):
        raise VoiceArtifactIntakeError("archive member path is not NFC")
    try:
        encoded = name.encode("utf-8", errors="strict")
    except UnicodeError as error:
        raise VoiceArtifactIntakeError("archive member path is not UTF-8") from error
    if len(encoded) > 1024:
        raise VoiceArtifactIntakeError("archive member path is too long")
    if any(unicodedata.category(character).startswith("C") for character in name):
        raise VoiceArtifactIntakeError("archive member path contains a control character")

    components = name.split("/")
    if any(
        component in ("", ".", "..")
        or len(component.encode("utf-8")) > 255
        for component in components
    ):
        raise VoiceArtifactIntakeError("archive member path has an unsafe component")
    if len(components) > 16:
        raise VoiceArtifactIntakeError("archive member path is too deep")
    if components[0] != archive_root:
        raise VoiceArtifactIntakeError("archive member is outside the frozen root")


def _create_output_directories(
    root_fd: int,
    created: List[_CreatedDirectory],
    output_directories: Tuple[str, ...],
) -> Dict[str, int]:
    directory_fds = {}  # type: Dict[str, int]
    flags = (
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    try:
        for name in output_directories:
            record = _CreatedDirectory(name=name)
            created.append(record)
            os.mkdir(name, mode=0o700, dir_fd=root_fd)
            directory_fd = os.open(name, flags, dir_fd=root_fd)
            directory_fds[name] = directory_fd
            os.fchmod(directory_fd, 0o700)
            metadata = os.fstat(directory_fd)
            record.device = metadata.st_dev
            record.inode = metadata.st_ino
            if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.geteuid():
                raise VoiceArtifactIntakeError("created output directory is unsafe")
            if stat.S_IMODE(metadata.st_mode) != 0o700:
                raise VoiceArtifactIntakeError("created output directory mode is unsafe")
            _validate_no_extended_acl(directory_fd, "created output directory")
        return directory_fds
    except Exception:
        for directory_fd in directory_fds.values():
            os.close(directory_fd)
        raise


def _copy_member_to_new_file(
    source: BinaryIO,
    expected_size: int,
    size_ceiling: int,
    parent_fd: int,
    parent_name: str,
    filename: str,
    created: List[_CreatedFile],
) -> int:
    flags = (
        os.O_WRONLY
        | os.O_CREAT
        | os.O_EXCL
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    record = _CreatedFile(
        parent_name=parent_name,
        name=filename,
        expected_size=expected_size,
    )
    created.append(record)
    output_fd = os.open(filename, flags, 0o600, dir_fd=parent_fd)
    written = 0
    try:
        opened = os.fstat(output_fd)
        record.device = opened.st_dev
        record.inode = opened.st_ino
        os.fchmod(output_fd, 0o600)
        while written < expected_size:
            chunk = source.read(min(_COPY_CHUNK_BYTES, expected_size - written))
            if not chunk:
                raise VoiceArtifactIntakeError("frozen cohort payload ended early")
            written += len(chunk)
            if written > size_ceiling:
                raise VoiceArtifactIntakeError("frozen cohort payload exceeds its ceiling")
            view = memoryview(chunk)
            while view:
                consumed = os.write(output_fd, view)
                if consumed <= 0:
                    raise VoiceArtifactIntakeError("frozen cohort payload write failed")
                view = view[consumed:]
        if source.read(1):
            raise VoiceArtifactIntakeError("frozen cohort payload exceeds its header size")
        os.fsync(output_fd)
        metadata = os.fstat(output_fd)
        if not stat.S_ISREG(metadata.st_mode):
            raise VoiceArtifactIntakeError("created output is not a regular file")
        if metadata.st_uid != os.geteuid() or metadata.st_nlink != 1:
            raise VoiceArtifactIntakeError("created output ownership is unsafe")
        if stat.S_IMODE(metadata.st_mode) != 0o600 or metadata.st_size != expected_size:
            raise VoiceArtifactIntakeError("created output metadata is unsafe")
        _validate_no_extended_acl(output_fd, "created output")
        record.modified_ns = metadata.st_mtime_ns
        record.changed_ns = metadata.st_ctime_ns
        return written
    finally:
        os.close(output_fd)


def _verify_materialized_tree(
    root_fd: int,
    created_directories: Iterable[_CreatedDirectory],
    created_files: Iterable[_CreatedFile],
    cohort: FrozenCohort,
) -> None:
    output_directories = _cohort_output_directories(cohort)
    directories = tuple(created_directories)
    files = tuple(created_files)
    if set(os.listdir(root_fd)) != set(output_directories):
        raise VoiceArtifactIntakeError("staging root contains an unexpected entry")
    directory_by_name = {record.name: record for record in directories}
    if set(directory_by_name) != set(output_directories):
        raise VoiceArtifactIntakeError("staging directory inventory is incomplete")

    expected_by_parent = {}  # type: Dict[str, Set[str]]
    for file_record in files:
        expected_by_parent.setdefault(file_record.parent_name, set()).add(
            file_record.name
        )
    if len(files) != len(cohort.member_targets):
        raise VoiceArtifactIntakeError("staged file inventory is incomplete")

    for directory_name in output_directories:
        record = directory_by_name[directory_name]
        directory_fd = _open_relative_directory(root_fd, directory_name)
        try:
            metadata = os.fstat(directory_fd)
            if not _matches_created_identity(metadata, record.device, record.inode):
                raise VoiceArtifactIntakeError("staged directory identity changed")
            if metadata.st_uid != os.geteuid() or stat.S_IMODE(metadata.st_mode) != 0o700:
                raise VoiceArtifactIntakeError("staged directory metadata changed")
            _validate_no_extended_acl(directory_fd, "staged directory")
            expected_names = expected_by_parent.get(directory_name, set())
            if set(os.listdir(directory_fd)) != expected_names:
                raise VoiceArtifactIntakeError(
                    "staged directory contains an unexpected entry"
                )
            for file_record in files:
                if file_record.parent_name != directory_name:
                    continue
                file_fd = _open_relative_nofollow(directory_fd, file_record.name)
                try:
                    file_metadata = os.fstat(file_fd)
                    if not _matches_created_identity(
                        file_metadata,
                        file_record.device,
                        file_record.inode,
                    ):
                        raise VoiceArtifactIntakeError("staged file identity changed")
                    if (
                        not stat.S_ISREG(file_metadata.st_mode)
                        or file_metadata.st_uid != os.geteuid()
                        or file_metadata.st_nlink != 1
                        or stat.S_IMODE(file_metadata.st_mode) != 0o600
                        or file_metadata.st_size != file_record.expected_size
                        or file_metadata.st_mtime_ns != file_record.modified_ns
                        or file_metadata.st_ctime_ns != file_record.changed_ns
                    ):
                        raise VoiceArtifactIntakeError("staged file metadata changed")
                    _validate_no_extended_acl(file_fd, "staged file")
                finally:
                    os.close(file_fd)
        finally:
            os.close(directory_fd)


def _cleanup_created_entries(
    root_fd: int,
    created_files: Iterable[_CreatedFile],
    created_directories: Iterable[_CreatedDirectory],
) -> None:
    directories = tuple(created_directories)
    directory_by_name = {record.name: record for record in directories}
    uncertain = False

    for file_record in reversed(tuple(created_files)):
        directory_record = directory_by_name.get(file_record.parent_name)
        if directory_record is None:
            uncertain = True
            continue
        try:
            parent_fd = _open_relative_directory(root_fd, file_record.parent_name)
        except FileNotFoundError:
            continue
        except OSError:
            uncertain = True
            continue
        try:
            parent_metadata = os.fstat(parent_fd)
            if not _matches_created_identity(
                parent_metadata,
                directory_record.device,
                directory_record.inode,
            ):
                uncertain = True
                continue
            try:
                file_fd = _open_relative_nofollow(parent_fd, file_record.name)
            except FileNotFoundError:
                continue
            except OSError:
                uncertain = True
                continue
            try:
                file_metadata = os.fstat(file_fd)
                if not _matches_created_identity(
                    file_metadata,
                    file_record.device,
                    file_record.inode,
                ):
                    uncertain = True
                    continue
            finally:
                os.close(file_fd)
            try:
                os.unlink(file_record.name, dir_fd=parent_fd)
            except OSError:
                uncertain = True
        finally:
            os.close(parent_fd)

    for directory_record in reversed(directories):
        try:
            directory_fd = _open_relative_directory(root_fd, directory_record.name)
        except FileNotFoundError:
            continue
        except OSError:
            uncertain = True
            continue
        try:
            metadata = os.fstat(directory_fd)
            if not _matches_created_identity(
                metadata,
                directory_record.device,
                directory_record.inode,
            ):
                uncertain = True
                continue
            if os.listdir(directory_fd):
                uncertain = True
                continue
        finally:
            os.close(directory_fd)
        try:
            os.rmdir(directory_record.name, dir_fd=root_fd)
        except OSError:
            uncertain = True

    if os.listdir(root_fd):
        uncertain = True
    if uncertain:
        raise VoiceArtifactIntakeError("staging cleanup could not be confirmed")


def _open_relative_directory(parent_fd: int, name: str) -> int:
    return os.open(
        name,
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0),
        dir_fd=parent_fd,
    )


def _open_relative_nofollow(parent_fd: int, name: str) -> int:
    return os.open(
        name,
        os.O_RDONLY
        | getattr(os, "O_NONBLOCK", 0)
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0),
        dir_fd=parent_fd,
    )


def _matches_created_identity(
    metadata: os.stat_result,
    expected_device: Optional[int],
    expected_inode: Optional[int],
) -> bool:
    return (
        expected_device is not None
        and expected_inode is not None
        and metadata.st_dev == expected_device
        and metadata.st_ino == expected_inode
    )


def _validate_no_extended_acl(file_descriptor: int, label: str) -> None:
    if sys.platform != "darwin":
        raise VoiceArtifactIntakeError(
            "Darwin extended ACL verification is unavailable on this platform"
        )

    libc = ctypes.CDLL(None, use_errno=True)
    acl_get_fd_np = libc.acl_get_fd_np
    acl_get_fd_np.argtypes = (ctypes.c_int, ctypes.c_int)
    acl_get_fd_np.restype = ctypes.c_void_p
    acl_free = libc.acl_free
    acl_free.argtypes = (ctypes.c_void_p,)
    acl_free.restype = ctypes.c_int

    ctypes.set_errno(0)
    acl = acl_get_fd_np(file_descriptor, 0x00000100)
    if acl:
        free_result = acl_free(acl)
        if free_result != 0:
            raise VoiceArtifactIntakeError(f"{label} ACL could not be released")
        raise VoiceArtifactIntakeError(f"{label} has an extended ACL")
    if ctypes.get_errno() != errno.ENOENT:
        raise VoiceArtifactIntakeError(f"{label} ACL could not be verified")
