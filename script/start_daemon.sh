#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
runtime_dir="${HOME}/Library/Application Support/RimeAI/runtime"
socket_path="${runtime_dir}/rimeai.sock"
pid_path="${runtime_dir}/rimeai-daemon.pid"
log_path="${runtime_dir}/rimeai-daemon.log"
language_model="${project_root}/.rimeai/models/p0-char-ngram-v2.json.gz"
beam_config="${project_root}/.rimeai/models/p0-beam-sentence-v3.json"
rime_dictionary="${project_root}/.rimeai/rime/shared/luna_pinyin.dict.yaml"
neural_model="${project_root}/.rimeai/models/rimeai-ranker-s-24m-v1"
fusion_config="${project_root}/.rimeai/models/rimeai-ranker-s-24m-fusion-v2.json"

for artifact in \
  "${language_model}" \
  "${beam_config}" \
  "${rime_dictionary}" \
  "${neural_model}/manifest.json" \
  "${fusion_config}"; do
  if [[ ! -f "${artifact}" ]]; then
    print -u2 "error: required local artifact is missing: ${artifact}"
    exit 2
  fi
done

expected_artifact_id=$(
  /usr/bin/python3 - "${fusion_config}" "${beam_config}" <<'PY'
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

mkdir -p "${runtime_dir}"
chmod 700 "${runtime_dir}"

socket_is_live() {
  python3 - "${socket_path}" "${expected_artifact_id}" <<'PY'
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
                    "client_id": "rimeai-startup-probe",
                    "capabilities": [],
                },
                separators=(",", ":"),
            )
            + "\n"
        ).encode("utf-8")
    )
    response = json.loads(probe.recv(4096))
    if response.get("status") != "ok":
        raise OSError("incompatible daemon response")
    if response.get("offline_lock") is not True:
        raise OSError("offline lock is not active")
    if "offline-lock" not in response.get("capabilities", []):
        raise OSError("offline lock capability is missing")
    if "decision-reasons" not in response.get("capabilities", []):
        raise OSError("structured decision capability is missing")
    if "long-input-reasons" not in response.get("capabilities", []):
        raise OSError("long-input decision capability is missing")
    if response.get("model_artifact_id") != sys.argv[2]:
        raise OSError("daemon is serving a stale model artifact")
except OSError:
    raise SystemExit(1)
finally:
    probe.close()
PY
}

if [[ -S "${socket_path}" ]] && socket_is_live; then
  print -r -- "${socket_path}"
  exit 0
fi

if [[ -f "${pid_path}" ]]; then
  previous_pid=$(<"${pid_path}")
  if [[ "${previous_pid}" == <-> ]] && kill -0 "${previous_pid}" 2>/dev/null; then
    previous_command=$(ps -p "${previous_pid}" -o command= 2>/dev/null || true)
    if [[ "${previous_command}" == *"rimeai_daemon"* ]]; then
      kill -TERM "${previous_pid}"
    fi
  fi
  rm -f -- "${pid_path}"
fi

cd "${project_root}"
nohup python3 -m rimeai_daemon \
  --socket "${socket_path}" \
  --language-model "${language_model}" \
  --beam-config "${beam_config}" \
  --rime-dictionary "${rime_dictionary}" \
  --neural-model "${neural_model}" \
  --fusion-config "${fusion_config}" \
  --neural-device cpu \
  >"${log_path}" 2>&1 &
daemon_pid=$!
print -r -- "${daemon_pid}" >"${pid_path}"
chmod 600 "${pid_path}" "${log_path}"

for _ in {1..50}; do
  if [[ -S "${socket_path}" ]] && socket_is_live; then
    print -r -- "${socket_path}"
    exit 0
  fi
  sleep 0.1
done

print -u2 "error: RimeAI daemon did not become ready"
tail -n 20 "${log_path}" >&2 || true
exit 1
