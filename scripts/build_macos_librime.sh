#!/bin/zsh

set -euo pipefail

if [[ $# -ne 1 ]]; then
  print -u2 "usage: $0 OUTPUT.xcframework"
  exit 2
fi
if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
  print -u2 "error: controlled macOS librime must be built on Apple silicon"
  exit 2
fi
for build_tool in cmake curl git xcodebuild xcrun; do
  if ! command -v "${build_tool}" >/dev/null 2>&1; then
    print -u2 "error: required build tool is missing: ${build_tool}"
    exit 2
  fi
done

script_dir=${0:A:h}
project_root=${script_dir:h}
lock_file="${project_root}/macos/Native/source-lock.json"
output_artifact=${1:A}
if [[ "${output_artifact}" != *.xcframework ]]; then
  print -u2 "error: output must end in .xcframework"
  exit 2
fi
if [[ -e "${output_artifact}" || -L "${output_artifact}" ]]; then
  print -u2 "error: refusing to overwrite controlled artifact: ${output_artifact}"
  exit 2
fi
if [[ ! -f "${lock_file}" ]]; then
  print -u2 "error: macOS librime source lock is missing"
  exit 2
fi

librime_revision=$(plutil -extract librime.revision raw -o - "${lock_file}")
boost_url=$(plutil -extract boost.url raw -o - "${lock_file}")
boost_sha=$(plutil -extract boost.archive_sha256 raw -o - "${lock_file}")
leveldb_revision=$(
  plutil -extract librime_submodules.leveldb raw -o - "${lock_file}"
)
marisa_revision=$(
  plutil -extract librime_submodules.marisa-trie raw -o - "${lock_file}"
)
opencc_revision=$(
  plutil -extract librime_submodules.opencc raw -o - "${lock_file}"
)
yaml_revision=$(
  plutil -extract librime_submodules.yaml-cpp raw -o - "${lock_file}"
)

build_root=$(mktemp -d /tmp/rimeai-librime-build.XXXXXX)
source_root="${build_root}/librime"
dependency_prefix="${build_root}/prefix"
artifact_staging="${build_root}/RimeAIMacRuntime.xcframework"
source_cache=${RIMEAI_SOURCE_CACHE:-"${HOME}/Library/Caches/RimeAI/build-sources"}
cleanup() {
  case "${build_root}" in
    /tmp/rimeai-librime-build.*) find "${build_root}" -depth -delete ;;
    *) print -u2 "error: refusing to clean unexpected build path" ;;
  esac
}
trap cleanup EXIT

export COPYFILE_DISABLE=1
export MACOSX_DEPLOYMENT_TARGET=14.0
export ZERO_AR_DATE=1
sdk_root=$(xcrun --sdk macosx --show-sdk-path)
processor_count=$(sysctl -n hw.logicalcpu)
mkdir -p "${source_cache}"
common_cmake_arguments=(
  "-DCMAKE_BUILD_TYPE=Release"
  "-DCMAKE_INSTALL_PREFIX=${dependency_prefix}"
  "-DCMAKE_OSX_ARCHITECTURES=arm64"
  "-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0"
  "-DCMAKE_OSX_SYSROOT=${sdk_root}"
  "-DCMAKE_POSITION_INDEPENDENT_CODE=ON"
  "-DCMAKE_PREFIX_PATH=${dependency_prefix}"
  "-DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew;/usr/local"
)

git_mirror="${source_cache}/librime.git"
if [[ ! -d "${git_mirror}" ]]; then
  git clone --quiet --mirror https://github.com/rime/librime.git "${git_mirror}"
else
  git -C "${git_mirror}" fetch --quiet --prune origin
fi
git clone --quiet --reference-if-able "${git_mirror}" \
  --filter=blob:none --no-checkout \
  https://github.com/rime/librime.git "${source_root}"
git -C "${source_root}" fetch --quiet --depth 1 origin "${librime_revision}"
git -C "${source_root}" -c advice.detachedHead=false \
  checkout --quiet --detach "${librime_revision}"
git -C "${source_root}" submodule update \
  --init --recursive --depth 1 --quiet
