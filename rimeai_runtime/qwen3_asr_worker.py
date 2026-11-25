"""Offline MLX Qwen3-ASR streaming worker for RimeAI Voice Helper.

Protocol: newline-delimited JSON on stdin/stdout; diagnostics only on stderr
(never logs transcripts, audio, or user hotwords).

Invariants:
- Process-wide AF_INET/AF_INET6 guard is installed before model loading.
- Audio lives exclusively in process memory and is cleared on stop/cancel.
- Layer-1 hotword biasing passes concise hotwords to Qwen3-ASR ``hotwords=``.
- Layer-2 deterministic hotword restoration normalizes English spacing/casing
  (e.g. ``Rime AI`` -> ``RimeAI``, ``fast api`` -> ``FastAPI``) and exact
  Mandarin homophones via pypinyin without risking runaway false positives.
"""

from __future__ import annotations

import base64
import errno
import importlib
import json
import os
import re
import select
import socket
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Protocol, Sequence

import numpy as np

try:
    from pypinyin import Style, lazy_pinyin
except Exception:  # pragma: no cover - optional fallback in bare envs
    Style = None  # type: ignore[assignment]
    lazy_pinyin = None  # type: ignore[assignment]

SAMPLE_RATE_HZ = 16_000
PARTIAL_MIN_AUDIO_SECONDS = 0.55
PARTIAL_STEP_SECONDS = 0.85
MIN_FINAL_AUDIO_SECONDS = 0.15
SPEECH_RMS_THRESHOLD = 0.0035
SPEECH_PEAK_THRESHOLD = 0.015
VAD_FRAME_SAMPLES = int(SAMPLE_RATE_HZ * 0.1)  # 100 ms sub-frame
LEADING_SILENCE_MAX_SECONDS = 1.2
LEADING_SILENCE_KEEP_SECONDS = 0.4
SEGMENT_MIN_COMMIT_SECONDS = 3.0
SEGMENT_SILENCE_COMMIT_SECONDS = 0.9
SEGMENT_SOFT_MAX_SECONDS = 16.0
SEGMENT_SOFT_SILENCE_SECONDS = 0.25
SEGMENT_HARD_MAX_SECONDS = 22.0
SEGMENT_SPLIT_SEARCH_SECONDS = 3.0
# A failed segment decode is retried once before it counts as a failure.
SEGMENT_DECODE_ATTEMPTS = 2
# Consecutive failed hard-split commits that keep the buffered speech in
# memory before the worker gives up on it (and says so on stderr).
SEGMENT_DECODE_FAILURE_BUDGET = 2
# After a failed hard split the next one waits for this much fresh audio,
# instead of re-failing on every chunk that arrives.
SEGMENT_RETRY_BACKOFF_SECONDS = 2.0
DIAGNOSTIC_ERROR_LENGTH = 200
MAX_ASR_CONTEXT_HOTWORDS = 64
MAX_TOTAL_HOTWORDS = 128

_HAN_RE = re.compile(r"^[\u4e00-\u9fff]+$")
_ASCII_WORD_RE = re.compile(r"[A-Za-z0-9]")
_WHITESPACE_RE = re.compile(r"\s+")


def _error_summary(exc: BaseException) -> str:
    """One line, bounded, safe for the diagnostic stream."""
    summary = " ".join(str(exc).split())
    if not summary:
        summary = repr(exc)
    return summary[:DIAGNOSTIC_ERROR_LENGTH]


def _log_warning(event: str, **fields: Any) -> None:
    """Structured stderr diagnostic.

    Carries shapes only — callers never pass transcripts, audio or
    hotwords — so it stays on in release builds, where stderr is the
    only channel through which a decode failure would ever be noticed.
    """
    payload: dict[str, Any] = {
        "ts": round(time.time(), 3),
        "level": "warning",
        "event": event,
    }
    payload.update(fields)
    sys.stderr.write(
        json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n"
    )
    sys.stderr.flush()


# MARK: - Offline Network Guard


_ORIGINAL_SOCKET = socket.socket


class _OfflineSocket(_ORIGINAL_SOCKET):
    def __init__(
        self,
        family: int = -1,
        type: int = -1,
        proto: int = -1,
        fileno: Any = None,
    ) -> None:
        effective_family = socket.AF_INET if family == -1 else family
        if fileno is None and effective_family in (
            socket.AF_INET,
            socket.AF_INET6,
        ):
            raise PermissionError(
                errno.EPERM,
                "RimeAI Voice MLX worker denies internet sockets",
            )
        super().__init__(family, type, proto, fileno)


def install_offline_guard() -> None:
    """Block IPv4/IPv6 sockets while keeping local stdio/UDS operational."""
    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["TRANSFORMERS_OFFLINE"] = "1"
    os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
    os.environ["DO_NOT_TRACK"] = "1"
    try:
        from rimeai_daemon.offline import install_offline_network_guard

        install_offline_network_guard()
    except Exception:
        socket.socket = _OfflineSocket  # type: ignore[misc]


