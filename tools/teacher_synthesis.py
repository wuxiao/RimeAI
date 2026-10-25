"""Teacher synthesis for LM-002 data amplification (decided 2026-10-24).

Teacher = glm-5.3-flash, sequence-level only (Zhipu platform ignores
logprobs family-wide, so token-level soft labels are closed; see
docs/LM002_SFT_BASELINE_REPORT.md §7). The teacher composes sentences
from sampled pinyin seeds; only sentences reproducible under the local
dictionary enter the training set (D4 engineering: cloud text is never
taken as gold by itself — it must be alignable to the typed pinyin via
the frozen Rime dictionary, exactly like the product's constrained
decoder would have to).

Pipeline:
  1. sample word-level pinyin seeds from the frozen Rime dictionary
     (deterministic under --seed), excluding the frozen evaluation
     set's pinyin keys at the source;
  2. for each seed, ask the teacher (CloudModelClient.rank — the same
     prompt engineering and structural gates as the product path);
  3. alignment filter: the teacher sentence must align to the seed —
     exact match via PinyinGuard.segment (teacher did not correct the
     pinyin) or fuzzy match via fuzzy_segment_ok (teacher corrected a
     frozen confusion pair: an/ang, en/eng, in/ing, zh/z, ch/c, sh/s).
     Anything else is dropped and counted — it is not reproducible
     under the local dictionary mask and would poison the student
     (D4);
  4. write a jsonl consumed by tools/build_sft_dataset.py
     (--teacher-synthesis), rows shaped like decision-log pairs:
     {pinyin, chosen, rejected: null, weight, source:
     "teacher_synthesis", created_at_ms}. Files are 0600 (privacy
     posture of the language-profile export).

Explicit user invocation only. PRIVACY POSTURE (reveal 2026-10-24,
replaces the earlier "nothing is uploaded" claim): the teacher call
sends the seed PINYIN to the cloud endpoint exactly like the product's
cloud-correction path does (same endpoint, same data class, same
CloudModelClient contract). Pinyin is within the product's cloud
contract; no keystrokes, context, or candidate lists ever leave the
machine. When --seeds-file carries user-distribution seeds, those
pinyin strings are derived from local history and leave the machine
under the same cloud contract — pass dictionary-sampled seeds if that
is not acceptable. Nothing else is uploaded; outputs stay local
(0600).
"""

from __future__ import annotations

import argparse
import json
import os
import random
import sys
import time
from collections.abc import Callable, Sequence
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from rimeai_cloud_broker.cloud_model import (  # noqa: E402
    ALLOWED_MODELS,
    CloudBrokerError,
    CloudModelClient,
)
from rimeai_runtime.constrained_decoder import fuzzy_segment_ok  # noqa: E402
from rimeai_runtime.pinyin_guard import PinyinGuard  # noqa: E402

VERSION = 1
DEFAULT_MODEL_ID = next(iter(ALLOWED_MODELS))
# 教师合成权重：低于真实 adopted（1.0）与真实 rejected-chosen（0.7）——
# 教师句子未经用户确认且为合成分布，只作为覆盖放大，不作为偏好金标。
WEIGHT_TEACHER_SYNTHESIS = 0.5
DEFAULT_COUNT = 2_000
# 词级种子的句长分布：2-5 个词条、每词 2-4 音节（贴近真实打字句长）。
MIN_WORDS = 2
MAX_WORDS = 5
MAX_SYLLABLES_PER_WORD = 4
MAX_TOTAL_CHARACTERS = 30  # 与 PinyinGuard.segment 的合同一致
PINYIN_MAX_BYTES = 256  # 与 decision_log 的隐私合同一致
REQUEST_DEADLINE_MS = 20_000

DEFAULT_API_KEY_FILE = Path.home() / ".config/rimeai/cloud.env"
DEFAULT_EVAL_DATASET = (
    Path(__file__).resolve().parent.parent
    / ".rimeai/datasets/p0-librime-1.17.0-luna-simp.jsonl"
)


