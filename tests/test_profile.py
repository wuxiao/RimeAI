"""Tests for L3 style profiles and cloud compression (LP-005)."""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import pytest

from rimeai_cloud_broker.profile import (
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
    profile = StyleProfile(
        domain="global", revision=1, generated_at_ms=0, generator="t", traits={}
    )
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
