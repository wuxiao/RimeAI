#!/bin/zsh

# 构建/安装用户级语音 helper。helper 始终位于独立 App
# bundle 中，LaunchAgent 直接执行 Contents/MacOS 内的主二进制，以固定
# bundle ID 承载麦克风与语音识别 TCC 身份。安装默认保持关闭；只有显式
# `--enable` 或随后在 RimeAI 设置中启用才会启动 LaunchAgent。

set -euo pipefail

usage() {
  print -u2 -- \
    "usage: $0 [--engine unavailable|apple-speech (ad-hoc Debug only)] "\
"[--signing-identity -|<codesign identity>] [--enable] "\
"[--marketing-version X.Y.Z] [--build-number N] "\
"[--build-only] [--uninstall] (default engine: apple-speech)"
}

# 安装器默认选择真正可用且强制 on-device 的 Apple Speech 适配器；
# “默认关闭”由删除 enable marker、disable job 且不启动 LaunchAgent 保证。保留
# `--engine unavailable` 仅用于协议/打包故障路径验证。
engine=apple-speech
engine_option_provided=0
signing_identity=-
marketing_version=
build_number=
codesign_keychain_arguments=()
build_only=0
uninstall=0
enable_after_install=0
while [[ $# -gt 0 ]]; do
  case $1 in
    --engine)
      if [[ $# -lt 2 ]]; then
        usage
        exit 2
      fi
      engine=$2
      engine_option_provided=1
      shift 2
      ;;
    --signing-identity)
      if [[ $# -lt 2 ]]; then
        usage
        exit 2
      fi
      signing_identity=$2
      shift 2
      ;;
    --marketing-version)
      if [[ $# -lt 2 ]]; then
        usage
        exit 2
      fi
      marketing_version=$2
      shift 2
      ;;
    --build-number)
      if [[ $# -lt 2 ]]; then
        usage
        exit 2
      fi
      build_number=$2
      shift 2
      ;;
    --build-only)
      build_only=1
      shift
      ;;
    --enable)
      enable_after_install=1
      shift
      ;;
    --uninstall)
      uninstall=1
      shift
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

if [[ "${engine}" != "unavailable" && "${engine}" != "apple-speech" ]]; then
  print -u2 "error: unknown engine ${engine}"
  exit 2
fi
if [[ "${signing_identity}" != "-" && ${engine_option_provided} -eq 1 ]]; then
  print -u2 \
    "error: Release engine is selected only by the signed VoiceReleasePolicy"
  exit 2
fi
if [[ "${signing_identity}" != "-" && ${build_only} -eq 0 ]]; then
  print -u2 \
    "error: signed Release helper is only built as the paired nested bundle"
  exit 2
fi
if [[ -n "${marketing_version}" \
  && ! "${marketing_version}" =~ '^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$' ]]; then
  print -u2 "error: invalid helper marketing version"
  exit 2
fi
if [[ -n "${build_number}" && ! "${build_number}" =~ '^[1-9][0-9]*$' ]]; then
  print -u2 "error: invalid helper build number"
  exit 2
fi
if [[ ${uninstall} -eq 1 && ${build_only} -eq 1 ]]; then
  print -u2 "error: --uninstall and --build-only are mutually exclusive"
  exit 2
fi
if [[ ${build_only} -eq 1 && ${enable_after_install} -eq 1 ]]; then
  print -u2 "error: --build-only and --enable are mutually exclusive"
  exit 2
fi

script_dir=${0:A:h}
project_root=${script_dir:h}
label=fun.wwcn.rimeai.voice-helper
input_method_identifier=fun.wwcn.inputmethod.RimeAI
app_name=RimeAIVoiceHelper.app
domain="gui/${UID}"
template="${project_root}/macos/LaunchAgents/${label}.plist"
info_plist="${project_root}/macos/VoiceHelper/Info.plist"
entitlements="${project_root}/macos/VoiceHelper/RimeAIVoiceHelper.entitlements"
release_policy="${project_root}/macos/VoiceHelper/VoiceReleasePolicy.plist"
validator="${project_root}/script/verify_voice_helper_bundle.sh"
third_party_notices="${project_root}/THIRD_PARTY_NOTICES.md"
sherpa_license=\
"${project_root}/ios/ThirdPartyLicenses/sherpa-onnx-Apache-2.0.txt"
onnxruntime_license=\
"${project_root}/ios/ThirdPartyLicenses/onnxruntime-MIT.txt"
onnxruntime_notices=\
"${project_root}/ios/ThirdPartyLicenses/onnxruntime-ThirdPartyNotices-1.27.1.txt"
launch_agents_dir="${HOME}/Library/LaunchAgents"
target_plist="${launch_agents_dir}/${label}.plist"
support_root="${HOME}/Library/Application Support/RimeAI"
voice_root="${support_root}/voice"
helper_app="${voice_root}/${app_name}"
helper_executable="${helper_app}/Contents/MacOS/rimeai-voice-helper"
runtime_dir="${support_root}/runtime"
socket_file="${runtime_dir}/rimeai-voice.sock"
log_file="${runtime_dir}/rimeai-voice-helper.log"
control_dir="${HOME}/Library/Caches/RimeAI"
enabled_marker="${control_dir}/voice-enabled"
staging_root="${project_root}/.build/voice-helper"
staged_app="${staging_root}/${app_name}"
rendered_base="${staging_root}/${label}.base.plist"
rendered_plist="${staging_root}/${label}.plist"
installing_app="${voice_root}/.${app_name}.installing.$$"
host_input_method_app="${HOME}/Library/Input Methods/RimeAIInputMethod.app"
launchctl_service_not_found_status=113
service_state=""

if [[ -n "${RIMEAI_CODE_SIGN_KEYCHAIN:-}" ]]; then
  if [[ ! -f "${RIMEAI_CODE_SIGN_KEYCHAIN}" \
    || -L "${RIMEAI_CODE_SIGN_KEYCHAIN}" ]]; then
    print -u2 \
      "error: signing keychain is missing or unsafe: ${RIMEAI_CODE_SIGN_KEYCHAIN}"
    exit 2
  fi
  codesign_keychain_arguments=(--keychain "${RIMEAI_CODE_SIGN_KEYCHAIN}")
fi

query_service_state() {
  local launch_status
  service_state=""
  if launchctl print "${domain}/${label}" >/dev/null 2>&1; then
    service_state=loaded
    return 0
  else
    launch_status=$?
  fi
  if [[ ${launch_status} -eq ${launchctl_service_not_found_status} ]]; then
    service_state=absent
    return 0
  fi
  print -u2 \
    "error: launchctl 无法确定 ${label} 是否已加载（status=${launch_status}）"
  return 1
}

stop_loaded_service() {
  if ! query_service_state; then
    return 1
  fi
  if [[ "${service_state}" == absent ]]; then
    return 0
  fi
  if ! launchctl bootout "${domain}/${label}" >/dev/null 2>&1; then
    print -u2 "error: launchctl 无法停止已加载的 ${label}"
    return 1
  fi
  for _ in {1..20}; do
    if ! query_service_state; then
      return 1
    fi
    if [[ "${service_state}" == absent ]]; then
      return 0
    fi
    sleep 0.05
  done
  print -u2 "error: ${label} 在 bootout 后仍处于加载状态"
  return 1
}

# marker 删除与 bootout 始终都尝试；只有确认 job 已卸载后才删除 socket。
# 任一步失败都向调用方返回失败，不能宣称 helper 已关闭。
disable_service_state() {
  local failed=0
  if ! launchctl disable "${domain}/${label}" >/dev/null 2>&1; then
    print -u2 "error: launchctl 无法持久停用 ${label}"
    failed=1
  fi
  if [[ -e "${enabled_marker}" || -L "${enabled_marker}" ]]; then
    if ! rm -f -- "${enabled_marker}"; then
      print -u2 "error: 无法删除语音启用 marker"
      failed=1
    fi
  fi
  if ! stop_loaded_service; then
    failed=1
  elif [[ -e "${socket_file}" || -L "${socket_file}" ]]; then
    if ! rm -f -- "${socket_file}"; then
      print -u2 "error: 无法删除语音 socket"
      failed=1
    fi
  fi
  return ${failed}
}

enable_launchd_job() {
  if ! launchctl enable "${domain}/${label}" >/dev/null 2>&1; then
    print -u2 "error: launchctl 无法持久启用 ${label}"
    return 1
  fi
}

fail_enabled_install() {
  local reason=$1
  print -u2 "error: ${reason}"
  if ! disable_service_state; then
    print -u2 \
      "error: 启用失败后的停用回滚也失败；helper 状态未知，请勿继续使用语音"
  fi
  exit 1
}

extract_ready_field() {
  local field=$1
  print -r -- "${response}" \
    | plutil -extract "${field}" raw -o - -- - 2>/dev/null
}

extract_ready_integer_field() {
  local field=$1
  print -r -- "${response}" \
    | plutil -extract "${field}" raw -expect integer -o - -- - 2>/dev/null
}

extract_ready_string_field() {
  local field=$1
  print -r -- "${response}" \
    | plutil -extract "${field}" raw -expect string -o - -- - 2>/dev/null
}

validate_ready_capabilities() {
  local capability capability_count index
  local local_asr_count=0
  local streaming_count=0

  capability_count=$(
    print -r -- "${response}" \
      | plutil -extract capabilities raw -expect array -o - -- - \
        2>/dev/null
  ) || return 1
  [[ "${capability_count}" == <-> && "${capability_count}" -eq 2 ]] \
    || return 1

  for (( index = 0; index < capability_count; index++ )); do
    capability=$(
      print -r -- "${response}" \
        | plutil -extract "capabilities.${index}" raw -expect string \
          -n -o - -- - 2>/dev/null \
        && print -rn -- x
    ) || return 1
    # 尾随 sentinel 防止命令替换吞掉 capability 值本身的尾随换行。
    capability=${capability%x}
    case "${capability}" in
      local_asr)
        local_asr_count=$(( local_asr_count + 1 ))
        ;;
      streaming)
        streaming_count=$(( streaming_count + 1 ))
        ;;
      *)
        return 1
        ;;
    esac
  done

  [[ ${local_asr_count} -eq 1 && ${streaming_count} -eq 1 ]]
}