if [[ "$(git -C "${source_root}" rev-parse HEAD)" != "${librime_revision}" \
  || "$(git -C "${source_root}/deps/leveldb" rev-parse HEAD)" \
    != "${leveldb_revision}" \
  || "$(git -C "${source_root}/deps/marisa-trie" rev-parse HEAD)" \
    != "${marisa_revision}" \
  || "$(git -C "${source_root}/deps/opencc" rev-parse HEAD)" \
    != "${opencc_revision}" \
  || "$(git -C "${source_root}/deps/yaml-cpp" rev-parse HEAD)" \
    != "${yaml_revision}" ]]; then
  print -u2 "error: checked-out librime source does not match the source lock"
  exit 1
fi

cached_boost_archive="${source_cache}/boost_1_91_0.tar.bz2"
if [[ -f "${cached_boost_archive}" ]]; then
  cached_boost_sha=$(
    shasum -a 256 "${cached_boost_archive}" | awk '{ print $1 }'
  )
  if [[ "${cached_boost_sha}" != "${boost_sha}" ]]; then
    print -u2 "error: cached Boost archive does not match source lock"
    exit 1
  fi
else
  temporary_boost_archive="${source_cache}/.boost_1_91_0.${$}.download"
  curl --fail --location --silent --show-error \
    "${boost_url}" --output "${temporary_boost_archive}"
  downloaded_boost_sha=$(
    shasum -a 256 "${temporary_boost_archive}" | awk '{ print $1 }'
  )
  if [[ "${downloaded_boost_sha}" != "${boost_sha}" ]]; then
    print -u2 "error: Boost archive checksum does not match source lock"
    exit 1
  fi
  /bin/mv "${temporary_boost_archive}" "${cached_boost_archive}"
fi
boost_archive="${build_root}/boost.tar.bz2"
cp "${cached_boost_archive}" "${boost_archive}"
actual_boost_sha=$(shasum -a 256 "${boost_archive}" | awk '{ print $1 }')
if [[ "${actual_boost_sha}" != "${boost_sha}" ]]; then
  print -u2 "error: Boost archive checksum does not match source lock"
  exit 1
fi
tar -xjf "${boost_archive}" -C "${build_root}"
boost_source="${build_root}/boost_1_91_0"
(
  cd "${boost_source}"
  ./bootstrap.sh \
    --prefix="${dependency_prefix}" \
    --with-libraries=regex >/dev/null
  ./b2 \
    --layout=system \
    --prefix="${dependency_prefix}" \
    architecture=arm \
    address-model=64 \
    cxxflags="-arch arm64 -mmacosx-version-min=14.0" \
    link=static \
    linkflags="-arch arm64 -mmacosx-version-min=14.0" \
    runtime-link=shared \
    target-os=darwin \
    threading=multi \
    variant=release \
    --with-regex \
    -j"${processor_count}" \
    install >/dev/null
)

configure_and_install() {
  local source_directory=$1
  local build_directory=$2
  shift 2
  cmake -S "${source_directory}" -B "${build_directory}" \
    "${common_cmake_arguments[@]}" "$@"
  cmake --build "${build_directory}" \
    --config Release --target install --parallel "${processor_count}"
}

configure_and_install \
  "${source_root}/deps/leveldb" "${build_root}/build-leveldb" \
  -DBUILD_SHARED_LIBS=OFF \
  -DLEVELDB_BUILD_BENCHMARKS=OFF \
  -DLEVELDB_BUILD_TESTS=OFF \
  -DLEVELDB_INSTALL=ON \
  -DHAVE_CRC32C=OFF \
  -DHAVE_SNAPPY=OFF
configure_and_install \
  "${source_root}/deps/marisa-trie" "${build_root}/build-marisa" \
  -DBUILD_SHARED_LIBS=OFF \
  -DBUILD_TESTING=OFF \
  -DENABLE_TOOLS=OFF
