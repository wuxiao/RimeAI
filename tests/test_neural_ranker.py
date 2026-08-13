import json

import pytest

from rimeai_eval.neural_ranker import (
    FusionConfig,
    HybridSemanticRanker,
    NeuralRankerArtifact,
    RankerExample,
    build_ranker_examples,
    build_special_tokens,
    calibrate_change_threshold,
    format_ranker_input,
    standardize_scores,
)
from rimeai_eval.pinyin_guard import PinyinGuard


def _guard():
    return PinyinGuard(
        {
            "命": frozenset({"ming"}),
            "明": frozenset({"ming"}),
            "令": frozenset({"ling"}),
        }
    )


def test_special_tokens_include_pinyin_candidate_and_rank_markers():
    tokens = build_special_tokens(_guard())

    assert tokens[:3] == ["[CTX]", "[PY]", "[CAND]"]
    assert "[PY_ming]" in tokens
    assert "[PY_ling]" in tokens
    assert "[RANK_1]" in tokens
    assert "[RANK_10]" in tokens
    assert len(tokens) == len(set(tokens))


def test_ranker_input_uses_candidate_specific_pinyin_syllables():
    text = format_ranker_input(
        context="请执行这条",
        pinyin="mingling",
        candidate="命令",
        baseline_index=1,
        guard=_guard(),
    )

    assert text == (
        "[CTX] 请执行这条 [PY] [PY_ming] [PY_ling] "
        "[CAND] [RANK_2] 命令"
    )


def test_build_ranker_examples_excludes_uncovered_and_partial_gold():
    samples = [
        {
            "id": "covered",
            "split": "train",
            "context": "请执行这条",
            "pinyin": "mingling",
            "candidates": ["明令", "命令", "命"],
            "gold_text": "命令",
        },
        {
            "id": "uncovered",
            "split": "train",
            "context": "",
            "pinyin": "mingling",
            "candidates": ["明令", "命"],
            "gold_text": "命令",
        },
    ]

    examples = build_ranker_examples(samples, split="train")

    assert examples == [
        RankerExample(
            sample_id="covered",
            context="请执行这条",
            pinyin="mingling",
            candidates=("明令", "命令"),
            baseline_indices=(0, 1),
            label=1,
            context_ambiguous=False,
        )
    ]


def test_build_ranker_examples_marks_same_pinyin_multiple_gold_as_ambiguous():
    samples = [
        {
            "id": "accept",
            "split": "train",
            "context": "用户同意",
            "pinyin": "jieshou",
            "candidates": ["接受", "接收"],
            "gold_text": "接受",
        },
        {
            "id": "receive",
            "split": "train",
            "context": "网络数据",
            "pinyin": "jieshou",
            "candidates": ["接受", "接收"],
            "gold_text": "接收",
        },
    ]

    examples = build_ranker_examples(samples, split="train")

    assert all(example.context_ambiguous for example in examples)


def test_change_threshold_requires_precision_and_positive_net_gain():
    records = [
        {"margin": 0.9, "baseline_correct": False, "model_correct": True},
        {"margin": 0.8, "baseline_correct": False, "model_correct": True},
        {"margin": 0.7, "baseline_correct": True, "model_correct": False},
        {"margin": 0.6, "baseline_correct": False, "model_correct": True},
    ]

    calibration = calibrate_change_threshold(records, target_precision=0.8)

    assert calibration["margin_threshold"] == pytest.approx(0.8)
    assert calibration["changed_samples"] == 2
    assert calibration["wins"] == 2
    assert calibration["losses"] == 0
    assert calibration["precision"] == 1.0


def test_artifact_manifest_rejects_a_wrong_model_shape(tmp_path):
    manifest = {
        "schema_version": 1,
        "model_type": "rimeai-pinyin-listwise-cross-encoder",
        "base_model": {
            "id": "BAAI/bge-small-zh-v1.5",
            "revision": "pinned",
        },
        "architecture": {
            "hidden_size": 768,
            "layers": 12,
            "attention_heads": 12,
            "max_length": 128,
        },
        "decision": {"margin_threshold": 0.5},
        "dataset_sha256": "a" * 64,
        "files": {},
    }
    path = tmp_path / "manifest.json"
    path.write_text(json.dumps(manifest), encoding="utf-8")

    with pytest.raises(ValueError, match="24M architecture"):
        NeuralRankerArtifact.load(path.parent)


def test_score_standardization_is_stable_for_constant_and_ranked_values():
    assert standardize_scores([3.0, 3.0]) == [0.0, 0.0]
    standardized = standardize_scores([1.0, 2.0, 3.0])
    assert sum(standardized) == pytest.approx(0.0)
    assert standardized[2] > standardized[1] > standardized[0]


def test_fusion_config_rejects_a_mismatched_model(tmp_path):
    path = tmp_path / "fusion.json"
    path.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "fusion_type": "rimeai-neural-ngram-v1",
                "artifact_id": "fusion:test",
                "neural_weight": 0.5,
                "neural_artifact_id": "neural:a",
                "ngram_dataset_sha256": "b" * 64,
                "validation_dataset_sha256": "c" * 64,
                "decision": {
                    "margin_threshold": 0.5,
                    "target_precision": 0.9,
                },
            }
        ),
        encoding="utf-8",
    )

    with pytest.raises(ValueError, match="neural artifact"):
        FusionConfig.load(
            path,
            neural_artifact_id="neural:other",
            ngram_dataset_sha256="b" * 64,
        )


def test_hybrid_ranker_fuses_neural_and_ngram_scores(tmp_path):
    class Neural:
        model_artifact_id = "neural:test"
        cold_start_ms = 1.0

        def _scores(self, **kwargs):
            return [0.0, 3.0]

    class NGram:
        dataset_sha256 = "b" * 64

        def _candidate_score(self, context, candidate, baseline_index):
            return [3.0, 0.0][baseline_index]

    config = tmp_path / "fusion.json"
    config.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "fusion_type": "rimeai-neural-ngram-v1",
                "artifact_id": "fusion:test",
                "neural_weight": 0.75,
                "neural_artifact_id": "neural:test",
                "ngram_dataset_sha256": "b" * 64,
                "validation_dataset_sha256": "c" * 64,
                "decision": {
                    "margin_threshold": 0.0,
                    "target_precision": 0.9,
                },
            }
        ),
        encoding="utf-8",
    )
    ranker = HybridSemanticRanker(Neural(), NGram(), config)

    ranking, confidence = ranker.rank_candidates(
        context="请执行这条",
        pinyin="mingling",
        candidates=["明令", "命令"],
    )

    assert ranking == ["命令", "明令"]
    assert confidence >= 0.9
