#!/bin/zsh

set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  print -u2 "usage: $0 INPUT_METHOD.zip [EXPECTED_SIGNING_IDENTITY]"
  exit 2
fi
if [[ "$(uname -s)" != "Darwin" ]]; then
  print -u2 "error: input-method release verification requires macOS"
  exit 2
fi

archive_file=${1:A}
expected_signing_identity=${2:-}
script_dir=${0:A:h}
project_root=${script_dir:h}
if [[ ! -f "${archive_file}" || -L "${archive_file}" ]]; then
  print -u2 "error: expected a regular input-method ZIP archive"
  exit 2
fi

checksum_file="${archive_file}.sha256"
if [[ -f "${checksum_file}" ]]; then
  expected_sha=$(awk 'NR == 1 { print $1 }' "${checksum_file}")
  actual_sha=$(shasum -a 256 "${archive_file}" | awk '{ print $1 }')
  if [[ "${expected_sha}" != "${actual_sha}" ]]; then
    print -u2 "error: input-method archive checksum mismatch"
    exit 1
  fi
fi

temporary_root=$(mktemp -d /tmp/rimeai-input-method-verify.XXXXXX)
cleanup() {
  case "${temporary_root}" in
    /tmp/rimeai-input-method-verify.*)
      find "${temporary_root}" -depth -delete
      ;;
    *)
      print -u2 "error: refusing to clean unexpected path: ${temporary_root}"
      return 1
      ;;
  esac
}
trap cleanup EXIT

