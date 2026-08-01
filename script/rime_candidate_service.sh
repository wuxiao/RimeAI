#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
runtime_root=${RIMEAI_RIME_ROOT:-"${project_root}/.rimeai/rime"}
shared_dir="${runtime_root}/shared"
user_dir="${runtime_root}/user"

if [[ ! -f "${shared_dir}/luna_pinyin_simp.schema.yaml" ]]; then
  "${project_root}/scripts/bootstrap_rime_data.sh" >/dev/null
fi

cd "${project_root}"
swift build --product rime-candidate-service >/dev/null
binary_path=$(swift build --show-bin-path)/rime-candidate-service

exec "${binary_path}" \
  --shared-data "${shared_dir}" \
  --user-data "${user_dir}" \
  --schema luna_pinyin_simp
