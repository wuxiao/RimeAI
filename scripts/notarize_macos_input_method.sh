#!/bin/zsh

set -euo pipefail

if [[ $# -ne 2 ]]; then
  print -u2 "usage: $0 SIGNED_INPUT_METHOD.zip NOTARIZED_OUTPUT.zip"
  exit 2
fi
if [[ "$(uname -s)" != "Darwin" ]]; then
  print -u2 "error: notarization requires macOS"
  exit 2
fi

input_zip=${1:A}
output_zip=${2:A}
notary_profile=${RIMEAI_NOTARY_PROFILE:-}
if [[ ! -f "${input_zip}" || -L "${input_zip}" \
  || "${input_zip}" != *.zip || "${output_zip}" != *.zip ]]; then
  print -u2 "error: input and output must be regular .zip paths"
  exit 2
fi
if [[ -z "${notary_profile}" ]]; then
  print -u2 \
    "error: set RIMEAI_NOTARY_PROFILE to an xcrun notarytool keychain profile"
  exit 2
fi
if [[ -e "${output_zip}" || -L "${output_zip}" \
  || -e "${output_zip}.sha256" || -L "${output_zip}.sha256" ]]; then
  print -u2 "error: refusing to overwrite notarized output: ${output_zip}"
  exit 2
fi

mkdir -p "${output_zip:h}"
work_root=$(mktemp -d /tmp/rimeai-input-method-notary.XXXXXX)
temporary_zip=$(mktemp "${output_zip:h}/.rimeai-notarized.XXXXXX")
temporary_checksum=$(mktemp "${output_zip:h}/.rimeai-notarized-sha.XXXXXX")
cleanup() {
  case "${work_root}" in
    /tmp/rimeai-input-method-notary.*) find "${work_root}" -depth -delete ;;
    *) print -u2 "error: refusing to clean unexpected notary path: ${work_root}" ;;
  esac
  for temporary_file in "${temporary_zip}" "${temporary_checksum}"; do
    case "${temporary_file}" in
      "${output_zip:h}"/.rimeai-notarized.*|\
      "${output_zip:h}"/.rimeai-notarized-sha.*)
        [[ ! -f "${temporary_file}" ]] || unlink "${temporary_file}"
        ;;
      *) print -u2 "error: refusing to clean unexpected output path" ;;
    esac
  done
}
trap cleanup EXIT

expected_sha_file="${input_zip}.sha256"
if [[ -f "${expected_sha_file}" ]]; then
  expected_sha=$(awk 'NR == 1 { print $1 }' "${expected_sha_file}")
  actual_sha=$(shasum -a 256 "${input_zip}" | awk '{ print $1 }')
  if [[ "${expected_sha}" != "${actual_sha}" ]]; then
    print -u2 "error: signed input archive checksum mismatch"
    exit 1
  fi
fi
ditto -x -k "${input_zip}" "${work_root}"
apps=("${work_root}"/*.app(N))
if (( ${#apps} != 1 )); then
  print -u2 "error: signed archive must contain exactly one app"
  exit 1
fi
app_bundle=${apps[1]}
codesign --verify --deep --strict "${app_bundle}"

submission_json="${work_root}/notary-submission.json"
xcrun notarytool submit "${input_zip}" \
  --keychain-profile "${notary_profile}" \
  --wait \
  --output-format json >"${submission_json}"
submission_status=$(plutil -extract status raw -o - "${submission_json}")
submission_id=$(plutil -extract id raw -o - "${submission_json}")
if [[ "${submission_status}" != "Accepted" ]]; then
  xcrun notarytool log "${submission_id}" \
    --keychain-profile "${notary_profile}" || true
  print -u2 "error: Apple notarization status is ${submission_status}"
  exit 1
fi

xcrun stapler staple "${app_bundle}"
xcrun stapler validate "${app_bundle}"
spctl --assess --type execute --verbose=4 "${app_bundle}"
COPYFILE_DISABLE=1 ditto --norsrc -c -k --keepParent \
  "${app_bundle}" "${temporary_zip}"
"${0:A:h}/verify_macos_input_method_release.sh" \
  "${temporary_zip}" >/dev/null
archive_sha=$(shasum -a 256 "${temporary_zip}" | awk '{ print $1 }')
print -r -- "${archive_sha}  ${output_zip:t}" >"${temporary_checksum}"
/bin/mv "${temporary_zip}" "${output_zip}"
/bin/mv "${temporary_checksum}" "${output_zip}.sha256"

print -r -- "release=${output_zip}"
print -r -- "sha256=${archive_sha}"
print -r -- "notary_submission_id=${submission_id}"
print -r -- "notary_status=${submission_status}"