archive_entries=("${(@f)$(unzip -Z1 "${archive_file}")}")
if (( ${#archive_entries} == 0 )); then
  print -u2 "error: input-method archive is empty"
  exit 1
fi
for archive_entry in "${archive_entries[@]}"; do
  if [[ "${archive_entry}" == /* \
    || "/${archive_entry}/" == *'/../'* \
    || "${archive_entry}" == ._* \
    || "${archive_entry}" == */._* \
    || "${archive_entry}" == '.DS_Store' \
    || "${archive_entry}" == */.DS_Store ]]; then
    print -u2 "error: unsafe or forbidden path in archive: ${archive_entry}"
    exit 1
  fi
done
if zipinfo -l "${archive_file}" | awk '
  substr($1, 1, 1) == "l" { found = 1 }
  END { exit(found ? 0 : 1) }
'; then
  print -u2 "error: symbolic links are forbidden in the input-method archive"
  exit 1
fi

# Deliberately use plain unzip here. This is the extraction path that exposes
# AppleDouble entries which macOS-native ditto extraction can hide or merge.
unzip -qq "${archive_file}" -d "${temporary_root}"
if [[ -n "$(find "${temporary_root}" -type l -print -quit)" ]]; then
  print -u2 "error: extracted input-method archive contains a symbolic link"
  exit 1
fi
top_level_entries=("${temporary_root}"/*(DN))
if (( ${#top_level_entries} != 1 )) \
  || [[ ! -d "${top_level_entries[1]}" \
  || -L "${top_level_entries[1]}" \
  || "${top_level_entries[1]:t}" != *.app ]]; then
  print -u2 "error: archive must contain exactly one top-level app bundle"
  exit 1
fi
app_bundle=${top_level_entries[1]}
app_executable="${app_bundle}/Contents/MacOS/RimeAIInputMethod"
embedded_helper=\
"${app_bundle}/Contents/Helpers/RimeAIVoiceHelper.app"
embedded_helper_executable=\
"${embedded_helper}/Contents/MacOS/rimeai-voice-helper"
embedded_voice_resources="${app_bundle}/Contents/Resources/VoiceHelper"
embedded_launch_agent=\
"${embedded_voice_resources}/fun.wwcn.rimeai.voice-helper.plist"
embedded_voice_policy=\
"${embedded_voice_resources}/VoiceReleasePolicy.plist"
embedded_helper_policy=\
"${embedded_helper}/Contents/Resources/VoiceReleasePolicy.plist"
if [[ ! -x "${app_executable}" ]]; then
  print -u2 "error: input-method executable is missing or not executable"
  exit 1
fi
if [[ ! -d "${embedded_helper}" || -L "${embedded_helper}" \
  || ! -x "${embedded_helper_executable}" \
  || ! -f "${embedded_launch_agent}" || -L "${embedded_launch_agent}" \
  || ! -f "${embedded_voice_policy}" || -L "${embedded_voice_policy}" \
  || ! -f "${embedded_helper_policy}" || -L "${embedded_helper_policy}" ]]; then
  print -u2 "error: paired voice Release payload is missing or unsafe"
  exit 1
fi
if ! cmp -s "${embedded_voice_policy}" "${embedded_helper_policy}"; then
  print -u2 "error: paired voice Release payload is missing or unsafe"
  exit 1
fi
if [[ -n "$(find "${app_bundle}" \
  \( -name '._*' -o -name '.DS_Store' \) -print -quit)" ]]; then
  print -u2 "error: extracted app contains forbidden macOS metadata"
  exit 1
fi

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

input_method_info="${app_bundle}/Contents/Info.plist"
for icon_name in RimeAI.pdf RimeAIMenu.pdf; do
  packaged_icon="${app_bundle}/Contents/Resources/${icon_name}"
  controlled_icon="${project_root}/macos/Resources/${icon_name}"
  if [[ ! -f "${packaged_icon}" || -L "${packaged_icon}" ]]; then
    print -u2 "error: input-source icon is missing or unsafe: ${icon_name}"
    exit 1
  fi
  if ! cmp -s "${packaged_icon}" "${controlled_icon}"; then
    print -u2 "error: packaged input-source icon drifted: ${icon_name}"
    exit 1
  fi
done

verify_icon_dimensions() {
  local icon_path=$1
  local expected_width=$2
  local expected_height=$3
  local properties width height
  if ! properties=$(sips -g pixelWidth -g pixelHeight "${icon_path}" 2>/dev/null); then
    print -u2 "error: cannot inspect input-source icon: ${icon_path:t}"
    exit 1
  fi
  width=$(print -r -- "${properties}" | awk '/pixelWidth:/ { print $2 }')
  height=$(print -r -- "${properties}" | awk '/pixelHeight:/ { print $2 }')
  if ! awk -v width="${width}" -v height="${height}" \
    -v expected_width="${expected_width}" \
    -v expected_height="${expected_height}" 'BEGIN {
      exit !((width + 0) == (expected_width + 0) \
        && (height + 0) == (expected_height + 0))
    }'; then
    print -u2 \
      "error: unexpected input-source icon canvas: ${icon_path:t} "\
"(${width}x${height})"
    exit 1
  fi
}
verify_icon_dimensions \
  "${app_bundle}/Contents/Resources/RimeAI.pdf" 24 18
verify_icon_dimensions \
  "${app_bundle}/Contents/Resources/RimeAIMenu.pdf" 16 16

if ! icon_is_template=$(/usr/libexec/PlistBuddy \
  -c 'Print :TISIconIsTemplate' "${input_method_info}" 2>/dev/null) \
  || [[ "${icon_is_template}" != true ]]; then
  print -u2 "error: input-source icons must be configured as templates"
  exit 1
fi
icon_contracts=(
  ':tsInputMethodIconFileKey=RimeAI.pdf'
  ':ComponentInputModeDict:tsInputModeListKey:fun.wwcn.inputmethod.RimeAI.Primary:tsInputModeMenuIconFileKey=RimeAIMenu.pdf'
  ':ComponentInputModeDict:tsInputModeListKey:fun.wwcn.inputmethod.RimeAI.Primary:tsInputModeAlternateMenuIconFileKey=RimeAIMenu.pdf'
  ':ComponentInputModeDict:tsInputModeListKey:fun.wwcn.inputmethod.RimeAI.Primary:tsInputModePaletteIconFileKey=RimeAI.pdf'
)
for icon_contract in "${icon_contracts[@]}"; do
  plist_path=${icon_contract%%=*}
  expected_icon=${icon_contract#*=}
  if ! actual_icon=$(/usr/libexec/PlistBuddy \
    -c "Print ${plist_path}" "${input_method_info}" 2>/dev/null) \
    || [[ "${actual_icon}" != "${expected_icon}" ]]; then
    print -u2 \
      "error: input-source icon reference drifted: ${plist_path}"
    exit 1
  fi
done

mach_o_count=0
bridge_found=false
host_executable_mach_o_found=false
helper_executable_mach_o_found=false
while IFS= read -r -d '' target_file; do
  if ! file -b "${target_file}" | grep -q 'Mach-O'; then
    continue
  fi
  (( mach_o_count += 1 ))
  relative_mach_o_path=${target_file#${app_bundle}/}
  case "${relative_mach_o_path}" in
    Contents/MacOS/RimeAIInputMethod)
      host_executable_mach_o_found=true
      ;;
    Contents/Helpers/RimeAIVoiceHelper.app/Contents/MacOS/rimeai-voice-helper)
      helper_executable_mach_o_found=true
      ;;
    *)
      print -u2 \
        "error: unapproved Mach-O path in formal Release payload: "\
"${relative_mach_o_path}"
      exit 1
      ;;
  esac
  if [[ "$(lipo -archs "${target_file}")" != "arm64" ]]; then
    print -u2 "error: input-method Mach-O must be arm64: ${target_file}"
    exit 1
  fi
  linked_libraries=$(otool -L "${target_file}")
  if [[ "${linked_libraries}" == *'/opt/homebrew/'* \
    || "${linked_libraries}" == *'/usr/local/'* ]]; then
    print -u2 "error: machine-local dependency remains in ${target_file}"
    exit 1
  fi
  minimum_versions=(
    "${(@f)$(xcrun vtool -show-build "${target_file}" \
      | awk '/^[[:space:]]*minos / { print $2 }')}"
  )
  if (( ${#minimum_versions} == 0 )); then
    print -u2 "error: input-method Mach-O has no deployment target: ${target_file}"
    exit 1
  fi
  for minimum_version in "${minimum_versions[@]}"; do
    if ! awk -v found="${minimum_version}" 'BEGIN {
      split(found, actual, ".")
      if ((actual[1] + 0) > 14) exit 1
      if ((actual[1] + 0) == 14 && (actual[2] + 0) > 0) exit 1
    }'; then
      print -u2 \
        "error: ${target_file} requires macOS ${minimum_version}, expected 14.0"
      exit 1
    fi
  done
  if ! codesign --verify --strict "${target_file}" >/dev/null 2>&1; then
    print -u2 "error: invalid code signature: ${target_file}"
    exit 1
  fi
  signature_details=$(codesign -dvv "${target_file}" 2>&1)
  if [[ "${signature_details}" != *'flags='*'runtime'* ]]; then
    print -u2 "error: hardened runtime is missing: ${target_file}"
    exit 1
  fi
  if nm -gU "${target_file}" 2>/dev/null | grep -q ' _rai_engine_create'; then
    bridge_found=true
  fi
done < <(find "${app_bundle}/Contents" -type f -print0)

if (( mach_o_count != 2 )) \
  || [[ "${host_executable_mach_o_found}" != true \
  || "${helper_executable_mach_o_found}" != true ]]; then
  print -u2 \
    "error: formal Release payload must contain exactly the input method "\
"and paired helper Mach-O executables"
  exit 1
fi
if [[ "${bridge_found}" != true ]]; then
  print -u2 "error: controlled librime bridge is missing from the app"
  exit 1
fi
codesign --verify --deep --strict "${app_bundle}"
app_signature=$(codesign -dvvv "${app_bundle}" 2>&1)
if [[ -n "${expected_signing_identity}" \
  && "${app_signature}" != *"Authority=${expected_signing_identity}"* ]]; then
  print -u2 "error: signing identity does not match the expected identity"
  exit 1
fi

"${project_root}/script/verify_voice_release_policy.sh" \
  "${app_bundle}/Contents/Info.plist" \
  "${embedded_helper}/Contents/Info.plist" \
  "${embedded_voice_policy}" >/dev/null

host_team=$(print -r -- "${app_signature}" | sed -n 's/^TeamIdentifier=//p')
helper_signature=$(codesign -dvvv "${embedded_helper}" 2>&1)
helper_team=$(print -r -- "${helper_signature}" \
  | sed -n 's/^TeamIdentifier=//p')
if ! print -r -- "${host_team}" | grep -Eq '^[A-Z0-9]{10}$' \
  || [[ "${helper_team}" != "${host_team}" ]]; then
  print -u2 "error: input method and voice helper must use the same TeamIdentifier"
  exit 1
fi
host_requirement=\
"anchor apple generic and identifier \"fun.wwcn.inputmethod.RimeAI\" and "\
"certificate 1[field.1.2.840.113635.100.6.2.6] exists and "\
"certificate leaf[field.1.2.840.113635.100.6.1.13] exists and "\
"certificate leaf[subject.OU] = \"${host_team}\""
if ! codesign --verify --strict --verbose=2 \
  -R="${host_requirement}" "${app_bundle}"; then
  print -u2 "error: input method does not satisfy the Developer ID requirement"
  exit 1
fi

plutil -lint "${embedded_launch_agent}" >/dev/null

rendered_launch_agent="${temporary_root}/voice-helper.plist"
release_home="/Users/RimeAIReleaseVerifier"
host_build=$(plutil -extract CFBundleVersion raw \
  -o - "${app_bundle}/Contents/Info.plist")
voice_policy_sha256=$(shasum -a 256 "${embedded_voice_policy}" \
  | awk '{ print $1 }')
installed_helper=\
"${release_home}/Library/Input Methods/RimeAIInputMethod.app/Contents/Helpers/RimeAIVoiceHelper.app"
installed_executable=\
"${installed_helper}/Contents/MacOS/rimeai-voice-helper"
sed \
  -e "s|__HELPER_APP__|${installed_helper}|g" \
  -e 's|__TRANSPORT_FLAG__|--mach-service|g' \
  -e 's|__TRANSPORT_ENDPOINT__|fun.wwcn.rimeai.voice-helper|g' \
  -e "s|__ENABLED_MARKER__|${release_home}/Library/Caches/RimeAI/voice-enabled|g" \
  -e "s|__LOG_PATH__|${release_home}/Library/Application Support/RimeAI/runtime/rimeai-voice-helper.log|g" \
  -e "s|__HOST_BUILD__|${host_build}|g" \
  -e "s|__VOICE_POLICY_SHA256__|${voice_policy_sha256}|g" \
  "${embedded_launch_agent}" \
  | sed -e '/__ENGINE_FLAG__/d' -e '/__ENGINE_NAME__/d' \
  >"${rendered_launch_agent}"
"${project_root}/script/verify_voice_helper_bundle.sh" \
  "${embedded_helper}" \
  "${rendered_launch_agent}" \
  authenticated-xpc \
  fun.wwcn.rimeai.voice-helper \
  "${installed_executable}" >/dev/null

print -r -- "archive_sha256=$(shasum -a 256 "${archive_file}" | awk '{ print $1 }')"
print -r -- "app=${app_bundle:t}"
print -r -- "macho_files=${mach_o_count}"
print -r -- "architecture=arm64"
print -r -- "minimum_macos=14.0"
print -r -- "appledouble=none"
print -r -- "plain_unzip_codesign=verified"
print -r -- "hardened_runtime=verified"
print -r -- "paired_voice_helper=verified"
print -r -- "voice_release_eligible=false"
