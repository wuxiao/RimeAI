"""Pinned MLX 8-bit worker for pinyin-constrained sentence decoding.

Zero-prompt constrained decoding, identical in decision semantics to the
frozen torch worker (tools/constrained_qwen_worker.py,
docs/baselines/constrained-qwen-v2.json): same seed context, same
ConstrainedGreedyDecoder beam (width 4, fuzzy pairs), same final fuzzy
gate. Confidence is the pinyin-mask-renormalized geometric mean (see
DecodeResult / constrained_worker_protocol): each step scores the
chosen token as p / Z over that step's allowed candidates, so values
are length-comparable in [0,1]; the legacy RAW softmax geometric mean
rides along in stats.confidence_raw for evaluation-side comparison.
An optional RIMEAI_MLX_LENGTH_PENALTY environment knob (float >= 0,
default 0.0) enables the beam length penalty (GNMT-style
log_p / steps**penalty ranking) for tuning experiments — 0.0 keeps
the frozen joint-log-probability ranking bit-identical. The engine
differs only in numeric precision (8-bit affine MLX weights, fp16
activations; 4-bit was measured to collapse the seed-boundary
distribution this route depends on — see
models/qwen2.5-0.5b-mlx-8bit.lock.json
precision_decision) and in KV management:

- one persistent prompt cache serves base (seed+context) AND beam paths,
  across requests;
- every probability read rolls the cache back to the longest common
  token prefix of the target sequence and feeds only the delta, so each
  beam path is still scored against its OWN full history (the per-path
  KV correctness of constrained-v2) while common prefixes are computed
  once (the cross-path sharing named in the v2 baseline's history note,
  plus the cross-request persistent prefix cache that
  docs/baselines/phase2-4bit-mlx-latency-spike.json identifies as the
  biggest latency lever).

Runs inside the isolated MLX venv (.rimeai/mlx-venv, see
script/constrained_mlx_service.sh); the repo's pinned
torch/transformers stay untouched. MLX imports go through importlib so
the module (and its tests) import in the repo venv without mlx.
"""
from __future__ import annotations

import hashlib
import importlib
import json
import math
import os
import sys
import traceback
from abc import ABC, abstractmethod
from collections.abc import Callable, Sequence
from pathlib import Path
from time import monotonic
from typing import Any

from .constrained_decoder import (
    ConstrainedGreedyDecoder,
    DecodeResult,
    PinyinTokenIndex,
    fuzzy_segment_ok,
)
from .constrained_worker_protocol import (
    CONFIDENCE_CALIBER_MASK_RENORM,
    GenerateRequestError,
    generate_response,
    validate_generate_request,
)
from .pinyin_guard import PinyinGuard, segment_generic_pinyin
from .user_lm_view import UserLanguageModelView, UserLmViewError

MODEL_NAME = "qwen2.5-0.5b"
MODEL_REVISION = "060db6499f32faf8b98477b0a26969ef7d8b9987"
SOURCE_WEIGHTS_SHA256 = (
    # fp16 source lock models/qwen2.5-0.5b.lock.json
    "88c142557820ccad55bb59756bfcfcf891de9cc6202816bd346445188a0ed342"
)
MLX_WEIGHTS_SHA256 = (
    "9bc6f756079b502d08409edd09e24ad439429756e22fb6b9a15ae90f518e0d66"
)
MLX_QUANTIZATION = {"bits": 8, "group_size": 64, "mode": "affine"}
EXPECTED_MLX = "0.32.4"
EXPECTED_MLX_LM = "0.32.2"
PROMPT_VERSION = "constrained-v3-mlx"
BEAM_WIDTH = 4
# Identical to the frozen torch worker: a one-token sentence-boundary
# stabilizer, never a prompt or chat template.
SEED_CONTEXT = "。"


