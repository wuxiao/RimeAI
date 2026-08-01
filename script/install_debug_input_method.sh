#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
app_name=RimeAIInputMethod
source_app="${HOME}/Library/Developer/Xcode/DerivedData/RimeAI-Codex/Build/Products/Debug/${app_name}.app"
input_methods_dir="${HOME}/Library/Input Methods"
target_app="${input_methods_dir}/${app_name}.app"
timestamp=$(date +%Y%m%d-%H%M%S)
backup_app="${HOME}/.Trash/${app_name}.previous-${timestamp}.app"

"${project_root}/script/build_and_run.sh" --build-only >/dev/null
codesign --verify --deep --strict "${source_app}"
mkdir -p "${input_methods_dir}"

pkill -x "${app_name}" >/dev/null 2>&1 || true
if [[ -e "${target_app}" ]]; then
  if [[ -e "${backup_app}" ]]; then
    print -u2 "error: backup destination already exists: ${backup_app}"
    exit 2
  fi
  mv "${target_app}" "${backup_app}"
  print -r -- "previous_bundle=${backup_app}"
fi

ditto "${source_app}" "${target_app}"
codesign --verify --deep --strict "${target_app}"
"${project_root}/script/install_daemon_launch_agent.sh"
# Do not launch the bundle during installation. Starting an input-method server
# is itself an activation signal to Text Input Sources and creates an enabled
# container before the user clicks Add in Keyboard Settings.
expected_input_source_id=fun.wwcn.inputmethod.RimeAI
installed_plist="${target_app}/Contents/Info.plist"
container_input_source_id=$(plutil -extract TISInputSourceID raw -o - \
  "${installed_plist}")
visible_input_mode_id=$(plutil -extract \
  ComponentInputModeDict.tsVisibleInputModeOrderedArrayKey.0 raw -o - \
  "${installed_plist}")
if [[ "${container_input_source_id}" != "${expected_input_source_id}" || \
      "${visible_input_mode_id}" != "${expected_input_source_id}.Primary" ]]; then
  print -u2 "error: installed input source identifiers are inconsistent"
  exit 1
fi

print -r -- "installed=${target_app}"
print -r -- "input_source_id=${expected_input_source_id}"
