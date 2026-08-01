#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
label=fun.wwcn.rimeai.daemon
target_plist="${HOME}/Library/LaunchAgents/${label}.plist"
timestamp=$(date +%Y%m%d-%H%M%S)
trashed_plist="${HOME}/.Trash/${label}.uninstalled-${timestamp}.plist"

"${script_dir}/stop_daemon.sh" >/dev/null

if [[ -e "${target_plist}" ]]; then
  if [[ -e "${trashed_plist}" ]]; then
    print -u2 "error: Trash destination already exists: ${trashed_plist}"
    exit 2
  fi
  mv "${target_plist}" "${trashed_plist}"
  print -r -- "launch_agent_moved_to_trash=${trashed_plist}"
else
  print -r -- "LaunchAgent was not installed."
fi