def _beam_length_penalty() -> float:
    """Beam length penalty from RIMEAI_MLX_LENGTH_PENALTY (default 0.0).

    0.0 keeps the frozen joint-log-probability beam ranking; the knob
    exists for validation-split tuning only. Invalid values (non-float,
    negative, non-finite — reveal A-F1: ``nan`` slipped past the range
    check because ``nan < 0`` and ``nan > 4`` are both False) fail
    closed so a typo can never silently rerank the beam. Parsed ONCE
    at startup in main() (reveal A-F5); handle_request reuses the
    engine-stored value.
    """
    raw = os.environ.get("RIMEAI_MLX_LENGTH_PENALTY")
    if raw is None or raw == "":
        return 0.0
    try:
        value = float(raw)
    except ValueError as error:
        raise MlxEngineError(
            f"RIMEAI_MLX_LENGTH_PENALTY must be a float, got {raw!r}"
        ) from error
    if not math.isfinite(value):
        raise MlxEngineError(
            "RIMEAI_MLX_LENGTH_PENALTY must be a finite float, "
            f"got {raw!r}"
        )
    if value < 0.0 or value > 4.0:
        raise MlxEngineError(
            f"RIMEAI_MLX_LENGTH_PENALTY must be within [0, 4], got {value}"
        )
    return value


# L2 用户 LM 浅融合旋钮上限：与 daemon 侧 MAX_USER_WEIGHT 同量级，
# λ>1 意味着用户证据压过神经 LM 本身，不属于本融合的设计域。
MAX_USER_LM_WEIGHT = 1.0


def _user_lm_fusion_config() -> tuple[UserLanguageModelView | None, float]:
    """Optional user-LM shallow fusion from the environment (default off).

    RIMEAI_MLX_USER_LM_PATH + RIMEAI_MLX_USER_LM_WEIGHT enable L2
    shallow fusion into the constrained beam's ranking score
    (log p_fused = log p_LM + λ·logP_user). Both must be set together;
    an unset pair keeps the frozen no-fusion behavior bit-identical.
    Every failure mode fails CLOSED (MlxEngineError): half-set pair,
    non-float weight, weight outside [0, 1], missing/unreadable/invalid
    artifact — never a silent degrade to "no user evidence", which
    would hide a deployment misconfiguration behind λ-degenerate
    output. The weight bound mirrors the daemon-side MAX_USER_WEIGHT
    caliber (0.1-0.35 in production IMEs); λ beyond 1 lets user
    evidence dominate the neural LM and is out of scope. A set pair
    with weight 0.0 still validates the artifact but leaves decoding
    bit-identical (fusion inactive at λ=0).
    """
    raw_path = os.environ.get("RIMEAI_MLX_USER_LM_PATH")
    raw_weight = os.environ.get("RIMEAI_MLX_USER_LM_WEIGHT")
    path_set = bool(raw_path)
    weight_set = bool(raw_weight)
    if not path_set and not weight_set:
        return None, 0.0
    if not path_set or not weight_set:
        raise MlxEngineError(
            "RIMEAI_MLX_USER_LM_PATH and RIMEAI_MLX_USER_LM_WEIGHT "
            "must be set together for user-LM shallow fusion"
        )
    try:
        weight = float(raw_weight)
    except ValueError as error:
        raise MlxEngineError(
            f"RIMEAI_MLX_USER_LM_WEIGHT must be a float, got {raw_weight!r}"
        ) from error
    if not math.isfinite(weight) or not 0.0 <= weight <= MAX_USER_LM_WEIGHT:
        raise MlxEngineError(
            "RIMEAI_MLX_USER_LM_WEIGHT must be within "
            f"[0, {MAX_USER_LM_WEIGHT}], got {weight}"
        )
    try:
        view = UserLanguageModelView.load(Path(raw_path))
    except UserLmViewError as error:
        raise MlxEngineError(f"cannot load user LM: {error}") from error
    return view, weight


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        while chunk := file.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def _load_artifact_manifest(model_dir: Path) -> dict[str, Any] | None:
    """读取制品目录的可选 manifest（LM-002 SFT fused 制品）。

    存在时必须含 weights_sha256（64 位十六进制）与 model_name；
    字段非法按 fail-closed 拒载，不允许半路降级到内置 pin。
    """
    path = model_dir / "artifact.manifest.json"
    if not path.is_file():
        return None
    try:
        manifest = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise MlxEngineError(
            f"cannot read artifact manifest: {error}"
        ) from error
    if not isinstance(manifest, dict):
        raise MlxEngineError("artifact manifest must be an object")
    sha = manifest.get("weights_sha256")
    if (
        not isinstance(sha, str)
        or len(sha) != 64
        or any(c not in "0123456789abcdef" for c in sha.lower())
    ):
        raise MlxEngineError(
            "artifact manifest weights_sha256 must be 64 hex chars"
        )
    if not isinstance(manifest.get("model_name"), str):
        raise MlxEngineError("artifact manifest model_name is required")
    manifest["weights_sha256"] = sha.lower()
    return manifest


