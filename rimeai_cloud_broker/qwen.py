"""OpenAI-compatible cloud client for candidate choice or generation."""

from __future__ import annotations

import json
import math
import re
import sys
from collections import OrderedDict
from collections.abc import Callable, Sequence
from pathlib import Path
from threading import Lock
from time import monotonic
from typing import Any
from urllib import error, request

from rimeai_daemon.segment_policy import split_segmented_text


LOCAL_ENDPOINT = "http://localhost:11434/v1"
# Official Zhipu Coding Plan, direct connection (product decision
# 2026-10-12): replaces the local Ollama endpoint. The Swift client
# compares this string byte for byte against
# RimeAICloudConfiguration.endpoint, so the two stay frozen together.
ENDPOINT = "https://open.bigmodel.cn/api/coding/paas/v4"
PROVIDER = "Zhipu Coding Plan (direct)"
ALLOWED_MODELS = {
    "glm-5.3-flash",
}
# Generation is the only inference contract: the model composes from
# pinyin and recent_context (product decision 2026-10-12): composition
# quality is the model's job (rules in the system message), and the user
# settles ambiguity in the candidate panel. The alignment-tier design
# was removed on 2026-10-13 — the single policy is the former loose
# behavior, unconditionally: the model may fix arbitrary typos and
# compose mixed Chinese/English, and local gates are structural only.
GENERATE_MAXIMUM_CHARACTERS = 128
# Echo guard for accepted generations, mirroring the continuation policy:
# with no algorithmic alignment check, overlap with the recent-context
# tail is the anti-echo floor against verbatim context replays.
LOOSE_DEDUP_TAIL = 32
LOOSE_MAX_TAIL_OVERLAP = 3
# The chat payload is one exchange (product decision 2026-10-12): the
# system message carries the invariant contract, a single user message
# carries the per-request input — what the user is typing plus the text
# nearest the cursor. History snippets and profile hints stay out of the
# prompt; their only job was context steering, which recent_context
# covers.
# Only the text nearest the cursor informs the sentence being typed.
# Long context dumps (protocol allows 600 chars of whatever sits in the
# field) inflate prefill and hand the model more material to echo
# verbatim; a zero-Han context cannot inform a Chinese reading at all.
PROMPT_CONTEXT_TAIL = 120
# Explicit opt-in diagnostics: while this marker file exists, full request
# and response bodies are written to the broker's stderr log. Prompts
# contain the user's typed pinyin and context, so this stays off by
# default; credentials (the Authorization header) are never logged.
DEBUG_FLAG = Path.home() / ".config" / "rimeai" / "cloud-debug"

# Post-commit continuation mirrors Swift ContinuationTextPolicy
# (Sources/RimeAIInputCore/CloudBrokerProtocol.swift): keep every value
# byte-identical across the two sides.
CONTINUATION_MINIMUM_CONFIDENCE = 0.65
CONTINUATION_MIN_HAN = 2
CONTINUATION_MAX_HAN = 16
CONTINUATION_DEDUP_TAIL = 32
CONTINUATION_MAX_TAIL_OVERLAP = 3
# Frozen separately from ALLOWED_MODELS: continuation is a pure-context
# task and its output contract was smoked on the previous local model
# (Task 2.5, 10 fixed contexts). The allowlist follows the inference
# model to the direct endpoint; the smoke gate must be re-run before
# trusting the echo numbers again.
CONTINUATION_ALLOWED_MODELS = {
    "glm-5.3-flash",
}
_CONTINUATION_HAN_ONLY = re.compile(r"^[\u3400-\u9fff]+$")


def _han_count(text: str) -> int:
    return sum(1 for char in text if "\u3400" <= char <= "\u9fff")


def _abstain() -> dict[str, Any]:
    return {
        "decision": "abstain",
        "candidate_id": None,
        "confidence": None,
        "reason": "uncertain",
    }


def _prompt_context(context: str) -> str:
    """Bounds the recent_context shown to the model: tail window nearest
    the cursor, dropped entirely when it carries no Han."""
    tail = context[-PROMPT_CONTEXT_TAIL:]
    return tail if _han_count(tail) > 0 else ""


