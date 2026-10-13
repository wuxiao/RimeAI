#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
model_root=${RIMEAI_MODEL_ROOT:-"${project_root}/.rimeai/models"}
model_dir="${model_root}/qwen2.5-0.5b-base-060db64"
revision="060db6499f32faf8b98477b0a26969ef7d8b9987"
model_sha256="88c142557820ccad55bb59756bfcfcf891de9cc6202816bd346445188a0ed342"
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
  141506237b9022c4ab3e01734cfafb9310b57d2d
  cbbb3133034e192527e5321b4c679154e4819ab8
  20024bfe7c83998e9aeaf98a0cd6a2ce6306c2f0
  ''
  443909a61d429dff23010e5bddd28ff530edda00
  ba7e4c5637b9732dadcd66286ce48334e8b31e9e
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

download_root=$(mktemp -d /tmp/rimeai-qwen-base-download.XXXXXX)
cleanup() {
  case ${download_root} in
    /tmp/rimeai-qwen-base-download.*)
      command rm -rf -- "${download_root}"
      ;;
    *)
      print -u2 "error: refusing to remove unexpected temporary path"
      return 1
      ;;
  esac
}
trap cleanup EXIT

hf download Qwen/Qwen2.5-0.5B \
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
