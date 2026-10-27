#!/usr/bin/env python3
"""Regenerate the real-artifact ranker goldens (reveal B-F2).

Mission (README)
----------------
This tool replays a FIXED, hardcoded set of inputs against the REAL
local artifacts (``.rimeai/models`` — not committed to the repo) and
writes every output into ``tests/fixtures/goldens/ranker-v1.json``.

The golden's mission is **"future changes must not drift UNCONSCIOUSLY"**,
NOT "prove the current code equals the pre-change code":

* If a replay fails after an INTENTIONAL semantic change (e.g. a new
  confidence mapping), regenerate the golden with this tool in the same
  commit and update the ``code_semantics`` anchors below — the failure
  is then a conscious, reviewed decision.
* If a replay fails without such a change, the regression is real.

Missing optional artifacts simply omit their capture groups; the test
skips those groups. A changed artifact SHA-256 also skips the group
(artifact drift is not a code regression — regenerate instead).

Numeric policy (empirically established on this repo's artifacts):
* n-gram rank, beam decoder, user-LM view: pure-Python math over fixed
  artifacts → recorded and compared bit-for-bit.
* torch 24M (CPU): NOT bit-deterministic run-to-run on the same host
  (oneDNN/MKL kernel variability, ~2e-3 in fused-margin units even
  single-threaded) → confidences compared with pytest.approx
  (abs=0.01); entries whose fused margin sits within 0.02 of the
  calibrated threshold carry both legal branch confidences and either
  is accepted (the gate mapping itself is still pinned by the
  non-boundary entries).
* ONNX int8: bit-deterministic here, but cross-version onnxruntime is
  not guaranteed → abs=1e-6.

Usage:
    .venv/bin/python tools/build_ranker_goldens.py
    .venv/bin/python tools/build_ranker_goldens.py --output <path>
"""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

PROJECT_ROOT = Path(__file__).resolve().parents[1]
MODELS_DIR = PROJECT_ROOT / ".rimeai" / "models"
DICTIONARY = PROJECT_ROOT / ".rimeai/rime/shared/luna_pinyin.dict.yaml"

NGRAM_ARTIFACT = MODELS_DIR / "p0-char-ngram-v2.json.gz"
BEAM_CONFIG = MODELS_DIR / "p0-beam-sentence-v3.json"
TORCH_RANKER = MODELS_DIR / "rimeai-ranker-s-24m-v1"
TORCH_FUSION = MODELS_DIR / "rimeai-ranker-s-24m-fusion-v2.json"
ONNX_RANKER = MODELS_DIR / "rimeai-ranker-s-24m-int8-onnx-v1"
ONNX_FUSION = MODELS_DIR / "rimeai-ranker-s-24m-int8-onnx-fusion-v1.json"
USER_LM = MODELS_DIR / "eval-user-lm-p0-train/user-lm.json.gz"

SCHEMA_VERSION = 1
GOLDEN_ID = "ranker-v1"
# 仓库既有目录是 tests/Fixtures（大写 F）：统一用规范大小写，
# 避免 macOS（大小写不敏感）写入后在 Linux 检出（大小写敏感）失配。
DEFAULT_OUTPUT = PROJECT_ROOT / "tests/Fixtures/goldens/ranker-v1.json"

# Era anchors: describe the code semantics AT GENERATION TIME. When a
# golden replay fails after an intentional change, update these together
# with the regenerated outputs so future readers can tell which semantic
# era a golden belongs to (41c67de = B-F1 calibrated gate; this commit
# adds B-F6 ranker-owned windows).
CODE_SEMANTICS = {
    "confidence_mapping": "bf1-calibrated-gate",
    "rerank_window": "bf6-ranker-owned-top_k",
    "user_evidence_window": "eligible-window-guard",
    "ranker_min_confidence": 0.55,
    "sentence_min_confidence": 0.60,
}

# Boundary band: |fused margin - threshold| <= band means the observed
# confidence can legally sit on either side of the B-F1 gate under
# backend numeric noise (~5e-3 in margin units). The band is 10x the
# observed noise so band-edge cases stay classified as boundary even
# when their recorded margin itself wobbles between runs.
BOUNDARY_BAND = 0.05


