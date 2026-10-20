from __future__ import annotations

import argparse
import asyncio
import logging
import signal
import sqlite3
import stat
from collections.abc import Callable, Sequence
from enum import Enum
from pathlib import Path

from rimeai_daemon.consolidation import (
    ConsolidationPaths,
    ConsolidationPipeline,
    IdleConsolidationScheduler,
    SemanticPass,
)

from .cloud_model import CloudModelClient
from .history_index import HistoryEmbeddingIndexer
from .instance_lock import SingleInstanceLock
from .profile import (
    ChatTransport,
    CloudProfileSummarizer,
    ProfileStore,
    make_semantic_consolidator,
)
from .server import CloudBrokerServer

CREDENTIAL_KEY = "RIMEAI_CLOUD_API_KEY"

# One-shot warning for a group/world-readable credential file.
_CREDENTIAL_PERMISSION_WARNING_EMITTED = False


class CredentialPermissionError(ValueError):
    """The credential file is readable by other local accounts."""


class CloudCredentialState(Enum):
    """Why the L3 semantic pass can or cannot run this round."""

    OK = "ok"
    ABSENT = "absent"
    BROKEN = "broken"


def _cloud_env_loader() -> str:
    """Reads the API key from ~/.config/rimeai/cloud.env with the same
    semantics as Swift CloudCredentialStore.parse: whole-line `#` comments
    and blank lines are skipped, values are KEY=VALUE with surrounding
    whitespace and one pair of quotes stripped, and a non-comment line
    without `=` raises — a typo must not silently disable the cloud."""
    path = Path.home() / ".config" / "rimeai" / "cloud.env"
    try:
        mode = path.stat().st_mode
    except FileNotFoundError:
        return ""
    if mode & (stat.S_IRWXG | stat.S_IRWXO):
        # The Swift credential store forces 0o600 on this file; a
        # group/world-readable copy means the key is exposed to every
        # local account. Refuse to use it rather than uploading with an
        # exposed credential — the L3 pass retries until the user
        # tightens the permissions (statistics and eviction keep running).
        global _CREDENTIAL_PERMISSION_WARNING_EMITTED
        if not _CREDENTIAL_PERMISSION_WARNING_EMITTED:
            _CREDENTIAL_PERMISSION_WARNING_EMITTED = True
            logging.getLogger(__name__).warning(
                "cloud credential file is group/world accessible; "
                "refusing to use it until its permissions are 0600 "
                "(expected at ~/.config/rimeai/cloud.env)"
            )
        raise CredentialPermissionError(
            "cloud credential file is group/world accessible"
        )
    try:
        text = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return ""
    for raw_line in text.split("\n"):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        key, separator, value = line.partition("=")
        key = key.strip()
        if not separator or not key:
            raise ValueError("cloud credential file is malformed")
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in {
            '"',
            "'",
        }:
            value = value[1:-1]
        if key == CREDENTIAL_KEY:
            if not value:
                # The key line exists but carries no value: the user
                # meant to configure the cloud but the file is
                # incomplete. That is a transient fault (the backlog
                # is kept and retried), not "cloud compression was
                # never enabled" (which would discard the backlog).
                raise ValueError("cloud credential file is malformed")
            return value
    return ""


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="rimeai-cloud-broker")
    parser.add_argument(
        "--socket",
        type=Path,
        default=Path.home()
        / "Library"
        / "Application Support"
        / "RimeAI"
        / "runtime"
        / "rimeai-cloud.sock",
    )
    parser.add_argument(
        "--no-consolidation",
        action="store_true",
        help=(
            "skip the L3 cloud LLM profile pass on each idle "
            "consolidation round (statistics and eviction still run)"
        ),
    )
    return parser


def _phrasebook_domain_resolver(
    phrasebook_db: Path,
) -> Callable[[str], str]:
    """Bundle-to-domain resolver with a per-batch cache."""
    cache: dict[str, str] = {}

    def resolve(bundle_id: str) -> str:
        if bundle_id in cache:
            return cache[bundle_id]
        domain = "global"
        try:
            with sqlite3.connect(phrasebook_db, timeout=1) as db:
                row = db.execute(
                    "SELECT domain FROM domain_map WHERE bundle_id = ?",
                    (bundle_id,),
                ).fetchone()
            if row:
                domain = str(row[0])
        except sqlite3.Error:
            domain = "global"
        cache[bundle_id] = domain
        return domain

    return resolve


def _usable_cloud_api_key() -> str:
    """Scheduler-side credential decision.

    Returns the key when it is usable, and "" when no credential is
    configured at all — the user never opted into cloud compression, so
    the L3 pass is off for good and the raw-text eviction keeps running
    with the semantic pass explicitly skipped.

    Raises when a credential file exists but cannot be used (malformed,
    or readable by other local accounts): those faults are transient,
    so the caller keeps the L3 backlog and retries instead of dropping
    it.
    """
    return _cloud_env_loader()


def _cloud_credential_state() -> CloudCredentialState:
    """Classifies the cloud credential for this round.

    - OK: a usable key is configured.
    - ABSENT: no credential is configured at all — the user opted out.
    - BROKEN: a credential file exists but cannot be parsed, or it is
      exposed to other local accounts (transient: the pass retries).
    """
    try:
        key = _usable_cloud_api_key()
    except ValueError:
        return CloudCredentialState.BROKEN
    return CloudCredentialState.OK if key else CloudCredentialState.ABSENT