validate_ready_response() {
  local ready_protocol ready_type ready_server ready_network ready_engine
  local ready_maximum_hotwords
  local expected_engine
  # unavailable 只用于构建/故障探针；它没有 ASR 能力，绝不能被 --enable
  # 健康检查当作可用服务。真实空能力与伪造 local_asr 都必须 fail closed。
  if [[ "${engine}" == unavailable ]]; then
    return 1
  fi
  ready_protocol=$(extract_ready_integer_field protocol_version) || return 1
  ready_type=$(extract_ready_string_field type) || return 1
  ready_server=$(extract_ready_string_field server_id) || return 1
  ready_network=$(extract_ready_string_field network_policy) || return 1
  ready_engine=$(extract_ready_string_field asr_engine_id) || return 1
  ready_maximum_hotwords=$(
    extract_ready_integer_field maximum_hotwords
  ) || return 1
  validate_ready_capabilities || return 1
  expected_engine=apple-speech-ondevice
  [[ "${ready_protocol}" == 2 \
    && "${ready_type}" == voice_ready \
    && "${ready_server}" == "${label}" \
    && "${ready_network}" == offline \
    && "${ready_maximum_hotwords}" == 0 \
    && "${ready_engine}" == "${expected_engine}" ]]
}

prepare_install_directories() {
  local private_dir private_dir_perms private_dir_owner
  if ! mkdir -p \
    "${voice_root}" \
    "${runtime_dir}" \
    "${launch_agents_dir}" \
    "${control_dir}"; then
    print -u2 "error: 无法创建语音 helper 安装目录"
    return 1
  fi
  if ! chmod -N "${runtime_dir}" "${control_dir}"; then
    print -u2 "error: 无法清除语音私有目录的扩展 ACL"
    return 1
  fi
  if ! chmod 0700 "${runtime_dir}" "${control_dir}"; then
    print -u2 "error: 无法设置语音私有目录权限"
    return 1
  fi
  for private_dir in "${runtime_dir}" "${control_dir}"
  do
    private_dir_perms=$(stat -f "%Lp" "${private_dir}") || return 1
    private_dir_owner=$(stat -f "%u" "${private_dir}") || return 1
    if [[ "${private_dir_perms}" != 700 \
      || "${private_dir_owner}" != "${UID}" ]]; then
      print -u2 \
        "error: private directory is not current-user 0700: ${private_dir}"
      return 1
    fi
  done
}

