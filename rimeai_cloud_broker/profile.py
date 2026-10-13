"""L3 style-profile storage, merge, and cloud compression (LP-005).

Profiles are per-domain JSON documents versioned by revision. The merge
step folds a fresh LLM summary into the previous profile while locked
fields (user edits) stay untouched, and every save keeps the recent
revisions so a bad summary can be rolled back.
"""

from __future__ import annotations

import contextlib
import json
import os
import re
import shutil
import tempfile
import time
from collections.abc import Callable, Sequence
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 1
MAX_REVISIONS_KEPT = 10
MAX_SIGNATURE_PHRASES = 32
MAX_PHRASE_LENGTH = 64
MAX_TRAIT_ITEMS = 64
MAX_BATCH_CHARACTERS = 24_000
# Mirrors the daemon request validator and Swift PhraseBookStore domain
# validation; the domain is interpolated into file names, so its charset
# must stay closed.
DOMAIN_PATTERN = re.compile(r"[a-z0-9-]+")
ALLOWED_TRAIT_KEYS = (
    "register",
    "cn_en_mixing",
    "punctuation_habits",
    "sentence_templates",
    "vocabulary_domains",
    "signature_phrases",
)
PROFILE_TIMEOUT_SECONDS = 60.0

ChatTransport = Callable[..., dict[str, Any]]


class ProfileError(RuntimeError):
    pass


def _validate_string_list(value: Any, *, maximum: int) -> list[str]:
    if not isinstance(value, list) or len(value) > maximum:
        raise ProfileError("trait value must be a bounded list")
    items: list[str] = []
    for item in value:
        if not isinstance(item, str) or not item.strip():
            raise ProfileError("trait items must be non-empty strings")
        if len(item) > MAX_PHRASE_LENGTH:
            raise ProfileError("trait item exceeds the length cap")
        items.append(item.strip())
    return items


def _sanitize_traits(raw: Any) -> dict[str, list[str]]:
    """Normalizes an LLM-supplied or stored traits object into the
    whitelist with bounded lists; unknown keys are dropped silently."""
    if raw is None:
        return {}
    if not isinstance(raw, dict):
        raise ProfileError("traits must be an object")
    traits: dict[str, list[str]] = {}
    for key in ALLOWED_TRAIT_KEYS:
        if key not in raw or raw[key] is None:
            continue
        items = _validate_string_list(
            raw[key], maximum=MAX_SIGNATURE_PHRASES
            if key == "signature_phrases"
            else MAX_TRAIT_ITEMS
        )
        if items:
            traits[key] = items
    return traits


class StyleProfile:
    """One domain's compressed style memory."""

    def __init__(
        self,
        *,
        domain: str,
        revision: int,
        generated_at_ms: int,
        generator: str,
        traits: dict[str, list[str]],
        locked_fields: list[str] | None = None,
    ) -> None:
        if (
            not domain
            or len(domain) > 64
            or DOMAIN_PATTERN.fullmatch(domain) is None
        ):
            raise ProfileError("profile domain is invalid")
        if revision < 0:
            raise ProfileError("profile revision is invalid")
        self.domain = domain
        self.revision = revision
        self.generated_at_ms = generated_at_ms
        self.generator = generator
        self.traits = _sanitize_traits(traits)
        locked = locked_fields or []
        invalid = [
            name for name in locked if name not in ALLOWED_TRAIT_KEYS
        ]
        if invalid:
            raise ProfileError("locked fields must be trait keys")
        self.locked_fields = list(dict.fromkeys(locked))

    def to_payload(self) -> dict[str, Any]:
        return {
            "schema_version": SCHEMA_VERSION,
            "domain": self.domain,
            "revision": self.revision,
            "generated_at_ms": self.generated_at_ms,
            "generator": self.generator,
            "traits": self.traits,
            "locked_fields": self.locked_fields,
        }

    def __eq__(self, other: object) -> bool:
        if not isinstance(other, StyleProfile):
            return NotImplemented
        return self.to_payload() == other.to_payload()

    def __repr__(self) -> str:
        return (
            f"StyleProfile(domain={self.domain!r}, "
            f"revision={self.revision}, traits={self.traits!r})"
        )


