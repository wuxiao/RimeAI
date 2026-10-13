#!/bin/zsh

set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  print -u2 "usage: $0 OUTPUT_ARCHIVE.tar.gz [VERSION]"
  exit 2
fi
if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
  print -u2 "error: the macOS arm64 release must be built on Apple silicon"
  exit 2
fi
if [[ ! -x /usr/bin/python3 ]]; then
  print -u2 "error: Xcode's /usr/bin/python3 is required for the macOS 14 target"
  exit 2
fi
if ! command -v uv >/dev/null 2>&1; then
  print -u2 "error: uv is required to build the isolated release environment"
  exit 2
fi

script_dir=${0:A:h}
project_root=${script_dir:h}
output_archive=${1:A}
version=${2:-0.1.0-internal-preview.1}
if [[ "${output_archive}" != *.tar.gz ]]; then
  print -u2 "error: release output must end in .tar.gz"
  exit 2
fi
output_parent=${output_archive:h}
checksum_output="${output_archive}.sha256"
if [[ -e "${output_archive}" || -L "${output_archive}" \
  || -e "${checksum_output}" || -L "${checksum_output}" ]]; then
  print -u2 "error: refusing to overwrite release output: ${output_archive}"
  exit 2
fi
mkdir -p "${output_parent}"

language_model_source="${project_root}/.rimeai/models/p0-char-ngram-v2.json.gz"
beam_config_source="${project_root}/.rimeai/models/p0-beam-sentence-v3.json"
dictionary_source="${project_root}/.rimeai/rime/shared/luna_pinyin.dict.yaml"
neural_model_source="${project_root}/.rimeai/models/rimeai-ranker-s-24m-int8-onnx-v1"
fusion_config_source="${project_root}/.rimeai/models/rimeai-ranker-s-24m-int8-onnx-fusion-v1.json"
model_lock_source="${project_root}/models/bge-small-zh-v1.5.lock.json"
daemon_entitlements="${project_root}/macos/Daemon/RimeAIDaemon.entitlements"
for required_file in \
  "${project_root}/uv.lock" \
  "${project_root}/THIRD_PARTY_NOTICES.md" \
  "${project_root}/datasets/ATTRIBUTION.md" \
  "${language_model_source}" \
  "${beam_config_source}" \
  "${dictionary_source}" \
  "${neural_model_source}/manifest.json" \
  "${fusion_config_source}" \
  "${model_lock_source}" \
  "${project_root}/macos/Daemon/ThirdPartyLicenses/tokenizers-Apache-2.0.txt" \
  "${daemon_entitlements}"; do
  if [[ ! -f "${required_file}" ]]; then
    print -u2 "error: required release input is missing: ${required_file}"
    exit 2
  fi
done

build_root=$(mktemp -d /tmp/rimeai-daemon-build.XXXXXX)
staging_parent=$(mktemp -d /tmp/rimeai-daemon-stage.XXXXXX)
safe_version=${version//[^A-Za-z0-9._-]/-}
release_directory_name="rimeai-daemon-macos-arm64-${safe_version}"
staging_root="${staging_parent}/${release_directory_name}"
temporary_archive=$(mktemp "${output_parent}/.rimeai-daemon-archive.XXXXXX")
temporary_checksum=$(mktemp "${output_parent}/.rimeai-daemon-checksum.XXXXXX")
daemon_pid=""
cleanup() {
  if [[ -n "${daemon_pid}" ]] && kill -0 "${daemon_pid}" 2>/dev/null; then
    kill -TERM "${daemon_pid}" 2>/dev/null || true
    wait "${daemon_pid}" 2>/dev/null || true
  fi
  case "${build_root}" in
    /tmp/rimeai-daemon-build.*) find "${build_root}" -depth -delete ;;
    *) print -u2 "error: refusing to clean unexpected build path: ${build_root}" ;;
  esac
  case "${staging_parent}" in
    /tmp/rimeai-daemon-stage.*) find "${staging_parent}" -depth -delete ;;
    *) print -u2 "error: refusing to clean unexpected staging path: ${staging_parent}" ;;
  esac
  for temporary_file in "${temporary_archive}" "${temporary_checksum}"; do
    case "${temporary_file}" in
      "${output_parent}"/.rimeai-daemon-archive.*|\
      "${output_parent}"/.rimeai-daemon-checksum.*)
        if [[ -f "${temporary_file}" ]]; then
          rm -f -- "${temporary_file}"
        fi
        ;;
      *) print -u2 "error: refusing to clean unexpected output path: ${temporary_file}" ;;
    esac
  done
}
trap cleanup EXIT

