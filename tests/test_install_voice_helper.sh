#!/bin/zsh

# 纯函数专项测试：只使用 mktemp 目录，不构建、不写真实 HOME、不调用
# launchctl，也不启动 helper 或触发 TCC。

set -euo pipefail

test_root=$(mktemp -d "${TMPDIR:-/tmp}/rimeai-voice-installer-test.XXXXXX")
trap '/bin/rm -rf -- "${test_root}"' EXIT
export HOME="${test_root}/home"
mkdir -p "${HOME}"

test_dir=${0:A:h}
installer=${test_dir:h}/script/install_voice_helper.sh

if zsh "${installer}" --engine unavailable \
  --signing-identity 'Developer ID Application: Example (TEAMID1234)' \
  --build-only >/dev/null 2>&1; then
  print -u2 "FAIL: Release installer must reject argv engine selection"
  exit 1
fi
if zsh "${installer}" \
  --signing-identity 'Developer ID Application: Example (TEAMID1234)' \
  >/dev/null 2>&1; then
  print -u2 "FAIL: signed Release helper must not use standalone installation"
  exit 1
fi
export RIMEAI_VOICE_INSTALLER_TEST_SOURCE_ONLY=1
source "${installer}"
unset RIMEAI_VOICE_INSTALLER_TEST_SOURCE_ONLY

fail() {
  print -u2 "FAIL: $1"
  exit 1
}

expect_ready_rejected() {
  local name=$1
  response=$2
  if validate_ready_response; then
    fail "voice_ready should reject ${name}"
  fi
}

engine=apple-speech
response='{"protocol_version":2,"type":"voice_ready","server_id":"fun.wwcn.rimeai.voice-helper","capabilities":["streaming","local_asr"],"network_policy":"offline","asr_engine_id":"apple-speech-ondevice","maximum_hotwords":0}'
validate_ready_response || fail "exact Array<String> capabilities should pass"

version_plist="${test_root}/helper-info.plist"
cp "${info_plist}" "${version_plist}"
marketing_version=2.3.4
build_number=57
stamp_helper_version "${version_plist}" \
  || fail "helper version stamping should succeed"
[[ "$(plutil -extract CFBundleShortVersionString raw -o - "${version_plist}")" \
  == 2.3.4 ]] || fail "helper marketing version was not stamped"
[[ "$(plutil -extract CFBundleVersion raw -o - "${version_plist}")" == 57 ]] \
  || fail "helper build number was not stamped"
marketing_version=
build_number=

engine=unavailable
expect_ready_rejected "honest unavailable empty capabilities" \
  '{"protocol_version":2,"type":"voice_ready","server_id":"fun.wwcn.rimeai.voice-helper","capabilities":[],"network_policy":"offline","asr_engine_id":"unavailable-stub","maximum_hotwords":0}'
expect_ready_rejected "unavailable lying about ASR capabilities" \
  '{"protocol_version":2,"type":"voice_ready","server_id":"fun.wwcn.rimeai.voice-helper","capabilities":["local_asr","streaming"],"network_policy":"offline","asr_engine_id":"unavailable-stub","maximum_hotwords":0}'
engine=apple-speech

expect_ready_rejected "missing capability" \
  '{"protocol_version":2,"type":"voice_ready","server_id":"fun.wwcn.rimeai.voice-helper","capabilities":["local_asr"],"network_policy":"offline","asr_engine_id":"apple-speech-ondevice","maximum_hotwords":0}'
expect_ready_rejected "extra capability" \
  '{"protocol_version":2,"type":"voice_ready","server_id":"fun.wwcn.rimeai.voice-helper","capabilities":["local_asr","streaming","polish"],"network_policy":"offline","asr_engine_id":"apple-speech-ondevice","maximum_hotwords":0}'
expect_ready_rejected "duplicate capability" \
  '{"protocol_version":2,"type":"voice_ready","server_id":"fun.wwcn.rimeai.voice-helper","capabilities":["local_asr","local_asr"],"network_policy":"offline","asr_engine_id":"apple-speech-ondevice","maximum_hotwords":0}'
expect_ready_rejected "string disguised as array" \
  '{"protocol_version":2,"type":"voice_ready","server_id":"fun.wwcn.rimeai.voice-helper","capabilities":"[local_asr,streaming]","network_policy":"offline","asr_engine_id":"apple-speech-ondevice","maximum_hotwords":0}'
