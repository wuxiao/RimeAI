"""Unit tests for rimeai_runtime.qwen3_asr_worker."""

from __future__ import annotations

import base64
import json
import socket
import sys
import types
from collections.abc import Sequence

import numpy as np
import pytest

from rimeai_runtime.qwen3_asr_worker import (
    SAMPLE_RATE_HZ,
    SEGMENT_DECODE_ATTEMPTS,
    SEGMENT_DECODE_FAILURE_BUDGET,
    HotwordCorrector,
    MLXQwen3ASRTranscriber,
    Qwen3ASRWorker,
    _OfflineSocket,
    join_segments,
    resolve_default_model_dir,
    sanitize_transcript,
    split_stable_partial,
)


class _FakeTranscriber:
    def __init__(self, outputs: Sequence[str]) -> None:
        self._outputs = list(outputs)
        self.calls: list[tuple[int, list[str], int]] = []

    def transcribe(
        self,
        audio: np.ndarray,
        *,
        hotwords: Sequence[str],
        max_tokens: int,
    ) -> str:
        self.calls.append((int(audio.size), list(hotwords), max_tokens))
        if len(self._outputs) > 1:
            return self._outputs.pop(0)
        return self._outputs[0] if self._outputs else ""


def _speech_pcm_b64(seconds: float, amplitude: float = 0.15) -> str:
    n = int(SAMPLE_RATE_HZ * seconds)
    t = np.linspace(0.0, seconds, n, endpoint=False, dtype=np.float32)
    wave = (amplitude * np.sin(2.0 * np.pi * 440.0 * t)).astype("<f4")
    return base64.b64encode(wave.tobytes()).decode("ascii")


def _silence_pcm_b64(seconds: float) -> str:
    n = int(SAMPLE_RATE_HZ * seconds)
    wave = np.zeros(n, dtype="<f4")
    return base64.b64encode(wave.tobytes()).decode("ascii")


def test_hotword_corrector_normalizes_ascii_spacing_and_casing() -> None:
    corrector = HotwordCorrector(["RimeAI", "FastAPI", "SwiftUI"])
    result = corrector.apply("今天用 Rime AI 和 fast-api 写 swift ui 页面。")
    assert result == "今天用 RimeAI 和 FastAPI 写 SwiftUI 页面。"


def test_hotword_corrector_restores_chinese_homophones_conservatively() -> None:
    corrector = HotwordCorrector(["雾凇拼音", "特展", "人工智能"])
    # 4-char exact toneless pinyin match
    assert corrector.apply("我在测试雾松拼音输入法") == "我在测试雾凇拼音输入法"
    # 2-char exact toned pinyin match (te4 zhan3 == te4 zhan3)
    assert corrector.apply("特斩项目进度") == "特展项目进度"
    # 2-char unrelated tones with 0 shared characters must NOT be falsely rewritten
    assert corrector.apply("今天特别站得稳") == "今天特别站得稳"


def test_sanitize_transcript_strips_newlines_and_hotword_dump() -> None:
    assert sanitize_transcript("第一行\n第二行", has_speech=True) == "第一行 第二行"
    assert sanitize_transcript("幻觉文本", has_speech=False) == ""
    assert (
        sanitize_transcript(
            "RimeAI, FastAPI, 雾凇拼音, 特展",
            hotwords=["RimeAI", "FastAPI", "雾凇拼音", "特展"],
            has_speech=True,
        )
        == ""
    )


def test_split_stable_partial_tracks_common_prefix() -> None:
    assert split_stable_partial("", "我们今天") == ("", "我们今天")
    assert split_stable_partial("我们今天", "我们今天测试") == ("我们今天", "测试")
    assert split_stable_partial("我们今天测试", "我们明天测试") == ("我们", "明天测试")


