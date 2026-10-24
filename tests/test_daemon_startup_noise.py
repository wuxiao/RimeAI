"""Importing the daemon package must silence known third-party startup noise.

The daemon runs under the Xcode Python 3.9 stack (user site
``/Library/Python/3.9``) and its stderr is the LaunchAgent log, so
library one-liners otherwise land in ``rimeai-daemon.log`` on every
start: the urllib3/LibreSSL warning, the transformers 4.39
"Special tokens have been added..." advisory, and tokenizers' fork
deadlock-guard warning once the ranker tokenizer's parallelism has been
used before the neural worker is spawned.
"""
from __future__ import annotations

import importlib
import os
import warnings

import rimeai_daemon


def test_daemon_package_silences_third_party_startup_noise(
    monkeypatch,
) -> None:
    monkeypatch.delenv("TOKENIZERS_PARALLELISM", raising=False)
    monkeypatch.delenv("TRANSFORMERS_NO_ADVISORY_WARNINGS", raising=False)
    importlib.reload(rimeai_daemon)
    try:
        assert os.environ["TOKENIZERS_PARALLELISM"] == "false"
        assert os.environ["TRANSFORMERS_NO_ADVISORY_WARNINGS"] == "1"
        with warnings.catch_warnings(record=True) as caught:
            warnings.warn(
                "urllib3 v2 only supports OpenSSL 1.1.1+, currently the "
                "'ssl' module is compiled with 'LibreSSL 2.8.3'.",
                UserWarning,
                stacklevel=2,
            )
        assert caught == []
    finally:
        # Leave the package in its post-import (already silenced) state.
        importlib.reload(rimeai_daemon)


def test_existing_values_are_not_overridden(monkeypatch) -> None:
    monkeypatch.setenv("TOKENIZERS_PARALLELISM", "true")
    monkeypatch.setenv("TRANSFORMERS_NO_ADVISORY_WARNINGS", "0")
    importlib.reload(rimeai_daemon)
    try:
        assert os.environ["TOKENIZERS_PARALLELISM"] == "true"
        assert os.environ["TRANSFORMERS_NO_ADVISORY_WARNINGS"] == "0"
    finally:
        importlib.reload(rimeai_daemon)
