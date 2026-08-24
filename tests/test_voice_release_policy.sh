#!/bin/zsh

set -euo pipefail

test_root=$(mktemp -d "${TMPDIR:-/tmp}/rimeai-voice-release-policy.XXXXXX")
trap '/bin/rm -rf -- "${test_root}"' EXIT

test_dir=${0:A:h}
project_root=${test_dir:h}
validator="${project_root}/script/verify_voice_release_policy.sh"
host_info="${test_root}/host.plist"
helper_info="${test_root}/helper.plist"
policy="${test_root}/policy.plist"
cp "${project_root}/macos/RimeAIInputMethod/Info.plist" "${host_info}"
cp "${project_root}/macos/VoiceHelper/Info.plist" "${helper_info}"
cp "${project_root}/macos/VoiceHelper/VoiceReleasePolicy.plist" "${policy}"
/usr/libexec/PlistBuddy -c \
  'Set :CFBundleIdentifier fun.wwcn.inputmethod.RimeAI' "${host_info}"

fail() {
  print -u2 "FAIL: $1"
  exit 1
}

zsh -n "${project_root}/scripts/build_macos_input_method_release.sh" \
  || fail "paired Release builder must parse as valid zsh"
zsh -n "${project_root}/scripts/verify_macos_input_method_release.sh" \
  || fail "paired Release verifier must parse as valid zsh"

set_version_pair() {
  local version=$1
  local build=$2
  for plist in "${host_info}" "${helper_info}"; do
    /usr/libexec/PlistBuddy -c \
      "Set :CFBundleShortVersionString ${version}" "${plist}"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${build}" "${plist}"
  done
}

expect_rejected() {
  local name=$1
  if "${validator}" "${host_info}" "${helper_info}" "${policy}" \
    >/dev/null 2>&1; then
    fail "validator should reject ${name}"
  fi
}

set_version_pair 2.4.6 73
"${validator}" "${host_info}" "${helper_info}" "${policy}" >/dev/null \
  || fail "exact fail-closed paired metadata should pass"

/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 74' "${helper_info}"
expect_rejected "mismatched helper build number"
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 73' "${helper_info}"

/usr/libexec/PlistBuddy -c \
  'Set :CFBundleIdentifier fun.wwcn.rimeai.voice-helper.lookalike' \
  "${helper_info}"
expect_rejected "inexact helper identifier"
/usr/libexec/PlistBuddy -c \
  'Set :CFBundleIdentifier fun.wwcn.rimeai.voice-helper' "${helper_info}"

/usr/libexec/PlistBuddy -c 'Set :ReleaseEligible true' "${policy}"
expect_rejected "probe policy marked release eligible"
/usr/libexec/PlistBuddy -c 'Set :ReleaseEligible false' "${policy}"

/usr/libexec/PlistBuddy -c 'Set :RuntimeEngine product-managed' "${policy}"
expect_rejected "argv-independent runtime changed to product managed"
/usr/libexec/PlistBuddy -c 'Set :RuntimeEngine apple-speech' "${policy}"

/usr/libexec/PlistBuddy -c \
  'Set :TrustedCatalogSHA256 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  "${policy}"
expect_rejected "trusted catalog digest drift"
/usr/libexec/PlistBuddy -c \
  'Set :TrustedCatalogSHA256 b0c8659b59e05d39683c4d9c50126f736eb620ba5c2d9c0ef925bba1d275b499' \
  "${policy}"

/usr/libexec/PlistBuddy -c 'Add :Unexpected string value' "${policy}"
expect_rejected "extra policy key"
/usr/libexec/PlistBuddy -c 'Delete :Unexpected' "${policy}"

/usr/libexec/PlistBuddy -c \
  'Set :AssetManagement product_managed' "${policy}"
expect_rejected "Apple probe mislabeled as product managed"

print "PASS: paired voice Release metadata is exact and fail-closed"
