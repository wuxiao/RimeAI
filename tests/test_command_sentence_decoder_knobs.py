"""CommandSentenceDecoder：stats 旋钮与 confidence_caliber 透出（C-F6）。

reveal C-F6：评测侧只取 stats.confidence_raw，丢弃 worker 回传的
user_lm_weight/length_penalty，口径标记也无处可查——λ 扫描的“哪个
旋钮生效了”只能靠人工核对 shell 环境。现在旋钮与口径透出进
SentenceSuggestion → details 行（effective_knobs）与汇总报告；
旧 worker（无 stats、无标记）保持兼容（None，不崩）。
"""

import json
import sys
import textwrap
from pathlib import Path

from rimeai_eval.command_sentence_decoder import (
    CommandSentenceDecoder,
    SentenceSuggestion,
)
from rimeai_eval.sentence_evaluation import evaluate_sentence_dataset
from rimeai_runtime.pinyin_guard import PinyinGuard


def _write_worker(
    directory: Path, *, stats: dict | None, caliber: object
) -> Path:
    script = directory / "worker.py"
    script.write_text(
        textwrap.dedent(
            f"""
            import json, sys
            for line in sys.stdin:
                request = json.loads(line)
                response = {{
                    "schema_version": 1,
                    "request_id": request["request_id"],
                    "suggestion": "",
                    "confidence": 0.0,
                    "model_artifact_id": "stub:knobs",
                }}
                extras = json.loads({json.dumps(json.dumps({"stats": stats, "caliber": caliber}))})
                if extras["stats"] is not None:
                    response["stats"] = extras["stats"]
                if extras["caliber"] is not None:
                    response["confidence_caliber"] = extras["caliber"]
                sys.stdout.write(json.dumps(response) + "\\n")
                sys.stdout.flush()
            """
        ),
        encoding="utf-8",
    )
    return script


def _decoder(tmp_path: Path, script: Path) -> CommandSentenceDecoder:
    config = tmp_path / "decoder.json"
    config.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "name": "stub",
                "command": [sys.executable, str(script)],
                "timeout_ms": 10_000,
            }
        ),
        encoding="utf-8",
    )
    return CommandSentenceDecoder.from_config(config)


_SAMPLE = {
    "id": "s1",
    "split": "test",
    "domain": "general",
    "tags": [],
    "context": "",
    "pinyin": "nihao",
    "candidates": ["你好"],
    "gold_text": "你好",
}


def test_suggest_surfaces_knobs_and_caliber_from_stats(tmp_path: Path):
    script = _write_worker(
        tmp_path,
        stats={
            "confidence_raw": 0.02,
            "user_lm_weight": 0.35,
            "length_penalty": 0.5,
        },
        caliber="mask-renormalized-geometric-mean",
    )
    with _decoder(tmp_path, script) as decoder:
        suggestion = decoder.suggest(dict(_SAMPLE))
    assert suggestion.confidence_caliber == "mask-renormalized-geometric-mean"
    assert suggestion.user_lm_weight == 0.35
    assert suggestion.length_penalty == 0.5
    assert suggestion.raw_confidence == 0.02


def test_suggest_tolerates_legacy_response_without_stats(tmp_path: Path):
    # 旧 worker 产物：无 stats、无口径标记——None 字段，不崩。
    script = _write_worker(tmp_path, stats=None, caliber=None)
    with _decoder(tmp_path, script) as decoder:
        suggestion = decoder.suggest(dict(_SAMPLE))
    assert suggestion.confidence_caliber is None
    assert suggestion.user_lm_weight is None
    assert suggestion.length_penalty is None
    assert suggestion.raw_confidence is None


def test_suggest_ignores_non_finite_knob_values(tmp_path: Path):
    # 非法旋钮值（NaN/字符串）按缺失处理，不进 details。
    script = _write_worker(
        tmp_path,
        stats={"confidence_raw": 0.02, "user_lm_weight": "oops", "length_penalty": "nan"},
        caliber=42,
    )
    with _decoder(tmp_path, script) as decoder:
        suggestion = decoder.suggest(dict(_SAMPLE))
    assert suggestion.user_lm_weight is None
    assert suggestion.length_penalty is None
    assert suggestion.confidence_caliber is None


