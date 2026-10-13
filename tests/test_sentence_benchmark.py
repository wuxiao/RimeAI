import json
from pathlib import Path

import pytest

from rimeai_eval.cli import main
from rimeai_eval.command_sentence_decoder import (
    CommandSentenceDecoder,
    SentenceDecoderConfigurationError,
    SentenceDecoderProtocolError,
    SentenceSuggestion,
)
from rimeai_eval.sentence_benchmark import (
    benchmark_sentence_decoder,
    levenshtein,
    run_sentence_benchmark,
)
from rimeai_runtime.beam_decoder import (
    BeamSuggestion,
    train_beam_decoder_config,
    write_beam_config_atomic,
)
from rimeai_runtime.ngram_ranker import (
    train_ngram_model,
    write_ngram_model_atomic,
)
from rimeai_runtime.pinyin_guard import PinyinGuard


class _ScriptedDecoder:
    """Minimal stand-in for BeamSentenceDecoder with scripted suggestions."""

    def __init__(self, suggestions):
        self._suggestions = list(suggestions)
        self.calls = []

    def suggest(self, *, context, pinyin, candidates, scorer=None):
        self.calls.append(("suggest", context, pinyin, candidates, scorer))
        return self._suggestions.pop(0)

    def suggest_segments(
        self, *, context, segments, active_candidates, scorer=None
    ):
        self.calls.append(
            ("suggest_segments", context, segments, active_candidates, scorer)
        )
        return self._suggestions.pop(0)


def _sample(
    sample_id,
    split,
    context,
    gold,
    candidates,
    pinyin="mingling",
    segments=None,
):
    sample = {
        "schema_version": 1,
        "id": sample_id,
        "split": split,
        "domain": "general",
        "context": context,
        "pinyin": pinyin,
        "candidates": candidates,
        "gold_text": gold,
        "tags": [],
    }
    if segments is not None:
        sample["segments"] = segments
    return sample


def test_levenshtein_known_values():
    assert levenshtein("", "") == 0
    assert levenshtein("", "abc") == 3
    assert levenshtein("abc", "") == 3
    assert levenshtein("kitten", "sitting") == 3
    assert levenshtein("命令", "命令") == 0
    assert levenshtein("命令", "明令") == 1


def test_benchmark_counts_decisions_and_coverage():
    samples = [
        _sample(
            "sample-1",
            "test",
            "请在终端执行这条",
            "命令",
            ["命令", "明令"],
        ),
        _sample(
            "sample-2",
            "test",
            "最终",
            "结果",
            ["结国", "结果"],
        ),
        _sample(
            "sample-3",
            "test",
            "不要读取这个答案",
            "绝密",
            ["公开", "公告"],
        ),
    ]
    decoder = _ScriptedDecoder(
        [
            BeamSuggestion("命令", 0.9, 1.0, "suggestion"),
            BeamSuggestion("", 0.0, -1.0, "below_threshold"),
            BeamSuggestion("绝密", 0.2, 0.5, "suggestion"),
        ]
    )

    report = benchmark_sentence_decoder(
        samples,
        decoder,
        min_confidence=0.5,
    )

    assert report["samples"] == 3
    assert report["metrics"]["gold_in_top10_coverage"] == round(2 / 3, 6)
    assert report["metrics"]["baseline_sentence_accuracy"] == round(1 / 3, 6)
    assert (
        report["metrics"]["decoder_sentence_accuracy"] == round(1 / 3, 6)
    )
    assert report["decision_counts"] == {
        "below_threshold": 1,
        "suggestion": 2,
    }
    assert report["hyperparameters"] == {"min_confidence": 0.5}


def test_benchmark_gate_requires_confidence_and_reason():
    samples = [
        _sample(
            "sample-1",
            "test",
            "请在终端执行这条",
            "命令",
            ["明令", "命令"],
        ),
    ]
    decoder = _ScriptedDecoder(
        [BeamSuggestion("命令", 0.2, 0.5, "suggestion")]
    )

    gated = benchmark_sentence_decoder(
        samples, decoder, min_confidence=0.5
    )
    assert gated["metrics"]["decoder_sentence_accuracy"] == 0.0
    assert gated["metrics"]["decoder_char_accuracy"] == 0.5
    assert gated["metrics"]["mean_edit_distance"] == 1.0

    decoder = _ScriptedDecoder(
        [BeamSuggestion("命令", 0.9, 0.5, "below_threshold")]
    )
    fallback = benchmark_sentence_decoder(
        samples, decoder, min_confidence=0.0
    )
    assert fallback["metrics"]["decoder_sentence_accuracy"] == 0.0


