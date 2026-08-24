#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
output_dir=${1:-"${project_root}/python-dist"}

if [[ ${output_dir} != /* ]]; then
  output_dir="${PWD}/${output_dir}"
fi

if ! command -v uv >/dev/null 2>&1; then
  print -u2 "error: uv is required to build the Python package"
  exit 2
fi

stage_dir=$(mktemp -d /tmp/rimeai-python-build.XXXXXX)

cleanup() {
  case ${stage_dir} in
    /tmp/rimeai-python-build.*)
      command rm -rf -- "${stage_dir}"
      ;;
    *)
      print -u2 "error: refusing to clean unexpected staging path: ${stage_dir}"
      return 1
      ;;
  esac
}
trap cleanup EXIT

mkdir -p \
  "${stage_dir}/rimeai_eval" \
  "${stage_dir}/rimeai_daemon" \
  "${stage_dir}/tests" \
  "${output_dir}"

rsync -a \
  --exclude='._*' \
  --exclude='__pycache__' \
  "${project_root}/rimeai_eval/" \
  "${stage_dir}/rimeai_eval/"

rsync -a \
  --exclude='._*' \
  --exclude='__pycache__' \
  "${project_root}/rimeai_daemon/" \
  "${stage_dir}/rimeai_daemon/"

rsync -a \
  --exclude='._*' \
  --exclude='__pycache__' \
  "${project_root}/tests/" \
  "${stage_dir}/tests/"

rsync -a \
  "${project_root}/MANIFEST.in" \
  "${project_root}/README.md" \
  "${project_root}/pyproject.toml" \
  "${stage_dir}/"

uv build --project "${stage_dir}" --out-dir "${output_dir}"