def profile_from_payload(payload: Any) -> StyleProfile:
    if not isinstance(payload, dict):
        raise ProfileError("profile payload must be an object")
    if payload.get("schema_version") != SCHEMA_VERSION:
        raise ProfileError("unsupported profile schema version")
    for field in ("domain", "revision", "generator"):
        if field not in payload:
            raise ProfileError(f"profile field '{field}' is missing")
    try:
        return StyleProfile(
            domain=str(payload["domain"]),
            revision=int(payload["revision"]),
            generated_at_ms=int(payload.get("generated_at_ms", 0)),
            generator=str(payload["generator"])[:128],
            traits=payload.get("traits") or {},
            locked_fields=payload.get("locked_fields") or [],
        )
    except (TypeError, ValueError) as error:
        raise ProfileError("profile payload fields are invalid") from error


def merge_profile(
    previous: StyleProfile | None,
    summary_traits: dict[str, list[str]] | None,
    *,
    domain: str,
    generator: str,
) -> StyleProfile:
    """Folds a fresh summary into the previous profile.

    Locked fields always win over the LLM; signature phrases merge and
    deduplicate with recency (newest first)."""
    traits: dict[str, list[str]] = {}
    if previous is not None:
        traits.update(previous.traits)
    fresh = _sanitize_traits(summary_traits)
    locked = set(previous.locked_fields if previous else [])
    for key, items in fresh.items():
        if key in locked:
            continue
        if key == "signature_phrases" and key in traits:
            merged = list(dict.fromkeys(items + traits[key]))
            traits[key] = merged[:MAX_SIGNATURE_PHRASES]
        else:
            traits[key] = items
    return StyleProfile(
        domain=domain,
        revision=(previous.revision + 1) if previous else 1,
        generated_at_ms=int(time.time() * 1000),
        generator=generator[:128],
        traits=traits,
        locked_fields=list(previous.locked_fields) if previous else [],
    )