_ACTIVE_MANIFEST: dict[str, Any] | None = None


def model_artifact_id() -> str:
    if _ACTIVE_MANIFEST:
        revision = str(_ACTIVE_MANIFEST.get("revision", ""))
        return (
            f"{_ACTIVE_MANIFEST['model_name']}@{revision[:8] or 'sft'}:"
            f"sha256-{_ACTIVE_MANIFEST['weights_sha256'][:12]}:"
            f"mlx-8bit:{PROMPT_VERSION}"
        )
    return (
        f"{MODEL_NAME}@{MODEL_REVISION[:8]}:"
        f"sha256-{MLX_WEIGHTS_SHA256[:12]}:"
        f"mlx-8bit:{PROMPT_VERSION}"
    )


def common_prefix_length(left: list[int], right: list[int]) -> int:
    bound = min(len(left), len(right))
    index = 0
    while index < bound and left[index] == right[index]:
        index += 1
    return index


class PrefixRollbackCache:
    """One trimmable KV cache rolled to a target token sequence.

    ``feed(delta)`` appends ``delta`` and returns one row per delta
    position (the next-token distribution source after consuming each
    prefix); ``trim(n)`` drops the last ``n`` tokens. Because every feed
    stores all rows of its window and trims only prune positions beyond
    the new length, the row for the current endpoint is always present
    (the rows dict covers exactly {1..len(tokens)}); a missing row is a
    backend contract violation and fails loud. Pure decision logic — no
    MLX dependency — so the parity tests drive it with a fake backend.
    """

    def __init__(self, backend: RollbackBackend) -> None:
        self._backend = backend
        self._tokens: list[int] = []
        self._rows: dict[int, Any] = {}
        self.stats = {
            "cache_fed_tokens": 0,
            "cache_trim_operations": 0,
        }

    @property
    def tokens(self) -> list[int]:
        return list(self._tokens)

    def distribution(self, target: list[int]) -> Any:
        wanted = [int(token) for token in target]
        common = common_prefix_length(self._tokens, wanted)
        if common < len(self._tokens):
            surplus = len(self._tokens) - common
            trimmed = self._backend.trim(surplus)
            if trimmed != surplus:
                raise RuntimeError(
                    "prompt cache is not trimmable; refusing to proceed"
                )
            del self._tokens[common:]
            for position in [key for key in self._rows if key > common]:
                del self._rows[position]
            self.stats["cache_trim_operations"] += 1
        if len(self._tokens) < len(wanted):
            start = len(self._tokens)
            delta = wanted[start:]
            rows = self._backend.feed(delta)
            if len(rows) != len(delta):
                raise RuntimeError("feed returned wrong number of rows")
            self._tokens = wanted
            self.stats["cache_fed_tokens"] += len(delta)
            for offset, row in enumerate(rows, start=1):
                self._rows[start + offset] = row
        row = self._rows.get(len(wanted))
        if row is None:
            # Unreachable for a conforming backend: rows cover exactly
            # {1..len(tokens)} (every feed stores its whole window and
            # trims only prune beyond the new length).
            raise RuntimeError(
                "backend dropped rows inside the cached prefix"
            )
        return self._backend.softmax(row)


class RollbackBackend(ABC):
    """Feed/trim/softmax surface the rollback cache drives."""

    @abstractmethod
    def feed(self, delta: list[int]) -> list[Any]:
        """Appends ``delta`` and returns one row per delta position."""
        ...

    @abstractmethod
    def trim(self, count: int) -> int:
        """Drops the last ``count`` tokens; returns tokens trimmed."""
        ...

    @abstractmethod
    def softmax(self, row: Any) -> Any:
        """Converts a row into a probability mapping."""
        ...

class MlxEngineError(RuntimeError):
    pass