def load_api_key(path: Path) -> str:
    """Read RIMEAI_CLOUD_API_KEY from the privacy-center env file."""
    if not path.is_file():
        raise SystemExit(f"api key file not found: {path}")
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith("RIMEAI_CLOUD_API_KEY="):
            value = line.split("=", 1)[1].strip()
            if value:
                return value
    raise SystemExit(f"RIMEAI_CLOUD_API_KEY missing in {path}")


def dictionary_word_entries(
    guard: PinyinGuard, dictionary_path: Path
) -> list[tuple[str, str, tuple[str, ...]]]:
    """(word, joined pinyin, syllables) seed entries parsed from the
    raw dictionary lines: Rime dictionaries separate a multi-character
    word's syllables with spaces, so the syllable boundary comes from
    the dictionary itself — no heuristic splitting. Pure-Han words of
    2..MAX_SYLLABLES_PER_WORD syllables (single-syllable words make
    trivially short seeds; long words are rare in typing)."""
    entries: list[tuple[str, str, tuple[str, ...]]] = []
    seen: set[tuple[str, str]] = set()
    body_started = False
    with dictionary_path.open(encoding="utf-8") as handle:
        for line in handle:
            line = line.rstrip("\n")
            if not body_started:
                if line == "...":
                    body_started = True
                continue
            if not line or line.startswith("#"):
                continue
            fields = line.split("\t")
            if len(fields) < 2:
                continue
            text, raw_pinyin = fields[0], fields[1]
            syllables = tuple(
                s
                for s in (
                    part.strip().lower().replace("ü", "v").replace("u:", "v")
                    for part in raw_pinyin.split()
                )
                if s
            )
            if (
                len(text) >= 2
                and len(text) == len(syllables)
                and 2 <= len(syllables) <= MAX_SYLLABLES_PER_WORD
                and all(p.isalpha() for p in syllables)
            ):
                key = (text, "".join(syllables))
                if key not in seen:
                    seen.add(key)
                    entries.append((text, "".join(syllables), syllables))
    if not entries:
        raise ValueError(
            f"{dictionary_path}: no word entries usable as seeds"
        )
    return entries


def sample_pinyin_seeds(
    entries: Sequence[tuple[str, str, tuple[str, ...]]],
    *,
    count: int,
    seed: int,
    exclude_keys: set[str],
) -> list[tuple[str, tuple[str, ...]]]:
    """Deterministic word-level pinyin seeds as (joined pinyin,
    syllables); evaluation-set keys are excluded at the source (cheaper
    and cleaner than post-drop)."""
    rng = random.Random(seed)
    seeds: list[tuple[str, tuple[str, ...]]] = []
    joined_seen: set[str] = set()
    attempts = 0
    max_attempts = count * 20
    while len(seeds) < count and attempts < max_attempts:
        attempts += 1
        words = rng.sample(
            entries, k=rng.randint(MIN_WORDS, MAX_WORDS)
        )
        joined = "".join(item[1] for item in words)
        syllables: tuple[str, ...] = tuple(
            syl for item in words for syl in item[2]
        )
        if (
            len(joined.encode("utf-8")) > PINYIN_MAX_BYTES
            or len(joined) > MAX_TOTAL_CHARACTERS
            or joined in exclude_keys
            or joined in joined_seen
        ):
            continue
        joined_seen.add(joined)
        seeds.append((joined, syllables))
    return seeds


def teacher_sentence(
    client: CloudModelClient,
    *,
    model_id: str,
    pinyin: str,
    deadline_ms: int = REQUEST_DEADLINE_MS,
) -> str | None:
    """One teacher call through the product prompt/gate path; returns
    the sentence or None (abstain or error — counted by the caller)."""
    try:
        decision = client.rank(
            {
                "model_id": model_id,
                "pinyin": pinyin,
                "recent_context": "",
                "deadline_ms": deadline_ms,
            }
        )
    except CloudBrokerError:
        return None
    if decision.get("decision") != "generate":
        return None
    text = decision.get("text")
    return text if isinstance(text, str) and text else None


