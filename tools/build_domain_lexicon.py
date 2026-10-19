#!/usr/bin/env python3
"""Domain-lexicon builder: TSV source → Rime ``.dict.yaml`` + manifest.

人工只维护 ``source.tsv``（``词 [\\t权重]``，权重可省略默认 50）；
拼音注音由 ``--annotate`` 指定的 Rime 词典（如 luna_pinyin.dict.yaml）
自动完成：词级命中优先，逐字回退取首音；无法注音的词条输出报告，
不进入产物。产出即标准 Rime dict.yaml，可直接被 RimeAI 领域词库导入
端（``DomainLexiconStore.installDictYaml``）与 Rime 本身使用。

用法::

    python3 tools/build_domain_lexicon.py lexicons/it-programming \\
        --annotate .rimeai/rime/shared/luna_pinyin.dict.yaml

权重映射与 Swift 端 ``RimeDictYamlParser.normalizedWeight`` 一致：
Rime 权重 = 词频比例，产物写 ``w * 10``（导入端 w/10 钳回 1–99）。
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import unicodedata
from dataclasses import dataclass, field
from pathlib import Path

# 音节合法性：小写字母；ü 按输入法惯例写作 v。
SYLLABLE_RE = re.compile(r"^[a-z]+$")
TSV_MAX_WEIGHT = 99
TSV_MIN_WEIGHT = 1


@dataclass
class SourceEntry:
    text: str
    weight: int


@dataclass
class BuildReport:
    accepted: list[tuple[str, str, int]] = field(default_factory=list)
    unpronounceable: list[str] = field(default_factory=list)
    invalid_weight: list[str] = field(default_factory=list)
    duplicate_merges: int = 0

    def summary(self) -> dict[str, object]:
        return {
            "entries": len(self.accepted),
            "unpronounceable": len(self.unpronounceable),
            "invalid_weight": len(self.invalid_weight),
            "duplicate_merges": self.duplicate_merges,
        }


def load_annotator_from_text(
    content: str,
) -> tuple[dict[str, str], dict[str, str]]:
    """Returns (word_pinyin, char_pinyin) parsed from dict.yaml text."""
    word: dict[str, str] = {}
    char: dict[str, str] = {}
    in_body = False
    for raw in content.splitlines():
        line = raw.strip()
        if line == "...":
            in_body = True
            continue
        if not in_body or not line or line.startswith("#"):
            continue
        columns = line.split("\t")
        if len(columns) < 2:
            continue
        text, code = columns[0], columns[1].strip().lower()
        joined = "".join(code.split())
        if not joined or not joined.isascii() or not joined.isalpha():
            continue
        if len(text) == 1:
            char.setdefault(text, joined)
        else:
            word.setdefault(text, joined)
    return word, char


def load_annotator(path: Path) -> tuple[dict[str, str], dict[str, str]]:
    """Returns (word_pinyin, char_pinyin) from a Rime .dict.yaml file."""
    return load_annotator_from_text(path.read_text(encoding="utf-8"))


def normalize_pinyin(raw: str) -> str:
    """Lowercase, NFD-strip tone marks, ü→v, whitespace→single space."""
    decomposed = unicodedata.normalize("NFD", raw.lower())
    # NFD 形式的 ü 是 u + 组合分音符；预组合字符在这里已经不存在。
    decomposed = decomposed.replace("u\u0308", "v")
    stripped = "".join(
        ch
        for ch in decomposed
        if not unicodedata.combining(ch)
    )
    return " ".join(stripped.replace("ü", "v").split())


def annotate(text: str, word: dict[str, str], char: dict[str, str]) -> str | None:
    if text in word:
        return word[text]
    syllables: list[str] = []
    index = 0
    while index < len(text):
        matched: str | None = None
        # 贪心最长匹配：先试词级（剩余串最长的候选），单字最后。
        for end in range(len(text), index, -1):
            candidate = text[index:end]
            if candidate in word:
                matched = word[candidate]
                index = end
                break
            if end - index == 1 and candidate in char:
                matched = char[candidate]
                index = end
                break
        if matched is None:
            return None
        syllables.append(matched)
    return " ".join(syllables)


def parse_source_tsv(path: Path) -> tuple[list[SourceEntry], BuildReport]:
    report = BuildReport()
    best: dict[str, SourceEntry] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        columns = line.split("\t")
        text = columns[0].strip()
        if not text:
            continue
        weight = 50
        if len(columns) >= 2 and columns[1].strip():
            try:
                weight = int(columns[1].strip())
            except ValueError:
                report.invalid_weight.append(text)
                continue
        if not TSV_MIN_WEIGHT <= weight <= TSV_MAX_WEIGHT:
            report.invalid_weight.append(text)
            continue
        entry = SourceEntry(text=text, weight=weight)
        if text in best:
            report.duplicate_merges += 1
            if weight > best[text].weight:
                best[text] = entry
        else:
            best[text] = entry
    return sorted(best.values(), key=lambda e: (-e.weight, e.text)), report


def load_manifest(source_dir: Path) -> dict[str, object]:
    manifest_path = source_dir / "manifest.json"
    try:
        manifest = json.loads(
            manifest_path.read_text(encoding="utf-8")
        )
    except FileNotFoundError:
        print(
            f"error: {manifest_path} missing",
            file=sys.stderr,
        )
        raise SystemExit(2) from None
    except json.JSONDecodeError as exc:
        print(
            f"error: {manifest_path} is not valid JSON: {exc}",
            file=sys.stderr,
        )
        raise SystemExit(2) from None
    if not isinstance(manifest.get("name"), str) or not isinstance(
        manifest.get("version"), (str, int)
    ):
        print(
            f"error: {manifest_path} needs string 'name' and 'version'",
            file=sys.stderr,
        )
        raise SystemExit(2) from None
    return manifest


def build(
    source_dir: Path,
    annotator_path: Path,
) -> tuple[str, dict[str, object], BuildReport]:
    manifest_source = load_manifest(source_dir)
    entries, report = parse_source_tsv(source_dir / "source.tsv")
    word, char = load_annotator(annotator_path)

    lines: list[str] = []
    for entry in entries:
        pinyin = annotate(entry.text, word, char)
        if pinyin is None or not pinyin:
            report.unpronounceable.append(entry.text)
            continue
        normalized = normalize_pinyin(pinyin)
        if not normalized:
            report.unpronounceable.append(entry.text)
            continue
        # Rime 权重是词频比例：产物 ×10，导入端 /10 钳回 1–99。
        lines.append(
            f"{entry.text}\t{normalized}\t{entry.weight * 10}"
        )
        report.accepted.append((entry.text, normalized, entry.weight))

    name = manifest_source["name"]
    document = (
        "---\n"
        f"name: {name}\n"
        f"version: \"{manifest_source['version']}\"\n"
        "sort: original\n"
        "...\n"
        "# Generated by tools/build_domain_lexicon.py — do not edit.\n"
        + "\n".join(lines)
        + "\n"
    )
    manifest = {
        **manifest_source,
        "entries": len(report.accepted),
        "unpronounceable": report.unpronounceable,
        "builder": "tools/build_domain_lexicon.py",
    }
    return document, manifest, report


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source_dir", type=Path)
    parser.add_argument(
        "--annotate",
        type=Path,
        required=True,
        help="Rime .dict.yaml used for automatic pinyin annotation",
    )
    parser.add_argument("--out", type=Path, default=None)
    args = parser.parse_args(argv)

    if not (args.source_dir / "source.tsv").exists():
        print(f"error: {args.source_dir}/source.tsv missing", file=sys.stderr)
        return 2
    if not args.annotate.exists():
        print(f"error: annotator {args.annotate} missing", file=sys.stderr)
        return 2

    document, manifest, report = build(args.source_dir, args.annotate)
    out_dir = args.out or (args.source_dir / "dist")
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / f"{manifest['name']}.dict.yaml").write_text(
        document, encoding="utf-8"
    )
    (out_dir / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(json.dumps(report.summary(), ensure_ascii=False))
    if report.unpronounceable:
        print(
            "unpronounceable entries (excluded): "
            + ", ".join(report.unpronounceable[:20]),
            file=sys.stderr,
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
