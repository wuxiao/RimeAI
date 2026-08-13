#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
model_root=${RIMEAI_MODEL_ROOT:-"${project_root}/.rimeai/models"}
model_dir="${model_root}/bge-small-zh-v1.5-7999e1d"
revision="7999e1d3359715c523056ef9478215996d62a620"
files=(
  README.md
  config.json
  model.safetensors
  special_tokens_map.json
  tokenizer.json
  tokenizer_config.json
  vocab.txt
)
hashes=(
  c48a4eeea77f6b1d38b48ec1c5b8d4f86d5550cc43fa345a0db1b2ca1d082369
  3853a7979202c348751b753e36f579c41d8da7d36af617d3d907e1fc9b441f2a
  354763b9b1357bc9c44f62c6be2276321081ed2567773608c0d0785b61d5a026
  b6d346be366a7d1d48332dbc9fdf3bf8960b5d879522b7799ddba59e76237ee3
  48cea5d44424912a6fd1ea647bf4fe50b55ab8b1e5879c3275f80e339e8fae26
  e6f3b96db926a37d4039995fbf5ad17de158dfb8f6343d607e4dbaad18d75f5a
  45bbac6b341c319adc98a532532882e91a9cefc0329aa57bac9ae761c27b291c
)

verify_model() {
  local index file actual
  for (( index=1; index<=${#files}; index++ )); do
    file=${files[index]}
    [[ -f "${model_dir}/${file}" ]] || return 1
    actual=$(shasum -a 256 "${model_dir}/${file}" | awk '{print $1}')
    [[ ${actual} == ${hashes[index]} ]] || return 1
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

download_root=$(mktemp -d /tmp/rimeai-bge-download.XXXXXX)
cleanup() {
  case ${download_root} in
    /tmp/rimeai-bge-download.*)
      command rm -rf -- "${download_root}"
      ;;
    *)
      print -u2 "error: refusing to remove unexpected temporary path"
      return 1
      ;;
  esac
}
trap cleanup EXIT

HF_HUB_DISABLE_TELEMETRY=1 hf download BAAI/bge-small-zh-v1.5 \
  ${files[@]} \
  --revision "${revision}" \
  --local-dir "${download_root}"

mkdir -p "${model_dir}"
for file in ${files[@]}; do
  command cp "${download_root}/${file}" "${model_dir}/${file}"
done
dot_clean -m "${model_dir}" >/dev/null 2>&1 || true

if ! verify_model; then
  print -u2 "error: downloaded BGE model did not match the pinned lock"
  exit 2
fi

cleanup
trap - EXIT
print -r -- "model=${model_dir}"
