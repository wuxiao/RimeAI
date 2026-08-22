#!/bin/zsh

# 纯静态 verifier 测试。临时 bundle 的签名查询由本脚本的 stub 模式响应；
# 不启动 helper、不访问 TCC、不写真实 HOME。

set -euo pipefail

if [[ "${RIMEAI_CODESIGN_STUB:-0}" == 1 ]]; then
  case "$1" in
    -dvvv)
      print -u2 -- 'Identifier=fun.wwcn.rimeai.voice-helper'
      print -u2 -- 'CodeDirectory v=20500 size=1 flags=0x10000(runtime) hashes=1+1 location=embedded'
      if [[ "${MOCK_SIGNING_MODE}" == development-uds ]]; then
        print -u2 -- 'Signature=adhoc'
        print -u2 -- 'TeamIdentifier=not set'
      else
        print -u2 -- 'Authority=Developer ID Application: Example'
        print -u2 -- 'TeamIdentifier=TEAMID1234'
      fi
      exit 0
      ;;
    -d)
      if [[ "$2" == --entitlements ]]; then
        /bin/cat "${MOCK_ENTITLEMENTS}"
        exit 0
      fi
      ;;
    --verify)
      for argument in "$@"; do
        if [[ "${argument}" == -R=* \
          && "${MOCK_REQUIREMENT_FAILURE:-0}" == 1 ]]; then
          exit 3
        fi
      done
      exit 0
      ;;
  esac
  exit 2
fi

test_root=$(mktemp -d "${TMPDIR:-/tmp}/rimeai-voice-verifier-test.XXXXXX")
trap '/bin/rm -rf -- "${test_root}"' EXIT
export HOME="${test_root}/home"
mkdir -p "${HOME}"

test_dir=${0:A:h}
project_root=${test_dir:h}
installer="${project_root}/script/install_voice_helper.sh"
validator="${project_root}/script/verify_voice_helper_bundle.sh"
export RIMEAI_VOICE_INSTALLER_TEST_SOURCE_ONLY=1
source "${installer}"
unset RIMEAI_VOICE_INSTALLER_TEST_SOURCE_ONLY

fail() {
  print -u2 "FAIL: $1"
  exit 1
}

bundle="${test_root}/${app_name}"
mkdir -p \
  "${bundle}/Contents/MacOS" \
  "${bundle}/Contents/Resources/ThirdPartyLicenses"
/usr/bin/install -m 0644 "${info_plist}" "${bundle}/Contents/Info.plist"
/usr/bin/install -m 0644 "${release_policy}" \
  "${bundle}/Contents/Resources/VoiceReleasePolicy.plist"
/usr/bin/install -m 0644 "${third_party_notices}" \
  "${bundle}/Contents/Resources/THIRD_PARTY_NOTICES.md"
/usr/bin/install -m 0644 "${sherpa_license}" \
  "${bundle}/Contents/Resources/ThirdPartyLicenses/${sherpa_license:t}"
/usr/bin/install -m 0644 "${onnxruntime_license}" \
  "${bundle}/Contents/Resources/ThirdPartyLicenses/${onnxruntime_license:t}"
/usr/bin/install -m 0644 "${onnxruntime_notices}" \
  "${bundle}/Contents/Resources/ThirdPartyLicenses/${onnxruntime_notices:t}"
print '#!/bin/zsh\nexit 0' > "${bundle}/Contents/MacOS/rimeai-voice-helper"
chmod 0755 "${bundle}/Contents/MacOS/rimeai-voice-helper"

mock_bin="${test_root}/mock-bin"
mkdir -p "${mock_bin}"
ln -s "${0:A}" "${mock_bin}/codesign"
export MOCK_ENTITLEMENTS="${entitlements}"

render_case() {
  local case_name=$1
  local identity=$2
  local selected_engine=${3:-apple-speech}
  render_root="${test_root}/${case_name}"
  mkdir -p "${render_root}"
  rendered_base="${render_root}/base.plist"
  rendered_plist="${render_root}/rendered.plist"
  helper_app="${test_root}/installed/${app_name}"
  helper_executable="${helper_app}/Contents/MacOS/rimeai-voice-helper"
  socket_file="${test_root}/runtime/rimeai-voice.sock"
  enabled_marker="${test_root}/control/voice-enabled"
  log_file="${test_root}/runtime/voice-helper.log"
  engine=${selected_engine}
  signing_identity=${identity}
  configure_install_mode
  render_launch_agent >/dev/null
}