def test_benchmark_uses_suggest_segments_for_multi_segment_samples():
    samples = [
        _sample(
            "sample-1",
            "test",
            "请在终端执行这条",
            "命令，",
            ["命令，", "明令，"],
            segments=[
                {
                    "pinyin": "mingling",
                    "separator": "",
                    "committed_text": "",
                },
                {
                    "pinyin": "douhao",
                    "separator": "",
                    "committed_text": "，",
                },
            ],
        ),
        _sample(
            "sample-2",
            "test",
            "最终",
            "结果",
            ["结果", "结国"],
        ),
    ]
    decoder = _ScriptedDecoder(
        [
            BeamSuggestion("命令，", 0.9, 1.0, "suggestion"),
            BeamSuggestion("结果", 0.9, 1.0, "suggestion"),
        ]
    )

    benchmark_sentence_decoder(samples, decoder)

    assert decoder.calls[0][0] == "suggest_segments"
    assert decoder.calls[1][0] == "suggest"


def test_benchmark_report_shape():
    samples = [
        _sample(
            "sample-1",
            "test",
            "请在终端执行这条",
            "命令",
            ["命令", "明令"],
        ),
        _sample(
            "sample-2",
            "test",
            "最终",
            "结果",
            ["结果", "结国"],
        ),
    ]
    decoder = _ScriptedDecoder(
        [
            BeamSuggestion("命令", 0.9, 1.0, "suggestion"),
            BeamSuggestion("", 0.0, 0.0, "no_change"),
        ]
    )

    report = run_sentence_benchmark(samples, decoder)

    assert report["schema_version"] == 1
    assert report["benchmark_type"] == "sentence-benchmark"
    assert report["samples"] == 2
    for key in (
        "baseline_sentence_accuracy",
        "decoder_sentence_accuracy",
        "baseline_char_accuracy",
        "decoder_char_accuracy",
        "gold_in_top10_coverage",
        "mean_edit_distance",
        "decoder_latency_ms",
    ):
        assert key in report["metrics"]
    assert set(report["metrics"]["decoder_latency_ms"]) == {"p50", "p95"}
    assert isinstance(report["decision_counts"], dict)
    assert report["hyperparameters"] == {"min_confidence": 0.0}
    assert not any(
        key.startswith(("neural_", "fused_"))
        for key in report["metrics"]
    )
    assert not any(
        key.startswith(("neural_", "fused_")) for key in report
    )


def test_benchmark_latency_percentiles_are_ordered():
    samples = [
        _sample(
            f"sample-{index}",
            "test",
            "请在终端执行这条",
            "命令",
            ["命令", "明令"],
        )
        for index in range(3)
    ]
    decoder = _ScriptedDecoder(
        [
            BeamSuggestion("命令", 0.9, 1.0, "suggestion")
            for _ in range(3)
        ]
    )

    report = benchmark_sentence_decoder(samples, decoder)

    latency = report["metrics"]["decoder_latency_ms"]
    assert latency["p50"] >= 0.0
    assert latency["p95"] >= latency["p50"]


def _write_cli_artifacts(tmp_path: Path):
    dictionary = tmp_path / "fixture.dict.yaml"
    dictionary.write_text(
        "---\nname: fixture\n...\n命\tming\n令\tling\n明\tming\n",
        encoding="utf-8",
    )
    rows = [
        ("train-1", "train", "请在终端执行这条"),
        ("train-2", "train", "现在运行这条"),
        ("validation-1", "validation", "执行这条"),
        ("test-1", "test", "最后执行这条"),
        ("test-2", "test", "记得执行这条"),
    ]
    samples = [
        {
            "schema_version": 1,
            "id": sample_id,
            "split": split,
            "domain": "general",
            "context": context,
            "pinyin": "mingling",
            "candidates": ["明令", "命令"],
            "gold_text": "命令",
            "tags": [],
        }
        for sample_id, split, context in rows
    ]
    dataset = tmp_path / "dataset.jsonl"
    dataset.write_text(
        "".join(
            json.dumps(sample, ensure_ascii=False) + "\n"
            for sample in samples
        ),
        encoding="utf-8",
    )
    model, _ = train_ngram_model(samples, dataset_sha256="a" * 64)
    language_model = tmp_path / "model.ngram.json.gz"
    write_ngram_model_atomic(language_model, model)
    guard = PinyinGuard.from_rime_dictionary(dictionary)
    config, _ = train_beam_decoder_config(
        samples,
        model,
        guard,
        dataset_sha256="a" * 64,
        language_model_sha256="b" * 64,
        dictionary_sha256="c" * 64,
    )
    decoder_config = tmp_path / "beam.json"
    write_beam_config_atomic(decoder_config, config)
    return dataset, language_model, decoder_config, dictionary


