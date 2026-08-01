from pathlib import Path

from rimeai_eval.beam_decoder import (
    BeamDecoderConfig,
    BeamSentenceDecoder,
    train_beam_decoder_config,
)
from rimeai_eval.ngram_ranker import train_ngram_model
from rimeai_eval.pinyin_guard import PinyinGuard


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
        "命\tming\n明\tming\n令\tling\n",
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