# MARK: - Layer-2 Deterministic Hotword Corrector


def _ascii_skeleton(text: str) -> str:
    return re.sub(r"[\s\-_]+", "", text).lower()


def _is_han_char(ch: str) -> bool:
    code = ord(ch)
    return 0x4E00 <= code <= 0x9FFF


def _is_ascii_alnum(ch: str) -> bool:
    return ("a" <= ch <= "z") or ("A" <= ch <= "Z") or ("0" <= ch <= "9")


def _pinyin_tuple(text: str, *, with_tone: bool) -> tuple[str, ...] | None:
    if lazy_pinyin is None or Style is None:
        return None
    style = Style.TONE3 if with_tone else Style.NORMAL
    return tuple(lazy_pinyin(text, style=style))


@dataclass(frozen=True)
class _AsciiHotwordRule:
    phrase: str
    skeleton: str
    pattern: re.Pattern[str]


@dataclass(frozen=True)
class _HanHotwordRule:
    phrase: str
    length: int
    toneless: tuple[str, ...]
    toned: tuple[str, ...]


class HotwordCorrector:
    """Conservative, deterministic hotword restoration applied after ASR.

    Rules:
    1. ASCII / mixed-alphanumeric hotwords (e.g. ``RimeAI``, ``FastAPI``,
       ``SwiftUI``): match case-insensitively with optional spaces/hyphens
       between letters at ASCII word boundaries (fixes ``Rime AI`` ->
       ``RimeAI``, ``fast api`` -> ``FastAPI``).
    2. Pure Chinese hotwords (length >= 3): replace any contiguous same-length
       Han span with identical toneless pinyin (e.g. ``雾松拼音`` ->
       ``雾凇拼音``).
    3. Pure Chinese hotwords (length == 2): replace a contiguous 2-Han span
       only when toned pinyin matches identically OR toneless pinyin matches
       AND at least 1 character already matches (prevents unrelated homophone
       false positives while catching slips like ``雾松`` -> ``雾凇``).
    """

    def __init__(self, hotwords: Sequence[str]) -> None:
        cleaned = self._dedupe_phrases(hotwords)
        self.phrases: tuple[str, ...] = tuple(cleaned)
        self._ascii_rules: list[_AsciiHotwordRule] = []
        self._han_rules: list[_HanHotwordRule] = []

        # Longer phrases take precedence so substrings do not clobber them.
        for phrase in sorted(cleaned, key=lambda p: (-len(p), p)):
            if _HAN_RE.match(phrase) and len(phrase) >= 2:
                toneless = _pinyin_tuple(phrase, with_tone=False)
                toned = _pinyin_tuple(phrase, with_tone=True)
                if (
                    toneless is not None
                    and toned is not None
                    and len(toneless) == len(phrase)
                    and len(toned) == len(phrase)
                ):
                    self._han_rules.append(
                        _HanHotwordRule(
                            phrase=phrase,
                            length=len(phrase),
                            toneless=toneless,
                            toned=toned,
                        )
                    )
            elif _ASCII_WORD_RE.search(phrase):
                skeleton = _ascii_skeleton(phrase)
                if len(skeleton) >= 3 and skeleton.isascii():
                    # Allow optional spaces or hyphens between characters
                    # so "Rime AI" or "fast-api" matches "RimeAI"/"FastAPI".
                    escaped_chars = [re.escape(c) for c in skeleton]
                    body = r"[\s\-]*".join(escaped_chars)
                    pattern = re.compile(
                        rf"(?<![A-Za-z0-9]){body}(?![A-Za-z0-9])",
                        re.IGNORECASE,
                    )
                    self._ascii_rules.append(
                        _AsciiHotwordRule(
                            phrase=phrase,
                            skeleton=skeleton,
                            pattern=pattern,
                        )
                    )

    @staticmethod
    def _dedupe_phrases(hotwords: Sequence[str]) -> list[str]:
        seen: set[str] = set()
        result: list[str] = []
        for raw in hotwords:
            if not isinstance(raw, str):
                continue
            phrase = _WHITESPACE_RE.sub(" ", raw.strip())
            if len(phrase) < 2 or len(phrase) > 32:
                continue
            if phrase not in seen:
                seen.add(phrase)
                result.append(phrase)
            if len(result) >= MAX_TOTAL_HOTWORDS:
                break
        return result

    def apply(self, text: str) -> str:
        if not text:
            return ""
        updated = text
        for rule in self._ascii_rules:
            updated = rule.pattern.sub(rule.phrase, updated)
        if self._han_rules:
            updated = self._apply_han_rules(updated)
        return updated

    def _apply_han_rules(self, text: str) -> str:
        chars = list(text)
        n = len(chars)
        # Precompute per-character pinyin for Han characters only.
        char_toneless: list[str | None] = [None] * n
        char_toned: list[str | None] = [None] * n
        han_indices = [i for i, ch in enumerate(chars) if _is_han_char(ch)]
        if len(han_indices) < 2:
            return text

        # Compute pinyin over contiguous Han runs so polyphones use context.
        run_start = 0
        while run_start < len(han_indices):
            run_end = run_start
            while (
                run_end + 1 < len(han_indices)
                and han_indices[run_end + 1] == han_indices[run_end] + 1
            ):
                run_end += 1
            start_idx = han_indices[run_start]
            end_idx = han_indices[run_end] + 1
            segment = "".join(chars[start_idx:end_idx])
            seg_toneless = _pinyin_tuple(segment, with_tone=False)
            seg_toned = _pinyin_tuple(segment, with_tone=True)
            if (
                seg_toneless is not None
                and seg_toned is not None
                and len(seg_toneless) == len(segment)
                and len(seg_toned) == len(segment)
            ):
                for offset in range(len(segment)):
                    char_toneless[start_idx + offset] = seg_toneless[offset]
                    char_toned[start_idx + offset] = seg_toned[offset]
            run_start = run_end + 1

        locked = [False] * n
        for rule in self._han_rules:
            length = rule.length
            if length > n:
                continue
            i = 0
            while i <= n - length:
                if any(locked[i : i + length]) or any(
                    char_toneless[j] is None for j in range(i, i + length)
                ):
                    i += 1
                    continue
                span_toneless = tuple(char_toneless[i : i + length])
                if span_toneless != rule.toneless:
                    i += 1
                    continue
                current_span = "".join(chars[i : i + length])
                if current_span == rule.phrase:
                    for j in range(i, i + length):
                        locked[j] = True
                    i += length
                    continue
                if length >= 3:
                    should_replace = True
                else:
                    span_toned = tuple(char_toned[i : i + length])
                    shared_chars = sum(
                        1
                        for a, b in zip(current_span, rule.phrase)
                        if a == b
                    )
                    should_replace = (
                        span_toned == rule.toned or shared_chars >= 1
                    )
                if should_replace:
                    for offset, replacement_ch in enumerate(rule.phrase):
                        chars[i + offset] = replacement_ch
                        locked[i + offset] = True
                    i += length
                else:
                    i += 1
        return "".join(chars)