def _import_mlx_modules() -> tuple[Any, Any, Any, Any]:
    """Imports the pinned MLX stack via importlib (optional dependency).

    Raises MlxEngineError when the interpreter is not the isolated MLX
    venv or the versions drift from the pinned ones.
    """
    try:
        mx = importlib.import_module("mlx.core")
        mlx_lm = importlib.import_module("mlx_lm")
        mlx_lm_models_cache = importlib.import_module("mlx_lm.models.cache")
    except ImportError as error:
        raise MlxEngineError(
            "mlx/mlx-lm are not importable; run this worker inside the "
            "isolated venv via script/constrained_mlx_service.sh"
        ) from error
    if mlx_lm.__version__ != EXPECTED_MLX_LM:
        raise MlxEngineError(
            f"expected mlx-lm {EXPECTED_MLX_LM}, "
            f"found {mlx_lm.__version__}"
        )
    if mx.__version__ != EXPECTED_MLX:
        raise MlxEngineError(
            f"expected mlx {EXPECTED_MLX}, found {mx.__version__}"
        )
    return (
        mx,
        mlx_lm,
        mlx_lm_models_cache.make_prompt_cache,
        mlx_lm_models_cache.trim_prompt_cache,
    )


class _MlxBackend(RollbackBackend):
    """Rollback backend over one mlx_lm prompt cache."""

    def __init__(
        self, mx: Any, model: Any, cache: Any, trim_cache: Any
    ) -> None:
        self._mx = mx
        self._model = model
        self._cache = cache
        self._trim_cache = trim_cache

    def feed(self, delta: list[int]) -> list[Any]:
        logits = self._model(
            self._mx.array([delta]), cache=self._cache
        )
        return [logits[0, index, :] for index in range(logits.shape[1])]

    def trim(self, count: int) -> int:
        return int(self._trim_cache(self._cache, count))

    def softmax(self, row: Any) -> Any:
        return _ProbabilityView(
            self._mx.softmax(row.astype(self._mx.float32))
        )


class _ProbabilityView:
    """Probability lookup backing the scorer protocol (the decoder only
    probes a handful of token ids per step, so the full vocab is never
    materialized as a dict)."""

    def __init__(self, probabilities: Any) -> None:
        self._probabilities = probabilities

    def get(self, token_id: int, default: float = 0.0) -> float:
        index = int(token_id)
        if 0 <= index < self._probabilities.shape[-1]:
            return float(self._probabilities[index])
        return default


