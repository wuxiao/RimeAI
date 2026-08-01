import json
import os
from pathlib import Path
import tempfile
from typing import Any, Dict, List, Sequence


class ReportError(ValueError):
    pass


def write_jsonl_atomic(path: Path, records: Sequence[Dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    file_descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", dir=path.parent
    )
    try:
        with os.fdopen(file_descriptor, "w", encoding="utf-8") as output:
            for record in records:
                output.write(
                    json.dumps(
                        record,
                        ensure_ascii=False,
                        separators=(",", ":"),
                    )
                    + "\n"
                )
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary_name, path)
    except BaseException:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass
        raise


def load_reports(paths: Sequence[Path]) -> List[Dict[str, Any]]:
    reports: List[Dict[str, Any]] = []
    for path in paths:
        try:
            report = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise ReportError(f"cannot read report '{path}': {error}") from error
        if not isinstance(report, dict) or report.get("schema_version") != 1:
            raise ReportError(f"report '{path}' schema_version must be 1")
        reports.append(report)
    return reports


def render_markdown_comparison(reports: Sequence[Dict[str, Any]]) -> str:
    reference_dataset = reports[0]["dataset"]
    reference_identity = (
        reference_dataset["sha256"],
        reference_dataset["split"],
        reference_dataset["samples"],
    )
    for report in reports[1:]:
        dataset = report["dataset"]
        identity = (dataset["sha256"], dataset["split"], dataset["samples"])
        if identity != reference_identity:
            raise ReportError(
                "reports must use the same dataset hash, split, and sample count"
            )

    lines = [
        (
            f"Dataset `{reference_dataset['sha256']}` · "
            f"split `{reference_dataset['split']}` · "
            f"{reference_dataset['samples']} samples"
        ),
        "",
        (
            "| Ranker | Top-1 | Conditional Top-1 | MRR | Conditional MRR "
            "| CER | Conditional CER | P50 ms | P95 ms | Errors |"
        ),
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for report in reports:
        ranker = report["ranker"]
        metrics = report["metrics"]
        latency = report["latency_ms"]
        lines.append(
            "| {name} | {top1:.2%} | {conditional_top1:.2%} | "
            "{mrr:.4f} | {conditional_mrr:.4f} | {cer:.4f} | "
            "{conditional_cer:.4f} | {p50:.3f} | {p95:.3f} | {errors} |".format(
                name=ranker["name"],
                top1=metrics["top1_accuracy"],
                conditional_top1=metrics["conditional_top1_accuracy"],
                mrr=metrics["mrr"],
                conditional_mrr=metrics["conditional_mrr"],
                cer=metrics["cer"],
                conditional_cer=metrics["conditional_cer"],
                p50=latency["p50"],
                p95=latency["p95"],
                errors=ranker["errors"],
            )
        )
    return "\n".join(lines) + "\n"