def _case(
    case_id: str,
    *,
    context: str,
    pinyin: str,
    candidates: list[str],
    allow_sentence: bool = False,
    segments: list[dict[str, Any]] | None = None,
    source: str = "handcrafted",
) -> dict[str, Any]:
    return {
        "id": case_id,
        "source": source,
        "context": context[:100],
        "pinyin": pinyin,
        "candidates": candidates,
        "allow_sentence": allow_sentence,
        **({"segments": segments} if segments else {}),
    }


# ---------------------------------------------------------------------------
# Fixed replay inputs. Dataset-derived members quote the frozen P0 corpus
# (.rimeai/datasets/p0-librime-1.17.0-luna-simp.jsonl) verbatim; the
# handcrafted members pin edge shapes the corpus lacks (single candidate,
# non-full-length mixes, beyond-window tails, empty context/candidates,
# beam sentence paths, segments).
# ---------------------------------------------------------------------------
CASES: list[dict[str, Any]] = [
    # --- corpus-derived, short/medium contexts -----------------------------
    _case(
        "d-foxiang",
        context="* 云冈石窟 - 这些依山的洞穴和石窟总数超过50个，石窟中有超过51000个",
        pinyin="foxiang",
        candidates=["佛像", "佛系", "佛", "仏", "坲", "𧥚", "𧼴", "梻"],
        source="p0-corpus:general-00ee80600ee0c8ab",
    ),
    _case(
        "d-fenxi",
        context="不必依靠别人来决定你需要哪些",
        pinyin="fenxi",
        candidates=["分析", "汾西", "分系", "分携", "分细", "蚡息", "分", "份", "粉", "芬"],
        source="p0-corpus:developer-035711b9dc0ac8e1",
    ),
    _case(
        "d-biaoshi",
        context="一个 8 位值，",
        pinyin="biaoshi",
        candidates=["表示", "标识", "标示", "镖师", "表饰", "猋逝", "表", "标", "彪", "飙"],
        source="p0-corpus:developer-02da82674b4ff27d",
    ),
    _case(
        "d-weiyi",
        context="定义唯一标识符（ID），该标识符在整个文档中必须是",
        pinyin="weiyi",
        candidates=["唯一", "位移", "惟一", "为宜", "卫衣", "为一", "尾翼", "威仪", "逶迤", "委以"],
        source="p0-corpus:developer-0286c615d32bdc04",
    ),
    _case(
        "d-liuliang",
        context="然而，它们非常适合在真实环境中，测试低",
        pinyin="liuliang",
        candidates=["流量", "陆良", "六两", "六辆", "浏亮", "流利", "琉璃", "流离", "刘力", "流丽"],
        allow_sentence=True,
        source="p0-corpus:developer-0266ad3e52ff2bda",
    ),
    _case(
        "d-zhengfangxing",
        context="是一个关键字，它强制将字符（主要是表意文字和拉丁文字））--写在一个",
        pinyin="zhengfangxing",
        candidates=["正方形", "正方", "正房", "正", "整", "证", "郑", "挣", "争", "症"],
        source="p0-corpus:developer-0290c966179f6aa0",
    ),
    _case(
        "d-suoyin",
        context="这个属性的值总是比数组中最高的",
        pinyin="suoyin",
        candidates=["索引", "缩印", "缩阴", "索隐", "所", "锁", "索", "缩", "塑", "嗦"],
        source="p0-corpus:developer-0240608c245fa8ce",
    ),
    _case(
        "d-shengcheng",
        context="在生成器函数中，",
        pinyin="shengcheng",
        candidates=["生成", "声称", "省城", "圣城", "升成", "省成", "省称", "盛称", "生", "省"],
        source="p0-corpus:developer-02164280b454ed9b",
    ),
    _case(
        "d-chuangkou",
        context="[!NOTE] 在引入这个伪类之前，为背景窗口提供不同的样式是通过在顶层 XUL chrome",
        pinyin="chuangkou",
        candidates=["窗口", "创口", "疮口", "床", "创", "撞", "窗", "闯", "疮", "怆"],
        allow_sentence=True,
        source="p0-corpus:developer-02634022fb67a45f",
    ),
    _case(
        "d-peizhiwenjian",
        context="运行测试时，最好还是： 尽可能设置单独的浏览器",
        pinyin="peizhiwenjian",
        candidates=["配置文件", "配置", "配制", "培植", "陪", "配", "赔", "培", "佩", "裴"],
        source="p0-corpus:developer-0175ca4e7f1ec090",
    ),
    _case(
        "d-danshi",
        context="一个 headers 对象是一个简单的多键值对： 也可以传入一个多维数组或者对象字面量： 它的内容可以被获取： 虽然一些操作只能在 中使用，",
        pinyin="danshi",
        candidates=["但是", "单是", "胆识", "胆石", "单式", "但使", "啖噬", "啖食", "耽视", "但"],
        source="p0-corpus:developer-0255e08193b88a9e",
    ),
    # --- corpus-derived, long pinyin / traditional contexts ----------------
    _case(
        "d-nianjiushixiu",
        context="因越南鐵道為窄軌，加上",
        pinyin="nianjiushixiu",
        candidates=["年久失修", "念旧", "年久", "廿九", "拈阄", "拈酒", "年", "念", "粘", "捻"],
        source="p0-corpus:general-013a6c0dc1655c37",
    ),
    _case(
        "d-gonggongjiaotong",
        context="渡轮是威尼斯、里斯本、悉尼、旧金山湾区和斯德哥尔摩群岛等滨水地区",
        pinyin="gonggongjiaotong",
        candidates=["公共交通", "公共", "公公", "共工", "觥觥", "恭恭", "咣咣", "公宫", "弓弓", "共"],
        source="p0-corpus:general-000f84bb6415fdc1",
    ),
    _case(
        "d-yiji",
        context="对于 API 演示，如果你同时使用了多个 API，请指出包含了哪些 API，",
        pinyin="yiji",
        candidates=["以及", "一级", "一集", "遗迹", "一记", "一击", "一季", "亦即", "一己", "一剂"],
        allow_sentence=True,
        source="p0-corpus:developer-000508cc325d1d9a",
    ),
    _case(
        "d-hezi",
        context="结果 创建一个展开的盒子 为了使得 盒子初始为展开状态，要添加布尔属性 ： 结果 自定义外观 现在我们给展现",
        pinyin="hezi",
        candidates=["盒子", "合资", "赫兹", "核子", "合子", "核资", "蚵仔", "貉子", "诃子", "核字"],
        source="p0-corpus:developer-0005ce28b1092159",
    ),
    _case(
        "d-tongchang",
        context="出通常品質有些不好的食物的例子為魚類產品佔最大，包括燻製品和醃辣（需要特別關注）、預先做好的沙拉、新鮮蔬菜和水果，當你無法親自挑選時就詢問當地人（在商場上店鋪的婦女群，他們會教導你怎麼去挑好的食材，你",
        pinyin="tongchang",
        candidates=["通常", "通畅", "同唱", "铜厂", "同长", "同场", "同", "通", "痛", "铜"],
        source="p0-corpus:general-0004c529ea01e508",
    ),
    _case(
        "d-yanhai",
        context="南投市內流域有二，一為彰化",
        pinyin="yanhai",
        candidates=["沿海", "烟海", "烟害", "炎海", "砚海", "盐害", "眼", "演", "言", "烟"],
        source="p0-corpus:general-00073c4312f7a14b",
    ),
    # --- corpus-derived, fused-margin boundary members ---------------------
    _case(
        "d-zhishi",
        context="此响应代码表示服务器无法满足 请求标头字段所",
        pinyin="zhishi",
        candidates=["只是", "知识", "之时", "指示", "之事", "芝士", "致使", "之势", "制式", "之士"],
        source="p0-corpus:developer-0025cbee866575c6",
    ),
    _case(
        "d-fangzhi",
        context="另外，这些参数的用法会颠倒 — 插入符是",
        pinyin="fangzhi",
        candidates=["防止", "放置", "防治", "纺织", "仿制", "方知", "方志", "防制", "仿纸", "放至"],
        source="p0-corpus:developer-01527b47d16c563a",
    ),
    _case(
        "d-qiuzhi",
        context="总会同步地对表达式",
        pinyin="qiuzhi",
        candidates=["求职", "求知", "求治", "求值", "求之", "球", "求", "秋", "邱", "丘"],
        source="p0-corpus:developer-02aca7afe25d5149",
    ),
    # --- handcrafted edge shapes -------------------------------------------
    _case(
        "h-single-candidate",
        context="请执行这条",
        pinyin="mingling",
        candidates=["命令"],
    ),
    _case(
        "h-mixed-window",
        context="附近有没有",
        pinyin="fjfww",
        candidates=[
            "附近服务为",
            "附件服务为",
            "放进去",  # preserved：与首候选长度不同
            "附件服务网",
            "福晋服务为",
            "风景区",
            "复检服务为",
            "富锦服务为",
            "附近服务",
            "风景点",
            "风景区里",  # Top10 之外的尾巴
            "放进去吧",
        ],
    ),
    _case(
        "h-short-first",
        context="今天",
        pinyin="jintian",
        candidates=["今", "今天", "今天天气"],  # 首候选最短 → 仅 1 个全长 eligible
    ),
    _case(
        "h-empty-context",
        context="",
        pinyin="tianqi",
        candidates=["天气", "脾气", "添器", "田"],
    ),
    _case(
        "h-latin-candidates",
        context="git ",
        pinyin="commit",
        candidates=["commit", "comm", "it"],
    ),
    _case(
        "h-beam-sentence",
        context="",
        pinyin="jintiantianqi",
        candidates=["今天天气", "今天提起", "金田田七", "锦添天气"],
        allow_sentence=True,
    ),
    _case(
        "h-beam-too-long",
        context="讨论一下",
        pinyin="womenshibushiyinggaitingshuodedongxi",
        candidates=["我们是不是", "我们示意"],
        allow_sentence=True,
    ),
    _case(
        "h-segments",
        context="",
        pinyin="shi",
        candidates=["是", "时", "事", "世"],
        allow_sentence=True,
        segments=[
            {"pinyin": "mingling", "separator": "，", "committed_text": "明令"},
            {"pinyin": "shi", "separator": ""},
        ],
    ),
    _case(
        "h-tail-twelve",
        context="请执行这条",
        pinyin="mingling",
        candidates=[
            "命令",
            "明令",
            "名利",
            "命理",
            "明理",
            "冥理",
            "命里",
            "明礼",
            "鸣里",
            "铭理",
            "螟蛉",
            "茗荔",
        ],
    ),
    _case(
        "h-empty-candidates",
        context="请执行这条",
        pinyin="mingling",
        candidates=[],
    ),
]


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _artifact_record(role: str, path: Path, *extra: tuple[str, Any]) -> dict[str, Any]:
    record: dict[str, Any] = {
        "role": role,
        "path": str(path.relative_to(PROJECT_ROOT)),
        "sha256": _sha256(path),
    }
    record.update(dict(extra))
    return record


