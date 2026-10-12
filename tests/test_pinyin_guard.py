from pathlib import Path

from rimeai_runtime.pinyin_guard import PinyinGuard


def _dictionary(tmp_path: Path) -> Path:
    path = tmp_path / "fixture.dict.yaml"
    path.write_text(
        "---\n"
        "name: fixture\n"
        "...\n"
        "命\tming\n"
        "令\tling\n"
        "重\tzhong\n"
        "重\tchong\n"
        "庆\tqing\n"
        "命令\tming ling\n",
        encoding="utf-8",
    )
    return path


def test_guard_accepts_an_exact_dictionary_phrase(tmp_path: Path):
    guard = PinyinGuard.from_rime_dictionary(_dictionary(tmp_path))

    assert guard.matches("命令", "mingling")


def test_guard_accepts_a_valid_polyphonic_character_path(tmp_path: Path):
    guard = PinyinGuard.from_rime_dictionary(_dictionary(tmp_path))

    assert guard.matches("重庆", "chongqing")
    assert guard.matches("重庆", "zhongqing")
    assert guard.segment("重庆", "chongqing") == ["chong", "qing"]


def test_guard_rejects_text_that_does_not_match_the_original_pinyin(
    tmp_path: Path,
):
    guard = PinyinGuard.from_rime_dictionary(_dictionary(tmp_path))

    assert not guard.matches("命令", "minglin")
    assert not guard.matches("命令。", "mingling")


def test_guard_accepts_abbreviated_pinyin(tmp_path: Path):
    guard = PinyinGuard.from_rime_dictionary(_dictionary(tmp_path))

    assert guard.matches("命令", "mling")
    assert guard.matches("命令", "ml")
    assert guard.segment("命令", "ml") == ["ming", "ling"]
    assert guard.segment("重庆", "cq") == ["chong", "qing"]


def test_guard_rejects_abbreviated_input_without_a_matching_prefix(
    tmp_path: Path,
):
    guard = PinyinGuard.from_rime_dictionary(_dictionary(tmp_path))

    assert not guard.matches("命令", "mg")
    assert not guard.matches("命令", "mlm")
