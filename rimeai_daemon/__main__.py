from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import signal
import socket
import sys
from collections.abc import Sequence
from pathlib import Path
from typing import Any

from .decision_log import DecisionLog
from .engine import LocalInferenceEngine
from .neural_sentence import (
    NeuralSentenceConfigurationError,
    NeuralSentenceService,
    load_neural_sentence_config,
)
from .offline import install_offline_network_guard
from .server import DaemonConfigurationError, RimeAIDaemonServer


def _default_log_level() -> str:
    level = os.environ.get("RIMEAI_LOG_LEVEL", "").strip().lower()
    if level in {"debug", "info", "warning", "error"}:
        return level
    return "warning"


def _configure_logging(level: str) -> None:
    """stderr sink: the LaunchAgent redirects stderr to
    rimeai-daemon.log, so this is the daemon's file log too."""
    logging.basicConfig(
        stream=sys.stderr,
        level=getattr(logging, level.upper()),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )


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
        default=project_root / ".rimeai/models/p0-char-ngram-v2.json.gz",
    )
    parser.add_argument(
        "--beam-config",
        type=Path,
        default=project_root / ".rimeai/models/p0-beam-sentence-v3.json",
    )
    parser.add_argument(
        "--rime-dictionary",
        type=Path,
        default=project_root
        / ".rimeai/rime/shared/luna_pinyin.dict.yaml",
    )
    parser.add_argument("--neural-model", type=Path)
    parser.add_argument("--fusion-config", type=Path)
    parser.add_argument(
        "--neural-device",
        choices=("auto", "cpu", "mps"),
        default="cpu",
    )
    parser.add_argument(
        "--probe-socket",
        type=Path,
        help="validate a running release daemon instead of starting one",
    )
    parser.add_argument("--expected-artifact-id")
    parser.add_argument("--probe-timeout-ms", type=int, default=2000)
    parser.add_argument(
        "--user-lm",
        type=Path,
        help="L2 user language model artifact the engine reranks with",
    )
    parser.add_argument(
        "--no-decision-log",
        action="store_true",
        help=(
            "disable the local decision log (LM-003 sensing layer);"
            " feedback frames are then answered with nothing and the"
            " capability is not advertised"
        ),
    )
    parser.add_argument(
        "--neural-sentence-config",
        type=Path,
        help=(
            "decoder-style config for the async neural sentence arm "
            "(schema_version 1: name/command/timeout_ms plus budget_ms, "
            "min_confidence, model_type); omit to disable the tier"
        ),
    )
    parser.add_argument(
        "--log-level",
        choices=("debug", "info", "warning", "error"),
        default=_default_log_level(),
        help=(
            "daemon log verbosity on stderr (the LaunchAgent"
            " redirects it to rimeai-daemon.log); default comes from"
            " the RIMEAI_LOG_LEVEL environment variable or warning"
        ),
    )
    return parser


def _probe_running_daemon(
    socket_path: Path,
    *,
    expected_artifact_id: str,
    timeout_ms: int,
) -> dict[str, Any]:
    if not 1 <= timeout_ms <= 30_000:
        raise ValueError("probe timeout must be between 1 and 30000 ms")
    probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    probe.settimeout(timeout_ms / 1000)
    try:
        probe.connect(str(socket_path))
        request = {
            "schema_version": 1,
            "type": "hello",
            "client_id": "rimeai-release-health-probe",
            "capabilities": [],
        }
        probe.sendall(
            (
                json.dumps(request, separators=(",", ":")) + "\n"
            ).encode("utf-8")
        )
        response_bytes = bytearray()
        while b"\n" not in response_bytes:
            chunk = probe.recv(4096)
            if not chunk:
                raise OSError("daemon closed the probe connection")
            response_bytes.extend(chunk)
            if len(response_bytes) > 65_536:
                raise ValueError("daemon probe response is too large")
        response = json.loads(bytes(response_bytes).split(b"\n", 1)[0])
        if not isinstance(response, dict) or response.get("status") != "ok":
            raise ValueError("daemon health probe failed")
        if response.get("offline_lock") is not True:
            raise ValueError("daemon Offline Lock is not active")
        if response.get("model_artifact_id") != expected_artifact_id:
            raise ValueError("daemon is serving an unexpected model artifact")
        capabilities = response.get("capabilities")
        if not isinstance(capabilities, list) or not {
            "decision-reasons",
            "long-input-reasons",
        }.issubset(capabilities):
            raise ValueError("daemon protocol capabilities are incomplete")
        return response
    finally:
        probe.close()