def test_worker_streaming_partial_and_final_with_hotwords() -> None:
    fake = _FakeTranscriber(
        [
            "我们用 Rime AI",
            "我们用 Rime AI 和雾松拼音测试 fast api。",
        ]
    )
    worker = Qwen3ASRWorker(
        fake,
        model_id="qwen3-asr-0.6b-8bit",
        partial_min_seconds=0.5,
        partial_step_seconds=0.5,
    )

    assert worker.handle({"type": "ping"}) == [
        {"type": "pong", "model_id": "qwen3-asr-0.6b-8bit"}
    ]
    assert (
        worker.handle(
            {
                "type": "start",
                "request_id": "req-1",
                "hotwords": ["RimeAI", "雾凇拼音", "FastAPI"],
            }
        )
        == []
    )

    # First 0.3s chunk is below partial threshold
    assert (
        worker.handle(
            {
                "type": "audio",
                "request_id": "req-1",
                "pcm_b64": _speech_pcm_b64(0.3),
            }
        )
        == []
    )
    # Second 0.4s chunk crosses threshold and emits a partial delta
    partials = worker.handle(
        {
            "type": "audio",
            "request_id": "req-1",
            "pcm_b64": _speech_pcm_b64(0.4),
        }
    )
    assert len(partials) == 1
    assert partials[0]["type"] == "partial"
    assert partials[0]["stable_text"] + partials[0]["partial_text"] == "我们用 RimeAI"

    # Stop runs full-utterance final decode + Layer-2 corrector
    finals = worker.handle({"type": "stop", "request_id": "req-1"})
    assert len(finals) == 1
    assert finals[0]["type"] == "final"
    assert finals[0]["text"] == "我们用 RimeAI 和雾凇拼音测试 FastAPI。"
    assert finals[0]["confidence"] == pytest.approx(0.95)
    assert fake.calls[-1][1] == ["RimeAI", "雾凇拼音", "FastAPI"]


def test_worker_silence_returns_empty_without_calling_model() -> None:
    fake = _FakeTranscriber(["should never run"])
    worker = Qwen3ASRWorker(fake, model_id="qwen3-asr-0.6b-8bit")
    worker.handle({"type": "start", "request_id": "req-silent", "hotwords": ["RimeAI"]})
    assert (
        worker.handle(
            {
                "type": "audio",
                "request_id": "req-silent",
                "pcm_b64": _silence_pcm_b64(1.0),
            }
        )
        == []
    )
    finals = worker.handle({"type": "stop", "request_id": "req-silent"})
    assert finals == [
        {
            "type": "final",
            "request_id": "req-silent",
            "text": "",
            "confidence": 0.0,
            "polish_applied": False,
        }
    ]
    assert fake.calls == []


def test_worker_defers_partial_when_more_input_queued() -> None:
    fake = _FakeTranscriber(["延迟后的完整转写"])
    worker = Qwen3ASRWorker(
        fake,
        model_id="qwen3-asr-0.6b-8bit",
        partial_min_seconds=0.5,
        partial_step_seconds=0.5,
    )
    worker.handle({"type": "start", "request_id": "req-defer", "hotwords": []})
    # When defer_partial=True, audio is still buffered but partial decode is skipped.
    assert (
        worker.handle(
            {
                "type": "audio",
                "request_id": "req-defer",
                "pcm_b64": _speech_pcm_b64(1.0),
            },
            defer_partial=True,
        )
        == []
    )
    assert fake.calls == []

    # Stop still decodes the full buffered audio cleanly.
    finals = worker.handle({"type": "stop", "request_id": "req-defer"})
    assert len(finals) == 1
    assert finals[0]["type"] == "final"
    assert finals[0]["text"] == "延迟后的完整转写"
    assert len(fake.calls) == 1


def test_offline_socket_blocks_inet_and_allows_unix() -> None:
    with pytest.raises(PermissionError):
        _OfflineSocket(socket.AF_INET, socket.SOCK_STREAM)
    with pytest.raises(PermissionError):
        _OfflineSocket(socket.AF_INET6, socket.SOCK_STREAM)
    unix_sock = _OfflineSocket(socket.AF_UNIX, socket.SOCK_STREAM)
    unix_sock.close()


