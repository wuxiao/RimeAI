#!/bin/zsh

set -euo pipefail

PROJECT_ROOT=${0:A:h:h}
TEST_ROOT=$(mktemp -d /private/tmp/rimeai-partial-selection-tests.XXXXXX)
case "$TEST_ROOT" in
  /private/tmp/rimeai-partial-selection-tests.*) ;;
  *) exit 90 ;;
esac
trap '/usr/bin/trash "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/user"
cp -R "$PROJECT_ROOT/ios/RimeData/shared" "$TEST_ROOT/shared"
cp -R "$PROJECT_ROOT/ios/RimeData/user-build" "$TEST_ROOT/user/build"

COMMON_SOURCES=(
  "$PROJECT_ROOT/Sources/RimeBridgeC/RimeBridgeC.cc"
  "$PROJECT_ROOT/macos/Native/RimeAIMacRuntime.xcframework/macos-arm64/libRimeAIMacRuntime.a"
)
COMMON_FLAGS=(
  -std=c++17
  -DRIMEAI_BRIDGE_TESTING
  -I "$PROJECT_ROOT/Sources/RimeBridgeC/include"
  -I "$PROJECT_ROOT/ios/Native/include"
)

/usr/bin/xcrun --sdk macosx clang++ \
  "${COMMON_FLAGS[@]}" \
  "$PROJECT_ROOT/tests/RimeBridgeSelectionParsingTests.cc" \
  "${COMMON_SOURCES[@]}" \
  -o "$TEST_ROOT/selection-parser-test"
"$TEST_ROOT/selection-parser-test"

/usr/bin/xcrun --sdk macosx clang++ \
  "${COMMON_FLAGS[@]}" \
  "$PROJECT_ROOT/tests/RimeBridgePartialSelectionIntegration.cc" \
  "${COMMON_SOURCES[@]}" \
  -o "$TEST_ROOT/partial-selection-integration-test"
"$TEST_ROOT/partial-selection-integration-test" \
  "$TEST_ROOT/shared" \
  "$TEST_ROOT/user"

print -- "Rime partial candidate selection tests passed"