def _tail_overlap(context: str, text: str) -> int:
    """Longest suffix of context that is also a prefix of text."""
    overlap = 0
    for size in range(1, min(len(context), len(text)) + 1):
        if context.endswith(text[:size]):
            overlap = size
    return overlap


def continuation_text_allows(text: str, context: str, confidence: float) -> bool:
    """Mirror of Swift ContinuationTextPolicy.allows, rule for rule."""
    if (
        not isinstance(confidence, (int, float))
        or isinstance(confidence, bool)
        or not math.isfinite(confidence)
        or confidence < CONTINUATION_MINIMUM_CONFIDENCE
    ):
        return False
    if _CONTINUATION_HAN_ONLY.fullmatch(text) is None:
        return False
    if not CONTINUATION_MIN_HAN <= len(text) <= CONTINUATION_MAX_HAN:
        return False
    if context and text in context[-CONTINUATION_DEDUP_TAIL:]:
        return False
    if _tail_overlap(context, text) > CONTINUATION_MAX_TAIL_OVERLAP:
        return False
    return True


def _debug_enabled() -> bool:
    try:
        return DEBUG_FLAG.exists()
    except OSError:
        return False


class QwenBrokerError(RuntimeError):
    pass


def _first_json_object(content: str) -> Any:
    """Decodes the first JSON object in the content, ignoring trailing
    noise. Small local models sometimes append repeated fragments after
    an otherwise valid contract object; strict json.loads would discard
    the whole decision."""
    start = content.find("{")
    if start < 0:
        raise QwenBrokerError(
            "Qwen returned invalid structured output (no JSON object)"
        )
    try:
        value, _ = json.JSONDecoder().raw_decode(content[start:])
    except json.JSONDecodeError as exc:
        raise QwenBrokerError("Qwen returned invalid structured output") from exc
    return value


def _first_choice(response: dict[str, Any]) -> dict[str, Any]:
    """OpenAI-compatible responses carry the message in choices[0]."""
    choices = response.get("choices")
    if (
        not isinstance(choices, list)
        or not choices
        or not isinstance(choices[0], dict)
    ):
        raise QwenBrokerError("Qwen returned invalid structured output")
    return choices[0]


