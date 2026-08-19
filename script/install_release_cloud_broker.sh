#!/bin/zsh

set -euo pipefail

if [[ $# -ne 1 ]]; then
  print -u2 "usage: $0 RELEASE_ROOT"
  exit 2
fi

script_dir=${0:A:h}
project_root=${script_dir:h}
release_root=$1
if [[ "${release_root}" != /* || ! -d "${release_root}" ]]; then
  print -u2 "error: release root must be an absolute directory selector"
  exit 2
fi
label=fun.wwcn.rimeai.cloud-broker
domain="gui/${UID}"
template="${project_root}/macos/LaunchAgents/${label}.release.plist"
launch_agents_dir="${HOME}/Library/LaunchAgents"
target_plist="${launch_agents_dir}/${label}.plist"
runtime_dir="${HOME}/Library/Application Support/RimeAI/runtime"
control_dir="${HOME}/Library/Caches/RimeAI"
enabled_marker="${control_dir}/cloud-broker-enabled"
socket_path="${runtime_dir}/rimeai-cloud.sock"
log_path="${runtime_dir}/rimeai-cloud-broker.log"
executable="${release_root}/runtime/rimeai-cloud-broker/rimeai-cloud-broker"
staged_plist=$(mktemp "/tmp/${label}.release.XXXXXX")
backup_plist=$(mktemp "/tmp/${label}.previous.XXXXXX")
had_previous_plist=0
was_loaded=0
activation_changed=0

cleanup() {
  local task_exit_code=$?
  trap - EXIT
  if (( task_exit_code != 0 && activation_changed )); then
    launchctl bootout "${domain}/${label}" >/dev/null 2>&1 || true
    if (( had_previous_plist )); then
      install -m 600 "${backup_plist}" "${target_plist}"
      if (( was_loaded )); then
        launchctl bootstrap "${domain}" "${target_plist}" \
          >/dev/null 2>&1 || true
        if [[ -e "${enabled_marker}" ]]; then
          launchctl kickstart -k "${domain}/${label}" \
            >/dev/null 2>&1 || true
        fi
      fi
    elif [[ -f "${target_plist}" ]]; then
      unlink "${target_plist}"
    fi
    print -u2 "cloud broker activation rolled back"
  fi
  case "${staged_plist}" in
    /tmp/${label}.release.*)
      [[ ! -f "${staged_plist}" ]] || unlink "${staged_plist}"
      ;;
    *) print -u2 "error: refusing unexpected path: ${staged_plist}" ;;
  esac
  case "${backup_plist}" in
    /tmp/${label}.previous.*)
      [[ ! -f "${backup_plist}" ]] || unlink "${backup_plist}"
      ;;
    *) print -u2 "error: refusing unexpected path: ${backup_plist}" ;;
  esac
  exit "${task_exit_code}"
}
trap cleanup EXIT

for required in "${template}" "${executable}"; do
  if [[ ! -f "${required}" || -L "${required}" ]]; then
    print -u2 "error: cloud broker release input is missing: ${required}"
    exit 2
  fi
done
if [[ -L "${target_plist}" ]]; then
  print -u2 "error: refusing symlink cloud LaunchAgent target: ${target_plist}"
  exit 2
fi
mkdir -p "${launch_agents_dir}" "${runtime_dir}" "${control_dir}"
chmod 700 "${runtime_dir}" "${control_dir}"
touch "${log_path}"
chmod 600 "${log_path}"

cp "${template}" "${staged_plist}"
/usr/libexec/PlistBuddy -c \
  "Set :ProgramArguments:0 ${executable}" "${staged_plist}"
/usr/libexec/PlistBuddy -c \
  "Set :ProgramArguments:2 ${socket_path}" "${staged_plist}"
/usr/libexec/PlistBuddy -c \
  "Set :WorkingDirectory ${release_root}" "${staged_plist}"
/usr/libexec/PlistBuddy -c \
  "Set :StandardOutPath ${log_path}" "${staged_plist}"
/usr/libexec/PlistBuddy -c \
  "Set :StandardErrorPath ${log_path}" "${staged_plist}"
/usr/libexec/PlistBuddy -c \
  "Delete :KeepAlive:PathState:__ENABLED_MARKER__" "${staged_plist}"
/usr/libexec/PlistBuddy -c \
  "Add :KeepAlive:PathState:${enabled_marker} bool true" "${staged_plist}"
plutil -lint "${staged_plist}" >/dev/null

if launchctl print "${domain}/${label}" >/dev/null 2>&1; then
  was_loaded=1
fi
if [[ -f "${target_plist}" && ! -L "${target_plist}" ]]; then
  cp "${target_plist}" "${backup_plist}"
  had_previous_plist=1
fi
activation_changed=1
launchctl bootout "${domain}/${label}" >/dev/null 2>&1 || true
install -m 600 "${staged_plist}" "${target_plist}"
launchctl bootstrap "${domain}" "${target_plist}"

cloud_configured=0
if stored_cloud_configured=$(
  defaults read fun.wwcn.inputmethod.RimeAI RimeAICloudConfigured 2>/dev/null
); then
  [[ "${stored_cloud_configured}" != "1" ]] || cloud_configured=1
fi
if (( cloud_configured )); then
  touch "${enabled_marker}"
  chmod 600 "${enabled_marker}"
  launchctl kickstart -k "${domain}/${label}"
else
  rm -f -- "${enabled_marker}"
fi

activation_changed=0
print -r -- "cloud_launch_agent=${target_plist}"
