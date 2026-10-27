import gzip
import json
import math
import os
from pathlib import Path
import subprocess
import sys
from typing import Any

import pytest

from rimeai_eval.cli import main
from rimeai_runtime.ngram_ranker import (
    NGramModelError,
    load_ngram_model,
    train_ngram_model,
    write_ngram_model_atomic,
)


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
        "domain": "general",
        "context": context,
        "pinyin": "fixture",
        "candidates": candidates,
        "gold_text": gold,
        "tags": [],
    }


def test_training_uses_train_and_validation_but_not_test_labels(tmp_path: Path):
    samples = [
        _sample(
            "train-1",
            "train",
            "请执行下面这条",
            "命令",
            ["明令", "命令"],
        ),
        _sample(
            "train-2",
            "train",
            "终端运行这条",
            "命令",
            ["明令", "命令"],
        ),
        _sample(
            "validation-1",
            "validation",
            "现在执行这条",
            "命令",
            ["明令", "命令"],
        ),
        _sample(
            "test-1",
            "test",
            "不要读取这个答案",
            "绝密",
            ["公开", "绝密"],
        ),
    ]

    model, report = train_ngram_model(samples, dataset_sha256="a" * 64)

    assert model.dataset_sha256 == "a" * 64
    assert model.split_counts == {"train": 2, "validation": 1}
    assert "绝密" not in model.candidate_frequencies
    assert report["test_samples_used"] == 0
    assert report["validation"]["covered_samples"] == 1


def test_model_artifact_round_trips_and_ranks_a_contextual_candidate(
    tmp_path: Path,
):
    samples = [
        _sample(
            "train-1",
            "train",
            "请执行下面这条",
            "命令",
            ["明令", "命令"],
        ),
        _sample(
            "train-2",
            "train",
            "终端运行这条",
            "命令",
            ["明令", "命令"],
        ),
        _sample(
            "validation-1",
            "validation",
            "现在执行这条",
            "命令",
            ["明令", "命令"],
        ),
    ]
    model, _ = train_ngram_model(samples, dataset_sha256="b" * 64)
    artifact = tmp_path / "ranker.json.gz"

    write_ngram_model_atomic(artifact, model)
    loaded = load_ngram_model(artifact)
    ranking, confidence = loaded.rank(
        context="请在终端执行这条",
        candidates=["明令", "命令", "明"],
    )

    assert ranking[0] == "命令"
    assert sorted(ranking) == ["命令", "明", "明令"]
    assert 0 <= confidence <= 1
    with gzip.open(artifact, "rt", encoding="utf-8") as file:
        serialized = json.load(file)
    assert serialized["schema_version"] == 2
    assert serialized["model_type"] == "char-ngram-ranker"
    smoothing = serialized["hyperparameters"]["smoothing"]
    assert smoothing == {
        "method": "stupid-backoff",
        "alpha": loaded.backoff_alpha,
        "terminal_numerator": 0.1,
        "terminal_denominator": 1000.0,
    }


def test_language_score_is_the_public_view_of_rank_scoring(tmp_path: Path):
    samples = [
        _sample(
            "train-1",
            "train",
            "请执行下面这条",
            "命令",
            ["明令", "命令"],
        ),
        _sample(
            "validation-1",
            "validation",
            "终端运行这条",
            "命令",
            ["明令", "命令"],
        ),
    ]
    model, _ = train_ngram_model(samples, dataset_sha256="b" * 64)
    artifact = tmp_path / "ranker.json.gz"
    write_ngram_model_atomic(artifact, model)
    loaded = load_ngram_model(artifact)

    score = loaded.language_score("请在终端执行这条", "命令")
    assert score == loaded._language_score("请在终端执行这条", "命令")
    assert score > loaded.language_score("请在终端执行这条", "明令")


def _backoff_samples() -> list[dict]:
    return [
        _sample(
            "train-1",
            "train",
            "你",
            "好天气",
            ["明令", "好天气"],
        ),
        _sample(
            "train-2",
            "train",
            "他说你",
            "好天气",
            ["明令", "好天气"],
        ),
        _sample(
            "validation-1",
            "validation",
            "夸你",
            "好天气",
            ["明令", "好天气"],
        ),
    ]


