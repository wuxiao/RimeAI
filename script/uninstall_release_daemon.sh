#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
label=fun.wwcn.rimeai.daemon
support_root="${HOME}/Library/Application Support/RimeAI"
releases_root="${support_root}/releases/daemon"
target_plist="${HOME}/Library/LaunchAgents/${label}.plist"
timestamp=$(date +%Y%m%d-%H%M%S)
trashed_plist="${HOME}/.Trash/${label}.uninstalled-${timestamp}.plist"
trashed_releases="${HOME}/.Trash/RimeAI-daemon-releases-${timestamp}"

"${script_dir}/stop_daemon.sh" >/dev/null
if [[ -e "${target_plist}" ]]; then
  if [[ -e "${trashed_plist}" ]]; then
    print -u2 "error: Trash destination already exists: ${trashed_plist}"
    exit 2
  fi
  /bin/mv "${target_plist}" "${trashed_plist}"
  print -r -- "launch_agent_moved_to_trash=${trashed_plist}"
fi
if [[ -d "${releases_root}" && ! -L "${releases_root}" ]]; then
  if [[ -e "${trashed_releases}" ]]; then
    print -u2 "error: Trash destination already exists: ${trashed_releases}"
    exit 2
  fi
  /bin/mv "${releases_root}" "${trashed_releases}"
  print -r -- "releases_moved_to_trash=${trashed_releases}"
else
  print -r -- "release_runtime=not_installed"
fi