render_case development -
development_plist=${rendered_plist}
RIMEAI_CODESIGN_STUB=1 MOCK_SIGNING_MODE=development-uds \
PATH="${mock_bin}:${PATH}" \
  zsh "${validator}" \
    "${bundle}" "${development_plist}" development-uds \
    "${socket_file}" "${helper_executable}" \
  || fail "valid ad-hoc UDS bundle and LaunchAgent should pass"

bundle_policy="${bundle}/Contents/Resources/VoiceReleasePolicy.plist"
/bin/mv "${bundle_policy}" "${bundle_policy}.missing"
if RIMEAI_CODESIGN_STUB=1 MOCK_SIGNING_MODE=development-uds \
  PATH="${mock_bin}:${PATH}" \
  zsh "${validator}" \
    "${bundle}" "${development_plist}" development-uds \
    "${socket_file}" "${helper_executable}" >/dev/null 2>&1; then
  fail "helper verifier must reject a missing signed policy"
fi
/bin/mv "${bundle_policy}.missing" "${bundle_policy}"

missing_notice=\
"${bundle}/Contents/Resources/ThirdPartyLicenses/onnxruntime-ThirdPartyNotices-1.27.1.txt"
/bin/mv "${missing_notice}" "${missing_notice}.missing"
if RIMEAI_CODESIGN_STUB=1 MOCK_SIGNING_MODE=development-uds \
  PATH="${mock_bin}:${PATH}" \
  zsh "${validator}" \
    "${bundle}" "${development_plist}" development-uds \
    "${socket_file}" "${helper_executable}" >/dev/null 2>&1; then
  fail "helper verifier must reject a missing runtime notice"
fi
/bin/mv "${missing_notice}.missing" "${missing_notice}"

render_case release 'Developer ID Application: Example (TEAMID1234)'
release_plist=${rendered_plist}
RIMEAI_CODESIGN_STUB=1 MOCK_SIGNING_MODE=authenticated-xpc \
PATH="${mock_bin}:${PATH}" \
  zsh "${validator}" \
    "${bundle}" "${release_plist}" authenticated-xpc \
    "${label}" "${helper_executable}" \
  || fail "valid Developer ID XPC bundle and LaunchAgent should pass"

for forbidden_executable_name in \
  rimeai-voice-performance-collector \
  rimeai-voice-performance-tracer \
  rimeai-voice-evaluation-driver; do
  forbidden_executable=\
"${bundle}/Contents/MacOS/${forbidden_executable_name}"
  print '#!/bin/zsh\nexit 0' > "${forbidden_executable}"
  chmod 0755 "${forbidden_executable}"
  if RIMEAI_CODESIGN_STUB=1 MOCK_SIGNING_MODE=authenticated-xpc \
    PATH="${mock_bin}:${PATH}" \
    zsh "${validator}" \
      "${bundle}" "${release_plist}" authenticated-xpc \
      "${label}" "${helper_executable}" >/dev/null 2>&1; then
    fail "release verifier must reject ${forbidden_executable_name}"
  fi
  /bin/rm -- "${forbidden_executable}"
done

for forbidden_policy_name in \
  VoicePerformanceMeasurementPolicy.json \
  VoicePerformanceDriverPolicy.json \
  VoicePerformanceControlSocketPolicy.plist; do
  forbidden_policy=\
"${bundle}/Contents/Resources/${forbidden_policy_name}"
  print '{"schema_version":2}' > "${forbidden_policy}"
  if RIMEAI_CODESIGN_STUB=1 MOCK_SIGNING_MODE=authenticated-xpc \
    PATH="${mock_bin}:${PATH}" \
    zsh "${validator}" \
      "${bundle}" "${release_plist}" authenticated-xpc \
      "${label}" "${helper_executable}" >/dev/null 2>&1; then
    fail "release verifier must reject ${forbidden_policy_name}"
  fi
  /bin/rm -- "${forbidden_policy}"
done

release_with_engine="${test_root}/release-with-engine.plist"
/bin/cp "${release_plist}" "${release_with_engine}"
/usr/libexec/PlistBuddy -c \
  'Add :ProgramArguments:3 string --engine' "${release_with_engine}"
/usr/libexec/PlistBuddy -c \
  'Add :ProgramArguments:4 string apple-speech' "${release_with_engine}"