def test_backoff_falls_to_lower_order_when_high_order_unseen():
    model, _ = train_ngram_model(_backoff_samples(), dataset_sha256="d" * 64)
    alpha = model.backoff_alpha

    # Scoring context "好" + candidate "天气" gives text "^好天气":
    # position 2 ("天"): 3/4/5-gram unseen, bigram "好天" seen -> MLE * alpha**3
    # position 3 ("气"): 4/5-gram unseen, trigram "好天气" seen -> MLE * alpha**2
    expected = (math.log(alpha ** 3) + math.log(alpha ** 2)) / 2

    assert model.language_score("好", "天气") == pytest.approx(expected)
    assert model.language_score("好", "天气") > model.language_score("好", "zz")


def test_unseen_everywhere_character_gets_finite_score():
    model, _ = train_ngram_model(_backoff_samples(), dataset_sha256="d" * 64)

    score = model.language_score("好", "qq")

    assert math.isfinite(score)
    assert score < model.language_score("好", "天气")


def test_short_context_uses_available_orders():
    samples = [
        _sample(
            "train-1",
            "train",
            "",
            "天气",
            ["明令", "天气"],
        ),
        _sample(
            "validation-1",
            "validation",
            "",
            "天气",
            ["明令", "天气"],
        ),
    ]
    model, _ = train_ngram_model(samples, dataset_sha256="e" * 64)

    # context "" + candidate "天" gives text "^天": only order 2 fits and
    # bigram "^天" was seen with prefix "^", so the score is log(alpha**3).
    score = model.language_score("", "天")

    assert score == pytest.approx(math.log(model.backoff_alpha ** 3))
    assert score > model.language_score("", "鸭")


def test_load_rejects_schema_v1_artifact(tmp_path: Path):
    model, _ = train_ngram_model(_backoff_samples(), dataset_sha256="d" * 64)
    payload = model.to_dict()
    payload["schema_version"] = 1
    artifact = tmp_path / "ranker-v1.json.gz"
    with gzip.open(artifact, "wt", encoding="utf-8") as file:
        json.dump(payload, file, ensure_ascii=False)

    with pytest.raises(NGramModelError) as excinfo:
        load_ngram_model(artifact)

    assert "retrain" in str(excinfo.value)


@pytest.mark.parametrize(
    "method,alpha",
    [
        ("kneser-ney", 0.4),
        ("stupid-backoff", 0),
        ("stupid-backoff", 1.5),
        ("stupid-backoff", True),
    ],
)
def test_load_rejects_invalid_smoothing_hyperparameters(
    tmp_path: Path,
    method: str,
    alpha: float,
):
    model, _ = train_ngram_model(_backoff_samples(), dataset_sha256="d" * 64)
    payload = model.to_dict()
    payload["hyperparameters"]["smoothing"]["method"] = method
    payload["hyperparameters"]["smoothing"]["alpha"] = alpha
    artifact = tmp_path / "ranker.json.gz"
    with gzip.open(artifact, "wt", encoding="utf-8") as file:
        json.dump(payload, file, ensure_ascii=False)

    with pytest.raises(NGramModelError) as excinfo:
        load_ngram_model(artifact)

    assert "retrain" in str(excinfo.value)


def test_load_accepts_boundary_backoff_alpha(tmp_path: Path):
    model, _ = train_ngram_model(_backoff_samples(), dataset_sha256="d" * 64)
    payload = model.to_dict()
    payload["hyperparameters"]["smoothing"]["alpha"] = 1.0
    artifact = tmp_path / "ranker.json.gz"
    with gzip.open(artifact, "wt", encoding="utf-8") as file:
        json.dump(payload, file, ensure_ascii=False)

    assert load_ngram_model(artifact).backoff_alpha == 1.0


def test_train_reports_selected_alpha():
    model, report = train_ngram_model(
        _backoff_samples(), dataset_sha256="d" * 64
    )

    selected_alpha = report["selected_hyperparameters"]["backoff_alpha"]

    assert selected_alpha in {0.2, 0.4, 0.6, 0.8}
    assert model.backoff_alpha == selected_alpha


