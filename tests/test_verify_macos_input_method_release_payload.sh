#!/bin/zsh

# Static archive-verifier fixture. Tool stubs model a valid arm64 Developer ID
# payload without executing either the input method or the voice helper.

set -euo pipefail

if [[ "${RIMEAI_RELEASE_PAYLOAD_STUB:-0}" == 1 ]]; then
  command_name=${0:t}
  target=${argv[-1]:-}
  case "${command_name}" in
    file)
      case "${target:t}" in
        RimeAIInputMethod|rimeai-voice-helper|rimeai-voice-performance-tracer)
          print -- 'Mach-O 64-bit executable arm64'
          ;;
        *)
          print -- 'data'
          ;;
      esac
      ;;
    lipo)
      print -- arm64
      ;;
    otool)
      print -- "${target}:"
      print -- $'\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1.0.0)'
      ;;
    xcrun)
      print -- 'Load command 1'
      print -- '      cmd LC_BUILD_VERSION'
      print -- ' platform MACOS'
      print -- '    minos 14.0'
      ;;
    nm)
      if [[ "${target:t}" == RimeAIInputMethod ]]; then
        print -- '0000000000000000 T _rai_engine_create'
      fi
      ;;
    codesign)
      case "$1" in
        -dvvv)
          if [[ "${target:t}" == RimeAIVoiceHelper.app ]]; then
            print -u2 -- 'Identifier=fun.wwcn.rimeai.voice-helper'
            print -u2 -- 'Authority=Developer ID Application: Example'
          else
            print -u2 -- 'Identifier=fun.wwcn.inputmethod.RimeAI'
            print -u2 -- 'Authority=Developer ID Application: Example'
          fi
          print -u2 -- 'CodeDirectory v=20500 size=1 flags=0x10000(runtime) hashes=1+1 location=embedded'
          print -u2 -- 'TeamIdentifier=TEAMID1234'
          ;;
        -dvv)
          print -u2 -- 'CodeDirectory v=20500 size=1 flags=0x10000(runtime) hashes=1+1 location=embedded'
          ;;
        -d)
          if [[ "$2" == --entitlements ]]; then
            /bin/cat "${MOCK_ENTITLEMENTS}"
          else
            exit 2
          fi
          ;;
        --verify)
          ;;
        *)
          exit 2
          ;;
      esac
      ;;
    *)
      exit 2
      ;;
  esac
  exit 0
fi

test_root=$(mktemp -d \
  "${TMPDIR:-/tmp}/rimeai-input-release-payload-test.XXXXXX")
cleanup() {
  case "${test_root}" in
    "${TMPDIR:-/tmp}"/rimeai-input-release-payload-test.*)
      find "${test_root}" -depth -delete
      ;;
    *)
      print -u2 "error: refusing to clean unexpected test path: ${test_root}"
      return 1
      ;;
  esac
}
trap cleanup EXIT

test_dir=${0:A:h}
project_root=${test_dir:h}
validator="${project_root}/scripts/verify_macos_input_method_release.sh"
fixture_root="${test_root}/fixture"
app_bundle="${fixture_root}/RimeAIInputMethod.app"
helper_bundle="${app_bundle}/Contents/Helpers/RimeAIVoiceHelper.app"
host_resources="${app_bundle}/Contents/Resources"
helper_resources="${helper_bundle}/Contents/Resources"
voice_resources="${host_resources}/VoiceHelper"
archive_file="${test_root}/RimeAIInputMethod.zip"

fail() {
  print -u2 "FAIL: $1"
  exit 1
}

mkdir -p \
  "${app_bundle}/Contents/MacOS" \
  "${host_resources}/ThirdPartyLicenses" \
  "${voice_resources}" \
  "${helper_bundle}/Contents/MacOS" \
  "${helper_resources}/ThirdPartyLicenses"

/usr/bin/install -m 0644 \
  "${project_root}/macos/RimeAIInputMethod/Info.plist" \
  "${app_bundle}/Contents/Info.plist"
/usr/bin/install -m 0644 \
  "${project_root}/macos/VoiceHelper/Info.plist" \
  "${helper_bundle}/Contents/Info.plist"
for plist in \
  "${app_bundle}/Contents/Info.plist" \
  "${helper_bundle}/Contents/Info.plist"; do
  /usr/libexec/PlistBuddy -c \
    'Set :CFBundleShortVersionString 2.4.6' "${plist}"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 73' "${plist}"
done
/usr/libexec/PlistBuddy -c \
  'Set :CFBundleIdentifier fun.wwcn.inputmethod.RimeAI' \
  "${app_bundle}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c \
  'Set :CFBundleExecutable RimeAIInputMethod' \
  "${app_bundle}/Contents/Info.plist"

print -- fixture > "${app_bundle}/Contents/MacOS/RimeAIInputMethod"
print -- fixture > \
  "${helper_bundle}/Contents/MacOS/rimeai-voice-helper"
chmod 0755 \
  "${app_bundle}/Contents/MacOS/RimeAIInputMethod" \
  "${helper_bundle}/Contents/MacOS/rimeai-voice-helper"

/usr/bin/install -m 0644 "${project_root}/THIRD_PARTY_NOTICES.md" \
  "${host_resources}/THIRD_PARTY_NOTICES.md"
/usr/bin/install -m 0644 "${project_root}/datasets/ATTRIBUTION.md" \
  "${host_resources}/ATTRIBUTION.md"