def test_sanitize_transcript_preserves_long_text_without_200_char_cap() -> None:
    long_text = "测试长文本转写" * 60  # 420 chars
    assert sanitize_transcript(long_text, has_speech=True) == long_text


def test_join_segments_adds_space_only_between_ascii_words() -> None:
    assert join_segments("第一句。", "第二句。") == "第一句。第二句。"
    assert join_segments("hello", "world") == "hello world"
    assert join_segments("测试", "RimeAI") == "测试RimeAI"


def test_worker_commits_multiple_segments_across_pauses_and_beyond_60s() -> None:
    seg1 = "第一段内容" * 30  # 150 chars
    seg2 = "第二段内容" * 30  # 150 chars (total 300 > 200)
    fake = _FakeTranscriber([seg1, seg2])
    worker = Qwen3ASRWorker(
        fake,
        model_id="qwen3-asr-0.6b-8bit",
        partial_min_seconds=10.0,
        partial_step_seconds=10.0,
        segment_min_commit_seconds=2.0,
        segment_silence_commit_seconds=0.8,
        segment_soft_max_seconds=10.0,
        segment_hard_max_seconds=15.0,
    )
    worker.handle({"type": "start", "request_id": "req-long", "hotwords": []})

    # Stream > 60 seconds total via leading silence + 2 spoken segments with pauses.
    for _ in range(30):
        worker.handle(
            {
                "type": "audio",
                "request_id": "req-long",
                "pcm_b64": _silence_pcm_b64(2.0),
            }
        )
    # Leading silence stays bounded in memory while total_samples keeps growing.
    assert worker._session is not None
    assert worker._session.total_samples == 60 * SAMPLE_RATE_HZ
    assert worker._session.segment_samples <= int(1.2 * SAMPLE_RATE_HZ)

    # Segment 1: 2.0s speech + 1.0s pause -> commits seg1 automatically
    worker.handle(
        {
            "type": "audio",
            "request_id": "req-long",
            "pcm_b64": _speech_pcm_b64(2.0),
        }
    )
    commit1 = worker.handle(
        {
            "type": "audio",
            "request_id": "req-long",
            "pcm_b64": _silence_pcm_b64(1.0),
        }
    )
    assert len(commit1) == 1
    assert commit1[0]["stable_text"] == seg1
    assert commit1[0]["partial_text"] == ""
    assert worker._session.segment_samples == 0

    # Segment 2: 2.0s speech, then stop -> commits tail and joins without truncation
    worker.handle(
        {
            "type": "audio",
            "request_id": "req-long",
            "pcm_b64": _speech_pcm_b64(2.0),
        }
    )
    finals = worker.handle({"type": "stop", "request_id": "req-long"})
    assert len(finals) == 1
    assert finals[0]["type"] == "final"
    assert finals[0]["text"] == seg1 + seg2
    assert len(finals[0]["text"]) == 300


def test_worker_hard_splits_continuous_speech_without_pauses() -> None:
    fake = _FakeTranscriber(["第一连续段。", "第二连续段。"])
    worker = Qwen3ASRWorker(
        fake,
        model_id="qwen3-asr-0.6b-8bit",
        partial_min_seconds=10.0,
        partial_step_seconds=10.0,
        segment_min_commit_seconds=2.0,
        segment_silence_commit_seconds=1.0,
        segment_soft_max_seconds=3.0,
        segment_hard_max_seconds=4.0,
        segment_split_search_seconds=1.0,
    )
    worker.handle({"type": "start", "request_id": "req-cont", "hotwords": []})

    # 3.5s continuous speech + 0.2s quiet dip + 0.5s speech = 4.2s (> hard_max 4.0s)
    worker.handle(
        {
            "type": "audio",
            "request_id": "req-cont",
            "pcm_b64": _speech_pcm_b64(3.5, amplitude=0.2),
        }
    )
    worker.handle(
        {
            "type": "audio",
            "request_id": "req-cont",
            "pcm_b64": _speech_pcm_b64(0.2, amplitude=0.02),
        }
    )
    split_events = worker.handle(
        {
            "type": "audio",
            "request_id": "req-cont",
            "pcm_b64": _speech_pcm_b64(0.5, amplitude=0.2),
        }
    )
    assert len(split_events) == 1
    assert split_events[0]["stable_text"] == "第一连续段。"
    assert worker._session is not None
    assert worker._session.segment_samples > 0

    finals = worker.handle({"type": "stop", "request_id": "req-cont"})
    assert finals[0]["text"] == "第一连续段。第二连续段。"