class _RejectRedirects(request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise QwenBrokerError("Qwen endpoint redirect was refused")


class QwenCandidateRanker:
    def __init__(
        self,
        *,
        api_key_loader: Callable[[], str] | None = None,
        endpoint: str = ENDPOINT,
    ) -> None:
        if endpoint.rstrip("/") != ENDPOINT:
            raise ValueError("the Qwen endpoint is fixed by the product contract")
        self._api_key_loader = api_key_loader
        self._api_key: str | None = None
        self._api_key_lock = Lock()
        self._endpoint = ENDPOINT
        # Pool-independent outputs are cached per (model, pinyin, context)
        # and re-decided locally on every hit, so the synthesis gates stay
        # exact while repeat typing skips the network round trip entirely.
        # Context is part of the key because the prompt (and therefore the
        # composition) changes with it.
        self._decision_cache: OrderedDict[tuple, dict[str, Any]] = (
            OrderedDict()
        )

    def rank(self, cloud_request: dict[str, Any]) -> dict[str, Any]:
        started = monotonic()
        model_id = cloud_request["model_id"]
        if model_id not in ALLOWED_MODELS:
            raise QwenBrokerError("model is not in the frozen allowlist")
        # Generation is the only inference contract: the model composes
        # from pinyin and context, and local synthesis applies structural
        # gates only (product decision 2026-10-12; single-policy follow-up
        # 2026-10-13 — quality is the model's job, the user settles
        # ambiguity in the candidate panel).
        segments = cloud_request.get("segments")
        prompt_context = _prompt_context(cloud_request["recent_context"])
        if segments is None:
            cache_key = (
                model_id,
                cloud_request["pinyin"],
                prompt_context,
            )
        else:
            cache_key = None
        if cache_key is not None and cache_key in self._decision_cache:
            # Cache hit: re-run the local decision synthesis on the cached
            # raw model output; the deadline clock never starts.
            return self._synthesize_generation(
                self._decision_cache[cache_key],
                segments=None,
                recent_context=cloud_request["recent_context"],
            )
        if segments is not None:
            # Cross-punctuation composition: one round trip, the model sees
            # every segment (plus its committed_text hint) at once. Rules
            # and the output contract live in the system message — invariant
            # across requests, so prefill caching can reuse the whole
            # prefix — and the user message carries only per-request data.
            system_content = (
                "你是中文输入法的拼音组句引擎。用户正在输入一个被标点分隔"
                "的多段句子。segments 列表按输入顺序给出每一段："
                "pinyin 是该段拼音，separator 是该段之后的标点（最后一段"
                "为空字符串），committed_text 是用户已确认的该段文字"
                "（若有，原样保留）。规则：\n"
                "1. 生成覆盖全部段的完整句子：段间原样保留给定的 "
                "separator；用户可能打错前后鼻音（an/ang、en/eng、"
                "in/ing）、平翘舌（z/zh、c/ch、s/sh）甚至个别字母，"
                "按最合理的意图纠正。\n"
                "2. 段内可中英混排：用户键入的英文单词和数字原样保留，"
                "只修正拼音对应的中文部分；整句不超过 128 个字符。\n"
                "3. recent_context 是光标前已上屏的文本：用它判断"
                "语境，但严禁把其中的词句抄进生成结果。\n"
                "4. 只要存在合理解读就输出完整句子；确实无法解读时"
                "输出空。\n"
                "直接输出完整句子本身的纯文本：不要解释、引号"
                "或 JSON；确实无法解读时输出空。"
            )
        else:
            system_content = (
                "你是中文输入法的拼音组句引擎。根据用户键入的拼音推导其"
                "想输入的句子。规则：\n"
                "1. 用户可能打错前后鼻音（an/ang、en/eng、in/ing）或"
                "平翘舌（z/zh、c/ch、s/sh）甚至个别字母，按最合理的"
                "意图纠正。\n"
                "2. 输出可中英混排：用户键入的英文单词和数字原样保留，"
                "只修正拼音对应的中文部分；不超过 128 个字符。\n"
                "3. recent_context 是光标前已上屏的文本：用它判断"
                "语境，但严禁把其中的词句抄进生成结果。\n"
                "4. 只要存在合理解读就输出句子；确实无法解读时输出"
                "空。\n"
                '直接输出句子本身的纯文本：不要解释、引号或 JSON；'
                "确实无法解读时输出空。"
            )
        max_tokens = 256
        # One exchange (product decision 2026-10-12): the system message
        # carries the invariant contract so prefill caching can reuse the
        # whole prefix, and a single user message carries the per-request
        # input — the pinyin being typed (plus segments when the
        # composition spans punctuation) and the text nearest the cursor.
        prompt = {
            "pinyin": cloud_request["pinyin"],
            "recent_context": prompt_context,
        }
        if segments is not None:
            prompt["segments"] = segments
        messages: list[dict[str, str]] = [
            {
                "role": "system",
                "content": system_content,
            },
            {
                "role": "user",
                "content": json.dumps(
                    prompt,
                    ensure_ascii=False,
                    separators=(",", ":"),
                ),
            },
        ]
        payload = {
            "model": model_id,
            "messages": messages,
            # OpenAI-compatible /chat/completions shape. GLM 5.3 thinks
            # by default and burns the whole max_tokens budget on
            # reasoning with empty content; reasoning_effort is not
            # honored by the direct endpoint — thinking.type=disabled is
            # the only working switch (measured 2026-10-12).
            "temperature": 0,
            "max_tokens": max_tokens,
            "thinking": {"type": "disabled"},
        }
        api_key = self._resolve_api_key(cloud_request)
        remaining = (
            cloud_request["deadline_ms"] / 1000
            - (monotonic() - started)
            - 0.025
        )
        if remaining < 0.05:
            raise QwenBrokerError("cloud deadline expired before network send")
        response = self._post_json(
            "/chat/completions",
            payload,
            timeout=remaining,
            api_key=api_key,
        )
        choice = _first_choice(response)
        try:
            content = choice["message"]["content"]
        except (KeyError, TypeError) as exc:
            raise QwenBrokerError("Qwen returned invalid structured output") from exc
        if not isinstance(content, str):
            raise QwenBrokerError("Qwen returned invalid structured output")
        if choice.get("finish_reason") == "length":
            # Runaway output truncated at max_tokens: not a service error,
            # just no usable composition. Abstain locally instead of burning
            # the client's cloud-error budget on keyboard mashing.
            return _abstain()
        # Plain-text output contract (2026-10-12): the content IS the
        # sentence; an empty or whitespace-only output is the model
        # declining to compose, and _synthesize_generation turns that
        # into an abstain.
        text = content.strip()
        if text.startswith("{") and text.endswith("}"):
            # Lenient unwrap: a model that ignores the plain-text contract
            # and answers {"text": ...} must not surface the JSON literal
            # as the sentence. Brace-delimited content that fails to parse
            # (or parses into anything but the text contract) is the model
            # mangling the output — abstain rather than echo JSON.
            try:
                unwrapped = _first_json_object(text)
            except QwenBrokerError:
                return _abstain()
            if not (
                isinstance(unwrapped, dict)
                and isinstance(
                    unwrapped.get("text"), (str, type(None))
                )
            ):
                return _abstain()
            text = unwrapped.get("text") or ""
        decision = {"text": text}
        validated = self._synthesize_generation(
            decision,
            segments=segments,
            recent_context=cloud_request["recent_context"],
        )
        if cache_key is not None and isinstance(decision, dict):
            # Generation outputs are plain sentences and always
            # cacheable: the synthesis gates are pool-independent, so a
            # cached raw output re-validates cleanly against any pool.
            self._decision_cache[cache_key] = decision
            while len(self._decision_cache) > 256:
                self._decision_cache.popitem(last=False)
        return validated

    def rank_continuation(self, cloud_request: dict[str, Any]) -> dict[str, Any]:
        started = monotonic()
        model_id = cloud_request["model_id"]
        if model_id not in CONTINUATION_ALLOWED_MODELS:
            raise QwenBrokerError(
                "model is not in the continuation allowlist"
            )
        context = cloud_request["recent_context"]
        # Unlike the inference path (where context steers a pinyin-bound
        # composition), context IS the task here: post-commit continuation
        # asks what follows the committed text, so the prompt must carry
        # it. Same one-exchange shape as the inference path (product
        # decision 2026-10-12): the system message defines the JSON
        # output contract, the user message is the context alone —
        # history snippets stay out of the prompt.
        user_content = context
        payload = {
            "model": model_id,
            "messages": [
                {
                    "role": "system",
                    "content": (
                        "你是中文续写助手。用户给出刚上屏的中文文本，你输出"
                        "紧接其后的下一短语。要求：\n"
                        "1. 生成的短语必须是同一段文本/同一首诗中逐字紧接的"
                        "下一句，绝不能输出其他作品里的相似句子。\n"
                        "2. 记不准或没有把握时，宁可不猜：输出 "
                        '{"generated_text":null,"confidence":null}。\n'
                        "3. 短语为 2-16 个汉字，不含标点、数字、字母。\n"
                        "只输出一个 JSON 对象。"
                    ),
                },
                {"role": "user", "content": user_content},
            ],
            # See rank(): OpenAI-compatible /chat/completions shape with
            # thinking disabled — same budget rule as the inference path.
            "temperature": 0,
            "max_tokens": 64,
            "thinking": {"type": "disabled"},
        }
        api_key = self._resolve_api_key(cloud_request)
        remaining = (
            cloud_request["deadline_ms"] / 1000
            - (monotonic() - started)
            - 0.025
        )
        if remaining < 0.05:
            raise QwenBrokerError("cloud deadline expired before network send")
        response = self._post_json(
            "/chat/completions",
            payload,
            timeout=remaining,
            api_key=api_key,
        )
        choice = _first_choice(response)
        try:
            content = choice["message"]["content"]
        except (KeyError, TypeError) as exc:
            raise QwenBrokerError("Qwen returned invalid structured output") from exc
        try:
            decision = _first_json_object(content)
        except QwenBrokerError:
            if choice.get("finish_reason") == "length":
                # Same runaway-output rule as rank(): a truncated echo is
                # "no suggestion", not a service error.
                return self._validate_continuation_decision({}, context=context)
            raise
        return self._validate_continuation_decision(decision, context=context)

    def embed_texts(self, texts: Sequence[str]) -> list[list[float]]:
        bounded = list(texts[:32])
        if not bounded or any(
            not isinstance(value, str) or len(value.encode()) > 16_384
            for value in bounded
        ):
            raise QwenBrokerError("embedding input is invalid")
        response = self._post_json(
            "/embeddings",
            {
                "model": "text-embedding-v4",
                "input": bounded,
                "dimensions": 512,
                "encoding_format": "float",
            },
            timeout=5,
            api_key=self._current_api_key(),
        )
        try:
            ordered = sorted(response["data"], key=lambda item: item["index"])
            vectors = [item["embedding"] for item in ordered]
        except (KeyError, TypeError) as exc:
            raise QwenBrokerError("embedding response is invalid") from exc
        if len(vectors) != len(bounded) or any(
            not isinstance(vector, list)
            or len(vector) != 512
            or any(
                not isinstance(value, (int, float))
                or isinstance(value, bool)
                or not math.isfinite(value)
                for value in vector
            )
            for vector in vectors
        ):
            raise QwenBrokerError("embedding dimensions are invalid")
        return [[float(value) for value in vector] for vector in vectors]

    def _synthesize_generation(
        self,
        decision: Any,
        *,
        segments: Sequence[dict[str, Any]] | None = None,
        recent_context: str = "",
    ) -> dict[str, Any]:
        """Local decision synthesis for the generation contract.

        The model returns the sentence as plain text (empty means "no
        defensible reading"). Composition quality is the model's
        job — the system prompt carries the composition rules, and the
        user settles ambiguity in the candidate panel (product decision
        2026-10-12; single-policy follow-up 2026-10-13). Local gates are
        structural only: text without control characters within the
        128-character contract (the Swift client is the final gate for
        the >0x20 scalar rule and non-empty segmented parts), the
        request separators reproduced in order, and the echo guard
        against verbatim context replays.
        """
        if not isinstance(decision, dict):
            raise QwenBrokerError("Qwen decision is not an object")
        text = decision.get("text")
        # Empty text is the model declining to compose; the decision
        # dict here is an internal shape (the wire response never
        # carries it), and stray fields are ignored.
        if text is None:
            return _abstain()
        if not isinstance(text, str):
            raise QwenBrokerError("Qwen generated sentence is invalid")
        text = text.strip()
        if not text:
            return _abstain()
        if len(text) > GENERATE_MAXIMUM_CHARACTERS or any(
            ord(char) < 0x20 or ord(char) == 0x7F for char in text
        ):
            return _abstain()
        if segments is not None and (
            split_segmented_text(text, segments) is None
        ):
            return _abstain()
        if recent_context and (
            text in recent_context[-LOOSE_DEDUP_TAIL:]
            or _tail_overlap(recent_context, text) > LOOSE_MAX_TAIL_OVERLAP
        ):
            return _abstain()
        # Acceptance is binary (every gate above is deterministic), so the
        # wire confidence is a constant; the reason is a fixed
        # model-sourced label, not a local quality judgment.
        return {
            "decision": "generate",
            "candidate_id": None,
            "confidence": 1.0,
            "reason": "typo_match",
            "text": text,
        }

    def _validate_continuation_decision(
        self,
        decision: Any,
        *,
        context: str,
    ) -> dict[str, Any]:
        if not isinstance(decision, dict):
            raise QwenBrokerError("Qwen decision is not an object")
        action = decision.get("decision")
        text = decision.get("generated_text")
        if action is None:
            # The smoked few-shot contract carries no decision field:
            # generated_text alone decides generate vs abstain.
            action = "generate" if isinstance(text, str) and text else "abstain"
        if action not in {"generate", "abstain"}:
            raise QwenBrokerError("Qwen continuation decision is unsupported")
        raw_reason = decision.get("reason")
        if isinstance(raw_reason, str) and raw_reason in {
            "context_match",
            "history_match",
            "uncertain",
        }:
            reason: str = raw_reason
        else:
            reason = "context_match" if action == "generate" else "uncertain"
        if action == "abstain":
            return {
                "decision": "abstain",
                "generated_text": None,
                "confidence": None,
                "reason": reason,
            }
        confidence = decision.get("confidence")
        if (
            not isinstance(text, str)
            or not isinstance(confidence, (int, float))
            or isinstance(confidence, bool)
            or not math.isfinite(confidence)
            or not 0 <= confidence <= 1
        ):
            raise QwenBrokerError("Qwen continuation is invalid")
        # Validation failures degrade to abstain with a diagnostic reason
        # instead of raising: the client treats abstain as "no suggestion"
        # and a crash would only burn the cooldown counter.
        if confidence < CONTINUATION_MINIMUM_CONFIDENCE:
            return {
                "decision": "abstain",
                "generated_text": None,
                "confidence": None,
                "reason": "low_confidence",
            }
        if _CONTINUATION_HAN_ONLY.fullmatch(text) is None or not (
            CONTINUATION_MIN_HAN <= len(text) <= CONTINUATION_MAX_HAN
        ):
            return {
                "decision": "abstain",
                "generated_text": None,
                "confidence": None,
                "reason": "invalid_text",
            }
        if (context and text in context[-CONTINUATION_DEDUP_TAIL:]) or (
            _tail_overlap(context, text) > CONTINUATION_MAX_TAIL_OVERLAP
        ):
            return {
                "decision": "abstain",
                "generated_text": None,
                "confidence": None,
                "reason": "echoes_context",
            }
        return {
            "decision": "generate",
            "generated_text": text,
            "confidence": float(confidence),
            "reason": reason,
        }

    def post_json(
        self,
        path: str,
        payload: dict[str, Any],
        *,
        timeout: float,
        api_key: str | None = None,
    ) -> dict[str, Any]:
        """Public transport surface for co-located callers (the
        consolidation scheduler's profile summarizer)."""
        return self._post_json(
            path, payload, timeout=timeout, api_key=api_key
        )

    def _post_json(
        self,
        path: str,
        payload: dict[str, Any],
        *,
        timeout: float,
        api_key: str | None = None,
    ) -> dict[str, Any]:
        encoded = json.dumps(
            payload,
            ensure_ascii=False,
            separators=(",", ":"),
        ).encode("utf-8")
        url = self._endpoint + path
        if not url.startswith("https://") and self._endpoint != LOCAL_ENDPOINT:
            raise QwenBrokerError("cloud requests must stay on https")
        if _debug_enabled():
            sys.stderr.write(
                f"[cloud-debug] -> {path} "
                f"{encoded.decode('utf-8', 'replace')}\n"
            )
        cloud_request = request.Request(
            url,
            data=encoded,
            headers={
                # The direct endpoint authenticates with this header; the
                # local Ollama endpoint ignores it — the credential
                # contract is unchanged for the client.
                "Authorization": f"Bearer {api_key or self._current_api_key()}",
                "Content-Type": "application/json",
                "User-Agent": "RimeAI-CloudBroker/1.0",
            },
            method="POST",
        )
        try:
            opener = request.build_opener(_RejectRedirects())
            with opener.open(cloud_request, timeout=timeout) as response:
                body = response.read(1_048_577)
        except (error.URLError, TimeoutError, OSError) as exc:
            raise QwenBrokerError("Qwen request failed") from exc
        if len(body) > 1_048_576:
            raise QwenBrokerError("Qwen response is too large")
        try:
            value = json.loads(body)
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise QwenBrokerError("Qwen response is not JSON") from exc
        if not isinstance(value, dict):
            raise QwenBrokerError("Qwen response is not an object")
        if _debug_enabled():
            sys.stderr.write(
                f"[cloud-debug] <- {path} "
                f"{body.decode('utf-8', 'replace')}\n"
            )
        return value

    def _resolve_api_key(self, cloud_request: dict[str, Any]) -> str:
        supplied = cloud_request.pop("api_key", None)
        if supplied is not None:
            if (
                not isinstance(supplied, str)
                or not supplied
                or len(supplied.encode()) > 512
            ):
                raise QwenBrokerError("cloud credential is unavailable")
            with self._api_key_lock:
                self._api_key = supplied
            return supplied
        return self._current_api_key()

    def _current_api_key(self) -> str:
        with self._api_key_lock:
            value = self._api_key
        if value is None and self._api_key_loader is not None:
            value = self._api_key_loader()
            if isinstance(value, str) and value and len(value.encode()) <= 512:
                with self._api_key_lock:
                    self._api_key = value
        if not isinstance(value, str) or not value or len(value.encode()) > 512:
            raise QwenBrokerError("cloud credential is unavailable")
        return value