expect_ready_rejected "dictionary keys disguised as members" \
  '{"protocol_version":2,"type":"voice_ready","server_id":"fun.wwcn.rimeai.voice-helper","capabilities":{"local_asr":"streaming"},"network_policy":"offline","asr_engine_id":"apple-speech-ondevice","maximum_hotwords":0}'
expect_ready_rejected "non-string array member" \
  '{"protocol_version":2,"type":"voice_ready","server_id":"fun.wwcn.rimeai.voice-helper","capabilities":["local_asr",{"name":"streaming"}],"network_policy":"offline","asr_engine_id":"apple-speech-ondevice","maximum_hotwords":0}'
expect_ready_rejected "capability with trailing newline" \
  '{"protocol_version":2,"type":"voice_ready","server_id":"fun.wwcn.rimeai.voice-helper","capabilities":["local_asr","streaming\n"],"network_policy":"offline","asr_engine_id":"apple-speech-ondevice","maximum_hotwords":0}'

expect_ready_rejected "missing maximum_hotwords" \
  '{"protocol_version":2,"type":"voice_ready","server_id":"fun.wwcn.rimeai.voice-helper","capabilities":["local_asr","streaming"],"network_policy":"offline","asr_engine_id":"apple-speech-ondevice"}'
expect_ready_rejected "Apple probe claiming hotwords" \
  '{"protocol_version":2,"type":"voice_ready","server_id":"fun.wwcn.rimeai.voice-helper","capabilities":["local_asr","streaming"],"network_policy":"offline","asr_engine_id":"apple-speech-ondevice","maximum_hotwords":32}'
expect_ready_rejected "string maximum_hotwords" \
  '{"protocol_version":2,"type":"voice_ready","server_id":"fun.wwcn.rimeai.voice-helper","capabilities":["local_asr","streaming"],"network_policy":"offline","asr_engine_id":"apple-speech-ondevice","maximum_hotwords":"0"}'
expect_ready_rejected "string protocol_version" \
  '{"protocol_version":"2","type":"voice_ready","server_id":"fun.wwcn.rimeai.voice-helper","capabilities":["local_asr","streaming"],"network_policy":"offline","asr_engine_id":"apple-speech-ondevice","maximum_hotwords":0}'

typeset -g staging_failure=none
typeset -gi rm_failure_count=0

rm() {
  local destination=${@[-1]}
  if [[ "${staging_failure}" == rm \
    && "${destination}" == "${installing_app}" \
    && ${rm_failure_count} -eq 0 ]]; then
    rm_failure_count=1
    return 71
  fi
  /bin/rm "$@"
}

ditto() {
  if [[ "${staging_failure}" == ditto ]]; then
    mkdir -p "$2"
    print -r -- partial > "$2/partial-copy"
    return 72
  fi
  /usr/bin/ditto "$@"
}

codesign() {
  if [[ "${staging_failure}" == codesign ]]; then
    return 73
  fi
  return 0
}

launchctl() {
  fail "pure installer harness must not invoke launchctl"
}

reset_staging_case() {
  local name=$1
  case_root="${test_root}/staging-${name}"
  /bin/rm -rf -- "${case_root}"
  voice_root="${case_root}/voice"
  staged_app="${case_root}/staged/${app_name}"
  helper_app="${voice_root}/${app_name}"
  installing_app="${voice_root}/.${app_name}.installing.$$"
  mkdir -p "${staged_app}/Contents" "${helper_app}/Contents"
  print -r -- new > "${staged_app}/Contents/version"
  print -r -- old > "${helper_app}/Contents/version"
  staging_failure=none
  rm_failure_count=0
}

assert_old_helper_unchanged() {
  [[ -f "${helper_app}/Contents/version" ]] \
    || fail "old helper disappeared during pre-replacement staging"
  [[ "$(< "${helper_app}/Contents/version")" == old ]] \
    || fail "old helper changed during pre-replacement staging"
}

reset_staging_case rm
mkdir -p "${installing_app}"
print -r -- stale > "${installing_app}/stale"
staging_failure=rm
if stage_installing_app >/dev/null 2>&1; then
  fail "staging should fail when initial rm fails"
