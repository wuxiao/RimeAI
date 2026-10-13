#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
label=fun.wwcn.rimeai.daemon
domain="gui/${UID}"
support_root="${HOME}/Library/Application Support/RimeAI"
releases_root="${support_root}/releases/daemon"
current_link="${releases_root}/current"
previous_link="${releases_root}/previous"
target_plist="${HOME}/Library/LaunchAgents/${label}.plist"
socket_file="${support_root}/runtime/rimeai.sock"
enabled_marker="${HOME}/Library/Caches/RimeAI/daemon-enabled"
cloud_label=fun.wwcn.rimeai.cloud-broker
cloud_enabled_marker="${HOME}/Library/Caches/RimeAI/cloud-broker-enabled"

for selector in "${current_link}" "${previous_link}"; do
  if [[ ! -L "${selector}" ]]; then
    print -u2 "error: rollback selector is missing: ${selector}"
    exit 2
  fi
done
current_name=$(readlink "${current_link}")
previous_name=$(readlink "${previous_link}")
for release_name in "${current_name}" "${previous_name}"; do
  if [[ -z "${release_name}" || "${release_name}" == /* \
    || "${release_name}" == */* \
    || ! -d "${releases_root}/${release_name}" ]]; then
    print -u2 "error: invalid rollback release selector"
    exit 2
  fi
  "${project_root}/scripts/verify_daemon_release.sh" \
    "${releases_root}/${release_name}" >/dev/null
done
if [[ ! -f "${target_plist}" ]]; then
  print -u2 "error: release LaunchAgent is not installed"
  exit 2
fi

swap_selectors() {
  local new_current=$1
  local new_previous=$2
  local current_temporary="${releases_root}/.current.${$}.new"
  local previous_temporary="${releases_root}/.previous.${$}.new"
  ln -s "${new_current}" "${current_temporary}"
  ln -s "${new_previous}" "${previous_temporary}"
  /bin/mv -fh "${previous_temporary}" "${previous_link}"
  /bin/mv -fh "${current_temporary}" "${current_link}"
}

bootstrap_agent() {
  for _ in {1..20}; do
    if launchctl bootstrap "${domain}" "${target_plist}" 2>/dev/null; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

"${script_dir}/stop_daemon.sh" >/dev/null
swap_selectors "${previous_name}" "${current_name}"
if [[ -e "${cloud_enabled_marker}" ]]; then
  launchctl kickstart -k "${domain}/${cloud_label}" >/dev/null 2>&1 || true
fi
if ! bootstrap_agent; then
  swap_selectors "${current_name}" "${previous_name}"
  bootstrap_agent >/dev/null 2>&1 || true
  if [[ -e "${enabled_marker}" ]]; then
    launchctl kickstart -k "${domain}/${label}" >/dev/null 2>&1 || true
  fi
  print -u2 "error: rollback LaunchAgent bootstrap failed; selectors restored"
  exit 1
fi
if [[ ! -e "${enabled_marker}" ]]; then
  print -r -- "release=${releases_root}/${previous_name}"
  print -r -- "daemon_state=disabled_by_saved_preference"
  exit 0
fi
launchctl kickstart -k "${domain}/${label}"

release_root="${releases_root}/${previous_name}"
daemon_executable="${current_link}/runtime/rimeai-daemon/rimeai-daemon"
fusion_id=$(plutil -extract artifact_id raw -o - \
  "${release_root}/models/rimeai-ranker-s-24m-fusion-v1.json")
beam_sha=$(shasum -a 256 \
  "${release_root}/models/p0-beam-sentence-v3.json" | awk '{ print $1 }')
expected_model_artifact="${fusion_id}:beam-${beam_sha[1,12]}"
for _ in {1..240}; do
  if [[ -S "${socket_file}" ]] \
    && "${daemon_executable}" \
      --probe-socket "${socket_file}" \
      --expected-artifact-id "${expected_model_artifact}" \
      --probe-timeout-ms 500 >/dev/null 2>&1; then
    print -r -- "release=${release_root}"
    print -r -- "daemon_state=ready"
    exit 0
  fi
  sleep 0.5
done

launchctl bootout "${domain}/${label}" >/dev/null 2>&1 || true
swap_selectors "${current_name}" "${previous_name}"
if [[ -e "${cloud_enabled_marker}" ]]; then
  launchctl kickstart -k "${domain}/${cloud_label}" >/dev/null 2>&1 || true
fi
bootstrap_agent >/dev/null 2>&1 || true
launchctl kickstart -k "${domain}/${label}" >/dev/null 2>&1 || true
print -u2 "error: rollback release failed health check; original release restored"
exit 1
