#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
label=fun.wwcn.rimeai.daemon
cloud_label=fun.wwcn.rimeai.cloud-broker
domain="gui/${UID}"
support_root="${HOME}/Library/Application Support/RimeAI"
releases_root="${support_root}/releases/daemon"
target_plist="${HOME}/Library/LaunchAgents/${label}.plist"
timestamp=$(date +%Y%m%d-%H%M%S)
trashed_plist="${HOME}/.Trash/${label}.uninstalled-${timestamp}.plist"
cloud_plist="${HOME}/Library/LaunchAgents/${cloud_label}.plist"
trashed_cloud_plist="${HOME}/.Trash/${cloud_label}.uninstalled-${timestamp}.plist"
trashed_releases="${HOME}/.Trash/RimeAI-daemon-releases-${timestamp}"

"${script_dir}/stop_daemon.sh" >/dev/null
launchctl bootout "${domain}/${cloud_label}" >/dev/null 2>&1 || true
rm -f -- "${HOME}/Library/Caches/RimeAI/cloud-broker-enabled"
if [[ -e "${target_plist}" ]]; then
  if [[ -e "${trashed_plist}" ]]; then
    print -u2 "error: Trash destination already exists: ${trashed_plist}"
    exit 2
  fi
  /bin/mv "${target_plist}" "${trashed_plist}"
  print -r -- "launch_agent_moved_to_trash=${trashed_plist}"
fi
if [[ -e "${cloud_plist}" ]]; then
  if [[ -e "${trashed_cloud_plist}" ]]; then
    print -u2 "error: Trash destination already exists: ${trashed_cloud_plist}"
    exit 2
  fi
  /bin/mv "${cloud_plist}" "${trashed_cloud_plist}"
  print -r -- "cloud_launch_agent_moved_to_trash=${trashed_cloud_plist}"
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