class MlxConstrainedEngine:
    """Loads the pinned 8-bit model and decodes constrained sentences."""

    # L2 用户 LM 浅融合（默认关闭）：view + λ。类属性默认值保证未经
    # main() 接线的实例（测试手工装配路径）与旧行为完全一致。
    _user_lm: UserLanguageModelView | None = None
    _user_weight: float = 0.0
    # reveal A-F5：beam length penalty 在 main() 启动期解析一次存此
    # （非法值 fail-fast exit(2)，与 user-LM 同口径）；handle_request
    # 与 stats 复用，不再逐请求读环境。
    _length_penalty: float = 0.0

    def __init__(
        self,
        model_dir: Path,
        guard: PinyinGuard,
        *,
        verify_weights: bool = True,
    ) -> None:
        (
            mx,
            _mlx_lm,
            make_prompt_cache,
            trim_prompt_cache,
        ) = _import_mlx_modules()
        model_dir = model_dir.resolve()
        weights = model_dir / "model.safetensors"
        if not weights.is_file():
            raise MlxEngineError("MLX model files are missing")
        # 制品 manifest（LM-002 SFT fused 制品）可选地覆盖内置 pin：
        # 无 manifest 时维持内置 pin 校验（产品基座，行为不变）；有
        # manifest 时按 manifest 的 weights_sha256 校验并驱动
        # model_artifact_id —— 校验永远 fail-closed，只是预期值来源
        # 跟随制品。
        manifest = _load_artifact_manifest(model_dir)
        expected_weights_sha = (
            manifest["weights_sha256"] if manifest else MLX_WEIGHTS_SHA256
        )
        if verify_weights:
            actual = sha256_file(weights)
            if actual != expected_weights_sha:
                raise MlxEngineError(
                    "MLX weights do not match the pinned SHA-256"
                )
        global _ACTIVE_MANIFEST
        _ACTIVE_MANIFEST = manifest
        try:
            config = json.loads(
                (model_dir / "config.json").read_text(encoding="utf-8")
            )
        except (OSError, json.JSONDecodeError) as error:
            raise MlxEngineError(
                f"cannot read MLX model config: {error}"
            ) from error
        if not isinstance(config, dict):
            raise MlxEngineError("MLX model config must be an object")
        if config.get("quantization") != MLX_QUANTIZATION:
            raise MlxEngineError(
                f"unexpected quantization config: "
                f"{config.get('quantization')!r}"
            )
        load = importlib.import_module("mlx_lm").load
        model, tokenizer = load(str(model_dir))
        self._tokenizer = tokenizer
        backend = _MlxBackend(mx, model, make_prompt_cache(model), trim_prompt_cache)
        self.cache = PrefixRollbackCache(backend)
        started = monotonic()
        self.index = PinyinTokenIndex.build(tokenizer, guard)
        self.guard = guard
        print(
            f"constrained-mlx: pinyin token index built in "
            f"{monotonic() - started:.1f}s "
            f"({len(self.index.token_syllables)}/{tokenizer.vocab_size} "
            f"tokens indexed)",
            file=sys.stderr,
            flush=True,
        )

    def _encode(self, text: str) -> list[int]:
        return [int(token) for token in self._tokenizer.encode(text)]

    def handle_request(self, request: Any) -> dict[str, Any]:
        (
            request_id,
            context,
            pinyin,
            candidates,
            max_characters,
            want_stats,
        ) = validate_generate_request(request)
        syllables = self.guard.segment(candidates[0], pinyin)
        if syllables is None:
            # guard.segment keys on the top candidate's own readings and
            # fails when that candidate cannot tile the typed pinyin; the
            # old [pinyin] whole-string fallback names no syllable the
            # PinyinTokenIndex knows, so decode almost always abstained.
            # Use the shared generic dictionary segmentation when it fully
            # tiles the string; its DP failure keeps [pinyin] behavior.
            syllables = segment_generic_pinyin(pinyin, self.guard)
            if syllables is None:
                syllables = [pinyin]
        seed_ids = self._encode(SEED_CONTEXT)
        if context:
            seed_ids = seed_ids + self._encode(context)
        scorer = _SeedPathScorer(self.cache, seed_ids)
        user_lm = self._user_lm
        user_weight = self._user_weight
        user_scorer: Callable[[str, str], float | None] | None = None
        if user_lm is not None and user_weight > 0.0:
            # Shallow fusion context: seed context + request context as
            # the committed-history prefix, then the already generated
            # text as decoding proceeds (multi-char tokens scored per
            # character inside the view; 5-gram history means only the
            # last 4 characters of the prefix ever matter). Fusion only
            # re-ranks — the KV cache path (scorer) is untouched.
            fusion_prefix = SEED_CONTEXT + context

            def _fusion_scorer(
                prefix_text: str, token_text: str
            ) -> float | None:
                return user_lm.log_prob_sum(
                    fusion_prefix + prefix_text, token_text
                )

            user_scorer = _fusion_scorer
        result = ConstrainedGreedyDecoder.decode(
            scorer,
            syllables,
            self.index,
            max_characters=max_characters,
            fuzzy=True,
            beam_width=BEAM_WIDTH,
            length_penalty=self._length_penalty,
            user_scorer=user_scorer,
            user_weight=user_weight if user_scorer is not None else 0.0,
        )
        if result.text and not fuzzy_segment_ok(
            self.guard, result.text, syllables
        ):
            result = DecodeResult("", 0.0, result.consumed_syllables)
        stats: dict[str, Any] | None = None
        if want_stats:
            stats = dict(self.cache.stats)
            # Dual-caliber confidence telemetry: `confidence` in the
            # response envelope is the pinyin-mask-renormalized value;
            # the legacy RAW softmax geometric mean rides here for
            # evaluation-side calibration comparison, along with the
            # beam ranking knobs in effect for this request.
            stats["confidence_raw"] = result.raw_confidence
            stats["length_penalty"] = self._length_penalty
            stats["user_lm_weight"] = self._user_weight
        # Reveal C-F7: roll the shared cache back to the seed+context
        # endpoint after each request. The beam-tail rows (and their KV
        # entries, roughly 300KB per position of full-vocab logits) are
        # never reused by the next request, while the seed+context rows
        # ARE the cross-request prefix asset — keep exactly those.
        # Rolling back now also pre-does the next request's rollback.
        self.cache.distribution(seed_ids)
        return generate_response(
            request_id=request_id,
            suggestion=result.text,
            confidence=result.confidence,
            model_artifact_id=model_artifact_id(),
            stats=stats,
            # reveal C-F1：信封自声明口径（字段名/schema 未变，靠标记
            # 区分口径切换前后的产物）。
            confidence_caliber=CONFIDENCE_CALIBER_MASK_RENORM,
        )


