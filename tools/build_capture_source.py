#!/usr/bin/env python3

import argparse
import bz2
import hashlib
import heapq
import html
import logging
import json
import os
from pathlib import Path
import re
import sys
import tarfile
import tempfile
from typing import Dict, Iterable, Iterator, List, Sequence, Set, Tuple
from urllib.parse import quote
import xml.etree.ElementTree as ET

import jieba
from pypinyin import Style, lazy_pinyin

PROJECT_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT_ROOT))

from rimeai_eval.dataset_split import split_for_document

jieba.setLogLevel(logging.ERROR)

HAN_WORD = re.compile(r"^[\u3400-\u9fff]{2,4}$")
ASCII_PINYIN = re.compile(r"^[a-zv]+$")
SENTENCE_BOUNDARY = re.compile(r"[。！？；\n]+")
HTML_TAG = re.compile(r"<[^>]+>")
MARKDOWN_LINK = re.compile(r"!?\[([^\]]*)\]\([^)]*\)")
MARKDOWN_CODE = re.compile(r"`[^`]*`")
MARKDOWN_DIRECTIVE = re.compile(r"\{\{[^{}]*\}\}")
WIKI_LINK = re.compile(r"\[\[(?:[^\]|]*\|)?([^\]]+)\]\]")
WIKI_TEMPLATE = re.compile(r"\{\{[^{}]*\}\}")
WIKI_REF = re.compile(r"<ref\b[^>]*>.*?</ref>|<ref\b[^>]*/>", re.DOTALL)


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="build a deterministic RimeAI capture source from licensed corpora"
    )
    parser.add_argument("--wikivoyage", required=True, type=Path)
    parser.add_argument("--mdn", required=True, type=Path)
    parser.add_argument("--essay", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--general-samples", type=int, default=5000)
    parser.add_argument("--developer-samples", type=int, default=5000)
    return parser.parse_args()


def load_vocabulary(path: Path) -> Set[str]:
    vocabulary: Set[str] = set()
    with path.open(encoding="utf-8") as essay:
        for line in essay:
            word = line.partition("\t")[0]
            if HAN_WORD.fullmatch(word):
                vocabulary.add(word)
    return vocabulary


def clean_markdown(raw: str) -> str:
    if raw.startswith("---"):
        parts = raw.split("---", 2)
        if len(parts) == 3:
            raw = parts[2]
    raw = re.sub(r"```.*?```", " ", raw, flags=re.DOTALL)
    raw = re.sub(r"~~~.*?~~~", " ", raw, flags=re.DOTALL)
    raw = MARKDOWN_LINK.sub(r"\1", raw)
    raw = MARKDOWN_CODE.sub(" ", raw)
    raw = MARKDOWN_DIRECTIVE.sub(" ", raw)
    raw = HTML_TAG.sub(" ", raw)
    raw = re.sub(r"^[#>*|:\-\s]+", "", raw, flags=re.MULTILINE)
    return html.unescape(raw)


def clean_wikitext(raw: str) -> str:
    raw = WIKI_REF.sub(" ", raw)
    raw = WIKI_LINK.sub(r"\1", raw)
    for _ in range(5):
        updated = WIKI_TEMPLATE.sub(" ", raw)
        if updated == raw:
            break
        raw = updated
    raw = re.sub(r"\{\|.*?\|\}", " ", raw, flags=re.DOTALL)
    raw = re.sub(r"={2,}([^=]+)={2,}", r"\1", raw)
    raw = re.sub(r"'{2,}", "", raw)
    raw = HTML_TAG.sub(" ", raw)
    return html.unescape(raw)


def normalized_sentences(text: str) -> Iterator[str]:
    text = re.sub(r"\s+", " ", text)
    for sentence in SENTENCE_BOUNDARY.split(text):
        sentence = sentence.strip()
        if (
            20 <= len(sentence) <= 500
            and len(re.findall(r"[\u3400-\u9fff]", sentence)) >= 15
        ):
            yield sentence


def wikivoyage_documents(path: Path) -> Iterator[Tuple[str, str, str]]:
    with bz2.open(path, "rb") as source:
        for _, element in ET.iterparse(source, events=("end",)):
            if not element.tag.endswith("page"):
                continue
            title = element.findtext("./{*}title") or ""
            namespace = element.findtext("./{*}ns")
            text = element.findtext("./{*}revision/{*}text") or ""
            if namespace == "0" and title and text:
                url = "https://zh.wikivoyage.org/wiki/" + quote(
                    title.replace(" ", "_")
                )
                yield title, url, clean_wikitext(text)
            element.clear()


def mdn_documents(archive_path: Path) -> Iterator[Tuple[str, str, str]]:
    with tarfile.open(archive_path, "r|gz") as archive:
        for member in archive:
            if not member.isfile() or not member.name.endswith("/index.md"):
                continue
            source = archive.extractfile(member)
            if source is None:
                continue
            relative_name = member.name.removeprefix("./")
            relative = Path(relative_name)
            slug = "/".join(relative.parts[:-1])
            url = "https://developer.mozilla.org/zh-CN/docs/" + quote(slug)
            text = source.read().decode("utf-8")
            yield relative_name, url, clean_markdown(text)


def word_matches(sentence: str, vocabulary: Set[str]) -> Iterator[Tuple[int, str]]:
    for word, start, _ in jieba.tokenize(sentence, mode="default"):
        if start >= 8 and HAN_WORD.fullmatch(word) and word in vocabulary:
            yield start, word


def sample_key(corpus: str, document: str, context: str, word: str) -> str:
    return hashlib.sha256(
        f"{corpus}\0{document}\0{context}\0{word}".encode("utf-8")
    ).hexdigest()


def collect_samples(
    documents: Iterable[Tuple[str, str, str]],
    vocabulary: Set[str],
    corpus: str,
    domain: str,
    license_id: str,
    revision: str,
    limit: int,
) -> List[Dict[str, object]]:
    reservoir_limit = limit * 4
    reservoir: List[Tuple[int, str, Dict[str, object]]] = []
    seen = set()
    for document, url, text in documents:
        for sentence in normalized_sentences(text):
            for start, word in word_matches(sentence, vocabulary):
                context = sentence[max(0, start - 100) : start].strip()
                if len(context) < 8:
                    continue
                dedupe_key = (context, word)
                if dedupe_key in seen:
                    continue
                seen.add(dedupe_key)
                key = sample_key(corpus, document, context, word)
                hash_value = int(key, 16)
                tags = ["context-disambiguation"]
                if domain == "developer":
                    tags.append("technical-term")
                if re.search(r"[A-Za-z]", context):
                    tags.append("mixed-script")
                sample_without_pinyin = {
                    "schema_version": 1,
                    "split": split_for_document(corpus, document),
                    "domain": domain,
                    "context": context,
                    "gold_text": word,
                    "tags": tags,
                    "source": {
                        "corpus": corpus,
                        "document": document,
                        "url": url,
                        "license": license_id,
                        "revision": revision,
                    },
                }
                entry = (-hash_value, key, sample_without_pinyin)
                if len(reservoir) < reservoir_limit:
                    heapq.heappush(reservoir, entry)
                elif hash_value < -reservoir[0][0]:
                    heapq.heapreplace(reservoir, entry)

    samples: List[Dict[str, object]] = []
    for _, key, sample_without_pinyin in sorted(
        reservoir, key=lambda item: item[1]
    ):
        word = str(sample_without_pinyin["gold_text"])
        pinyin_parts = lazy_pinyin(
            word,
            style=Style.NORMAL,
            errors=lambda _: [],
        )
        if (
            len(pinyin_parts) != len(word)
            or any(not ASCII_PINYIN.fullmatch(part) for part in pinyin_parts)
        ):
            continue
        samples.append(
            {
                **sample_without_pinyin,
                "id": f"{domain}-{key[:16]}",
                "pinyin": "".join(pinyin_parts),
            }
        )
        if len(samples) == limit:
            break
    return samples


def write_dataset(path: Path, samples: Sequence[Dict[str, object]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    data = "".join(
        json.dumps(sample, ensure_ascii=False, separators=(",", ":")) + "\n"
        for sample in samples
    )
    descriptor, temporary_name = tempfile.mkstemp(
        dir=path.parent,
        prefix=f".{path.name}.",
        suffix=".tmp",
    )
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary_name, path)
    except BaseException:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass
        raise


def main() -> int:
    arguments = parse_arguments()
    if arguments.general_samples < 1 or arguments.developer_samples < 1:
        print("error: sample counts must be positive", file=sys.stderr)
        return 2
    vocabulary = load_vocabulary(arguments.essay)
    general = collect_samples(
        wikivoyage_documents(arguments.wikivoyage),
        vocabulary,
        "zhwikivoyage",
        "general",
        "CC-BY-SA-4.0",
        "20260701",
        arguments.general_samples,
    )
    developer = collect_samples(
        mdn_documents(arguments.mdn),
        vocabulary,
        "mdn-translated-content",
        "developer",
        "CC-BY-SA-2.5",
        "9780b8cb15f9973e0bfbf5a5d60d3461b3d386ef",
        arguments.developer_samples,
    )
    if len(general) < arguments.general_samples:
        print(
            f"error: only produced {len(general)} general samples",
            file=sys.stderr,
        )
        return 2
    if len(developer) < arguments.developer_samples:
        print(
            f"error: only produced {len(developer)} developer samples",
            file=sys.stderr,
        )
        return 2
    samples = sorted(general + developer, key=lambda sample: str(sample["id"]))
    write_dataset(arguments.output, samples)
    report = {
        "schema_version": 1,
        "samples": len(samples),
        "domains": {
            "developer": len(developer),
            "general": len(general),
        },
        "sha256": hashlib.sha256(arguments.output.read_bytes()).hexdigest(),
    }
    print(json.dumps(report, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