# --------------------------------------------------------------------------
# Decode failures: reported on stderr, never silently discarding speech.


class _ScriptedTranscriber:
    """Raises or answers per call; the last outcome repeats."""

    def __init__(self, outcomes: Sequence[object]) -> None:
        self._outcomes = list(outcomes)
        self.calls: list[int] = []

    def transcribe(
        self,
        audio: np.ndarray,
        *,
        hotwords: Sequence[str],
        max_tokens: int,
    ) -> str:
        self.calls.append(int(audio.size))
        outcome = (
            self._outcomes.pop(0) if len(self._outcomes) > 1 else self._outcomes[0]
        )
        if isinstance(outcome, BaseException):
            raise outcome
        return str(outcome)


def _diagnostics(capsys: pytest.CaptureFixture) -> list[dict]:
    return [
        json.loads(line)
        for line in capsys.readouterr().err.splitlines()
        if line.startswith("{")
    ]


def _events(diagnostics: list[dict], event: str) -> list[dict]:
    return [entry for entry in diagnostics if entry["event"] == event]


def _audio(worker: Qwen3ASRWorker, request_id: str, pcm_b64: str) -> list[dict]:
    return worker.handle(
        {"type": "audio", "request_id": request_id, "pcm_b64": pcm_b64}
    )


def _hard_split_worker(fake: _ScriptedTranscriber) -> Qwen3ASRWorker:
    # Same shape as the hard-split scenario above: a 4 s ceiling, no
    # incremental partials, a 1 s split search and the 2 s retry backoff.
    return Qwen3ASRWorker(
        fake,
        model_id="qwen3-asr-0.6b-8bit",
        partial_min_seconds=10.0,
        partial_step_seconds=10.0,
        segment_min_commit_seconds=2.0,
        segment_silence_commit_seconds=1.0,
        segment_soft_max_seconds=3.0,
        segment_hard_max_seconds=4.0,
        segment_split_search_seconds=1.0,
    )


def _cross_the_hard_ceiling(worker: Qwen3ASRWorker, request_id: str) -> list[dict]:
    # 3.5 s speech + 0.2 s quiet dip + 0.5 s speech = 4.2 s (> 4.0 s).
    for seconds, amplitude in ((3.5, 0.2), (0.2, 0.02)):
        assert _audio(
            worker, request_id, _speech_pcm_b64(seconds, amplitude=amplitude)
        ) == []
    return _audio(worker, request_id, _speech_pcm_b64(0.5, amplitude=0.2))


def test_hard_split_decode_failure_is_retried_before_it_counts(capsys):
    fake = _ScriptedTranscriber(
        [RuntimeError("metal hiccup"), "第一连续段。", "第二连续段。"]
    )
    worker = _hard_split_worker(fake)
    worker.handle({"type": "start", "request_id": "req-retry", "hotwords": []})

    events = _cross_the_hard_ceiling(worker, "req-retry")

    assert len(events) == 1
    assert events[0]["stable_text"] == "第一连续段。"
    finals = worker.handle({"type": "stop", "request_id": "req-retry"})
    assert finals[0]["text"] == "第一连续段。第二连续段。"
    # The retry decoded the very same audio, so nothing was lost.
    assert fake.calls[0] == fake.calls[1]
    failed = _events(_diagnostics(capsys), "segment_decode_failed")
    assert len(failed) == 1
    assert failed[0]["level"] == "warning"
    assert failed[0]["stage"] == "commit"
    assert failed[0]["attempt"] == 1
    assert failed[0]["request_id"] == "req-retry"
    assert failed[0]["error_type"] == "RuntimeError"
    # The engine's message never reaches the log: shapes only.
    assert "metal hiccup" not in json.dumps(failed[0])


