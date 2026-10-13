#!/bin/zsh

set -euo pipefail

if [[ $# -ne 1 ]]; then
  print -u2 "usage: $0 RELEASE_ARCHIVE.tar.gz"
  exit 2
fi

script_dir=${0:A:h}
project_root=${script_dir:h}
archive_file=${1:A}
label=fun.wwcn.rimeai.daemon
domain="gui/${UID}"
template="${project_root}/macos/LaunchAgents/${label}.release.plist"
launch_agents_dir="${HOME}/Library/LaunchAgents"
target_plist="${launch_agents_dir}/${label}.plist"
support_root="${HOME}/Library/Application Support/RimeAI"
releases_root="${support_root}/releases/daemon"
current_link="${releases_root}/current"
previous_link="${releases_root}/previous"
runtime_dir="${support_root}/runtime"
socket_file="${runtime_dir}/rimeai.sock"
log_file="${runtime_dir}/rimeai-daemon.log"
control_dir="${HOME}/Library/Caches/RimeAI"
enabled_marker="${control_dir}/daemon-enabled"
timestamp=$(date +%Y%m%d-%H%M%S)
backup_plist="${HOME}/.Trash/${label}.previous-${timestamp}.plist"
failed_plist="${HOME}/.Trash/${label}.failed-${timestamp}.plist"
extraction_root=$(mktemp -d /tmp/rimeai-release-install.XXXXXX)
staged_plist=$(mktemp "/tmp/${label}.release.XXXXXX")
staging_release=""
old_current=""
old_previous=""
activation_changed=0

valid_link_target() {
  local link_file=$1
  if [[ ! -e "${link_file}" && ! -L "${link_file}" ]]; then
    return 0
  fi
  if [[ ! -L "${link_file}" ]]; then
    print -u2 "error: release selector is not a symlink: ${link_file}"
    return 2
  fi
  local target_name
  target_name=$(readlink "${link_file}")
  if [[ -z "${target_name}" || "${target_name}" == /* \
    || "${target_name}" == */* \
    || ! -d "${releases_root}/${target_name}" ]]; then
    print -u2 "error: invalid release selector: ${link_file}"
    return 2
  fi
  print -r -- "${target_name}"
}

replace_selector() {
  local selector=$1
  local target_name=$2
  local temporary_selector="${releases_root}/.${selector:t}.${$}.new"
  if [[ -e "${temporary_selector}" || -L "${temporary_selector}" ]]; then
    print -u2 "error: temporary selector already exists: ${temporary_selector}"
    return 2
  fi
  if [[ -n "${target_name}" ]]; then
    ln -s "${target_name}" "${temporary_selector}"
    # -h is required because selectors point at directories; without it BSD
    # mv follows the destination symlink and moves the temporary link inside
    # the old release instead of replacing the selector.
    /bin/mv -fh "${temporary_selector}" "${selector}"
  elif [[ -L "${selector}" ]]; then
    unlink "${selector}"
  fi
}

restore_activation() {
  set +e
  launchctl bootout "${domain}/${label}" >/dev/null 2>&1
  replace_selector "${current_link}" "${old_current}"
  replace_selector "${previous_link}" "${old_previous}"
  if [[ -f "${target_plist}" ]]; then
    if [[ ! -e "${failed_plist}" ]]; then
      /bin/mv "${target_plist}" "${failed_plist}"
    fi
  fi
  if [[ -f "${backup_plist}" ]]; then
    /bin/mv "${backup_plist}" "${target_plist}"
    launchctl bootstrap "${domain}" "${target_plist}" >/dev/null 2>&1
    if [[ -e "${enabled_marker}" ]]; then
      launchctl kickstart -k "${domain}/${label}" >/dev/null 2>&1
    fi
  fi
  print -u2 "release activation rolled back"
}

cleanup() {
  local exit_status=$?
  trap - EXIT
  if (( exit_status != 0 && activation_changed )); then
    restore_activation
  fi
  if [[ -n "${staging_release}" && -d "${staging_release}" ]]; then
    case "${staging_release}" in
      "${releases_root}"/.staging.*)
        find "${staging_release}" -depth -delete
        ;;
      *) print -u2 "error: refusing to clean unexpected staging path" ;;
    esac
  fi
  case "${extraction_root}" in
    /tmp/rimeai-release-install.*) find "${extraction_root}" -depth -delete ;;
    *) print -u2 "error: refusing to clean unexpected extraction path" ;;
  esac
  case "${staged_plist}" in
    /tmp/${label}.release.*)
      if [[ -f "${staged_plist}" ]]; then
        unlink "${staged_plist}"
      fi
      ;;
    *) print -u2 "error: refusing to clean unexpected plist path" ;;
  esac
  exit "${exit_status}"
}
trap cleanup EXIT

