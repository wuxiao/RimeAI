import hashlib
import json
import subprocess
import sys
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]


def test_validate_accepts_a_valid_rerank_dataset(tmp_path):
    dataset = tmp_path / "samples.jsonl"
    dataset.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "id": "general-001",
                "split": "test",
                "domain": "general",
                "context": "我们需要给数据库增加一个",
                "pinyin": "suoyin",
                "candidates": ["所以", "索引", "缩印"],
                "gold_text": "索引",
                "tags": ["context-disambiguation"],
            },
            ensure_ascii=False,
        )
        + "\n",
        encoding="utf-8",
    )

    result = subprocess.run(
        [sys.executable, "-m", "rimeai_eval", "validate", str(dataset)],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout) == {
        "schema_version": 1,
        "samples": 1,
        "domains": {"general": 1},
        "splits": {"test": 1},
    }
    assert result.stderr == ""


def test_validate_rejects_duplicate_candidates_without_a_traceback(tmp_path):
    dataset = tmp_path / "invalid.jsonl"
    dataset.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "id": "general-001",
                "split": "test",
                "domain": "general",
                "context": "",
                "pinyin": "suoyin",
                "candidates": ["索引", "索引"],
                "gold_text": "索引",
            },
            ensure_ascii=False,
        )
        + "\n",
        encoding="utf-8",
    )

    result = subprocess.run(
        [sys.executable, "-m", "rimeai_eval", "validate", str(dataset)],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 2
    assert result.stdout == ""
    assert (
        result.stderr
        == f"error: {dataset}:1: candidates must contain unique values\n"
    )


def test_evaluate_reports_baseline_coverage_and_ranking_metrics(tmp_path):
    dataset = tmp_path / "evaluation.jsonl"
    samples = [
        {
            "schema_version": 1,
            "id": "general-001",
            "split": "test",
            "domain": "general",
            "context": "我们需要给数据库增加一个",
            "pinyin": "suoyin",
            "candidates": ["所以", "索引"],
            "gold_text": "索引",
        },
        {
            "schema_version": 1,
            "id": "developer-001",
            "split": "test",
            "domain": "developer",
            "context": "请在终端执行这条",
            "pinyin": "mingling",
            "candidates": ["命令", "明令"],
            "gold_text": "命令",
        },
        {
            "schema_version": 1,
            "id": "developer-002",
            "split": "test",
            "domain": "developer",
            "context": "这个答案不在候选中",
            "pinyin": "mubiao",
            "candidates": ["目标", "木标"],
            "gold_text": "目的",
        },
    ]
    dataset.write_text(
        "".join(json.dumps(sample, ensure_ascii=False) + "\n" for sample in samples),
        encoding="utf-8",
    )

    result = subprocess.run(
        [
            sys.executable,
            "-m",
            "rimeai_eval",
            "evaluate",
            str(dataset),
            "--ranker",
            "baseline",
        ],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    report = json.loads(result.stdout)
    assert report["schema_version"] == 1
    assert report["dataset"] == {
        "split": "test",
        "samples": 3,
        "covered_samples": 2,
        "top_k_coverage": 0.666667,
        "sha256": hashlib.sha256(dataset.read_bytes()).hexdigest(),
    }
    assert report["ranker"] == {"name": "baseline", "errors": 0}
    assert report["metrics"] == {
        "top1_accuracy": 0.333333,
        "conditional_top1_accuracy": 0.5,
        "mrr": 0.5,
        "conditional_mrr": 0.75,
        "cer": 0.5,
        "conditional_cer": 0.5,
    }
    assert report["latency_ms"]["samples"] == 3
    assert report["latency_ms"]["p50"] >= 0
    assert report["latency_ms"]["p95"] >= 0
    assert "我们需要给数据库增加一个" not in result.stdout
    assert "suoyin" not in result.stdout
    assert result.stderr == ""


def test_validate_rejects_an_unsupported_schema_version(tmp_path):
    dataset = tmp_path / "unsupported.jsonl"
    dataset.write_text(
        json.dumps(
            {
                "schema_version": 2,
                "id": "general-001",
                "split": "test",
                "domain": "general",
                "context": "",
                "pinyin": "suoyin",
                "candidates": ["索引"],
                "gold_text": "索引",
            },
            ensure_ascii=False,
        )
        + "\n",
        encoding="utf-8",
    )

    result = subprocess.run(
        [sys.executable, "-m", "rimeai_eval", "validate", str(dataset)],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 2
    assert result.stdout == ""
    assert (
        result.stderr
        == f"error: {dataset}:1: schema_version must be 1\n"
    )


def test_validate_reports_malformed_json_with_its_line_number(tmp_path):
    dataset = tmp_path / "malformed.jsonl"
    dataset.write_text('{"schema_version": 1,\n', encoding="utf-8")

    result = subprocess.run(
        [sys.executable, "-m", "rimeai_eval", "validate", str(dataset)],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 2
    assert result.stdout == ""
    assert result.stderr.startswith(f"error: {dataset}:1: invalid JSON: ")
    assert "Traceback" not in result.stderr


def test_validate_reports_invalid_utf8_with_its_line_number(tmp_path):
    dataset = tmp_path / "invalid-utf8.jsonl"
    dataset.write_bytes(b"\xff\n")

    result = subprocess.run(
        [sys.executable, "-m", "rimeai_eval", "validate", str(dataset)],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 2
    assert result.stdout == ""
    assert (
        result.stderr
        == f"error: {dataset}:1: line must be valid UTF-8\n"
    )
    assert "Traceback" not in result.stderr


def test_capture_builds_a_valid_dataset_from_a_candidate_process(tmp_path):
    source = tmp_path / "source.jsonl"
    source.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "id": "developer-001",
                "split": "test",
                "domain": "developer",
                "context": "我们需要给数据库增加一个",
                "pinyin": "suoyin",
                "gold_text": "索引",
                "tags": ["technical-term"],
            },
            ensure_ascii=False,
        )
        + "\n",
        encoding="utf-8",
    )
    worker = tmp_path / "candidate_worker.py"
    worker.write_text(
        "\n".join(
            [
                "import json",
                "import sys",
                "for line in sys.stdin:",
                "    request = json.loads(line)",
                "    print(json.dumps({",
                "        'schema_version': 1,",
                "        'request_id': request['request_id'],",
                "        'candidates': ['所以', '索引', '缩印'],",
                "        'engine': {",
                "            'name': 'librime',",
                "            'version': '1.17.0',",
                "            'schema_id': 'luna_pinyin_simp',",
                "            'data_sha256': 'a' * 64,",
                "        },",
                "    }, ensure_ascii=False), flush=True)",
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    config = tmp_path / "candidate.json"
    config.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "name": "test-librime",
                "command": [sys.executable, str(worker)],
                "timeout_ms": 400,
            }
        ),
        encoding="utf-8",
    )
    output = tmp_path / "captured.jsonl"
    provenance = tmp_path / "captured.provenance.json"

    result = subprocess.run(
        [
            sys.executable,
            "-m",
            "rimeai_eval",
            "capture",
            str(source),
            "--candidate-config",
            str(config),
            "--output",
            str(output),
            "--provenance-output",
            str(provenance),
        ],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout) == {
        "candidate_source": "test-librime",
        "captured_samples": 1,
        "engine": {
            "data_sha256": "a" * 64,
            "name": "librime",
            "schema_id": "luna_pinyin_simp",
            "version": "1.17.0",
        },
        "schema_version": 1,
    }
    captured = json.loads(output.read_text(encoding="utf-8"))
    assert captured["candidates"] == ["所以", "索引", "缩印"]
    assert captured["gold_text"] == "索引"
    assert captured["context"] == "我们需要给数据库增加一个"
    provenance_report = json.loads(provenance.read_text(encoding="utf-8"))
    assert provenance_report["dataset_sha256"] == hashlib.sha256(
        output.read_bytes()
    ).hexdigest()
    assert provenance_report["source_sha256"] == hashlib.sha256(
        source.read_bytes()
    ).hexdigest()
    assert provenance_report["latency_ms"]["samples"] == 1
    assert provenance_report["latency_ms"]["p50"] >= 0
    assert (
        provenance_report["latency_ms"]["p95"]
        >= provenance_report["latency_ms"]["p50"]
    )
    assert "context" not in provenance_report
    assert "gold_text" not in provenance_report


def test_validate_rejects_a_missing_required_text_field(tmp_path):
    dataset = tmp_path / "missing-pinyin.jsonl"
    dataset.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "id": "general-001",
                "split": "test",
                "domain": "general",
                "context": "",
                "candidates": ["索引"],
                "gold_text": "索引",
            },
            ensure_ascii=False,
        )
        + "\n",
        encoding="utf-8",
    )

    result = subprocess.run(
        [sys.executable, "-m", "rimeai_eval", "validate", str(dataset)],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 2
    assert result.stdout == ""
    assert result.stderr == f"error: {dataset}:1: pinyin must be a non-empty string\n"


def test_validate_rejects_an_invalid_candidate_list(tmp_path):
    dataset = tmp_path / "invalid-candidates.jsonl"
    dataset.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "id": "general-001",
                "split": "test",
                "domain": "general",
                "context": "",
                "pinyin": "suoyin",
                "candidates": [],
                "gold_text": "索引",
            },
            ensure_ascii=False,
        )
        + "\n",
        encoding="utf-8",
    )

    result = subprocess.run(
        [sys.executable, "-m", "rimeai_eval", "validate", str(dataset)],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 2
    assert result.stdout == ""
    assert (
        result.stderr
        == f"error: {dataset}:1: candidates must contain 1 to 20 non-empty strings\n"
    )


def test_validate_rejects_duplicate_sample_ids(tmp_path):
    dataset = tmp_path / "duplicate-ids.jsonl"
    sample = {
        "schema_version": 1,
        "id": "general-001",
        "split": "test",
        "domain": "general",
        "context": "",
        "pinyin": "suoyin",
        "candidates": ["索引"],
        "gold_text": "索引",
    }
    dataset.write_text(
        json.dumps(sample, ensure_ascii=False)
        + "\n"
        + json.dumps(sample, ensure_ascii=False)
        + "\n",
        encoding="utf-8",
    )

    result = subprocess.run(
        [sys.executable, "-m", "rimeai_eval", "validate", str(dataset)],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 2
    assert result.stdout == ""
    assert result.stderr == f"error: {dataset}:2: duplicate sample id 'general-001'\n"


def test_validate_requires_a_domain(tmp_path):
    dataset = tmp_path / "missing-domain.jsonl"
    dataset.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "id": "general-001",
                "split": "test",
                "context": "",
                "pinyin": "suoyin",
                "candidates": ["索引"],
                "gold_text": "索引",
            },
            ensure_ascii=False,
        )
        + "\n",
        encoding="utf-8",
    )

    result = subprocess.run(
        [sys.executable, "-m", "rimeai_eval", "validate", str(dataset)],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 2
    assert result.stdout == ""
    assert result.stderr == f"error: {dataset}:1: domain must be a non-empty string\n"


def test_validate_requires_a_known_split(tmp_path):
    dataset = tmp_path / "unknown-split.jsonl"
    dataset.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "id": "general-001",
                "split": "production",
                "domain": "general",
                "context": "",
                "pinyin": "suoyin",
                "candidates": ["索引"],
                "gold_text": "索引",
            },
            ensure_ascii=False,
        )
        + "\n",
        encoding="utf-8",
    )

    result = subprocess.run(
        [sys.executable, "-m", "rimeai_eval", "validate", str(dataset)],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 2
    assert result.stdout == ""
    assert (
        result.stderr
        == f"error: {dataset}:1: split must be one of train, validation, or test\n"
    )


def test_validate_requires_non_empty_gold_text(tmp_path):
    dataset = tmp_path / "missing-gold.jsonl"
    dataset.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "id": "general-001",
                "split": "test",
                "domain": "general",
                "context": "",
                "pinyin": "suoyin",
                "candidates": ["索引"],
                "gold_text": "",
            },
            ensure_ascii=False,
        )
        + "\n",
        encoding="utf-8",
    )

    result = subprocess.run(
        [sys.executable, "-m", "rimeai_eval", "validate", str(dataset)],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 2
    assert result.stdout == ""
    assert (
        result.stderr
        == f"error: {dataset}:1: gold_text must be a non-empty string\n"
    )


def test_validate_requires_context_to_be_text(tmp_path):
    dataset = tmp_path / "invalid-context.jsonl"
    dataset.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "id": "general-001",
                "split": "test",
                "domain": "general",
                "context": None,
                "pinyin": "suoyin",
                "candidates": ["索引"],
                "gold_text": "索引",
            },
            ensure_ascii=False,
        )
        + "\n",
        encoding="utf-8",
    )

    result = subprocess.run(
        [sys.executable, "-m", "rimeai_eval", "validate", str(dataset)],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 2
    assert result.stdout == ""
    assert result.stderr == f"error: {dataset}:1: context must be a string\n"


def test_validate_rejects_an_empty_dataset(tmp_path):
    dataset = tmp_path / "empty.jsonl"
    dataset.write_text("\n", encoding="utf-8")

    result = subprocess.run(
        [sys.executable, "-m", "rimeai_eval", "validate", str(dataset)],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 2
    assert result.stdout == ""
    assert result.stderr == f"error: {dataset}: dataset contains no samples\n"


def test_evaluate_reports_metrics_for_each_domain(tmp_path):
    dataset = tmp_path / "domains.jsonl"
    samples = [
        {
            "schema_version": 1,
            "id": "general-001",
            "split": "test",
            "domain": "general",
            "context": "",
            "pinyin": "suoyin",
            "candidates": ["所以", "索引"],
            "gold_text": "索引",
        },
        {
            "schema_version": 1,
            "id": "developer-001",
            "split": "test",
            "domain": "developer",
            "context": "",
            "pinyin": "mingling",
            "candidates": ["命令", "明令"],
            "gold_text": "命令",
        },
    ]
    dataset.write_text(
        "".join(json.dumps(sample, ensure_ascii=False) + "\n" for sample in samples),
        encoding="utf-8",
    )

    result = subprocess.run(
        [
            sys.executable,
            "-m",
            "rimeai_eval",
            "evaluate",
            str(dataset),
            "--ranker",
            "baseline",
        ],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    domain_slices = json.loads(result.stdout)["slices"]["domain"]
    assert domain_slices == {
        "developer": {
            "samples": 1,
            "covered_samples": 1,
            "top_k_coverage": 1.0,
            "top1_accuracy": 1.0,
            "conditional_top1_accuracy": 1.0,
            "mrr": 1.0,
            "conditional_mrr": 1.0,
            "cer": 0.0,
            "conditional_cer": 0.0,
        },
        "general": {
            "samples": 1,
            "covered_samples": 1,
            "top_k_coverage": 1.0,
            "top1_accuracy": 0.0,
            "conditional_top1_accuracy": 0.0,
            "mrr": 0.5,
            "conditional_mrr": 0.5,
            "cer": 1.0,
            "conditional_cer": 1.0,
        },
    }


def test_evaluate_can_use_a_persistent_local_ranker_process(tmp_path):
    dataset = tmp_path / "external.jsonl"
    dataset.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "id": "developer-001",
                "split": "test",
                "domain": "developer",
                "context": "请在终端执行这条",
                "pinyin": "mingling",
                "candidates": ["明令", "命令"],
                "gold_text": "命令",
            },
            ensure_ascii=False,
        )
        + "\n",
        encoding="utf-8",
    )
    worker = tmp_path / "reverse_ranker.py"
    worker.write_text(
        "\n".join(
            [
                "import json",
                "import sys",
                "for line in sys.stdin:",
                "    request = json.loads(line)",
                "    assert 'gold_text' not in request",
                "    candidate_ids = [item['id'] for item in request['candidates']]",
                "    response = {",
                "        'schema_version': 1,",
                "        'request_id': request['request_id'],",
                "        'ranking': list(reversed(candidate_ids)),",
                "        'confidence': 0.9,",
                "        'model_artifact_id': 'fake-reverse-v1',",
                "    }",
                "    print(json.dumps(response), flush=True)",
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    config = tmp_path / "ranker.json"
    config.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "name": "fake-reverse",
                "command": [sys.executable, str(worker)],
                "timeout_ms": 400,
            }
        ),
        encoding="utf-8",
    )

    result = subprocess.run(
        [
            sys.executable,
            "-m",
            "rimeai_eval",
            "evaluate",
            str(dataset),
            "--ranker",
            "command",
            "--ranker-config",
            str(config),
        ],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    report = json.loads(result.stdout)
    ranker_report = report["ranker"]
    assert ranker_report["resource"]["peak_rss_bytes"] > 0
    assert ranker_report["cold_start_ms"] >= 0
    assert {
        key: value
        for key, value in ranker_report.items()
        if key not in {"resource", "cold_start_ms"}
    } == {
        "name": "fake-reverse",
        "errors": 0,
        "model_artifact_id": "fake-reverse-v1",
        "attempted_samples": 1,
        "successful_samples": 1,
    }
    assert report["metrics"]["top1_accuracy"] == 1.0
    assert report["metrics"]["conditional_top1_accuracy"] == 1.0
    assert result.stderr == ""


def test_evaluate_counts_invalid_ranker_responses_and_uses_baseline_fallback(
    tmp_path,
):
    dataset = tmp_path / "fallback.jsonl"
    dataset.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "id": "general-001",
                "split": "test",
                "domain": "general",
                "context": "",
                "pinyin": "suoyin",
                "candidates": ["索引", "所以"],
                "gold_text": "索引",
            },
            ensure_ascii=False,
        )
        + "\n",
        encoding="utf-8",
    )
    worker = tmp_path / "broken_ranker.py"
    worker.write_text(
        "\n".join(
            [
                "import json",
                "import sys",
                "for line in sys.stdin:",
                "    request = json.loads(line)",
                "    response = {",
                "        'schema_version': 1,",
                "        'request_id': request['request_id'],",
                "        'ranking': ['unknown-candidate'],",
                "    }",
                "    print(json.dumps(response), flush=True)",
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    config = tmp_path / "ranker.json"
    config.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "name": "broken-ranker",
                "command": [sys.executable, str(worker)],
                "timeout_ms": 400,
            }
        ),
        encoding="utf-8",
    )

    result = subprocess.run(
        [
            sys.executable,
            "-m",
            "rimeai_eval",
            "evaluate",
            str(dataset),
            "--ranker",
            "command",
            "--ranker-config",
            str(config),
        ],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    report = json.loads(result.stdout)
    assert report["ranker"] == {
        "name": "broken-ranker",
        "errors": 1,
        "attempted_samples": 1,
        "successful_samples": 0,
    }
    assert report["metrics"]["top1_accuracy"] == 1.0
    assert report["metrics"]["conditional_top1_accuracy"] == 1.0
    assert result.stderr == ""


def test_evaluate_enforces_the_local_ranker_deadline(tmp_path):
    dataset = tmp_path / "timeout.jsonl"
    dataset.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "id": "general-001",
                "split": "test",
                "domain": "general",
                "context": "",
                "pinyin": "suoyin",
                "candidates": ["索引", "所以"],
                "gold_text": "索引",
            },
            ensure_ascii=False,
        )
        + "\n",
        encoding="utf-8",
    )
    worker = tmp_path / "slow_ranker.py"
    worker.write_text(
        "\n".join(
            [
                "import json",
                "import sys",
                "import time",
                "for line in sys.stdin:",
                "    request = json.loads(line)",
                "    time.sleep(0.25)",
                "    candidate_ids = [item['id'] for item in request['candidates']]",
                "    print(json.dumps({",
                "        'schema_version': 1,",
                "        'request_id': request['request_id'],",
                "        'ranking': candidate_ids,",
                "    }), flush=True)",
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    config = tmp_path / "ranker.json"
    config.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "name": "slow-ranker",
                "command": [sys.executable, str(worker)],
                "timeout_ms": 20,
            }
        ),
        encoding="utf-8",
    )

    result = subprocess.run(
        [
            sys.executable,
            "-m",
            "rimeai_eval",
            "evaluate",
            str(dataset),
            "--ranker",
            "command",
            "--ranker-config",
            str(config),
        ],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
        check=False,
        timeout=2,
    )

    assert result.returncode == 0, result.stderr
    report = json.loads(result.stdout)
    assert report["ranker"] == {
        "name": "slow-ranker",
        "errors": 1,
        "attempted_samples": 1,
        "successful_samples": 0,
    }
    assert 15 <= report["latency_ms"]["p95"] < 150
    assert report["metrics"]["top1_accuracy"] == 1.0


