#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
certificate_path=${RIMEAI_DEVELOPER_ID_CERTIFICATE:-}
private_key_path=${RIMEAI_DEVELOPER_ID_PRIVATE_KEY:-}
signing_identity=${RIMEAI_CODE_SIGN_IDENTITY:-}

if [[ -z "${certificate_path}" || -z "${private_key_path}" \
  || -z "${signing_identity}" ]]; then
  print -u2 -- "usage: set RIMEAI_DEVELOPER_ID_CERTIFICATE, \\"
  print -u2 -- "  RIMEAI_DEVELOPER_ID_PRIVATE_KEY, and RIMEAI_CODE_SIGN_IDENTITY"
  exit 2
fi
if [[ "${signing_identity}" != "Developer ID Application:"* ]]; then
  print -u2 -- "error: RIMEAI_CODE_SIGN_IDENTITY must be a Developer ID Application identity"
  exit 2
fi
if [[ ! -f "${certificate_path}" || ! -f "${private_key_path}" ]]; then
  print -u2 -- "error: Developer ID certificate or private key does not exist"
  exit 2
fi

original_keychains=(
  "${(@f)$(security list-keychains -d user \
    | sed -E 's/^[[:space:]]*"//; s/"[[:space:]]*$//')}"
)
original_default_keychain=$(
  security default-keychain -d user \
    | sed -E 's/^[[:space:]]*"//; s/"[[:space:]]*$//'
)

signing_dir=$(mktemp -d /tmp/rimeai-signing-keychain.XXXXXX)
signing_keychain="${signing_dir}/rimeai-build.keychain-db"
p12_path="${signing_dir}/developer-id.p12"
intermediates_path="${signing_dir}/developer-id-intermediates.pem"
signing_password=$(openssl rand -hex 24)
p12_password=$(openssl rand -hex 24)

cleanup_signing_keychain() {
  if (( ${#original_keychains[@]} > 0 )); then
    security list-keychains -d user -s \
      "${original_keychains[@]}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${original_default_keychain}" ]]; then
    security default-keychain -d user -s \
      "${original_default_keychain}" >/dev/null 2>&1 || true
  fi
  security delete-keychain "${signing_keychain}" >/dev/null 2>&1 || true
  unlink "${p12_path}" "${intermediates_path}" >/dev/null 2>&1 || true
  case "${signing_dir}" in
    /tmp/rimeai-signing-keychain.*)
      rmdir "${signing_dir}" >/dev/null 2>&1 || true
      ;;
    *)
      print -u2 -- "error: refusing to clean unexpected signing path"
      return 1
      ;;
  esac
}
trap cleanup_signing_keychain EXIT

security find-certificate -a \
  -c "Developer ID Certification Authority" \
  -p > "${intermediates_path}"
if [[ ! -s "${intermediates_path}" ]]; then
  print -u2 -- "error: Developer ID intermediate certificate is unavailable"
  exit 1
fi

openssl pkcs12 -export -legacy \
  -out "${p12_path}" \
  -inkey "${private_key_path}" \
  -in "${certificate_path}" \
  -name "${signing_identity}" \
  -passout "pass:${p12_password}"

security create-keychain -p "${signing_password}" "${signing_keychain}"
security set-keychain-settings -lut 3600 "${signing_keychain}"
security unlock-keychain -p "${signing_password}" "${signing_keychain}"
security import "${p12_path}" \
  -k "${signing_keychain}" \
  -P "${p12_password}" \
  -T /usr/bin/codesign >/dev/null
security import "${intermediates_path}" \
  -k "${signing_keychain}" \
  -t agg \
  -f pemseq >/dev/null
security set-key-partition-list \
  -S "apple:" \
  -l "${signing_identity}" \
  -k "${signing_password}" \
  "${signing_keychain}" >/dev/null

# A duplicate identity in login.keychain can make codesign select the wrong
# private-key ACL even when --keychain is supplied. Restrict the search list
# for the duration of the build, then restore it in the EXIT trap.
security list-keychains -d user -s "${signing_keychain}"
security default-keychain -d user -s "${signing_keychain}"
if ! security find-identity -v -p codesigning "${signing_keychain}" \
  | grep -Fq "\"${signing_identity}\""; then
  print -u2 -- "error: isolated Developer ID signing identity is invalid"
  exit 1
fi

RIMEAI_XCODE_CODE_SIGN_IDENTITY="-" \
RIMEAI_CODE_SIGN_IDENTITY="${signing_identity}" \
RIMEAI_CODE_SIGN_KEYCHAIN="${signing_keychain}" \
  "${script_dir}/install_debug_input_method.sh"