/usr/bin/install -m 0644 "${project_root}/macos/Resources/RimeAI.pdf" \
  "${host_resources}/RimeAI.pdf"
/usr/bin/install -m 0644 "${project_root}/macos/Resources/RimeAIMenu.pdf" \
  "${host_resources}/RimeAIMenu.pdf"
for license_name in \
  librime-BSD-3-Clause.txt \
  sherpa-onnx-Apache-2.0.txt \
  onnxruntime-MIT.txt \
  onnxruntime-ThirdPartyNotices-1.27.1.txt; do
  /usr/bin/install -m 0644 \
    "${project_root}/ios/ThirdPartyLicenses/${license_name}" \
    "${host_resources}/ThirdPartyLicenses/${license_name}"
done

/usr/bin/install -m 0644 \
  "${project_root}/macos/LaunchAgents/fun.wwcn.rimeai.voice-helper.plist" \
  "${voice_resources}/fun.wwcn.rimeai.voice-helper.plist"
/usr/bin/install -m 0644 \
  "${project_root}/macos/VoiceHelper/VoiceReleasePolicy.plist" \
  "${voice_resources}/VoiceReleasePolicy.plist"
/usr/bin/install -m 0644 \
  "${project_root}/macos/VoiceHelper/VoiceReleasePolicy.plist" \
  "${helper_resources}/VoiceReleasePolicy.plist"
/usr/bin/install -m 0644 "${project_root}/THIRD_PARTY_NOTICES.md" \
  "${helper_resources}/THIRD_PARTY_NOTICES.md"
for license_name in \
  sherpa-onnx-Apache-2.0.txt \
  onnxruntime-MIT.txt \
  onnxruntime-ThirdPartyNotices-1.27.1.txt; do
  /usr/bin/install -m 0644 \
    "${project_root}/ios/ThirdPartyLicenses/${license_name}" \
    "${helper_resources}/ThirdPartyLicenses/${license_name}"
done

mock_bin="${test_root}/mock-bin"
mkdir -p "${mock_bin}"
for command_name in file lipo otool xcrun nm codesign; do
  ln -s "${0:A}" "${mock_bin}/${command_name}"
done
export MOCK_ENTITLEMENTS=\
"${project_root}/macos/VoiceHelper/RimeAIVoiceHelper.entitlements"

build_archive() {
  /bin/rm -f -- "${archive_file}"
  (
    cd "${fixture_root}"
    COPYFILE_DISABLE=1 /usr/bin/zip -qry \
      "${archive_file}" "${app_bundle:t}"
  )
}

build_archive
RIMEAI_RELEASE_PAYLOAD_STUB=1 PATH="${mock_bin}:${PATH}" \
  zsh "${validator}" "${archive_file}" >/dev/null \
  || fail "valid paired Release payload fixture should pass"

expect_archive_rejected() {
  local failure_message=$1
  build_archive
  if RIMEAI_RELEASE_PAYLOAD_STUB=1 PATH="${mock_bin}:${PATH}" \
    zsh "${validator}" "${archive_file}" >/dev/null 2>&1; then
    fail "${failure_message}"
  fi
}

menu_icon="${host_resources}/RimeAIMenu.pdf"
menu_icon_backup="${test_root}/RimeAIMenu.pdf"
/bin/mv "${menu_icon}" "${menu_icon_backup}"
expect_archive_rejected \
  "archive verifier must reject a missing menu icon"
/bin/mv "${menu_icon_backup}" "${menu_icon}"

/usr/bin/install -m 0644 "${host_resources}/RimeAI.pdf" "${menu_icon}"
expect_archive_rejected \
  "archive verifier must reject a menu icon with the 24x18 settings canvas"
/usr/bin/install -m 0644 \
  "${project_root}/macos/Resources/RimeAIMenu.pdf" "${menu_icon}"

menu_icon_key=\
':ComponentInputModeDict:tsInputModeListKey:fun.wwcn.inputmethod.RimeAI.Primary:tsInputModeMenuIconFileKey'
/usr/libexec/PlistBuddy -c \
  "Set ${menu_icon_key} RimeAI.pdf" "${app_bundle}/Contents/Info.plist"
expect_archive_rejected \
  "archive verifier must reject a drifted menu-icon reference"
/usr/libexec/PlistBuddy -c \
  "Set ${menu_icon_key} RimeAIMenu.pdf" "${app_bundle}/Contents/Info.plist"

/usr/libexec/PlistBuddy -c \
  'Set :TISIconIsTemplate false' "${app_bundle}/Contents/Info.plist"
expect_archive_rejected \
  "archive verifier must reject non-template input-source icons"
/usr/libexec/PlistBuddy -c \
  'Set :TISIconIsTemplate true' "${app_bundle}/Contents/Info.plist"

performance_executable=\
"${app_bundle}/Contents/MacOS/rimeai-voice-performance-tracer"
print -- fixture > "${performance_executable}"
chmod 0755 "${performance_executable}"
build_archive
if RIMEAI_RELEASE_PAYLOAD_STUB=1 PATH="${mock_bin}:${PATH}" \
  zsh "${validator}" "${archive_file}" >/dev/null 2>&1; then
  fail "archive verifier must reject an extra signed tracer Mach-O"
fi

print 'PASS: paired Release archive enforces icon and Mach-O contracts'
