"""teacher_synthesis 工具与 build_sft_dataset 混合管道的单元测试。

教师调用全部用 stub 注入（不打真实 API）；词典用最小手工 yaml。
"""

from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path

import pytest

TOOL_PATH = (
    Path(__file__).resolve().parent.parent / "tools" / "teacher_synthesis.py"
)
spec = importlib.util.spec_from_file_location("teacher_synthesis", TOOL_PATH)
assert spec is not None and spec.loader is not None
teacher = importlib.util.module_from_spec(spec)
sys.modules.setdefault("teacher_synthesis", teacher)
spec.loader.exec_module(teacher)

BUILDER_PATH = (
    Path(__file__).resolve().parent.parent / "tools" / "build_sft_dataset.py"
)
builder_spec = importlib.util.spec_from_file_location(
    "build_sft_dataset", BUILDER_PATH
)
assert builder_spec is not None and builder_spec.loader is not None
builder = importlib.util.module_from_spec(builder_spec)
sys.modules.setdefault("build_sft_dataset", builder)
builder_spec.loader.exec_module(builder)

from rimeai_runtime.pinyin_guard import PinyinGuard  # noqa: E402

# 最小词典：Rime 格式，多字词拼音用空格分隔音节（音节边界来自词典本身）。
# PinyinGuard.segment 逐字查词典，所以单字条目必须同时存在（真实
# luna_pinyin.dict.yaml 单字与词条并存）。
DICT_CHARS = [
    ("命", "ming"), ("令", "ling"), ("安", "an"), ("装", "zhuang"),
    ("今", "jin"), ("天", "tian"), ("气", "qi"), ("很", "hen"),
    ("好", "hao"), ("引", "yin"), ("擎", "qing"), ("测", "ce"),
    ("试", "shi"),
]
DICT_BODY = [
    ("命令", "ming ling"),
    ("安装", "an zhuang"),
    ("今天", "jin tian"),
    ("天气", "tian qi"),
    ("很好", "hen hao"),
    ("引擎", "yin qing"),
]


@pytest.fixture
def dictionary(tmp_path: Path) -> Path:
    path = tmp_path / "luna_pinyin.dict.yaml"
    path.write_text(
        "# minimal test dictionary\n...\n"
        + "".join(
            f"{word}\t{pinyin}\n"
            for word, pinyin in DICT_CHARS + DICT_BODY
        ),
        encoding="utf-8",
    )
    return path


@pytest.fixture
def guard(dictionary: Path) -> PinyinGuard:
    return PinyinGuard.from_rime_dictionary(dictionary)


class TestSeeds:
    def test_sampling_is_deterministic_under_seed(self, guard, dictionary):
        entries = teacher.dictionary_word_entries(guard, dictionary)
        first = teacher.sample_pinyin_seeds(
            entries, count=5, seed=42, exclude_keys=set()
        )
        second = teacher.sample_pinyin_seeds(
            entries, count=5, seed=42, exclude_keys=set()
        )
        assert first == second
        assert len(first) == 5
        assert len({joined for joined, _ in first}) == 5
        # 每个种子的音节数与连写拼音一致（音节边界来自词典）。
        for joined, syllables in first:
            assert "".join(syllables) == joined

    def test_eval_keys_excluded_at_source(self, guard, dictionary):
        entries = teacher.dictionary_word_entries(guard, dictionary)
        excluded = {"minglinganzhuang"}
        seeds = teacher.sample_pinyin_seeds(
            entries, count=50, seed=7, exclude_keys=excluded
        )
        assert "minglinganzhuang" not in {joined for joined, _ in seeds}


class TestAlignmentFilter:
    def test_exact_alignment_passes(self, guard):
        assert teacher.alignment_filter(guard, "命令", "mingling")
        assert teacher.alignment_filter(guard, "今天天气很好", "jintiantianqihenhao")

    def test_unreproducible_sentence_dropped(self, guard):
        # 词典无法从 mingling 复现「安装」——D4 边界，必须丢弃。
        assert not teacher.alignment_filter(guard, "安装", "mingling")
        # 含词典外字符（英文）同样不可复现。
        assert not teacher.alignment_filter(guard, "命令ok", "minglingok")

    def test_fuzzy_confusion_passes(self, guard):
        # 教师按冻结混淆对纠正了前后鼻音：yin qing 键入为 yin qin。
        assert teacher.alignment_filter(
            guard, "引擎", "yinqin", ("yin", "qin")
        )
        # 无音节信息时只信精确对齐（保守）。
        assert not teacher.alignment_filter(guard, "引擎", "yinqin")


