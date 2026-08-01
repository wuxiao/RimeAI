#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
label=fun.wwcn.rimeai.daemon
domain="gui/${UID}"
template="${project_root}/macos/LaunchAgents/${label}.plist"
launch_agents_dir="${HOME}/Library/LaunchAgents"
target_plist="${launch_agents_dir}/${label}.plist"
support_root="${HOME}/Library/Application Support/RimeAI"
daemon_bundle_dir="${support_root}/daemon"
model_bundle_dir="${support_root}/models"
runtime_dir="${support_root}/runtime"
control_dir="${HOME}/Library/Caches/RimeAI"
enabled_marker="${control_dir}/daemon-enabled"
socket_path="${runtime_dir}/rimeai.sock"
log_path="${runtime_dir}/rimeai-daemon.log"
source_language_model="${project_root}/.rimeai/models/p0-char-ngram-v1.json.gz"
source_beam_config="${project_root}/.rimeai/models/p0-beam-sentence-v1.json"
source_rime_dictionary="${project_root}/.rimeai/rime/shared/luna_pinyin.dict.yaml"
language_model="${model_bundle_dir}/p0-char-ngram-v1.json.gz"
beam_config="${model_bundle_dir}/p0-beam-sentence-v1.json"
rime_dictionary="${model_bundle_dir}/luna_pinyin.dict.yaml"
python_path=$(command -v python3)
timestamp=$(date +%Y%m%d-%H%M%S)
backup_plist="${HOME}/.Trash/${label}.previous-${timestamp}.plist"
staged_plist=$(mktemp "/tmp/${label}.XXXXXX.plist")
ai_enabled=1

if stored_ai_enabled=$(
  defaults read fun.wwcn.inputmethod.RimeAI RimeAIEnabled 2>/dev/null
); then
  if [[ "${stored_ai_enabled}" == "0" ]]; then
    ai_enabled=0
  fi
fi

cleanup() {
  case "${staged_plist}" in
    /tmp/${label}.*.plist)
      rm -f -- "${staged_plist}"
      ;;
    *)
      print -u2 "error: refusing to clean unexpected path: ${staged_plist}"
      return 1
      ;;
  esac
}
trap cleanup EXIT

for artifact in \
  "${template}" \
  "${source_language_model}" \
  "${source_beam_config}" \
  "${source_rime_dictionary}"; do
  if [[ ! -f "${artifact}" ]]; then
    print -u2 "error: required daemon artifact is missing: ${artifact}"
    exit 2
  fi
done

mkdir -p \
  "${launch_agents_dir}" \
  "${daemon_bundle_dir}" \
  "${model_bundle_dir}" \
  "${runtime_dir}" \
  "${control_dir}"
chmod 700 "${runtime_dir}" "${control_dir}"
touch "${log_path}"
chmod 600 "${log_path}"

"${script_dir}/stop_daemon.sh" >/dev/null
truncate -s 0 "${log_path}"
if (( ai_enabled )); then
  touch "${enabled_marker}"
  chmod 600 "${enabled_marker}"
else
  rm -f -- "${enabled_marker}"
fi

rsync -a \
  --exclude='._*' \
  --exclude='__pycache__' \
  "${project_root}/rimeai_daemon/" \
  "${daemon_bundle_dir}/rimeai_daemon/"
rsync -a \
  --exclude='._*' \
  --exclude='__pycache__' \
  "${project_root}/rimeai_eval/" \
  "${daemon_bundle_dir}/rimeai_eval/"
install -m 600 "${source_language_model}" "${language_model}"
install -m 600 "${source_beam_config}" "${beam_config}"
install -m 600 "${source_rime_dictionary}" "${rime_dictionary}"

cp "${template}" "${staged_plist}"
/usr/libexec/PlistBuddy -c \
  "Set :ProgramArguments:0 ${python_path}" "${staged_plist}"
/usr/libexec/PlistBuddy -c \
  "Set :ProgramArguments:4 ${socket_path}" "${staged_plist}"
/usr/libexec/PlistBuddy -c \
  "Set :ProgramArguments:6 ${language_model}" "${staged_plist}"
/usr/libexec/PlistBuddy -c \
  "Set :ProgramArguments:8 ${beam_config}" "${staged_plist}"
/usr/libexec/PlistBuddy -c \
  "Set :ProgramArguments:10 ${rime_dictionary}" "${staged_plist}"
/usr/libexec/PlistBuddy -c \
  "Set :WorkingDirectory ${daemon_bundle_dir}" "${staged_plist}"
/usr/libexec/PlistBuddy -c \
  "Set :StandardOutPath ${log_path}" "${staged_plist}"
/usr/libexec/PlistBuddy -c \
  "Set :StandardErrorPath ${log_path}" "${staged_plist}"
/usr/libexec/PlistBuddy -c \
  "Set :EnvironmentVariables:PYTHONPATH ${daemon_bundle_dir}" \
  "${staged_plist}"
/usr/libexec/PlistBuddy -c \
  "Delete :KeepAlive:PathState:__ENABLED_MARKER__" "${staged_plist}"
/usr/libexec/PlistBuddy -c \
  "Add :KeepAlive:PathState:${enabled_marker} bool true" "${staged_plist}"
plutil -lint "${staged_plist}" >/dev/null

if [[ -e "${target_plist}" ]]; then
  if [[ -e "${backup_plist}" ]]; then
    print -u2 "error: Trash destination already exists: ${backup_plist}"
    exit 2
  fi
  mv "${target_plist}" "${backup_plist}"
  print -r -- "previous_launch_agent=${backup_plist}"
fi
install -m 600 "${staged_plist}" "${target_plist}"

launchctl bootstrap "${domain}" "${target_plist}"
if (( ! ai_enabled )); then
  print -r -- "launch_agent=${target_plist}"
  print -r -- "daemon_state=disabled_by_saved_preference"
  exit 0
fi

launchctl kickstart -k "${domain}/${label}"

for _ in {1..50}; do
  if [[ -S "${socket_path}" ]] \
    && python3 - "${socket_path}" <<'PY' >/dev/null 2>&1
import json
import socket
import sys

probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
probe.settimeout(0.5)
try:
    probe.connect(sys.argv[1])
    probe.sendall(
        (
            json.dumps(
                {
                    "schema_version": 1,
                    "type": "hello",
                    "client_id": "rimeai-launch-agent-probe",
                    "capabilities": [],
                },
                separators=(",", ":"),
            )
            + "\n"
        ).encode("utf-8")
    )
    response = json.loads(probe.recv(65_536))
    if response.get("status") != "ok":
        raise OSError("daemon is not ready")
    if response.get("offline_lock") is not True:
        raise OSError("offline lock is not active")
finally:
    probe.close()
PY
  then
    print -r -- "launch_agent=${target_plist}"
    print -r -- "socket=${socket_path}"
    exit 0
  fi
  sleep 0.1
done

print -u2 "error: LaunchAgent daemon did not become ready"
tail -n 30 "${log_path}" >&2 || true
exit 1