cleanup_installing_app() {
  local expected_name_prefix=".${app_name}.installing."
  if [[ -z "${installing_app:-}" \
    || "${installing_app:h}" != "${voice_root}" \
    || "${installing_app:t}" != "${expected_name_prefix}"* ]]; then
    print -u2 "error: refusing unsafe staging cleanup path: ${installing_app:-<empty>}"
    return 1
  fi
  if [[ -e "${installing_app}" || -L "${installing_app}" ]]; then
    if ! rm -rf -- "${installing_app}"; then
      print -u2 "error: 无法清理语音 helper 临时安装目录：${installing_app}"
      return 1
    fi
  fi
  if [[ -e "${installing_app}" || -L "${installing_app}" ]]; then
    print -u2 "error: 语音 helper 临时安装目录清理后仍存在：${installing_app}"
    return 1
  fi
}

fail_staging_install() {
  local reason=$1
  print -u2 "error: ${reason}"
  if ! cleanup_installing_app; then
    print -u2 "error: 临时安装目录回滚失败，请先人工检查再重试"
  fi
  print -u2 "error: 新 bundle 尚未进入替换阶段；旧 helper 状态保持不变"
  return 1
}

# 新 bundle 在停止旧服务之前复制、验签；任一步失败都清除隐藏临时目录，
# 且绝不触碰旧 helper bundle、LaunchAgent 或 marker。
stage_installing_app() {
  if ! cleanup_installing_app; then
    fail_staging_install "无法准备语音 helper 临时安装目录"
    return 1
  fi
  if ! ditto "${staged_app}" "${installing_app}"; then
    fail_staging_install "无法复制语音 helper 到临时安装目录"
    return 1
  fi
  if ! codesign --verify --strict --verbose=2 "${installing_app}"; then
    fail_staging_install "临时语音 helper bundle 验签失败"
    return 1
  fi
}