class TestSynth:
    def test_synthesizes_filters_and_counts(self, guard):
        answers = {
            "mingling": "命令",
            "anzhuang": "安装",
            # 词典可复现但与键入拼音错位（D4 边界：不可对齐必颁丢弃）。
            "jintiantianqi": "命令安装",
        }
        seeds = [
            ("mingling", ("ming", "ling")),
            ("anzhuang", ("an", "zhuang")),
            ("jintiantianqi", ("jin", "tian", "tian", "qi")),
            ("tianqi", ("tian", "qi")),
        ]
        rows, stats = teacher.synth(
            guard,
            lambda pinyin: answers.get(pinyin),
            seeds=seeds,
        )
        assert stats == {
            "requested": 4,
            "teacher_abstain_or_error": 1,  # tianqi 无答案（abstain）
            "alignment_dropped": 1,          # jintiantianqi 拼音错位
            "kept": 2,
        }
        assert [row["chosen"] for row in rows] == ["命令", "安装"]
        assert all(row["source"] == "teacher_synthesis" for row in rows)
        assert all(row["rejected"] is None for row in rows)
        assert all(row["weight"] == teacher.WEIGHT_TEACHER_SYNTHESIS for row in rows)


class TestMixIntoDataset:
    def _teacher_jsonl(self, tmp_path: Path) -> Path:
        path = tmp_path / "teacher.jsonl"
        path.write_text(
            "\n".join(
                json.dumps(row, ensure_ascii=False)
                for row in [
                    {
                        "pinyin": "yinqing",
                        "chosen": "引擎",
                        "rejected": None,
                        "weight": 0.5,
                        "source": "teacher_synthesis",
                        "created_at_ms": 5_000,
                    },
                    {
                        # 与真实 adopted 同键：真实数据应胜出。
                        "pinyin": "ceshi",
                        "chosen": "测试",
                        "rejected": None,
                        "weight": 0.5,
                        "source": "teacher_synthesis",
                        "created_at_ms": 4_000,
                    },
                    {"pinyin": "", "chosen": "坏行"},  # 非法行只丢自己
                ]
            )
            + "\n",
            encoding="utf-8",
        )
        return path

    def test_teacher_rows_mixed_and_real_wins(self, tmp_path):
        import sqlite3

        daemon = tmp_path / "decision_log.db"
        with sqlite3.connect(daemon) as db:
            db.executescript(
                """
                CREATE TABLE decisions (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    created_at_ms INTEGER NOT NULL,
                    source TEXT NOT NULL,
                    request_id TEXT NOT NULL,
                    pinyin TEXT NOT NULL,
                    suggestion TEXT NOT NULL,
                    outcome TEXT NOT NULL DEFAULT 'pending'
                );
                INSERT INTO decisions VALUES (1, 1000, 'local_rank',
                    'r1', 'ceshi', '测试', 'adopted');
                """
            )
        eval_path = tmp_path / "eval.jsonl"
        eval_path.write_text(
            json.dumps({"split": "test", "pinyin": "wuguan"}) + "\n",
            encoding="utf-8",
        )
        output = tmp_path / "out"
        code = builder.main(
            [
                "--decision-log", str(daemon),
                "--eval-dataset", str(eval_path),
                "--teacher-synthesis", str(self._teacher_jsonl(tmp_path)),
                "--output-dir", str(output),
                "--min-samples", "1",
            ]
        )
        assert code == builder.EXIT_OK
        rows = [
            json.loads(line)
            for line in (
                output / "sft-constrained-v1.jsonl"
            ).read_text(encoding="utf-8").splitlines()
        ]
        assert len(rows) == 2  # ceshi(真实) + yinqing(教师)；坏行被丢
        sources = {row["pinyin"]: row["source"] for row in rows}
        assert sources["ceshi"] == "daemon/local_rank/adopted"
        assert sources["yinqing"] == "teacher_synthesis"
        lock = json.loads(
            (output / "sft-constrained-v1.lock.json").read_text(
                encoding="utf-8"
            )
        )
        assert lock["counts"]["teacher_rows_loaded"] == 1
        assert lock["counts"]["teacher_shadowed_by_real"] == 1
        assert lock["counts"]["teacher_invalid_dropped"] == 1
        # ceshi 教师行与真实行同拼音：让位（矛盾金标不共存），
        # 不再走 duplicates_dropped 路径。
        assert lock["counts"]["duplicates_dropped"] == 0
        assert lock["sources"]["teacher_synthesis"].endswith("teacher.jsonl")
