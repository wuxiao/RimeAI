from pathlib import Path
import math

import pytest

from rimeai_runtime.beam_decoder import (
    BeamDecoderConfig,
    BeamSentenceDecoder,
    SegmentDecodeInput,
    train_beam_decoder_config,
)
from rimeai_runtime.ngram_ranker import train_ngram_model
from rimeai_runtime.pinyin_guard import PinyinGuard


def _sample(
    sample_id: str,
    split: str,
    context: str,
    gold: str,
    candidates: list[str],
) -> dict:
    return {
        "schema_version": 1,
        "id": sample_id,
        "split": split,
        "domain": "developer",
        "context": context,
        "pinyin": "mingling",
        "candidates": candidates,
        "gold_text": gold,
        "tags": ["long-input"],
    }


def _guard(tmp_path: Path) -> PinyinGuard:
    dictionary = tmp_path / "fixture.dict.yaml"
    dictionary.write_text(
        "---\nname: fixture\n...\n"
        "命\tming\n明\tming\n令\tling\n是\tshi\n时\tshi\n",
        encoding="utf-8",
    )
    return PinyinGuard.from_rime_dictionary(dictionary)


def _language_model():
    samples = [
        _sample(
            "train-1",
            "train",
            "请在终端执行这条",
            "命令",
            ["明令", "命令"],
        ),
        _sample(
            "train-2",
            "train",
            "现在运行这条",
            "命令",
            ["明令", "命令"],
        ),
        _sample(
            "validation-ranker",
            "validation",
            "执行这条",
            "命令",
            ["明令", "命令"],
        ),
    ]
    model, _ = train_ngram_model(samples, dataset_sha256="d" * 64)
    return model


def test_beam_decoder_generates_only_a_dictionary_pinyin_path(
    tmp_path: Path,
):
    decoder = BeamSentenceDecoder(
        _language_model(),
        _guard(tmp_path),
        BeamDecoderConfig(
            threshold=0.0,
            beam_width=16,
            characters_per_syllable=20,
            language_model_sha256="a" * 64,
            dictionary_sha256="b" * 64,
            dataset_sha256="c" * 64,
        ),
    )

    result = decoder.suggest(
        context="请执行这条",
        pinyin="mingling",
        candidates=["明令", "命令"],
    )

    assert result.text == "命令"
    assert _guard(tmp_path).matches(result.text, "mingling")
    assert 0 <= result.confidence <= 1


def test_beam_decoder_uses_a_full_input_candidate_when_first_is_partial(
    tmp_path: Path,
):
    decoder = BeamSentenceDecoder(
        _language_model(),
        _guard(tmp_path),
        BeamDecoderConfig(
            threshold=0.0,
            beam_width=16,
            characters_per_syllable=20,
            language_model_sha256="a" * 64,
            dictionary_sha256="b" * 64,
            dataset_sha256="c" * 64,
        ),
    )

    result = decoder.suggest(
        context="请执行这条",
        pinyin="mingling",
        candidates=["明", "明令", "命令"],
    )

    assert result.text == "命令"
    assert result.reason == "suggestion"


def test_beam_decoder_generates_a_sentence_for_abbreviated_pinyin(
    tmp_path: Path,
):
    decoder = BeamSentenceDecoder(
        _language_model(),
        _guard(tmp_path),
        BeamDecoderConfig(
            threshold=0.0,
            beam_width=16,
            characters_per_syllable=20,
            language_model_sha256="a" * 64,
            dictionary_sha256="b" * 64,
            dataset_sha256="c" * 64,
        ),
    )

    result = decoder.suggest(
        context="请执行这条",
        pinyin="ml",
        candidates=["明令", "命令"],
    )

    assert result.text == "命令"
    assert result.reason == "suggestion"
    assert _guard(tmp_path).matches(result.text, "ml")


def test_beam_decoder_reports_inputs_beyond_the_validated_sentence_limit(
    tmp_path: Path,
):
    decoder = BeamSentenceDecoder(
        _language_model(),
        _guard(tmp_path),
        BeamDecoderConfig(
            threshold=0.0,
            beam_width=16,
            characters_per_syllable=20,
            language_model_sha256="a" * 64,
            dictionary_sha256="b" * 64,
            dataset_sha256="c" * 64,
        ),
    )

    result = decoder.suggest(
        context="长句测试",
        pinyin="shi" * 31,
        candidates=["是" * 31, "时" * 31],
    )

    assert result.text == ""
    assert result.reason == "too_long"


def _decoder(tmp_path: Path, threshold: float = 0.0) -> BeamSentenceDecoder:
    return BeamSentenceDecoder(
        _language_model(),
        _guard(tmp_path),
        BeamDecoderConfig(
            threshold=threshold,
            beam_width=16,
            characters_per_syllable=20,
            language_model_sha256="a" * 64,
            dictionary_sha256="b" * 64,
            dataset_sha256="c" * 64,
        ),
    )


class _RecordingDecoder(BeamSentenceDecoder):
    def __init__(self, language_model, guard, config):
        super().__init__(language_model, guard, config)
        self.calls: list[tuple[str, str, list[str]]] = []

    def suggest(self, *, context, pinyin, candidates):
        self.calls.append((context, pinyin, list(candidates)))
        return super().suggest(
            context=context, pinyin=pinyin, candidates=candidates
        )


