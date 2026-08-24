#!/bin/zsh

set -euo pipefail

if [[ $# -ne 1 ]]; then
  print -u2 "usage: $0 RimeAIMacRuntime.xcframework"
  exit 2
fi

script_dir=${0:A:h}
project_root=${script_dir:h}
artifact_root=${1:A}
if [[ ! -d "${artifact_root}" || -L "${artifact_root}" ]]; then
  print -u2 "error: controlled librime artifact must be a real directory"
  exit 2
fi
info_plist="${artifact_root}/Info.plist"
if [[ ! -f "${info_plist}" ]]; then
  print -u2 "error: XCFramework Info.plist is missing"
  exit 2
fi
plutil -lint "${info_plist}" >/dev/null

library_files=("${(@f)$(find "${artifact_root}" -type f \
  -name 'libRimeAIMacRuntime.a')}")
if (( ${#library_files} != 1 )); then
  print -u2 "error: XCFramework must contain one controlled static library"
  exit 1
fi
library_file=${library_files[1]}
headers_dir=${library_file:h}/Headers
if [[ ! -d "${headers_dir}" || -L "${headers_dir}" ]]; then
  print -u2 "error: public librime Headers must be a real directory"
  exit 1
fi
for header_name in rime_api.h rime_api_stdbool.h rime_api_deprecated.h; do
  if [[ ! -f "${headers_dir}/${header_name}" \
    || -L "${headers_dir}/${header_name}" ]]; then
    print -u2 "error: public librime header is missing: ${header_name}"
    exit 1
  fi
done
if [[ "$(lipo -archs "${library_file}")" != "arm64" ]]; then
  print -u2 "error: controlled librime must be arm64-only"
  exit 1
fi

artifact_lock="${artifact_root:h}/artifact-lock.json"
source_lock="${artifact_root:h}/source-lock.json"
if [[ -f "${artifact_lock}" ]]; then
  if [[ ! -f "${source_lock}" ]]; then
    print -u2 "error: controlled librime source lock is missing"
    exit 1
  fi
  expected_artifact=$(plutil -extract artifact raw -o - "${artifact_lock}")
  expected_source_lock_sha=$(
    plutil -extract source_lock_sha256 raw -o - "${artifact_lock}"
  )
  expected_info_sha=$(
    plutil -extract info_plist_sha256 raw -o - "${artifact_lock}"
  )
  expected_library_path=$(
    plutil -extract library.path raw -o - "${artifact_lock}"
  )
  expected_library_size=$(
    plutil -extract library.size_bytes raw -o - "${artifact_lock}"
  )
  expected_library_sha=$(
    plutil -extract library.sha256 raw -o - "${artifact_lock}"
  )
  actual_library_path=${library_file#"${artifact_root}/"}
  actual_library_size=$(stat -f '%z' "${library_file}")
  actual_library_sha=$(shasum -a 256 "${library_file}" | awk '{ print $1 }')
  actual_info_sha=$(shasum -a 256 "${info_plist}" | awk '{ print $1 }')
  actual_source_lock_sha=$(
    shasum -a 256 "${source_lock}" | awk '{ print $1 }'
  )
  header_lock_keys=(
    rime_api
    rime_api_deprecated
    rime_api_stdbool
  )
  for header_key in "${header_lock_keys[@]}"; do
    expected_header_name=$(
      plutil -extract "public_headers.${header_key}.path" raw -o - \
        "${artifact_lock}"
    )
    expected_header_sha=$(
      plutil -extract "public_headers.${header_key}.sha256" raw -o - \
        "${artifact_lock}"
    )
    artifact_header="${headers_dir}/${expected_header_name}"
    canonical_header="${project_root}/ios/Native/include/${expected_header_name}"
    if [[ ! -f "${artifact_header}" || -L "${artifact_header}" \
      || ! -f "${canonical_header}" || -L "${canonical_header}" ]]; then
      print -u2 \
        "error: locked public librime header must be a real file: ${expected_header_name}"
      exit 1
    fi
    actual_header_sha=$(shasum -a 256 "${artifact_header}" | awk '{ print $1 }')
    canonical_header_sha=$(
      shasum -a 256 "${canonical_header}" | awk '{ print $1 }'
    )
    if [[ "${actual_header_sha}" != "${expected_header_sha}" \
      || "${canonical_header_sha}" != "${expected_header_sha}" ]]; then
      print -u2 \
        "error: public librime header does not match its lock: ${expected_header_name}"
      exit 1
    fi
  done
  if [[ "${artifact_root:t}" != "${expected_artifact}" \
    || "${actual_library_path}" != "${expected_library_path}" \
    || "${actual_library_size}" != "${expected_library_size}" \
    || "${actual_library_sha}" != "${expected_library_sha}" \
    || "${actual_info_sha}" != "${expected_info_sha}" \
    || "${actual_source_lock_sha}" != "${expected_source_lock_sha}" ]]; then
    print -u2 "error: controlled librime artifact does not match its lock"
    exit 1
  fi
fi
exported_symbols=$(nm -gU "${library_file}")
if [[ "${exported_symbols}" != *' _rime_get_api'* ]]; then
  print -u2 "error: controlled librime API symbol is missing"
  exit 1
fi
shared_library=$(
  find "${artifact_root}" -type f \
    \( -name '*.dylib' -o -name '*.so' \) -print -quit
)
if [[ -n "${shared_library}" ]]; then
  print -u2 "error: controlled librime artifact contains a shared library"
  exit 1
fi
forbidden_metadata=$(
  find "${artifact_root}" \
    \( -name '._*' -o -name '.DS_Store' \) -print -quit
)
if [[ -n "${forbidden_metadata}" ]]; then
  print -u2 "error: controlled librime contains macOS metadata"
  exit 1
fi

minimum_versions=(
  "${(@f)$(otool -l "${library_file}" \
    | awk '/^[[:space:]]*minos / { print $2 }')}"
)
if (( ${#minimum_versions} == 0 )); then
  print -u2 "error: static librime objects have no deployment target"
  exit 1
fi
for minimum_version in "${minimum_versions[@]}"; do
  if ! awk -v found="${minimum_version}" 'BEGIN {
    split(found, actual, ".")
    if ((actual[1] + 0) > 14) exit 1
    if ((actual[1] + 0) == 14 && (actual[2] + 0) > 0) exit 1
  }'; then
    print -u2 \
      "error: static librime object requires macOS ${minimum_version}"
    exit 1
  fi
done

temporary_root=$(mktemp -d /tmp/rimeai-librime-verify.XXXXXX)
cleanup() {
  case "${temporary_root}" in
    /tmp/rimeai-librime-verify.*) find "${temporary_root}" -depth -delete ;;
    *) print -u2 "error: refusing to clean unexpected verify path" ;;
  esac
}
trap cleanup EXIT
smoke_executable="${temporary_root}/rime-native-smoke"
smoke_user_dir="${temporary_root}/user"
mkdir -m 700 "${smoke_user_dir}"
xcrun clang++ \
  -std=c++17 \
  -arch arm64 \
  -mmacosx-version-min=14.0 \
  -I "${headers_dir}" \
  -I "${project_root}/Sources/RimeBridgeC/include" \
  "${project_root}/Sources/RimeBridgeC/RimeBridgeC.cc" \
  "${project_root}/tools/rime_native_smoke.cc" \
  "${library_file}" \
  -o "${smoke_executable}"
linked_libraries=$(otool -L "${smoke_executable}")
if [[ "${linked_libraries}" == *'/opt/homebrew/'* \
  || "${linked_libraries}" == *'/usr/local/'* ]]; then
  print -u2 "error: controlled librime smoke linked a machine-local library"
  exit 1
fi
"${smoke_executable}" \
  "${project_root}/.rimeai/rime/shared" "${smoke_user_dir}"

print -r -- "library=${library_file}"
print -r -- "architecture=arm64"
print -r -- "minimum_macos=14.0"
print -r -- "shared_libraries=none"
print -r -- "smoke=passed"
