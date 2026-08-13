#!/usr/bin/env python3

"""PyInstaller entry point for the self-contained daemon runtime."""

from rimeai_daemon.__main__ import main


if __name__ == "__main__":
    raise SystemExit(main())