fi
[[ ! -e "${installing_app}" && ! -L "${installing_app}" ]] \
  || fail "rm failure left the private .installing directory behind"
assert_old_helper_unchanged

reset_staging_case ditto
staging_failure=ditto
if stage_installing_app >/dev/null 2>&1; then
  fail "staging should fail when ditto fails"
fi
[[ ! -e "${installing_app}" && ! -L "${installing_app}" ]] \
  || fail "ditto failure left a partial .installing directory behind"
assert_old_helper_unchanged

reset_staging_case codesign
staging_failure=codesign
if stage_installing_app >/dev/null 2>&1; then
  fail "staging should fail when codesign verification fails"
fi
[[ ! -e "${installing_app}" && ! -L "${installing_app}" ]] \
  || fail "codesign failure left the .installing directory behind"
assert_old_helper_unchanged

reset_staging_case success
stage_installing_app >/dev/null 2>&1 \
  || fail "valid staging should succeed"
[[ -f "${installing_app}/Contents/version" ]] \
  || fail "valid staging did not copy the new helper"
assert_old_helper_unchanged
cleanup_installing_app >/dev/null 2>&1 \
  || fail "successful staging cleanup failed"

reset_staging_case unsafe-path
unsafe_installing_app="${case_root}/outside/.${app_name}.installing.$$"
mkdir -p "${unsafe_installing_app}"
print -r -- preserved > "${unsafe_installing_app}/sentinel"
installing_app="${unsafe_installing_app}"
if cleanup_installing_app >/dev/null 2>&1; then
  fail "cleanup should reject an .installing path outside voice_root"
fi
[[ "$(< "${unsafe_installing_app}/sentinel")" == preserved ]] \
  || fail "unsafe cleanup path was modified"

control_dir="${test_root}/marker"
mkdir -p "${control_dir}"
enabled_marker="${control_dir}/voice-enabled"
umask 022
create_enabled_marker || fail "atomic marker creation failed"
marker_perms=$(stat -f "%Lp" "${enabled_marker}")
[[ "${marker_perms}" == 600 ]] \
  || fail "marker was not created with mode 0600"
/bin/rm -f -- "${enabled_marker}"

print -r -- preserved > "${enabled_marker}"
chmod 0600 "${enabled_marker}"
if create_enabled_marker >/dev/null 2>&1; then
  fail "marker creation should reject an existing file"
fi
[[ "$(< "${enabled_marker}")" == preserved ]] \
  || fail "existing marker was overwritten"
/bin/rm -f -- "${enabled_marker}"

victim="${control_dir}/victim"
print -r -- preserved > "${victim}"
ln -s "${victim}" "${enabled_marker}"
if create_enabled_marker >/dev/null 2>&1; then
  fail "marker creation should reject a symlink"
fi
[[ "$(< "${victim}")" == preserved ]] \
  || fail "marker symlink target was modified"

if grep -Eq \
  'touch[[:space:]]+"\$\{enabled_marker\}"|chmod[[:space:]]+0?600[[:space:]]+"\$\{enabled_marker\}"' \
  "${installer}"; then
  fail "installer reintroduced a touch/chmod marker permission window"
fi
[[ ! -e "${HOME}/Library" ]] \
  || fail "pure installer harness wrote into its isolated HOME"

render_root="${test_root}/render-development"
mkdir -p "${render_root}"
rendered_base="${render_root}/base.plist"
rendered_plist="${render_root}/rendered.plist"
helper_app="${render_root}/${app_name}"
helper_executable="${helper_app}/Contents/MacOS/rimeai-voice-helper"
socket_file="${render_root}/rimeai-voice.sock"
enabled_marker="${render_root}/voice-enabled"
log_file="${render_root}/voice-helper.log"
engine=apple-speech
signing_identity=-
configure_install_mode
[[ "${build_configuration}" == debug ]] \
  || fail "ad-hoc mode must select a Debug build"
[[ "${transport_kind}" == development-uds ]] \
  || fail "ad-hoc mode must select explicit development UDS"
render_launch_agent
[[ "$(plutil -extract ProgramArguments raw -expect array \
  -o - "${rendered_plist}")" == 5 ]] \
  || fail "ad-hoc Apple LaunchAgent must have five arguments"
