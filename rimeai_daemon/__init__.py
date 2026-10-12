"""User-private local inference daemon for RimeAI."""

__all__ = ["RimeAIDaemonServer"]


def __getattr__(name: str):
    # Lazy import: partial deployments (e.g. the cloud broker snapshot) ship
    # only consolidation/user_lm and must not pull in the server stack.
    if name == "RimeAIDaemonServer":
        from .server import RimeAIDaemonServer

        return RimeAIDaemonServer
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")
