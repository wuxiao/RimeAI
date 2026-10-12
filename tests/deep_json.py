"""Deterministic deep-nesting payloads for untrusted-JSON parser tests.

How deep the JSON parser may recurse before raising RecursionError is
an interpreter-internal budget: sys.getrecursionlimit() governs it on
CPython <= 3.11, while 3.12+ enforces a separate, larger C-level
limit. A fixed fixture depth therefore parses cleanly on some
interpreters and raises on others, so these helpers probe the running
parser and pick a depth that reliably trips it while staying under
each loader's byte cap.
"""

from __future__ import annotations

import json

_PROBE_DEPTH_CEILING = 65_536


def _trips_parser(depth: int) -> bool:
    try:
        json.loads("[" * depth + "0" + "]" * depth)
    except RecursionError:
        return True
    except Exception:
        return False
    return False


def deep_nesting_payloads(maximum_bytes: int) -> list[bytes]:
    """Payloads whose parse depth makes json.loads raise RecursionError
    on this interpreter, each 2*depth+1 bytes within maximum_bytes.

    Returns [] when the running parser survives every probeable depth:
    the RecursionError branch is then unreachable for inputs under the
    byte cap, so there is nothing to assert on this interpreter.
    """
    deepest = min(_PROBE_DEPTH_CEILING, max(1, (maximum_bytes - 2) // 2))
    if not _trips_parser(deepest):
        return []
    low, high = 1, deepest
    while low < high:
        middle = (low + high) // 2
        if _trips_parser(middle):
            high = middle
        else:
            low = middle + 1
    depth = min(deepest, low + 64)
    return [b"[" * depth + b"0" + b"]" * depth]
