from __future__ import annotations

import hashlib
import io
import os
from pathlib import Path
import pwd
import stat
import subprocess
import tarfile

import pytest

from rimeai_eval import voice_artifact_intake


ARCHIVE_ROOT = "sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20"

REQUIRED_ARCHIVE_PAYLOADS = {
    f"{ARCHIVE_ROOT}/encoder-epoch-99-avg-1.int8.onnx": b"int8 encoder",
    f"{ARCHIVE_ROOT}/decoder-epoch-99-avg-1.onnx": b"fp32 decoder",
    f"{ARCHIVE_ROOT}/joiner-epoch-99-avg-1.int8.onnx": b"int8 joiner",
    f"{ARCHIVE_ROOT}/tokens.txt": b"<blk> 0\nhello 1\n",
    f"{ARCHIVE_ROOT}/bpe.model": b"sentencepiece model",
    f"{ARCHIVE_ROOT}/bpe.vocab": b"<blk>\t0\nhello\t-1\n",
}

EXPECTED_STAGED_PAYLOADS = {
    "model/encoder.onnx": b"int8 encoder",
    "model/decoder.onnx": b"fp32 decoder",
    "model/joiner.onnx": b"int8 joiner",
    "model/tokens.txt": b"<blk> 0\nhello 1\n",
    "generator/bpe.model": b"sentencepiece model",
    "generator/archive-bpe.vocab": b"<blk>\t0\nhello\t-1\n",
}


def test_freezes_the_official_archive_identity_and_runtime_member_allowlist() -> None:
    assert voice_artifact_intake.FROZEN_ARCHIVE_URL == (
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/"
        "sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20.tar.bz2"
    )
    assert voice_artifact_intake.FROZEN_ARCHIVE_BYTES == 511_274_346
    assert voice_artifact_intake.FROZEN_ARCHIVE_SHA256 == (
        "27ffbd9ee24ad186d99acc2f6354d7992b27bcab490812510665fa8f9389c5f8"
    )
    assert [
        (source, target)
        for source, target, _ceiling in voice_artifact_intake.FROZEN_MEMBER_TARGETS
    ] == [
        (
            f"{ARCHIVE_ROOT}/encoder-epoch-99-avg-1.int8.onnx",
            "model/encoder.onnx",
        ),
        (
            f"{ARCHIVE_ROOT}/decoder-epoch-99-avg-1.onnx",
            "model/decoder.onnx",
        ),
        (
            f"{ARCHIVE_ROOT}/joiner-epoch-99-avg-1.int8.onnx",
            "model/joiner.onnx",
        ),
        (f"{ARCHIVE_ROOT}/tokens.txt", "model/tokens.txt"),
        (f"{ARCHIVE_ROOT}/bpe.model", "generator/bpe.model"),
        (f"{ARCHIVE_ROOT}/bpe.vocab", "generator/archive-bpe.vocab"),
    ]


def _write_archive(
    path: Path,
    payloads: dict[str, bytes],
    *,
    extra_members: tuple[tarfile.TarInfo, ...] = (),
    archive_format: int = tarfile.GNU_FORMAT,
    pax_headers: dict[str, str] | None = None,
) -> None:
    with tarfile.open(
        path,
        mode="w:bz2",
        format=archive_format,
        pax_headers=pax_headers,
    ) as archive:
        root = tarfile.TarInfo(ARCHIVE_ROOT)
        root.type = tarfile.DIRTYPE
        root.mode = 0o755
        archive.addfile(root)

        for name, payload in payloads.items():
            member = tarfile.TarInfo(name)
            member.size = len(payload)
            member.mode = 0o644
            archive.addfile(member, io.BytesIO(payload))
        for member in extra_members:
            archive.addfile(member)
    path.chmod(0o600)


def _freeze_synthetic_archive(
    monkeypatch: pytest.MonkeyPatch,
    archive_path: Path,
) -> None:
    monkeypatch.setattr(
        voice_artifact_intake,
        "FROZEN_ARCHIVE_BYTES",
        archive_path.stat().st_size,
    )
    monkeypatch.setattr(
        voice_artifact_intake,
        "FROZEN_ARCHIVE_SHA256",
        hashlib.sha256(archive_path.read_bytes()).hexdigest(),
    )


