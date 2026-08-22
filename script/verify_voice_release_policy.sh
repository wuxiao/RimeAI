#!/bin/zsh

# Pure metadata gate for the paired input-method / voice-helper Release.
# It performs no signing, launchctl, TCC, or installation work.

set -euo pipefail

if [[ $# -ne 3 ]]; then
  print -u2 \
    "usage: $0 INPUT_METHOD_INFO.plist HELPER_INFO.plist VOICE_POLICY.plist"
  exit 2
fi

host_info=${1:A}
helper_info=${2:A}
voice_policy=${3:A}
for plist in "${host_info}" "${helper_info}" "${voice_policy}"; do
  if [[ ! -f "${plist}" || -L "${plist}" ]]; then
    print -u2 "error: paired Release metadata is missing or unsafe: ${plist}"
    exit 1
  fi
done
plutil -lint "${host_info}" "${helper_info}" "${voice_policy}" >/dev/null

host_identifier=$(plutil -extract CFBundleIdentifier raw -expect string \
  -o - "${host_info}")
helper_identifier=$(plutil -extract CFBundleIdentifier raw -expect string \
  -o - "${helper_info}")
host_version=$(plutil -extract CFBundleShortVersionString raw -expect string \
  -o - "${host_info}")
helper_version=$(plutil -extract CFBundleShortVersionString raw -expect string \
  -o - "${helper_info}")
host_build=$(plutil -extract CFBundleVersion raw -expect string \
  -o - "${host_info}")
helper_build=$(plutil -extract CFBundleVersion raw -expect string \
  -o - "${helper_info}")

if [[ "${host_identifier}" != fun.wwcn.inputmethod.RimeAI \
  || "${helper_identifier}" != fun.wwcn.rimeai.voice-helper \
  || "${host_version}" != "${helper_version}" \
  || "${host_build}" != "${helper_build}" \
  || ! "${host_version}" =~ \
    '^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$' \
  || ! "${host_build}" =~ '^[1-9][0-9]*$' ]]; then
  print -u2 "error: input method and voice helper identity/version pairing failed"
  exit 1
fi

policy_key_count=$(grep -c '<key>' "${voice_policy}")
if [[ "${policy_key_count}" != 7 \
  || "$(plutil -extract SchemaVersion raw -expect integer -o - \
    "${voice_policy}")" != 2 \
  || "$(plutil -extract RuntimeEngine raw -expect string -o - \
    "${voice_policy}")" != apple-speech \
  || "$(plutil -extract EngineIdentifier raw -expect string -o - \
    "${voice_policy}")" != apple-speech-ondevice \
  || "$(plutil -extract AssetManagement raw -expect string -o - \
    "${voice_policy}")" != system_managed \
  || "$(plutil -extract ReleaseEligible raw -expect bool -o - \
    "${voice_policy}")" != false \
  || "$(plutil -extract EligibilityReason raw -expect string -o - \
    "${voice_policy}")" != macos14_15_system_managed_probe_only \
  || "$(plutil -extract TrustedCatalogSHA256 raw -expect string -o - \
    "${voice_policy}")" \
      != b0c8659b59e05d39683c4d9c50126f736eb620ba5c2d9c0ef925bba1d275b499 ]]; then
  print -u2 "error: embedded voice Release policy is not exact and fail-closed"
  exit 1
fi

print -r -- "paired_voice_metadata=verified"
print -r -- "voice_release_eligible=false"
print -r -- \
  "voice_catalog_sha256=b0c8659b59e05d39683c4d9c50126f736eb620ba5c2d9c0ef925bba1d275b499"
