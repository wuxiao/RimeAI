#!/bin/zsh

set -euo pipefail

label=fun.wwcn.rimeai.daemon
domain="gui/${UID}"
runtime_dir="${HOME}/Library/Application Support/RimeAI/runtime"
socket_path="${runtime_dir}/rimeai.sock"
pid_path="${runtime_dir}/rimeai-daemon.pid"

if launchctl print "${domain}/${label}" >/dev/null 2>&1; then
  launchctl bootout "${domain}/${label}"
fi

if [[ -f "${pid_path}" ]]; then
  daemon_pid=$(tr -d '[:space:]' <"${pid_path}")
  if [[ "${daemon_pid}" == <-> ]] \
    && kill -0 "${daemon_pid}" 2>/dev/null; then
    daemon_command=$(ps -p "${daemon_pid}" -o command= 2>/dev/null || true)
    if [[ ( "${daemon_command}" == *"rimeai_daemon"* \
      || "${daemon_command}" == *"rimeai-daemon"* ) ]] \
      && [[ "${daemon_command}" == *"${socket_path}"* ]]; then
      kill -TERM "${daemon_pid}"
      for _ in {1..30}; do
        if ! kill -0 "${daemon_pid}" 2>/dev/null; then
          break
        fi
        sleep 0.1
      done
    else
      print -u2 "error: refusing to stop unrelated pid ${daemon_pid}"
      exit 2
    fi
  fi
  rm -f -- "${pid_path}"
fi

if [[ -S "${socket_path}" ]]; then
  rm -f -- "${socket_path}"
fi

print -r -- "daemon_stopped=${label}"
