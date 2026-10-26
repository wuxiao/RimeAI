import json
import math

import pytest

from rimeai_runtime.neural_ranker import (
    FUSION_TYPE,
    FUSION_TYPE_GLOBAL_NORM,
    GLOBAL_NORM_METHOD,
    FusionConfig,
    HybridSemanticRanker,
    NeuralRankerArtifact,
    NeuralRankerError,
    RankerExample,
    _generic_pinyin_segmentation,
    build_ranker_examples,
    build_special_tokens,
    calibrate_change_threshold,
    format_ranker_input,
    pooled_affine_stats,
    standardize_scores,
    train_fusion_config,
)
from rimeai_runtime.pinyin_guard import (
    PinyinGuard,
    generic_pinyin_segmentation,
    segment_generic_pinyin,
)


def _guard():
    return PinyinGuard(
        {
            "命": frozenset({"ming"}),
            "明": frozenset({"ming"}),
            "令": frozenset({"ling"}),
        }
    )


def _reference_generic_segmentation(pinyin, guard):
    """下沉前 neural_ranker._generic_pinyin_segmentation 的逐行副本，
    作为行为快照 oracle。"""
    normalized = pinyin.lower().replace("'", "").replace(" ", "")
    syllables = sorted(
        {
            pronunciation
            for text, pronunciations in guard.pronunciations.items()
            if len(text) == 1
            for pronunciation in pronunciations
        },
        key=lambda value: (-len(value), value),
    )
    paths = {0: []}
    for start in range(len(normalized) + 1):
        if start not in paths:
            continue
        for syllable in syllables:
            if normalized.startswith(syllable, start):
                end = start + len(syllable)
                candidate = paths[start] + [syllable]
                previous = paths.get(end)
                if previous is None or len(candidate) < len(previous):
                    paths[end] = candidate
    return paths.get(len(normalized), [normalized] if normalized else [])


def _segmentation_guard():
    return PinyinGuard(
        {
            "命": frozenset({"ming"}),
            "明": frozenset({"ming"}),
            "令": frozenset({"ling"}),
            "灵": frozenset({"ling"}),
            "力": frozenset({"li"}),
            "你": frozenset({"ni"}),
            "好": frozenset({"hao"}),
        }
    )


@pytest.mark.parametrize(
    "pinyin",
    [
        "mingling",
        "lingming",
        "li",
        "nilihaoming",
        "ming ling",
        "Ming'ling",
        "",
        "''",
        "zzzz",
        "liii",
        "mingmingming",
        "liming",
    ],
)
def test_generic_pinyin_segmentation_matches_pre_move_behavior(pinyin):
    guard = _segmentation_guard()
    assert generic_pinyin_segmentation(pinyin, guard) == (
        _reference_generic_segmentation(pinyin, guard)
    )
    assert _generic_pinyin_segmentation(pinyin, guard) == (
        _reference_generic_segmentation(pinyin, guard)
    )


def test_segment_generic_pinyin_distinguishes_tiling_from_fallback():
    guard = _segmentation_guard()
    # 可完整铺满 → 具体切分。
    assert segment_generic_pinyin("mingling", guard) == ["ming", "ling"]
    assert segment_generic_pinyin("li", guard) == ["li"]
    # 空串与旧实现一致返回 []（DP 起点即终点，未走兜底）。
    assert segment_generic_pinyin("", guard) == []
    # 无法铺满 → None（与 generic_pinyin_segmentation 的整串兜底区分）。
    assert segment_generic_pinyin("zzzz", guard) is None


def test_generic_pinyin_segmentation_prefers_fewer_syllables():
    # 最长音节优先 + 更少音节切分：li+ming（2 个）胜过 li+min+g（若有）。
    guard = _segmentation_guard()
    assert generic_pinyin_segmentation("liming", guard) == ["li", "ming"]