class ProfileStore:
    """Filesystem store: current profile plus bounded revisions."""

    def __init__(self, directory: Path) -> None:
        self.directory = directory
        self.revisions_directory = directory / "revisions"

    def _current_path(self, domain: str) -> Path:
        return self.directory / f"profile-{domain}.json"

    def load(self, domain: str) -> StyleProfile | None:
        path = self._current_path(domain)
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except FileNotFoundError:
            return None
        except (OSError, json.JSONDecodeError) as error:
            raise ProfileError(
                f"cannot read style profile '{domain}'"
            ) from error
        return profile_from_payload(payload)

    def save(self, profile: StyleProfile) -> None:
        self.directory.mkdir(parents=True, exist_ok=True)
        current = self._current_path(profile.domain)
        if current.exists():
            self._archive(current, profile.domain)
        self._atomic_write(current, profile.to_payload())

    def rollback(self, domain: str, steps: int = 1) -> StyleProfile | None:
        """Restores the most recent archived revision strictly older than
        the current one, `steps` times; None when nothing is archived."""
        current = self.load(domain)
        for _ in range(max(1, steps)):
            if current is None:
                break
            archived = self._previous_revision(domain, current.revision)
            if archived is None:
                break
            just_archived = self._archive(
                self._current_path(domain), domain
            )
            if not archived.exists():
                # _archive's trim removed the selected revision (it was
                # among the oldest); re-resolve once, and if nothing older
                # survives put the current profile back instead of
                # stranding the domain without one.
                archived = self._previous_revision(domain, current.revision)
                if archived is None:
                    shutil.move(
                        str(just_archived), str(self._current_path(domain))
                    )
                    break
            try:
                shutil.move(
                    str(archived), str(self._current_path(domain))
                )
            except shutil.SameFileError:
                pass
            except OSError as error:
                raise ProfileError(
                    f"cannot restore profile revision: {error}"
                ) from error
            current = self.load(domain)
        if current is None:
            raise ProfileError(
                f"rollback left no profile for '{domain}'"
            )
        return current

    def clear(self, domain: str | None = None) -> int:
        """Removes one or all profiles (plus revisions); returns files
        removed."""
        removed = 0
        targets: list[Path] = []
        if domain is None:
            if self.directory.exists():
                targets = [
                    item
                    for item in self.directory.iterdir()
                    if item.is_file()
                ] + [self.revisions_directory]
        else:
            targets = [self._current_path(domain)]
            if self.revisions_directory.exists():
                targets.extend(
                    self.revisions_directory.glob(f"{domain}-*.json")
                )
        for target in targets:
            if not target.exists():
                continue
            try:
                if target.is_dir():
                    shutil.rmtree(target)
                else:
                    target.unlink()
            except OSError as error:
                raise ProfileError(
                    f"cannot clear profile artifacts: {error}"
                ) from error
            removed += 1
        return removed

    def _archive(self, current: Path, domain: str) -> Path:
        """Moves the current profile into the bounded revision history and
        returns the archive path it landed on."""
        self.revisions_directory.mkdir(parents=True, exist_ok=True)
        stamp = int(time.time() * 1000)
        target = self.revisions_directory / f"{domain}-{stamp}.json"
        suffix = 0
        # Millisecond stamps can collide during rapid saves; never let a
        # newer archive silently overwrite an older revision.
        while target.exists():
            suffix += 1
            target = (
                self.revisions_directory
                / f"{domain}-{stamp}-{suffix}.json"
            )
        try:
            shutil.move(str(current), str(target))
        except shutil.SameFileError:
            pass
        except OSError as error:
            raise ProfileError(
                f"cannot archive profile revision: {error}"
            ) from error
        self._trim_revisions(domain)
        return target

    def _previous_revision(
        self, domain: str, current_revision: int
    ) -> Path | None:
        """Newest archived revision with revision < current revision."""
        if not self.revisions_directory.exists():
            return None
        best: tuple[int, Path] | None = None
        for candidate in self.revisions_directory.glob(f"{domain}-*.json"):
            try:
                payload = json.loads(
                    candidate.read_text(encoding="utf-8")
                )
                revision = int(payload["revision"])
            except (
                OSError,
                ValueError,
                KeyError,
                TypeError,
                json.JSONDecodeError,
            ):
                continue
            if revision >= current_revision:
                continue
            if best is None or revision > best[0]:
                best = (revision, candidate)
        return best[1] if best else None

    def _trim_revisions(self, domain: str) -> None:
        candidates = sorted(
            self.revisions_directory.glob(f"{domain}-*.json"), reverse=True
        )
        for stale in candidates[MAX_REVISIONS_KEPT:]:
            # A failed unlink must not abort the save/rollback in progress;
            # leftover revisions are bounded by disk, not correctness.
            with contextlib.suppress(OSError):
                stale.unlink()

    def _atomic_write(self, path: Path, payload: dict[str, Any]) -> None:
        descriptor, temporary = tempfile.mkstemp(
            dir=path.parent, prefix=f".{path.name}.", suffix=".tmp"
        )
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
                json.dump(
                    payload,
                    handle,
                    ensure_ascii=False,
                    separators=(",", ":"),
                    sort_keys=True,
                )
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary, path)
        except BaseException:
            with contextlib.suppress(FileNotFoundError):
                os.unlink(temporary)
            raise


_JSON_OBJECT_PATTERN = re.compile(r"\{.*\}", re.DOTALL)


