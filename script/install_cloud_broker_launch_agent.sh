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
if ! PYTHONPATH="${project_root}" "${python_path}" -c \
  'from rimeai_cloud_broker import CloudBrokerServer, CloudModelClient; from rimeai_daemon.consolidation import ConsolidationPipeline; from rimeai_daemon.llm_backfill import SignaturePhraseBackfiller' \
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
# The broker serves clients over the local IPC socket; ship the IPC module
# beside the broker so the LaunchAgent runtime never depends on the
# repository checkout.
mkdir -p "${broker_root}/rimeai_runtime"
rsync -a --delete --exclude='._*' --exclude='__pycache__' \
  "${project_root}/rimeai_runtime/__init__.py" \
  "${project_root}/rimeai_runtime/localipc.py" \
  "${broker_root}/rimeai_runtime/"
# __main__.py imports rimeai_daemon.consolidation for idle history
# consolidation, rimeai_daemon.llm_backfill for signature-phrase
# backfill (LM-003), and both servers share rimeai_daemon.segment_policy
# for pinyin-segment validation; ship the modules they need the same way.
mkdir -p "${broker_root}/rimeai_daemon"
rsync -a --delete --exclude='._*' --exclude='__pycache__' \
  "${project_root}/rimeai_daemon/__init__.py" \
  "${project_root}/rimeai_daemon/consolidation.py" \
  "${project_root}/rimeai_daemon/llm_backfill.py" \
  "${project_root}/rimeai_daemon/segment_policy.py" \
  "${project_root}/rimeai_daemon/user_lm.py" \
  "${broker_root}/rimeai_daemon/"
# Fail fast if the staged snapshot cannot import the full module chain the
# LaunchAgent will run (this exact gap once crash-looped the broker).
if ! PYTHONPATH="${broker_root}" "${python_path}" -c \
  'from rimeai_cloud_broker import CloudBrokerServer; from rimeai_daemon.consolidation import ConsolidationPipeline; from rimeai_daemon.llm_backfill import SignaturePhraseBackfiller' \
  >/dev/null 2>&1; then
  print -u2 "error: staged cloud broker snapshot failed its import smoke test"
  exit 2
fi

cp "${template}" "${staged_plist}"
/usr/libexec/PlistBuddy -c \
  "Set :ProgramArguments:0 ${python_path}" "${staged_plist}"
/usr/libexec/PlistBuddy -c \
  "Set :ProgramArguments:4 ${socket_path}" "${staged_plist}"
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
# bootout 是异步的：等旧任务真正离域后再 bootstrap，否则会撞
# "Bootstrap failed: 5: Input/output error"（同 install_daemon_launch_agent.sh
# 2026-10-23 的修复）。
wait_attempt=0
while (( wait_attempt < 50 )); do
  if ! launchctl print "${domain}/${label}" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
  wait_attempt=$((wait_attempt + 1))
done
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