def test_evaluate_rejects_out_of_range_ranker_confidence(tmp_path):
    dataset = tmp_path / "confidence.jsonl"
    dataset.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "id": "general-001",
                "split": "test",
                "domain": "general",
                "context": "",
                "pinyin": "suoyin",
                "candidates": ["索引", "所以"],
                "gold_text": "索引",
            },
            ensure_ascii=False,
        )
        + "\n",
        encoding="utf-8",
    )
    worker = tmp_path / "invalid_confidence_ranker.py"
    worker.write_text(
        "\n".join(
            [
                "import json",
                "import sys",
                "for line in sys.stdin:",
                "    request = json.loads(line)",
                "    candidate_ids = [item['id'] for item in request['candidates']]",
                "    print(json.dumps({",
                "        'schema_version': 1,",
                "        'request_id': request['request_id'],",
                "        'ranking': list(reversed(candidate_ids)),",
                "        'confidence': 2.0,",
                "        'model_artifact_id': 'bad-confidence-v1',",
                "    }), flush=True)",
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    config = tmp_path / "ranker.json"
    config.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "name": "invalid-confidence",
                "command": [sys.executable, str(worker)],
                "timeout_ms": 400,
            }
        ),
        encoding="utf-8",
    )

    result = subprocess.run(
        [
            sys.executable,
            "-m",
            "rimeai_eval",
            "evaluate",
            str(dataset),
            "--ranker",
            "command",
            "--ranker-config",
            str(config),
        ],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    report = json.loads(result.stdout)
    assert report["ranker"] == {
        "name": "invalid-confidence",
        "errors": 1,
        "attempted_samples": 1,
        "successful_samples": 0,
    }
    assert report["metrics"]["top1_accuracy"] == 1.0


def test_evaluate_includes_a_transparent_context_repeat_rule_baseline(tmp_path):
    dataset = tmp_path / "context-repeat.jsonl"
    dataset.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "id": "developer-001",
                "split": "test",
                "domain": "developer",
                "context": "PostgreSQL 的索引非常重要，现在还需要新增一个",
                "pinyin": "suoyin",
                "candidates": ["所以", "索引"],
                "gold_text": "索引",
            },
            ensure_ascii=False,
        )
        + "\n",
        encoding="utf-8",
    )

    result = subprocess.run(
        [
            sys.executable,
            "-m",
            "rimeai_eval",
            "evaluate",
            str(dataset),
            "--ranker",
            "context-repeat",
        ],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    report = json.loads(result.stdout)
    assert report["ranker"] == {"name": "context-repeat", "errors": 0}
    assert report["metrics"]["top1_accuracy"] == 1.0
    assert report["metrics"]["conditional_top1_accuracy"] == 1.0


def test_evaluate_can_write_opt_in_per_sample_audit_details(tmp_path):
    dataset = tmp_path / "details.jsonl"
    dataset.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "id": "developer-001",
                "split": "test",
                "domain": "developer",
                "context": "数据库需要建立索引",
                "pinyin": "suoyin",
                "candidates": ["所以", "索引"],
                "gold_text": "索引",
                "tags": ["technical-term"],
            },
            ensure_ascii=False,
        )
        + "\n",
        encoding="utf-8",
    )
    details_output = tmp_path / "details-output.jsonl"

    result = subprocess.run(
        [
            sys.executable,
            "-m",
            "rimeai_eval",
            "evaluate",
            str(dataset),
            "--ranker",
            "context-repeat",
            "--details-output",
            str(details_output),
        ],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    assert "数据库需要建立索引" not in result.stdout
    detail = json.loads(details_output.read_text(encoding="utf-8"))
    assert detail["schema_version"] == 1
    assert detail["id"] == "developer-001"
    assert detail["baseline_candidates"] == ["所以", "索引"]
    assert detail["ranked_candidates"] == ["索引", "所以"]
    assert detail["applied_candidates"] == ["索引", "所以"]
    assert detail["gold_text"] == "索引"
    assert detail["confidence"] == 1.0
    assert detail["applied"] is True
    assert detail["ranker_error"] is None
    assert detail["latency_ms"] >= 0


def test_evaluate_reports_metrics_for_each_dataset_tag(tmp_path):
    dataset = tmp_path / "tags.jsonl"
    samples = [
        {
            "schema_version": 1,
            "id": "developer-001",
            "split": "test",
            "domain": "developer",
            "context": "",
            "pinyin": "apipeizhi",
            "candidates": ["API 配置", "API 陪置"],
            "gold_text": "API 配置",
            "tags": ["mixed-script", "technical-term"],
        },
        {
            "schema_version": 1,
            "id": "developer-002",
            "split": "test",
            "domain": "developer",
            "context": "",
            "pinyin": "gitfenzhi",
            "candidates": ["Git 分支", "Git 分之"],
            "gold_text": "Git 分支",
            "tags": ["mixed-script"],
        },
    ]
    dataset.write_text(
        "".join(json.dumps(sample, ensure_ascii=False) + "\n" for sample in samples),
        encoding="utf-8",
    )

    result = subprocess.run(
        [
            sys.executable,
            "-m",
            "rimeai_eval",
            "evaluate",
            str(dataset),
            "--ranker",
            "baseline",
        ],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    tag_slices = json.loads(result.stdout)["slices"]["tag"]
    assert tag_slices["mixed-script"]["samples"] == 2
    assert tag_slices["mixed-script"]["top1_accuracy"] == 1.0
    assert tag_slices["technical-term"]["samples"] == 1


def test_validate_requires_tags_to_be_unique_non_empty_strings(tmp_path):
    dataset = tmp_path / "invalid-tags.jsonl"
    dataset.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "id": "developer-001",
                "split": "test",
                "domain": "developer",
                "context": "",
                "pinyin": "suoyin",
                "candidates": ["索引"],
                "gold_text": "索引",
                "tags": ["technical-term", "technical-term"],
            },
            ensure_ascii=False,
        )
        + "\n",
        encoding="utf-8",
    )

    result = subprocess.run(
        [sys.executable, "-m", "rimeai_eval", "validate", str(dataset)],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 2
    assert result.stdout == ""
    assert (
        result.stderr
        == f"error: {dataset}:1: tags must contain unique non-empty strings\n"
    )


def test_evaluate_defaults_to_the_frozen_test_split(tmp_path):
    dataset = tmp_path / "splits.jsonl"
    samples = [
        {
            "schema_version": 1,
            "id": "train-001",
            "split": "train",
            "domain": "general",
            "context": "",
            "pinyin": "suoyin",
            "candidates": ["所以", "索引"],
            "gold_text": "索引",
        },
        {
            "schema_version": 1,
            "id": "test-001",
            "split": "test",
            "domain": "general",
            "context": "",
            "pinyin": "mingling",
            "candidates": ["命令", "明令"],
            "gold_text": "命令",
        },
    ]
    dataset.write_text(
        "".join(json.dumps(sample, ensure_ascii=False) + "\n" for sample in samples),
        encoding="utf-8",
    )

    result = subprocess.run(
        [
            sys.executable,
            "-m",
            "rimeai_eval",
            "evaluate",
            str(dataset),
            "--ranker",
            "baseline",
        ],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    report = json.loads(result.stdout)
    assert report["dataset"]["split"] == "test"
    assert report["dataset"]["samples"] == 1
    assert report["metrics"]["top1_accuracy"] == 1.0


def test_evaluate_fingerprints_the_exact_dataset_bytes(tmp_path):
    dataset = tmp_path / "fingerprint.jsonl"
    dataset.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "id": "general-001",
                "split": "test",
                "domain": "general",
                "context": "",
                "pinyin": "suoyin",
                "candidates": ["索引"],
                "gold_text": "索引",
            },
            ensure_ascii=False,
        )
        + "\n",
        encoding="utf-8",
    )

    result = subprocess.run(
        [
            sys.executable,
            "-m",
            "rimeai_eval",
            "evaluate",
            str(dataset),
            "--ranker",
            "baseline",
        ],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    report = json.loads(result.stdout)
    assert report["dataset"]["sha256"] == hashlib.sha256(
        dataset.read_bytes()
    ).hexdigest()


def test_evaluate_can_abstain_on_low_confidence_and_keep_rime_order(tmp_path):
    dataset = tmp_path / "abstain.jsonl"
    dataset.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "id": "general-001",
                "split": "test",
                "domain": "general",
                "context": "",
                "pinyin": "suoyin",
                "candidates": ["索引", "所以"],
                "gold_text": "索引",
            },
            ensure_ascii=False,
        )
        + "\n",
        encoding="utf-8",
    )
    worker = tmp_path / "low_confidence_ranker.py"
    worker.write_text(
        "\n".join(
            [
                "import json",
                "import sys",
                "for line in sys.stdin:",
                "    request = json.loads(line)",
                "    candidate_ids = [item['id'] for item in request['candidates']]",
                "    print(json.dumps({",
                "        'schema_version': 1,",
                "        'request_id': request['request_id'],",
                "        'ranking': list(reversed(candidate_ids)),",
                "        'confidence': 0.1,",
                "        'model_artifact_id': 'low-confidence-v1',",
                "    }), flush=True)",
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    config = tmp_path / "ranker.json"
    config.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "name": "low-confidence",
                "command": [sys.executable, str(worker)],
                "timeout_ms": 400,
            }
        ),
        encoding="utf-8",
    )

    result = subprocess.run(
        [
            sys.executable,
            "-m",
            "rimeai_eval",
            "evaluate",
            str(dataset),
            "--ranker",
            "command",
            "--ranker-config",
            str(config),
            "--min-confidence",
            "0.5",
        ],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    report = json.loads(result.stdout)
    assert report["ranker"]["errors"] == 0
    assert report["ranker"]["abstained_samples"] == 1
    assert report["ranker"]["min_confidence"] == 0.5
    assert report["raw_metrics"]["top1_accuracy"] == 0.0
    assert report["metrics"]["top1_accuracy"] == 1.0


def test_evaluate_rejects_an_invalid_confidence_threshold(tmp_path):
    dataset = tmp_path / "threshold.jsonl"
    dataset.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "id": "general-001",
                "split": "test",
                "domain": "general",
                "context": "",
                "pinyin": "suoyin",
                "candidates": ["索引"],
                "gold_text": "索引",
            },
            ensure_ascii=False,
        )
        + "\n",
        encoding="utf-8",
    )

    result = subprocess.run(
        [
            sys.executable,
            "-m",
            "rimeai_eval",
            "evaluate",
            str(dataset),
            "--min-confidence",
            "1.5",
        ],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 2
    assert result.stdout == ""
    assert result.stderr == "error: --min-confidence must be from 0 to 1\n"


def test_validate_reports_a_missing_dataset_without_a_traceback(tmp_path):
    dataset = tmp_path / "missing.jsonl"

    result = subprocess.run(
        [sys.executable, "-m", "rimeai_eval", "validate", str(dataset)],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 2
    assert result.stdout == ""
    assert result.stderr == f"error: {dataset}: cannot read dataset\n"


def test_compare_renders_compatible_reports_as_markdown(tmp_path):
    baseline = tmp_path / "baseline.json"
    model = tmp_path / "model.json"
    shared_dataset = {
        "sha256": "abc123",
        "split": "test",
        "samples": 100,
        "covered_samples": 80,
        "top_k_coverage": 0.8,
    }
    baseline.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "dataset": shared_dataset,
                "ranker": {"name": "baseline", "errors": 0},
                "metrics": {
                    "top1_accuracy": 0.5,
                    "conditional_top1_accuracy": 0.625,
                    "mrr": 0.6,
                    "conditional_mrr": 0.75,
                    "cer": 0.2,
                    "conditional_cer": 0.1,
                },
                "latency_ms": {"samples": 100, "p50": 0.01, "p95": 0.02},
            }
        ),
        encoding="utf-8",
    )
    model.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "dataset": shared_dataset,
                "ranker": {
                    "name": "local-model",
                    "errors": 2,
                    "model_artifact_id": "model-v1",
                },
                "metrics": {
                    "top1_accuracy": 0.6,
                    "conditional_top1_accuracy": 0.75,
                    "mrr": 0.68,
                    "conditional_mrr": 0.85,
                    "cer": 0.12,
                    "conditional_cer": 0.08,
                },
                "latency_ms": {"samples": 100, "p50": 120.5, "p95": 310.25},
            }
        ),
        encoding="utf-8",
    )

    result = subprocess.run(
        [
            sys.executable,
            "-m",
            "rimeai_eval",
            "compare",
            str(baseline),
            str(model),
            "--format",
            "markdown",
        ],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    assert "Dataset `abc123` · split `test` · 100 samples" in result.stdout
    assert "| CER | Conditional CER |" in result.stdout
    assert "| baseline | 50.00% | 62.50% | 0.6000 | 0.7500 | 0.2000 | 0.1000 | 0.010 | 0.020 | 0 |" in result.stdout
    assert "| local-model | 60.00% | 75.00% | 0.6800 | 0.8500 | 0.1200 | 0.0800 | 120.500 | 310.250 | 2 |" in result.stdout
    assert result.stderr == ""


def test_command_ranker_opens_its_circuit_after_a_timeout(tmp_path):
    dataset = tmp_path / "two-samples.jsonl"
    samples = [
        {
            "schema_version": 1,
            "id": f"general-{index:03d}",
            "split": "test",
            "domain": "general",
            "context": "",
            "pinyin": "suoyin",
            "candidates": ["索引", "所以"],
            "gold_text": "索引",
        }
        for index in (1, 2)
    ]
    dataset.write_text(
        "".join(json.dumps(sample, ensure_ascii=False) + "\n" for sample in samples),
        encoding="utf-8",
    )
    request_log = tmp_path / "requests.log"
    worker = tmp_path / "slow_counting_ranker.py"
    worker.write_text(
        "\n".join(
            [
                "import json",
                "from pathlib import Path",
                "import sys",
                "import time",
                "request_log = Path(sys.argv[1])",
                "for line in sys.stdin:",
                "    with request_log.open('a', encoding='utf-8') as log:",
                "        log.write('request\\n')",
                "    request = json.loads(line)",
                "    time.sleep(0.1)",
                "    candidate_ids = [item['id'] for item in request['candidates']]",
                "    print(json.dumps({",
                "        'schema_version': 1,",
                "        'request_id': request['request_id'],",
                "        'ranking': candidate_ids,",
                "        'confidence': 1.0,",
                "        'model_artifact_id': 'slow-v1',",
                "    }), flush=True)",
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    config = tmp_path / "ranker.json"
    config.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "name": "slow-counting",
                "command": [sys.executable, str(worker), str(request_log)],
                "timeout_ms": 20,
            }
        ),
        encoding="utf-8",
    )

    result = subprocess.run(
        [
            sys.executable,
            "-m",
            "rimeai_eval",
            "evaluate",
            str(dataset),
            "--ranker",
            "command",
            "--ranker-config",
            str(config),
        ],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
        check=False,
        timeout=2,
    )

    assert result.returncode == 0, result.stderr
    report = json.loads(result.stdout)
    assert report["ranker"]["errors"] == 2
    assert report["ranker"]["attempted_samples"] == 1
    assert report["ranker"]["successful_samples"] == 0
    assert report["latency_ms"]["samples"] == 1
    assert request_log.read_text(encoding="utf-8").splitlines() == ["request"]


def test_validate_requires_each_json_line_to_be_an_object(tmp_path):
    dataset = tmp_path / "array.jsonl"
    dataset.write_text("[]\n", encoding="utf-8")

    result = subprocess.run(
        [sys.executable, "-m", "rimeai_eval", "validate", str(dataset)],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 2
    assert result.stdout == ""
    assert result.stderr == f"error: {dataset}:1: sample must be a JSON object\n"


def test_evaluate_reports_character_error_rate(tmp_path):
    dataset = tmp_path / "cer.jsonl"
    samples = [
        {
            "schema_version": 1,
            "id": "general-001",
            "split": "test",
            "domain": "general",
            "context": "",
            "pinyin": "suoyin",
            "candidates": ["索引"],
            "gold_text": "索引",
        },
        {
            "schema_version": 1,
            "id": "general-002",
            "split": "test",
            "domain": "general",
            "context": "",
            "pinyin": "suoyin",
            "candidates": ["所以"],
            "gold_text": "索引",
        },
    ]
    dataset.write_text(
        "".join(json.dumps(sample, ensure_ascii=False) + "\n" for sample in samples),
        encoding="utf-8",
    )

    result = subprocess.run(
        [
            sys.executable,
            "-m",
            "rimeai_eval",
            "evaluate",
            str(dataset),
            "--ranker",
            "baseline",
        ],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    metrics = json.loads(result.stdout)["metrics"]
    assert metrics["cer"] == 0.5
    assert metrics["conditional_cer"] == 0.0


def _write_train_ngram_dataset(tmp_path: Path) -> Path:
    samples = [
        {
            "schema_version": 1,
            "id": "train-1",
            "split": "train",
            "domain": "general",
            "context": "请执行下面这条",
            "pinyin": "fixture",
            "candidates": ["明令", "命令"],
            "gold_text": "命令",
            "tags": [],
        },
        {
            "schema_version": 1,
            "id": "train-2",
            "split": "train",
            "domain": "general",
            "context": "终端运行这条",
            "pinyin": "fixture",
            "candidates": ["明令", "命令"],
            "gold_text": "命令",
            "tags": [],
        },
        {
            "schema_version": 1,
            "id": "validation-1",
            "split": "validation",
            "domain": "general",
            "context": "现在执行这条",
            "pinyin": "fixture",
            "candidates": ["明令", "命令"],
            "gold_text": "命令",
            "tags": [],
        },
    ]
    dataset = tmp_path / "train-ngram.jsonl"
    dataset.write_text(
        "".join(
            json.dumps(sample, ensure_ascii=False) + "\n" for sample in samples
        ),
        encoding="utf-8",
    )
    return dataset


def test_train_ngram_terminal_method_accepts_comma_combination(tmp_path):
    # help 承诺 'legacy,unigram' 逗号形式扫描两种终端平滑方法：CLI
    # 不得在 argparse 层拒绝，必须走进 handler 的逗号解析分支并
    # 把两种方法都送进扫描网格。
    dataset = _write_train_ngram_dataset(tmp_path)
    artifact = tmp_path / "model.json.gz"

    result = subprocess.run(
        [
            sys.executable,
            "-m",
            "rimeai_eval",
            "train-ngram",
            str(dataset),
            "--output",
            str(artifact),
            "--terminal-method",
            "legacy,unigram",
        ],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    report = json.loads(result.stdout)
    assert report["smoothing_scan"]["terminal_method_grid"] == [
        "legacy",
        "unigram",
    ]
    assert report["selected_hyperparameters"]["terminal_method"] in (
        "legacy",
        "unigram",
    )
    assert artifact.is_file()


def test_train_ngram_terminal_method_rejects_unknown_entry(tmp_path):
    # 非法值由 handler 既有分支校验：exit 2 + 'error:' 消息风格，
    # 而不是 argparse 的 'invalid choice' SystemExit 文本。
    dataset = _write_train_ngram_dataset(tmp_path)

    result = subprocess.run(
        [
            sys.executable,
            "-m",
            "rimeai_eval",
            "train-ngram",
            str(dataset),
            "--output",
            str(tmp_path / "model.json.gz"),
            "--terminal-method",
            "kneser-ney",
        ],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 2
    assert result.stdout == ""
    assert (
        result.stderr
        == "error: --terminal-method entries must be 'legacy' and/or "
        "'unigram'\n"
    )


# --- reveal B-F4: train-neural-fusion caliber opt-out + in-place guard ---

_FUSION_DATASET_SHA = "d" * 64
_FUSION_NGRAM_SHA = "b" * 64

_FUSION_CLI_SAMPLES = [
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


class _FakeDataset:
    def __init__(self, samples):
        self.samples = samples
        self.sha256 = _FUSION_DATASET_SHA


class _FakeNeural:
    model_artifact_id = "neural:test"

    def __init__(self, table):
        self._table = table

    def _scores(self, **kwargs):
        return list(self._table[kwargs["context"]])


class _FakeNGram:
    dataset_sha256 = _FUSION_NGRAM_SHA

    def __init__(self, table):
        self._table = table

    def _candidate_score(self, context, candidate, baseline_index):
        return self._table[context][baseline_index]


def _fusion_tables():
    return (
        _FakeNeural({"命令": [1.0, 4.0], "任务": [1.0, 5.0], "历史": [3.0, 1.0]}),
        _FakeNGram({"命令": [2.0, 1.0], "任务": [2.0, 1.0], "历史": [2.0, 1.0]}),
    )


def _patch_fusion_loaders(monkeypatch):
    from rimeai_eval import cli

    neural, ngram = _fusion_tables()
    monkeypatch.setattr(
        cli, "load_dataset", lambda path: _FakeDataset(_FUSION_CLI_SAMPLES)
    )
    monkeypatch.setattr(
        cli, "load_neural_ranker", lambda path, guard, device="auto": neural
    )
    monkeypatch.setattr(cli, "load_ngram_model", lambda path: ngram)
    monkeypatch.setattr(
        cli.PinyinGuard, "from_rime_dictionary", classmethod(lambda cls, path: None)
    )
    return cli


def _train_fusion_argv(output, *extra):
    return [
        "train-neural-fusion",
        "dataset.jsonl",
        "--neural-model",
        "neural-model",
        "--language-model",
        "ngram-model.json.gz",
        "--rime-dictionary",
        "dict.yaml",
        "--output",
        str(output),
        *extra,
    ]


def test_train_fusion_defaults_to_global_norm_caliber(tmp_path, monkeypatch, capsys):
    cli = _patch_fusion_loaders(monkeypatch)
    output = tmp_path / "fusion.json"

    code = cli.main(_train_fusion_argv(output))

    assert code == 0
    payload = json.loads(output.read_text(encoding="utf-8"))
    assert payload["fusion_type"] == "rimeai-neural-ngram-v2"
    assert payload["score_normalization"]["method"] == (
        "validation-global-affine"
    )
    from rimeai_runtime.neural_ranker import FusionConfig

    assert FusionConfig.load(output).fusion_type == "rimeai-neural-ngram-v2"
    assert capsys.readouterr().out.strip()  # 训练报告仍打印到 stdout


def test_train_fusion_legacy_zscore_writes_v1_config(tmp_path, monkeypatch):
    cli = _patch_fusion_loaders(monkeypatch)
    output = tmp_path / "fusion-v1.json"

    code = cli.main(_train_fusion_argv(output, "--fusion-type", "legacy-zscore"))

    assert code == 0
    payload = json.loads(output.read_text(encoding="utf-8"))
    assert payload["fusion_type"] == "rimeai-neural-ngram-v1"
    assert "score_normalization" not in payload
    from rimeai_runtime.neural_ranker import FusionConfig

    config = FusionConfig.load(output)
    assert config.fusion_type == "rimeai-neural-ngram-v1"
    assert config.neural_mean is None


def test_train_fusion_same_caliber_overwrite_succeeds(
    tmp_path, monkeypatch, capsys
):
    cli = _patch_fusion_loaders(monkeypatch)
    output = tmp_path / "fusion.json"

    assert cli.main(_train_fusion_argv(output, "--fusion-type", "legacy-zscore")) == 0
    first = output.read_text(encoding="utf-8")
    capsys.readouterr()

    assert cli.main(_train_fusion_argv(output, "--fusion-type", "legacy-zscore")) == 0

    assert output.read_text(encoding="utf-8") == first  # 确定性重写，同口径允许


def test_train_fusion_refuses_to_change_caliber_in_place(
    tmp_path, monkeypatch, capsys
):
    cli = _patch_fusion_loaders(monkeypatch)
    output = tmp_path / "fusion.json"
    assert cli.main(_train_fusion_argv(output, "--fusion-type", "legacy-zscore")) == 0
    incumbent = output.read_text(encoding="utf-8")
    capsys.readouterr()

    code = cli.main(_train_fusion_argv(output))  # 默认 global-norm

    assert code == 2
    stderr = capsys.readouterr().err
    assert "refusing to change fusion caliber of existing config in place; " in stderr
    assert "move it aside or choose a new filename" in stderr
    assert "rimeai-neural-ngram-v1" in stderr
    assert "rimeai-neural-ngram-v2" in stderr
    assert output.read_text(encoding="utf-8") == incumbent  # 原文件未被触碰


def test_train_fusion_refuses_caliber_change_in_either_direction(
    tmp_path, monkeypatch, capsys
):
    cli = _patch_fusion_loaders(monkeypatch)
    output = tmp_path / "fusion.json"
    assert cli.main(_train_fusion_argv(output)) == 0  # v2 incumbent
    capsys.readouterr()

    code = cli.main(_train_fusion_argv(output, "--fusion-type", "legacy-zscore"))

    assert code == 2
    assert "refusing to change fusion caliber" in capsys.readouterr().err


def test_train_fusion_refuses_to_overwrite_corrupt_output(
    tmp_path, monkeypatch, capsys
):
    cli = _patch_fusion_loaders(monkeypatch)
    output = tmp_path / "fusion.json"
    output.write_text("{not valid json", encoding="utf-8")

    code = cli.main(_train_fusion_argv(output))

    assert code == 2
    stderr = capsys.readouterr().err
    assert "refusing to change fusion caliber of existing config in place; " in stderr
    assert output.read_text(encoding="utf-8") == "{not valid json"
