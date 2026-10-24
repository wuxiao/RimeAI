"""User-private local inference daemon for RimeAI."""

import os
import warnings

__all__ = ["RimeAIDaemonServer"]


def _silence_known_third_party_startup_noise() -> None:
    """Keep the daemon log readable; env hygiene only, no behavior change.

    - ``TOKENIZERS_PARALLELISM``: the ranker loads a HF fast tokenizer
      (Rayon parallelism) before the server Popens the neural worker,
      so every spawn without an explicit value trips tokenizers'
      deadlock guard ("The current process just got forked...").
      ``setdefault`` keeps the service scripts' explicit exports
      authoritative and is inherited by spawned workers.
    - ``TRANSFORMERS_NO_ADVISORY_WARNINGS``: transformers 4.39 prints
      "Special tokens have been added..." on every tokenizer load
      (``logger.warning_advice``, re-read from the env each call).
    - urllib3 v2 on the Xcode Python 3.9 stack warns "only supports
      OpenSSL 1.1.1+" at import (LibreSSL build) on every start.

    Lives here (not ``__main__``) so any entry point importing the
    package applies it before heavy modules are imported.
    """
    os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")
    os.environ.setdefault("TRANSFORMERS_NO_ADVISORY_WARNINGS", "1")
    warnings.filterwarnings(
        "ignore",
        message=r"urllib3 v2 only supports OpenSSL.*",
    )


_silence_known_third_party_startup_noise()


def __getattr__(name: str):
    # Lazy import: partial deployments (e.g. the cloud broker snapshot) ship
    # only consolidation/user_lm and must not pull in the server stack.
    if name == "RimeAIDaemonServer":
        from .server import RimeAIDaemonServer

        return RimeAIDaemonServer
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")