create_enabled_marker() {
  local marker_owner marker_perms
  if [[ -e "${enabled_marker}" || -L "${enabled_marker}" ]]; then
    print -u2 "error: 语音启用 marker 已存在，拒绝覆盖"
    return 1
  fi

  # noclobber 令创建为排他的；077 umask 使 inode 从首次可见起即为 0600，
  # 不存在 touch 后再 chmod 的 0644 观察窗口。
  if ! (
    umask 077
    setopt noclobber
    : > "${enabled_marker}"
  ); then
    print -u2 "error: 无法原子创建 0600 语音启用 marker"
    return 1
  fi
  if ! chmod -N "${enabled_marker}"; then
    print -u2 "error: 无法清除语音启用 marker 的扩展 ACL"
    rm -f -- "${enabled_marker}" || true
    return 1
  fi
  marker_perms=$(stat -f "%Lp" "${enabled_marker}") || {
    rm -f -- "${enabled_marker}" || true
    return 1
  }
  marker_owner=$(stat -f "%u" "${enabled_marker}") || {
    rm -f -- "${enabled_marker}" || true
    return 1
  }
  if [[ ! -f "${enabled_marker}" || -L "${enabled_marker}" \
    || "${marker_perms}" != 600 || "${marker_owner}" != "${UID}" ]]; then
    print -u2 \
      "error: 语音启用 marker 必须是当前用户拥有的 0600 普通文件"
    rm -f -- "${enabled_marker}" || true
    return 1
  fi
}

configure_install_mode() {
  if [[ "${signing_identity}" == "-" ]]; then
    build_configuration=debug
    transport_kind=development-uds
    transport_flag=--socket
    transport_endpoint="${socket_file}"
    engine_description="${engine}"
  else
    build_configuration=release
    transport_kind=authenticated-xpc
    transport_flag=--mach-service
    transport_endpoint="${label}"
    engine_description="signed-policy"
  fi
}

escape_sed_replacement() {
  print -r -- "$1" | sed -e 's/[&|\\]/\\&/g'
}

