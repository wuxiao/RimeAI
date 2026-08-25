#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}

if [[ $# -ne 1 ]]; then
  print -u2 "usage: $0 OUTPUT.jsonl"
  exit 2
fi

cd "${project_root}"
exec /usr/bin/python3 tools/collect_keyboard_evaluation.py --output "$1"