# MARK: - Text Sanitization & Repetition Guard


def sanitize_transcript(
    text: str,
    *,
    hotwords: Sequence[str] = (),
    has_speech: bool = True,
) -> str:
    """Enforce single-line V2 protocol text and guard against hotword echoes."""
    if not text:
        return ""
    cleaned = text.replace("\r", " ").replace("\n", " ")
    cleaned = _WHITESPACE_RE.sub(" ", cleaned).strip()
    if not cleaned:
        return ""

    # Guard against silence / near-silence hallucinating the hotword prompt.
    if not has_speech:
        return ""
    if hotwords and _looks_like_hotword_dump(cleaned, hotwords):
        return ""

    return cleaned


def _looks_like_hotword_dump(text: str, hotwords: Sequence[str]) -> bool:
    """Detect when ASR hallucinates the injected hotword list verbatim."""
    if len(hotwords) < 3:
        return False
    hits = 0
    matched_chars = 0
    for phrase in hotwords[:MAX_ASR_CONTEXT_HOTWORDS]:
        if phrase and phrase in text:
            hits += 1
            matched_chars += len(phrase)
    if hits < 3:
        return False
    # If >85% of the non-punctuation characters are just concatenated hotwords
    # with separator punctuation, treat as a hotword-prompt echo hallucination.
    content_chars = len(re.sub(r"[\s,，、.;；:：]+", "", text))
    return content_chars > 0 and (matched_chars / content_chars) >= 0.85


def split_stable_partial(previous: str, current: str) -> tuple[str, str]:
    """Split streaming transcript into stable common prefix + changing tail."""
    if not current:
        return ("", "")
    if not previous:
        return ("", current)
    limit = min(len(previous), len(current))
    prefix_len = 0
    while prefix_len < limit and previous[prefix_len] == current[prefix_len]:
        prefix_len += 1
    return (current[:prefix_len], current[prefix_len:])


# MARK: - ASR Backend Protocol & MLX Wrapper


class ASRTranscriber(Protocol):
    def transcribe(
        self,
        audio: np.ndarray,
        *,
        hotwords: Sequence[str],
        max_tokens: int,
    ) -> str: ...