# --------------------------------------------------------------------------
# 报告侧：details 行 effective_knobs + 汇总报告口径/旋钮。


class _FakeDecoder(CommandSentenceDecoder):
    # 子类化而非鸭子替身：与 evaluate_sentence_dataset 的参数类型真
    # 兼容（不经过 __init__，只装配被用到的表面）。

    def __init__(self, suggestion: SentenceSuggestion) -> None:
        self.name = "fake"
        self.model_artifact_id = "stub:knobs"
        self.cold_start_ms = None
        self.peak_rss_bytes = None
        self._suggestion = suggestion
        self.attempted_samples = 0
        self.successful_samples = 0
        self.attempt_latencies_ms = []

    def suggest(self, sample):
        self.attempted_samples += 1
        self.successful_samples += 1
        self.attempt_latencies_ms.append(1.0)
        return self._suggestion


def _guard() -> PinyinGuard:
    return PinyinGuard({"你": frozenset({"ni"}), "好": frozenset({"hao"})})


def test_details_rows_and_report_carry_effective_knobs():
    decoder = _FakeDecoder(
        SentenceSuggestion(
            "",
            0.0,
            0.02,
            confidence_caliber="mask-renormalized-geometric-mean",
            user_lm_weight=0.35,
            length_penalty=0.5,
        )
    )
    details: list[dict] = []
    report = evaluate_sentence_dataset(
        [dict(_SAMPLE)],
        decoder,
        _guard(),
        split="test",
        details=details,
    )
    assert details[0]["effective_knobs"] == {
        "user_lm_weight": 0.35,
        "length_penalty": 0.5,
    }
    assert details[0]["confidence_caliber"] == "mask-renormalized-geometric-mean"
    assert report["decoder"]["effective_knobs"] == {
        "user_lm_weight": 0.35,
        "length_penalty": 0.5,
    }
    assert (
        report["decoder"]["confidence_caliber"]
        == "mask-renormalized-geometric-mean"
    )


def test_details_rows_without_knobs_stay_compatible():
    # 旧 worker（无 stats）：details 里旋钮为 None、口径为 None，
    # 汇总报告省略该节——旧产物读取方不受影响。
    decoder = _FakeDecoder(SentenceSuggestion("", 0.0))
    details: list[dict] = []
    report = evaluate_sentence_dataset(
        [dict(_SAMPLE)],
        decoder,
        _guard(),
        split="test",
        details=details,
    )
    assert details[0]["effective_knobs"] == {
        "user_lm_weight": None,
        "length_penalty": None,
    }
    assert details[0]["confidence_caliber"] is None
    assert "effective_knobs" not in report["decoder"]
    assert "confidence_caliber" not in report["decoder"]


def test_report_marks_mixed_knobs_across_samples():
    # 理论上逐样本旋钮可变（如 worker 重启换配置）：汇总报告列出
    # 观测到的不同值，而不是静默取最后一个。
    first = SentenceSuggestion(
        "", 0.0, 0.01, user_lm_weight=0.1, length_penalty=0.0
    )
    second = SentenceSuggestion(
        "", 0.0, 0.02, user_lm_weight=0.35, length_penalty=0.0
    )
    decoder = _FakeDecoder(first)

    def alternate(sample):
        decoder.attempted_samples += 1
        decoder.successful_samples += 1
        decoder.attempt_latencies_ms.append(1.0)
        return second if decoder.attempted_samples % 2 == 0 else first

    decoder.suggest = alternate  # type: ignore[method-assign]
    report = evaluate_sentence_dataset(
        [dict(_SAMPLE), dict(_SAMPLE, id="s2")],
        decoder,
        _guard(),
        split="test",
    )
    assert report["decoder"]["effective_knobs"]["user_lm_weight"] == [0.1, 0.35]
    assert report["decoder"]["effective_knobs"]["length_penalty"] == 0.0
