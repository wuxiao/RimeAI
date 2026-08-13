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

# Deliberately use plain unzip here. This is the extraction path that exposes
# AppleDouble entries which macOS-native ditto extraction can hide or merge.
unzip -qq "${archive_file}" -d "${temporary_root}"
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
if [[ ! -x "${app_executable}" ]]; then
  print -u2 "error: input-method executable is missing or not executable"
  exit 1
fi
if [[ -n "$(find "${app_bundle}" \
  \( -name '._*' -o -name '.DS_Store' \) -print -quit)" ]]; then
  print -u2 "error: extracted app contains forbidden macOS metadata"
  exit 1
fi

for required_resource in \
  THIRD_PARTY_NOTICES.md ATTRIBUTION.md ThirdPartyLicenses/librime-BSD-3-Clause.txt; do
  if [[ ! -f "${app_bundle}/Contents/Resources/${required_resource}" ]]; then
    print -u2 "error: release attribution is missing: ${required_resource}"
    exit 1
  fi
done

mach_o_count=0
bridge_found=false
while IFS= read -r -d '' target_file; do
  if ! file -b "${target_file}" | grep -q 'Mach-O'; then
    continue
  fi
  (( mach_o_count += 1 ))
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

if (( mach_o_count == 0 )); then
  print -u2 "error: input-method archive contains no Mach-O files"
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

print -r -- "archive_sha256=$(shasum -a 256 "${archive_file}" | awk '{ print $1 }')"
print -r -- "app=${app_bundle:t}"
print -r -- "macho_files=${mach_o_count}"
print -r -- "architecture=arm64"
print -r -- "minimum_macos=14.0"
print -r -- "appledouble=none"
print -r -- "plain_unzip_codesign=verified"
print -r -- "hardened_runtime=verified"