def alignment_filter(
    guard: PinyinGuard,
    text: str,
    pinyin: str,
    syllables: Sequence[str] | None = None,
) -> bool:
    """D4 engineering: a teacher sentence enters the training set only
    when the frozen dictionary can reproduce it for the typed pinyin —
    exactly (no correction) or via the frozen confusion pairs (teacher
    corrected an/ang, en/eng, in/ing, zh/z, ch/c, sh/s). Syllables come
    from the dictionary-side seed when available."""
    if guard.segment(text, pinyin) is not None:
        return True
    if syllables is None:
        return False
    if len(text) != len(syllables):
        return False
    # 锚定（reveal R1 P1-2 / R3 P2）：音节必须顺序拼出 typed pinyin；
    # 未锚定的音节列表可让词典根本无法复现的拼音通过 fuzzy 分支。
    if "".join(syllables) != pinyin:
        return False
    return fuzzy_segment_ok(guard, text, list(syllables))


def synth(
    guard: PinyinGuard,
    ask_teacher: Callable[[str], str | None],
    *,
    seeds: Sequence[tuple[str, tuple[str, ...]]],
    concurrency: int = 1,
) -> tuple[list[dict[str, Any]], dict[str, int]]:
    """Teacher calls optionally run in a thread pool (each worker gets
    its own ask_teacher handle — the CLI builds one CloudModelClient
    per thread to avoid sharing the decision cache); alignment and
    row assembly stay single-threaded and deterministic."""
    rows: list[dict[str, Any]] = []
    stats = {
        "requested": len(seeds),
        "teacher_abstain_or_error": 0,
        "alignment_dropped": 0,
        "kept": 0,
    }
    now_ms = int(time.time() * 1000)

    def one(seed: tuple[str, tuple[str, ...]]) -> tuple[int, str | None]:
        pinyin, syllables = seed
        sentence = ask_teacher(pinyin)
        return (
            0 if sentence is not None else 1,
            None
            if sentence is None
            else (
                sentence
                if alignment_filter(guard, sentence, pinyin, syllables)
                else ""
            ),
        )

    if concurrency <= 1:
        outcomes = map(one, seeds)
    else:
        from concurrent.futures import ThreadPoolExecutor

        with ThreadPoolExecutor(max_workers=concurrency) as pool:
            outcomes = list(pool.map(one, seeds))

    for index, (status, sentence) in enumerate(outcomes):
        if status == 1:
            stats["teacher_abstain_or_error"] += 1
            continue
        if not sentence:
            stats["alignment_dropped"] += 1
            continue
        rows.append(
            {
                "pinyin": seeds[index][0],
                "chosen": sentence,
                "rejected": None,
                "weight": WEIGHT_TEACHER_SYNTHESIS,
                "source": "teacher_synthesis",
                "created_at_ms": now_ms + index,
            }
        )
        stats["kept"] += 1
    return rows, stats


