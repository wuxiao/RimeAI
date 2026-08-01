#!/bin/zsh

set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  print -u2 "usage: $0 APP_BUNDLE [CODE_SIGN_IDENTITY]"
  exit 2
fi

app_bundle=$1
signing_identity=${2:--}
frameworks_dir="${app_bundle}/Contents/Frameworks"
macos_dir="${app_bundle}/Contents/MacOS"
app_executable="${macos_dir}/RimeAIInputMethod"
app_debug_library="${macos_dir}/RimeAIInputMethod.debug.dylib"
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
  keychain_arguments=(
    "--keychain"
    "${RIMEAI_CODE_SIGN_KEYCHAIN}"
  )
fi

if [[ ! -d "${app_bundle}" || ! -f "${app_executable}" ]]; then
  print -u2 "error: RimeAI input method bundle is incomplete"
  exit 2
fi

app_patch_target="${app_executable}"
if [[ -f "${app_debug_library}" ]]; then
  # Xcode 16 and later put Debug code in this dylib and leave a small runner
  # executable in the bundle. Release builds link librime into the executable.
  app_patch_target="${app_debug_library}"
fi

mkdir -p "${frameworks_dir}"

dependency_pairs=(
  "/opt/homebrew/opt/librime/lib/librime.1.dylib|librime.1.dylib"
  "/opt/homebrew/opt/glog/lib/libglog.2.dylib|libglog.2.dylib"
  "/opt/homebrew/opt/yaml-cpp/lib/libyaml-cpp.0.9.dylib|libyaml-cpp.0.9.dylib"
  "/opt/homebrew/opt/gflags/lib/libgflags.2.3.dylib|libgflags.2.3.dylib"
  "/opt/homebrew/opt/leveldb/lib/libleveldb.1.dylib|libleveldb.1.dylib"
  "/opt/homebrew/opt/marisa/lib/libmarisa.0.dylib|libmarisa.0.dylib"
  "/opt/homebrew/opt/opencc/lib/libopencc.1.4.dylib|libopencc.1.4.dylib"
  "/opt/homebrew/opt/snappy/lib/libsnappy.1.dylib|libsnappy.1.dylib"
)

bundled_libraries=()
for pair in "${dependency_pairs[@]}"; do
  fields=("${(@s:|:)pair}")
  source_library=${fields[1]}
  destination_name=${fields[2]}
  destination_library="${frameworks_dir}/${destination_name}"
  if [[ ! -f "${source_library}" ]]; then
    print -u2 "error: required librime dependency is missing: ${source_library}"
    exit 2
  fi
  /bin/cp -fL "${source_library}" "${destination_library}"
  chmod 755 "${destination_library}"
  install_name_tool -id "@rpath/${destination_name}" \
    "${destination_library}"
  bundled_libraries+=("${destination_library}")
done

patch_targets=("${app_patch_target}" "${bundled_libraries[@]}")
for target in "${patch_targets[@]}"; do
  for pair in "${dependency_pairs[@]}"; do
    fields=("${(@s:|:)pair}")
    source_library=${fields[1]}
    destination_name=${fields[2]}
    if otool -L "${target}" | grep -Fq "${source_library}"; then
      install_name_tool -change "${source_library}" \
        "@rpath/${destination_name}" "${target}"
    fi
  done
done

for target in "${bundled_libraries[@]}" "${macos_dir}"/*.dylib(N); do
  codesign --force --sign "${signing_identity}" "${timestamp_argument}" \
    "${keychain_arguments[@]}" --options runtime "${target}"
done
codesign --force --sign "${signing_identity}" "${timestamp_argument}" \
  "${keychain_arguments[@]}" --options runtime "${app_bundle}"
codesign --verify --deep --strict "${app_bundle}"

for target in "${patch_targets[@]}"; do
  if otool -L "${target}" | grep -Fq "/opt/homebrew/"; then
    print -u2 "error: Homebrew dependency remains in ${target}"
    exit 1
  fi
done