def test_train_ngram_cli_writes_an_artifact_and_provenance_report(
    tmp_path: Path, capsys
):
    dataset = tmp_path / "dataset.jsonl"
    samples = [
        _sample(
            "train-1",
            "train",
            "请执行下面这条",
            "命令",
            ["明令", "命令"],
        ),
        _sample(
            "validation-1",
            "validation",
            "终端执行这条",
            "命令",
            ["明令", "命令"],
        ),
        _sample(
            "test-1",
            "test",
            "测试保留",
            "结果",
            ["结果", "结国"],
        ),
    ]
    dataset.write_text(
        "".join(
            json.dumps(sample, ensure_ascii=False) + "\n"
            for sample in samples
        ),
        encoding="utf-8",
    )
    artifact = tmp_path / "model.json.gz"

    exit_code = main(
        ["train-ngram", str(dataset), "--output", str(artifact)]
    )

    assert exit_code == 0
    assert artifact.is_file()
    report = json.loads(capsys.readouterr().out)
    assert report["test_samples_used"] == 0
    assert report["artifact"]["sha256"]


def test_ngram_worker_implements_the_persistent_ranker_protocol(tmp_path: Path):
    samples = [
        _sample(
            "train-1",
            "train",
            "终端运行这条",
            "命令",
            ["明令", "命令"],
        ),
        _sample(
            "validation-1",
            "validation",
            "请执行这条",
            "命令",
            ["明令", "命令"],
        ),
    ]
    model, _ = train_ngram_model(samples, dataset_sha256="c" * 64)
    artifact = tmp_path / "ranker.json.gz"
    write_ngram_model_atomic(artifact, model)
    request = {
        "schema_version": 1,
        "task": "rerank",
        "request_id": "request-1",
        "context": "现在执行这条",
        "pinyin": "mingling",
        "candidates": [
            {"id": "c0", "text": "明令"},
            {"id": "c1", "text": "命令"},
        ],
    }
    project_root = Path(__file__).resolve().parent.parent
    environment = dict(os.environ)
    environment["RIMEAI_NGRAM_MODEL"] = str(artifact)

    process = subprocess.run(
        [sys.executable, str(project_root / "tools/ngram_ranker_worker.py")],
        input=json.dumps(request, ensure_ascii=False) + "\n",
        text=True,
        capture_output=True,
        env=environment,
        check=False,
    )

    assert process.returncode == 0, process.stderr
    response = json.loads(process.stdout)
    assert response["request_id"] == "request-1"
    assert response["ranking"][0] == "c1"
    assert response["model_artifact_id"].startswith("char-ngram-ranker:sha256-")


# ---------------------------------------------------------------------------
# v3 smoothing: unigram-backoff terminal + extra training corpus
# ---------------------------------------------------------------------------

_V3_WEIGHTS: dict[str, Any] = dict(
    rank_weight_grid=(0.1,),
    frequency_weight_grid=(0.0,),
    language_weight_grid=(1.0,),
    backoff_alpha_grid=(0.4,),
)


def _unigram_samples() -> list[dict]:
    return [
        _sample(
            "train-1",
            "train",
            "他每天练习",
            "命令",
            ["明令", "命令"],
        ),
        _sample(
            "train-2",
            "train",
            "发布执行",
            "命令",
            ["明令", "命令"],
        ),
        _sample(
            "validation-1",
            "validation",
            "下达执行",
            "命令",
            ["明令", "命令"],
        ),
    ]


def test_unigram_terminal_breaks_ties_between_unseen_bigrams():
    samples = _unigram_samples()
    legacy, _ = train_ngram_model(samples, dataset_sha256="u" * 64)
    unigram, _ = train_ngram_model(
        samples,
        dataset_sha256="u" * 64,
        terminal_method_grid=("unigram",),
        **_V3_WEIGHTS,
    )
    assert legacy.unigram_terminal is None
    assert unigram.unigram_terminal is not None

    # "天" appears twice in the training text; "鸭" never does. Under the
    # legacy terminal both score the same constant; under the unigram
    # terminal the frequent character must win.
    context = "练习"  # unseen bigram prefix for both candidates below
    legacy_tie = legacy.language_score(context, "天")
    legacy_duck = legacy.language_score(context, "鸭")
    if legacy_tie == legacy_duck:  # constant terminal on this fixture
        assert unigram.language_score(context, "天") > unigram.language_score(
            context, "鸭"
        )