def test_cli_sentence_benchmark_runs(tmp_path: Path, capsys):
    dataset, language_model, decoder_config, dictionary = (
        _write_cli_artifacts(tmp_path)
    )

    exit_code = main(
        [
            "sentence-benchmark",
            str(dataset),
            "--language-model",
            str(language_model),
            "--decoder-config",
            str(decoder_config),
            "--rime-dictionary",
            str(dictionary),
        ]
    )

    assert exit_code == 0
    report = json.loads(capsys.readouterr().out)
    assert report["benchmark_type"] == "sentence-benchmark"
    assert report["samples"] == 2
    assert (
        report["metrics"]["decoder_latency_ms"]["p95"]
        >= report["metrics"]["decoder_latency_ms"]["p50"]
    )


def test_command_decoder_arm_omitted_without_flag(
    tmp_path: Path, capsys, monkeypatch
):
    dataset, language_model, decoder_config, dictionary = (
        _write_cli_artifacts(tmp_path)
    )
    base_argv = [
        "sentence-benchmark",
        str(dataset),
        "--language-model",
        str(language_model),
        "--decoder-config",
        str(decoder_config),
        "--rime-dictionary",
        str(dictionary),
    ]

    exit_code = main(base_argv)
    assert exit_code == 0
    report = json.loads(capsys.readouterr().out)
    assert not any(
        key.startswith("neural_") for key in report["metrics"]
    )

    class _FakeNeuralDecoder:
        def __enter__(self):
            return self

        def __exit__(self, *args):
            return None

        def suggest(self, sample):
            return SentenceSuggestion("命令", 0.9)

    monkeypatch.setattr(
        CommandSentenceDecoder,
        "from_config",
        lambda path: _FakeNeuralDecoder(),
    )
    neural_config = tmp_path / "neural.json"

    exit_code = main(
        [
            *base_argv,
            "--command-decoder-config",
            str(neural_config),
        ]
    )
    assert exit_code == 0
    report = json.loads(capsys.readouterr().out)
    assert report["metrics"]["neural_sentence_accuracy"] == 1.0
    assert report["metrics"]["neural_abstain_rate"] == 0.0


def test_benchmark_propagates_neural_protocol_errors():
    samples = [
        _sample(
            "sample-1",
            "test",
            "请在终端执行这条",
            "命令",
            ["命令", "明令"],
        ),
    ]
    decoder = _ScriptedDecoder(
        [BeamSuggestion("命令", 0.9, 1.0, "suggestion")]
    )

    class _FailingNeuralDecoder:
        def suggest(self, sample):
            raise SentenceDecoderProtocolError("decoder response timed out")

    with pytest.raises(SentenceDecoderProtocolError):
        run_sentence_benchmark(
            samples,
            decoder,
            command_decoder=_FailingNeuralDecoder(),
        )


def test_cli_sentence_benchmark_neural_protocol_error_exits_two(
    tmp_path: Path, capsys, monkeypatch
):
    dataset, language_model, decoder_config, dictionary = (
        _write_cli_artifacts(tmp_path)
    )

    class _FailingNeuralDecoder:
        def __enter__(self):
            return self

        def __exit__(self, *args):
            return None

        def suggest(self, sample):
            raise SentenceDecoderProtocolError("decoder response timed out")

    monkeypatch.setattr(
        CommandSentenceDecoder,
        "from_config",
        lambda path: _FailingNeuralDecoder(),
    )

    exit_code = main(
        [
            "sentence-benchmark",
            str(dataset),
            "--language-model",
            str(language_model),
            "--decoder-config",
            str(decoder_config),
            "--rime-dictionary",
            str(dictionary),
            "--command-decoder-config",
            str(tmp_path / "neural.json"),
        ]
    )

    assert exit_code == 2
    captured = capsys.readouterr()
    assert captured.out == ""
    assert captured.err.startswith("error: ")
    assert "timed out" in captured.err


def test_cli_sentence_benchmark_neural_launch_failure_exits_two(
    tmp_path: Path, capsys, monkeypatch
):
    dataset, language_model, decoder_config, dictionary = (
        _write_cli_artifacts(tmp_path)
    )

    class _UnlaunchableNeuralDecoder:
        def __enter__(self):
            raise SentenceDecoderConfigurationError(
                "cannot start decoder command"
            )

        def __exit__(self, *args):
            return None

    monkeypatch.setattr(
        CommandSentenceDecoder,
        "from_config",
        lambda path: _UnlaunchableNeuralDecoder(),
    )

    exit_code = main(
        [
            "sentence-benchmark",
            str(dataset),
            "--language-model",
            str(language_model),
            "--decoder-config",
            str(decoder_config),
            "--rime-dictionary",
            str(dictionary),
            "--command-decoder-config",
            str(tmp_path / "neural.json"),
        ]
    )

    assert exit_code == 2
    captured = capsys.readouterr()
    assert captured.out == ""
    assert captured.err.startswith("error: cannot start decoder command")