def _git_head() -> str:
    try:
        return (
            subprocess.run(
                ["git", "rev-parse", "--short", "HEAD"],
                cwd=PROJECT_ROOT,
                capture_output=True,
                text=True,
                check=True,
            )
            .stdout
            .strip()
        )
    except (OSError, subprocess.CalledProcessError):
        return "unknown"


def _fused_margin(hybrid: Any, case: dict[str, Any]) -> float | None:
    """Recomputes the fused top1-top2 margin for boundary classification."""
    from rimeai_runtime.candidate_policy import partition_full_length_candidates

    candidates = case["candidates"]
    window = [
        {"id": str(index), "text": candidate}
        for index, candidate in enumerate(candidates[: hybrid.rerank_window])
    ]
    eligible, _preserved = partition_full_length_candidates(window)
    if len(eligible) < 2:
        return None
    texts = [candidate["text"] for candidate in eligible]
    indices = [int(candidate["id"]) for candidate in eligible]
    neural_scores = hybrid.neural_ranker._scores(
        context=case["context"],
        pinyin=case["pinyin"],
        candidates=texts,
        baseline_indices=indices,
    )
    ngram_scores = [
        hybrid.ngram_ranker._candidate_score(case["context"], text, index)
        for text, index in zip(texts, indices, strict=True)
    ]
    fused = hybrid.config.fuse_scores(neural_scores, ngram_scores)
    order = sorted(range(len(fused)), key=lambda index: (-fused[index], index))
    return float(fused[order[0]] - fused[order[1]])


