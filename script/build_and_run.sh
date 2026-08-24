#!/bin/zsh

set -euo pipefail

mode=${1:-run}
app_name=RimeAIInputMethod
bundle_id=fun.wwcn.inputmethod.RimeAI
script_dir=${0:A:h}
project_root=${script_dir:h}
macos_dir="${project_root}/macos"
project_path="${macos_dir}/RimeAIInputMethod.xcodeproj"
derived_data=${RIMEAI_DERIVED_DATA_PATH:-"${HOME}/Library/Developer/Xcode/DerivedData/RimeAI-Codex"}
app_bundle="${derived_data}/Build/Products/Debug/${app_name}.app"
app_binary="${app_bundle}/Contents/MacOS/${app_name}"

case "${mode}" in
  run|--settings|settings|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify|--build-only|build-only)
    ;;
  *)
    print -u2 "usage: $0 [run|--settings|--debug|--logs|--telemetry|--verify|--build-only]"
    exit 2
    ;;
esac

if [[ ! -f "${project_root}/.rimeai/rime/shared/data-lock.json" \
      || ! -f "${project_root}/.rimeai/rime/shared/opencc/t2s.json" \
      || ! -f "${project_root}/.rimeai/rime/shared/opencc/TSCharacters.ocd2" ]]; then
  "${project_root}/scripts/bootstrap_rime_data.sh" >/dev/null
fi
"${project_root}/scripts/verify_macos_librime.sh" \
  "${macos_dir}/Native/RimeAIMacRuntime.xcframework" >/dev/null

dot_clean -m "${macos_dir}" "${project_root}/Sources" \
  "${project_root}/.rimeai/rime/shared" >/dev/null 2>&1 || true
xcodegen generate --spec "${macos_dir}/project.yml" \
  --project "${macos_dir}"

pkill -x "${app_name}" >/dev/null 2>&1 || true

signing_identity=${RIMEAI_CODE_SIGN_IDENTITY:-$(
  security find-identity -v -p codesigning \
    | awk '/"Apple Development:/{print $2; exit}'
)}
xcode_signing_identity=${RIMEAI_XCODE_CODE_SIGN_IDENTITY:-${signing_identity}}
signing_arguments=(
  "CODE_SIGN_STYLE=Manual"
  "DEVELOPMENT_TEAM="
  "CODE_SIGN_IDENTITY=-"
)
if [[ -n "${xcode_signing_identity}" ]]; then
  signing_arguments[3]="CODE_SIGN_IDENTITY=${xcode_signing_identity}"
fi

COPYFILE_DISABLE=1 xcodebuild \
  -project "${project_path}" \
  -scheme "${app_name}" \
  -configuration Debug \
  -derivedDataPath "${derived_data}" \
  "${signing_arguments[@]}" \
  clean build

if otool -L "${app_binary}" \
    | rg -Fq "@rpath/${app_name}.debug.dylib"; then
  print -u2 "error: debug dylib executor is not suitable for an installed input method"
  exit 1
fi

"${project_root}/script/bundle_librime_dependencies.sh" \
  "${app_bundle}" "${signing_identity:--}"

if [[ "${mode}" == "--build-only" || "${mode}" == "build-only" ]]; then
  exit 0
fi

"${project_root}/script/start_daemon.sh" >/dev/null

open_app() {
  /usr/bin/open -n "${app_bundle}"
}

case "${mode}" in
  run)
    open_app
    ;;
  --settings|settings)
    /usr/bin/open -n "${app_bundle}" --args --settings
    ;;
  --debug|debug)
    lldb -- "${app_binary}"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact \
      --predicate "process == \"${app_name}\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact \
      --predicate "subsystem == \"${bundle_id}\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "${app_name}" >/dev/null
    ;;
esac