async def _run(args: argparse.Namespace) -> None:
    logger = logging.getLogger(__name__)
    logger.info(
        "daemon starting socket=%s neural_device=%s"
        " neural_sentence_config=%s decision_log=%s",
        args.socket,
        args.neural_device,
        args.neural_sentence_config,
        not args.no_decision_log,
    )
    # The cloud broker owns the idle consolidation loop (it holds the
    # credentials); the daemon only consumes the artifacts it produces.
    support_directory = (
        Path.home()
        / "Library"
        / "Application Support"
        / "RimeAI"
    )
    # Optional output-time t2s table, deployed beside the language
    # model (dev: .rimeai/models/, installed: ~/Library/Application
    # Support/RimeAI/models/). Missing table = no conversion, which
    # keeps older deployments working unchanged.
    t2s_table_path = args.language_model.parent / "t2s-simplified.json"
    engine = LocalInferenceEngine(
        language_model_path=args.language_model,
        beam_config_path=args.beam_config,
        rime_dictionary_path=args.rime_dictionary,
        neural_model_path=args.neural_model,
        fusion_config_path=args.fusion_config,
        neural_device=args.neural_device,
        user_lm_path=(
            args.user_lm
            or support_directory / "language_profile" / "user-lm.json.gz"
        ),
        t2s_table_path=(
            t2s_table_path if t2s_table_path.is_file() else None
        ),
    )
    neural_sentence_service = None
    if args.neural_sentence_config is not None:
        neural_sentence_service = NeuralSentenceService(
            load_neural_sentence_config(args.neural_sentence_config),
            project_root=Path(__file__).resolve().parent.parent,
        )
    decision_log = None
    if not args.no_decision_log:
        decision_log = DecisionLog(
            support_directory / "language_profile" / "decision_log.db"
        )
    server = RimeAIDaemonServer(
        args.socket,
        engine,
        neural_sentence=neural_sentence_service,
        decision_log=decision_log,
    )
    await server.start()
    logger.info(
        "daemon ready socket=%s artifact_id=%s", args.socket, engine.artifact_id
    )
    stop_event = asyncio.Event()
    loop = asyncio.get_running_loop()
    for signal_number in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(signal_number, stop_event.set)
    try:
        await stop_event.wait()
    finally:
        await server.close()


def main(argv: Sequence[str] | None = None) -> int:
    parser = _parser()
    args = parser.parse_args(argv)
    _configure_logging(args.log_level)
    if (args.probe_socket is None) != (args.expected_artifact_id is None):
        parser.error(
            "--probe-socket and --expected-artifact-id must be used together"
        )
    install_offline_network_guard()
    try:
        if args.probe_socket is not None:
            response = _probe_running_daemon(
                args.probe_socket,
                expected_artifact_id=args.expected_artifact_id,
                timeout_ms=args.probe_timeout_ms,
            )
            print(
                json.dumps(
                    {
                        "model_artifact_id": response["model_artifact_id"],
                        "offline_lock": response["offline_lock"],
                        "status": response["status"],
                    },
                    separators=(",", ":"),
                    sort_keys=True,
                )
            )
            return 0
        asyncio.run(_run(args))
    except (
        DaemonConfigurationError,
        NeuralSentenceConfigurationError,
        json.JSONDecodeError,
        OSError,
        ValueError,
    ) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
