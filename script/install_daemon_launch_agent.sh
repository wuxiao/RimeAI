#!/bin/zsh
# shellcheck disable=SC1071

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
source_language_model="${project_root}/.rimeai/models/p0-char-ngram-v2.json.gz"
source_beam_config="${project_root}/.rimeai/models/p0-beam-sentence-v3.json"
source_rime_dictionary="${project_root}/.rimeai/rime/shared/luna_pinyin.dict.yaml"
source_neural_model="${project_root}/.rimeai/models/rimeai-ranker-s-24m-v1"
source_fusion_config="${project_root}/.rimeai/models/rimeai-ranker-s-24m-fusion-v2.json"
language_model="${model_bundle_dir}/p0-char-ngram-v2.json.gz"
beam_config="${model_bundle_dir}/p0-beam-sentence-v3.json"
rime_dictionary="${model_bundle_dir}/luna_pinyin.dict.yaml"
neural_model="${model_bundle_dir}/rimeai-ranker-s-24m-v1"
fusion_config="${model_bundle_dir}/rimeai-ranker-s-24m-fusion-v2.json"
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
  "${source_rime_dictionary}" \
  "${source_neural_model}/manifest.json" \
  "${source_fusion_config}"; do
  if [[ ! -f "${artifact}" ]]; then
    print -u2 "error: required daemon artifact is missing: ${artifact}"
    exit 2
  fi
done

expected_artifact_id=$(
  /usr/bin/python3 - "${source_fusion_config}" "${source_beam_config}" <<'PY'
import hashlib
import json
import sys
with open(sys.argv[1], encoding="utf-8") as file:
    ranker_id = json.load(file)["artifact_id"]
with open(sys.argv[2], "rb") as file:
    beam_sha256 = hashlib.sha256(file.read()).hexdigest()
print(f"{ranker_id}:beam-{beam_sha256[:12]}")
PY
)

if ! PYTHONPATH="${project_root}" "${python_path}" -c \
  'import torch, transformers, safetensors; from rimeai_daemon.engine import LocalInferenceEngine' \
  >/dev/null 2>&1; then
  print -u2 \
    "error: daemon source is incompatible with ${python_path}; installation was not changed"
  exit 2
fi

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
rsync -a --delete \
  --exclude='._*' \
  --exclude='__pycache__' \
  "${project_root}/rimeai_runtime/" \
  "${daemon_bundle_dir}/rimeai_runtime/"
install -m 600 "${source_language_model}" "${language_model}"
install -m 600 "${source_beam_config}" "${beam_config}"
install -m 600 "${source_rime_dictionary}" "${rime_dictionary}"
rsync -a --delete --exclude='._*' \
  "${source_neural_model}/" "${neural_model}/"
install -m 600 "${source_fusion_config}" "${fusion_config}"

# Neural sentence arm: stage the decoder config with an absolute worker
# command (the bundled daemon cannot resolve repo-relative paths).
neural_sentence_config="${daemon_bundle_dir}/neural_sentence.json"
if ! /usr/bin/python3 - "${project_root}" "${neural_sentence_config}" <<'PY'
import json
import sys
from pathlib import Path

project_root = Path(sys.argv[1]).resolve()
config = json.loads(
    (project_root / "examples/constrained_mlx_decoder.json").read_text(
        encoding="utf-8"
    )
)
service = project_root / "script/constrained_mlx_service.sh"
if not service.is_file():
    raise SystemExit(
        f"missing neural sentence worker: {service}"
    )
config["command"] = [str(service)]
# The eval decoder config allows a 60s batch read timeout; the
# interactive daemon must not inherit it — a wedged worker would
# hold the single neural executor thread (and process teardown) for
# up to a minute (reveal B-F5/C-F2 amplification). Cap it for
# interactive deployment; eval keeps its own config untouched.
config["timeout_ms"] = min(
    int(config.get("timeout_ms", 10000)), 5000
)
Path(sys.argv[2]).write_text(
    json.dumps(config, ensure_ascii=False, indent=2) + "\n",
    encoding="utf-8",
)
PY
then
  print -u2 "error: cannot stage the neural sentence config"
  exit 2
fi
chmod 600 "${neural_sentence_config}"

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
  "Set :ProgramArguments:12 ${neural_model}" "${staged_plist}"
/usr/libexec/PlistBuddy -c \
  "Set :ProgramArguments:14 ${fusion_config}" "${staged_plist}"
/usr/libexec/PlistBuddy -c \
  "Set :ProgramArguments:18 ${neural_sentence_config}" "${staged_plist}"
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

bootstrap_succeeded=0
for _ in {1..20}; do
  if launchctl bootstrap "${domain}" "${target_plist}" 2>/dev/null; then
    bootstrap_succeeded=1
    break
  fi
  # 服务已在域内（上一代 load/bootstrap 残留）时 bootstrap 报 I/O
  # error：bootout 后 launchd 异步卸载，必须轮询等真正离开域才能
  # 重新 bootstrap（盲重试必然连续失败）。
  launchctl bootout "${domain}/${label}" 2>/dev/null || true
  for _ in {1..25}; do
    if ! launchctl print "${domain}/${label}" >/dev/null 2>&1; then
      break
    fi
    sleep 0.2
  done
  sleep 0.3
done
if (( ! bootstrap_succeeded )); then
  print -u2 "error: could not bootstrap ${label} after launchd retry window"
  exit 1
fi
if (( ! ai_enabled )); then
  print -r -- "launch_agent=${target_plist}"
  print -r -- "daemon_state=disabled_by_saved_preference"
  exit 0
fi

launchctl kickstart -k "${domain}/${label}"

for _ in {1..50}; do
  if [[ -S "${socket_path}" ]] \
    && python3 - "${socket_path}" "${expected_artifact_id}" <<'PY' >/dev/null 2>&1
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
    if "decision-reasons" not in response.get("capabilities", []):
        raise OSError("structured decision capability is missing")
    if "long-input-reasons" not in response.get("capabilities", []):
        raise OSError("long-input decision capability is missing")
    if response.get("model_artifact_id") != sys.argv[2]:
        raise OSError("daemon is serving a stale model artifact")
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
