#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
model_root=${RIMEAI_MODEL_ROOT:-"${project_root}/.rimeai/models"}
model_dir="${model_root}/gte-multilingual-reranker-base-8215cf0"
code_dir="${model_root}/new_impl_40ced75"

if [[ ! -f "${model_dir}/model.safetensors" ]] ||
   [[ ! -f "${code_dir}/modeling.py" ]]; then
  print -u2 "error: run scripts/bootstrap_gte_model.sh first"
  exit 2
fi

export HF_HUB_OFFLINE=1
export TRANSFORMERS_OFFLINE=1
export HF_HUB_DISABLE_TELEMETRY=1
export DO_NOT_TRACK=1
export TOKENIZERS_PARALLELISM=false
export RIMEAI_GTE_MODEL_DIR="${model_dir}"
export RIMEAI_GTE_CODE_DIR="${code_dir}"
export RIMEAI_GTE_DEVICE=${RIMEAI_GTE_DEVICE:-mps}
export RIMEAI_GTE_STRATEGY=${RIMEAI_GTE_STRATEGY:-context-candidate}

exec python3 "${project_root}/tools/gte_ranker_worker.py"
