#!/bin/bash

set -euo pipefail

test_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
project_root="$(dirname -- "$test_dir")"
scratch_root="$(mktemp -d "${TMPDIR:-/tmp}/rimeai-voice-helper-isolation.XXXXXX")"
trap 'rm -rf "$scratch_root"' EXIT

mkdir -p "$scratch_root/clang-module-cache" "$scratch_root/swift-module-cache"

(
    cd "$project_root"
    CLANG_MODULE_CACHE_PATH="$scratch_root/clang-module-cache" \
        SWIFT_MODULECACHE_PATH="$scratch_root/swift-module-cache" \
        swift package --disable-sandbox dump-package \
        > "$scratch_root/package.json"
)

/usr/bin/python3 - "$scratch_root/package.json" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as package_file:
    package = json.load(package_file)

targets = {target["name"]: target for target in package["targets"]}
root = "RimeAIVoiceHelper"
if root not in targets:
    raise SystemExit(f"missing production helper target: {root}")


def dependency_name(dependency):
    for key in ("byName", "target", "product"):
        value = dependency.get(key)
        if value:
            return value[0] if isinstance(value, list) else value
    raise SystemExit(f"unknown dependency shape: {dependency!r}")


tracer_target = "RimeAIVoicePerformanceTracerDarwin"
tracer_dependencies = [
    dependency_name(dependency)
    for dependency in targets[tracer_target].get("dependencies", [])
]
expected_tracer_dependencies = [
    "RimeAIVoicePerformanceCollector",
    "RimeAIVoicePerformanceControlDarwin",
]
if tracer_dependencies != expected_tracer_dependencies:
    raise SystemExit(
        f"{tracer_target} dependencies must be exact and unique: "
        f"expected {expected_tracer_dependencies!r}, "
        f"got {tracer_dependencies!r}"
    )


closure = set()
pending = [root]
while pending:
    name = pending.pop()
    if name in closure:
        continue
    closure.add(name)
    target = targets.get(name)
    if target is None:
        continue
    pending.extend(
        dependency_name(dependency)
        for dependency in target.get("dependencies", [])
    )

forbidden = re.compile(r"(?:Performance|Tracer|Evaluation|Control)")
leaks = sorted(name for name in closure if forbidden.search(name))
if leaks:
    raise SystemExit(
        "production helper target closure contains tracer-only targets: "
        + ", ".join(leaks)
    )

print("production helper target closure is tracer-free: " + ", ".join(sorted(closure)))
PY

forbidden_source_pattern='VoiceHelperPerformanceTracer|VoiceHelperInternalTracer|VoiceASREvaluationArtifact|WAVReplayPCMSource|PerformanceControl|@_spi\(VoiceEvaluation\)'
source_matches="$(
    rg -n "$forbidden_source_pattern" \
        "$project_root/Sources/RimeAIVoiceHelper/Engine" \
        "$project_root/Sources/RimeAIInputCore" \
        || true
)"
if [[ -n "$source_matches" ]]; then
    echo "production Swift targets contain tracer-only source:" >&2
    echo "$source_matches" >&2
    exit 1
fi

if rg -n 'VoiceASREvaluationArtifact|WAVReplayPCMSource' \
    "$project_root/macos/RimeAIInputMethod.xcodeproj/project.pbxproj"
then
    echo "production Xcode source graph contains evaluation-only files" >&2
    exit 1
fi

echo "production Swift and Xcode source graphs are tracer-free"