if RIMEAI_CODESIGN_STUB=1 MOCK_SIGNING_MODE=authenticated-xpc \
  PATH="${mock_bin}:${PATH}" \
  zsh "${validator}" \
    "${bundle}" "${release_with_engine}" authenticated-xpc \
    "${label}" "${helper_executable}" >/dev/null 2>&1; then
  fail "release verifier must reject argv engine selection"
fi

wrong_build_plist="${test_root}/release-wrong-build.plist"
/bin/cp "${release_plist}" "${wrong_build_plist}"
plutil -replace EnvironmentVariables.RIMEAI_PAIRED_BUILD \
  -string 999 "${wrong_build_plist}"
if RIMEAI_CODESIGN_STUB=1 MOCK_SIGNING_MODE=authenticated-xpc \
  PATH="${mock_bin}:${PATH}" \
  zsh "${validator}" \
    "${bundle}" "${wrong_build_plist}" authenticated-xpc \
    "${label}" "${helper_executable}" >/dev/null 2>&1; then
  fail "release verifier must reject a mismatched paired build"
fi

render_case release-unavailable \
  'Developer ID Application: Example (TEAMID1234)' unavailable
release_unavailable_plist=${rendered_plist}
cmp -s "${release_plist}" "${release_unavailable_plist}" \
  || fail "release engine argv must not alter the signed-policy LaunchAgent"
RIMEAI_CODESIGN_STUB=1 MOCK_SIGNING_MODE=authenticated-xpc \
  PATH="${mock_bin}:${PATH}" \
  zsh "${validator}" \
    "${bundle}" "${release_unavailable_plist}" authenticated-xpc \
    "${label}" "${helper_executable}" \
  || fail "release verifier must ignore development engine selection argv"

/usr/libexec/PlistBuddy -c 'Set :ReleaseEligible true' "${bundle_policy}"
if RIMEAI_CODESIGN_STUB=1 MOCK_SIGNING_MODE=authenticated-xpc \
  PATH="${mock_bin}:${PATH}" \
  zsh "${validator}" \
    "${bundle}" "${release_plist}" authenticated-xpc \
    "${label}" "${helper_executable}" >/dev/null 2>&1; then
  fail "release verifier must reject a bundle policy that diverges from source"
fi
/usr/bin/install -m 0644 "${release_policy}" "${bundle_policy}"

debug_entitlements="${test_root}/debug-entitlements.plist"
/bin/cp "${entitlements}" "${debug_entitlements}"
/usr/libexec/PlistBuddy \
  -c 'Add :com.apple.security.get-task-allow bool true' \
  "${debug_entitlements}"
if RIMEAI_CODESIGN_STUB=1 MOCK_SIGNING_MODE=authenticated-xpc \
  MOCK_ENTITLEMENTS="${debug_entitlements}" \
  PATH="${mock_bin}:${PATH}" \
  zsh "${validator}" \
    "${bundle}" "${release_plist}" authenticated-xpc \
    "${label}" "${helper_executable}" >/dev/null 2>&1; then
  fail "release verifier must reject get-task-allow"
fi

if RIMEAI_CODESIGN_STUB=1 MOCK_SIGNING_MODE=authenticated-xpc \
  MOCK_REQUIREMENT_FAILURE=1 \
  PATH="${mock_bin}:${PATH}" \
  zsh "${validator}" \
    "${bundle}" "${release_plist}" authenticated-xpc \
    "${label}" "${helper_executable}" >/dev/null 2>&1; then
  fail "release verifier must enforce the Developer ID requirement"
fi

if RIMEAI_CODESIGN_STUB=1 MOCK_SIGNING_MODE=authenticated-xpc \
  PATH="${mock_bin}:${PATH}" \
  zsh "${validator}" \
    "${bundle}" "${development_plist}" authenticated-xpc \
    "${label}" "${helper_executable}" >/dev/null 2>&1; then
  fail "release verifier must reject a UDS LaunchAgent"
fi

if RIMEAI_CODESIGN_STUB=1 MOCK_SIGNING_MODE=development-uds \
  PATH="${mock_bin}:${PATH}" \
  zsh "${validator}" \
    "${bundle}" "${release_plist}" development-uds \
    "${socket_file}" "${helper_executable}" >/dev/null 2>&1; then
  fail "development verifier must reject a MachServices LaunchAgent"
fi

[[ ! -e "${HOME}/Library" ]] \
  || fail "verifier test wrote into its isolated HOME"
print 'PASS: voice helper verifier transport/signing checks'
