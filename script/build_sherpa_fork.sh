#!/usr/bin/env bash
# SECURITY-001：重建 sherpa-onnx 冻结 fork xcframework。
#
# 基线：k2-fsa/sherpa-onnx v1.13.6（tag commit 1cb484af）
# 补丁：third-party/sherpa-onnx-v1.13.6-buffer-loader.patch
#   （csrc + C API 的模型 buffer 加载通路：*_buf / *_buf_size 字段，
#   zipformer / zipformer2 / paraformer 三族构造 buffer 优先分支，
#   fork 身份 1cb484af-rimeai-buffer）
# 产物：macos/Native/SherpaOnnxMacOS-fork.xcframework（repo 内
#   binaryTarget path: 引用；Package.swift 不再用上游 URL）
#
# 上游 v1.13.8 与 master 均无模型 buffer API（仅 tokens_buf，见
# c-api-examples/streaming-paraformer-buffered-tokens-c-api.c），升级
# 不消除 pathname TOCTOU 窗口——fork 是 SECURITY-001 的裁决结果。
#
# 用法：script/build_sherpa_fork.sh [workdir]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${1:-$(mktemp -d /tmp/sherpa-fork.XXXXXX)}"
TAG="v1.13.6"
BASE_COMMIT="1cb484af"
PATCH="$ROOT/third-party/sherpa-onnx-v1.13.6-buffer-loader.patch"
DEST="$ROOT/macos/Native/SherpaOnnxMacOS-fork.xcframework"

echo "== workdir: $WORK"
cd "$WORK"
if [ ! -d sherpa-src ]; then
    git clone --depth 1 --branch "$TAG" \
        https://github.com/k2-fsa/sherpa-onnx.git sherpa-src
fi
cd sherpa-src
HEAD_SHA="$(git rev-parse --short HEAD)"
if [ "$HEAD_SHA" != "$BASE_COMMIT" ]; then
    echo "unexpected base commit $HEAD_SHA (want $BASE_COMMIT)" >&2
    exit 1
fi
git apply "$PATCH"

# 上游官方构建脚本（cmake universal -> libtool -> framework bundle ->
# xcframework zip + checksum）
./build-macos.sh

ZIP="build-macos/sherpa-onnx-v1.13.6-macos-static.xcframework.zip"
rm -rf /tmp/sherpa-fork-xf && mkdir -p /tmp/sherpa-fork-xf
unzip -q "$ZIP" -d /tmp/sherpa-fork-xf

# 身份自检：二进制必须嵌入 fork 标识。
strings /tmp/sherpa-fork-xf/sherpa-onnx.xcframework/macos-arm64_x86_64/SherpaOnnxC.framework/Versions/A/SherpaOnnxC \
    | grep -q '1cb484af-rimeai-buffer' || {
    echo "fork identity string missing from built binary" >&2
    exit 1
}
grep -q 'encoder_buf' /tmp/sherpa-fork-xf/sherpa-onnx.xcframework/macos-arm64_x86_64/SherpaOnnxC.framework/Versions/A/Headers/sherpa-onnx/c-api/c-api.h || {
    echo "buffer API missing from built header" >&2
    exit 1
}

rm -rf "$DEST"
cp -R /tmp/sherpa-fork-xf/sherpa-onnx.xcframework "$DEST"
echo "== installed: $DEST"
du -sh "$DEST"