render_launch_agent() {
  local helper_app_escaped marker_escaped log_escaped paired_build_escaped
  local transport_flag_escaped transport_endpoint_escaped
  local paired_build_number policy_sha256 policy_sha256_escaped

  helper_app_escaped=$(escape_sed_replacement "${helper_app}")
  marker_escaped=$(escape_sed_replacement "${enabled_marker}")
  log_escaped=$(escape_sed_replacement "${log_file}")
  transport_flag_escaped=$(escape_sed_replacement "${transport_flag}")
  transport_endpoint_escaped=$(escape_sed_replacement "${transport_endpoint}")
  paired_build_number=${build_number:-$(
    plutil -extract CFBundleVersion raw -o - "${info_plist}"
  )}
  paired_build_escaped=$(escape_sed_replacement "${paired_build_number}")
  policy_sha256=$(shasum -a 256 "${release_policy}" | awk '{ print $1 }')
  policy_sha256_escaped=$(escape_sed_replacement "${policy_sha256}")

  sed \
    -e "s|__HELPER_APP__|${helper_app_escaped}|g" \
    -e "s|__TRANSPORT_FLAG__|${transport_flag_escaped}|g" \
    -e "s|__TRANSPORT_ENDPOINT__|${transport_endpoint_escaped}|g" \
    -e "s|__ENABLED_MARKER__|${marker_escaped}|g" \
    -e "s|__LOG_PATH__|${log_escaped}|g" \
    -e "s|__HOST_BUILD__|${paired_build_escaped}|g" \
    -e "s|__VOICE_POLICY_SHA256__|${policy_sha256_escaped}|g" \
    "${template}" > "${rendered_base}"
  if [[ "${transport_kind}" == authenticated-xpc ]]; then
    # Release helper 的引擎由其签名 bundle 内的 VoiceReleasePolicy.plist
    # 唯一决定。LaunchAgent 不得再用用户可写 argv 形成第二份策略。
    sed -e '/__ENGINE_FLAG__/d' -e '/__ENGINE_NAME__/d' \
      "${rendered_base}" > "${rendered_plist}"
  elif [[ "${engine}" == "unavailable" ]]; then
    sed -e '/__ENGINE_FLAG__/d' -e '/__ENGINE_NAME__/d' \
      "${rendered_base}" > "${rendered_plist}"
  else
    sed \
      -e "s|__ENGINE_FLAG__|--engine|" \
      -e "s|__ENGINE_NAME__|${engine}|" \
      "${rendered_base}" > "${rendered_plist}"
  fi
  if [[ "${transport_kind}" == development-uds ]]; then
    plutil -remove MachServices "${rendered_plist}"
  fi
  plutil -lint "${rendered_plist}"
}

stamp_helper_version() {
  local plist=$1
  if [[ ! -f "${plist}" || -L "${plist}" ]]; then
    print -u2 "error: helper Info.plist is missing or unsafe"
    return 1
  fi
  if [[ -n "${marketing_version}" ]]; then
    /usr/libexec/PlistBuddy -c \
      "Set :CFBundleShortVersionString ${marketing_version}" "${plist}"
  fi
  if [[ -n "${build_number}" ]]; then
    /usr/libexec/PlistBuddy -c \
      "Set :CFBundleVersion ${build_number}" "${plist}"
  fi
}

extract_signing_field() {
  local signing_details=$1
  local field=$2
  local value
  value=$(
    print -r -- "${signing_details}" \
      | sed -n "s/^${field}=//p"
  ) || return 1
  if [[ -z "${value}" || "${value}" == *$'\n'* ]]; then
    return 1
  fi
  REPLY=${value}
}

developer_id_requirement() {
  local identifier=$1
  local team_identifier=$2
  print -rn -- \
    "anchor apple generic and identifier \"${identifier}\" and "\
"certificate 1[field.1.2.840.113635.100.6.2.6] exists and "\
"certificate leaf[field.1.2.840.113635.100.6.1.13] exists and "\
"certificate leaf[subject.OU] = \"${team_identifier}\""
}

