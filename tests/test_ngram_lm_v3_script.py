"""End-to-end regression test for tools/ngram_lm_v3.py.

Runs the v3 training/report script against tiny synthetic corpora and
asserts the artifacts, leakage discipline, and report structure. The
fixture deliberately contains a held-out sample in the extra corpus in
one test to prove the script fails closed on leakage.
"""

import json
import subprocess
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
SCRIPT = PROJECT_ROOT / "tools/ngram_lm_v3.py"


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
        "pinyin": "mingling",
        "candidates": candidates,
        "gold_text": gold,
        "tags": [],
    }


def _primary_samples() -> list[dict]:
    return [
        _sample("t1", "train", "请执行下面这条", "命令", ["明令", "命令"]),
        _sample("t2", "train", "终端运行这条", "命令", ["明令", "命令"]),
        _sample("t3", "train", "他每天练习", "命令", ["明令", "命令"]),
        _sample("t4", "train", "下达执行", "命令", ["明令", "命令"]),
        _sample(
            "v1", "validation", "现在执行这条", "命令", ["明令", "命令"]
        ),
        _sample(
            "v2", "validation", "立刻执行这条", "命令", ["明令", "命令"]
        ),
        _sample(
            "s1", "test", "最终执行这条", "命令", ["明令", "命令"]
        ),
        _sample(
            "s2", "test", "再次执行这条", "命令", ["明令", "命令"]
        ),
    ]


def _extra_samples() -> list[dict]:
    return [
        _sample("z1", "train", "维基语料第一条", "句子", ["句子", "剧子"]),
        _sample("z2", "train", "维基语料第二条", "文章", ["文章", "蚊子"]),
        _sample(
            "zv1", "validation", "维基验证", "条目", ["条目", "调目"]
        ),
        _sample("zs1", "test", "维基测试", "条目", ["条目", "调目"]),
    ]


def _write_jsonl(path: Path, samples: list[dict]) -> None:
    path.write_text(
        "".join(
            json.dumps(sample, ensure_ascii=False) + "\n"
            for sample in samples
        ),
        encoding="utf-8",
    )


def _build_environment(tmp_path: Path) -> dict[str, Path]:
    from rimeai_runtime.beam_decoder import (
        train_beam_decoder_config,
        write_beam_config_atomic,
    )
    from rimeai_runtime.ngram_ranker import (
        train_ngram_model,
        write_ngram_model_atomic,
    )
    from rimeai_runtime.pinyin_guard import PinyinGuard

    models = tmp_path / "models"
    models.mkdir()
    reports = tmp_path / "reports"
    reports.mkdir()
    primary = tmp_path / "primary.jsonl"
    extra = tmp_path / "extra.jsonl"
    _write_jsonl(primary, _primary_samples())
    _write_jsonl(extra, _extra_samples())
    dictionary = (
        PROJECT_ROOT / ".rimeai/rime/shared/luna_pinyin.dict.yaml"
    )
    incumbent, _ = train_ngram_model(
        _primary_samples(), dataset_sha256="0" * 64
    )
    incumbent_sha = write_ngram_model_atomic(
        models / "incumbent.json.gz", incumbent
    )
    guard = PinyinGuard.from_rime_dictionary(dictionary)
    config, _ = train_beam_decoder_config(
        _primary_samples(),
        incumbent,
        guard,
        dataset_sha256="0" * 64,
        language_model_sha256=incumbent_sha,
        dictionary_sha256="1" * 64,
    )
    write_beam_config_atomic(models / "incumbent-beam.json", config)
    return {
        "primary": primary,
        "extra": extra,
        "dictionary": dictionary,
        "incumbent": models / "incumbent.json.gz",
        "incumbent_beam": models / "incumbent-beam.json",
        "model": models / "v3-candidate.json.gz",
        "beam": models / "v5-candidate.json",
        "report": reports / "ngram-lm-v3.json",
    }


