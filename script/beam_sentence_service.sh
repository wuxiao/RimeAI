#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}

export RIMEAI_BEAM_DECODER_CONFIG=${RIMEAI_BEAM_DECODER_CONFIG:-"${project_root}/.rimeai/models/p0-beam-sentence-v3.json"}
export RIMEAI_NGRAM_MODEL=${RIMEAI_NGRAM_MODEL:-"${project_root}/.rimeai/models/p0-char-ngram-v2.json.gz"}
export RIMEAI_RIME_DICTIONARY=${RIMEAI_RIME_DICTIONARY:-"${project_root}/.rimeai/rime/shared/luna_pinyin.dict.yaml"}
export NO_PROXY='*'
export no_proxy='*'

for required_file in \
  "${RIMEAI_BEAM_DECODER_CONFIG}" \
  "${RIMEAI_NGRAM_MODEL}" \
  "${RIMEAI_RIME_DICTIONARY}"; do
  if [[ ! -f ${required_file} ]]; then
    print -u2 "error: missing decoder dependency: ${required_file}"
    exit 2
  fi
done

exec python3 "${project_root}/tools/beam_sentence_worker.py"