# 发布 helper 只信任同一 Developer ID Team 签名的固定输入法宿主。
# 这是安装前的静态门；Release XPC listener 仍会逐连接执行同等 requirement。
validate_release_signing_pair() {
  local helper_bundle=$1
  local helper_details host_details helper_identifier host_identifier
  local helper_team host_team helper_requirement host_requirement

  if [[ ! -d "${helper_bundle}" || -L "${helper_bundle}" ]]; then
    print -u2 "error: release helper bundle missing or is a symlink: ${helper_bundle}"
    return 1
  fi
  if [[ ! -d "${host_input_method_app}" || -L "${host_input_method_app}" ]]; then
    print -u2 \
      "error: signed install requires ${host_input_method_app} as a real app bundle"
    return 1
  fi

  helper_details=$(codesign -dvvv "${helper_bundle}" 2>&1) || {
    print -u2 "error: unable to inspect release helper signature"
    return 1
  }
  host_details=$(codesign -dvvv "${host_input_method_app}" 2>&1) || {
    print -u2 "error: unable to inspect installed input method signature"
    return 1
  }
  extract_signing_field "${helper_details}" Identifier || {
    print -u2 "error: release helper has no unique signing identifier"
    return 1
  }
  helper_identifier=${REPLY}
  extract_signing_field "${host_details}" Identifier || {
    print -u2 "error: installed input method has no unique signing identifier"
    return 1
  }
  host_identifier=${REPLY}
  if [[ "${helper_identifier}" != "${label}" \
    || "${host_identifier}" != "${input_method_identifier}" ]]; then
    print -u2 \
      "error: signed identifiers must be exactly ${label} and ${input_method_identifier}"
    return 1
  fi

  extract_signing_field "${helper_details}" TeamIdentifier || {
    print -u2 "error: release helper has no unique TeamIdentifier"
    return 1
  }
  helper_team=${REPLY}
  extract_signing_field "${host_details}" TeamIdentifier || {
    print -u2 "error: installed input method has no unique TeamIdentifier"
    return 1
  }
  host_team=${REPLY}
  if ! print -r -- "${helper_team}" | grep -Eq '^[A-Z0-9]{10}$' \
    || [[ "${helper_team}" != "${host_team}" ]]; then
    print -u2 "error: release helper and input method must use the same valid TeamIdentifier"
    return 1
  fi

  helper_requirement=$(developer_id_requirement "${label}" "${helper_team}")
  host_requirement=$(
    developer_id_requirement "${input_method_identifier}" "${helper_team}"
  )
  if ! codesign --verify --strict --verbose=2 \
    -R="${helper_requirement}" "${helper_bundle}"; then
    print -u2 "error: helper does not satisfy the Developer ID requirement"
    return 1
  fi
  if ! codesign --verify --strict --verbose=2 \
    -R="${host_requirement}" "${host_input_method_app}"; then
    print -u2 "error: installed input method does not satisfy the Developer ID requirement"
    return 1
  fi
}

verify_enabled_transport() {
  local socket_perms socket_owner hello_line
  local response=""

  if [[ "${transport_kind}" == authenticated-xpc ]]; then
    print -n "等待 authenticated Mach service job……"
    for _ in {1..50}; do
      if ! query_service_state; then
        return 1
      fi
      if [[ "${service_state}" == loaded ]]; then
        print " ok"
        return 0
      fi
      print -n "."
      sleep 0.2
    done
    print -u2 "\nerror: authenticated Mach service job 未保持加载"
    return 1
  fi

  print -n "等待开发 socket……"
  for _ in {1..50}; do
    if [[ -S "${socket_file}" ]]; then
      break
    fi
    print -n "."
    sleep 0.2
  done
  if [[ ! -S "${socket_file}" ]]; then
    print -u2 "\nerror: 开发 socket 未出现，检查 ${log_file}"
    return 1
  fi
  print " ok"

  socket_perms=$(stat -f "%Lp" "${socket_file}") || return 1
  socket_owner=$(stat -f "%u" "${socket_file}") || return 1
  if [[ "${socket_perms}" != 600 || "${socket_owner}" != "${UID}" ]]; then
    print -u2 \
      "error: socket 必须由当前用户拥有且权限为 600（实际 owner=${socket_owner}, mode=${socket_perms}）"
    return 1
  fi

  print "开发 UDS 协议健康检查……"
  hello_line='{"protocol_version":2,"type":"voice_hello","client_id":"fun.wwcn.inputmethod.RimeAI","capabilities":["dictation","cancel","accept-ack"]}'
  response=$(printf '%s\n' "${hello_line}" | nc -U -w 3 "${socket_file}" || true)
  if ! validate_ready_response; then
    print -u2 "error: 健康检查未返回兼容且匹配所选引擎的 voice_ready"
    return 1
  fi
  print "voice_ready: ${response}"
}