def test_generic_pinyin_segmentation_cache_is_per_guard_instance():
    guard_a = PinyinGuard({"命": frozenset({"ming"}), "令": frozenset({"ling"})})
    guard_b = PinyinGuard({"你": frozenset({"ni"}), "好": frozenset({"hao"})})

    # 首次调用填充缓存，重复调用结果不变。
    assert generic_pinyin_segmentation("mingling", guard_a) == ["ming", "ling"]
    assert generic_pinyin_segmentation("mingling", guard_a) == ["ming", "ling"]
    # 缓存确实生效（按实例 memo：缓存的是全音节有序表）。
    from rimeai_runtime.pinyin_guard import _GENERIC_SYLLABLES_CACHE

    assert getattr(guard_a, _GENERIC_SYLLABLES_CACHE) == ("ling", "ming")
    # 不同实例互不串缓存：guard_b 的词典里没有 ming/ling。
    assert generic_pinyin_segmentation("mingling", guard_b) == ["mingling"]
    assert generic_pinyin_segmentation("nihao", guard_b) == ["ni", "hao"]
    assert getattr(guard_b, _GENERIC_SYLLABLES_CACHE) == ("hao", "ni")
    # 回到 guard_a 仍然正确。
    assert generic_pinyin_segmentation("lingming", guard_a) == ["ling", "ming"]


def test_format_ranker_input_falls_back_to_generic_segmentation():
    # candidate 文本无法 tile 整串拼音（令 只有一个 ling）→ segment None
    # → 复用下沉后的通用切分。
    text = format_ranker_input(
        context="",
        pinyin="lingming",
        candidate="令",
        baseline_index=0,
        guard=_guard(),
    )
    assert "[PY] [PY_ling] [PY_ming]" in text


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


# --- v2 global normalization: two-candidate degeneration and compatibility ---


class _FixedNeural:
    model_artifact_id = "neural:test"
    cold_start_ms = 1.0

    def __init__(self, scores):
        self._fixed_scores = scores

    def _scores(self, **kwargs):
        return list(self._fixed_scores)


class _FixedNGram:
    dataset_sha256 = "b" * 64

    def __init__(self, scores):
        self._fixed_scores = scores

    def _candidate_score(self, context, candidate, baseline_index):
        return self._fixed_scores[baseline_index]


def _fusion_payload(
    *,
    fusion_type=FUSION_TYPE,
    neural_weight=0.5,
    margin_threshold=0.3,
    target_precision=0.9,
    score_normalization=None,
):
    payload = {
        "schema_version": 1,
        "fusion_type": fusion_type,
        "artifact_id": "fusion:test",
        "neural_weight": neural_weight,
        "neural_artifact_id": "neural:test",
        "ngram_dataset_sha256": "b" * 64,
        "validation_dataset_sha256": "c" * 64,
        "decision": {
            "margin_threshold": margin_threshold,
            "target_precision": target_precision,
        },
    }
    if score_normalization is not None:
        payload["score_normalization"] = score_normalization
    return payload


_GLOBAL_NORM = {
    "method": GLOBAL_NORM_METHOD,
    "neural_mean": 0.0,
    "neural_std": 2.0,
    "ngram_mean": 0.0,
    "ngram_std": 1.0,
}


def test_two_candidate_v1_fusion_degenerates_to_zero_margin():
    # 数值复现：per-sample z-score 下两候选意见相反且 w=0.5 时，
    # 融合分恒等（margin=0），按原索引回落 Rime 原序，
    # confidence=0.5 < ranker_min_confidence=0.55，神经结构性无法翻转。
    import tempfile
    from pathlib import Path

    with tempfile.TemporaryDirectory() as directory:
        config = Path(directory) / "fusion.json"
        config.write_text(
            json.dumps(
                _fusion_payload(
                    fusion_type=FUSION_TYPE,
                    neural_weight=0.5,
                    margin_threshold=0.3,
                )
            ),
            encoding="utf-8",
        )
        ranker = HybridSemanticRanker(
            _FixedNeural([1.0, 5.0]), _FixedNGram([2.0, 1.0]), config
        )
        # 融合分恒等（margin=0）的数学事实：
        assert config_reader_fused(ranker) == [0.0, 0.0]

        ranking, confidence = ranker.rank_candidates(
            context="请执行这条",
            pinyin="mingling",
            candidates=["明令", "命令"],
        )

    assert ranking == ["明令", "命令"]
    # 稳定排序按原索引回落 → 首选不变 → same-top 分支 confidence=1.0，
    # 即神经的强烈反对意见（z=[-1,1]）被结构性压制，daemon 永不翻转首选。
    assert confidence == 1.0


def config_reader_fused(ranker):
    """Expose the fused scores for margin assertions without touching privates."""
    return ranker.config.fuse_scores([1.0, 5.0], [2.0, 1.0])