export COPYFILE_DISABLE=1
export MACOSX_DEPLOYMENT_TARGET=14.0
export SOURCE_DATE_EPOCH=$(git -C "${project_root}" log -1 --format=%ct)
git_commit=$(git -C "${project_root}" rev-parse HEAD)
git_dirty=false
if ! git -C "${project_root}" diff --quiet --ignore-submodules -- \
  || ! git -C "${project_root}" diff --cached --quiet --ignore-submodules --; then
  git_dirty=true
fi

/usr/bin/python3 -m venv "${build_root}/venv"
VIRTUAL_ENV="${build_root}/venv" \
UV_PROJECT_ENVIRONMENT="${build_root}/venv" \
  uv sync \
    --project "${project_root}" \
    --frozen \
    --active \
    --extra release

release_python="${build_root}/venv/bin/python"
python_version=$(
  "${release_python}" -c \
    'import platform; print(platform.python_version())'
)
pyinstaller_version=$(
  "${release_python}" -c \
    'import PyInstaller; print(PyInstaller.__version__)'
)
onnxruntime_version=$(
  "${release_python}" -c \
    'import onnxruntime; print(onnxruntime.__version__)'
)
if [[ "${python_version}" != 3.9.* \
  || "${pyinstaller_version}" != "6.21.0" \
  || "${onnxruntime_version}" != "1.19.2" ]]; then
  print -u2 \
    "error: unexpected release toolchain: Python ${python_version}, PyInstaller ${pyinstaller_version}, ONNX Runtime ${onnxruntime_version}"
  exit 1
fi
site_packages=$(
  "${release_python}" -c \
    'import sysconfig; print(sysconfig.get_paths()["purelib"])'
)

"${release_python}" -m PyInstaller \
  --noconfirm \
  --clean \
  --onedir \
  --name rimeai-daemon \
  --target-arch arm64 \
  --distpath "${build_root}/dist" \
  --workpath "${build_root}/work" \
  --specpath "${build_root}/spec" \
  --collect-binaries onnxruntime \
  --exclude-module onnx \
  --exclude-module safetensors \
  --exclude-module torch \
  --exclude-module transformers \
  --exclude-module tkinter \
  --exclude-module matplotlib \
  --exclude-module scipy \
  "${project_root}/tools/rimeai_daemon_entry.py"

"${release_python}" -m PyInstaller \
  --noconfirm \
  --clean \
  --onedir \
  --name rimeai-cloud-broker \
  --target-arch arm64 \
  --distpath "${build_root}/dist" \
  --workpath "${build_root}/cloud-work" \
  --specpath "${build_root}/cloud-spec" \
  --exclude-module onnx \
  --exclude-module onnxruntime \
  --exclude-module safetensors \
  --exclude-module torch \
  --exclude-module transformers \
  --exclude-module tkinter \
  --exclude-module matplotlib \
  --exclude-module scipy \
  "${project_root}/tools/rimeai_cloud_broker_entry.py"

mkdir -p \
  "${staging_root}/runtime" \
  "${staging_root}/models" \
  "${staging_root}/licenses"
rsync -a \
  --exclude='._*' \
  --exclude='__pycache__' \
  "${build_root}/dist/rimeai-daemon/" \
  "${staging_root}/runtime/rimeai-daemon/"
rsync -a \
  --exclude='._*' \
  --exclude='__pycache__' \
  "${build_root}/dist/rimeai-cloud-broker/" \
  "${staging_root}/runtime/rimeai-cloud-broker/"
install -m 644 "${language_model_source}" \
  "${staging_root}/models/p0-char-ngram-v2.json.gz"
install -m 644 "${beam_config_source}" \
  "${staging_root}/models/p0-beam-sentence-v3.json"
install -m 644 "${dictionary_source}" \
  "${staging_root}/models/luna_pinyin.dict.yaml"
# Keep the stable release path so rollback can switch between PyTorch and ONNX
# releases without rewriting the LaunchAgent.
rsync -a --exclude='._*' --exclude='__pycache__' \
  "${neural_model_source}/" \
  "${staging_root}/models/rimeai-ranker-s-24m-v1/"
install -m 644 "${fusion_config_source}" \
  "${staging_root}/models/rimeai-ranker-s-24m-fusion-v1.json"