# 专项 shell harness 只加载上面的纯函数；执行安装器时此变量必须保持未设置。
if [[ "${RIMEAI_VOICE_INSTALLER_TEST_SOURCE_ONLY:-0}" == 1 ]]; then
  if [[ "${ZSH_EVAL_CONTEXT}" != *:file* ]]; then
    print -u2 "error: test source-only mode requires sourcing this script"
    exit 2
  fi
  return 0
fi

if [[ ${uninstall} -eq 1 ]]; then
  print "卸载 ${label}……"
  if ! disable_service_state; then
    print -u2 "error: helper 未确认停止，拒绝删除安装制品"
    exit 1
  fi
  rm -f -- "${target_plist}" "${enabled_marker}" "${socket_file}"
  rm -rf -- "${voice_root}"
  print "已卸载（保留日志与 Rime 用户数据）"
  exit 0
fi

for required_file in \
  "${template}" \
  "${info_plist}" \
  "${entitlements}" \
  "${release_policy}" \
  "${validator}" \
  "${third_party_notices}" \
  "${sherpa_license}" \
  "${onnxruntime_license}" \
  "${onnxruntime_notices}"
do
  if [[ ! -f "${required_file}" ]]; then
    print -u2 "error: required file missing: ${required_file}"
    exit 1
  fi
done

if [[ "${signing_identity}" != "-" ]]; then
  available_identities=$(security find-identity -v -p codesigning 2>/dev/null || true)
  if [[ "${available_identities}" != *"${signing_identity}"* ]]; then
    print -u2 "error: codesign identity is not available: ${signing_identity}"
    exit 1
  fi
fi

configure_install_mode

print "构建 rimeai-voice-helper……"
if ! (cd "${project_root}" \
  && swift build -c "${build_configuration}" --product rimeai-voice-helper); then
  print -u2 "error: build failed"
  exit 1
fi

swift_bin_dir=$(
  cd "${project_root}" \
    && swift build -c "${build_configuration}" --show-bin-path
)
built_binary="${swift_bin_dir}/rimeai-voice-helper"
if [[ ! -x "${built_binary}" ]]; then
  print -u2 "error: built binary missing: ${built_binary}"
  exit 1
fi

mkdir -p "${staging_root}"
rm -rf -- "${staged_app}"
mkdir -p \
  "${staged_app}/Contents/MacOS" \
  "${staged_app}/Contents/Resources/ThirdPartyLicenses"
install -m 0644 "${info_plist}" "${staged_app}/Contents/Info.plist"
install -m 0644 "${release_policy}" \
  "${staged_app}/Contents/Resources/VoiceReleasePolicy.plist"
install -m 0644 "${third_party_notices}" \
  "${staged_app}/Contents/Resources/THIRD_PARTY_NOTICES.md"
install -m 0644 "${sherpa_license}" \
  "${staged_app}/Contents/Resources/ThirdPartyLicenses/${sherpa_license:t}"
install -m 0644 "${onnxruntime_license}" \
  "${staged_app}/Contents/Resources/ThirdPartyLicenses/${onnxruntime_license:t}"
install -m 0644 "${onnxruntime_notices}" \
  "${staged_app}/Contents/Resources/ThirdPartyLicenses/${onnxruntime_notices:t}"
stamp_helper_version "${staged_app}/Contents/Info.plist"
install -m 0755 \
  "${built_binary}" \
  "${staged_app}/Contents/MacOS/rimeai-voice-helper"

# 项目盘可能是 exFAT；复制带扩展属性的 SwiftPM 制品会生成 AppleDouble
# `._*` 文件。签名前移除这些派生元数据，避免它们被当作未签名嵌套代码。
find "${staged_app}" ! -name '._*' -exec xattr -c {} +
find "${staged_app}" -name '._*' -type f -delete

