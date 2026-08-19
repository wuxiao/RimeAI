#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
runtime_root=${RIMEAI_RIME_ROOT:-"${project_root}/.rimeai/rime"}
source_root="${runtime_root}/sources"
shared_dir="${runtime_root}/shared"
user_dir="${runtime_root}/user"
opencc_data_dir="${project_root}/ios/RimeData/shared/opencc"

mkdir -p "${source_root}" "${user_dir}"

for required_opencc_file in t2s.json TSCharacters.ocd2 TSPhrases.ocd2; do
  if [[ ! -f "${opencc_data_dir}/${required_opencc_file}" ]]; then
    print -u2 "error: tracked OpenCC data is incomplete: ${required_opencc_file}"
    exit 1
  fi
done

repositories=(
  "rime-prelude|https://github.com/rime/rime-prelude.git|082425ea0684bca36474415d4a0e8db9b016487e"
  "rime-essay|https://github.com/rime/rime-essay.git|e9b1a374a6ea015fca5bdd04318924b4483ac35a"
  "rime-luna-pinyin|https://github.com/rime/rime-luna-pinyin.git|56b934b099dfbeab842320f13aa8b461a6ab3e42"
  "rime-stroke|https://github.com/rime/rime-stroke.git|3a4b0f4013e2b4c14b1e80c92b1d4723eb65f39c"
)

for repository in "${repositories[@]}"; do
  parts=("${(@s:|:)repository}")
  name=${parts[1]}
  url=${parts[2]}
  revision=${parts[3]}
  checkout="${source_root}/${name}"
  if [[ ! -d "${checkout}/.git" ]]; then
    git clone --quiet --no-checkout "${url}" "${checkout}"
  fi
  if ! git -C "${checkout}" cat-file -e "${revision}^{commit}" 2>/dev/null; then
    git -C "${checkout}" fetch --quiet --depth 1 origin "${revision}"
  fi
  git -C "${checkout}" checkout --quiet --detach "${revision}"
done

stage_dir=$(mktemp -d "${runtime_root}/shared.XXXXXX")
cleanup() {
  if [[ -d ${stage_dir} ]]; then
    case ${stage_dir} in
      "${runtime_root}"/shared.*)
        command rm -rf -- "${stage_dir}"
        ;;
      *)
        print -u2 "error: refusing to clean unexpected staging path: ${stage_dir}"
        return 1
        ;;
    esac
  fi
}
trap cleanup EXIT

rsync -a --exclude='._*' --include='*.yaml' --exclude='*' \
  "${source_root}/rime-prelude/" "${stage_dir}/"
rsync -a --exclude='._*' --include='*.yaml' --exclude='*' \
  "${source_root}/rime-luna-pinyin/" "${stage_dir}/"
rsync -a --exclude='._*' --include='*.yaml' --exclude='*' \
  "${source_root}/rime-stroke/" "${stage_dir}/"
rsync -a "${source_root}/rime-essay/essay.txt" "${stage_dir}/essay.txt"
# The controlled macOS runtime links librime-opencc, but the conversion filter
# also requires its JSON configurations and compiled dictionaries at runtime.
# Reuse the same tracked, licensed data set shipped by the iOS target.
rsync -a --exclude='._*' "${opencc_data_dir}/" "${stage_dir}/opencc/"
rsync -a "${project_root}/native/rime/default.custom.yaml" \
  "${stage_dir}/default.custom.yaml"
rsync -a "${project_root}/native/rime/data-lock.json" \
  "${stage_dir}/data-lock.json"
dot_clean -m "${stage_dir}" >/dev/null 2>&1 || true

case ${shared_dir} in
  "${runtime_root}"/shared)
    command rm -rf -- "${shared_dir}"
    ;;
  *)
    print -u2 "error: refusing to replace unexpected shared path: ${shared_dir}"
    exit 2
    ;;
esac
mv "${stage_dir}" "${shared_dir}"
trap - EXIT

print -r -- "${shared_dir}"