def test_hard_split_decode_failure_preserves_the_buffered_speech(capsys):
    # 回归：硬切分解码失败时，旧实现提交上一条 partial 并把未解码的
    # commit_audio 直接丢掉——用户中途说的话就没了。现在音频留在缓冲
    # 里，退避后在更大的切分点上重试，整段语音仍被解码出来。
    fake = _ScriptedTranscriber(
        [RuntimeError("boom"), RuntimeError("boom"), "第一连续段。", "第二连续段。"]
    )
    worker = _hard_split_worker(fake)
    worker.handle({"type": "start", "request_id": "req-keep", "hotwords": []})

    assert _cross_the_hard_ceiling(worker, "req-keep") == []

    session = worker._session
    assert session is not None
    buffered = session.segment_samples
    assert buffered == 67200  # the whole 4.2 s buffer is still there
    assert session.committed_text == ""
    assert session.segment_decode_failures == 1
    # The retry is due after 2 s of fresh audio, not on the next chunk.
    assert session.hard_split_defer_until_samples == buffered + 2 * SAMPLE_RATE_HZ
    kept = _events(_diagnostics(capsys), "segment_audio_preserved")
    assert len(kept) == 1
    assert kept[0]["failures"] == 1
    assert kept[0]["buffered_seconds"] == pytest.approx(4.2)
    assert kept[0]["retry_in_seconds"] == pytest.approx(2.0)

    # 1.2 s more speech is still inside the backoff window: no decode at all.
    assert _audio(worker, "req-keep", _speech_pcm_b64(1.2)) == []
    assert len(fake.calls) == SEGMENT_DECODE_ATTEMPTS
    # A quiet dip followed by 0.8 s speech crosses the retry point; the
    # split lands in the dip, so everything before it is the commit.
    assert _audio(worker, "req-keep", _speech_pcm_b64(0.2, amplitude=0.02)) == []
    events = _audio(worker, "req-keep", _speech_pcm_b64(0.8))
    assert events[0]["stable_text"] == "第一连续段。"
    # The successful attempt decoded the preserved buffer (>= 5.2 s of
    # audio), not just the 2.2 s that arrived after the failure.
    assert fake.calls[SEGMENT_DECODE_ATTEMPTS] >= int(5.2 * SAMPLE_RATE_HZ)
    assert session.segment_decode_failures == 0
    assert session.hard_split_defer_until_samples == 0
    finals = worker.handle({"type": "stop", "request_id": "req-keep"})
    assert finals[0]["text"] == "第一连续段。第二连续段。"
    assert _events(_diagnostics(capsys), "segment_audio_dropped") == []