def _boundary_ranges(config: Any, margin: float) -> list[list[float]]:
    """Branch-legal confidence RANGES for a near-threshold margin.

    Near the calibrated threshold the fused margin wobbles by backend
    noise, so the below-branch confidence (0.55*margin/threshold) forms
    a continuum, not a point. Pin the FORMULA with the legal branch
    ranges instead: below-branch, calibrated-branch, and same-top 1.0.
    A legacy mapping (min(0.899, 0.5+0.399*ratio) >= 0.86 for ratio
    >= 0.9) lands in none of them.
    """
    threshold = config.margin_threshold
    target = config.target_precision
    slack = BOUNDARY_BAND + 0.01
    if threshold > 0:
        below_low = 0.55 * max(0.0, (threshold - slack) / threshold)
        below_high = 0.55
    else:
        below_low = below_high = 0.0
    calibrated_high = target + (1.0 - target) * (
        1.0 - pow(2.718281828459045, -slack)
    )
    return [
        [round(below_low, 10), round(below_high, 10)],
        [round(target, 10), round(calibrated_high, 10)],
        [1.0, 1.0],
    ]


def _hybrid_entry(hybrid: Any, case: dict[str, Any]) -> dict[str, Any]:
    ranking, confidence = hybrid.rank_candidates(
        context=case["context"],
        pinyin=case["pinyin"],
        candidates=case["candidates"],
    )
    entry: dict[str, Any] = {
        "ranking": ranking,
        "confidence": confidence,
    }
    margin = _fused_margin(hybrid, case)
    if margin is not None:
        entry["fused_margin"] = margin
        if abs(margin - hybrid.config.margin_threshold) <= BOUNDARY_BAND:
            entry["boundary"] = True
            entry["confidence_legal_ranges"] = _boundary_ranges(
                hybrid.config, margin
            )
    return entry


