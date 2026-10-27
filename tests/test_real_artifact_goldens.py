"""Real-artifact golden replay (reveal B-F2).

使命（README）
--------------
本文件对拍 ``tests/fixtures/goldens/ranker-v1.json`` 里用真实本机制品
（``.rimeai/models``，未入库）生成的 golden：

* golden 的使命是 **"未来改动不得无意识漂移"**，不是"证明等于改前"。
  有意语义变更后，用 ``tools/build_ranker_goldens.py`` 重新生成 golden
  并同步更新其 ``code_semantics`` 锚——回放失败即是"有意识的、被评审
  的决定"；无意漂移（回归）必须让回放失败。
* 本机缺真实制品 → 对应 capture 组（或整文件）skip，不算失败。
* 制品 sha256 与 golden 记录不一致 → 该组 skip：制品漂移不是代码
  回归，应重新生成 golden。
* 数值策略按组执行，来自生成时的实证结论：
  - n-gram rank / beam / user-LM 视图：纯 Python 定函数 → 逐位相等；
  - torch 24M（CPU）：同进程两次调用即非逐位确定（oneDNN/MKL 内核
    变异性，margin 单位 ~2e-3）→ ``pytest.approx(abs=0.01)``；
  - ONNX int8：本机逐位确定，跨版本不保证 → ``abs=1e-6``；
  - 边界条目（生成时 |fused margin − τ| ≤ 0.05）：B-F1 门两侧的
    decision/confidence 均为合法值，接受任一记录的分支值——门映射
    本身仍由非边界条目钉死。
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any

import pytest

from rimeai_runtime.candidate_policy import partition_full_length_candidates

PROJECT_ROOT = Path(__file__).resolve().parents[1]
# 仓库既有目录是 tests/Fixtures（大写 F）：与工具的规范路径保持一致。
GOLDEN_PATH = (
    Path(__file__).resolve().parent / "Fixtures/goldens/ranker-v1.json"
)

if GOLDEN_PATH.is_file():
    GOLDEN: dict[str, Any] = json.loads(GOLDEN_PATH.read_text(encoding="utf-8"))
else:
    # 空对象保证模块可导入（类型可下标）；pytestmark 在此场景下
    # 将整文件 skip，任何测试体都不会执行。
    GOLDEN = {}


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _group_available(group: dict) -> tuple[bool, str]:
    """A group replays only against the exact artifacts it was built from."""
    for artifact in group.get("artifacts", []):
        path = PROJECT_ROOT / artifact["path"]
        if not path.is_file():
            return False, f"artifact missing: {artifact['path']}"
        if _sha256(path) != artifact["sha256"]:
            return False, f"artifact drifted (sha256 mismatch): {artifact['path']}"
    return True, ""


def _any_group_available() -> bool:
    return any(
        _group_available(group)[0]
        for group in GOLDEN.get("captures", {}).values()
    )


pytestmark = [
    pytest.mark.skipif(
        not GOLDEN, reason="golden fixture not generated (ranker-v1.json)"
    ),
    pytest.mark.skipif(
        bool(GOLDEN) and not _any_group_available(),
        reason="no real artifacts present on this machine",
    ),
]

def _eligible_window_members(case: dict) -> set[str]:
    """Full-length eligible candidates inside the Top-K window (B-F6).

    Boundary entries may legally flip which eligible member surfaces,
    but a flip must NEVER pull a preserved or tail member to the top.
    """
    window = [
        {"id": str(index), "text": candidate}
        for index, candidate in enumerate(case["candidates"][:10])
    ]
    eligible, _ = partition_full_length_candidates(window)
    return {candidate["text"] for candidate in eligible}


_CASES = {case["id"]: case for case in GOLDEN.get("cases", [])}


# ---------------------------------------------------------------------------
# Replay targets, constructed lazily and cached for the whole session.
# ---------------------------------------------------------------------------
_CACHE: dict[str, Any] = {}


def _role_paths(group_name: str) -> dict[str, Path]:
    roles: dict[str, Path] = {}
    for artifact in GOLDEN["captures"][group_name]["artifacts"]:
        role = artifact["role"]
        path = PROJECT_ROOT / artifact["path"]
        if role == "neural_ranker_manifest":
            roles["neural_model_path"] = path.parent
        else:
            roles[role] = path
    return roles


def _load_ngram() -> Any:
    from rimeai_runtime.ngram_ranker import load_ngram_model

    paths = _role_paths("ngram_rank")
    return load_ngram_model(paths["language_model"])


def _load_decoder() -> Any:
    from rimeai_runtime.beam_decoder import BeamSentenceDecoder, load_beam_config
    from rimeai_runtime.pinyin_guard import PinyinGuard

    paths = _role_paths("beam")
    ngram = _CACHE.setdefault("ngram", _load_ngram())
    config = load_beam_config(paths["sentence_config"])
    guard = PinyinGuard.from_rime_dictionary(paths["rime_dictionary"])
    return BeamSentenceDecoder(ngram, guard, config)


def _load_hybrid(group_name: str) -> Any:
    from rimeai_runtime.neural_ranker import (
        HybridSemanticRanker,
        load_neural_ranker,
    )
    from rimeai_runtime.pinyin_guard import PinyinGuard

    if group_name.endswith("onnx"):
        device = "cpu"
    else:
        import torch

        torch.set_num_threads(1)
        device = "cpu"
    paths = _role_paths(group_name)
    guard = PinyinGuard.from_rime_dictionary(
        _role_paths("beam")["rime_dictionary"]
    )
    ngram = _CACHE.setdefault("ngram", _load_ngram())
    neural = load_neural_ranker(paths["neural_model_path"], guard, device=device)
    return HybridSemanticRanker(neural, ngram, paths["fusion_config"])


def _load_engine(group_name: str) -> Any:
    from rimeai_daemon.engine import LocalInferenceEngine

    paths = _role_paths(group_name)
    kwargs: dict[str, Any] = {
        "language_model_path": paths["language_model"],
        "beam_config_path": paths["sentence_config"],
        "rime_dictionary_path": paths["rime_dictionary"],
    }
    kwargs["neural_device"] = "cpu"
    if "neural_model_path" in paths:
        kwargs["neural_model_path"] = paths["neural_model_path"]
        kwargs["fusion_config_path"] = paths["fusion_config"]
    if "user_lm" in paths:
        kwargs["user_lm_path"] = paths["user_lm"]
    return LocalInferenceEngine(**kwargs)


def _load_user_lm_view() -> Any:
    from rimeai_runtime.user_lm_view import UserLanguageModelView

    return UserLanguageModelView.load(_role_paths("user_lm_view")["user_lm"])


def _replay_target(group_name: str):
    if group_name in _CACHE:
        return _CACHE[group_name]
    if group_name == "ngram_rank":
        target = _load_ngram()
    elif group_name == "beam":
        target = _load_decoder()
    elif group_name == "user_lm_view":
        target = _load_user_lm_view()
    elif group_name.startswith("hybrid_"):
        target = _load_hybrid(group_name)
    else:
        target = _load_engine(group_name)
    _CACHE[group_name] = target
    return target


# ---------------------------------------------------------------------------
# Comparison helpers.
# ---------------------------------------------------------------------------
def _compare_float(observed: float, entry: dict, key: str, tolerance: float | None) -> None:
    if tolerance is None:  # exact, pure-Python deterministic function
        assert observed == entry[key], f"{key}: {observed!r} != {entry[key]!r}"
        return
    ranges = entry.get("confidence_legal_ranges")
    if ranges:
        # 边界条目：钉死分支公式而非点值——合法置信度落在任一分支
        # 区间内（below / calibrated / same-top=1.0）。
        slack = tolerance
        assert any(
            low - slack <= observed <= high + slack
            for low, high in (pair[:2] for pair in ranges)
        ), (
            f"{key}: {observed!r} falls in none of the legal branch ranges "
            f"{ranges}"
        )
        return
    assert observed == pytest.approx(entry[key], abs=tolerance), (
        f"{key}: {observed!r} != {entry[key]!r} (abs={tolerance})"
    )


def _tolerance(group: dict) -> float | None:
    numeric = group.get("numeric", {})
    if numeric.get("confidence") == "exact":
        return None
    return float(numeric.get("abs", 0.0))


def _params():
    if not GOLDEN:
        return []
    params = []
    for group_name, group in GOLDEN["captures"].items():
        available, reason = _group_available(group)
        marks = [] if available else [pytest.mark.skip(reason=reason)]
        for case_id in group["results"]:
            params.append(
                pytest.param(group_name, case_id, marks=marks, id=f"{group_name}-{case_id}")
            )
    return params


# ---------------------------------------------------------------------------
# Golden schema and mission anchors.
# ---------------------------------------------------------------------------
def test_golden_schema_and_semantic_anchors():
    # 语义锚描述"生成时"的代码语义（41c67de 的 B-F1 映射 + 本次的
    # B-F6 窗口）。有意变更语义时须重新生成 golden 并同步更新锚。
    assert GOLDEN["schema_version"] == 1
    assert GOLDEN["golden_id"] == "ranker-v1"
    assert GOLDEN["code_semantics"]["confidence_mapping"] == "bf1-calibrated-gate"
    assert GOLDEN["code_semantics"]["rerank_window"] == "bf6-ranker-owned-top_k"
    assert GOLDEN["code_semantics"]["user_evidence_window"] == "eligible-window-guard"
    assert GOLDEN["head_commit"] == "41c67de"
    # 固定输入集：约 30 条，含语料与手工边界形态，逐条可追溯。
    assert GOLDEN["case_count"] == len(_CASES) >= 30
    sources = {case.get("source", "handcrafted") for case in _CASES.values()}
    assert any(source.startswith("p0-corpus:") for source in sources)
    assert {"h-single-candidate", "h-mixed-window", "h-empty-candidates"} <= set(
        _CASES
    )


def test_golden_covers_boundary_margin_entries():
    # 边界 margin 条目必须被显式记录（双分支合法值），否则跨运行
    # 的后端数值噪声会把对拍变成 flaky。
    hybrid = GOLDEN["captures"]["hybrid_torch"]["results"]
    boundary = {
        case_id for case_id, entry in hybrid.items() if entry.get("boundary")
    }
    assert boundary, "no boundary-margin entries recorded in hybrid_torch"
    for case_id in boundary:
        assert hybrid[case_id]["confidence_legal_ranges"]


# ---------------------------------------------------------------------------
# The replay itself.
# ---------------------------------------------------------------------------
@pytest.mark.parametrize(("group_name", "case_id"), _params())
def test_real_artifact_golden_replay(group_name: str, case_id: str):
    group = GOLDEN["captures"][group_name]
    case = _CASES[case_id]
    entry = group["results"][case_id]
    tolerance = _tolerance(group)
    target = _replay_target(group_name)

    if group_name == "ngram_rank":
        ranking, confidence = target.rank(
            context=case["context"], candidates=case["candidates"]
        )
        assert ranking == entry["ranking"]
        _compare_float(confidence, entry, "confidence", tolerance)

    elif group_name.startswith("hybrid_"):
        ranking, confidence = target.rank_candidates(
            context=case["context"],
            pinyin=case["pinyin"],
            candidates=case["candidates"],
        )
        recorded = entry["ranking"]
        if group_name == "hybrid_onnx":
            # 确定性后端：布局与顺序逐位对拍（B-F6：窗口由制品暴露）。
            assert ranking == recorded
        else:
            # torch CPU 后端非逐位确定：top-1（决策面）逐位钉死，
            # 其余名次允许近并列互换，但窗口/尾巴成员集合不得漂移。
            if ranking:
                assert ranking[0] == recorded[0]
            assert sorted(ranking) == sorted(recorded)
        _compare_float(confidence, entry, "confidence", tolerance)

    elif group_name == "beam":
        if "segments" in case:
            from rimeai_runtime.beam_decoder import SegmentDecodeInput

            suggestion = target.suggest_segments(
                context=case["context"],
                segments=[
                    SegmentDecodeInput(
                        pinyin=segment["pinyin"],
                        separator=segment["separator"],
                        committed_text=segment.get("committed_text") or "",
                    )
                    for segment in case["segments"]
                ],
                active_candidates=case["candidates"],
            )
        else:
            suggestion = target.suggest(
                context=case["context"],
                pinyin=case["pinyin"],
                candidates=case["candidates"],
            )
        assert suggestion.text == entry["text"]
        assert suggestion.reason == entry["reason"]
        _compare_float(suggestion.confidence, entry, "confidence", tolerance)

    elif group_name == "user_lm_view":
        observed = [
            target.log_prob_sum(case["context"], candidate)
            for candidate in case["candidates"][:5]
        ]
        assert observed == entry["log_prob_sums"]

    else:  # engine_* groups: full infer surface.
        request = {
            "context": case["context"],
            "pinyin": case["pinyin"],
            "candidates": list(case["candidates"]),
            "allow_sentence": case["allow_sentence"],
        }
        if "segments" in case:
            request["segments"] = case["segments"]
        result = target.infer(request)
        alternatives = entry.get("decision_alternatives")
        if alternatives:
            assert result["decision"] in alternatives
            if result["decision"] == "ranked_candidate":
                # 边界噪声可合法换人，但翻上来的必须是窗口内全长
                # eligible（B-F6 守卫），preserved/尾巴永远不行。
                assert result["ranked_candidate"] in _eligible_window_members(case)
            else:
                assert result["ranked_candidate"] == entry["ranked_candidate"]
        else:
            assert result["decision"] == entry["decision"]
            assert result["ranked_candidate"] == entry["ranked_candidate"]
        assert result["sentence_suggestion"] == entry["sentence_suggestion"]
        _compare_float(result["confidence"], entry, "confidence", tolerance)