class CloudProfileSummarizer:
    """Compresses a consolidation batch into trait summaries via the
    fixed cloud gateway. The transport is injected so tests never touch
    the network."""

    def __init__(
        self,
        transport: ChatTransport,
        *,
        model_id: str = "glm-5.3-flash",
        generator_label: str | None = None,
    ) -> None:
        self._transport = transport
        self._model_id = model_id
        self._generator = generator_label or f"{model_id}@cloud"

    @property
    def generator(self) -> str:
        return self._generator

    def summarize(
        self,
        texts: Sequence[str],
        previous: StyleProfile | None,
    ) -> dict[str, list[str]]:
        corpus = "\n".join(texts)
        if len(corpus) > MAX_BATCH_CHARACTERS:
            corpus = corpus[-MAX_BATCH_CHARACTERS:]
        messages = [
            {
                "role": "system",
                "content": (
                    "You compress a Chinese IME user's committed text into a "
                    "compact style profile. Output exactly one JSON object "
                    "with any of these optional keys: register (writing "
                    "style tendencies like classical/literary/colloquial), "
                    "cn_en_mixing (typical Chinese-English mixing patterns), "
                    "punctuation_habits, sentence_templates (recurring "
                    "sentence frames with {slots}), vocabulary_domains, "
                    "signature_phrases (short phrases this person clearly "
                    "reuses). Every value is a list of short strings. No "
                    "other keys, no prose."
                ),
            },
            {
                "role": "user",
                "content": json.dumps(
                    {
                        "previous_traits": (
                            previous.traits if previous else {}
                        ),
                        "committed_text": corpus,
                    },
                    ensure_ascii=False,
                ),
            },
        ]
        response = self._transport(
            "/chat/completions",
            {
                "model": self._model_id,
                "messages": messages,
                # OpenAI-compatible /chat/completions shape, same as
                # cloud_model.py; thinking.type=disabled keeps GLM 5.3 from
                # burning the budget on reasoning.
                "temperature": 0.2,
                "max_tokens": 800,
                "thinking": {"type": "disabled"},
            },
            timeout=PROFILE_TIMEOUT_SECONDS,
        )
        content = _extract_content(response)
        return _sanitize_traits(_decode_trait_object(content))


def _extract_content(response: dict[str, Any]) -> str:
    choices = response.get("choices")
    message = (
        choices[0].get("message")
        if isinstance(choices, list) and choices and isinstance(choices[0], dict)
        else None
    )
    content = message.get("content") if isinstance(message, dict) else None
    if not isinstance(content, str) or not content.strip():
        raise ProfileError("summary response has no content")
    return content


def make_semantic_consolidator(
    store: ProfileStore,
    summarizer: CloudProfileSummarizer,
    *,
    domain_resolver: Callable[[str], str],
) -> Callable[[Sequence[Any]], bool]:
    """Bridges the consolidation pipeline to L3 cloud compression.

    Groups one consolidation batch by effective domain, summarizes each
    group, merges into the stored profile, and returns True only when
    every domain succeeded — a single failure keeps the whole batch for
    the next idle window (double-delete guard)."""

    def consolidate(batch: Sequence[Any]) -> bool:
        groups: dict[str, list[str]] = {}
        for commit in batch:
            domain = domain_resolver(commit.bundle_id)
            groups.setdefault(domain, []).append(commit.committed_text)
        for domain, texts in sorted(groups.items()):
            previous = store.load(domain)
            fresh = summarizer.summarize(texts, previous)
            merged = merge_profile(
                previous,
                fresh,
                domain=domain,
                generator=summarizer.generator,
            )
            store.save(merged)
        return True

    return consolidate


def _decode_trait_object(content: str) -> Any:
    try:
        return json.loads(content)
    except json.JSONDecodeError:
        match = _JSON_OBJECT_PATTERN.search(content)
        if match is None:
            raise ProfileError("summary content is not JSON") from None
        try:
            return json.loads(match.group(0))
        except json.JSONDecodeError as error:
            raise ProfileError("summary content is not JSON") from error