def test_unigram_terminal_expected_probability_formula():
    model, _ = train_ngram_model(
        _unigram_samples(),
        dataset_sha256="u" * 64,
        terminal_method_grid=("unigram",),
        unigram_add_k_grid=(0.5,),
        **_V3_WEIGHTS,
    )
    terminal = model.unigram_terminal
    assert terminal is not None
    alpha = model.backoff_alpha

    # text for scoring "鸭" after unseen prefix "鸭": terminal fires.
    counts = terminal.unigram_counts
    total = terminal.total_count
    vocab = terminal.vocabulary_size
    expected = math.log(
        ((counts.get("鸭", 0) + 0.5) / (total + 0.5 * vocab)) * alpha**3
    )
    assert model.language_score("鸭", "鸭") == pytest.approx(expected)
    assert terminal.discount == alpha**3
    assert total == sum(counts.values())
    assert vocab == len(counts)


def test_unigram_terminal_round_trips_through_artifact(tmp_path: Path):
    model, _ = train_ngram_model(
        _unigram_samples(),
        dataset_sha256="u" * 64,
        terminal_method_grid=("unigram",),
        **_V3_WEIGHTS,
    )
    artifact = tmp_path / "v3.json.gz"
    write_ngram_model_atomic(artifact, model)
    loaded = load_ngram_model(artifact)

    loaded_terminal = loaded.unigram_terminal
    trained_terminal = model.unigram_terminal
    assert loaded_terminal is not None
    assert trained_terminal is not None
    assert loaded_terminal.unigram_counts == trained_terminal.unigram_counts
    assert loaded_terminal.add_k == trained_terminal.add_k
    assert loaded_terminal.discount == trained_terminal.discount
    for sample in _unigram_samples():
        for candidate in ("命令", "明令", "鸭天"):
            assert loaded.language_score(
                sample["context"], candidate
            ) == model.language_score(sample["context"], candidate)
    with gzip.open(artifact, "rt", encoding="utf-8") as file:
        serialized = json.load(file)
    smoothing = serialized["hyperparameters"]["smoothing"]
    assert serialized["schema_version"] == 3
    assert smoothing["unigram_terminal"] == {
        "add_k": trained_terminal.add_k,
        "discount": trained_terminal.discount,
    }
    assert serialized["unigram_counts"] == trained_terminal.unigram_counts


def test_unigram_terminal_artifact_is_invisible_to_stale_loaders():
    """New-semantics artifacts must self-describe as schema v3 (B-F3).

    The schema bump is the whole fix: the stale loader at f23fa49 and
    earlier gated on ``payload.get("schema_version") != 2``, so a v3
    artifact makes that load fail closed instead of succeeding and
    silently scoring with the legacy terminal. Asserting
    ``schema_version == 3`` (i.e. ``!= 2``) below is exactly the
    "stale loader rejects the new artifact" precondition; the same
    holds for the beam config's v2 bump in test_beam_decoder.py.
    """
    model, _ = train_ngram_model(
        _unigram_samples(),
        dataset_sha256="u" * 64,
        terminal_method_grid=("unigram",),
        **_V3_WEIGHTS,
    )
    payload = model.to_dict()

    assert payload["schema_version"] == 3
    # f23fa49 loader gate: schema_version must equal 2 -> this artifact
    # fails that load instead of loading with legacy semantics.
    assert payload["schema_version"] != 2


