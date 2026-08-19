import argparse
import asyncio
from pathlib import Path
import signal
from typing import Optional, Sequence

from .qwen import QwenCandidateRanker
from .server import CloudBrokerServer
from .history_index import HistoryEmbeddingIndexer


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
    return parser


async def _run(socket_path: Path) -> None:
    history_root = (
        Path.home()
        / "Library"
        / "Application Support"
        / "RimeAI"
        / "History"
    )
    server = CloudBrokerServer(
        socket_path,
        QwenCandidateRanker(),
        HistoryEmbeddingIndexer(
            history_root / "history.sqlite3",
            history_root / "history-hnsw-v1.bin",
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
        await server.close()


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = _parser().parse_args(argv)
    asyncio.run(_run(args.socket))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
