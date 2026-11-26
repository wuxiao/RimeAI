#!/bin/zsh
# shellcheck disable=SC1071

set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
shared_models_home="${AI_MODELS_HOME:-${HOME}/Models}"
shared_models_home="${shared_models_home/#\~/${HOME}}"
legacy_model_root="${project_root}/.rimeai/models"

resolve_hf_cached_model_dir() {
  local hf_hub_cache=""
  if [[ -n "${HF_HUB_CACHE:-}" ]]; then
    hf_hub_cache="${HF_HUB_CACHE/#\~/${HOME}}"
  elif [[ -n "${HF_HOME:-}" ]]; then
    hf_hub_cache="${HF_HOME/#\~/${HOME}}/hub"
  else
    hf_hub_cache="${HOME}/.cache/huggingface/hub"
  fi
  local repo_dir="${hf_hub_cache}/models--mlx-community--Qwen3-ASR-0.6B-8bit"
  local ref_file="${repo_dir}/refs/main"
  if [[ -f "${ref_file}" ]]; then
    local rev
    rev="$(tr -d '[:space:]' < "${ref_file}")"
    if [[ -n "${rev}" && -f "${repo_dir}/snapshots/${rev}/config.json" ]]; then
      print -r -- "${repo_dir}/snapshots/${rev}"
      return 0
    fi
  fi
  local snap
  for snap in "${repo_dir}"/snapshots/*(N/); do
    if [[ -f "${snap}/config.json" ]]; then
      print -r -- "${snap}"
      return 0
    fi
  done
  return 1
}

resolve_model_dir() {
  if [[ -n "${RIMEAI_VOICE_MLX_MODEL_DIR:-}" ]]; then
    print -r -- "${RIMEAI_VOICE_MLX_MODEL_DIR/#\~/${HOME}}"
    return 0
  fi
  if [[ -n "${RIMEAI_MODEL_ROOT:-}" ]]; then
    local explicit_root="${RIMEAI_MODEL_ROOT/#\~/${HOME}}"
    print -r -- "${explicit_root}/qwen3-asr-0.6b-8bit"
    return 0
  fi
  local shared_candidate="${shared_models_home}/qwen3-asr-0.6b-8bit"
  if [[ -d "${shared_candidate}" ]]; then
    print -r -- "${shared_candidate}"
    return 0
  fi
  local hf_candidate
  if hf_candidate="$(resolve_hf_cached_model_dir)"; then
    print -r -- "${hf_candidate}"
    return 0
  fi
  local legacy_candidate="${legacy_model_root}/qwen3-asr-0.6b-8bit"
  if [[ -d "${legacy_candidate}" ]]; then
    print -r -- "${legacy_candidate}"
    return 0
  fi
  print -r -- "${shared_candidate}"
}

resolve_voice_venv() {
  if [[ -n "${RIMEAI_VOICE_MLX_VENV:-}" ]]; then
    print -r -- "${RIMEAI_VOICE_MLX_VENV/#\~/${HOME}}"
    return 0
  fi
  local candidates=(
    "${shared_models_home}/runtimes/voice-mlx-venv"
    "${project_root}/.rimeai/voice-mlx-venv"
  )
  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -x "${candidate}/bin/python" ]]; then
      print -r -- "${candidate}"
      return 0
    fi
  done
  print -r -- "${candidates[1]}"
}

model_dir="$(resolve_model_dir)"
voice_venv="$(resolve_voice_venv)"

if [[ ! -d "${model_dir}" ]]; then
  print -u2 "error: Qwen3-ASR MLX model missing at ${model_dir}"
  exit 2
fi
if [[ ! -x "${voice_venv}/bin/python" ]]; then
  print -u2 "error: isolated voice MLX venv missing at ${voice_venv}"
  exit 2
fi

export HF_HUB_OFFLINE=1
export TRANSFORMERS_OFFLINE=1
export HF_HUB_DISABLE_TELEMETRY=1
export DO_NOT_TRACK=1
export TOKENIZERS_PARALLELISM=false
export RIMEAI_VOICE_MLX_MODEL_DIR="${model_dir}"
export PYTHONPATH="${project_root}${PYTHONPATH:+:${PYTHONPATH}}"
export NO_PROXY='*'
export no_proxy='*'

exec "${voice_venv}/bin/python" -m rimeai_runtime.qwen3_asr_worker