def test_two_candidate_v2_global_norm_enables_flip():
    # 同样的原始分数，v2 全局仿射归一化后两候选意见相反时 margin
    # 不再结构性归零：融合分 [1.25, 1.75]，候选 1 胜出且置信度越线。
    import tempfile
    from pathlib import Path

    with tempfile.TemporaryDirectory() as directory:
        config = Path(directory) / "fusion.json"
        config.write_text(
            json.dumps(
                _fusion_payload(
                    fusion_type=FUSION_TYPE_GLOBAL_NORM,
                    neural_weight=0.5,
                    margin_threshold=0.3,
                    score_normalization=_GLOBAL_NORM,
                )
            ),
            encoding="utf-8",
        )
        ranker = HybridSemanticRanker(
            _FixedNeural([1.0, 5.0]), _FixedNGram([2.0, 1.0]), config
        )

        ranking, confidence = ranker.rank_candidates(
            context="请执行这条",
            pinyin="mingling",
            candidates=["明令", "命令"],
        )

    assert ranking == ["命令", "明令"]
    # margin = 1.75 - 1.25 = 0.5 >= threshold 0.3:
    # confidence = 0.9 + 0.1 * (1 - exp(-0.2)) ≈ 0.918 > 0.55.
    assert confidence == pytest.approx(0.9 + 0.1 * (1.0 - math.exp(-0.2)))
    assert confidence > 0.55


def _legacy_v1_ranking_and_confidence(
    neural_raw,
    ngram_raw,
    *,
    weight,
    margin_threshold,
    target_precision,
):
    """改造前 HybridSemanticRanker v1 路径的逐行副本（行为 oracle）。"""
    fused_scores = [
        weight * standardize_scores(neural_raw)[index]
        + (1.0 - weight) * standardize_scores(ngram_raw)[index]
        for index in range(len(neural_raw))
    ]
    ranked_indices = sorted(
        range(len(fused_scores)),
        key=lambda index: (-fused_scores[index], index),
    )
    margin = fused_scores[ranked_indices[0]] - fused_scores[ranked_indices[1]]
    if ranked_indices[0] == 0:
        confidence = 1.0
    elif margin >= margin_threshold:
        excess = margin - margin_threshold
        confidence = target_precision + (1.0 - target_precision) * (
            1.0 - math.exp(-excess)
        )
    else:
        ratio = 0.0 if margin_threshold <= 0 else max(0.0, margin / margin_threshold)
        confidence = min(0.899, 0.5 + 0.399 * ratio)
    return ranked_indices, confidence


@pytest.mark.parametrize(
    "neural_raw,ngram_raw,weight,margin_threshold,target_precision",
    [
        ([1.0, 5.0], [2.0, 1.0], 0.5, 0.3, 0.9),
        ([0.0, 3.0, 1.0], [3.0, 0.0, 1.5], 0.75, 0.0, 0.9),
        ([2.0, 2.0, 2.0], [1.0, 2.0, 3.0], 0.25, 1.4, 0.9),
        ([5.0, 1.0, 4.0, 0.5, 3.3], [0.3, 2.2, 1.1, 4.4, 0.9], 0.6, 0.8, 0.8),
        ([1.0, 2.0], [2.0, 1.0], 0.0, 0.27, 0.9),
        ([1.0, 2.0], [2.0, 1.0], 1.0, 0.27, 0.9),
    ],
)
def test_v1_fusion_config_matches_legacy_zscore_path_bit_for_bit(
    neural_raw,
    ngram_raw,
    weight,
    margin_threshold,
    target_precision,
):
    import tempfile
    from pathlib import Path

    candidates = [f"候选{index}" for index in range(len(neural_raw))]
    with tempfile.TemporaryDirectory() as directory:
        config = Path(directory) / "fusion.json"
        config.write_text(
            json.dumps(
                _fusion_payload(
                    fusion_type=FUSION_TYPE,
                    neural_weight=weight,
                    margin_threshold=margin_threshold,
                    target_precision=target_precision,
                )
            ),
            encoding="utf-8",
        )
        ranker = HybridSemanticRanker(
            _FixedNeural(neural_raw), _FixedNGram(ngram_raw), config
        )
        ranking, confidence = ranker.rank_candidates(
            context="上下文",
            pinyin="mingling",
            candidates=candidates,
        )

    legacy_indices, legacy_confidence = _legacy_v1_ranking_and_confidence(
        neural_raw,
        ngram_raw,
        weight=weight,
        margin_threshold=margin_threshold,
        target_precision=target_precision,
    )
    assert ranking == [candidates[index] for index in legacy_indices]
    assert confidence == legacy_confidence


