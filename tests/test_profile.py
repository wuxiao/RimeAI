"""Tests for L3 style profiles and cloud compression (LP-005)."""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import pytest

from rimeai_cloud_broker.profile import (
    DOMAIN_PATTERN,
    MAX_BATCH_BYTES,
    MAX_BATCH_CHARACTERS,
    CloudProfileSummarizer,
    ProfileError,
    ProfileStore,
    StyleProfile,
    make_semantic_consolidator,
    merge_profile,
    profile_from_payload,
)


def _completion(content: str) -> dict[str, Any]:
    return {
        "choices": [
            {
                "message": {"role": "assistant", "content": content},
                "finish_reason": "stop",
            }
        ]
    }


def test_profile_round_trip_and_validation(tmp_path: Path):
    profile = StyleProfile(
        domain="work",
        revision=3,
        generated_at_ms=1_000,
        generator="glm-5.3-flash@cloud",
        traits={"register": ["classical", "terse"]},
        locked_fields=["register"],
    )
    restored = profile_from_payload(profile.to_payload())
    assert restored == profile

    with pytest.raises(ProfileError):
        StyleProfile(domain="", revision=1, generated_at_ms=0, generator="g", traits={})
    with pytest.raises(ProfileError):
        StyleProfile(
            domain="x",
            revision=-1,
            generated_at_ms=0,
            generator="g",
            traits={},
        )
    with pytest.raises(ProfileError):
        StyleProfile(
            domain="x",
            revision=1,
            generated_at_ms=0,
            generator="g",
            traits={},
            locked_fields=["not_a_trait"],
        )
    with pytest.raises(ProfileError):
        profile_from_payload({"schema_version": 99})


def test_unknown_trait_keys_are_dropped_and_bounded():
    traits = {
        "register": ["classical"],
        "unknown_key": ["dropped"],
        "signature_phrases": ["口头禅"],
    }
    profile = StyleProfile(
        domain="global",
        revision=1,
        generated_at_ms=0,
        generator="test",
        traits=traits,
    )
    assert set(profile.traits) == {"register", "signature_phrases"}

    with pytest.raises(ProfileError):
        StyleProfile(
            domain="global",
            revision=1,
            generated_at_ms=0,
            generator="test",
            traits={"register": ["ok", ""]},  # blank items rejected
        )
    with pytest.raises(ProfileError):
        StyleProfile(
            domain="global",
            revision=1,
            generated_at_ms=0,
            generator="test",
            traits={"signature_phrases": ["长" * 65]},  # exceeds cap
        )


def test_merge_protects_locked_fields_and_deduplicates():
    previous = StyleProfile(
        domain="global",
        revision=4,
        generated_at_ms=1_000,
        generator="old",
        traits={
            "register": ["classical"],
            "signature_phrases": ["旧句", "保留句"],
        },
        locked_fields=["register"],
    )
    merged = merge_profile(
        previous,
        {
            "register": ["colloquial"],  # locked: must not win
            "signature_phrases": ["新句", "旧句"],
        },
        domain="global",
        generator="glm-5.3-flash@cloud",
    )
    assert merged.revision == 5
    assert merged.traits["register"] == ["classical"]
    assert merged.traits["signature_phrases"] == ["新句", "旧句", "保留句"]
    assert merged.locked_fields == ["register"]

    first = merge_profile(
        None, {"register": ["formal"]}, domain="work", generator="g"
    )
    assert first.revision == 1


def test_profile_store_versions_and_rollback(tmp_path: Path):
    store = ProfileStore(tmp_path / "language_profile")

    def save_revision(domain: str, marker: str) -> None:
        current = store.load(domain)
        store.save(
            merge_profile(
                current,
                {"register": [marker]},
                domain=domain,
                generator="test",
            )
        )

    assert store.load("work") is None
    for marker in ("v1", "v2", "v3"):
        save_revision("work", marker)

    current = store.load("work")
    assert current is not None
    assert current.revision == 3
    assert current.traits["register"] == ["v3"]

    rolled = store.rollback("work")
    assert rolled is not None and rolled.traits["register"] == ["v2"]
    again = store.rollback("work")
    assert again is not None and again.traits["register"] == ["v1"]

    # Domains are isolated.
    save_revision("chat", "chat-only")
    assert store.load("chat") is not None
    assert store.load("work") is not None

    removed = store.clear("chat")
    assert removed >= 1
    assert store.load("chat") is None
    assert store.load("work") is not None


