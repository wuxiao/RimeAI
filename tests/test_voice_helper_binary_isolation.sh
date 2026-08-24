#!/bin/bash

set -euo pipefail

if [[ "$#" -ne 1 ]]; then
    echo "usage: $0 /absolute/path/to/rimeai-voice-helper" >&2
    exit 64
fi

helper_binary="$1"
if [[ ! -f "$helper_binary" || ! -x "$helper_binary" ]]; then
    echo "not an executable helper binary: $helper_binary" >&2
    exit 66
fi

forbidden_pattern='RimeAIVoicePerformance|VoiceHelperPerformanceTracer|VoiceHelperInternalTracer|VoiceASREvaluation|VoiceEvaluation|WAVReplayPCMSource|PerformanceControl|evaluationFactory|evaluationArtifact'

string_matches="$(LC_ALL=C strings -a "$helper_binary" | grep -E "$forbidden_pattern" || true)"
if [[ -n "$string_matches" ]]; then
    echo "production helper contains tracer-only strings:" >&2
    echo "$string_matches" >&2
    exit 1
fi

symbol_matches="$(nm -gj "$helper_binary" | grep -E "$forbidden_pattern" || true)"
if [[ -n "$symbol_matches" ]]; then
    echo "production helper exports tracer-only symbols:" >&2
    echo "$symbol_matches" >&2
    exit 1
fi

echo "production helper binary is tracer-free: $helper_binary"