if [[ ! -f "${archive_file}" || -L "${archive_file}" ]]; then
  print -u2 "error: release archive is not a regular file: ${archive_file}"
  exit 2
fi
if [[ ! -f "${template}" ]]; then
  print -u2 "error: release LaunchAgent template is missing"
  exit 2
fi
if [[ ! -f "${archive_file}.sha256" || -L "${archive_file}.sha256" ]]; then
  print -u2 "error: release archive checksum sidecar is missing"
  exit 2
fi
expected_archive_sha=$(awk 'NR == 1 { print $1 }' "${archive_file}.sha256")
actual_archive_sha=$(shasum -a 256 "${archive_file}" | awk '{ print $1 }')
if [[ "${expected_archive_sha}" != "${actual_archive_sha}" ]]; then
  print -u2 "error: release archive checksum does not match its sidecar"
  exit 1
fi
"${project_root}/scripts/verify_daemon_archive.sh" "${archive_file}"
COPYFILE_DISABLE=1 tar -xzf "${archive_file}" -C "${extraction_root}"
extracted_entries=("${extraction_root}"/*(DN))
if (( ${#extracted_entries} != 1 )) || [[ ! -d "${extracted_entries[1]}" ]]; then
  print -u2 "error: archive must contain exactly one release directory"
  exit 1
fi
extracted_release=${extracted_entries[1]}
manifest_file="${extracted_release}/manifest.json"
version=$(plutil -extract version raw -o - "${manifest_file}")
artifact_id=$(plutil -extract artifact_id raw -o - "${manifest_file}")
artifact_digest=${artifact_id##*:}
safe_version=${version//[^A-Za-z0-9._-]/-}
release_name="${safe_version}-${artifact_digest}"
target_release="${releases_root}/${release_name}"

mkdir -p \
  "${launch_agents_dir}" \
  "${releases_root}" \
  "${runtime_dir}" \
  "${control_dir}"
chmod 700 "${releases_root}" "${runtime_dir}" "${control_dir}"
touch "${log_file}"
chmod 600 "${log_file}"

old_current=$(valid_link_target "${current_link}")
old_previous=$(valid_link_target "${previous_link}")
if [[ -d "${target_release}" ]]; then
  "${project_root}/scripts/verify_daemon_release.sh" "${target_release}"
  installed_artifact_id=$(
    plutil -extract artifact_id raw -o - "${target_release}/manifest.json"
  )
  if [[ "${installed_artifact_id}" != "${artifact_id}" ]]; then
    print -u2 "error: release directory collision: ${target_release}"
    exit 1
  fi
else
  staging_release=$(mktemp -d "${releases_root}/.staging.XXXXXX")
  COPYFILE_DISABLE=1 rsync -a --exclude='._*' \
    "${extracted_release}/" "${staging_release}/"
  "${project_root}/scripts/verify_daemon_release.sh" "${staging_release}"
  /bin/mv "${staging_release}" "${target_release}"
  staging_release=""
fi

stable_release="${current_link}"
daemon_executable="${stable_release}/runtime/rimeai-daemon/rimeai-daemon"
language_model="${stable_release}/models/p0-char-ngram-v2.json.gz"
beam_config="${stable_release}/models/p0-beam-sentence-v3.json"
rime_dictionary="${stable_release}/models/luna_pinyin.dict.yaml"
neural_model="${stable_release}/models/rimeai-ranker-s-24m-v1"
fusion_config="${stable_release}/models/rimeai-ranker-s-24m-fusion-v1.json"

cp "${template}" "${staged_plist}"
/usr/libexec/PlistBuddy -c \
  "Set :ProgramArguments:0 ${daemon_executable}" "${staged_plist}"
/usr/libexec/PlistBuddy -c \
  "Set :ProgramArguments:2 ${socket_file}" "${staged_plist}"
/usr/libexec/PlistBuddy -c \
  "Set :ProgramArguments:4 ${language_model}" "${staged_plist}"
/usr/libexec/PlistBuddy -c \
  "Set :ProgramArguments:6 ${beam_config}" "${staged_plist}"
/usr/libexec/PlistBuddy -c \
  "Set :ProgramArguments:8 ${rime_dictionary}" "${staged_plist}"
/usr/libexec/PlistBuddy -c \
  "Set :ProgramArguments:10 ${neural_model}" "${staged_plist}"
/usr/libexec/PlistBuddy -c \
  "Set :ProgramArguments:12 ${fusion_config}" "${staged_plist}"
/usr/libexec/PlistBuddy -c \
  "Set :WorkingDirectory ${stable_release}" "${staged_plist}"
/usr/libexec/PlistBuddy -c \
  "Set :StandardOutPath ${log_file}" "${staged_plist}"
/usr/libexec/PlistBuddy -c \
  "Set :StandardErrorPath ${log_file}" "${staged_plist}"
/usr/libexec/PlistBuddy -c \
  "Delete :KeepAlive:PathState:__ENABLED_MARKER__" "${staged_plist}"
/usr/libexec/PlistBuddy -c \
  "Add :KeepAlive:PathState:${enabled_marker} bool true" "${staged_plist}"
plutil -lint "${staged_plist}" >/dev/null

ai_enabled=1
if stored_ai_enabled=$(
  defaults read fun.wwcn.inputmethod.RimeAI RimeAIEnabled 2>/dev/null
); then
  if [[ "${stored_ai_enabled}" == "0" ]]; then
    ai_enabled=0
  fi
fi

"${script_dir}/stop_daemon.sh" >/dev/null
activation_changed=1
if [[ -e "${target_plist}" ]]; then
  if [[ -e "${backup_plist}" ]]; then
    print -u2 "error: Trash destination already exists: ${backup_plist}"
    exit 2
  fi
  /bin/mv "${target_plist}" "${backup_plist}"
fi
if [[ -n "${old_current}" && "${old_current}" != "${release_name}" ]]; then
  replace_selector "${previous_link}" "${old_current}"
fi
replace_selector "${current_link}" "${release_name}"
install -m 600 "${staged_plist}" "${target_plist}"
if (( ai_enabled )); then
  touch "${enabled_marker}"
  chmod 600 "${enabled_marker}"
else
  if [[ -e "${enabled_marker}" ]]; then
    unlink "${enabled_marker}"
  fi
fi

bootstrap_succeeded=0
for _ in {1..20}; do
  if launchctl bootstrap "${domain}" "${target_plist}" 2>/dev/null; then
    bootstrap_succeeded=1
    break
  fi
  sleep 0.1
done
if (( ! bootstrap_succeeded )); then
  print -u2 "error: could not bootstrap release LaunchAgent"
  exit 1
fi
if (( ai_enabled )); then
  launchctl kickstart -k "${domain}/${label}"
  fusion_artifact_id=$(plutil -extract artifact_id raw -o - \
    "${target_release}/models/rimeai-ranker-s-24m-fusion-v1.json")
  beam_sha=$(shasum -a 256 \
    "${target_release}/models/p0-beam-sentence-v3.json" | awk '{ print $1 }')
  expected_model_artifact="${fusion_artifact_id}:beam-${beam_sha[1,12]}"
  daemon_ready=0
  for _ in {1..240}; do
    if [[ -S "${socket_file}" ]] \
      && "${daemon_executable}" \
        --probe-socket "${socket_file}" \
        --expected-artifact-id "${expected_model_artifact}" \
        --probe-timeout-ms 500 >/dev/null 2>&1; then
      daemon_ready=1
      break
    fi
    sleep 0.5
  done
  if (( ! daemon_ready )); then
    print -u2 "error: release daemon failed its post-install health check"
    tail -n 40 "${log_file}" >&2 || true
    exit 1
  fi
fi

"${script_dir}/install_release_cloud_broker.sh" "${stable_release}"

activation_changed=0
print -r -- "release=${target_release}"
print -r -- "artifact_id=${artifact_id}"
print -r -- "launch_agent=${target_plist}"
if (( ai_enabled )); then
  print -r -- "daemon_state=ready"
else
  print -r -- "daemon_state=disabled_by_saved_preference"
fi