install -m 644 "${model_lock_source}" \
  "${staging_root}/licenses/bge-small-zh-v1.5.lock.json"
install -m 644 "${project_root}/THIRD_PARTY_NOTICES.md" \
  "${staging_root}/licenses/THIRD_PARTY_NOTICES.md"
install -m 644 "${project_root}/datasets/ATTRIBUTION.md" \
  "${staging_root}/licenses/DATASET_ATTRIBUTION.md"
rsync -a --exclude='._*' \
  "${project_root}/ios/ThirdPartyLicenses/" \
  "${staging_root}/licenses/third-party-texts/"
install -m 644 \
  "${project_root}/macos/Daemon/ThirdPartyLicenses/bge-small-zh-v1.5-MIT.txt" \
  "${staging_root}/licenses/third-party-texts/bge-small-zh-v1.5-MIT.txt"
install -m 644 \
  "${site_packages}/onnxruntime/LICENSE" \
  "${staging_root}/licenses/third-party-texts/onnxruntime-MIT.txt"
install -m 644 \
  "${site_packages}/numpy-2.0.2.dist-info/LICENSE.txt" \
  "${staging_root}/licenses/third-party-texts/numpy-BSD-and-bundled-licenses.txt"
install -m 644 \
  "${site_packages}/charset_normalizer-3.5.0.dist-info/licenses/LICENSE" \
  "${staging_root}/licenses/third-party-texts/charset-normalizer-MIT.txt"
install -m 644 \
  "${site_packages}/pyyaml-6.0.3.dist-info/licenses/LICENSE" \
  "${staging_root}/licenses/third-party-texts/pyyaml-MIT.txt"
install -m 644 \
  "${project_root}/macos/Daemon/ThirdPartyLicenses/tokenizers-Apache-2.0.txt" \
  "${staging_root}/licenses/third-party-texts/tokenizers-Apache-2.0.txt"
install -m 644 \
  "/Applications/Xcode.app/Contents/Developer/Library/Frameworks/Python3.framework/Versions/3.9/lib/python3.9/LICENSE.txt" \
  "${staging_root}/licenses/third-party-texts/cpython-PSF.txt"
find "${staging_root}" -type d -exec chmod 755 {} +
find "${staging_root}" -type f ! -perm -u+x -exec chmod 644 {} +
find "${staging_root}" \( -name '._*' -o -name '.DS_Store' \) -delete
find "${staging_root}" -exec xattr -c {} + 2>/dev/null || true

signing_identity=${RIMEAI_CODE_SIGN_IDENTITY:--}
timestamp_argument="--timestamp=none"
if [[ "${signing_identity}" == "Developer ID Application:"* ]]; then
  timestamp_argument="--timestamp=http://timestamp.apple.com/ts01"
fi
keychain_arguments=()
if [[ -n "${RIMEAI_CODE_SIGN_KEYCHAIN:-}" ]]; then
  if [[ ! -f "${RIMEAI_CODE_SIGN_KEYCHAIN}" ]]; then
    print -u2 \
      "error: signing keychain does not exist: ${RIMEAI_CODE_SIGN_KEYCHAIN}"
    exit 2
  fi
  keychain_arguments=("--keychain" "${RIMEAI_CODE_SIGN_KEYCHAIN}")
fi
daemon_executable="${staging_root}/runtime/rimeai-daemon/rimeai-daemon"
cloud_broker_executable="${staging_root}/runtime/rimeai-cloud-broker/rimeai-cloud-broker"
macho_targets=()
while IFS= read -r -d '' target_file; do
  if file -b "${target_file}" | grep -q 'Mach-O'; then
    if [[ "${target_file}" != "${daemon_executable}" \
      && "${target_file}" != "${cloud_broker_executable}" ]]; then
      macho_targets+=("${target_file}")
    fi
  fi
done < <(find "${staging_root}/runtime" -type f -print0)
for target_file in "${macho_targets[@]}"; do
  codesign \
    --force \
    --sign "${signing_identity}" \
    "${timestamp_argument}" \
    "${keychain_arguments[@]}" \
    --options runtime \
    "${target_file}"
done
codesign \
  --force \
  --sign "${signing_identity}" \
  "${timestamp_argument}" \
  "${keychain_arguments[@]}" \
  --options runtime \
  --entitlements "${daemon_entitlements}" \
  "${daemon_executable}"
