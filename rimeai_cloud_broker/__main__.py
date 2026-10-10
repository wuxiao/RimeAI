import argparse
import asyncio
from pathlib import Path
import signal
import sys
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
    parser.add_argument(
        "--rime-dictionary",
        type=Path,
        default=None,
        help="Rime dictionary for pinyin alignment of generated sentences",
    )
    return parser


def _load_pinyin_guard(path: Optional[Path]):
    if path is None:
        return None
    try:
        from rimeai_eval.pinyin_guard import PinyinGuard

        return PinyinGuard.from_rime_dictionary(path)
    except Exception as exc:  # noqa: BLE001 - degrade, never fail startup
        print(
            f"rimeai-cloud-broker: pinyin guard unavailable ({exc}); "
            "text generation stays disabled",
            file=sys.stderr,
        )
        return None


async def _run(
    socket_path: Path,
    rime_dictionary: Optional[Path],
) -> None:
    history_root = (
        Path.home()
        / "Library"
        / "Application Support"
        / "RimeAI"
        / "History"
    )
    pinyin_guard = _load_pinyin_guard(rime_dictionary)
    ranker = QwenCandidateRanker(pinyin_guard=pinyin_guard)
    server = CloudBrokerServer(
        socket_path,
        ranker,
        HistoryEmbeddingIndexer(
            history_root / "history.sqlite3",
            history_root / "history-hnsw-v1.bin",
        ),
        text_generation_enabled=ranker.generation_enabled,
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
    asyncio.run(_run(args.socket, args.rime_dictionary))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