def test_legacy_to_dict_key_layout_matches_f23fa49_artifacts():
    """Legacy-terminal artifacts serialize exactly like f23fa49 output.

    Same key set, same version (2), no unigram keys: with sort_keys
    JSON writers (write_ngram_model_atomic) the bytes are identical to
    artifacts produced by the f23fa49 trainer.
    """
    model, _ = train_ngram_model(
        _unigram_samples(), dataset_sha256="u" * 64
    )
    payload = model.to_dict()

    assert payload["schema_version"] == 2
    assert set(payload) == {
        "schema_version",
        "model_type",
        "dataset_sha256",
        "split_counts",
        "hyperparameters",
        "candidate_frequencies",
        "ngram_counts",
        "prefix_counts",
    }
    assert set(payload["hyperparameters"]) == {
        "rank_weight",
        "frequency_weight",
        "language_weight",
        "orders",
        "max_context_characters",
        "top_k",
        "smoothing",
    }
    assert set(payload["hyperparameters"]["smoothing"]) == {
        "method",
        "alpha",
        "terminal_numerator",
        "terminal_denominator",
    }


def test_rerank_window_roundtrips_through_the_artifact(tmp_path: Path):
    # B-F6：重排窗口是制品字段 top_k（load 时读回），rank() 只重排
    # 窗口内候选；窗口外原样拼接，单 eligible 时置信度为 1.0。
    import dataclasses

    samples = [
        _sample("train-1", "train", "请执行下面这条", "命令", ["明令", "命令"]),
        _sample("train-2", "train", "终端运行这条", "命令", ["明令", "命令"]),
        _sample(
            "validation-1", "validation", "现在执行这条", "命令", ["明令", "命令"]
        ),
    ]
    model, _report = train_ngram_model(samples, dataset_sha256="f" * 64)
    tuned = dataclasses.replace(model, top_k=1)
    artifact = tmp_path / "ngram-top-k-1.json.gz"
    with gzip.open(artifact, "wt", encoding="utf-8") as handle:
        json.dump(tuned.to_dict(), handle, ensure_ascii=False)

    loaded = load_ngram_model(artifact)

    assert loaded.top_k == 1
    assert loaded.rerank_window == 1
    ranking, confidence = loaded.rank(
        context="请执行这条", candidates=["明令", "命令", "命令行"]
    )
    # top_k=1：窗口内仅 1 个 eligible → 无重排，窗口外候选逐位保留。
    assert ranking == ["明令", "命令", "命令行"]
    assert confidence == 1.0


def _write_payload(tmp_path: Path, payload: dict) -> Path:
    artifact = tmp_path / "handwritten.json.gz"
    with gzip.open(artifact, "wt", encoding="utf-8") as file:
        json.dump(payload, file, ensure_ascii=False)
    return artifact


def test_load_rejects_schema_v2_carrying_unigram_terminal(tmp_path: Path):
    """Hand-written or corrupted v2 artifacts must fail closed.

    v2 + unigram_terminal is exactly the ambiguous mix the schema bump
    exists to prevent: the stale loader would accept the version and
    silently score with legacy semantics.
    """
    model, _ = train_ngram_model(
        _unigram_samples(),
        dataset_sha256="u" * 64,
        terminal_method_grid=("unigram",),
        **_V3_WEIGHTS,
    )
    payload = model.to_dict()
    payload["schema_version"] = 2

    with pytest.raises(NGramModelError, match="schema v3"):
        load_ngram_model(_write_payload(tmp_path, payload))


def test_load_rejects_schema_v3_without_unigram_terminal(tmp_path: Path):
    model, _ = train_ngram_model(
        _unigram_samples(), dataset_sha256="u" * 64
    )
    payload = model.to_dict()
    payload["schema_version"] = 3

    with pytest.raises(NGramModelError, match="unigram_terminal"):
        load_ngram_model(_write_payload(tmp_path, payload))


@pytest.mark.parametrize("version", [1, 4])
def test_load_rejects_unknown_schema_versions(tmp_path: Path, version: int):
    model, _ = train_ngram_model(
        _unigram_samples(), dataset_sha256="u" * 64
    )
    payload = model.to_dict()
    payload["schema_version"] = version

    with pytest.raises(NGramModelError, match="unsupported"):
        load_ngram_model(_write_payload(tmp_path, payload))