codesign \
  --force \
  --sign "${signing_identity}" \
  "${timestamp_argument}" \
  "${keychain_arguments[@]}" \
  --options runtime \
  --entitlements "${daemon_entitlements}" \
  "${cloud_broker_executable}"

"${release_python}" "${project_root}/tools/release_manifest.py" create \
  --root "${staging_root}" \
  --version "${version}" \
  --git-commit "${git_commit}" \
  --git-dirty "${git_dirty}" \
  --source-date-epoch "${SOURCE_DATE_EPOCH}" \
  --model-manifest \
    "${staging_root}/models/rimeai-ranker-s-24m-v1/manifest.json" \
  --fusion-config \
    "${staging_root}/models/rimeai-ranker-s-24m-fusion-v1.json" \
  --beam-config "${staging_root}/models/p0-beam-sentence-v3.json" \
  --language-model "${staging_root}/models/p0-char-ngram-v2.json.gz" \
  --dictionary "${staging_root}/models/luna_pinyin.dict.yaml" \
  --python-version "${python_version}" \
  --pyinstaller-version "${pyinstaller_version}"
"${release_python}" "${project_root}/tools/release_manifest.py" verify \
  --root "${staging_root}"
"${project_root}/scripts/verify_daemon_release.sh" "${staging_root}"

expected_artifact_id=$(
  "${release_python}" - \
    "${staging_root}/models/rimeai-ranker-s-24m-fusion-v1.json" \
    "${staging_root}/models/p0-beam-sentence-v3.json" <<'PY'
import hashlib
import json
import sys
with open(sys.argv[1], encoding="utf-8") as file:
    fusion_id = json.load(file)["artifact_id"]
with open(sys.argv[2], "rb") as file:
    beam_digest = hashlib.sha256(file.read()).hexdigest()
print("%s:beam-%s" % (fusion_id, beam_digest[:12]))
PY
)
runtime_directory="${build_root}/runtime"
mkdir -m 700 "${runtime_directory}"
socket_file="${runtime_directory}/rimeai.sock"
daemon_log="${build_root}/daemon.log"
"${daemon_executable}" \
  --socket "${socket_file}" \
  --language-model "${staging_root}/models/p0-char-ngram-v2.json.gz" \
  --beam-config "${staging_root}/models/p0-beam-sentence-v3.json" \
  --rime-dictionary "${staging_root}/models/luna_pinyin.dict.yaml" \
  --neural-model "${staging_root}/models/rimeai-ranker-s-24m-v1" \
  --fusion-config \
    "${staging_root}/models/rimeai-ranker-s-24m-fusion-v1.json" \
  --neural-device cpu >"${daemon_log}" 2>&1 &
daemon_pid=$!
ready=0
for _ in {1..240}; do
  if [[ -S "${socket_file}" ]]; then
    ready=1
    break
  fi
  if ! kill -0 "${daemon_pid}" 2>/dev/null; then
    break
  fi
  sleep 0.5
done
if (( ! ready )); then
  print -u2 "error: frozen daemon did not become ready"
  tail -n 40 "${daemon_log}" >&2 || true
  exit 1
fi
"${release_python}" "${project_root}/tools/probe_daemon_release.py" \
  --socket "${socket_file}" \
  --expected-artifact-id "${expected_artifact_id}" \
  --requests 20
if lsof -nP -a -p "${daemon_pid}" -i \
  >"${build_root}/inet-sockets.txt"; then
  if [[ -s "${build_root}/inet-sockets.txt" ]]; then
    print -u2 "error: frozen daemon opened an INET socket"
    sed -n '1,40p' "${build_root}/inet-sockets.txt" >&2
    exit 1
  fi
fi
kill -TERM "${daemon_pid}"
wait "${daemon_pid}"
daemon_pid=""

COPYFILE_DISABLE=1 tar -czf "${temporary_archive}" \
  -C "${staging_parent}" "${release_directory_name}"
"${project_root}/scripts/verify_daemon_archive.sh" "${temporary_archive}"
archive_digest=$(shasum -a 256 "${temporary_archive}" | awk '{ print $1 }')
print -r -- "${archive_digest}  ${output_archive:t}" > "${temporary_checksum}"
mv "${temporary_archive}" "${output_archive}"
mv "${temporary_checksum}" "${checksum_output}"
print -r -- "release=${output_archive}"
print -r -- "sha256=${archive_digest}"
print -r -- "version=${version}"
print -r -- "signing_identity=${signing_identity}"
