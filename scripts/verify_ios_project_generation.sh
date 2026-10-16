#!/bin/zsh
# shellcheck disable=SC1071  # zsh script; ShellCheck only lints sh/bash

set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
expected_xcodegen_version="Version: 2.44.1"

if ! command -v xcodegen >/dev/null 2>&1; then
  print -u2 "error: xcodegen ${expected_xcodegen_version#Version: } is required"
  exit 1
fi
actual_xcodegen_version=$(xcodegen --version)
if [[ "${actual_xcodegen_version}" != "${expected_xcodegen_version}" ]]; then
  print -u2 \
    "error: expected ${expected_xcodegen_version}, got ${actual_xcodegen_version}"
  exit 1
fi

temporary_container=$(mktemp -d /tmp/rimeai-ios-project-check.XXXXXX)
cleanup() {
  case "${temporary_container}" in
    /tmp/rimeai-ios-project-check.*)
      find "${temporary_container}" -depth -delete
      ;;
    *)
      print -u2 "error: refusing to clean unexpected project-check path"
      ;;
  esac
}
trap cleanup EXIT

# XcodeGen includes the enclosing repository directory name in stable object
# identifiers. Reproduce the checked-in .../RimeAI/ios layout so a temporary
# generation detects real drift instead of manufacturing different PBX IDs.
mirror_root="${temporary_container}/RimeAI"
mirror_ios="${mirror_root}/ios"
mirror_core="${mirror_root}/Sources/RimeAIInputCore"
mirror_bridge="${mirror_root}/Sources/RimeBridgeC"
mkdir -p \
  "${mirror_ios}" \
  "${mirror_core}" \
  "${mirror_bridge}" \
  "${mirror_ios}/RimeData" \
  "${mirror_ios}/SemanticModel" \
  "${mirror_ios}/Native/RimeAINative.xcframework"

cp "${project_root}/ios/project.yml" "${mirror_ios}/project.yml"
cp "${project_root}/LICENSE" "${mirror_root}/LICENSE"
ios_source_directories=(
  HostApp
  KeyboardExtension
  KeyboardTests
  UITests
  ThirdPartyLicenses
)
for source_directory in "${ios_source_directories[@]}"; do
  cp -R \
    "${project_root}/ios/${source_directory}" \
    "${mirror_ios}/${source_directory}"
done

portable_core_sources=(
  CandidateSelectionTransition.swift
  CloudConfiguration.swift
  CloudGeneratedSentencePolicy.swift
  CompositionState.swift
  CompositionState+Derived.swift
  DaemonProtocol.swift
  FailureCircuitBreaker.swift
  InputPreferences.swift
  LocalSemanticRanker.swift
  RimeAISettingsStore.swift
  SessionContextStore.swift
  VoiceDictationKeyRouter.swift
)
for source_file in "${portable_core_sources[@]}"; do
  cp \
    "${project_root}/Sources/RimeAIInputCore/${source_file}" \
    "${mirror_core}/${source_file}"
done
cp \
  "${project_root}/Sources/RimeBridgeC/RimeBridgeC.cc" \
  "${mirror_bridge}/RimeBridgeC.cc"

xcodegen generate \
  --spec "${mirror_ios}/project.yml" \
  --project "${mirror_ios}" \
  --quiet

checked_project="${project_root}/ios/RimeAIiOS.xcodeproj"
generated_project="${mirror_ios}/RimeAIiOS.xcodeproj"
project_files=(
  project.pbxproj
  project.xcworkspace/contents.xcworkspacedata
  xcshareddata/xcschemes/RimeAI.xcscheme
)
for project_file in "${project_files[@]}"; do
  if ! cmp -s \
    "${checked_project}/${project_file}" \
    "${generated_project}/${project_file}"; then
    print -u2 "error: generated iOS project drifted: ${project_file}"
    diff -u \
      "${checked_project}/${project_file}" \
      "${generated_project}/${project_file}" | sed -n '1,160p' || true
    exit 1
  fi
done

print -r -- "xcodegen=2.44.1"
print -r -- "ios_project_generation=passed"