def test_persistent_hard_split_failure_releases_the_buffer_loudly(capsys):
    # 引擎持续失败时不能无限占用内存：宽限次数用尽后才释放缓冲，且
    # 释放必须带显式诊断，而不是悄悄丢掉语音。
    fake = _ScriptedTranscriber([RuntimeError("engine down")])
    worker = _hard_split_worker(fake)
    worker.handle({"type": "start", "request_id": "req-drop", "hotwords": []})

    # Failure 1: preserved.
    assert _cross_the_hard_ceiling(worker, "req-drop") == []
    session = worker._session
    assert session is not None
    assert session.segment_samples == 67200
    # Inside the backoff window nothing is re-attempted.
    assert _audio(worker, "req-drop", _speech_pcm_b64(1.2)) == []
    assert len(fake.calls) == SEGMENT_DECODE_ATTEMPTS
    # Failure 2 (+1.0 s reaches the retry point): still preserved.
    assert _audio(worker, "req-drop", _speech_pcm_b64(1.0)) == []
    assert session.segment_decode_failures == 2
    assert session.segment_samples == 102400
    # Failure 3 (+2.0 s reaches the new retry point): the budget is spent.
    assert _audio(worker, "req-drop", _speech_pcm_b64(2.0)) == []
    assert session.segment_decode_failures == SEGMENT_DECODE_FAILURE_BUDGET + 1
    # Only the tail after the split point is kept.
    assert 0 <= session.segment_samples <= SAMPLE_RATE_HZ
    assert session.hard_split_defer_until_samples == 0
    assert session.committed_text == ""

    diagnostics = _diagnostics(capsys)
    assert len(_events(diagnostics, "segment_decode_failed")) == 3 * SEGMENT_DECODE_ATTEMPTS
    assert [entry["failures"] for entry in _events(diagnostics, "segment_audio_preserved")] == [1, 2]
    dropped = _events(diagnostics, "segment_audio_dropped")
    assert len(dropped) == 1
    assert dropped[0]["failures"] == SEGMENT_DECODE_FAILURE_BUDGET + 1
    # 8.4 s buffered, the split search covers the last second.
    assert dropped[0]["dropped_seconds"] >= 7.4
    assert dropped[0]["committed_partial"] is False
    assert dropped[0]["level"] == "warning"


def test_pause_commit_decode_failure_keeps_the_buffer_for_the_next_pause(capsys):
    fake = _ScriptedTranscriber(
        [RuntimeError("hiccup"), RuntimeError("hiccup"), "第一段", "第二段"]
    )
    worker = Qwen3ASRWorker(
        fake,
        model_id="qwen3-asr-0.6b-8bit",
        partial_min_seconds=10.0,
        partial_step_seconds=10.0,
        segment_min_commit_seconds=2.0,
        segment_silence_commit_seconds=0.8,
        segment_soft_max_seconds=10.0,
        segment_hard_max_seconds=15.0,
    )
    worker.handle({"type": "start", "request_id": "req-pause", "hotwords": []})
    assert _audio(worker, "req-pause", _speech_pcm_b64(2.0)) == []

    # 2.0 s speech + 1.0 s pause asks for a commit; both attempts fail.
    assert _audio(worker, "req-pause", _silence_pcm_b64(1.0)) == []
    session = worker._session
    assert session is not None
    assert session.segment_samples == 3 * SAMPLE_RATE_HZ  # untouched
    assert session.committed_text == ""
    assert len(fake.calls) == SEGMENT_DECODE_ATTEMPTS
    assert fake.calls[0] == fake.calls[1] == 3 * SAMPLE_RATE_HZ

    # The next pause re-attempts the same buffered speech and succeeds,
    # committing all 4 s of it; nothing of the buffer is left behind.
    events = _audio(worker, "req-pause", _silence_pcm_b64(1.0))
    assert events[0]["stable_text"] == "第一段"
    assert fake.calls[SEGMENT_DECODE_ATTEMPTS] == 4 * SAMPLE_RATE_HZ
    assert session.segment_samples == 0
    assert _audio(worker, "req-pause", _speech_pcm_b64(1.0)) == []
    finals = worker.handle({"type": "stop", "request_id": "req-pause"})
    assert finals[0]["text"] == "第一段第二段"
    failed = _events(_diagnostics(capsys), "segment_decode_failed")
    assert [entry["attempt"] for entry in failed] == [1, 2]
    assert all(entry["stage"] == "commit" for entry in failed)