[[ "$(plutil -extract ProgramArguments.1 raw -o - "${rendered_plist}")" \
  == --socket ]] || fail "ad-hoc LaunchAgent must pass --socket"
[[ "$(plutil -extract ProgramArguments.2 raw -o - "${rendered_plist}")" \
  == "${socket_file}" ]] || fail "ad-hoc LaunchAgent socket path mismatch"
[[ "$(plutil -extract EnvironmentVariables.RIMEAI_PAIRED_BUILD raw \
  -o - "${rendered_plist}")" == 1 ]] \
  || fail "ad-hoc LaunchAgent paired build mismatch"
expected_policy_sha256=$(shasum -a 256 "${release_policy}" | awk '{ print $1 }')
[[ "$(plutil -extract EnvironmentVariables.RIMEAI_VOICE_POLICY_SHA256 raw \
  -o - "${rendered_plist}")" == "${expected_policy_sha256}" ]] \
  || fail "ad-hoc LaunchAgent policy digest mismatch"
if plutil -type MachServices "${rendered_plist}" >/dev/null 2>&1; then
  fail "ad-hoc LaunchAgent must not contain MachServices"
fi

render_root="${test_root}/render-release"
mkdir -p "${render_root}"
rendered_base="${render_root}/base.plist"
rendered_plist="${render_root}/rendered.plist"
helper_app="${render_root}/${app_name}"
helper_executable="${helper_app}/Contents/MacOS/rimeai-voice-helper"
socket_file="${render_root}/must-not-appear.sock"
enabled_marker="${render_root}/voice-enabled"
log_file="${render_root}/voice-helper.log"
signing_identity='Developer ID Application: Example (TEAMID1234)'
configure_install_mode
[[ "${build_configuration}" == release ]] \
  || fail "Developer ID mode must select a Release build"
[[ "${transport_kind}" == authenticated-xpc ]] \
  || fail "Developer ID mode must select authenticated XPC"
render_launch_agent
[[ "$(plutil -extract ProgramArguments raw -expect array \
  -o - "${rendered_plist}")" == 3 ]] \
  || fail "release LaunchAgent must have only three arguments"
[[ "$(plutil -extract ProgramArguments.1 raw -o - "${rendered_plist}")" \
  == --mach-service ]] || fail "release LaunchAgent must pass --mach-service"
[[ "$(plutil -extract ProgramArguments.2 raw -o - "${rendered_plist}")" \
  == "${label}" ]] || fail "release Mach service argument mismatch"
[[ "$(plutil -extract EnvironmentVariables.RIMEAI_PAIRED_BUILD raw \
  -o - "${rendered_plist}")" == 1 ]] \
  || fail "release LaunchAgent paired build mismatch"
[[ "$(plutil -extract EnvironmentVariables.RIMEAI_VOICE_POLICY_SHA256 raw \
  -o - "${rendered_plist}")" == "${expected_policy_sha256}" ]] \
  || fail "release LaunchAgent policy digest mismatch"
mach_service_keys=$(
  plutil -extract MachServices raw -expect dictionary -o - "${rendered_plist}"
) || fail "release LaunchAgent MachServices must be a dictionary"
[[ "${mach_service_keys}" == "${label}" ]] \
  || fail "release LaunchAgent must declare exactly one Mach service"
[[ "$(/usr/libexec/PlistBuddy \
  -c "Print :MachServices:${label}" "${rendered_plist}")" == true ]] \
  || fail "release LaunchAgent must vend the exact enabled Mach service"
if grep -F -- '--socket' "${rendered_plist}" >/dev/null \
  || grep -F -- "${socket_file}" "${rendered_plist}" >/dev/null \
  || grep -F -- '--engine' "${rendered_plist}" >/dev/null; then
  fail "release LaunchAgent must contain neither UDS nor engine arguments"
fi

typeset -ga launchctl_calls=()
launchctl() {
  launchctl_calls+=("$*")
  if [[ "$1" == print ]]; then
    return ${launchctl_service_not_found_status}
  fi
  return 0
}
enabled_marker="${test_root}/launchd/voice-enabled"
socket_file="${test_root}/launchd/voice.sock"
mkdir -p "${enabled_marker:h}"
disable_service_state || fail "disabling an absent job should succeed"
if [[ "${(F)launchctl_calls}" != *"disable ${domain}/${label}"* ]]; then
  fail "disable_service_state must persistently disable the launchd job"
