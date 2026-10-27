from pathlib import Path
import json
import math

import pytest

from rimeai_eval.cli import _build_parser, _parse_float_grid, _parse_int_grid
from rimeai_runtime.beam_decoder import (
    BeamDecoderConfig,
    BeamDecoderError,
    BeamSentenceDecoder,
    SegmentDecodeInput,
    load_beam_config,
    train_beam_decoder_config,
    write_beam_config_atomic,
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

    def suggest(self, *, context, pinyin, candidates, scorer=None):
        self.calls.append((context, pinyin, list(candidates)))
        return super().suggest(
            context=context,
            pinyin=pinyin,
            candidates=candidates,
            scorer=scorer,
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


class _AntiMingScorer:
    """Adjudication-only scorer: hates 命 (the winning path's first char)."""

    max_context_characters = 40

    def next_char_log_prob(self, context: str, character: str) -> float:
        return math.log(1e-300) if character == "命" else math.log(0.5)

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
    # One-way ratchet: beam 扩展与门控永远走静态打分；自定义 scorer
    # 只能提升 confidence，不得改变解码文本、margin 或接受决策。
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
    assert biased.margin == default.margin
    assert biased.confidence > default.confidence


def test_adversarial_scorer_cannot_demote_a_statically_accepted_suggestion(
    tmp_path: Path,
):
    # Ratchet 的另一半：即便融合 margin 远低于阈值，静态已接受的建议
    # 也不得被压回 below_threshold，confidence 不得被降低。
    decoder = _decoder(tmp_path)

    default = decoder.suggest(
        context="请执行这条",
        pinyin="mingling",
        candidates=["明令", "命令"],
    )
    adversarial = decoder.suggest(
        context="请执行这条",
        pinyin="mingling",
        candidates=["明令", "命令"],
        scorer=_AntiMingScorer(),
    )

    assert default.reason == "suggestion"
    assert adversarial.reason == "suggestion"
    assert adversarial.text == default.text
    assert adversarial.margin == default.margin
    assert adversarial.confidence == pytest.approx(default.confidence)


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


def test_config_defaults_character_frequency_weight_to_one_half():
    config = BeamDecoderConfig(
        threshold=1.0,
        beam_width=16,
        characters_per_syllable=20,
        language_model_sha256="a" * 64,
        dictionary_sha256="b" * 64,
        dataset_sha256="c" * 64,
    )

    assert config.character_frequency_weight == 0.5
    serialized = config.to_dict()
    # Default weight keeps the historical artifact shape: schema v1 with
    # no character_frequency_weight key at all, so the serialized bytes
    # match f23fa49 output bit-for-bit.
    assert serialized["schema_version"] == 1
    assert "character_frequency_weight" not in serialized
    assert set(serialized) == {
        "schema_version",
        "decoder_type",
        "threshold",
        "beam_width",
        "characters_per_syllable",
        "language_model_sha256",
        "dictionary_sha256",
        "dataset_sha256",
    }


def test_non_default_weight_writes_schema_v2_and_is_invisible_to_stale_loaders(
    tmp_path: Path,
):
    """Weighted configs must self-describe as schema v2 (B-F3).

    The stale loader at f23fa49 and earlier gated on
    ``payload.get("schema_version") != 1``, so a v2 artifact fails that
    load closed instead of succeeding and silently decoding with the
    hardcoded 0.5 prior. Asserting ``schema_version == 2`` below is
    exactly that "stale loader rejects the new artifact" precondition.
    """
    config = BeamDecoderConfig(
        threshold=2.0,
        beam_width=8,
        characters_per_syllable=12,
        character_frequency_weight=0.25,
        language_model_sha256="a" * 64,
        dictionary_sha256="b" * 64,
        dataset_sha256="c" * 64,
    )

    serialized = config.to_dict()
    assert serialized["schema_version"] == 2
    assert serialized["character_frequency_weight"] == 0.25
    # f23fa49 loader gate: schema_version must equal 1 -> this artifact
    # fails that load instead of decoding with 0.5 semantics.
    assert serialized["schema_version"] != 1

    path = tmp_path / "weighted-v2.json"
    write_beam_config_atomic(path, config)
    assert load_beam_config(path) == config


def test_loading_a_legacy_config_without_the_weight_field_is_bit_identical(
    tmp_path: Path,
):
    legacy_payload = {
        "schema_version": 1,
        "decoder_type": "pinyin-beam-ngram",
        "threshold": 4.25,
        "beam_width": 16,
        "characters_per_syllable": 20,
        "language_model_sha256": "a" * 64,
        "dictionary_sha256": "b" * 64,
        "dataset_sha256": "c" * 64,
    }
    legacy_path = tmp_path / "legacy.json"
    legacy_path.write_text(
        json.dumps(legacy_payload, sort_keys=True, separators=(",", ":")),
        encoding="utf-8",
    )

    loaded = load_beam_config(legacy_path)

    assert loaded.character_frequency_weight == 0.5
    legacy_decoder = BeamSentenceDecoder(
        _language_model(), _guard(tmp_path), loaded
    )
    explicit_decoder = BeamSentenceDecoder(
        _language_model(),
        _guard(tmp_path),
        BeamDecoderConfig(
            threshold=loaded.threshold,
            beam_width=loaded.beam_width,
            characters_per_syllable=loaded.characters_per_syllable,
            character_frequency_weight=0.5,
            language_model_sha256="a" * 64,
            dictionary_sha256="b" * 64,
            dataset_sha256="c" * 64,
        ),
    )
    for decoder in (legacy_decoder, explicit_decoder):
        suggestion = decoder.suggest(
            context="请执行这条",
            pinyin="mingling",
            candidates=["明令", "命令"],
        )
        assert suggestion.text == "命令"
        assert suggestion.reason == "suggestion"
    legacy_suggestion = legacy_decoder.suggest(
        context="请执行这条", pinyin="mingling", candidates=["明令", "命令"]
    )
    explicit_suggestion = explicit_decoder.suggest(
        context="请执行这条", pinyin="mingling", candidates=["明令", "命令"]
    )
    assert legacy_suggestion == explicit_suggestion


def test_config_with_explicit_weight_round_trips(tmp_path: Path):
    config = BeamDecoderConfig(
        threshold=2.0,
        beam_width=8,
        characters_per_syllable=12,
        character_frequency_weight=0.25,
        language_model_sha256="a" * 64,
        dictionary_sha256="b" * 64,
        dataset_sha256="c" * 64,
    )
    path = tmp_path / "weighted.json"

    write_beam_config_atomic(path, config)
    loaded = load_beam_config(path)

    assert loaded == config
    assert loaded.character_frequency_weight == 0.25


@pytest.mark.parametrize(
    "weight",
    [
        -0.1,
        float("nan"),
        float("inf"),
        True,
        "0.5",
        None,
        [0.5],
    ],
)
def test_invalid_character_frequency_weight_fails_closed(
    tmp_path: Path, weight
):
    payload = {
        "schema_version": 2,
        "decoder_type": "pinyin-beam-ngram",
        "threshold": 1.0,
        "beam_width": 16,
        "characters_per_syllable": 20,
        "character_frequency_weight": weight,
        "language_model_sha256": "a" * 64,
        "dictionary_sha256": "b" * 64,
        "dataset_sha256": "c" * 64,
    }
    path = tmp_path / "invalid.json"
    path.write_text(json.dumps(payload), encoding="utf-8")

    with pytest.raises(BeamDecoderError):
        load_beam_config(path)


def test_load_rejects_schema_v2_without_explicit_weight(tmp_path: Path):
    payload = {
        "schema_version": 2,
        "decoder_type": "pinyin-beam-ngram",
        "threshold": 1.0,
        "beam_width": 16,
        "characters_per_syllable": 20,
        "language_model_sha256": "a" * 64,
        "dictionary_sha256": "b" * 64,
        "dataset_sha256": "c" * 64,
    }
    path = tmp_path / "v2-missing-weight.json"
    path.write_text(json.dumps(payload), encoding="utf-8")

    with pytest.raises(BeamDecoderError, match="explicit"):
        load_beam_config(path)


def test_schema_v1_accepts_only_the_default_weight(tmp_path: Path):
    base = {
        "schema_version": 1,
        "decoder_type": "pinyin-beam-ngram",
        "threshold": 1.0,
        "beam_width": 16,
        "characters_per_syllable": 20,
        "language_model_sha256": "a" * 64,
        "dictionary_sha256": "b" * 64,
        "dataset_sha256": "c" * 64,
    }

    # Explicitly-written default value is still fine (artifacts written
    # between abe63dd and the schema bump carry it under v1).
    with_default = {**base, "character_frequency_weight": 0.5}
    path = tmp_path / "v1-explicit-default.json"
    path.write_text(json.dumps(with_default), encoding="utf-8")
    assert load_beam_config(path).character_frequency_weight == 0.5

    # Anything else under v1 fails closed: a stale loader must never
    # decode a v1 artifact with non-default frequency semantics.
    with_non_default = {**base, "character_frequency_weight": 0.25}
    path = tmp_path / "v1-non-default.json"
    path.write_text(json.dumps(with_non_default), encoding="utf-8")
    with pytest.raises(BeamDecoderError, match="schema v2"):
        load_beam_config(path)


@pytest.mark.parametrize("version", [0, 3])
def test_load_rejects_unknown_beam_schema_versions(tmp_path: Path, version):
    payload = {
        "schema_version": version,
        "decoder_type": "pinyin-beam-ngram",
        "threshold": 1.0,
        "beam_width": 16,
        "characters_per_syllable": 20,
        "language_model_sha256": "a" * 64,
        "dictionary_sha256": "b" * 64,
        "dataset_sha256": "c" * 64,
    }
    path = tmp_path / "unknown-version.json"
    path.write_text(json.dumps(payload), encoding="utf-8")

    with pytest.raises(BeamDecoderError, match="unsupported"):
        load_beam_config(path)


def test_frequency_weight_zero_removes_the_static_prior(tmp_path: Path):
    model = _language_model()
    decoder = BeamSentenceDecoder(
        model,
        _guard(tmp_path),
        BeamDecoderConfig(
            threshold=0.0,
            beam_width=16,
            characters_per_syllable=20,
            character_frequency_weight=0.0,
            language_model_sha256="a" * 64,
            dictionary_sha256="b" * 64,
            dataset_sha256="c" * 64,
        ),
    )
    scorer = decoder._default_scorer

    assert decoder._next_score(scorer, "请执行", "命") == (
        scorer.next_char_log_prob("请执行", "命")
    )
    assert decoder._next_score(scorer, "请执行", "命") != _decoder(
        tmp_path
    )._next_score(
        _decoder(tmp_path)._default_scorer, "请执行", "命"
    )


def test_hyperparameter_scan_reports_the_grid_and_uses_only_validation(
    tmp_path: Path,
):
    validation = [
        _sample(
            f"validation-{index}",
            "validation",
            "请执行这条",
            "命令",
            ["明令", "命令"],
        )
        for index in range(2)
    ]
    secret_test = [
        _sample(
            "test-1",
            "test",
            "不要读取测试答案",
            "绝密",
            ["公开", "绝密"],
        )
    ]

    config, report = train_beam_decoder_config(
        [*validation, *secret_test],
        _language_model(),
        _guard(tmp_path),
        dataset_sha256="e" * 64,
        language_model_sha256="f" * 64,
        dictionary_sha256="1" * 64,
        beam_width=[16, 8],
        characters_per_syllable=[20, 10],
        character_frequency_weight=[0.5, 0.25],
    )
    validation_only_config, validation_only_report = (
        train_beam_decoder_config(
            validation,
            _language_model(),
            _guard(tmp_path),
            dataset_sha256="e" * 64,
            language_model_sha256="f" * 64,
            dictionary_sha256="1" * 64,
            beam_width=[16, 8],
            characters_per_syllable=[20, 10],
            character_frequency_weight=[0.5, 0.25],
        )
    )

    assert config == validation_only_config
    assert report == validation_only_report
    assert report["test_samples_used"] == 0
    assert report["hyperparameter_scan"]["splits_used"] == ["validation"]
    assert report["hyperparameter_scan"]["evaluated_combinations"] == 5
    combinations = report["hyperparameter_scan"]["combinations"]
    assert [row["stage"] for row in combinations] == [1, 1, 1, 1, 2]
    assert {row["beam_width"] for row in combinations if row["stage"] == 1} == {
        16
    }
    assert combinations[-1]["beam_width"] == 8
    assert report["selected_hyperparameters"]["beam_width"] in (8, 16)
    assert report["selected_hyperparameters"]["characters_per_syllable"] in (
        10,
        20,
    )
    assert report["selected_hyperparameters"][
        "character_frequency_weight"
    ] in (0.25, 0.5)


def test_hyperparameter_scan_ties_keep_the_anchor_values(tmp_path: Path):
    validation = [
        _sample(
            "validation-1", "validation", "请执行这条", "命令", ["命令"]
        )
    ]

    config, report = train_beam_decoder_config(
        validation,
        _language_model(),
        _guard(tmp_path),
        dataset_sha256="e" * 64,
        language_model_sha256="f" * 64,
        dictionary_sha256="1" * 64,
        beam_width=[16, 4],
        characters_per_syllable=[20, 5],
        character_frequency_weight=[0.5, 0.0],
    )

    # The single sample is already correct as the baseline candidate, so
    # every combination ties and the anchor grid values must win.
    assert config.beam_width == 16
    assert config.characters_per_syllable == 20
    assert config.character_frequency_weight == 0.5
    assert report["selected_hyperparameters"] == {
        "threshold": config.threshold,
        "beam_width": 16,
        "characters_per_syllable": 20,
        "character_frequency_weight": 0.5,
    }


@pytest.mark.parametrize(
    "kwargs",
    [
        {"beam_width": []},
        {"beam_width": [0]},
        {"beam_width": [2.5]},
        {"characters_per_syllable": []},
        {"characters_per_syllable": [True]},
        {"character_frequency_weight": []},
        {"character_frequency_weight": [-0.5]},
        {"character_frequency_weight": [float("nan")]},
    ],
)
def test_invalid_hyperparameter_grids_fail_closed(tmp_path: Path, kwargs):
    validation = _sample(
        "validation-1", "validation", "请执行这条", "命令", ["明令", "命令"]
    )

    with pytest.raises(BeamDecoderError):
        train_beam_decoder_config(
            [validation],
            _language_model(),
            _guard(tmp_path),
            dataset_sha256="e" * 64,
            language_model_sha256="f" * 64,
            dictionary_sha256="1" * 64,
            **kwargs,
        )


def test_train_beam_cli_parses_comma_separated_grids():
    parser = _build_parser()

    args = parser.parse_args(
        [
            "train-beam-decoder",
            "dataset.jsonl",
            "--language-model",
            "lm.json.gz",
            "--rime-dictionary",
            "dict.yaml",
            "--output",
            "out.json",
            "--beam-width",
            "16,8,32",
            "--characters-per-syllable",
            "20,10",
            "--character-frequency-weight",
            "0.5,0,1.5",
        ]
    )

    assert _parse_int_grid(args.beam_width, "--beam-width") == [16, 8, 32]
    assert _parse_int_grid(
        args.characters_per_syllable, "--characters-per-syllable"
    ) == [20, 10]
    assert _parse_float_grid(
        args.character_frequency_weight, "--character-frequency-weight"
    ) == [0.5, 0.0, 1.5]
    assert _parse_int_grid("16", "--beam-width") == [16]


def test_train_beam_cli_rejects_malformed_grids():
    with pytest.raises(ValueError):
        _parse_int_grid("16,x", "--beam-width")
    with pytest.raises(ValueError):
        _parse_int_grid("0", "--beam-width")
    with pytest.raises(ValueError):
        _parse_float_grid("-1", "--character-frequency-weight")
    with pytest.raises(ValueError):
        _parse_float_grid("nan", "--character-frequency-weight")