def test_legacy_artifact_scores_bit_for_bit_without_terminal(tmp_path: Path):
    import sys

    model, _ = train_ngram_model(
        _unigram_samples(), dataset_sha256="u" * 64
    )
    assert model.unigram_terminal is None
    artifact = tmp_path / "legacy.json.gz"
    write_ngram_model_atomic(artifact, model)
    loaded = load_ngram_model(artifact)
    assert loaded.unigram_terminal is None

    # Reference implementation of the frozen legacy terminal, run against
    # the loaded artifact's counts: unseen-bigram positions must match
    # bit-for-bit, not approximately.
    project_root = Path(__file__).resolve().parent.parent
    sys.path.insert(0, str(project_root))
    from rimeai_runtime.ngram_ranker import ORDERS

    def legacy_score(context: str, candidate: str) -> float:
        text = "^" + context[-loaded.max_context_characters :] + candidate
        candidate_start = len(text) - len(candidate)
        total = 0.0
        terms = 0
        for position in range(candidate_start, len(text)):
            probability = None
            for order in reversed(ORDERS):
                start = position - order + 1
                if start < 0:
                    continue
                gram = text[start : position + 1]
                count = loaded.ngram_counts[order].get(gram, 0)
                prefix = loaded.prefix_counts[order].get(gram[:-1], 0)
                if count > 0 and prefix > 0:
                    probability = (count / prefix) * loaded.backoff_alpha ** (
                        5 - order
                    )
                    break
            if probability is None:
                gram = text[position - 1 : position + 1]
                count = loaded.ngram_counts[2].get(gram, 0)
                prefix = loaded.prefix_counts[2].get(gram[:-1], 0)
                probability = ((count + 0.1) / (prefix + 1000.0)) * (
                    loaded.backoff_alpha**3
                )
            total += math.log(probability)
            terms += 1
        return total / max(1, terms)

    for context in ("练习", "他每天", "", "执行这条命令的鸭"):
        for candidate in ("鸭天", "命令", "鸭"):
            assert loaded.language_score(context, candidate) == legacy_score(
                context, candidate
            )


def test_extra_train_corpus_joins_counts_and_reports_checks():
    primary = _unigram_samples()
    extra = [
        _sample(
            "extra-1",
            "train",
            "维基语料的第一条",
            "句子",
            ["句子", "剧子"],
        ),
        # duplicate of primary train-1 by text: dropped by dedupe
        _sample(
            "extra-2",
            "train",
            "他每天练习",
            "命令",
            ["明令", "命令"],
        ),
    ]
    model, report = train_ngram_model(
        primary,
        dataset_sha256="u" * 64,
        extra_train_samples=extra,
        **_V3_WEIGHTS,
    )

    assert model.split_counts == {
        "train": 2,
        "validation": 1,
        "extra_train": 1,
    }
    assert model.candidate_frequencies.get("句子") == 1
    extra_report = report["extra_train"]
    assert extra_report["extra_train_input_samples"] == 2
    assert extra_report["duplicate_text_samples_dropped"] == 1
    assert extra_report["extra_train_kept_samples"] == 1
    assert len(extra_report["leakage_checks"]) == 2
    for check in extra_report["leakage_checks"]:
        assert check["id_overlap_samples"] == 0
        assert check["text_overlap_samples"] == 0


def test_extra_train_leakage_raises_on_id_or_text_overlap():
    primary = _unigram_samples()
    leaked_by_id = _sample(
        "validation-1",  # collides with the primary validation id
        "train",
        "完全不同的文本",
        "内容",
        ["内容", "内溶"],
    )
    with pytest.raises(NGramModelError, match="leaks held-out validation"):
        train_ngram_model(
            primary,
            dataset_sha256="u" * 64,
            extra_train_samples=[leaked_by_id],
            **_V3_WEIGHTS,
        )

    leaked_by_text = _sample(
        "extra-clean-id",
        "train",
        "下达执行",  # same normalized text as the primary validation sample
        "命令",
        ["明令", "命令"],
    )
    with pytest.raises(NGramModelError, match="leaks held-out validation"):
        train_ngram_model(
            primary,
            dataset_sha256="u" * 64,
            extra_train_samples=[leaked_by_text],
            **_V3_WEIGHTS,
        )


