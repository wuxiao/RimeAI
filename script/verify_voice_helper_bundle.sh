#!/bin/zsh

# 纯静态验证：不启动 helper、不触发 TCC、不写用户安装目录。

set -euo pipefail

if [[ $# -ne 5 ]]; then
  print -u2 -- \
    "usage: $0 <RimeAIVoiceHelper.app> <rendered LaunchAgent.plist> "\
"<development-uds|authenticated-xpc> <transport endpoint> "\
"<expected installed executable>"
  exit 2
fi

bundle=${1:A}
launch_agent=${2:A}
transport_kind=$3
transport_endpoint=$4
expected_launch_executable=$5
script_dir=${0:A:h}
project_root=${script_dir:h}
label=fun.wwcn.rimeai.voice-helper
info_plist="${bundle}/Contents/Info.plist"
executable="${bundle}/Contents/MacOS/rimeai-voice-helper"
source_entitlements="${project_root}/macos/VoiceHelper/RimeAIVoiceHelper.entitlements"
source_release_policy="${project_root}/macos/VoiceHelper/VoiceReleasePolicy.plist"
bundle_release_policy=\
"${bundle}/Contents/Resources/VoiceReleasePolicy.plist"
typeset -a approved_helper_resources=(
  "${bundle_release_policy}"
  "${bundle}/Contents/Resources/THIRD_PARTY_NOTICES.md"
  "${bundle}/Contents/Resources/ThirdPartyLicenses/sherpa-onnx-Apache-2.0.txt"
  "${bundle}/Contents/Resources/ThirdPartyLicenses/onnxruntime-MIT.txt"
  "${bundle}/Contents/Resources/ThirdPartyLicenses/onnxruntime-ThirdPartyNotices-1.27.1.txt"
)

if [[ "${transport_kind}" != development-uds \
  && "${transport_kind}" != authenticated-xpc ]]; then
  print -u2 "error: unknown transport kind: ${transport_kind}"
  exit 2
fi

if [[ ! -d "${bundle}" ]]; then
  print -u2 "error: app bundle missing: ${bundle}"
  exit 1
fi
if [[ ! -f "${executable}" || -L "${executable}" \
  || ! -x "${executable}" ]]; then
  print -u2 "error: app executable missing: ${executable}"
  exit 1
fi
unexpected_helper_executable=$(find "${bundle}/Contents/MacOS" \
  -mindepth 1 -maxdepth 1 ! -name rimeai-voice-helper -print -quit)
if [[ -n "${unexpected_helper_executable}" ]]; then
  print -u2 \
    "error: helper contains an unapproved executable payload: "\
"${unexpected_helper_executable}"
  exit 1
fi
if [[ ! -f "${launch_agent}" ]]; then
  print -u2 "error: rendered LaunchAgent missing: ${launch_agent}"
  exit 1
fi
for resource in "${approved_helper_resources[@]}"; do
  if [[ ! -f "${resource}" || -L "${resource}" ]]; then
    print -u2 "error: required helper resource is missing or unsafe: ${resource}"
    exit 1
  fi
done
while IFS= read -r -d '' resource; do
  resource_is_approved=false
  for approved_resource in "${approved_helper_resources[@]}"; do
    if [[ "${resource}" == "${approved_resource}" ]]; then
      resource_is_approved=true
      break
    fi
  done
  if [[ "${resource_is_approved}" != true ]]; then
    print -u2 \
      "error: helper contains an unapproved signed resource: ${resource}"
    exit 1
  fi
done < <(find "${bundle}/Contents/Resources" -mindepth 1 ! -type d -print0)

plutil -lint "${info_plist}" "${source_entitlements}" "${launch_agent}" \
  "${bundle_release_policy}" "${source_release_policy}"
if ! cmp -s "${source_release_policy}" "${bundle_release_policy}"; then
  print -u2 \
    "error: helper signed policy does not match the approved source policy"
  exit 1
fi

assert_plist_value() {
  local plist=$1
  local key=$2
  local expected=$3
  local actual
  actual=$(plutil -extract "${key}" raw -o - "${plist}")
  if [[ "${actual}" != "${expected}" ]]; then
    print -u2 \
      "error: ${plist:t} ${key} is '${actual}', expected '${expected}'"
    exit 1
  fi
}

assert_nonempty_plist_value() {
  local plist=$1
  local key=$2
  local actual
  actual=$(plutil -extract "${key}" raw -o - "${plist}")
  if [[ -z "${actual}" ]]; then
    print -u2 "error: ${plist:t} ${key} must not be empty"
    exit 1
  fi
}

assert_plist_value "${info_plist}" CFBundleIdentifier "${label}"
assert_plist_value "${info_plist}" CFBundleExecutable rimeai-voice-helper
assert_plist_value "${info_plist}" CFBundlePackageType APPL
assert_plist_value "${info_plist}" LSUIElement true
assert_nonempty_plist_value "${info_plist}" NSMicrophoneUsageDescription
assert_nonempty_plist_value "${info_plist}" NSSpeechRecognitionUsageDescription
helper_build=$(plutil -extract CFBundleVersion raw -o - "${info_plist}")
environment_keys=$(
  plutil -extract EnvironmentVariables raw -expect dictionary \
    -o - "${launch_agent}"
) || {
  print -u2 "error: LaunchAgent EnvironmentVariables must be a dictionary"
  exit 1
}
environment_keys_sorted=$(print -r -- "${environment_keys}" | LC_ALL=C sort)
bundle_policy_sha256=$(shasum -a 256 "${bundle_release_policy}" \
  | awk '{ print $1 }')
if [[ "${environment_keys_sorted}" \
      != $'RIMEAI_PAIRED_BUILD\nRIMEAI_VOICE_POLICY_SHA256' ]] \
  || [[ "$(plutil -extract EnvironmentVariables.RIMEAI_PAIRED_BUILD \
    raw -expect string -o - "${launch_agent}")" != "${helper_build}" ]] \
  || [[ "$(plutil -extract EnvironmentVariables.RIMEAI_VOICE_POLICY_SHA256 \
    raw -expect string -o - "${launch_agent}")" \
      != "${bundle_policy_sha256}" ]]; then
  print -u2 \
    "error: LaunchAgent must bind the exact helper build and signed policy"
  exit 1
fi

assert_plist_value "${launch_agent}" Label "${label}"
argument_count=$(
  plutil -extract ProgramArguments raw -expect array -o - "${launch_agent}"
) || {
  print -u2 "error: LaunchAgent ProgramArguments must be an array"
  exit 1
}
if [[ "${argument_count}" != 3 && "${argument_count}" != 5 ]]; then
  print -u2 "error: LaunchAgent must have exactly 3 or 5 string arguments"
  exit 1
fi
if [[ "${transport_kind}" == authenticated-xpc \
  && "${argument_count}" != 3 ]]; then
  print -u2 \
    "error: release LaunchAgent must defer engine selection to the signed policy"
  exit 1
fi
typeset -a launch_arguments=()
for (( index = 0; index < argument_count; index++ )); do
  launch_argument=$(
    plutil -extract "ProgramArguments.${index}" raw -expect string \
      -n -o - "${launch_agent}" \
      && print -rn -- x
  ) || {
    print -u2 "error: LaunchAgent argument ${index} must be a string"
    exit 1
  }
  launch_argument=${launch_argument%x}
  launch_arguments+=("${launch_argument}")
done
if [[ "${launch_arguments[1]}" != "${expected_launch_executable}" ]]; then
  print -u2 \
    "error: LaunchAgent must point to ${expected_launch_executable}"
  exit 1
fi
if [[ ${argument_count} -eq 5 ]]; then
  if [[ "${transport_kind}" != development-uds ]]; then
    print -u2 "error: release LaunchAgent must not select an engine by argv"
    exit 1
  fi
  if [[ "${launch_arguments[4]}" != --engine \
    || ( "${launch_arguments[5]}" != apple-speech \
      && "${launch_arguments[5]}" != unavailable ) ]]; then
    print -u2 "error: LaunchAgent engine arguments are invalid"
    exit 1
  fi
fi
if grep -Eq '__[A-Z_]+__' "${launch_agent}"; then
  print -u2 "error: LaunchAgent contains an unresolved template placeholder"
  exit 1
fi

if [[ "${transport_kind}" == development-uds ]]; then
  if [[ "${launch_arguments[2]}" != --socket \
    || "${launch_arguments[3]}" != "${transport_endpoint}" ]]; then
    print -u2 "error: development LaunchAgent must use the exact UDS endpoint"
    exit 1
  fi
  if plutil -type MachServices "${launch_agent}" >/dev/null 2>&1; then
    print -u2 "error: development LaunchAgent must not declare MachServices"
    exit 1
  fi
else
  if [[ "${transport_endpoint}" != "${label}" \
    || "${launch_arguments[2]}" != --mach-service \
    || "${launch_arguments[3]}" != "${label}" ]]; then
    print -u2 "error: release LaunchAgent must use the exact Mach service"
    exit 1
  fi
  mach_service_keys=$(
    plutil -extract MachServices raw -expect dictionary -o - "${launch_agent}"
  ) || {
    print -u2 "error: release LaunchAgent MachServices must be a dictionary"
    exit 1
  }
  if [[ "${mach_service_keys}" != "${label}" \
    || "$(/usr/libexec/PlistBuddy \
      -c "Print :MachServices:${label}" "${launch_agent}")" != true ]]; then
    print -u2 "error: release LaunchAgent must vend only ${label}"
    exit 1
  fi
  if grep -F -- '--socket' "${launch_agent}" >/dev/null; then
    print -u2 "error: release LaunchAgent contains a UDS argument"
    exit 1
  fi
fi

codesign --verify --strict --verbose=2 "${bundle}"
signing_details=$(codesign -dvvv "${bundle}" 2>&1)
signed_identifier=$(
  print -r -- "${signing_details}" | sed -n 's/^Identifier=//p'
)
if [[ "${signed_identifier}" != "${label}" ]]; then
  print -u2 "error: signed identifier is not ${label}"
  exit 1
fi
runtime_flag_line=$(
  print -r -- "${signing_details}" \
    | sed -n '/^CodeDirectory .*flags=.*runtime/p'
)
if [[ -z "${runtime_flag_line}" ]]; then
  print -u2 "error: Hardened Runtime flag is missing"
  exit 1
fi

if [[ "${transport_kind}" == development-uds ]]; then
  signature_kind=$(
    print -r -- "${signing_details}" | sed -n 's/^Signature=//p'
  )
  team_identifier=$(
    print -r -- "${signing_details}" | sed -n 's/^TeamIdentifier=//p'
  )
  if [[ "${signature_kind}" != adhoc \
    || ( -n "${team_identifier}" && "${team_identifier}" != 'not set' ) ]]; then
    print -u2 "error: development UDS bundle must be ad-hoc signed"
    exit 1
  fi
else
  team_identifier=$(
    print -r -- "${signing_details}" | sed -n 's/^TeamIdentifier=//p'
  )
  if ! print -r -- "${team_identifier}" | grep -Eq '^[A-Z0-9]{10}$'; then
    print -u2 "error: release bundle has no valid TeamIdentifier"
    exit 1
  fi
  developer_id_requirement=\
"anchor apple generic and identifier \"${label}\" and "\
"certificate 1[field.1.2.840.113635.100.6.2.6] exists and "\
"certificate leaf[field.1.2.840.113635.100.6.1.13] exists and "\
"certificate leaf[subject.OU] = \"${team_identifier}\""
  if ! codesign --verify --strict --verbose=2 \
    -R="${developer_id_requirement}" "${bundle}"; then
    print -u2 "error: release bundle does not satisfy the Developer ID requirement"
    exit 1
  fi
fi

scratch_directory=$(mktemp -d "${TMPDIR:-/tmp}/rimeai-voice-verify.XXXXXX")
trap 'rm -rf -- "${scratch_directory}"' EXIT
signed_entitlements="${scratch_directory}/signed-entitlements.plist"
codesign -d --entitlements :- "${bundle}" \
  > "${signed_entitlements}" 2>/dev/null
plutil -lint "${signed_entitlements}"
plutil -convert xml1 "${signed_entitlements}"
audio_input_entitlement=$(
  /usr/libexec/PlistBuddy \
    -c 'Print :com.apple.security.device.audio-input' \
    "${signed_entitlements}"
)
if [[ "${audio_input_entitlement}" != "true" ]]; then
  print -u2 "error: signed audio-input entitlement is not true"
  exit 1
fi

# 此 helper 不是沙箱 App；发布合同只允许音频输入这一项 entitlement。精确
# 白名单会同时拒绝 get-task-allow、关闭 library validation、JIT 与网络等任何
# 意外能力。缺少 network entitlement 仍只是一项静态信号，不会限制非沙箱
# 进程联网；离线发布仍依赖 on-device fail-closed、无云代码路径和运行态
# no-INET 审计。
entitlement_key_count=$(grep -c '<key>' "${signed_entitlements}")
if [[ "${entitlement_key_count}" != 1 ]]; then
  print -u2 \
    "error: signed helper entitlements must contain only audio-input"
  exit 1
fi

print -- \
  "voice helper bundle static verification passed "\
"(${transport_kind}; runtime no-INET not tested): ${bundle}"
