#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
model_root=${RIMEAI_MODEL_ROOT:-"${project_root}/.rimeai/models"}
model_dir="${model_root}/qwen2.5-0.5b-instruct-7ae5576"
revision="7ae557604adf67be50417f59c2c2f167def9a775"
model_sha256="fdf756fa7fcbe7404d5c60e26bff1a0c8b8aa1f72ced49e7dd0210fe288fb7fe"
files=(
  LICENSE
  config.json
  generation_config.json
  merges.txt
  model.safetensors
  tokenizer.json
  tokenizer_config.json
  vocab.json
)
blob_ids=(
  6634c8cc3133b3848ec74b9f275acaaa1ea618ab
  0dbb161213629a23f0fc00ef286e6b1e366d180f
  dfc11073787daf1b0f9c0f1499487ab5f4c93738
  20024bfe7c83998e9aeaf98a0cd6a2ce6306c2f0
  ''
  443909a61d429dff23010e5bddd28ff530edda00
  07bfe0640cb5a0037f9322287fbfc682806cf672
  4783fe10ac3adce15ac8f358ef5462739852c569
)

verify_model() {
  local index file expected actual
  for (( index=1; index<=${#files}; index++ )); do
    file=${files[index]}
    [[ -f "${model_dir}/${file}" ]] || return 1
    if [[ ${file} == model.safetensors ]]; then
      actual=$(shasum -a 256 "${model_dir}/${file}" | awk '{print $1}')
      [[ ${actual} == ${model_sha256} ]] || return 1
    else
      expected=${blob_ids[index]}
      actual=$(git hash-object "${model_dir}/${file}")
      [[ ${actual} == ${expected} ]] || return 1
    fi
  done
}

if verify_model; then
  print -r -- "model=${model_dir}"
  exit 0
fi

command -v hf >/dev/null 2>&1 || {
  print -u2 "error: the Hugging Face 'hf' CLI is required"
  exit 2
}

download_root=$(mktemp -d /tmp/rimeai-qwen-download.XXXXXX)
cleanup() {
  case ${download_root} in
    /tmp/rimeai-qwen-download.*)
      command rm -rf -- "${download_root}"
      ;;
    *)
      print -u2 "error: refusing to remove unexpected temporary path"
      return 1
      ;;
  esac
}
trap cleanup EXIT

hf download Qwen/Qwen2.5-0.5B-Instruct \
  ${files[@]} \
  --revision "${revision}" \
  --local-dir "${download_root}"

mkdir -p "${model_dir}"
for file in ${files[@]}; do
  command cp "${download_root}/${file}" "${model_dir}/${file}"
done

if ! verify_model; then
  print -u2 "error: downloaded Qwen model did not match the pinned lock"
  exit 2
fi

cleanup
trap - EXIT
print -r -- "model=${model_dir}"