def test_revision_history_is_bounded(tmp_path: Path):
    store = ProfileStore(tmp_path / "language_profile")
    for revision in range(1, 16):
        store.save(
            StyleProfile(
                domain="global",
                revision=revision,
                generated_at_ms=revision,
                generator="t",
                traits={},
            )
        )
    archived = list((tmp_path / "language_profile" / "revisions").glob("global-*.json"))
    assert len(archived) <= 11  # 10 kept plus rollback artifacts bound


def test_summarizer_truncates_line_aligned_keeping_newest():
    # 超批量预算时按整条丢弃最旧条目（行对齐），绝不把一条上屏原文
    # 拦腰截成残片喂给模型；保留最新尾部（旧批次风格已由
    # previous_traits 携带）。预算按 UTF-8 字节计（设置页披露的
    # “每域每轮 24KB”），所以全中文语料会先于字符上限触顶。
    captured: dict[str, Any] = {}

    def transport(path: str, payload: dict[str, Any], *, timeout: float) -> dict[str, Any]:
        captured["payload"] = payload
        return _completion(json.dumps({"register": ["x"]}))

    summarizer = CloudProfileSummarizer(transport)
    # 每条 1000 个汉字 = 3000 字节；10 条共 10,000 字符（未超字符
    # 上限）但 30,000 字节（超 24KB 字节预算）→ 必须截断。
    texts = [f"{index}" + "旧" * 999 for index in range(10)]
    summarizer.summarize(texts, None)
    content = captured["payload"]["messages"][1]["content"]
    corpus = json.loads(content)["committed_text"]
    assert len(corpus.encode("utf-8")) <= MAX_BATCH_BYTES
    assert len(corpus) <= MAX_BATCH_CHARACTERS
    kept = corpus.split("\n")
    # 保留最新的若干条，最旧的整条被丢弃（不拦腰截断）。
    assert kept == texts[-len(kept):]
    assert len(kept) < len(texts)


def test_summarizer_truncates_a_single_oversized_entry_to_its_tail():
    # 单条原文超过整个批量预算时不能发出空 corpus；退化为该条尾部
    # 截断（旧行为对该场景的语义），仍不超预算（字节与字符双上限）。
    captured: dict[str, Any] = {}

    def transport(path: str, payload: dict[str, Any], *, timeout: float) -> dict[str, Any]:
        captured["payload"] = payload
        return _completion(json.dumps({"register": ["x"]}))

    summarizer = CloudProfileSummarizer(transport)
    huge = "巨" * (MAX_BATCH_CHARACTERS + 500)
    summarizer.summarize([huge], None)
    content = captured["payload"]["messages"][1]["content"]
    corpus = json.loads(content)["committed_text"]
    assert len(corpus.encode("utf-8")) <= MAX_BATCH_BYTES
    assert len(corpus) <= MAX_BATCH_CHARACTERS
    assert huge.endswith(corpus)


def test_summarizer_clamps_malformed_llm_traits():
    # 模型偶尔会把 trait 值写成裸字符串/混入空项、非字符串项、超长项。
    # summarize 面向 LLM 输出，必须走 clamp 容错：能捞的捞，坏的丢，
    # 绝不抛 ProfileError——严格抛错会让 consolidation 批次无限重试
    # 同一批文本（日志里实测的死循环）。
    def transport(
        path: str, payload: dict[str, Any], *, timeout: float
    ) -> dict[str, Any]:
        return _completion(
            json.dumps(
                {
                    "register": "书面语",  # 裸字符串 → 单元素列表
                    "cn_en_mixing": {"style": 1},  # 非 list 非 str → 丢该 key
                    "signature_phrases": [  # 空项/非字符串项/超长项 → 跳过，保留好的
                        "常用短语",
                        "",
                        123,
                        "长" * 65,
                    ],
                    "vocabulary_domains": ["技术", "医学"],
                },
                ensure_ascii=False,
            )
        )

    summarizer = CloudProfileSummarizer(transport)
    traits = summarizer.summarize(["你好"], None)
    assert traits == {
        "register": ["书面语"],
        "signature_phrases": ["常用短语"],
        "vocabulary_domains": ["技术", "医学"],
    }


def test_summarizer_parses_strict_and_embedded_json():
    captured: dict[str, Any] = {}

    def transport(path: str, payload: dict[str, Any], *, timeout: float) -> dict[str, Any]:
        captured["payload"] = payload
        captured["path"] = path
        return _completion(
            json.dumps(
                {
                    "register": ["classical"],
                    "signature_phrases": ["接口设计"],
                },
                ensure_ascii=False,
            )
        )

    summarizer = CloudProfileSummarizer(transport)
    traits = summarizer.summarize(["诗人疾之不能默"], None)
    assert traits["register"] == ["classical"]
    assert traits["signature_phrases"] == ["接口设计"]
    assert captured["path"] == "/chat/completions"
    assert captured["payload"]["model"] == "glm-5.3-flash"
    assert captured["payload"]["thinking"] == {"type": "disabled"}
    assert "committed_text" in captured["payload"]["messages"][1]["content"]


