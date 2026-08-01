from rimeai_eval.dataset_split import split_for_document


def test_document_split_is_stable_and_only_uses_source_identity():
    first = split_for_document("mdn", "web/api/fetch/index.md")
    second = split_for_document("mdn", "web/api/fetch/index.md")

    assert first == second
    assert first in {"train", "validation", "test"}


def test_document_split_keeps_all_samples_from_one_document_together():
    documents = [
        ("mdn", "web/api/fetch/index.md"),
        ("mdn", "web/api/url/index.md"),
        ("zhwikivoyage", "上海"),
    ]

    mapping = {
        source: {split_for_document(*source) for _ in range(10)}
        for source in documents
    }

    assert all(len(splits) == 1 for splits in mapping.values())
