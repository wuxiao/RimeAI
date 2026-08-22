#!/bin/bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
manifest_json="$(mktemp /private/tmp/rimeai-tracer-package.XXXXXX)"
trap 'rm -f "$manifest_json"' EXIT

cd "$repo_root"
env \
  COPYFILE_DISABLE=1 \
  CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/rimeai-tracer-package-clang}" \
  SWIFT_MODULE_CACHE_PATH="${SWIFT_MODULE_CACHE_PATH:-/private/tmp/rimeai-tracer-package-swift}" \
  swift package --disable-sandbox dump-package > "$manifest_json"

python3 - "$manifest_json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    package = json.load(handle)

products = {product["name"]: product for product in package["products"]}
targets = {target["name"]: target for target in package["targets"]}

expected = {
    "rimeai-voice-performance-tracer": (
        "RimeAIVoicePerformanceTracerCollectorExecutable",
        "RimeAIVoicePerformanceTracerCollectorProcess",
    ),
    "rimeai-voice-performance-driver": (
        "RimeAIVoicePerformanceTracerDriverExecutable",
        "RimeAIVoicePerformanceTracerDriverProcess",
    ),
    "rimeai-voice-performance-helper": (
        "RimeAIVoicePerformanceTracerHelperExecutable",
        "RimeAIVoicePerformanceTracerHelperProcess",
    ),
}

def dependency_names(target):
    names = []
    for dependency in target["dependencies"]:
        if "byName" not in dependency:
            raise AssertionError(
                f"{target['name']} has non-byName dependency: {dependency}"
            )
        names.append(dependency["byName"][0])
    return names

for product_name, (target_name, process_name) in expected.items():
    product = products[product_name]
    assert product["type"] == {"executable": None}, product
    assert product["targets"] == [target_name], product

    target = targets[target_name]
    assert target["type"] == "executable", target
    assert dependency_names(target) == [process_name], target
    assert len(target["dependencies"]) == 1, target

production_helper_dependencies = dependency_names(targets["RimeAIVoiceHelper"])
assert production_helper_dependencies == [
    "RimeAIInputCore",
    "RimeAIVoiceHelperEngine",
], production_helper_dependencies
assert not set(production_helper_dependencies) & {
    target_name for target_name, _ in expected.values()
}
PY

echo "voice performance tracer executable isolation: PASS"
