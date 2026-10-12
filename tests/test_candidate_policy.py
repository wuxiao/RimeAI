from rimeai_runtime.candidate_policy import (
    build_semantic_pairs,
    partition_full_length_candidates,
)


def test_partition_only_reranks_candidates_matching_rime_first_choice_length():
    candidates = [
        {"id": "c0", "text": "能力"},
        {"id": "c1", "text": "挵"},
        {"id": "c2", "text": "内力"},
        {"id": "c3", "text": "儜"},
    ]

    eligible, preserved = partition_full_length_candidates(candidates)

    assert [candidate["id"] for candidate in eligible] == ["c0", "c2"]
    assert [candidate["id"] for candidate in preserved] == ["c1", "c3"]


def test_partition_ignores_spacing_when_comparing_candidate_lengths():
    candidates = [
        {"id": "c0", "text": "API 配置"},
        {"id": "c1", "text": "API配置"},
        {"id": "c2", "text": "API"},
    ]

    eligible, preserved = partition_full_length_candidates(candidates)

    assert [candidate["id"] for candidate in eligible] == ["c0", "c1"]
    assert [candidate["id"] for candidate in preserved] == ["c2"]


def test_context_candidate_pairs_do_not_pollute_query_with_pinyin_labels():
    candidates = [
        {"id": "c0", "text": "明令"},
        {"id": "c1", "text": "命令"},
    ]

    pairs = build_semantic_pairs(
        context="请在终端执行下面这条",
        candidates=candidates,
        strategy="context-candidate",
    )

    assert pairs == [
        ("请在终端执行下面这条", "明令"),
        ("请在终端执行下面这条", "命令"),
    ]


def test_context_completion_pairs_score_the_completed_text():
    candidates = [{"id": "c0", "text": "命令"}]

    pairs = build_semantic_pairs(
        context="请在终端执行下面这条",
        candidates=candidates,
        strategy="context-completion",
    )

    assert pairs == [
        ("请判断候选是否自然地续接前文", "请在终端执行下面这条命令")
    ]