def test_summarizer_extracts_json_from_prose_and_rejects_garbage():
    def prose_transport(
        path: str, payload: dict[str, Any], *, timeout: float
    ) -> dict[str, Any]:
        return _completion(
            '好的，以下是压缩结果：{"register": ["formal"]} 请查收'
        )

    traits = CloudProfileSummarizer(prose_transport).summarize(["文本"], None)
    assert traits == {"register": ["formal"]}

    def garbage_transport(
        path: str, payload: dict[str, Any], *, timeout: float
    ) -> dict[str, Any]:
        return _completion("完全不是 JSON 的回复")

    with pytest.raises(ProfileError):
        CloudProfileSummarizer(garbage_transport).summarize(["文本"], None)

    def empty_transport(
        path: str, payload: dict[str, Any], *, timeout: float
    ) -> dict[str, Any]:
        return {}

    with pytest.raises(ProfileError):
        CloudProfileSummarizer(empty_transport).summarize(["文本"], None)


@dataclass(frozen=True)
class _Commit:
    bundle_id: str
    committed_text: str


def test_semantic_consolidator_groups_by_domain_and_saves(tmp_path: Path):
    store = ProfileStore(tmp_path / "language_profile")
    seen_domains: list[str] = []

    def transport(path: str, payload: dict[str, Any], *, timeout: float) -> dict[str, Any]:
        content = json.dumps(
            {"register": ["classical"], "signature_phrases": ["口头禅"]}
        )
        return _completion(content)

    summarizer = CloudProfileSummarizer(transport)

    def resolver(bundle_id: str) -> str:
        seen_domains.append(bundle_id)
        return "work" if bundle_id == "com.example.Work" else "global"

    consolidate = make_semantic_consolidator(
        store, summarizer, domain_resolver=resolver
    )

    batch = [
        _Commit("com.example.Work", "接口设计文档"),
        _Commit("com.example.Work", "接口实现评审"),
        _Commit("com.example.Chat", "哈哈哈哈"),
    ]
    assert consolidate(batch) is True

    work = store.load("work")
    global_profile = store.load("global")
    assert work is not None and work.revision == 1
    assert global_profile is not None and global_profile.revision == 1
    assert set(seen_domains) == {
        "com.example.Work",
        "com.example.Chat",
    }


def test_semantic_consolidator_failure_propagates(tmp_path: Path):
    store = ProfileStore(tmp_path / "language_profile")

    def failing_transport(
        path: str, payload: dict[str, Any], *, timeout: float
    ) -> dict[str, Any]:
        raise OSError("gateway unreachable")

    summarizer = CloudProfileSummarizer(failing_transport)
    consolidate = make_semantic_consolidator(
        store, summarizer, domain_resolver=lambda bundle: "global"
    )
    with pytest.raises(OSError):
        consolidate([_Commit("com.example.Chat", "文本")])
    # The pipeline converts this into ConsolidationError and keeps the
    # batch for retry, so no profile may be persisted.
    assert store.load("global") is None


def test_rollback_never_strands_the_current_profile(tmp_path: Path):
    # M4 回归：保存 15 版（归档超过上限触发裁剪）后连续回滚，当前
    # profile 文件任何时候都必须存在，且 revision 单调递减。
    store = ProfileStore(tmp_path / "language_profile")
    for revision in range(1, 16):
        store.save(
            StyleProfile(
                domain="global",
                revision=revision,
                generated_at_ms=revision,
                generator="t",
                traits={"register": [f"v{revision}"]},
            )
        )
    expected = 15
    for _ in range(15):
        rolled = store.rollback("global")
        assert rolled is not None
        # Revision decreases while older archives survive the bounded
        # history; once they are trimmed away rollback holds at the floor
        # instead of ever stranding the domain without a current profile.
        assert rolled.revision <= expected
        expected = rolled.revision
        assert store.load("global") is not None


def test_domain_charset_matches_daemon_validator():
    # P1-3：三层域字符集必须一致（Swift 侧由 PhraseBookStoreTests 锁同一矩阵）。
    from rimeai_daemon.server import is_valid_domain

    valid = ("global", "work", "dev-tools", "a1", "-", "x" * 64)
    invalid = (
        "my_work",
        "work_chat",
        "中文域",
        "UPPER",
        "",
        "x" * 65,
        "../escape",
        "work space",
    )
    for domain in valid:
        assert is_valid_domain(domain), domain
        assert DOMAIN_PATTERN.fullmatch(domain), domain
    for domain in invalid:
        assert not is_valid_domain(domain), domain
        assert DOMAIN_PATTERN.fullmatch(domain) is None, domain