def test_partial_decode_failure_is_reported_and_non_fatal(capsys):
    fake = _ScriptedTranscriber([RuntimeError("partial boom"), "延迟后的完整转写"])
    worker = Qwen3ASRWorker(
        fake,
        model_id="qwen3-asr-0.6b-8bit",
        partial_min_seconds=0.5,
        partial_step_seconds=0.5,
    )
    worker.handle({"type": "start", "request_id": "req-partial", "hotwords": []})

    assert _audio(worker, "req-partial", _speech_pcm_b64(1.0)) == []

    failed = _events(_diagnostics(capsys), "segment_decode_failed")
    assert failed == [
        {
            "ts": failed[0]["ts"],
            "level": "warning",
            "event": "segment_decode_failed",
            "request_id": "req-partial",
            "stage": "partial",
            "attempt": 1,
            "audio_seconds": 1.0,
            "error_type": "RuntimeError",
        }
    ]
    finals = worker.handle({"type": "stop", "request_id": "req-partial"})
    assert finals[0]["text"] == "延迟后的完整转写"


def test_final_decode_failure_is_reported_alongside_the_error_frame(capsys):
    fake = _ScriptedTranscriber([RuntimeError("dead")])
    worker = Qwen3ASRWorker(fake, model_id="qwen3-asr-0.6b-8bit")
    worker.handle({"type": "start", "request_id": "req-final", "hotwords": []})
    assert _audio(worker, "req-final", _speech_pcm_b64(1.0)) == []

    finals = worker.handle({"type": "stop", "request_id": "req-final"})

    assert finals == [
        {"type": "error", "request_id": "req-final", "code": "asr_engine_error"}
    ]
    failed = _events(_diagnostics(capsys), "final_decode_failed")
    assert len(failed) == 1
    assert failed[0]["error_type"] == "RuntimeError"
    assert failed[0]["buffered_seconds"] == 1.0
    assert failed[0]["committed"] is False


class _SttModule(types.ModuleType):
    """Stand-in for ``mlx_audio.stt`` with the model loader replaced."""

    def __init__(self, model) -> None:
        super().__init__("mlx_audio.stt")
        self.load = lambda path: model


class _MlxAudioModule(types.ModuleType):
    """Stand-in for the ``mlx_audio`` package, exposing ``.stt``."""

    def __init__(self, stt: _SttModule) -> None:
        super().__init__("mlx_audio")
        self.stt = stt


def _install_mlx_audio_stub(monkeypatch: pytest.MonkeyPatch, model) -> None:
    # importlib resolves "mlx_audio.stt" straight from sys.modules, so
    # the worker's by-name import needs nothing but these two entries.
    stt = _SttModule(model)
    monkeypatch.setitem(sys.modules, "mlx_audio", _MlxAudioModule(stt))
    monkeypatch.setitem(sys.modules, "mlx_audio.stt", stt)


def test_warmup_failure_is_logged_instead_of_swallowed(
    tmp_path, monkeypatch, capsys
):
    # 回归：warmup 用 250 ms 静音预热 Metal 内核，失败只意味着首句慢
    # ——但旧实现的 `except Exception: pass` 让“模型根本解不了码”完全
    # 不可见。现在它是一条结构化 stderr 警告（输入是静音，不含用户
    # 数据，所以可以带上错误原因）。
    class ExplodingModel:
        def generate(self, audio, **kwargs):
            raise RuntimeError("metal kernel   boom\nline two")

    _install_mlx_audio_stub(monkeypatch, ExplodingModel())

    transcriber = MLXQwen3ASRTranscriber(tmp_path)

    assert isinstance(transcriber._model, ExplodingModel)
    diagnostics = _diagnostics(capsys)
    assert len(diagnostics) == 1
    assert diagnostics[0]["level"] == "warning"
    assert diagnostics[0]["event"] == "warmup_failed"
    assert diagnostics[0]["error_type"] == "RuntimeError"
    # One bounded line, whitespace collapsed.
    assert diagnostics[0]["error"] == "metal kernel boom line two"


