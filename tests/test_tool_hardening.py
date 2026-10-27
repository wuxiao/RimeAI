"""C-F8 工具加固：报告原子写、--output 输入保护、旧口径产物明确报错。

reveal C-F8：confidence_renorm_report / report_fusion_global_norm 直接
write_text（中断即留下半份报告，被 sha 锁定的制品可能被覆盖）；
beam_hparam_scan_v4 的 --output 保护集合漏掉 dataset/language-model/
rime-dictionary/training-report；缺 raw_confidence 键的旧口径 details
在 discrimination() 里裸 KeyError。
"""

import json
import sys
from pathlib import Path

import pytest

from tools import (
    beam_hparam_scan_v4,
    confidence_renorm_report,
    report_fusion_global_norm,
)
from tools.confidence_renorm_report import load_details

renorm_atomic_write = confidence_renorm_report._write_atomic_json
fusion_atomic_write = report_fusion_global_norm._write_atomic_json
scan_main = beam_hparam_scan_v4.main

_DUAL_CALIBER_ROW = {
    "id": "s1",
    "domain": "general",
    "pinyin": "nihao",
    "gold_text": "你好",
    "raw_suggestion": "你好",
    "applied_text": "你好",
    "status": "applied",
    "confidence": 0.9,
    "raw_confidence": 0.02,
}


def _write_details(path: Path, rows: list[dict]) -> Path:
    path.write_text(
        "".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8"
    )
    return path


def test_load_details_rejects_raw_caliber_products(tmp_path: Path):
    # 旧口径产物（口径切换前的 details，confidence 列本身就是 RAW
    # 值）没有 raw_confidence 键——必须明确报错退出并说明原因，不再
    # 在 discrimination() 里裸 KeyError（且 precision_coverage 会把缺键
    # 静默当 0.0 污染聚合）。
    row = {key: value for key, value in _DUAL_CALIBER_ROW.items()
           if key != "raw_confidence"}
    path = _write_details(tmp_path / "old.jsonl", [row])
    with pytest.raises(SystemExit, match="raw_confidence"):
        load_details(path)


def test_load_details_accepts_dual_caliber_rows(tmp_path: Path):
    path = _write_details(tmp_path / "new.jsonl", [_DUAL_CALIBER_ROW])
    rows = load_details(path)
    assert rows[0]["raw_confidence"] == 0.02


def test_renorm_report_write_is_atomic(tmp_path: Path):
    out = tmp_path / "nested" / "report.json"
    renorm_atomic_write(out, {"schema_version": 1})
    assert json.loads(out.read_text(encoding="utf-8")) == {"schema_version": 1}
    # 原子写不留临时文件残骸。
    assert not list(out.parent.glob(".*.tmp"))


def test_fusion_report_write_is_atomic(tmp_path: Path):
    out = tmp_path / "nested" / "report.json"
    fusion_atomic_write(out, {"schema_version": 1})
    assert json.loads(out.read_text(encoding="utf-8")) == {"schema_version": 1}
    assert not list(out.parent.glob(".*.tmp"))


def _scan_argv(tmp_path: Path, output: str) -> list[str]:
    return [
        "scan",
        "--dataset", str(tmp_path / "dataset.jsonl"),
        "--language-model", str(tmp_path / "lm.json.gz"),
        "--rime-dictionary", str(tmp_path / "dict.yaml"),
        "--v3-config", str(tmp_path / "v3.json"),
        "--v4-config", str(tmp_path / "v4.json"),
        "--training-report", str(tmp_path / "training.json"),
        "--output", output,
    ]


@pytest.mark.parametrize(
    "flag,path_part",
    [
        ("--dataset", "dataset.jsonl"),
        ("--language-model", "lm.json.gz"),
        ("--rime-dictionary", "dict.yaml"),
        ("--training-report", "training.json"),
        ("--v3-config", "v3.json"),
        ("--v4-config", "v4.json"),
    ],
)
def test_scan_output_protection_covers_all_inputs(
    tmp_path: Path, monkeypatch, flag: str, path_part: str
):
    # reveal C-F8：--output 与任一输入同路径必须在重负载之前被拒绝
    # （rc=2 + 指名输入）；旧保护集合只含 v3/v4 config，覆盖被 sha
    # 锁定的 dataset/lm/dict/training-report 会在数分钟计算后原地把
    # 输入制品覆盖掉。
    collided = tmp_path / path_part
    collided.write_text("sentinel", encoding="utf-8")
    argv = _scan_argv(tmp_path, str(collided))
    monkeypatch.setattr(sys, "argv", argv)
    assert scan_main() == 2
    assert collided.read_text(encoding="utf-8") == "sentinel"
    captured = capsys_error(argv, flag)
    assert f"must not overwrite {flag}" in captured


def capsys_error(argv: list[str], flag: str) -> str:
    # scan_main 的错误打到 stderr；这里复跑一次以捕获（rc 已在上面
    # 断言，此处只取消息）。
    import contextlib
    import io

    stderr = io.StringIO()
    with contextlib.redirect_stderr(stderr):
        scan_main()
    return stderr.getvalue()
