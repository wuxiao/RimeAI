#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
model_root=${RIMEAI_MODEL_ROOT:-"${project_root}/.rimeai/models"}
model_dir="${model_root}/gte-multilingual-reranker-base-8215cf0"
code_dir="${model_root}/new_impl_40ced75"
model_revision="8215cf04918ba6f7b6a62bb44238ce2953d8831c"
code_revision="40ced75c3017eb27626c9d4ea981bde21a2662f4"
model_sha256="10ebaa49322dd7e01a13a91c49810939e3f91f231aceaa47fdf0cab3083954f6"
tokenizer_sha256="d6f76fe13d42f80dcee0cb86a1aeb5f14f8909bb8a8782f7a4a4ad76697ef164"

if ! command -v hf >/dev/null 2>&1; then
  print -u2 "error: Hugging Face 'hf' CLI is required"
  exit 2
fi

mkdir -p "${model_dir}" "${code_dir}"
export HF_HUB_DISABLE_TELEMETRY=1

hf download Alibaba-NLP/gte-multilingual-reranker-base \
  --revision "${model_revision}" \
  --local-dir "${model_dir}" \
  --exclude 'images/*' \
  --quiet

hf download Alibaba-NLP/new-impl configuration.py modeling.py \
  --revision "${code_revision}" \
  --local-dir "${code_dir}" \
  --quiet

print -r -- "" > "${code_dir}/__init__.py"
dot_clean -m "${model_dir}" >/dev/null 2>&1 || true
dot_clean -m "${code_dir}" >/dev/null 2>&1 || true

actual_model_sha256=$(shasum -a 256 "${model_dir}/model.safetensors" | awk '{print $1}')
actual_tokenizer_sha256=$(shasum -a 256 "${model_dir}/tokenizer.json" | awk '{print $1}')
if [[ ${actual_model_sha256} != ${model_sha256} ]]; then
  print -u2 "error: GTE model SHA-256 mismatch"
  exit 2
fi
if [[ ${actual_tokenizer_sha256} != ${tokenizer_sha256} ]]; then
  print -u2 "error: GTE tokenizer SHA-256 mismatch"
  exit 2
fi

print -r -- "model=${model_dir}"
print -r -- "code=${code_dir}"