def test_warmup_failure_message_is_bounded(tmp_path, monkeypatch, capsys):
    class LoudModel:
        def generate(self, audio, **kwargs):
            raise RuntimeError("x" * 5000)

    _install_mlx_audio_stub(monkeypatch, LoudModel())

    MLXQwen3ASRTranscriber(tmp_path)

    (diagnostic,) = _diagnostics(capsys)
    assert len(diagnostic["error"]) == 200


def test_warmup_runs_once_on_silence_and_stays_quiet(tmp_path, monkeypatch, capsys):
    calls: list[tuple[int, dict]] = []

    class QuietModel:
        def generate(self, audio, **kwargs):
            calls.append((int(audio.size), kwargs))
            return types.SimpleNamespace(text="")

    _install_mlx_audio_stub(monkeypatch, QuietModel())

    transcriber = MLXQwen3ASRTranscriber(tmp_path)

    assert transcriber.model_dir == tmp_path
    assert calls == [
        (int(SAMPLE_RATE_HZ * 0.25), {"max_tokens": 8, "temperature": 0.0})
    ]
    assert _diagnostics(capsys) == []


def test_resolve_default_model_dir_shared_hf_and_legacy_priority(tmp_path):
    fake_home = tmp_path / "home"
    fake_project = tmp_path / "project"
    legacy_dir = fake_project / ".rimeai" / "models" / "qwen3-asr-0.6b-8bit"
    legacy_dir.mkdir(parents=True)

    # 1. Falls back to legacy repo path when neither shared nor HF cache exists
    assert (
        resolve_default_model_dir(
            env={},
            home_dir=fake_home,
            project_root=fake_project,
        )
        == legacy_dir
    )

    # 2. Incomplete HF cache stub (refs/main without config.json) is ignored
    hf_repo = (
        fake_home
        / ".cache"
        / "huggingface"
        / "hub"
        / "models--mlx-community--Qwen3-ASR-0.6B-8bit"
    )
    (hf_repo / "refs").mkdir(parents=True)
    (hf_repo / "refs" / "main").write_text("deadbeef\n", encoding="utf-8")
    assert (
        resolve_default_model_dir(
            env={},
            home_dir=fake_home,
            project_root=fake_project,
        )
        == legacy_dir
    )

    # 3. Valid HF snapshot (with config.json) wins over legacy repo path
    hf_snapshot = hf_repo / "snapshots" / "deadbeef"
    hf_snapshot.mkdir(parents=True)
    (hf_snapshot / "config.json").write_text("{}", encoding="utf-8")
    assert (
        resolve_default_model_dir(
            env={},
            home_dir=fake_home,
            project_root=fake_project,
        )
        == hf_snapshot
    )

    # 4. Shared ~/Models/qwen3-asr-0.6b-8bit wins over HF cache
    shared_dir = fake_home / "Models" / "qwen3-asr-0.6b-8bit"
    shared_dir.mkdir(parents=True)
    assert (
        resolve_default_model_dir(
            env={},
            home_dir=fake_home,
            project_root=fake_project,
        )
        == shared_dir
    )

    # 5. AI_MODELS_HOME overrides ~/Models
    custom_home = tmp_path / "external-models"
    custom_shared = custom_home / "qwen3-asr-0.6b-8bit"
    custom_shared.mkdir(parents=True)
    assert (
        resolve_default_model_dir(
            env={"AI_MODELS_HOME": str(custom_home)},
            home_dir=fake_home,
            project_root=fake_project,
        )
        == custom_shared
    )

    # 6. RIMEAI_VOICE_MLX_MODEL_DIR has highest precedence
    explicit = tmp_path / "explicit-model"
    assert (
        resolve_default_model_dir(
            env={
                "RIMEAI_VOICE_MLX_MODEL_DIR": str(explicit),
                "AI_MODELS_HOME": str(custom_home),
            },
            home_dir=fake_home,
            project_root=fake_project,
        )
        == explicit
    )