def test_suggest_segments_decodes_each_segment_with_accumulated_context(
    tmp_path: Path,
):
    decoder = _RecordingDecoder(
        _language_model(),
        _guard(tmp_path),
        BeamDecoderConfig(
            threshold=0.0,
            beam_width=16,
            characters_per_syllable=20,
            language_model_sha256="a" * 64,
            dictionary_sha256="b" * 64,
            dataset_sha256="c" * 64,
        ),
    )

    result = decoder.suggest_segments(
        context="请执行这条",
        segments=[
            SegmentDecodeInput(
                pinyin="mingling", separator="，", committed_text="明令"
            ),
            SegmentDecodeInput(pinyin="shi", separator="", committed_text=""),
        ],
        active_candidates=["是", "时"],
    )

    assert decoder.calls[0] == ("请执行这条", "mingling", ["明令"])
    assert decoder.calls[1] == ("请执行这条命令，", "shi", ["是", "时"])
    assert result.text == "命令，时"
    assert result.reason == "suggestion"
    assert result.confidence == pytest.approx(0.5)
    assert _guard(tmp_path).matches(
        result.text.replace("，", ""), "minglingshi"
    )


def test_suggest_segments_falls_back_to_committed_text(tmp_path: Path):
    decoder = _decoder(tmp_path)

    result = decoder.suggest_segments(
        context="请执行这条",
        segments=[
            SegmentDecodeInput(
                pinyin="mingling", separator="，", committed_text="执行"
            ),
            SegmentDecodeInput(pinyin="shi", separator="", committed_text=""),
        ],
        active_candidates=["是", "时"],
    )

    assert result.text == "执行，时"
    assert result.reason == "suggestion"
    assert 0 <= result.confidence <= 1


def test_suggest_segments_min_confidence_gates_joined_sentence(
    tmp_path: Path,
):
    decoder = _decoder(tmp_path, threshold=100.0)

    result = decoder.suggest_segments(
        context="请执行这条",
        segments=[
            SegmentDecodeInput(
                pinyin="mingling", separator="，", committed_text="明令"
            ),
            SegmentDecodeInput(pinyin="shi", separator="", committed_text=""),
        ],
        active_candidates=["是", "时"],
    )

    assert result.text == ""
    assert result.reason == "below_threshold"


def test_suggest_segments_reports_overlength_joined_sentence(
    tmp_path: Path,
):
    decoder = _decoder(tmp_path)
    long_pinyin = "shi" * 20

    result = decoder.suggest_segments(
        context="长句测试",
        segments=[
            SegmentDecodeInput(
                pinyin=long_pinyin, separator="，", committed_text="时" * 20
            ),
            SegmentDecodeInput(pinyin=long_pinyin, separator="", committed_text=""),
        ],
        active_candidates=["时" * 20, "是" * 20],
    )

    assert result.text == ""
    assert result.reason == "too_long"


class _ProMingScorer:
    """Adjudication-only scorer: loves 命, hates everything else."""

    max_context_characters = 40

    def next_char_log_prob(self, context: str, character: str) -> float:
        return math.log(0.999999) if character == "命" else math.log(1e-300)

    def character_frequency(self, character: str) -> int:
        return 0


def test_suggest_accepts_custom_scorer(tmp_path: Path):
    from rimeai_runtime.lm_fusion import StaticCharLM

    model = _language_model()
    decoder = _decoder(tmp_path)

    default = decoder.suggest(
        context="请执行这条",
        pinyin="mingling",
        candidates=["明令", "命令"],
    )
    explicit = decoder.suggest(
        context="请执行这条",
        pinyin="mingling",
        candidates=["明令", "命令"],
        scorer=StaticCharLM(model),
    )

    assert explicit == default


def test_scorer_adjudicates_margin_without_steering_expansion(
    tmp_path: Path,
):
    # Ruling 10: beam 扩展永远走静态打分；自定义 scorer 只参与最终
    # 路径裁决（margin），不得改变解码文本。
    decoder = _decoder(tmp_path)

    default = decoder.suggest(
        context="请执行这条",
        pinyin="mingling",
        candidates=["明令", "命令"],
    )
    biased = decoder.suggest(
        context="请执行这条",
        pinyin="mingling",
        candidates=["明令", "命令"],
        scorer=_ProMingScorer(),
    )

    assert biased.text == default.text == "命令"
    assert biased.reason == default.reason == "suggestion"
    assert biased.margin > default.margin


def test_threshold_training_uses_validation_and_never_test_labels(
    tmp_path: Path,
):
    validation = _sample(
        "validation-1",
        "validation",
        "请执行这条",
        "命令",
        ["明令", "命令"],
    )
    secret_test = _sample(
        "test-1",
        "test",
        "不要读取测试答案",
        "绝密",
        ["公开", "绝密"],
    )

    config, report = train_beam_decoder_config(
        [validation, secret_test],
        _language_model(),
        _guard(tmp_path),
        dataset_sha256="e" * 64,
        language_model_sha256="f" * 64,
        dictionary_sha256="1" * 64,
    )

    assert config.dataset_sha256 == "e" * 64
    assert report["validation_samples"] == 1
    assert report["test_samples_used"] == 0
