import argparse
import asyncio
from pathlib import Path
import signal
import sys
from typing import Optional, Sequence

from .engine import LocalInferenceEngine
from .offline import install_offline_network_guard
from .server import DaemonConfigurationError, RimeAIDaemonServer


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="rimeai-daemon")
    project_root = Path(__file__).resolve().parent.parent
    parser.add_argument(
        "--socket",
        type=Path,
        default=Path.home()
        / "Library"
        / "Application Support"
        / "RimeAI"
        / "runtime"
        / "rimeai.sock",
    )
    parser.add_argument(
        "--language-model",
        type=Path,
        default=project_root / ".rimeai/models/p0-char-ngram-v1.json.gz",
    )
    parser.add_argument(
        "--beam-config",
        type=Path,
        default=project_root / ".rimeai/models/p0-beam-sentence-v1.json",
    )
    parser.add_argument(
        "--rime-dictionary",
        type=Path,
        default=project_root
        / ".rimeai/rime/shared/luna_pinyin.dict.yaml",
    )
    return parser


async def _run(args: argparse.Namespace) -> None:
    engine = LocalInferenceEngine(
        language_model_path=args.language_model,
        beam_config_path=args.beam_config,
        rime_dictionary_path=args.rime_dictionary,
    )
    server = RimeAIDaemonServer(args.socket, engine)
    await server.start()
    stop_event = asyncio.Event()
    loop = asyncio.get_running_loop()
    for signal_number in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(signal_number, stop_event.set)
    try:
        await stop_event.wait()
    finally:
        await server.close()


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = _parser().parse_args(argv)
    install_offline_network_guard()
    try:
        asyncio.run(_run(args))
    except (
        DaemonConfigurationError,
        OSError,
        ValueError,
    ) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
