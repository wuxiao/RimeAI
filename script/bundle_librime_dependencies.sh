#!/bin/zsh

# The historical name is retained for callers. librime is now linked from the
# repository-controlled static XCFramework, so this script verifies and signs;
# it never copies libraries from Homebrew or another machine-local prefix.
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  print -u2 "usage: $0 APP_BUNDLE [CODE_SIGN_IDENTITY]"
  exit 2
fi

app_bundle=${1:A}
signing_identity=${2:--}
macos_dir="${app_bundle}/Contents/MacOS"
app_executable="${macos_dir}/RimeAIInputMethod"
timestamp_argument="--timestamp=none"
keychain_arguments=()

if [[ "${signing_identity}" == "Developer ID Application:"* ]]; then
  timestamp_argument="--timestamp=http://timestamp.apple.com/ts01"
fi
if [[ -n "${RIMEAI_CODE_SIGN_KEYCHAIN:-}" ]]; then
  if [[ ! -f "${RIMEAI_CODE_SIGN_KEYCHAIN}" ]]; then
    print -u2 \
      "error: signing keychain does not exist: ${RIMEAI_CODE_SIGN_KEYCHAIN}"
    exit 2
  fi
  keychain_arguments=("--keychain" "${RIMEAI_CODE_SIGN_KEYCHAIN}")
fi
if [[ ! -d "${app_bundle}" || ! -f "${app_executable}" ]]; then
  print -u2 "error: RimeAI input method bundle is incomplete"
  exit 2
fi

mach_o_files=()
while IFS= read -r candidate; do
  if file -b "${candidate}" | grep -q 'Mach-O'; then
    mach_o_files+=("${candidate}")
  fi
done < <(find "${app_bundle}/Contents" -type f -print | sort)
if (( ${#mach_o_files} == 0 )); then
  print -u2 "error: input method bundle contains no Mach-O files"
  exit 1
fi

bridge_found=false
for target in "${mach_o_files[@]}"; do
  linked_libraries=$(otool -L "${target}")
  if [[ "${linked_libraries}" == *'/opt/homebrew/'* \
    || "${linked_libraries}" == *'/usr/local/'* ]]; then
    print -u2 "error: machine-local dependency remains in ${target}"
    exit 1
  fi
  if [[ "$(lipo -archs "${target}")" != "arm64" ]]; then
    print -u2 "error: input method Mach-O must be arm64: ${target}"
    exit 1
  fi
  minimum_versions=(
    "${(@f)$(otool -l "${target}" \
      | awk '/^[[:space:]]*minos / { print $2 }')}"
  )
  if (( ${#minimum_versions} == 0 )); then
    print -u2 "error: input method Mach-O has no deployment target: ${target}"
    exit 1
  fi
  for minimum_version in "${minimum_versions[@]}"; do
    if ! awk -v found="${minimum_version}" 'BEGIN {
      split(found, actual, ".")
      if ((actual[1] + 0) > 14) exit 1
      if ((actual[1] + 0) == 14 && (actual[2] + 0) > 0) exit 1
    }'; then
      print -u2 \
        "error: ${target} requires macOS ${minimum_version}, expected 14.0"
      exit 1
    fi
  done
  if nm -gU "${target}" 2>/dev/null | grep -q ' _rai_engine_create'; then
    bridge_found=true
  fi
done
if [[ "${bridge_found}" != true ]]; then
  print -u2 "error: controlled librime bridge was not linked into the app"
  exit 1
fi

for target in "${mach_o_files[@]}"; do
  codesign --force --sign "${signing_identity}" "${timestamp_argument}" \
    "${keychain_arguments[@]}" --options runtime "${target}"
done
codesign --force --sign "${signing_identity}" "${timestamp_argument}" \
  "${keychain_arguments[@]}" --options runtime "${app_bundle}"
codesign --verify --deep --strict "${app_bundle}"

print -r -- "mach_o_count=${#mach_o_files}"
print -r -- "architecture=arm64"
print -r -- "minimum_macos=14.0"
print -r -- "machine_local_dependencies=none"
print -r -- "controlled_librime=linked"