class MLXQwen3ASRTranscriber:
    """Thin wrapper around ``mlx_audio`` Qwen3-ASR loaded strictly offline."""

    def __init__(self, model_dir: Path) -> None:
        if not model_dir.is_dir():
            raise FileNotFoundError(
                f"Qwen3-ASR model directory not found: {model_dir}"
            )
        # Imported by name, exactly like mlx_worker does for mlx/mlx-lm:
        # the model stack only exists in the MLX virtualenv, and a static
        # import would make this module unresolvable in the repo venv.
        load = importlib.import_module("mlx_audio.stt").load

        self.model_dir = model_dir
        self._model = load(str(model_dir))
        # Warmup Metal kernels once so first live utterance has low latency.
        warmup = np.zeros(int(SAMPLE_RATE_HZ * 0.25), dtype=np.float32)
        try:
            self._model.generate(warmup, max_tokens=8, temperature=0.0)
        except Exception as exc:
            # Warmup only pre-compiles the Metal kernels: failing it leaves
            # the first live utterance slow, not broken. It still has to be
            # seen — a model that cannot decode a quarter second of silence
            # is a warning about every decode that follows. The message is
            # logged because it names the engine fault (never user data:
            # the input is silence).
            _log_warning(
                "warmup_failed",
                error_type=type(exc).__name__,
                error=_error_summary(exc),
            )

    def transcribe(
        self,
        audio: np.ndarray,
        *,
        hotwords: Sequence[str],
        max_tokens: int = 256,
    ) -> str:
        asr_hotwords = list(hotwords[:MAX_ASR_CONTEXT_HOTWORDS]) or None
        output = self._model.generate(
            audio,
            max_tokens=max_tokens,
            temperature=0.0,
            repetition_penalty=1.05,
            hotwords=asr_hotwords,
        )
        text = getattr(output, "text", "")
        return text if isinstance(text, str) else str(text)


def join_segments(prefix: str, segment: str) -> str:
    """Join committed segment text with a new segment without gluing ASCII words."""
    if not prefix:
        return segment
    if not segment:
        return prefix
    if _is_ascii_alnum(prefix[-1]) and _is_ascii_alnum(segment[0]):
        return f"{prefix} {segment}"
    return f"{prefix}{segment}"


def _subframe_has_speech(frame: np.ndarray) -> bool:
    if frame.size == 0:
        return False
    rms = float(np.sqrt(np.mean(frame * frame)))
    peak = float(np.max(np.abs(frame)))
    return rms >= SPEECH_RMS_THRESHOLD or peak >= SPEECH_PEAK_THRESHOLD


