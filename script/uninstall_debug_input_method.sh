#!/bin/zsh

set -euo pipefail

mode=${1:-preserve-data}
app_name=RimeAIInputMethod
bundle_id=fun.wwcn.inputmethod.RimeAI
script_dir=${0:A:h}
project_root=${script_dir:h}
target_app="${HOME}/Library/Input Methods/${app_name}.app"
support_dir="${HOME}/Library/Application Support/RimeAI"
control_dir="${HOME}/Library/Caches/RimeAI"
timestamp=$(date +%Y%m%d-%H%M%S)
trashed_app="${HOME}/.Trash/${app_name}.uninstalled-${timestamp}.app"
trashed_artifacts="${HOME}/.Trash/RimeAI-managed-artifacts-${timestamp}"
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

case "${mode}" in
  preserve-data|--preserve-data)
    ;;
  --trash-rimeai-data)
    ;;
  *)
    print -u2 "usage: $0 [--preserve-data|--trash-rimeai-data]"
    exit 2
    ;;
esac

"${script_dir}/uninstall_daemon_launch_agent.sh"

if [[ -e "${target_app}" ]]; then
  if [[ -e "${trashed_app}" ]]; then
    print -u2 "error: Trash destination already exists: ${trashed_app}"
    exit 2
  fi

  pkill -x "${app_name}" >/dev/null 2>&1 || true
  "${lsregister}" -u "${target_app}" >/dev/null 2>&1 || true
  mv "${target_app}" "${trashed_app}"
  xcrun swift "${project_root}/macos/tools/disable_input_sources.swift" \
    "${bundle_id}"
  print -r -- "moved_to_trash=${trashed_app}"
else
  print -r -- "RimeAI debug input method is not installed."
fi

if [[ "${mode}" == "--trash-rimeai-data" ]]; then
  managed_artifacts=(
    "${support_dir}/daemon"
    "${support_dir}/models"
    "${support_dir}/runtime"
    "${control_dir}"
  )
  artifacts_found=0
  for artifact in "${managed_artifacts[@]}"; do
    if [[ -e "${artifact}" ]]; then
      artifacts_found=1
      break
    fi
  done

  if (( artifacts_found )); then
    if [[ -e "${trashed_artifacts}" ]]; then
      print -u2 \
        "error: Trash destination already exists: ${trashed_artifacts}"
      exit 2
    fi
    mkdir -m 700 "${trashed_artifacts}"
    for artifact in "${managed_artifacts[@]}"; do
      if [[ -e "${artifact}" ]]; then
        mv "${artifact}" "${trashed_artifacts}/${artifact:t}"
      fi
    done
    print -r -- "ai_artifacts_moved_to_trash=${trashed_artifacts}"
  else
    print -r -- "No managed AI artifacts were present."
  fi
  if [[ -e "${support_dir}/Rime" ]]; then
    print -r -- "Rime user data was preserved at ${support_dir}/Rime."
  else
    print -r -- "No Rime user data directory was present."
  fi
else
  print -r -- "Rime user data and RimeAI settings were preserved."
fi