def test_materializes_only_the_frozen_runtime_cohort(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    archive_path = tmp_path / "voice-model.tar.bz2"
    payloads = dict(REQUIRED_ARCHIVE_PAYLOADS)
    payloads.update(
        {
            # The official archive contains these alternate precision files. They
            # are audited as ordinary members but must never enter the cohort.
            f"{ARCHIVE_ROOT}/encoder-epoch-99-avg-1.onnx": b"wrong encoder",
            f"{ARCHIVE_ROOT}/decoder-epoch-99-avg-1.int8.onnx": b"wrong decoder",
            f"{ARCHIVE_ROOT}/joiner-epoch-99-avg-1.onnx": b"wrong joiner",
            f"{ARCHIVE_ROOT}/README.md": b"upstream notes",
        }
    )
    _write_archive(archive_path, payloads)
    _freeze_synthetic_archive(monkeypatch, archive_path)

    staging_root = tmp_path / "staging"
    staging_root.mkdir(mode=0o700)
    staging_root.chmod(0o700)

    result = voice_artifact_intake.materialize_frozen_voice_evaluation_artifact(
        archive_path,
        staging_root,
    )

    assert result.archive_sha256 == voice_artifact_intake.FROZEN_ARCHIVE_SHA256
    assert result.extracted_files == tuple(EXPECTED_STAGED_PAYLOADS)
    assert result.extracted_bytes == sum(map(len, EXPECTED_STAGED_PAYLOADS.values()))
    assert {
        path.relative_to(staging_root).as_posix()
        for path in staging_root.rglob("*")
        if path.is_file()
    } == set(EXPECTED_STAGED_PAYLOADS)
    for relative_path, expected in EXPECTED_STAGED_PAYLOADS.items():
        output = staging_root / relative_path
        assert output.read_bytes() == expected
        assert stat.S_IMODE(output.stat().st_mode) == 0o600
        assert output.stat().st_nlink == 1
    for directory in (staging_root / "model", staging_root / "generator"):
        assert stat.S_IMODE(directory.stat().st_mode) == 0o700


@pytest.mark.parametrize(
    "unsafe_name",
    [
        f"{ARCHIVE_ROOT}/../../escape",
        "/absolute",
        f"{ARCHIVE_ROOT}/cafe\N{COMBINING ACUTE ACCENT}.txt",
    ],
    ids=("traversal", "absolute", "non-nfc"),
)
def test_rejects_noncanonical_member_paths_before_writing(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    unsafe_name: str,
) -> None:
    archive_path = tmp_path / "unsafe-name.tar.bz2"
    payloads = dict(REQUIRED_ARCHIVE_PAYLOADS)
    payloads[unsafe_name] = b"must not be ignored"
    _write_archive(archive_path, payloads)
    _freeze_synthetic_archive(monkeypatch, archive_path)
    staging_root = tmp_path / "staging"
    staging_root.mkdir(mode=0o700)
    staging_root.chmod(0o700)

    with pytest.raises(voice_artifact_intake.VoiceArtifactIntakeError):
        voice_artifact_intake.materialize_frozen_voice_evaluation_artifact(
            archive_path,
            staging_root,
        )

    assert list(staging_root.iterdir()) == []


@pytest.mark.parametrize("scope", ["member", "global"])
def test_rejects_pax_extended_headers(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    scope: str,
) -> None:
    extra = tarfile.TarInfo(f"{ARCHIVE_ROOT}/pax-entry")
    extra.size = 0
    extra.pax_headers = {"comment": "must be rejected"} if scope == "member" else {}
    archive_path = tmp_path / "pax.tar.bz2"
    _write_archive(
        archive_path,
        dict(REQUIRED_ARCHIVE_PAYLOADS),
        extra_members=(extra,),
        archive_format=tarfile.PAX_FORMAT,
        pax_headers={"comment": "must be rejected"} if scope == "global" else None,
    )
    _freeze_synthetic_archive(monkeypatch, archive_path)
    staging_root = tmp_path / "staging"
    staging_root.mkdir(mode=0o700)
    staging_root.chmod(0o700)

    with pytest.raises(voice_artifact_intake.VoiceArtifactIntakeError):
        voice_artifact_intake.materialize_frozen_voice_evaluation_artifact(
            archive_path,
            staging_root,
        )

    assert list(staging_root.iterdir()) == []
    assert not (tmp_path / "escape").exists()


@pytest.mark.parametrize(
    "member_type",
    [
        tarfile.SYMTYPE,
        tarfile.LNKTYPE,
        tarfile.CHRTYPE,
        tarfile.BLKTYPE,
        tarfile.FIFOTYPE,
        tarfile.GNUTYPE_SPARSE,
        b"Z",
    ],
    ids=("symlink", "hardlink", "character-device", "block-device", "fifo", "sparse", "unknown"),
)
def test_rejects_every_non_file_non_directory_member_type(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    member_type: bytes,
) -> None:
    unsafe = tarfile.TarInfo(f"{ARCHIVE_ROOT}/unsafe-entry")
    unsafe.type = member_type
    unsafe.linkname = f"{ARCHIVE_ROOT}/tokens.txt"
    unsafe.devmajor = 1
    unsafe.devminor = 3
    archive_path = tmp_path / "unsafe-type.tar.bz2"
    _write_archive(
        archive_path,
        dict(REQUIRED_ARCHIVE_PAYLOADS),
        extra_members=(unsafe,),
    )
    _freeze_synthetic_archive(monkeypatch, archive_path)
    staging_root = tmp_path / "staging"
    staging_root.mkdir(mode=0o700)
    staging_root.chmod(0o700)

    with pytest.raises(voice_artifact_intake.VoiceArtifactIntakeError):
        voice_artifact_intake.materialize_frozen_voice_evaluation_artifact(
            archive_path,
            staging_root,
        )

    assert list(staging_root.iterdir()) == []


@pytest.mark.parametrize("symlinked_boundary", ["archive", "staging"])
def test_rejects_symlinked_intermediate_path_components(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    symlinked_boundary: str,
) -> None:
    real_parent = tmp_path / "real-parent"
    real_parent.mkdir(mode=0o700)
    archive_path = real_parent / "voice-model.tar.bz2"
    _write_archive(archive_path, dict(REQUIRED_ARCHIVE_PAYLOADS))
    _freeze_synthetic_archive(monkeypatch, archive_path)

    staging_root = real_parent / "staging"
    staging_root.mkdir(mode=0o700)
    staging_root.chmod(0o700)
    alias_parent = tmp_path / "alias-parent"
    alias_parent.symlink_to(real_parent, target_is_directory=True)

    archive_argument = (
        alias_parent / archive_path.name
        if symlinked_boundary == "archive"
        else archive_path
    )
    staging_argument = (
        alias_parent / staging_root.name
        if symlinked_boundary == "staging"
        else staging_root
    )

    with pytest.raises(voice_artifact_intake.VoiceArtifactIntakeError):
        voice_artifact_intake.materialize_frozen_voice_evaluation_artifact(
            archive_argument,
            staging_argument,
        )

    assert list(staging_root.iterdir()) == []


def test_rejects_a_staging_root_with_an_extended_acl(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    archive_path = tmp_path / "voice-model.tar.bz2"
    _write_archive(archive_path, dict(REQUIRED_ARCHIVE_PAYLOADS))
    _freeze_synthetic_archive(monkeypatch, archive_path)
    staging_root = tmp_path / "staging"
    staging_root.mkdir(mode=0o700)
    staging_root.chmod(0o700)
    subprocess.run(
        [
            "/bin/chmod",
            "+a",
            f"{pwd.getpwuid(os.geteuid()).pw_name} allow read",
            str(staging_root),
        ],
        check=True,
        capture_output=True,
        text=True,
    )

    with pytest.raises(voice_artifact_intake.VoiceArtifactIntakeError):
        voice_artifact_intake.materialize_frozen_voice_evaluation_artifact(
            archive_path,
            staging_root,
        )

    assert list(staging_root.iterdir()) == []


@pytest.mark.parametrize("budget", ["member-count", "member-bytes", "declared-bytes"])
def test_rejects_archives_outside_code_owned_expansion_budgets(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    budget: str,
) -> None:
    payloads = dict(REQUIRED_ARCHIVE_PAYLOADS)
    largest_fixture_payload = max(map(len, payloads.values()))
    payloads[f"{ARCHIVE_ROOT}/unselected.bin"] = b"x" * (
        largest_fixture_payload + 1
    )
    archive_path = tmp_path / "over-budget.tar.bz2"
    _write_archive(archive_path, payloads)
    _freeze_synthetic_archive(monkeypatch, archive_path)

    if budget == "member-count":
        monkeypatch.setattr(
            voice_artifact_intake,
            "MAX_ARCHIVE_MEMBERS",
            1 + len(REQUIRED_ARCHIVE_PAYLOADS),
        )
    elif budget == "member-bytes":
        monkeypatch.setattr(
            voice_artifact_intake,
            "MAX_REGULAR_MEMBER_BYTES",
            largest_fixture_payload,
        )
    else:
        monkeypatch.setattr(
            voice_artifact_intake,
            "MAX_TOTAL_DECLARED_BYTES",
            sum(map(len, REQUIRED_ARCHIVE_PAYLOADS.values())),
        )

    staging_root = tmp_path / "staging"
    staging_root.mkdir(mode=0o700)
    staging_root.chmod(0o700)
    with pytest.raises(voice_artifact_intake.VoiceArtifactIntakeError):
        voice_artifact_intake.materialize_frozen_voice_evaluation_artifact(
            archive_path,
            staging_root,
        )

    assert list(staging_root.iterdir()) == []


def test_rejects_archive_identity_change_after_the_initial_hash(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    archive_path = tmp_path / "voice-model.tar.bz2"
    _write_archive(archive_path, dict(REQUIRED_ARCHIVE_PAYLOADS))
    _freeze_synthetic_archive(monkeypatch, archive_path)
    staging_root = tmp_path / "staging"
    staging_root.mkdir(mode=0o700)
    staging_root.chmod(0o700)
    real_write = voice_artifact_intake.os.write
    mutated = False

    def mutate_archive_then_write(descriptor: int, data: memoryview) -> int:
        nonlocal mutated
        if not mutated:
            mutated = True
            before = archive_path.stat()
            os.utime(
                archive_path,
                ns=(before.st_atime_ns, before.st_mtime_ns + 1_000_000_000),
            )
        return real_write(descriptor, data)

    monkeypatch.setattr(voice_artifact_intake.os, "write", mutate_archive_then_write)

    with pytest.raises(voice_artifact_intake.VoiceArtifactIntakeError):
        voice_artifact_intake.materialize_frozen_voice_evaluation_artifact(
            archive_path,
            staging_root,
        )

    assert mutated
    assert list(staging_root.iterdir()) == []


def test_cleanup_preserves_a_swapped_replacement_and_reports_failure(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    forbidden_tail = tarfile.TarInfo(f"{ARCHIVE_ROOT}/forbidden-tail")
    forbidden_tail.type = tarfile.SYMTYPE
    forbidden_tail.linkname = f"{ARCHIVE_ROOT}/tokens.txt"
    archive_path = tmp_path / "tail-failure.tar.bz2"
    _write_archive(
        archive_path,
        dict(REQUIRED_ARCHIVE_PAYLOADS),
        extra_members=(forbidden_tail,),
    )
    _freeze_synthetic_archive(monkeypatch, archive_path)
    staging_root = tmp_path / "staging"
    staging_root.mkdir(mode=0o700)
    staging_root.chmod(0o700)
    real_write = voice_artifact_intake.os.write
    swapped = False

    def swap_target_then_write(descriptor: int, data: memoryview) -> int:
        nonlocal swapped
        if not swapped:
            swapped = True
            target = staging_root / "model" / "encoder.onnx"
            target.rename(target.with_name("original-swapped-away.onnx"))
            target.write_bytes(b"replacement must survive")
        return real_write(descriptor, data)

    monkeypatch.setattr(voice_artifact_intake.os, "write", swap_target_then_write)

    with pytest.raises(
        voice_artifact_intake.VoiceArtifactIntakeError,
        match="cleanup could not be confirmed",
    ):
        voice_artifact_intake.materialize_frozen_voice_evaluation_artifact(
            archive_path,
            staging_root,
        )

    assert swapped
    assert (staging_root / "model" / "encoder.onnx").read_bytes() == (
        b"replacement must survive"
    )


@pytest.mark.parametrize("defect", ["duplicate", "missing", "wrong-cohort"])
def test_rejects_ambiguous_or_incomplete_frozen_cohorts(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    defect: str,
) -> None:
    payloads = dict(REQUIRED_ARCHIVE_PAYLOADS)
    extra_members: tuple[tarfile.TarInfo, ...] = ()
    if defect == "duplicate":
        duplicate = tarfile.TarInfo(f"{ARCHIVE_ROOT}/tokens.txt")
        duplicate.size = 0
        extra_members = (duplicate,)
    elif defect == "missing":
        del payloads[f"{ARCHIVE_ROOT}/bpe.model"]
    else:
        del payloads[f"{ARCHIVE_ROOT}/encoder-epoch-99-avg-1.int8.onnx"]
        payloads[f"{ARCHIVE_ROOT}/encoder-epoch-99-avg-1.onnx"] = (
            b"alternate fp32 encoder is not the frozen cohort"
        )

    archive_path = tmp_path / "bad-cohort.tar.bz2"
    _write_archive(archive_path, payloads, extra_members=extra_members)
    _freeze_synthetic_archive(monkeypatch, archive_path)
    staging_root = tmp_path / "staging"
    staging_root.mkdir(mode=0o700)
    staging_root.chmod(0o700)

    with pytest.raises(voice_artifact_intake.VoiceArtifactIntakeError):
        voice_artifact_intake.materialize_frozen_voice_evaluation_artifact(
            archive_path,
            staging_root,
        )

    assert list(staging_root.iterdir()) == []


def test_rejects_a_required_member_above_its_fixed_ceiling(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    payloads = dict(REQUIRED_ARCHIVE_PAYLOADS)
    tokens_source = f"{ARCHIVE_ROOT}/tokens.txt"
    tokens_ceiling = next(
        ceiling
        for source, _target, ceiling in voice_artifact_intake.FROZEN_MEMBER_TARGETS
        if source == tokens_source
    )
    payloads[tokens_source] = b"x" * (tokens_ceiling + 1)
    archive_path = tmp_path / "oversize-required.tar.bz2"
    _write_archive(archive_path, payloads)
    _freeze_synthetic_archive(monkeypatch, archive_path)
    staging_root = tmp_path / "staging"
    staging_root.mkdir(mode=0o700)
    staging_root.chmod(0o700)

    with pytest.raises(voice_artifact_intake.VoiceArtifactIntakeError):
        voice_artifact_intake.materialize_frozen_voice_evaluation_artifact(
            archive_path,
            staging_root,
        )

    assert list(staging_root.iterdir()) == []


def test_rejects_a_multiply_linked_archive(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    archive_path = tmp_path / "voice-model.tar.bz2"
    _write_archive(archive_path, dict(REQUIRED_ARCHIVE_PAYLOADS))
    linked_archive = tmp_path / "linked-model.tar.bz2"
    os.link(archive_path, linked_archive)
    _freeze_synthetic_archive(monkeypatch, archive_path)
    staging_root = tmp_path / "staging"
    staging_root.mkdir(mode=0o700)
    staging_root.chmod(0o700)

    with pytest.raises(voice_artifact_intake.VoiceArtifactIntakeError):
        voice_artifact_intake.materialize_frozen_voice_evaluation_artifact(
            linked_archive,
            staging_root,
        )

    assert list(staging_root.iterdir()) == []