fi
launchctl_calls=()
enable_launchd_job || fail "enabling the launchd job should succeed"
[[ "${(F)launchctl_calls}" == "enable ${domain}/${label}" ]] \
  || fail "enable_launchd_job must enable the exact launchd job"

staged_app="${test_root}/release-signing/${app_name}"
host_input_method_app="${HOME}/Library/Input Methods/RimeAIInputMethod.app"
mkdir -p "${staged_app}" "${host_input_method_app}"
typeset -g mock_helper_identifier="${label}"
typeset -g mock_host_identifier=fun.wwcn.inputmethod.RimeAI
typeset -g mock_helper_team=TEAMID1234
typeset -g mock_host_team=TEAMID1234
typeset -g mock_requirement_failure=none
typeset -ga requirement_checks=()
codesign() {
  local argument bundle_path
  if [[ "$1" == -dvvv ]]; then
    bundle_path=$2
    if [[ "${bundle_path}" == "${staged_app}" ]]; then
      print -u2 -- "Identifier=${mock_helper_identifier}"
      print -u2 -- "TeamIdentifier=${mock_helper_team}"
    elif [[ "${bundle_path}" == "${host_input_method_app}" ]]; then
      print -u2 -- "Identifier=${mock_host_identifier}"
      print -u2 -- "TeamIdentifier=${mock_host_team}"
    else
      return 1
    fi
    return 0
  fi
  if [[ "$1" == --verify ]]; then
    bundle_path=${@[-1]}
    for argument in "$@"; do
      if [[ "${argument}" == -R=* ]]; then
        requirement_checks+=("${bundle_path}|${argument}")
      fi
    done
    if [[ "${mock_requirement_failure}" == "${bundle_path}" ]]; then
      return 3
    fi
    return 0
  fi
  return 1
}
validate_release_signing_pair "${staged_app}" \
  || fail "matching Developer ID helper and input method should pass"
[[ ${#requirement_checks} -eq 2 ]] \
  || fail "both release bundles must undergo a Developer ID requirement check"
[[ "${(F)requirement_checks}" == *"identifier \"${label}\""* \
  && "${(F)requirement_checks}" == *"identifier \"fun.wwcn.inputmethod.RimeAI\""* \
  && "${(F)requirement_checks}" == *'certificate leaf[subject.OU] = "TEAMID1234"'* ]] \
  || fail "Developer ID requirements must bind exact identifiers and Team"

mock_helper_identifier="${label}.lookalike"
if validate_release_signing_pair "${staged_app}" >/dev/null 2>&1; then
  fail "release validation must reject an inexact helper identifier"
fi
mock_helper_identifier="${label}"
mock_host_identifier=fun.wwcn.inputmethod.RimeAI.lookalike
if validate_release_signing_pair "${staged_app}" >/dev/null 2>&1; then
  fail "release validation must reject an inexact input method identifier"
fi
mock_host_identifier=fun.wwcn.inputmethod.RimeAI
mock_host_team=OTHERTEAM1
if validate_release_signing_pair "${staged_app}" >/dev/null 2>&1; then
  fail "release validation must reject a different input method Team"
fi
mock_host_team=TEAMID1234
mock_requirement_failure="${staged_app}"
if validate_release_signing_pair "${staged_app}" >/dev/null 2>&1; then
  fail "release validation must reject a non-Developer-ID helper"
fi
mock_requirement_failure="${host_input_method_app}"
if validate_release_signing_pair "${staged_app}" >/dev/null 2>&1; then
  fail "release validation must reject a non-Developer-ID input method"
fi
mock_requirement_failure=none

typeset -ga release_readiness_calls=()
launchctl() {
  release_readiness_calls+=("$*")
  [[ "$1" == print ]]
}
nc() {
  fail "authenticated XPC readiness must never invoke nc"
}
transport_kind=authenticated-xpc
verify_enabled_transport \
  || fail "loaded authenticated XPC job should pass readiness"
[[ "${(F)release_readiness_calls}" == "print ${domain}/${label}" ]] \
  || fail "authenticated XPC readiness must inspect only the exact launchd job"

print "PASS: install_voice_helper staging, capabilities, and marker checks"
