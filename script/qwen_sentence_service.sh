#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
model_root=${RIMEAI_MODEL_ROOT:-"${project_root}/.rimeai/models"}
model_dir="${model_root}/qwen2.5-0.5b-instruct-7ae5576"

if [[ ! -f "${model_dir}/model.safetensors" ]]; then
  print -u2 "error: run scripts/bootstrap_qwen_sentence_model.sh first"
  exit 2
fi

export HF_HUB_OFFLINE=1
export TRANSFORMERS_OFFLINE=1
export HF_HUB_DISABLE_TELEMETRY=1
export DO_NOT_TRACK=1
export TOKENIZERS_PARALLELISM=false
export RIMEAI_QWEN_MODEL_DIR="${model_dir}"
export RIMEAI_QWEN_DEVICE=${RIMEAI_QWEN_DEVICE:-mps}
export RIMEAI_RIME_DICTIONARY="${project_root}/.rimeai/rime/shared/luna_pinyin.dict.yaml"
export NO_PROXY='*'
export no_proxy='*'

exec python3 "${project_root}/tools/qwen_sentence_worker.py"
