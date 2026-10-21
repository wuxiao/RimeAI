#!/bin/zsh
# shellcheck disable=SC1071

set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
model_root=${RIMEAI_MODEL_ROOT:-"${project_root}/.rimeai/models"}
# SFT 对照评估（LM-002）经外部 RIMEAI_MLX_MODEL_DIR 指向 fused 制品目录；
# 产品默认仍是 lock 过的 8-bit 基座。
model_dir="${RIMEAI_MLX_MODEL_DIR:-"${model_root}/qwen2.5-0.5b-mlx-8bit-v1"}"
mlx_venv="${RIMEAI_MLX_VENV:-"${project_root}/.rimeai/mlx-venv"}"

if [[ ! -f "${model_dir}/model.safetensors" ]]; then
  print -u2 "error: MLX model files missing at ${model_dir} (see models/qwen2.5-0.5b-mlx-8bit.lock.json)"
  exit 2
fi
if [[ ! -x "${mlx_venv}/bin/python" ]]; then
  print -u2 "error: isolated MLX venv missing at ${mlx_venv} (mlx-lm==0.32.2, mlx==0.32.4)"
  exit 2
fi

export HF_HUB_OFFLINE=1
export TRANSFORMERS_OFFLINE=1
export HF_HUB_DISABLE_TELEMETRY=1
export DO_NOT_TRACK=1
export TOKENIZERS_PARALLELISM=false
export RIMEAI_MLX_MODEL_DIR="${model_dir}"
export RIMEAI_RIME_DICTIONARY="${project_root}/.rimeai/rime/shared/luna_pinyin.dict.yaml"
export PYTHONPATH="${project_root}${PYTHONPATH:+:${PYTHONPATH}}"
export NO_PROXY='*'
export no_proxy='*'

exec "${mlx_venv}/bin/python" -m rimeai_runtime.mlx_worker
