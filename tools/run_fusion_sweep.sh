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

run_one() {
  local tag="$1"; shift
  local weight="$1"; shift
  local with_env="$1"; shift
  echo "== [${SPLIT}] lambda=${weight} (${tag}) =="
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
    .venv/bin/python -m rimeai_eval evaluate-sentence "${DATASET}" \
      --decoder-config examples/constrained_mlx_decoder.json \
      --rime-dictionary .rimeai/rime/shared/luna_pinyin.dict.yaml \
      --split "${SPLIT}" \
      --details-output "${OUT}/details-l${weight}-${tag}.jsonl" \
      > "${OUT}/report-l${weight}-${tag}.json" 2> "${OUT}/stderr-l${weight}-${tag}.log"
  fi
  .venv/bin/python - "$OUT/report-l${weight}-${tag}.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
m = r["metrics"]
print(f"  accuracy={m['sentence_accuracy']} baseline={m['baseline_sentence_accuracy']} "
      f"lift={m['relative_lift']} samples={r['dataset']['samples']}")
PY
}

run_one baseline 0 no
run_one withview 0.0 yes
run_one fused 0.1 yes
run_one fused 0.2 yes
run_one fused 0.35 yes
echo "sweep done: ${OUT}"
