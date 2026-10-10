#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
label=fun.wwcn.rimeai.cloud-broker
domain="gui/${UID}"
template="${project_root}/macos/LaunchAgents/${label}.plist"
launch_agents_dir="${HOME}/Library/LaunchAgents"
target_plist="${launch_agents_dir}/${label}.plist"
support_root="${HOME}/Library/Application Support/RimeAI"
broker_root="${support_root}/cloud-broker"
runtime_dir="${support_root}/runtime"
control_dir="${HOME}/Library/Caches/RimeAI"
enabled_marker="${control_dir}/cloud-broker-enabled"
socket_path="${runtime_dir}/rimeai-cloud.sock"
log_path="${runtime_dir}/rimeai-cloud-broker.log"
python_path=$(command -v python3)
staged_plist=$(mktemp "/tmp/${label}.XXXXXX.plist")

cleanup() {
  case "${staged_plist}" in
    /tmp/${label}.*.plist) rm -f -- "${staged_plist}" ;;
    *) print -u2 "error: refusing unexpected path: ${staged_plist}" ;;
  esac
}
trap cleanup EXIT

if [[ ! -f "${template}" ]]; then
  print -u2 "error: cloud broker LaunchAgent template is missing"
  exit 2
fi
source_rime_dictionary="${project_root}/.rimeai/rime/shared/luna_pinyin.dict.yaml"
if [[ ! -f "${source_rime_dictionary}" ]]; then
  print -u2 "error: Rime dictionary is missing for cloud broker install"
  exit 2
fi
if ! PYTHONPATH="${project_root}" "${python_path}" -c \
  'from rimeai_cloud_broker import CloudBrokerServer, QwenCandidateRanker' \
  >/dev/null 2>&1; then
  print -u2 "error: cloud broker source is incompatible with ${python_path}"
  exit 2
fi

mkdir -p \
  "${launch_agents_dir}" \
  "${broker_root}" \
  "${runtime_dir}" \
  "${control_dir}"
chmod 700 "${broker_root}" "${runtime_dir}" "${control_dir}"
touch "${log_path}"
chmod 600 "${log_path}"
rsync -a --delete --exclude='._*' --exclude='__pycache__' \
  "${project_root}/rimeai_cloud_broker/" \
  "${broker_root}/rimeai_cloud_broker/"
# The broker validates generated sentences against the Rime dictionary;
# ship the guard module and the dictionary beside the broker so the
# LaunchAgent runtime never depends on the repository checkout.
mkdir -p "${broker_root}/rimeai_eval"
rsync -a --delete --exclude='._*' --exclude='__pycache__' \
  "${project_root}/rimeai_eval/__init__.py" \
  "${project_root}/rimeai_eval/pinyin_guard.py" \
  "${broker_root}/rimeai_eval/"
rime_dictionary="${broker_root}/luna_pinyin.dict.yaml"
install -m 600 "${source_rime_dictionary}" "${rime_dictionary}"

cp "${template}" "${staged_plist}"
/usr/libexec/PlistBuddy -c \
  "Set :ProgramArguments:0 ${python_path}" "${staged_plist}"
/usr/libexec/PlistBuddy -c \
  "Set :ProgramArguments:4 ${socket_path}" "${staged_plist}"
/usr/libexec/PlistBuddy -c \
  "Set :ProgramArguments:6 ${rime_dictionary}" "${staged_plist}"
/usr/libexec/PlistBuddy -c \
  "Set :WorkingDirectory ${broker_root}" "${staged_plist}"
/usr/libexec/PlistBuddy -c \
  "Set :StandardOutPath ${log_path}" "${staged_plist}"
/usr/libexec/PlistBuddy -c \
  "Set :StandardErrorPath ${log_path}" "${staged_plist}"
/usr/libexec/PlistBuddy -c \
  "Set :EnvironmentVariables:PYTHONPATH ${broker_root}" "${staged_plist}"
/usr/libexec/PlistBuddy -c \
  "Delete :KeepAlive:PathState:__ENABLED_MARKER__" "${staged_plist}"
/usr/libexec/PlistBuddy -c \
  "Add :KeepAlive:PathState:${enabled_marker} bool true" "${staged_plist}"
plutil -lint "${staged_plist}" >/dev/null

launchctl bootout "${domain}/${label}" >/dev/null 2>&1 || true
install -m 600 "${staged_plist}" "${target_plist}"
if ! launchctl bootstrap "${domain}" "${target_plist}"; then
  print -u2 "warning: cloud broker bootstrap failed; retrying once"
  sleep 0.5
  launchctl bootstrap "${domain}" "${target_plist}"
fi

cloud_configured=0
if stored_cloud_configured=$(
  defaults read fun.wwcn.inputmethod.RimeAI RimeAICloudConfigured 2>/dev/null
); then
  if [[ "${stored_cloud_configured}" == "1" ]]; then
    cloud_configured=1
  fi
fi
if (( cloud_configured )); then
  touch "${enabled_marker}"
  chmod 600 "${enabled_marker}"
  launchctl kickstart -k "${domain}/${label}"
else
  rm -f -- "${enabled_marker}"
fi

print -r -- "launch_agent=${target_plist}"
print -r -- "cloud_broker_state=$([[ ${cloud_configured} == 1 ]] && print enabled || print disabled)"