def test_profile_domain_charset_is_validated(tmp_path: Path):
    # M7：domain 会插值进文件名，字符集必须封闭（镜像 daemon 请求校验
    # 与 Swift PhraseBookStore 的域校验）。
    for bad in ("../escape", "Global", "work space", "d/o", "域"):
        with pytest.raises(ProfileError):
            StyleProfile(
                domain=bad,
                revision=1,
                generated_at_ms=0,
                generator="t",
                traits={},
            )


def _profile(domain: str, revision: int) -> StyleProfile:
    return StyleProfile(
        domain=domain,
        revision=revision,
        generated_at_ms=revision * 1_000,
        generator="test@local",
        traits={"register": ["casual"]},
    )


def test_trait_item_limits_single_source_covers_every_key():
    # P2-merge：traits 上限必须来自同一张表，sanitize 与 merge 不得各写
    # 各的常量后再漂移。
    from rimeai_cloud_broker.profile import (
        ALLOWED_TRAIT_KEYS,
        MAX_SIGNATURE_PHRASES,
        MAX_TRAIT_ITEMS,
        TRAIT_ITEM_LIMITS,
    )

    assert set(TRAIT_ITEM_LIMITS) == set(ALLOWED_TRAIT_KEYS)
    assert TRAIT_ITEM_LIMITS["signature_phrases"] == MAX_SIGNATURE_PHRASES
    for key in ALLOWED_TRAIT_KEYS:
        if key != "signature_phrases":
            assert TRAIT_ITEM_LIMITS[key] == MAX_TRAIT_ITEMS


def test_merge_clamps_every_trait_to_its_limit():
    from rimeai_cloud_broker.profile import TRAIT_ITEM_LIMITS

    over = {
        key: [f"{key}-item-{index}" for index in range(limit + 5)]
        for key, limit in TRAIT_ITEM_LIMITS.items()
    }
    merged = merge_profile(
        None, over, domain="work", generator="test@local"
    )
    for key, limit in TRAIT_ITEM_LIMITS.items():
        assert len(merged.traits[key]) <= limit


def test_concurrent_saves_per_domain_never_lose_a_revision(tmp_path: Path):
    # P2-lock：并发 save 同一域必须串行——最终 revision 等于写入次数，
    # last-write-wins 交错会丢修订号。
    import threading

    store = ProfileStore(tmp_path)
    writers = 6
    saves_per_writer = 8

    def write_all() -> None:
        for _ in range(saves_per_writer):
            store.update(
                "work",
                lambda current: _profile(
                    "work", (current.revision if current else 0) + 1
                ),
            )

    threads = [
        threading.Thread(target=write_all) for _ in range(writers)
    ]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    final = store.load("work")
    assert final is not None
    assert final.revision == writers * saves_per_writer


def test_domain_locks_are_scoped_per_domain(tmp_path: Path):
    store = ProfileStore(tmp_path)
    # 另一域不受同域临界区阻塞（不同锁文件，可嵌套持有）。
    with store.locked("work"), store.locked("chat"):
        pass


def test_revision_trim_keeps_newest_under_stamp_collisions(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
):
    # P3-nit：同一毫秒内的归档后缀 -10/-11 在字典序下排在 -2 之前，
    # 裁剪必须按 (stamp, suffix) 数值序而不是文件名排序。
    from rimeai_cloud_broker import profile as profile_module

    monkeypatch.setattr(
        profile_module.time, "time", lambda: 1_700_000_000.0
    )
    store = ProfileStore(tmp_path)
    total = profile_module.MAX_REVISIONS_KEPT + 3
    for revision in range(1, total + 1):
        store.save(_profile("work", revision))
    kept = sorted(
        tmp_path.joinpath("revisions").glob("work-*.json")
    )
    assert len(kept) == profile_module.MAX_REVISIONS_KEPT
    kept_revisions = []
    for candidate in kept:
        payload = json.loads(candidate.read_text(encoding="utf-8"))
        kept_revisions.append(int(payload["revision"]))
    expected = list(range(1, total + 1))[-profile_module.MAX_REVISIONS_KEPT:]
    # 归档的是“被替换下来的上一版”，所以 revision 1..total-1 才进历史。
    expected = list(range(1, total))[-profile_module.MAX_REVISIONS_KEPT:]
    assert sorted(kept_revisions) == expected
