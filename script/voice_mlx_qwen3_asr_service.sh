#!/bin/zsh
# shellcheck disable=SC1071

set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
model_root=${RIMEAI_MODEL_ROOT:-"${project_root}/.rimeai/models"}
model_dir="${RIMEAI_VOICE_MLX_MODEL_DIR:-"${model_root}/qwen3-asr-0.6b-8bit"}"
voice_venv="${RIMEAI_VOICE_MLX_VENV:-"${project_root}/.rimeai/voice-mlx-venv"}"

if [[ ! -d "${model_dir}" ]]; then
  print -u2 "error: Qwen3-ASR MLX model missing at ${model_dir}"
  exit 2
fi
if [[ ! -x "${voice_venv}/bin/python" ]]; then
  print -u2 "error: isolated voice MLX venv missing at ${voice_venv}"
  exit 2
fi

export HF_HUB_OFFLINE=1
export TRANSFORMERS_OFFLINE=1
export HF_HUB_DISABLE_TELEMETRY=1
export DO_NOT_TRACK=1
export TOKENIZERS_PARALLELISM=false
export RIMEAI_VOICE_MLX_MODEL_DIR="${model_dir}"
export PYTHONPATH="${project_root}${PYTHONPATH:+:${PYTHONPATH}}"
export NO_PROXY='*'
export no_proxy='*'

exec "${voice_venv}/bin/python" -m rimeai_runtime.qwen3_asr_worker
