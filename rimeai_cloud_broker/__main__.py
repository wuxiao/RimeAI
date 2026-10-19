from __future__ import annotations

import argparse
import asyncio
import logging
import signal
import sqlite3
from collections.abc import Callable, Sequence
from pathlib import Path

from rimeai_daemon.consolidation import (
    ConsolidationPaths,
    ConsolidationPipeline,
    IdleConsolidationScheduler,
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


def _cloud_env_loader() -> str:
    """Reads the API key from ~/.config/rimeai/cloud.env with the same
    semantics as Swift CloudCredentialStore.parse: whole-line `#` comments
    and blank lines are skipped, values are KEY=VALUE with surrounding
    whitespace and one pair of quotes stripped, and a non-comment line
    without `=` raises — a typo must not silently disable the cloud."""
    path = Path.home() / ".config" / "rimeai" / "cloud.env"
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
    """Scheduler-side credential decision: a malformed file or a missing
    key means "no usable credentials" for the L3 pass (logged once at
    startup), not a broken scheduler — the statistics phase and raw-text
    eviction keep running with the semantic pass explicitly skipped."""
    try:
        return _cloud_env_loader()
    except ValueError:
        logging.getLogger(__name__).exception(
            "cloud credential file is malformed; the semantic pass is "
            "skipped until the file parses"
        )
        return ""


def _semantic_consolidator(
    transport: ChatTransport,
    *,
    enabled: bool,
    profile_directory: Path,
    phrasebook_db: Path,
):
    """Builds the L3 cloud-compression consolidator, or None when the
    semantic pass must be skipped this round (disabled, no credential
    file, or an unusable one) so eviction still proceeds. Called once
    per consolidation round via the provider below."""
    if not enabled:
        return None
    if not _usable_cloud_api_key():
        return None
    summarizer = CloudProfileSummarizer(transport)
    return make_semantic_consolidator(
        ProfileStore(profile_directory),
        summarizer,
        # Fresh resolver per round: the per-bundle cache must not outlive
        # the round, or settings-page domain edits never reach L3 (P2-1).
        domain_resolver=_phrasebook_domain_resolver(phrasebook_db),
    )


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

    def provide():
        consolidator = _semantic_consolidator(
            transport,
            enabled=enabled,
            profile_directory=profile_directory,
            phrasebook_db=phrasebook_db,
        )
        active = consolidator is not None
        if active != last_state["active"]:
            last_state["active"] = active
            logging.getLogger(__name__).info(
                "semantic consolidation %s for the upcoming rounds",
                "enabled" if active else "disabled",
            )
        return consolidator

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