def test_leakage_check_blocks_prefix_rewrites_beyond_the_counting_window():
    """A rewritten prefix beyond the 40-char window cannot dodge overlap.

    _build_counts only ever sees context[-40:], so a held-out sample
    whose context was rewritten outside that window counts identically
    to the original. The leakage key (_normalized_text) truncates the
    context with the same window, so the overlap is still caught
    instead of silently double-counting (B-F9).
    """
    from rimeai_runtime.ngram_ranker import _normalized_text

    shared_tail = "终端流程演练" * 7  # 42 chars, beyond the counting window
    heldout = _sample(
        "validation-1",
        "validation",
        "甲乙丙丁" + shared_tail,
        "命令",
        ["明令", "命令"],
    )
    rewritten = _sample(
        "extra-rewritten",
        "train",
        "子丑寅卯" + shared_tail,
        "命令",
        ["明令", "命令"],
    )
    primary = [
        _sample("train-1", "train", "他每天练习", "命令", ["明令", "命令"]),
        _sample("train-2", "train", "发布执行", "命令", ["明令", "命令"]),
        heldout,
    ]

    # Same counting key ([-40:] window + gold), different raw context:
    # the rewrite used to make the two keys differ and dodge the check.
    assert _normalized_text(rewritten) == _normalized_text(heldout)
    assert rewritten["context"] != heldout["context"]

    with pytest.raises(NGramModelError, match="leaks held-out validation"):
        train_ngram_model(
            primary,
            dataset_sha256="u" * 64,
            extra_train_samples=[rewritten],
            **_V3_WEIGHTS,
        )


def test_extra_train_rejects_non_train_splits():
    primary = _unigram_samples()
    intruder = _sample(
        "extra-test",
        "test",
        "测试样本",
        "内容",
        ["内容", "内溶"],
    )
    with pytest.raises(NGramModelError, match="train split"):
        train_ngram_model(
            primary,
            dataset_sha256="u" * 64,
            extra_train_samples=[intruder],
            **_V3_WEIGHTS,
        )


def test_terminal_method_grid_rejects_unknown_methods():
    with pytest.raises(NGramModelError, match="unknown terminal method"):
        train_ngram_model(
            _unigram_samples(),
            dataset_sha256="u" * 64,
            terminal_method_grid=("kneser-ney",),
            **_V3_WEIGHTS,
        )


def test_train_ngram_cli_supports_extra_dataset_and_unigram_terminal(
    tmp_path: Path, capsys
):
    primary = tmp_path / "primary.jsonl"
    extra = tmp_path / "extra.jsonl"
    samples = _unigram_samples()
    primary.write_text(
        "".join(
            json.dumps(sample, ensure_ascii=False) + "\n"
            for sample in samples
        ),
        encoding="utf-8",
    )
    extra.write_text(
        json.dumps(
            _sample("extra-1", "train", "维基语料第一条", "句子", ["句子"]),
            ensure_ascii=False,
        )
        + "\n"
        + json.dumps(
            _sample(
                "extra-holdout",
                "validation",
                "绝不能进入训练",
                "机密",
                ["机密"],
            ),
            ensure_ascii=False,
        )
        + "\n",
        encoding="utf-8",
    )
    artifact = tmp_path / "v3-candidate.json.gz"

    exit_code = main(
        [
            "train-ngram",
            str(primary),
            "--output",
            str(artifact),
            "--extra-train-dataset",
            str(extra),
            "--terminal-method",
            "unigram",
        ]
    )

    assert exit_code == 0
    report = json.loads(capsys.readouterr().out)
    assert report["selected_hyperparameters"]["terminal_method"] == "unigram"
    assert report["extra_train"]["extra_train_kept_samples"] == 1
    # only the extra corpus's train split entered counting
    assert "机密" not in json.dumps(
        json.loads(
            gzip.open(artifact, "rt", encoding="utf-8").read()
        )["candidate_frequencies"]
    )
    loaded = load_ngram_model(artifact)
    assert loaded.unigram_terminal is not None