def _write_private(path: Path, lines: Sequence[str]) -> None:
    path.write_text("".join(line + "\n" for line in lines), encoding="utf-8")
    os.chmod(path, 0o600)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="teacher-synthesis",
        description=(
            "glm-5.3-flash sequence-level teacher synthesis with the "
            "dictionary alignment filter (LM-002 data amplification)."
        ),
    )
    parser.add_argument(
        "--dictionary", type=Path, required=True,
        help="frozen Rime dictionary yaml (luna_pinyin.dict.yaml)",
    )
    parser.add_argument(
        "--count", type=int, default=DEFAULT_COUNT,
        help=f"pinyin seeds to synthesize (default {DEFAULT_COUNT})",
    )
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument(
        "--concurrency", type=int, default=4,
        help="parallel teacher requests (each thread its own client; "
        "default 4)",
    )
    parser.add_argument(
        "--eval-dataset", type=Path, default=DEFAULT_EVAL_DATASET,
        help="frozen evaluation jsonl whose pinyin keys are excluded",
    )
    parser.add_argument(
        "--api-key-file", type=Path, default=DEFAULT_API_KEY_FILE,
    )
    parser.add_argument(
        "--seeds-file", type=Path, default=None,
        help="pre-extracted pinyin seeds jsonl ({pinyin, syllables}) "
        "-- bypasses dictionary sampling entirely (e.g. user-"
        "distribution seeds from history)",
    )
    parser.add_argument(
        "--output", type=Path, required=True,
        help="output jsonl for build_sft_dataset --teacher-synthesis",
    )
    args = parser.parse_args(argv)

    guard = PinyinGuard.from_rime_dictionary(args.dictionary)
    exclude_keys = _eval_pinyin_keys(args.eval_dataset)
    if args.seeds_file is not None:
        seeds = _load_seeds_file(args.seeds_file, exclude_keys)
    else:
        entries = dictionary_word_entries(guard, args.dictionary)
        seeds = sample_pinyin_seeds(
            entries, count=args.count, seed=args.seed,
            exclude_keys=exclude_keys,
        )
    if not args.seeds_file and len(seeds) < args.count:
        print(
            f"warning: only {len(seeds)}/{args.count} unique seeds sampled",
            file=sys.stderr,
        )

    # 每线程独立 CloudModelClient（决策缓存/journal 不跨线程共享；造数
    # 场景拼音唯一、缓存命中率约零，无重复调用代价）。
    import threading

    thread_local = threading.local()

    def ask_teacher(pinyin: str) -> str | None:
        client = getattr(thread_local, "client", None)
        if client is None:
            client = CloudModelClient(
                api_key_loader=lambda: load_api_key(args.api_key_file)
            )
            thread_local.client = client
        return teacher_sentence(
            client, model_id=DEFAULT_MODEL_ID, pinyin=pinyin
        )

    rows, stats = synth(
        guard,
        ask_teacher,
        seeds=seeds,
        concurrency=args.concurrency,
    )
    _write_private(
        args.output,
        [
            json.dumps(
                {
                    "pinyin": row["pinyin"],
                    "chosen": row["chosen"],
                    "rejected": row["rejected"],
                    "weight": row["weight"],
                    "source": row["source"],
                    "created_at_ms": row["created_at_ms"],
                },
                ensure_ascii=False,
                sort_keys=True,
            )
            for row in rows
        ],
    )
    print(
        f"teacher synthesis v{VERSION}: requested={stats['requested']} "
        f"abstain_or_error={stats['teacher_abstain_or_error']} "
        f"alignment_dropped={stats['alignment_dropped']} "
        f"kept={stats['kept']} -> {args.output}"
    )
    if stats["kept"] == 0:
        # 全空产出不冒充成功（reveal R3 P2）。
        print(
            "teacher synthesis kept 0 rows — treat as failure",
            file=sys.stderr,
        )
        return 1
    return 0


def _load_seeds_file(
    path: Path, exclude_keys: set[str]
) -> list[tuple[str, tuple[str, ...]]]:
    """Pre-extracted seeds jsonl rows {pinyin, syllables} (e.g. user-
    distribution seeds from history); evaluation-overlap keys are still
    excluded defensively."""
    seeds: list[tuple[str, tuple[str, ...]]] = []
    seen: set[str] = set()
    with path.open(encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
            except ValueError:
                continue
            pinyin = record.get("pinyin")
            syllables = record.get("syllables")
            if (
                isinstance(pinyin, str)
                and pinyin
                and pinyin not in exclude_keys
                and pinyin not in seen
                and isinstance(syllables, list)
                and all(isinstance(s, str) and s for s in syllables)
                and "".join(syllables) == pinyin
            ):
                # 锚定校验（reveal R1 P1-2）：音节必须精确拼出拼音。
                seen.add(pinyin)
                seeds.append((pinyin, tuple(syllables)))
    return seeds


def _eval_pinyin_keys(path: Path) -> set[str]:
    """Pinyin keys of the frozen evaluation set (same posture as
    build_sft_dataset.eval_pinyin_set, but never hard-fails — the
    source-side exclusion is an optimization, the authoritative leak
    check still lives in build_sft_dataset)."""
    keys: set[str] = set()
    if not path.is_file():
        return keys
    with path.open(encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
            except ValueError:
                continue
            pinyin = record.get("pinyin")
            if isinstance(pinyin, str) and pinyin:
                keys.add(pinyin.replace("'", "").replace(" ", ""))
    return keys


if __name__ == "__main__":
    raise SystemExit(main())
