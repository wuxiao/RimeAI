#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
model_path=${RIMEAI_NGRAM_MODEL:-"${project_root}/.rimeai/models/p0-char-ngram-v2.json.gz"}

if [[ ! -f "${model_path}" ]]; then
  print -u2 "error: train the n-gram model before starting the service"
  exit 2
fi

export RIMEAI_NGRAM_MODEL="${model_path}"
export NO_PROXY='*'
export no_proxy='*'

exec python3 "${project_root}/tools/ngram_ranker_worker.py"