def _find_lowest_energy_split(
    audio: np.ndarray,
    *,
    search_samples: int,
    min_prefix_samples: int,
) -> int:
    """Choose a split index near the tail of ``audio`` at the quietest 100 ms frame."""
    total = int(audio.size)
    if total <= min_prefix_samples:
        return total
    window = VAD_FRAME_SAMPLES
    search_start = max(min_prefix_samples, total - search_samples)
    if total - search_start < window:
        return total
    best_idx = total
    best_rms = float("inf")
    step = max(window // 2, 1)
    for start in range(search_start, total - window + 1, step):
        seg = audio[start : start + window]
        rms = float(np.sqrt(np.mean(seg * seg)))
        if rms < best_rms:
            best_rms = rms
            best_idx = start + window // 2
    return best_idx


# MARK: - Streaming Session State Machine


@dataclass
class ActiveSession:
    request_id: str
    hotwords: list[str]
    corrector: HotwordCorrector
    chunks: list[np.ndarray] = field(default_factory=list)
    segment_samples: int = 0
    total_samples: int = 0
    samples_since_partial: int = 0
    segment_speech_detected: bool = False
    trailing_silence_samples: int = 0
    committed_text: str = ""
    last_active_partial: str = ""
    last_emitted_full_text: str = ""
    # Consecutive hard-split commits whose decode failed after retry. The
    # buffered speech stays in memory while this is within
    # SEGMENT_DECODE_FAILURE_BUDGET; only past it is it released.
    segment_decode_failures: int = 0
    # A failed hard split backs off: the next one waits until the buffer
    # reaches this many samples.
    hard_split_defer_until_samples: int = 0

    def append_pcm(
        self,
        samples: np.ndarray,
        *,
        leading_silence_max_samples: int = int(
            LEADING_SILENCE_MAX_SECONDS * SAMPLE_RATE_HZ
        ),
        leading_silence_keep_samples: int = int(
            LEADING_SILENCE_KEEP_SECONDS * SAMPLE_RATE_HZ
        ),
    ) -> bool:
        """Append 16 kHz mono float32 samples with no session duration cap."""
        if samples.size == 0:
            return False
        if not np.all(np.isfinite(samples)):
            samples = np.nan_to_num(samples, nan=0.0, posinf=0.0, neginf=0.0)
        self.chunks.append(samples)
        self.segment_samples += int(samples.size)
        self.total_samples += int(samples.size)
        self.samples_since_partial += int(samples.size)

        chunk_has_speech = False
        offset = 0
        n = int(samples.size)
        while offset < n:
            end = min(offset + VAD_FRAME_SAMPLES, n)
            sub = samples[offset:end]
            if _subframe_has_speech(sub):
                chunk_has_speech = True
                self.segment_speech_detected = True
                self.trailing_silence_samples = 0
            else:
                self.trailing_silence_samples += int(sub.size)
            offset = end

        # Prevent unbounded memory growth during long silence before speech starts.
        if (
            not self.segment_speech_detected
            and self.segment_samples > leading_silence_max_samples
        ):
            self._trim_leading_silence(leading_silence_keep_samples)
        return chunk_has_speech

    def _trim_leading_silence(self, keep_samples: int) -> None:
        if keep_samples <= 0:
            self.chunks.clear()
            self.segment_samples = 0
            self.samples_since_partial = 0
            self.trailing_silence_samples = 0
            return
        audio = self.segment_audio()
        if audio.size <= keep_samples:
            return
        tail = audio[-keep_samples:].copy()
        self.chunks = [tail]
        self.segment_samples = int(tail.size)
        self.samples_since_partial = min(self.samples_since_partial, self.segment_samples)
        self.trailing_silence_samples = self.segment_samples

    def segment_audio(self) -> np.ndarray:
        if not self.chunks:
            return np.zeros(0, dtype=np.float32)
        if len(self.chunks) == 1:
            return self.chunks[0]
        return np.concatenate(self.chunks)

    def reset_active_segment(self, tail: np.ndarray | None = None) -> None:
        self.chunks.clear()
        self.segment_samples = 0
        self.samples_since_partial = 0
        self.segment_speech_detected = False
        self.trailing_silence_samples = 0
        self.last_active_partial = ""
        # The buffer starts over, so a retry point computed for the old one
        # no longer means anything.
        self.hard_split_defer_until_samples = 0
        if tail is not None and tail.size > 0:
            tail_copy = tail.copy()
            self.chunks.append(tail_copy)
            self.segment_samples = int(tail_copy.size)
            offset = 0
            n = int(tail_copy.size)
            while offset < n:
                end = min(offset + VAD_FRAME_SAMPLES, n)
                sub = tail_copy[offset:end]
                if _subframe_has_speech(sub):
                    self.segment_speech_detected = True
                    self.trailing_silence_samples = 0
                else:
                    self.trailing_silence_samples += int(sub.size)
                offset = end

    def clear(self) -> None:
        self.chunks.clear()
        self.segment_samples = 0
        self.total_samples = 0
        self.samples_since_partial = 0
        self.segment_speech_detected = False
        self.trailing_silence_samples = 0
        self.committed_text = ""
        self.last_active_partial = ""
        self.last_emitted_full_text = ""
        self.segment_decode_failures = 0
        self.hard_split_defer_until_samples = 0


class Qwen3ASRWorker:
    """Handles NDJSON commands for one voice-helper worker process.

    Supports unlimited dictation duration and unlimited text length via
    incremental VAD / bounded-segment committing: completed phrases are
    decoded, sealed into ``committed_text``, and their PCM buffers freed so
    latency and memory stay constant regardless of session length.
    """

    def __init__(
        self,
        transcriber: ASRTranscriber,
        *,
        model_id: str,
        partial_min_seconds: float = PARTIAL_MIN_AUDIO_SECONDS,
        partial_step_seconds: float = PARTIAL_STEP_SECONDS,
        segment_min_commit_seconds: float = SEGMENT_MIN_COMMIT_SECONDS,
        segment_silence_commit_seconds: float = SEGMENT_SILENCE_COMMIT_SECONDS,
        segment_soft_max_seconds: float = SEGMENT_SOFT_MAX_SECONDS,
        segment_soft_silence_seconds: float = SEGMENT_SOFT_SILENCE_SECONDS,
        segment_hard_max_seconds: float = SEGMENT_HARD_MAX_SECONDS,
        segment_split_search_seconds: float = SEGMENT_SPLIT_SEARCH_SECONDS,
        segment_retry_backoff_seconds: float = SEGMENT_RETRY_BACKOFF_SECONDS,
    ) -> None:
        self._transcriber = transcriber
        self._model_id = model_id
        self._partial_min_samples = int(partial_min_seconds * SAMPLE_RATE_HZ)
        self._partial_step_samples = int(partial_step_seconds * SAMPLE_RATE_HZ)
        self._segment_min_commit_samples = int(
            segment_min_commit_seconds * SAMPLE_RATE_HZ
        )
        self._segment_silence_commit_samples = int(
            segment_silence_commit_seconds * SAMPLE_RATE_HZ
        )
        self._segment_soft_max_samples = int(
            segment_soft_max_seconds * SAMPLE_RATE_HZ
        )
        self._segment_soft_silence_samples = int(
            segment_soft_silence_seconds * SAMPLE_RATE_HZ
        )
        self._segment_hard_max_samples = int(
            segment_hard_max_seconds * SAMPLE_RATE_HZ
        )
        self._segment_split_search_samples = int(
            segment_split_search_seconds * SAMPLE_RATE_HZ
        )
        self._segment_retry_backoff_samples = int(
            segment_retry_backoff_seconds * SAMPLE_RATE_HZ
        )
        self._session: ActiveSession | None = None

    def handle(
        self,
        message: dict[str, Any],
        *,
        defer_partial: bool = False,
    ) -> list[dict[str, Any]]:
        msg_type = message.get("type")
        if msg_type == "ping":
            return [{"type": "pong", "model_id": self._model_id}]

        if msg_type == "start":
            request_id = str(message.get("request_id", "")).strip()
            if not request_id:
                return [
                    {
                        "type": "error",
                        "request_id": "",
                        "code": "invalid_request",
                    }
                ]
            if self._session is not None:
                self._session.clear()
            raw_hotwords = message.get("hotwords") or []
            hotwords = (
                HotwordCorrector._dedupe_phrases(raw_hotwords)
                if isinstance(raw_hotwords, list)
                else []
            )
            self._session = ActiveSession(
                request_id=request_id,
                hotwords=hotwords,
                corrector=HotwordCorrector(hotwords),
            )
            return []

        if msg_type == "audio":
            return self._handle_audio(message, defer_partial=defer_partial)

        if msg_type == "stop":
            return self._handle_stop(message)

        if msg_type == "cancel":
            request_id = str(message.get("request_id", ""))
            if self._session is not None and (
                not request_id or self._session.request_id == request_id
            ):
                self._session.clear()
                self._session = None
            return []

        if msg_type == "shutdown":
            if self._session is not None:
                self._session.clear()
                self._session = None
            return [{"type": "shutdown_ack"}]

        return [
            {
                "type": "error",
                "request_id": str(message.get("request_id", "")),
                "code": "invalid_request",
            }
        ]

    def _decode_segment(
        self,
        session: ActiveSession,
        audio: np.ndarray,
        *,
        max_tokens: int,
    ) -> str:
        raw_text = self._transcriber.transcribe(
            audio,
            hotwords=session.hotwords,
            max_tokens=max_tokens,
        )
        corrected = session.corrector.apply(raw_text)
        return sanitize_transcript(
            corrected,
            hotwords=session.hotwords,
            has_speech=True,
        )

    def _emit_partial_if_changed(
        self,
        session: ActiveSession,
        active_text: str,
    ) -> list[dict[str, Any]]:
        full_text = join_segments(session.committed_text, active_text)
        if not full_text or full_text == session.last_emitted_full_text:
            session.last_active_partial = active_text
            return []
        if not session.committed_text:
            stable, partial = split_stable_partial(
                session.last_active_partial,
                active_text,
            )
        else:
            seg_stable, _ = split_stable_partial(
                session.last_active_partial,
                active_text,
            )
            stable = (
                join_segments(session.committed_text, seg_stable)
                if seg_stable
                else session.committed_text
            )
            partial = full_text[len(stable) :]
        session.last_active_partial = active_text
        session.last_emitted_full_text = full_text
        return [
            {
                "type": "partial",
                "request_id": session.request_id,
                "stable_text": stable,
                "partial_text": partial,
                "confidence": 0.9,
            }
        ]

    def _should_commit_on_pause(self, session: ActiveSession) -> bool:
        if not session.segment_speech_detected:
            return False
        if (
            session.segment_samples >= self._segment_min_commit_samples
            and session.trailing_silence_samples
            >= self._segment_silence_commit_samples
        ):
            return True
        if (
            session.segment_samples >= self._segment_soft_max_samples
            and session.trailing_silence_samples
            >= self._segment_soft_silence_samples
        ):
            return True
        return False

    def _decode_with_retry(
        self,
        session: ActiveSession,
        audio: np.ndarray,
        *,
        stage: str,
    ) -> str | None:
        """Decode commit audio, retrying once; ``None`` when every attempt failed.

        Each failure is reported on stderr — a decode that fails is never
        silent, even when the caller recovers from it.
        """
        for attempt in range(1, SEGMENT_DECODE_ATTEMPTS + 1):
            try:
                return self._decode_segment(session, audio, max_tokens=384)
            except Exception as exc:
                _log_warning(
                    "segment_decode_failed",
                    request_id=session.request_id,
                    stage=stage,
                    attempt=attempt,
                    audio_seconds=round(audio.size / SAMPLE_RATE_HZ, 2),
                    error_type=type(exc).__name__,
                )
        return None

    def _commit_active_segment(
        self,
        session: ActiveSession,
        *,
        hard_split: bool,
    ) -> list[dict[str, Any]]:
        audio = session.segment_audio()
        if audio.size == 0 or not session.segment_speech_detected:
            session.reset_active_segment()
            return []

        if hard_split and audio.size >= self._segment_hard_max_samples:
            min_prefix = max(
                int(MIN_FINAL_AUDIO_SECONDS * SAMPLE_RATE_HZ),
                audio.size - self._segment_split_search_samples,
            )
            split_idx = _find_lowest_energy_split(
                audio,
                search_samples=self._segment_split_search_samples,
                min_prefix_samples=min_prefix,
            )
            commit_audio = audio[:split_idx]
            tail_audio = audio[split_idx:]
        else:
            commit_audio = audio
            tail_audio = None

        segment_text = self._decode_with_retry(
            session, commit_audio, stage="commit"
        )
        if segment_text is not None:
            session.segment_decode_failures = 0
            if segment_text:
                session.committed_text = join_segments(
                    session.committed_text,
                    segment_text,
                )
            session.reset_active_segment(tail=tail_audio)
            return self._emit_partial_if_changed(session, "")

        # Every attempt failed. The buffered speech is not discarded here:
        # a pause commit simply keeps it for the next pause or for the final
        # stop decode, and a hard split keeps it too as long as the engine
        # has not failed on it repeatedly.
        if not hard_split:
            return []
        session.segment_decode_failures += 1
        if session.segment_decode_failures <= SEGMENT_DECODE_FAILURE_BUDGET:
            # Keep every sample and back off, so the retry happens on fresh
            # audio at a larger split instead of on every incoming chunk.
            session.hard_split_defer_until_samples = (
                audio.size + self._segment_retry_backoff_samples
            )
            _log_warning(
                "segment_audio_preserved",
                request_id=session.request_id,
                buffered_seconds=round(audio.size / SAMPLE_RATE_HZ, 2),
                retry_in_seconds=round(
                    self._segment_retry_backoff_samples / SAMPLE_RATE_HZ, 2
                ),
                failures=session.segment_decode_failures,
            )
            return []
        # The buffer is at its ceiling and the engine has failed on it
        # SEGMENT_DECODE_ATTEMPTS × budget times: holding it any longer
        # would only grow memory for speech that cannot be decoded. The
        # last good partial is committed when there is one, the tail is
        # kept for the next segment, and the loss is reported — never
        # silent.
        segment_text = session.last_active_partial
        if segment_text:
            session.committed_text = join_segments(
                session.committed_text,
                segment_text,
            )
        session.reset_active_segment(tail=tail_audio)
        _log_warning(
            "segment_audio_dropped",
            request_id=session.request_id,
            dropped_seconds=round(commit_audio.size / SAMPLE_RATE_HZ, 2),
            committed_partial=bool(segment_text),
            failures=session.segment_decode_failures,
        )
        return self._emit_partial_if_changed(session, "")

    def _hard_split_due(self, session: ActiveSession, *, backlog: bool = False) -> bool:
        """Whether the uncommitted buffer must be hard-split now.

        Under backlog the ceiling is 1.5× (incremental work is deferred
        until the buffer is well past it). A failed split is retried once
        the buffer has grown past its retry point, in either mode.
        """
        ceiling = int(self._segment_hard_max_samples * (1.5 if backlog else 1.0))
        return session.segment_samples >= max(
            ceiling, session.hard_split_defer_until_samples
        )

    def _handle_audio(
        self,
        message: dict[str, Any],
        *,
        defer_partial: bool = False,
    ) -> list[dict[str, Any]]:
        session = self._session
        request_id = str(message.get("request_id", ""))
        if session is None or session.request_id != request_id:
            return []
        pcm_b64 = message.get("pcm_b64")
        if not isinstance(pcm_b64, str) or not pcm_b64:
            return []
        try:
            raw = base64.b64decode(pcm_b64)
        except Exception:
            return []
        if len(raw) == 0 or (len(raw) % 4) != 0:
            return []
        samples = np.frombuffer(raw, dtype="<f4").copy()
        session.append_pcm(samples)

        if not session.segment_speech_detected:
            return []

        # Under backlog (defer_partial=True), skip incremental decoding unless
        # the uncommitted buffer grew well beyond the hard segment ceiling.
        if defer_partial:
            if self._hard_split_due(session, backlog=True):
                return self._commit_active_segment(session, hard_split=True)
            return []

        if self._hard_split_due(session):
            return self._commit_active_segment(session, hard_split=True)

        if self._should_commit_on_pause(session):
            return self._commit_active_segment(session, hard_split=False)

        if (
            session.segment_samples < self._partial_min_samples
            or session.samples_since_partial < self._partial_step_samples
        ):
            return []

        session.samples_since_partial = 0
        try:
            audio = session.segment_audio()
            active_text = self._decode_segment(
                session,
                audio,
                max_tokens=256,
            )
        except Exception as exc:
            # Partial decode failure is non-fatal; wait for next chunk or
            # stop — but it is reported, never swallowed.
            _log_warning(
                "segment_decode_failed",
                request_id=session.request_id,
                stage="partial",
                attempt=1,
                audio_seconds=round(session.segment_samples / SAMPLE_RATE_HZ, 2),
                error_type=type(exc).__name__,
            )
            return []

        if not active_text:
            return []
        return self._emit_partial_if_changed(session, active_text)

    def _handle_stop(self, message: dict[str, Any]) -> list[dict[str, Any]]:
        session = self._session
        request_id = str(message.get("request_id", ""))
        if session is None or session.request_id != request_id:
            return []
        self._session = None
        try:
            final_text = session.committed_text
            audio = session.segment_audio()
            min_samples = int(MIN_FINAL_AUDIO_SECONDS * SAMPLE_RATE_HZ)
            if session.segment_speech_detected and audio.size >= min_samples:
                # If a single uncommitted buffer somehow exceeds hard max
                # (e.g. deferred chunks arrived right before stop), split into
                # bounded segments so each decode stays well within model limits.
                remaining = audio
                while remaining.size > self._segment_hard_max_samples:
                    min_prefix = max(
                        min_samples,
                        self._segment_hard_max_samples
                        - self._segment_split_search_samples,
                    )
                    split_idx = _find_lowest_energy_split(
                        remaining[: self._segment_hard_max_samples],
                        search_samples=self._segment_split_search_samples,
                        min_prefix_samples=min_prefix,
                    )
                    chunk = remaining[:split_idx]
                    remaining = remaining[split_idx:]
                    if chunk.size >= min_samples and _subframe_has_speech(chunk):
                        piece = self._decode_segment(
                            session,
                            chunk,
                            max_tokens=384,
                        )
                        if piece:
                            final_text = join_segments(final_text, piece)
                if remaining.size >= min_samples and _subframe_has_speech(remaining):
                    tail_piece = self._decode_segment(
                        session,
                        remaining,
                        max_tokens=384,
                    )
                    if tail_piece:
                        final_text = join_segments(final_text, tail_piece)

            return [
                {
                    "type": "final",
                    "request_id": request_id,
                    "text": final_text,
                    "confidence": 0.95 if final_text else 0.0,
                    "polish_applied": False,
                }
            ]
        except Exception as exc:
            # The error frame tells the client; stderr tells the operator.
            _log_warning(
                "final_decode_failed",
                request_id=request_id,
                buffered_seconds=round(session.segment_samples / SAMPLE_RATE_HZ, 2),
                committed=bool(session.committed_text),
                error_type=type(exc).__name__,
            )
            return [
                {
                    "type": "error",
                    "request_id": request_id,
                    "code": "asr_engine_error",
                }
            ]
        finally:
            session.clear()


def _emit_json(
    payload: dict[str, Any],
    writer: Callable[[str], Any] = sys.stdout.write,
    flusher: Callable[[], Any] = sys.stdout.flush,
) -> None:
    writer(json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n")
    flusher()


def resolve_default_model_dir() -> Path:
    env_dir = os.environ.get("RIMEAI_VOICE_MLX_MODEL_DIR", "").strip()
    if env_dir:
        return Path(env_dir).expanduser()
    project_root = Path(__file__).resolve().parent.parent
    return project_root / ".rimeai" / "models" / "qwen3-asr-0.6b-8bit"


def main() -> int:
    install_offline_guard()
    model_dir = resolve_default_model_dir()
    t0 = time.perf_counter()
    try:
        transcriber = MLXQwen3ASRTranscriber(model_dir)
    except Exception as exc:
        sys.stderr.write(f"qwen3_asr_worker startup failed: {type(exc).__name__}\n")
        sys.stderr.flush()
        _emit_json({"type": "startup_error", "code": "asr_engine_error"})
        return 78

    load_ms = int((time.perf_counter() - t0) * 1000)
    model_id = model_dir.name
    worker = Qwen3ASRWorker(transcriber, model_id=model_id)
    _emit_json({"type": "ready", "model_id": model_id, "load_ms": load_ms})

    stdin_fd = sys.stdin.fileno()
    while True:
        raw_line = sys.stdin.readline()
        if not raw_line:
            break
        line = raw_line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except Exception:
            _emit_json({"type": "error", "request_id": "", "code": "invalid_request"})
            continue
        if not isinstance(message, dict):
            _emit_json({"type": "error", "request_id": "", "code": "invalid_request"})
            continue
        # If more messages (e.g. newer audio chunks or a stop command) are
        # already queued on stdin, drain them first before running a partial
        # decode so stop/finalization is never delayed by stale partial work.
        has_more_input = False
        if message.get("type") == "audio":
            try:
                ready_fds, _, _ = select.select([stdin_fd], [], [], 0.0)
                has_more_input = bool(ready_fds)
            except Exception:
                has_more_input = False
        responses = worker.handle(message, defer_partial=has_more_input)
        for response in responses:
            _emit_json(response)
            if response.get("type") == "shutdown_ack":
                return 0
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