# Hardened Runtime 在 ad-hoc 与 Developer ID 两条打包路径上都启用。
# entitlement 只授予音频输入；它不启用 App Sandbox，也不授予网络权限。
codesign_arguments=(
  --force
  --sign "${signing_identity}"
  --identifier "${label}"
  --options runtime
  --entitlements "${entitlements}"
)
if [[ "${signing_identity}" == "-" ]]; then
  codesign_arguments+=(--timestamp=none)
  signing_description="ad-hoc（仅本机开发，不能公证）"
else
  codesign_arguments+=(--timestamp)
  signing_description="${signing_identity}（Hardened Runtime）"
fi
codesign "${codesign_arguments[@]}" \
  "${codesign_keychain_arguments[@]}" "${staged_app}"
# The repository can live on a filesystem that materializes macOS metadata as
# AppleDouble files.  codesign itself may recreate those companions; they are
# never part of the helper contract and would invalidate a later bundle copy.
find "${staged_app}" -name '._*' -type f -delete
codesign --verify --strict --verbose=2 "${staged_app}"

print "渲染 LaunchAgent plist（引擎 ${engine_description}）……"
render_launch_agent
rendered_executable=$(
  /usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "${rendered_plist}"
)
if [[ "${rendered_executable}" != "${helper_executable}" ]]; then
  print -u2 "error: LaunchAgent executable mismatch: ${rendered_executable}"
  exit 1
fi
"${validator}" \
  "${staged_app}" \
  "${rendered_plist}" \
  "${transport_kind}" \
  "${transport_endpoint}" \
  "${helper_executable}"

if [[ ${build_only} -eq 1 ]]; then
  print "仅构建完成，未写入用户目录、未调用 launchctl："
  print "${staged_app}"
  print "已验证 LaunchAgent：${rendered_plist}"
  print "签名：${signing_description}"
  exit 0
fi

# build-only 在此之前退出，因此不会检查或写入用户 HOME。发布安装在创建任何
# 用户目录、停用旧 job 或替换文件前，先静态验证已安装输入法的签名信任链。
if [[ "${transport_kind}" == authenticated-xpc ]]; then
  if ! validate_release_signing_pair "${staged_app}"; then
    print -u2 "error: signed voice helper install refused before user-state mutation"
    exit 1
  fi
fi

if ! prepare_install_directories; then
  if ! disable_service_state; then
    print -u2 \
      "error: 安装目录权限失败后的停用回滚也失败；helper 状态未知"
  fi
  exit 1
fi
if ! stage_installing_app; then
  exit 1
fi

# 已完整构建、签名并验证新 bundle 后，才停止旧进程和替换安装制品。
if ! disable_service_state; then
  if ! cleanup_installing_app; then
    print -u2 "error: 停用旧 helper 失败后，临时安装目录也未能清理"
  fi
  print -u2 "error: 旧 helper 未确认停止，拒绝替换安装制品"
  exit 1
fi
rm -rf -- "${helper_app}"
mv "${installing_app}" "${helper_app}"
install -m 0644 "${rendered_plist}" "${target_plist}"
"${validator}" \
  "${helper_app}" \
  "${target_plist}" \
  "${transport_kind}" \
  "${transport_endpoint}" \
  "${helper_executable}"

if [[ ${enable_after_install} -eq 0 ]]; then
  print "安装完成：${label}（默认关闭，${signing_description}）"
  print "请在 RimeAI 设置中显式启用语音；安装过程未启动 helper。"
  print "卸载: $0 --uninstall"
  exit 0
fi

# marker 先于 bootstrap：KeepAlive PathState 满足后 launchd 启动 helper。
if ! create_enabled_marker; then
  fail_enabled_install "无法创建受保护的语音启用 marker"
fi

if ! enable_launchd_job; then
  fail_enabled_install "launchctl 无法启用语音 helper"
fi
if ! launchctl bootstrap "${domain}" "${target_plist}"; then
  fail_enabled_install "launchctl 无法加载语音 helper"
fi
if ! launchctl kickstart -k "${domain}/${label}"; then
  fail_enabled_install "launchctl 无法启动语音 helper"
fi

if ! verify_enabled_transport; then
  fail_enabled_install "语音 helper 启用后未通过 ${transport_kind} 就绪检查"
fi

print "安装完成：${label}（引擎 ${engine_description}，${signing_description}，${transport_kind}）"
print "卸载: $0 --uninstall"
