#!/bin/zsh

set -euo pipefail

if [[ $# -lt 1 || $# -gt 3 ]]; then
  print -u2 "usage: $0 OUTPUT.zip [MARKETING_VERSION] [BUILD_NUMBER]"
  exit 2
fi
if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
  print -u2 "error: the macOS release must be built on Apple silicon"
  exit 2
fi
if ! command -v xcodegen >/dev/null 2>&1; then
  print -u2 "error: xcodegen is required"
  exit 2
fi

script_dir=${0:A:h}
project_root=${script_dir:h}
macos_dir="${project_root}/macos"
project_path="${macos_dir}/RimeAIInputMethod.xcodeproj"
output_zip=${1:A}
marketing_version=${2:-0.1.0}
build_number=${3:-20}
signing_identity=${RIMEAI_CODE_SIGN_IDENTITY:-}
if [[ "${output_zip}" != *.zip ]]; then
  print -u2 "error: release output must end in .zip"
  exit 2
fi
if [[ -e "${output_zip}" || -L "${output_zip}" \
  || -e "${output_zip}.sha256" || -L "${output_zip}.sha256" ]]; then
  print -u2 "error: refusing to overwrite release output: ${output_zip}"
  exit 2
fi
if [[ "${signing_identity}" != "Developer ID Application:"* ]]; then
  print -u2 \
    "error: set RIMEAI_CODE_SIGN_IDENTITY to a Developer ID Application identity"
  exit 2
fi
if [[ ! "${marketing_version}" =~ '^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$' \
  || ! "${build_number}" =~ '^[1-9][0-9]*$' ]]; then
  print -u2 "error: invalid marketing version or build number"
  exit 2
fi

mkdir -p "${output_zip:h}"
build_root=$(mktemp -d /tmp/rimeai-input-method-release.XXXXXX)
temporary_zip=$(mktemp "${output_zip:h}/.rimeai-input-method.XXXXXX")
temporary_checksum=$(mktemp "${output_zip:h}/.rimeai-input-method-sha.XXXXXX")
cleanup() {
  case "${build_root}" in
    /tmp/rimeai-input-method-release.*) find "${build_root}" -depth -delete ;;
    *) print -u2 "error: refusing to clean unexpected build path: ${build_root}" ;;
  esac
  for temporary_file in "${temporary_zip}" "${temporary_checksum}"; do
    case "${temporary_file}" in
      "${output_zip:h}"/.rimeai-input-method.*|\
      "${output_zip:h}"/.rimeai-input-method-sha.*)
        [[ ! -f "${temporary_file}" ]] || unlink "${temporary_file}"
        ;;
      *) print -u2 "error: refusing to clean unexpected output path" ;;
    esac
  done
}
trap cleanup EXIT

"${project_root}/scripts/verify_macos_librime.sh" \
  "${macos_dir}/Native/RimeAIMacRuntime.xcframework" >/dev/null
if [[ ! -f "${project_root}/.rimeai/rime/shared/data-lock.json" \
      || ! -f "${project_root}/.rimeai/rime/shared/opencc/t2s.json" \
      || ! -f "${project_root}/.rimeai/rime/shared/opencc/TSCharacters.ocd2" ]]; then
  "${project_root}/scripts/bootstrap_rime_data.sh" >/dev/null
fi
dot_clean -m "${macos_dir}" "${project_root}/Sources" \
  "${project_root}/.rimeai/rime/shared" >/dev/null 2>&1 || true
xcodegen generate --spec "${macos_dir}/project.yml" \
  --project "${macos_dir}" >/dev/null

COPYFILE_DISABLE=1 xcodebuild \
  -project "${project_path}" \
  -scheme RimeAIInputMethod \
  -configuration Release \
  -derivedDataPath "${build_root}/DerivedData" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM= \
  CODE_SIGN_IDENTITY=- \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  COPY_PHASE_STRIP=NO \
  STRIP_INSTALLED_PRODUCT=NO \
  clean build >/dev/null

app_bundle="${build_root}/DerivedData/Build/Products/Release/RimeAIInputMethod.app"
if [[ ! -d "${app_bundle}" ]]; then
  print -u2 "error: Xcode did not produce the input method bundle"
  exit 1
fi
/usr/libexec/PlistBuddy -c \
  "Set :CFBundleShortVersionString ${marketing_version}" \
  "${app_bundle}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c \
  "Set :CFBundleVersion ${build_number}" \
  "${app_bundle}/Contents/Info.plist"
find "${app_bundle}" \( -name '._*' -o -name '.DS_Store' \) -delete
find "${app_bundle}" -exec xattr -c {} + 2>/dev/null || true

RIMEAI_CODE_SIGN_KEYCHAIN=${RIMEAI_CODE_SIGN_KEYCHAIN:-} \
  "${project_root}/script/bundle_librime_dependencies.sh" \
    "${app_bundle}" "${signing_identity}" >/dev/null