def _engine_entry(
    engine: Any,
    case: dict[str, Any],
    boundary_cases: dict[str, list[list[float]]] | None = None,
) -> dict[str, Any]:
    request = {
        "context": case["context"],
        "pinyin": case["pinyin"],
        "candidates": list(case["candidates"]),
        "allow_sentence": case["allow_sentence"],
    }
    if "segments" in case:
        request["segments"] = case["segments"]
    result = engine.infer(request)
    entry = dict(result)
    ranges = (boundary_cases or {}).get(case["id"])
    if ranges:
        # Near the B-F1 gate the decision/confidence pair can legally
        # flip between branches (including same-top) under backend noise.
        entry["relaxed_boundary"] = True
        entry["decision_alternatives"] = sorted(
            {
                result["decision"],
                "ranked_candidate",
                "below_confidence",
                "same_top_candidate",
            }
        )
        entry["confidence_legal_ranges"] = ranges
    return entry


def _beam_entry(decoder: Any, case: dict[str, Any]) -> dict[str, Any]:
    if "segments" in case:
        from rimeai_runtime.beam_decoder import SegmentDecodeInput

        suggestion = decoder.suggest_segments(
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
        suggestion = decoder.suggest(
            context=case["context"],
            pinyin=case["pinyin"],
            candidates=case["candidates"],
        )
    return {
        "text": suggestion.text,
        "confidence": suggestion.confidence,
        "reason": suggestion.reason,
    }


def _versions() -> dict[str, Any]:
    versions: dict[str, Any] = {}
    try:
        import torch

        versions["torch"] = torch.__version__
    except ImportError:
        versions["torch"] = None
    try:
        import onnxruntime

        versions["onnxruntime"] = onnxruntime.__version__
    except ImportError:
        versions["onnxruntime"] = None
    return versions


def build(output: Path, *, device: str) -> dict[str, Any]:
    # Import lazily so `--help` works without the ML stack installed.
    from rimeai_daemon.engine import LocalInferenceEngine
    from rimeai_runtime.beam_decoder import BeamSentenceDecoder, load_beam_config
    from rimeai_runtime.neural_ranker import HybridSemanticRanker, load_neural_ranker
    from rimeai_runtime.ngram_ranker import load_ngram_model
    from rimeai_runtime.pinyin_guard import PinyinGuard

    missing = [
        path
        for path in (NGRAM_ARTIFACT, BEAM_CONFIG, DICTIONARY)
        if not path.is_file()
    ]
    if missing:
        raise SystemExit(
            "required artifacts missing: "
            + ", ".join(str(path) for path in missing)
        )

    try:
        import torch

        torch.set_num_threads(1)
    except ImportError:
        pass

    print("loading n-gram artifact …")
    guard = PinyinGuard.from_rime_dictionary(DICTIONARY)
    ngram = load_ngram_model(NGRAM_ARTIFACT)
    beam_config = load_beam_config(BEAM_CONFIG)
    decoder = BeamSentenceDecoder(ngram, guard, beam_config)

    captures: dict[str, Any] = {}

    captures["ngram_rank"] = {
        "description": "NGramRankerModel.rank — 纯 Python，逐位对拍",
        "numeric": {"confidence": "exact"},
        "rerank_window": ngram.rerank_window,
        "artifacts": [
            _artifact_record("language_model", NGRAM_ARTIFACT),
        ],
        "results": {},
    }
    for case in CASES:
        ranking, confidence = ngram.rank(
            context=case["context"], candidates=case["candidates"]
        )
        captures["ngram_rank"]["results"][case["id"]] = {
            "ranking": ranking,
            "confidence": confidence,
        }

    captures["beam"] = {
        "description": "BeamSentenceDecoder.suggest/suggest_segments — 纯 Python，逐位对拍",
        "numeric": {"confidence": "exact"},
        "artifacts": [
            _artifact_record("language_model", NGRAM_ARTIFACT),
            _artifact_record("sentence_config", BEAM_CONFIG),
            _artifact_record("rime_dictionary", DICTIONARY),
        ],
        "results": {
            case["id"]: _beam_entry(decoder, case) for case in CASES
        },
    }

    def engine_group(name: str, engine: LocalInferenceEngine, artifacts: list, numeric: dict, description: str, boundary_cases: dict[str, list[list[float]]] | None = None) -> None:
        captures[name] = {
            "description": description,
            "numeric": numeric,
            "artifacts": artifacts,
            "results": {
                case["id"]: _engine_entry(engine, case, boundary_cases)
                for case in CASES
            },
        }

    print("replaying ngram-only engine …")
    engine_ngram = LocalInferenceEngine(
        language_model_path=NGRAM_ARTIFACT,
        beam_config_path=BEAM_CONFIG,
        rime_dictionary_path=DICTIONARY,
    )
    engine_group(
        "engine_ngram",
        engine_ngram,
        [
            _artifact_record("language_model", NGRAM_ARTIFACT),
            _artifact_record("sentence_config", BEAM_CONFIG),
            _artifact_record("rime_dictionary", DICTIONARY),
        ],
        {"confidence": "exact"},
        "LocalInferenceEngine（n-gram-only 配置）infer 全路径 — decision/sentence",
        None,
    )

    hybrid_specs: list[tuple[str, Path, Path, str]] = []
    if TORCH_RANKER.is_dir() and TORCH_FUSION.is_file():
        hybrid_specs.append(("hybrid_torch", TORCH_RANKER, TORCH_FUSION, device))
    else:
        print("torch 24M artifacts absent; skipping hybrid_torch groups")
    if ONNX_RANKER.is_dir() and ONNX_FUSION.is_file():
        hybrid_specs.append(("hybrid_onnx", ONNX_RANKER, ONNX_FUSION, "cpu"))
    else:
        print("ONNX artifacts absent; skipping hybrid_onnx groups")

    boundary_cases: dict[str, list[list[float]]] = {}
    for prefix, ranker_dir, fusion_path, ranker_device in hybrid_specs:
        print(f"replaying {prefix} …")
        neural = load_neural_ranker(ranker_dir, guard, device=ranker_device)
        hybrid = HybridSemanticRanker(neural, ngram, fusion_path)
        approx = 0.01 if prefix == "hybrid_torch" else 1e-6
        captures[prefix] = {
            "description": (
                "HybridSemanticRanker.rank_candidates — torch CPU 后端非逐位确定"
                if prefix == "hybrid_torch"
                else "HybridSemanticRanker.rank_candidates — ONNX int8 后端"
            ),
            "numeric": {"confidence": "approx", "abs": approx},
            "device": ranker_device,
            "rerank_window": hybrid.rerank_window,
            "threshold": hybrid.config.margin_threshold,
            "artifacts": [
                _artifact_record("language_model", NGRAM_ARTIFACT),
                _artifact_record(
                    "neural_ranker_manifest",
                    ranker_dir / "manifest.json",
                    ("artifact_id", getattr(hybrid.neural_ranker, "model_artifact_id", None)),
                ),
                _artifact_record("fusion_config", fusion_path),
            ],
            "results": {
                case["id"]: _hybrid_entry(hybrid, case) for case in CASES
            },
        }
        for case_id, entry in captures[prefix]["results"].items():
            if entry.get("boundary"):
                boundary_cases[case_id] = entry["confidence_legal_ranges"]

        engine = LocalInferenceEngine(
            language_model_path=NGRAM_ARTIFACT,
            beam_config_path=BEAM_CONFIG,
            rime_dictionary_path=DICTIONARY,
            neural_model_path=ranker_dir,
            fusion_config_path=fusion_path,
            neural_device=ranker_device,
        )
        engine_artifacts = [
            *_artifact_records_for_engine(False),
            _artifact_record(
                "neural_ranker_manifest",
                ranker_dir / "manifest.json",
                ("artifact_id", getattr(hybrid.neural_ranker, "model_artifact_id", None)),
            ),
            _artifact_record("fusion_config", fusion_path),
        ]
        engine_group(
            f"engine_{prefix}",
            engine,
            engine_artifacts,
            {"confidence": "approx", "abs": approx},
            f"LocalInferenceEngine（{prefix} 配置）infer 全路径 — decision/sentence",
            boundary_cases if approx == 0.01 else None,
        )

    if USER_LM.is_file():
        print("replaying user-LM view …")
        from rimeai_runtime.user_lm_view import UserLanguageModelView

        view = UserLanguageModelView.load(USER_LM)
        captures["user_lm_view"] = {
            "description": "UserLanguageModelView.log_prob_sum — 冻结评测制品，纯 Python 逐位对拍",
            "numeric": {"confidence": "exact"},
            "artifacts": [_artifact_record("user_lm", USER_LM)],
            "results": {
                case["id"]: {
                    "log_prob_sums": [
                        view.log_prob_sum(case["context"], candidate)
                        for candidate in case["candidates"][:5]
                    ]
                }
                for case in CASES
                if case["candidates"]
            },
        }
        if TORCH_RANKER.is_dir() and TORCH_FUSION.is_file():
            print("replaying hybrid+user-lm engine (L2 guard end-to-end) …")
            engine_user = LocalInferenceEngine(
                language_model_path=NGRAM_ARTIFACT,
                beam_config_path=BEAM_CONFIG,
                rime_dictionary_path=DICTIONARY,
                neural_model_path=TORCH_RANKER,
                fusion_config_path=TORCH_FUSION,
                neural_device=device,
                user_lm_path=USER_LM,
            )
            engine_group(
                "engine_hybrid_torch_userlm",
                engine_user,
                [
                    *_artifact_records_for_engine(True),
                    _artifact_record("user_lm", USER_LM),
                ],
                {"confidence": "approx", "abs": 0.01},
                "LocalInferenceEngine（hybrid_torch + 冻结用户 LM）— B-F6 窗口守卫端到端",
                boundary_cases,
            )
    else:
        print("frozen user-LM artifact absent; skipping user-LM groups")

    golden = {
        "schema_version": SCHEMA_VERSION,
        "golden_id": GOLDEN_ID,
        "_readme": (
            "本 golden 的使命：未来改动不得无意识漂移——不是证明等于改前。"
            "有意语义变更后请用 tools/build_ranker_goldens.py 重新生成，"
            "并同步更新 code_semantics 锚；无意漂移（回归）必须让回放失败。"
            "本机缺真实制品或制品 sha256 变化时对应组自动 skip，不算失败。"
        ),
        "code_semantics": dict(CODE_SEMANTICS),
        "head_commit": _git_head(),
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "versions": _versions(),
        "boundary_band": BOUNDARY_BAND,
        "case_count": len(CASES),
        "cases": CASES,
        "captures": captures,
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(golden, ensure_ascii=False, indent=1, sort_keys=True),
        encoding="utf-8",
    )
    print(f"wrote {output}")
    for name, capture in captures.items():
        boundary = sum(
            1
            for entry in capture["results"].values()
            if entry.get("boundary") or entry.get("relaxed_boundary")
        )
        print(
            f"  {name}: {len(capture['results'])} entries"
            + (f" ({boundary} boundary)" if boundary else "")
        )
    return golden


def _artifact_records_for_engine(hybrid: bool) -> list[dict[str, Any]]:
    records = [
        _artifact_record("language_model", NGRAM_ARTIFACT),
        _artifact_record("sentence_config", BEAM_CONFIG),
        _artifact_record("rime_dictionary", DICTIONARY),
    ]
    if hybrid:
        records.extend(
            [
                _artifact_record(
                    "neural_ranker_manifest", TORCH_RANKER / "manifest.json"
                ),
                _artifact_record("fusion_config", TORCH_FUSION),
            ]
        )
    return records


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument(
        "--device",
        default="cpu",
        help="torch device for the 24M replay (default cpu for stability)",
    )
    args = parser.parse_args(argv)
    build(args.output, device=args.device)
    return 0


if __name__ == "__main__":
    sys.exit(main())