class _SeedPathScorer:
    """Scorer over the shared rollback cache: score seed+path prefixes."""

    def __init__(self, cache: PrefixRollbackCache, seed_ids: list[int]) -> None:
        self._cache = cache
        self._seed_ids = seed_ids

    def __call__(self, step_token_ids: Sequence[int]) -> Any:
        return self._cache.distribution(
            self._seed_ids + [int(token) for token in step_token_ids]
        )


def handle_request_line(engine: Any, line: str) -> dict[str, Any] | None:
    """Handles one request line; returns the response dict, or None
    when the line is not valid JSON (protocol error → exit).

    Reveal A-F4: a per-request internal failure (cache contract
    violation, tokenizer edge input) fails CLOSED with an empty
    suggestion instead of crashing the worker — a crash would cost a
    cold restart (model load + dictionary index, seconds) and, under a
    stream of bad requests, a crash loop. Only protocol-level errors
    (invalid JSON) exit.
    """
    try:
        request = json.loads(line)
    except json.JSONDecodeError:
        return None
    request_id = (
        request.get("request_id")
        if isinstance(request, dict)
        else None
    )
    try:
        return engine.handle_request(request)
    except GenerateRequestError:
        # Protocol-level validation errors keep the frozen torch
        # worker's exit(2) contract (main handles them).
        raise
    except Exception:
        traceback.print_exc()
        return {
            "schema_version": 1,
            "request_id": request_id,
            "suggestion": "",
            "confidence": 0.0,
            "model_artifact_id": model_artifact_id(),
            # 兜底信封同样自声明口径（本 worker 恒为掩码内归一化）。
            "confidence_caliber": CONFIDENCE_CALIBER_MASK_RENORM,
        }


def main() -> int:
    try:
        model_dir = Path(os.environ["RIMEAI_MLX_MODEL_DIR"]).resolve()
        dictionary_path = Path(os.environ["RIMEAI_RIME_DICTIONARY"]).resolve()
    except KeyError as error:
        print(
            f"constrained-mlx: missing environment {error}",
            file=sys.stderr,
            flush=True,
        )
        return 2
    try:
        guard = PinyinGuard.from_rime_dictionary(dictionary_path)
    except (OSError, ValueError) as error:
        print(f"constrained-mlx: {error}", file=sys.stderr, flush=True)
        return 2
    try:
        engine = MlxConstrainedEngine(model_dir, guard)
    except MlxEngineError as error:
        print(f"constrained-mlx: {error}", file=sys.stderr, flush=True)
        return 2
    try:
        # 显式配置才启用 L2 浅融合；一切配置错误 fail-closed（退出 2），
        # 绝不静默降级；默认（两个环境变量都未设）行为与无融合时逐位一致。
        engine._user_lm, engine._user_weight = _user_lm_fusion_config()
    except MlxEngineError as error:
        print(f"constrained-mlx: {error}", file=sys.stderr, flush=True)
        return 2
    try:
        # reveal A-F5：length penalty 同样只在启动期解析一次；非法值
        # fail-fast（exit 2），不会进入“worker 存活但逐请求弃权”的
        # 静默坏状态。
        engine._length_penalty = _beam_length_penalty()
    except MlxEngineError as error:
        print(f"constrained-mlx: {error}", file=sys.stderr, flush=True)
        return 2
    if engine._user_lm is not None:
        print(
            "constrained-mlx: user-LM shallow fusion "
            + (
                f"enabled (weight={engine._user_weight}, "
                f"domains={engine._user_lm.domains()})"
                if engine._user_weight > 0.0
                else "validated but inactive (weight=0)"
            ),
            file=sys.stderr,
            flush=True,
        )
    for line in sys.stdin:
        try:
            response = handle_request_line(engine, line)
        except GenerateRequestError as error:
            print(
                f"constrained-mlx: {error}",
                file=sys.stderr,
                flush=True,
            )
            return 2
        if response is None:
            print(
                "constrained-mlx: request is not valid JSON",
                file=sys.stderr,
                flush=True,
            )
            return 2
        sys.stdout.write(
            json.dumps(
                response,
                ensure_ascii=False,
                separators=(",", ":"),
                sort_keys=True,
            )
            + "\n"
        )
        sys.stdout.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