def _write_config(tmp_path, payload, name="fusion.json"):
    path = tmp_path / name
    path.write_text(json.dumps(payload), encoding="utf-8")
    return path


def test_v2_config_loads_global_normalization_fields(tmp_path):
    path = _write_config(
        tmp_path,
        _fusion_payload(
            fusion_type=FUSION_TYPE_GLOBAL_NORM,
            score_normalization=_GLOBAL_NORM,
        ),
    )

    config = FusionConfig.load(path)

    assert config.fusion_type == FUSION_TYPE_GLOBAL_NORM
    assert config.neural_mean == 0.0
    assert config.neural_std == 2.0
    assert config.ngram_mean == 0.0
    assert config.ngram_std == 1.0
    fused = config.fuse_scores([2.0, 6.0], [1.0, 2.0])
    # affine: neural -> [1, 3], ngram -> [1, 2]; w=0.5 -> [1, 2.5]
    assert fused == [1.0, 2.5]


@pytest.mark.parametrize(
    "mutation",
    [
        "missing_section",
        "wrong_method",
        "missing_neural_std",
        "zero_neural_std",
        "negative_ngram_std",
        "nan_mean",
        "infinite_std",
        "string_value",
        "boolean_value",
        "unknown_fusion_type",
    ],
)
def test_v2_config_fails_closed_on_invalid_normalization(tmp_path, mutation):
    normalization = dict(_GLOBAL_NORM)
    fusion_type = FUSION_TYPE_GLOBAL_NORM
    if mutation == "missing_section":
        normalization = None
    elif mutation == "wrong_method":
        normalization["method"] = "per-sample-zscore"
    elif mutation == "missing_neural_std":
        del normalization["neural_std"]
    elif mutation == "zero_neural_std":
        normalization["neural_std"] = 0.0
    elif mutation == "negative_ngram_std":
        normalization["ngram_std"] = -1.0
    elif mutation == "nan_mean":
        normalization["ngram_mean"] = float("nan")
    elif mutation == "infinite_std":
        normalization["neural_std"] = float("inf")
    elif mutation == "string_value":
        normalization["neural_mean"] = "0.0"
    elif mutation == "boolean_value":
        normalization["ngram_mean"] = True
    elif mutation == "unknown_fusion_type":
        fusion_type = "rimeai-neural-ngram-v3"

    path = _write_config(
        tmp_path,
        _fusion_payload(
            fusion_type=fusion_type,
            score_normalization=normalization,
        ),
    )

    with pytest.raises(NeuralRankerError):
        FusionConfig.load(path)


def test_pooled_affine_stats_matches_population_moments():
    scores = [1.0, 2.0, 3.0, 6.0]
    mean, std = pooled_affine_stats(scores)
    assert mean == pytest.approx(3.0)
    assert std == pytest.approx(math.sqrt(14.0 / 4.0))

    with pytest.raises(NeuralRankerError):
        pooled_affine_stats([])
    with pytest.raises(NeuralRankerError):
        pooled_affine_stats([2.5, 2.5])


class _ScoreByPositionNeural:
    """Deterministic neural double whose scores depend on the sample."""

    model_artifact_id = "neural:test"
    cold_start_ms = 0.0

    def __init__(self, table):
        self._table = table

    def _scores(self, *, context, pinyin, candidates, baseline_indices):
        return list(self._table[context])


class _ScoreByPositionNGram:
    dataset_sha256 = "b" * 64

    def __init__(self, table):
        self._table = table

    def _candidate_score(self, context, candidate, baseline_index):
        return self._table[context][baseline_index]


_FUSION_SAMPLES = [
    {
        "id": "agree",
        "split": "validation",
        "context": "命令",
        "pinyin": "mingling",
        "candidates": ["明令", "命令"],
        "gold_text": "命令",
    },
    {
        "id": "conflict",
        "split": "validation",
        "context": "任务",
        "pinyin": "mingling",
        "candidates": ["明令", "命令"],
        "gold_text": "命令",
    },
    {
        "id": "baseline_gold",
        "split": "validation",
        "context": "历史",
        "pinyin": "mingling",
        "candidates": ["明令", "命令"],
        "gold_text": "明令",
    },
]


