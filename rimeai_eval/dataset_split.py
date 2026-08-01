"""Stable, source-document-level dataset splitting."""

import hashlib


def split_for_document(corpus: str, document: str) -> str:
    """Assign one source document to an 80/10/10 split deterministically."""

    digest = hashlib.sha256(f"{corpus}\0{document}".encode("utf-8")).digest()
    bucket = int.from_bytes(digest[:4], "big") % 10
    if bucket < 8:
        return "train"
    if bucket == 8:
        return "validation"
    return "test"