codesign --verify --deep --strict "${app_bundle}"

# The Release ZIP is a paired product artifact.  Keep the voice helper as a
# nested, independently signed App so it retains its TCC identity and exact
# audio-input entitlement while the distribution stays one top-level bundle.
RIMEAI_CODE_SIGN_KEYCHAIN=${RIMEAI_CODE_SIGN_KEYCHAIN:-} \
  "${project_root}/script/install_voice_helper.sh" \
    --signing-identity "${signing_identity}" \
    --marketing-version "${marketing_version}" \
    --build-number "${build_number}" \
    --build-only >/dev/null
staged_helper="${project_root}/.build/voice-helper/RimeAIVoiceHelper.app"
staged_launch_agent=\
"${project_root}/macos/LaunchAgents/fun.wwcn.rimeai.voice-helper.plist"
voice_policy="${project_root}/macos/VoiceHelper/VoiceReleasePolicy.plist"
staged_helper_policy=\
"${staged_helper}/Contents/Resources/VoiceReleasePolicy.plist"
embedded_helper=\
"${app_bundle}/Contents/Helpers/RimeAIVoiceHelper.app"
embedded_voice_resources="${app_bundle}/Contents/Resources/VoiceHelper"
if [[ ! -d "${staged_helper}" || -L "${staged_helper}" \
  || ! -f "${staged_launch_agent}" || ! -f "${voice_policy}" \
  || ! -f "${staged_helper_policy}" || -L "${staged_helper_policy}" ]]; then
  print -u2 "error: paired voice Release payload is incomplete"
  exit 1
fi
if ! cmp -s "${voice_policy}" "${staged_helper_policy}"; then
  print -u2 "error: paired voice Release payload is incomplete"
  exit 1
fi
mkdir -p "${embedded_helper:h}" "${embedded_voice_resources}"
COPYFILE_DISABLE=1 ditto --norsrc "${staged_helper}" "${embedded_helper}"
find "${embedded_helper}" -name '._*' -type f -delete
codesign --verify --deep --strict "${embedded_helper}"
install -m 0644 "${staged_launch_agent}" \
  "${embedded_voice_resources}/fun.wwcn.rimeai.voice-helper.plist"
install -m 0644 "${staged_helper_policy}" \
  "${embedded_voice_resources}/VoiceReleasePolicy.plist"
if ! cmp -s \
  "${embedded_helper}/Contents/Resources/VoiceReleasePolicy.plist" \
  "${embedded_voice_resources}/VoiceReleasePolicy.plist"; then
  print -u2 "error: nested and host voice Release policies diverged"
  exit 1
fi

outer_codesign_arguments=(
  --force
  --sign "${signing_identity}"
  --options runtime
  --timestamp=http://timestamp.apple.com/ts01
)
if [[ -n "${RIMEAI_CODE_SIGN_KEYCHAIN:-}" ]]; then
  outer_codesign_arguments+=(--keychain "${RIMEAI_CODE_SIGN_KEYCHAIN}")
fi
codesign "${outer_codesign_arguments[@]}" "${app_bundle}"
codesign --verify --deep --strict "${app_bundle}"
for required_resource in \
  THIRD_PARTY_NOTICES.md \
  ATTRIBUTION.md \
  ThirdPartyLicenses/librime-BSD-3-Clause.txt \
  ThirdPartyLicenses/sherpa-onnx-Apache-2.0.txt \
  ThirdPartyLicenses/onnxruntime-MIT.txt \
  ThirdPartyLicenses/onnxruntime-ThirdPartyNotices-1.27.1.txt; do
  if [[ ! -f "${app_bundle}/Contents/Resources/${required_resource}" ]]; then
    print -u2 "error: release attribution is missing: ${required_resource}"
    exit 1
  fi
done

COPYFILE_DISABLE=1 ditto --norsrc -c -k --keepParent \
  "${app_bundle}" "${temporary_zip}"
"${project_root}/scripts/verify_macos_input_method_release.sh" \
  "${temporary_zip}" "${signing_identity}" >/dev/null
archive_sha=$(shasum -a 256 "${temporary_zip}" | awk '{ print $1 }')
print -r -- "${archive_sha}  ${output_zip:t}" >"${temporary_checksum}"
/bin/mv "${temporary_zip}" "${output_zip}"
/bin/mv "${temporary_checksum}" "${output_zip}.sha256"

print -r -- "release=${output_zip}"
print -r -- "sha256=${archive_sha}"
print -r -- "version=${marketing_version}"
print -r -- "build=${build_number}"
print -r -- "architecture=arm64"
print -r -- "minimum_macos=14.0"
print -r -- "signing_identity=${signing_identity}"
print -r -- "paired_voice_helper=embedded"
print -r -- "voice_release_eligible=false"
