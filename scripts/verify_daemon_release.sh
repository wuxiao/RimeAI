#!/bin/zsh

set -euo pipefail

if [[ $# -ne 1 ]]; then
  print -u2 "usage: $0 RELEASE_ROOT"
  exit 2
fi

release_root=${1:A}
if [[ ! -d "${release_root}" || -L "${release_root}" ]]; then
  print -u2 "error: release root must be a real directory: ${release_root}"
  exit 2
fi

manifest_file="${release_root}/manifest.json"
checksums_file="${release_root}/SHA256SUMS"
daemon_executable="${release_root}/runtime/rimeai-daemon/rimeai-daemon"
cloud_broker_executable="${release_root}/runtime/rimeai-cloud-broker/rimeai-cloud-broker"
for required_file in \
  "${manifest_file}" \
  "${checksums_file}" \
  "${daemon_executable}" \
  "${cloud_broker_executable}"; do
  if [[ ! -f "${required_file}" ]]; then
    print -u2 "error: required release file is missing: ${required_file}"
    exit 2
  fi
done

schema_version=$(plutil -extract schema_version raw -o - "${manifest_file}")
artifact_type=$(plutil -extract artifact_type raw -o - "${manifest_file}")
artifact_id=$(plutil -extract artifact_id raw -o - "${manifest_file}")
target_platform=$(plutil -extract target.platform raw -o - "${manifest_file}")
target_architecture=$(
  plutil -extract target.architecture raw -o - "${manifest_file}"
)
minimum_macos=$(
  plutil -extract target.minimum_macos_version raw -o - "${manifest_file}"
)
if [[ "${schema_version}" != "1" \
  || "${artifact_type}" != "rimeai-daemon-release" \
  || "${artifact_id}" != rimeai-daemon-release:* \
  || "${target_platform}" != "macos" \
  || "${target_architecture}" != "arm64" \
  || "${minimum_macos}" != "14.0" ]]; then
  print -u2 "error: release manifest target or identity is invalid"
  exit 1
fi

temporary_root=$(mktemp -d /tmp/rimeai-release-verify.XXXXXX)
cleanup() {
  case "${temporary_root}" in
    /tmp/rimeai-release-verify.*)
      find "${temporary_root}" -depth -delete
      ;;
    *)
      print -u2 "error: refusing to clean unexpected path: ${temporary_root}"
      return 1
      ;;
  esac
}
trap cleanup EXIT

(
  cd "${release_root}"
  shasum -a 256 -c SHA256SUMS >/dev/null
  awk 'length($0) >= 67 { print substr($0, 67) }' SHA256SUMS \
    | LC_ALL=C sort > "${temporary_root}/listed-files.txt"
  find . -type f ! -name SHA256SUMS -print \
    | sed 's#^\./##' \
    | LC_ALL=C sort > "${temporary_root}/actual-files.txt"
)
if ! cmp -s \
  "${temporary_root}/listed-files.txt" \
  "${temporary_root}/actual-files.txt"; then
  print -u2 "error: SHA256SUMS does not describe the exact regular-file set"
  diff -u \
    "${temporary_root}/listed-files.txt" \
    "${temporary_root}/actual-files.txt" >&2 || true
  exit 1
fi

forbidden_metadata=$(
  find "${release_root}" \
    \( -name '._*' -o -name '.DS_Store' \) -print -quit
)
if [[ -n "${forbidden_metadata}" ]]; then
  print -u2 "error: release contains forbidden macOS metadata"
  exit 1
fi

while IFS= read -r -d '' link_file; do
  link_target=$(readlink "${link_file}")
  if [[ "${link_target}" == /* || ! -e "${link_file}" ]]; then
    print -u2 "error: absolute or dangling release symlink: ${link_file}"
    exit 1
  fi
  resolved_target=${link_file:A}
  case "${resolved_target}" in
    "${release_root}"/*) ;;
    *)
      print -u2 "error: release symlink escapes its root: ${link_file}"
      exit 1
      ;;
  esac
done < <(find "${release_root}" -type l -print0)

macho_count=0
while IFS= read -r -d '' target_file; do
  if ! file -b "${target_file}" | grep -q 'Mach-O'; then
    continue
  fi
  (( macho_count += 1 ))
  architectures=$(lipo -archs "${target_file}")
  if [[ "${architectures}" != "arm64" ]]; then
    print -u2 \
      "error: release Mach-O is not arm64-only: ${target_file} (${architectures})"
    exit 1
  fi
  linked_libraries=$(otool -L "${target_file}")
  if [[ "${linked_libraries}" == *'/opt/homebrew/'* \
    || "${linked_libraries}" == *'/usr/local/'* ]]; then
    print -u2 "error: release contains a development-machine dylib path: ${target_file}"
    exit 1
  fi
  build_versions=(
    "${(@f)$(xcrun vtool -show-build "${target_file}" \
      | awk '/^[[:space:]]*minos / { print $2 }')}"
  )
  if (( ${#build_versions} == 0 )); then
    print -u2 "error: Mach-O has no LC_BUILD_VERSION minimum: ${target_file}"
    exit 1
  fi
  for build_version in "${build_versions[@]}"; do
    if ! awk -v found="${build_version}" 'BEGIN {
      split(found, actual, ".")
      if ((actual[1] + 0) > 14) exit 1
      if ((actual[1] + 0) == 14 && (actual[2] + 0) > 0) exit 1
    }'; then
      print -u2 \
        "error: Mach-O minimum ${build_version} exceeds macOS 14.0: ${target_file}"
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
done < <(find "${release_root}/runtime" -type f -print0)

if (( macho_count == 0 )); then
  print -u2 "error: release contains no Mach-O runtime"
  exit 1
fi
if [[ ! -x "${daemon_executable}" ]]; then
  print -u2 "error: daemon entry point is not executable"
  exit 1
fi
if [[ ! -x "${cloud_broker_executable}" ]]; then
  print -u2 "error: cloud broker entry point is not executable"
  exit 1
fi
daemon_entitlements=$(
  codesign -d --entitlements - "${daemon_executable}" 2>&1
)
if [[ "${daemon_entitlements}" \
  != *'com.apple.security.cs.disable-library-validation'* ]]; then
  print -u2 "error: daemon library-validation entitlement is missing"
  exit 1
fi
"${daemon_executable}" --help >/dev/null
cloud_broker_entitlements=$(
  codesign -d --entitlements - "${cloud_broker_executable}" 2>&1
)
if [[ "${cloud_broker_entitlements}" \
  != *'com.apple.security.cs.disable-library-validation'* ]]; then
  print -u2 "error: cloud broker library-validation entitlement is missing"
  exit 1
fi
"${cloud_broker_executable}" --help >/dev/null

print -r -- "artifact_id=${artifact_id}"
print -r -- "macho_files=${macho_count}"
print -r -- "architecture=arm64"
print -r -- "minimum_macos=14.0"
print -r -- "checksums=verified"
print -r -- "hardened_runtime=verified"
print -r -- "library_validation=manifest_locked_embedded_runtime"