def _semantic_consolidator(
    transport: ChatTransport,
    *,
    enabled: bool,
    profile_directory: Path,
    phrasebook_db: Path,
) -> SemanticPass:
    """Builds the L3 cloud-compression consolidator for this round, or a
    `SemanticPass` that says why it cannot run.

    Called once per consolidation round via the provider below."""
    if not enabled:
        # The user turned the semantic pass off explicitly.
        return SemanticPass(None, permanently_unavailable=True)
    state = _cloud_credential_state()
    if state is CloudCredentialState.ABSENT:
        # No credential configured: the user never opted into cloud
        # compression, so the L3 backlog is closed for good and the raw
        # text is evicted (statistics keep running).
        return SemanticPass(None, permanently_unavailable=True)
    if state is CloudCredentialState.BROKEN:
        # A credential file exists but cannot be used right now. Keep
        # the backlog so the pending summaries are still produced once
        # the file parses or its permissions are tightened.
        logging.getLogger(__name__).warning(
            "cloud credential is unusable; the semantic pass retries"
        )
        return SemanticPass(None, permanently_unavailable=False)
    summarizer = CloudProfileSummarizer(transport)
    consolidator = make_semantic_consolidator(
        ProfileStore(profile_directory),
        summarizer,
        # Fresh resolver per round: the per-bundle cache must not outlive
        # the round, or settings-page domain edits never reach L3 (P2-1).
        domain_resolver=_phrasebook_domain_resolver(phrasebook_db),
    )
    return SemanticPass(consolidator, permanently_unavailable=False)


def _semantic_consolidator_provider(
    transport: ChatTransport,
    *,
    enabled: bool,
    profile_directory: Path,
    phrasebook_db: Path,
):
    """Per-round consolidator factory (P2-1/P3-3): credentials and
    bundle→domain mappings are re-evaluated every round, so editing
    cloud.env or the phrasebook mapping takes effect at the next idle
    round instead of requiring a broker restart."""
    last_state: dict[str, bool] = {"active": False}

    def provide() -> SemanticPass:
        state = _semantic_consolidator(
            transport,
            enabled=enabled,
            profile_directory=profile_directory,
            phrasebook_db=phrasebook_db,
        )
        active = state.consolidator is not None
        if active != last_state["active"]:
            last_state["active"] = active
            logging.getLogger(__name__).info(
                "semantic consolidation %s for the upcoming rounds",
                "enabled" if active else "disabled",
            )
        return state

    return provide


def _maybe_start_consolidation(
    ranker: CloudModelClient,
    *,
    enabled: bool,
) -> IdleConsolidationScheduler | None:
    """Starts the L3 cloud-compression loop when credentials exist.

    Without usable credentials the scheduler still runs the statistics
    phase (semantic pass explicitly skipped) so raw-text eviction
    continues even while the cloud is unusable."""
    support = Path.home() / "Library" / "Application Support" / "RimeAI"
    profile_directory = support / "language_profile"
    paths = ConsolidationPaths(
        history_db=support / "History" / "history.sqlite3",
        phrasebook_db=profile_directory / "phrasebook.sqlite3",
        user_lm=profile_directory / "user-lm.json.gz",
    )
    scheduler = IdleConsolidationScheduler(
        ConsolidationPipeline(paths),
        semantic_consolidator_provider=_semantic_consolidator_provider(
            ranker.post_json,
            enabled=enabled,
            profile_directory=profile_directory,
            phrasebook_db=paths.phrasebook_db,
        ),
    )
    scheduler.start()
    return scheduler


async def _run(
    socket_path: Path,
    *,
    consolidation_enabled: bool = True,
) -> None:
    history_root = (
        Path.home()
        / "Library"
        / "Application Support"
        / "RimeAI"
        / "History"
    )
    ranker = CloudModelClient(api_key_loader=_cloud_env_loader)
    # The scheduler owns the idle gate for consolidation; creating it
    # before the server lets every accepted inference/continuation
    # request refresh the idle deadline, so rounds never fire mid-typing.
    scheduler = _maybe_start_consolidation(
        ranker,
        enabled=consolidation_enabled,
    )
    server = CloudBrokerServer(
        socket_path,
        ranker,
        HistoryEmbeddingIndexer(
            history_root / "history.sqlite3",
            history_root / "history-hnsw-v1.bin",
        ),
        activity_notifier=(
            scheduler.note_activity if scheduler is not None else None
        ),
    )
    await server.start()
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for signal_number in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(signal_number, stop.set)
    try:
        await stop.wait()
    finally:
        if scheduler is not None:
            scheduler.stop()
        await server.close()


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    # P2-7：进程级单例——launchd 双起窗口内两个 broker 会并发跑固化轮，
    # last-write-wins 损坏画像修订链。flock 随进程消亡自动释放。
    instance_lock = SingleInstanceLock(
        args.socket.parent, name="rimeai-cloud"
    )
    if not instance_lock.acquire():
        logging.getLogger(__name__).error(
            "another rimeai cloud broker already holds the instance lock"
        )
        return 2
    try:
        asyncio.run(
            _run(
                args.socket,
                consolidation_enabled=not args.no_consolidation,
            )
        )
    finally:
        instance_lock.release()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