def test_train_fusion_config_selects_jointly_and_writes_v2_payload(tmp_path):
    neural = _ScoreByPositionNeural(
        {
            "命令": [1.0, 4.0],
            "任务": [1.0, 5.0],
            "历史": [3.0, 1.0],
        }
    )
    ngram = _ScoreByPositionNGram(
        {
            "命令": [2.0, 1.0],
            "任务": [2.0, 1.0],
            "历史": [2.0, 1.0],
        }
    )
    output = tmp_path / "fusion-v2.json"

    payload = train_fusion_config(
        _FUSION_SAMPLES,
        dataset_sha256="d" * 64,
        neural_ranker=neural,
        ngram_ranker=ngram,
        output_path=output,
        target_precision=0.5,
    )

    assert payload["fusion_type"] == FUSION_TYPE_GLOBAL_NORM
    normalization = payload["score_normalization"]
    assert normalization["method"] == GLOBAL_NORM_METHOD
    neural_flat = [1.0, 4.0, 1.0, 5.0, 3.0, 1.0]
    expected_neural_mean = sum(neural_flat) / len(neural_flat)
    expected_neural_std = math.sqrt(
        sum((s - expected_neural_mean) ** 2 for s in neural_flat) / len(neural_flat)
    )
    assert normalization["neural_mean"] == pytest.approx(expected_neural_mean)
    assert normalization["neural_std"] == pytest.approx(expected_neural_std)
    assert normalization["ngram_mean"] == pytest.approx(1.5)
    assert normalization["ngram_std"] == pytest.approx(0.5)

    table = payload["validation"]["weight_table"]
    assert [row["weight"] for row in table] == [step / 20 for step in range(21)]
    # 固定选择口径独立复核：选中行按 (net_gain, changed, accuracy, -weight)
    # 在（若存在则限）可校准行上最大。
    selected = next(
        row for row in table if row["weight"] == payload["neural_weight"]
    )
    key = lambda row: (  # noqa: E731
        row["net_gain"],
        row["changed_samples"],
        row["raw_top1_accuracy"],
        -row["weight"],
    )
    calibrated = [row for row in table if row["calibrated"]]
    pool = calibrated or table
    assert pool and key(selected) == max(key(row) for row in pool)
    if calibrated:
        assert selected["calibrated"]
    assert payload["decision"]["margin_threshold"] == selected["margin_threshold"]
    assert payload["decision"]["wins"] == selected["wins"]
    assert payload["validation"]["test_samples_used"] == 0

    # 写出的文件可被 fail-closed 加载器重新加载。
    reloaded = FusionConfig.load(output)
    assert reloaded.fusion_type == FUSION_TYPE_GLOBAL_NORM
    assert reloaded.neural_weight == payload["neural_weight"]


def test_train_fusion_config_v1_examples_still_rank_bit_for_bit(tmp_path):
    """联合校准只产出 v2；旧 v1 config 的排序路径保持逐位一致。"""
    neural = _ScoreByPositionNeural(
        {"任务": [1.0, 5.0], "命令": [1.0, 4.0], "历史": [3.0, 1.0]}
    )
    ngram = _ScoreByPositionNGram(
        {"任务": [2.0, 1.0], "命令": [2.0, 1.0], "历史": [2.0, 1.0]}
    )
    output = tmp_path / "fusion-v2.json"
    train_fusion_config(
        _FUSION_SAMPLES,
        dataset_sha256="d" * 64,
        neural_ranker=neural,
        ngram_ranker=ngram,
        output_path=output,
        target_precision=0.5,
    )

    legacy_config = _write_config(
        tmp_path,
        _fusion_payload(
            fusion_type=FUSION_TYPE,
            neural_weight=0.5,
            margin_threshold=0.3,
        ),
        name="fusion-v1.json",
    )
    ranker = HybridSemanticRanker(neural, ngram, legacy_config)
    ranking, confidence = ranker.rank_candidates(
        context="任务",
        pinyin="mingling",
        candidates=["明令", "命令"],
    )
    legacy_indices, legacy_confidence = _legacy_v1_ranking_and_confidence(
        [1.0, 5.0],
        [2.0, 1.0],
        weight=0.5,
        margin_threshold=0.3,
        target_precision=0.9,
    )
    assert ranking == [["明令", "命令"][index] for index in legacy_indices]
    assert confidence == legacy_confidence
