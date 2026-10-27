#!/bin/bash
# λ 扫描跑批：按 split 全量，逐轮保存报告与 details。
# 用法: run_fusion_sweep.sh <split> <outdir>
set -euo pipefail
cd "$(dirname "$0")/.."
SPLIT="${1:-validation}"
OUT="${2:-/tmp/neural-user-fusion-eval}/${SPLIT}"
DATASET=.rimeai/datasets/p0-librime-1.17.0-luna-simp.jsonl
USER_LM=.rimeai/models/eval-user-lm-p0-train/user-lm.json.gz
mkdir -p "${OUT}"

# reveal C-F5：details 里的 effective_knobs（worker stats 透出）必须与
# 该臂预期一致，不一致即非零退出——脏 shell 环境污染（export 进来的
# 旧 USER_LM/LENGTH_PENALTY 值）会在这一步被抓到，而不是产出一份
# "名义 baseline、实际带融合"的污染报告。
assert_knobs() {
  local details="$1"; local expect_weight="$2"
  .venv/bin/python - "$details" "$expect_weight" <<'PY'
import json
import sys

details_path, expect_weight = sys.argv[1], float(sys.argv[2])
mismatches = 0
rows = 0
with open(details_path, encoding="utf-8") as file:
    for line in file:
        line = line.strip()
        if not line:
            continue
        rows += 1
        row = json.loads(line)
        knobs = row.get("effective_knobs") or {}
        weight = knobs.get("user_lm_weight")
        penalty = knobs.get("length_penalty")
        if (
            weight is None
            or float(weight) != expect_weight
            or penalty is None
            or float(penalty) != 0.0
        ):
            mismatches += 1
if mismatches:
    print(
        f"knob mismatch: {mismatches}/{rows} rows "
        f"(expected user_lm_weight={expect_weight}, length_penalty=0.0)",
        file=sys.stderr,
    )
    raise SystemExit(1)
print(f"  knobs ok: user_lm_weight={expect_weight} length_penalty=0.0 ({rows} rows)")
PY
}

run_one() {
  local tag="$1"; shift
  local weight="$1"; shift
  local expect_weight="$1"; shift
  local with_env="$1"; shift
  echo "== [${SPLIT}] lambda=${weight} (${tag}) =="
  # 每臂回显生效旋钮（与 assert_knobs 的预期一致）。
  echo "   knobs: user_lm_weight=${expect_weight} length_penalty=0.0"
  if [[ "${with_env}" == "yes" ]]; then
    env RIMEAI_MLX_USER_LM_PATH="${USER_LM}" \
        RIMEAI_MLX_USER_LM_WEIGHT="${weight}" \
        .venv/bin/python -m rimeai_eval evaluate-sentence "${DATASET}" \
          --decoder-config examples/constrained_mlx_decoder.json \
          --rime-dictionary .rimeai/rime/shared/luna_pinyin.dict.yaml \
          --split "${SPLIT}" \
          --details-output "${OUT}/details-l${weight}-${tag}.jsonl" \
          > "${OUT}/report-l${weight}-${tag}.json" 2> "${OUT}/stderr-l${weight}-${tag}.log"
  else
    # reveal C-F5：baseline 臂显式清掉融合/惩罚旋钮——脏 shell 里
    # export 过的旧值会让"基线"臂悄悄带着融合跑，产出被污染的对照。
    env -u RIMEAI_MLX_USER_LM_PATH -u RIMEAI_MLX_USER_LM_WEIGHT \
        -u RIMEAI_MLX_LENGTH_PENALTY \
        .venv/bin/python -m rimeai_eval evaluate-sentence "${DATASET}" \
          --decoder-config examples/constrained_mlx_decoder.json \
          --rime-dictionary .rimeai/rime/shared/luna_pinyin.dict.yaml \
          --split "${SPLIT}" \
          --details-output "${OUT}/details-l${weight}-${tag}.jsonl" \
          > "${OUT}/report-l${weight}-${tag}.json" 2> "${OUT}/stderr-l${weight}-${tag}.log"
  fi
  assert_knobs "${OUT}/details-l${weight}-${tag}.jsonl" "${expect_weight}"
  .venv/bin/python - "$OUT/report-l${weight}-${tag}.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
m = r["metrics"]
print(f"  accuracy={m['sentence_accuracy']} baseline={m['baseline_sentence_accuracy']} "
      f"lift={m['relative_lift']} samples={r['dataset']['samples']}")
PY
}

run_one baseline 0 0.0 no
run_one withview 0.0 0.0 yes
run_one fused 0.1 0.1 yes
run_one fused 0.2 0.2 yes
run_one fused 0.35 0.35 yes
echo "sweep done: ${OUT}"
