#!/bin/zsh

# 安装/卸载用户级语音 helper（开发配置）。对齐 install_release_daemon.sh
# 的 launchctl 生命周期模式：marker 文件按需启停、0600 socket、
# bootstrap/bootout。设计见 docs/VOICE_INPUT_DESIGN.md 第 2 节。

set -euo pipefail

usage() {
  print -u2 "usage: $0 [--engine unavailable|apple-speech] [--uninstall]"
}

engine=unavailable
uninstall=0
while [[ $# -gt 0 ]]; do
  case $1 in
    --engine)
      if [[ $# -lt 2 ]]; then
        usage
        exit 2
      fi
      engine=$2
      shift 2
      ;;
    --uninstall)
      uninstall=1
      shift
      ;;
    *)
      usage
      exit 2
      ;;
  esac done

if [[ "${engine}" != "unavailable" && "${engine}" != "apple-speech" ]]; then
  print -u2 "error: unknown engine ${engine}"
  exit 2
fi

script_dir=${0:A:h}
project_root=${script_dir:h}
label=fun.wwcn.rimeai.voice-helper
domain="gui/${UID}"
template="${project_root}/macos/LaunchAgents/${label}.plist"
launch_agents_dir="${HOME}/Library/LaunchAgents"
target_plist="${launch_agents_dir}/${label}.plist"
support_root="${HOME}/Library/Application Support/RimeAI"
voice_root="${support_root}/voice"
helper_binary="${voice_root}/rimeai-voice-helper"
runtime_dir="${support_root}/runtime"
socket_file="${runtime_dir}/rimeai-voice.sock"
log_file="${runtime_dir}/rimeai-voice-helper.log"
control_dir="${HOME}/Library/Caches/RimeAI"
enabled_marker="${control_dir}/voice-enabled"

if [[ ${uninstall} -eq 1 ]]; then
  print "卸载 ${label}……"
  launchctl bootout "${domain}/${label}" >/dev/null 2>&1 || true
  rm -f "${target_plist}" "${enabled_marker}" "${socket_file}"
  rm -rf "${voice_root}"
  print "已卸载（保留日志与 Rime 用户数据）"
  exit 0
fi

print "构建 rimeai-voice-helper……"
if ! (cd "${project_root}" && swift build --product rimeai-voice-helper); then
  print -u2 "error: build failed"
  exit 1
fi

built_binary="${project_root}/.build/debug/rimeai-voice-helper"
if [[ ! -x "${built_binary}" ]]; then
  print -u2 "error: built binary missing: ${built_binary}"
  exit 1
fi

mkdir -p "${voice_root}" "${runtime_dir}" "${launch_agents_dir}" "${control_dir}"
install -m 0755 "${built_binary}" "${helper_binary}"

print "渲染 LaunchAgent plist（引擎 ${engine}）……"
sed \
  -e "s|__HELPER_BINARY__|${helper_binary}|g" \
  -e "s|__SOCKET__|${socket_file}|g" \
  -e "s|__ENABLED_MARKER__|${enabled_marker}|g" \
  -e "s|__LOG_PATH__|${log_file}|g" \
  "${template}" > "${target_plist}.tmp"
if [[ "${engine}" == "unavailable" ]]; then
  sed -e '/__ENGINE_FLAG__/d' -e '/__ENGINE_NAME__/d' \
    "${target_plist}.tmp" > "${target_plist}"
else
  sed \
    -e "s|__ENGINE_FLAG__|--engine|" \
    -e "s|__ENGINE_NAME__|${engine}|" \
    "${target_plist}.tmp" > "${target_plist}"
fi
rm -f "${target_plist}.tmp"
chmod 0644 "${target_plist}"

# marker 先于 bootstrap：KeepAlive PathState 满足后 launchd 启动 helper。
touch "${enabled_marker}"

launchctl bootout "${domain}/${label}" >/dev/null 2>&1 || true
launchctl bootstrap "${domain}" "${target_plist}"
launchctl kickstart -k "${domain}/${label}"

print -n "等待 socket……"
for _ in {1..50}; do
  if [[ -S "${socket_file}" ]]; then
    break
  fi
  print -n "."
  sleep 0.2
done
if [[ ! -S "${socket_file}" ]]; then
  print -u2 "\nerror: socket 未出现，检查 ${log_file}"
  exit 1
fi
print " ok"

socket_perms=$(stat -f "%Lp" "${socket_file}")
if [[ "${socket_perms}" != "600" ]]; then
  print -u2 "warning: socket 权限为 ${socket_perms}，预期 600"
fi

print "协议健康检查……"
hello_line='{"protocol_version":1,"type":"voice_hello","client_id":"fun.wwcn.inputmethod.RimeAI","capabilities":["dictation"]}'
response=$(printf '%s\n' "${hello_line}" | nc -U -w 3 "${socket_file}" || true)
if [[ "${response}" != *"voice_ready"* ]]; then
  print -u2 "error: 健康检查失败，响应: ${response}"
  exit 1
fi
print "voice_ready: ${response}"

print "安装完成：${label}（引擎 ${engine}，socket 600）"
print "卸载: $0 --uninstall"