configure_and_install \
  "${source_root}/deps/opencc" "${build_root}/build-opencc" \
  -DBUILD_DOCUMENTATION=OFF \
  -DBUILD_PYTHON=OFF \
  -DBUILD_SHARED_LIBS=OFF \
  -DENABLE_BENCHMARK=OFF \
  -DENABLE_GTEST=OFF \
  "-DCMAKE_CXX_FLAGS=-I${dependency_prefix}/include" \
  -DPYTHON_EXECUTABLE=/usr/bin/python3 \
  -DPython_EXECUTABLE=/usr/bin/python3 \
  -DUSE_SYSTEM_MARISA=ON
configure_and_install \
  "${source_root}/deps/yaml-cpp" "${build_root}/build-yaml" \
  -DBUILD_SHARED_LIBS=OFF \
  -DYAML_BUILD_SHARED_LIBS=OFF \
  -DYAML_CPP_BUILD_CONTRIB=OFF \
  -DYAML_CPP_BUILD_TESTS=OFF \
  -DYAML_CPP_BUILD_TOOLS=OFF

cmake -S "${source_root}" -B "${build_root}/build-librime" \
  "${common_cmake_arguments[@]}" \
  -DBOOST_INCLUDEDIR="${dependency_prefix}/include" \
  -DBOOST_LIBRARYDIR="${dependency_prefix}/lib" \
  -DBOOST_ROOT="${dependency_prefix}" \
  -DBoost_NO_BOOST_CMAKE=ON \
  -DBoost_NO_SYSTEM_PATHS=ON \
  -DBUILD_DATA=OFF \
  -DBUILD_MERGED_PLUGINS=ON \
  -DBUILD_SAMPLE=OFF \
  -DBUILD_SHARED_LIBS=OFF \
  -DBUILD_STATIC=ON \
  -DBUILD_TEST=OFF \
  -DENABLE_EXTERNAL_PLUGINS=OFF \
  -DENABLE_LOGGING=OFF \
  -DENABLE_TIMESTAMP=OFF
cmake --build "${build_root}/build-librime" \
  --config Release --target install --parallel "${processor_count}"

static_libraries=(
  "${dependency_prefix}/lib/librime.a"
  "${dependency_prefix}/lib/libboost_regex.a"
  "${dependency_prefix}/lib/libleveldb.a"
  "${dependency_prefix}/lib/libmarisa.a"
  "${dependency_prefix}/lib/libopencc.a"
  "${dependency_prefix}/lib/libyaml-cpp.a"
)
for static_library in "${static_libraries[@]}"; do
  if [[ ! -f "${static_library}" ]]; then
    print -u2 "error: expected static dependency is missing: ${static_library}"
    exit 1
  fi
  if [[ "$(lipo -archs "${static_library}")" != "arm64" ]]; then
    print -u2 "error: static dependency is not arm64: ${static_library}"
    exit 1
  fi
done

combined_library="${build_root}/libRimeAIMacRuntime.a"
xcrun libtool -static -D -o "${combined_library}" \
  "${static_libraries[@]}"
xcrun ranlib "${combined_library}"
headers_directory="${build_root}/Headers"
mkdir "${headers_directory}"
install -m 644 \
  "${dependency_prefix}/include/rime_api.h" \
  "${dependency_prefix}/include/rime_api_stdbool.h" \
  "${dependency_prefix}/include/rime_api_deprecated.h" \
  "${headers_directory}/"
xcodebuild -create-xcframework \
  -library "${combined_library}" \
  -headers "${headers_directory}" \
  -output "${artifact_staging}"
find "${artifact_staging}" -exec xattr -c {} + 2>/dev/null || true
"${project_root}/scripts/verify_macos_librime.sh" "${artifact_staging}"

mkdir -p "${output_artifact:h}"
COPYFILE_DISABLE=1 rsync -a --exclude='._*' \
  "${artifact_staging}/" "${output_artifact}/"
# exFAT can materialize AppleDouble sidecars while receiving otherwise clean
# files. They are not part of the controlled artifact and break its inventory.
find "${output_artifact}" -type f -name '._*' -delete
"${project_root}/scripts/verify_macos_librime.sh" "${output_artifact}"
print -r -- "artifact=${output_artifact}"
print -r -- "library_sha256=$(shasum -a 256 \
  "${output_artifact}"/*/libRimeAIMacRuntime.a | awk '{ print $1 }')"
print -r -- "librime_revision=${librime_revision}"