def _run_script(paths: dict[str, Path]) -> subprocess.CompletedProcess:
    return subprocess.run(
        [
            sys.executable,
            str(SCRIPT),
            "--dataset",
            str(paths["primary"]),
            "--extra-dataset",
            str(paths["extra"]),
            "--rime-dictionary",
            str(paths["dictionary"]),
            "--incumbent-model",
            str(paths["incumbent"]),
            "--incumbent-beam-config",
            str(paths["incumbent_beam"]),
            "--output-model",
            str(paths["model"]),
            "--output-beam-config",
            str(paths["beam"]),
            "--output-report",
            str(paths["report"]),
        ],
        capture_output=True,
        text=True,
        cwd=str(PROJECT_ROOT),
        check=False,
    )


def test_v3_script_produces_artifacts_and_structured_report(tmp_path: Path):
    paths = _build_environment(tmp_path)

    process = _run_script(paths)

    assert process.returncode == 0, process.stderr
    assert paths["model"].is_file()
    assert paths["beam"].is_file()
    report = json.loads(paths["report"].read_text(encoding="utf-8"))
    assert report["kind"] == "ngram-lm-v3"
    assert set(report["scan"]["arms"]) == {
        "A_smoothing_legacy",
        "A_smoothing_unigram",
        "B_extra_legacy",
        "B_extra_unigram",
    }
    assert set(report["comparison"]) == {
        "validation",
        "p0_test",
        "zhwiki_test",
    }
    for split in report["comparison"].values():
        for arm in split.values():
            assert set(arm["beam"]) == {
                "min_confidence_0.00",
                "min_confidence_0.60",
            }
    assert len(report["leakage_checks"]) == 4
    for check in report["leakage_checks"]:
        assert check["id_overlap_samples"] == 0
        assert check["text_overlap_samples"] == 0
    extra_report = report["scan"]["arms"]["B_extra_unigram"]["train_report"][
        "extra_train"
    ]
    assert extra_report["extra_train_kept_samples"] == 2
    assert report["recommendation"] in {
        "keep-v2",
        "replace-v2-with-v3-candidate",
    }
    # The candidate artifact itself loads and carries the scanned
    # smoothing hyperparameters.
    from rimeai_runtime.ngram_ranker import load_ngram_model

    loaded = load_ngram_model(paths["model"])
    selected = report["scan"]["arms"][report["scan"]["selected_arm"]][
        "train_report"
    ]["selected_hyperparameters"]
    assert loaded.backoff_alpha == selected["backoff_alpha"]
    assert (
        loaded.unigram_terminal is not None
    ) == (selected["terminal_method"] == "unigram")


def test_v3_script_fails_closed_when_extra_corpus_leaks_test(tmp_path: Path):
    paths = _build_environment(tmp_path)
    leaked = _extra_samples()
    leaked.append(
        # exact duplicate of the primary validation sample by text
        _sample("z-leak", "train", "现在执行这条", "命令", ["明令", "命令"])
    )
    _write_jsonl(paths["extra"], leaked)

    process = _run_script(paths)

    assert process.returncode == 2
    assert "leaks" in process.stderr
    assert not paths["report"].exists()
    assert not paths["model"].exists()
    assert not paths["beam"].exists()


def test_v3_script_refuses_to_overwrite_inputs(tmp_path: Path):
    paths = _build_environment(tmp_path)
    process = subprocess.run(
        [
            sys.executable,
            str(SCRIPT),
            "--dataset",
            str(paths["primary"]),
            "--extra-dataset",
            str(paths["extra"]),
            "--rime-dictionary",
            str(paths["dictionary"]),
            "--incumbent-model",
            str(paths["incumbent"]),
            "--incumbent-beam-config",
            str(paths["incumbent_beam"]),
            "--output-model",
            str(paths["incumbent"]),
            "--output-beam-config",
            str(paths["beam"]),
            "--output-report",
            str(paths["report"]),
        ],
        capture_output=True,
        text=True,
        cwd=str(PROJECT_ROOT),
        check=False,
    )

    assert process.returncode == 2
    assert "must not overwrite" in process.stderr
