"""Trainable character n-gram baseline for constrained Rime reranking."""

from collections import Counter
from dataclasses import dataclass
import gzip
import hashlib
import json
import math
import os
from pathlib import Path
import tempfile
from collections.abc import Iterable, Mapping, Sequence
from typing import Any

from .candidate_policy import partition_full_length_candidates


ORDERS = (2, 3, 4, 5)
TOP_K = 10
# Both the counting pass (_build_counts) and the leakage-check key
# (_normalized_text) truncate the context to this window, so rewriting
# characters outside it cannot dodge a text-overlap check.
_TRAIN_CONTEXT_CHARACTERS = 40
_RANK_WEIGHTS = (0.1, 0.25, 0.5, 1.0, 2.0)
_FREQUENCY_WEIGHTS = (0.0, 0.25, 0.5, 1.0, 2.0)
_LANGUAGE_WEIGHTS = (0.0, 0.25, 0.5, 1.0, 2.0)
_BACKOFF_ALPHAS = (0.2, 0.4, 0.6, 0.8)
TERMINAL_LEGACY = "legacy"
TERMINAL_UNIGRAM = "unigram"
_UNIGRAM_ADD_KS = (0.01, 0.1, 1.0)


def _normalized_text(sample: Mapping[str, Any]) -> str:
    """Whitespace-insensitive comparison key for leakage checks.

    The context is truncated to the same training counting window
    (``_TRAIN_CONTEXT_CHARACTERS``) so a rewritten prefix beyond that
    window cannot dodge the overlap check: two contexts differing only
    before the window count identically and must collide here too.
    """
    context = sample.get("context", "")
    return "\x00".join(
        (context[-_TRAIN_CONTEXT_CHARACTERS:], sample.get("gold_text", ""))
    ).replace(" ", "").replace("\t", "").replace("\n", "")


class NGramModelError(ValueError):
    pass


@dataclass(frozen=True)
class UnigramTerminal:
    """Optional unigram-backoff terminal for unseen bigrams.

    When present, the stupid-backoff terminal probability for a character
    with no seen bigram becomes
    ``((unigram_count(c) + add_k) / (total_count + add_k * vocabulary_size))
    * discount`` instead of the legacy constant-numerator add-k estimate.
    Artifacts without this field keep the legacy terminal bit-for-bit.
    """

    unigram_counts: dict[str, int]
    total_count: int
    vocabulary_size: int
    add_k: float
    discount: float


def _terminal_probability(
    unigram_terminal: UnigramTerminal | None,
    character: str,
    bigram_count: int,
    bigram_prefix_count: int,
    backoff_alpha: float,
) -> float:
    """Terminal probability once every n-gram order has missed.

    Single source of truth shared by ``NGramRankerModel._language_score``
    and ``StaticCharLM.next_char_log_prob`` so both stay on the same base
    distribution: with ``unigram_terminal`` the score backs off to the
    character unigram estimate, otherwise the legacy add-k constant
    applies bit-for-bit.
    """
    if unigram_terminal is not None:
        return (
            (
                unigram_terminal.unigram_counts.get(character, 0)
                + unigram_terminal.add_k
            )
            / (
                unigram_terminal.total_count
                + unigram_terminal.add_k * unigram_terminal.vocabulary_size
            )
        ) * unigram_terminal.discount
    return (
        (bigram_count + 0.1) / (bigram_prefix_count + 1000.0)
    ) * backoff_alpha**3


@dataclass(frozen=True)
class NGramRankerModel:
    dataset_sha256: str
    split_counts: dict[str, int]
    rank_weight: float
    frequency_weight: float
    language_weight: float
    candidate_frequencies: dict[str, int]
    ngram_counts: dict[int, dict[str, int]]
    prefix_counts: dict[int, dict[str, int]]
    max_context_characters: int = 40
    top_k: int = TOP_K
    backoff_alpha: float = 0.4
    # None keeps the legacy add-k terminal (bit-for-bit v2 behavior);
    # an UnigramTerminal switches unseen-bigram scoring to unigram
    # backoff. Only artifacts that explicitly carry the new smoothing
    # hyperparameters enable it.
    unigram_terminal: UnigramTerminal | None = None

    @property
    def rerank_window(self) -> int:
        """The Top-K window this model actually reorders.

        Single source of truth for the daemon's user-evidence guard:
        the artifact's ``top_k`` hyperparameter (read back at load
        time), never a daemon-side constant."""
        return self.top_k

    def language_score(self, context: str, candidate: str) -> float:
        """Mean log-probability per character of `candidate` after
        `context` under this model's n-gram counts. Public read-only
        view of the scoring used by `rank`, for evaluation tooling."""
        return self._language_score(context, candidate)

    def _language_score(self, context: str, candidate: str) -> float:
        text = "^" + context[-self.max_context_characters :] + candidate
        candidate_start = len(text) - len(candidate)
        total = 0.0
        terms = 0
        for position in range(candidate_start, len(text)):
            probability = None
            for order in reversed(ORDERS):
                start = position - order + 1
                if start < 0:
                    continue
                gram = text[start : position + 1]
                count = self.ngram_counts[order].get(gram, 0)
                prefix_count = self.prefix_counts[order].get(gram[:-1], 0)
                if count > 0 and prefix_count > 0:
                    probability = (count / prefix_count) * self.backoff_alpha ** (
                        5 - order
                    )
                    break
            if probability is None:
                probability = _terminal_probability(
                    self.unigram_terminal,
                    text[position],
                    self.ngram_counts[2].get(
                        text[position - 1 : position + 1], 0
                    ),
                    self.prefix_counts[2].get(text[position - 1 : position], 0),
                    self.backoff_alpha,
                )
            total += math.log(probability)
            terms += 1
        return total / max(1, terms)

    def _candidate_score(
        self,
        context: str,
        candidate: str,
        baseline_index: int,
    ) -> float:
        return (
            -self.rank_weight * baseline_index
            + self.frequency_weight
            * math.log1p(self.candidate_frequencies.get(candidate, 0))
            + self.language_weight * self._language_score(context, candidate)
        )

    def rank(
        self,
        *,
        context: str,
        candidates: Sequence[str],
    ) -> tuple[list[str], float]:
        semantic_window = [
            {"id": f"c{index}", "text": candidate}
            for index, candidate in enumerate(candidates[: self.top_k])
        ]
        eligible, preserved = partition_full_length_candidates(semantic_window)
        scored = [
            (
                self._candidate_score(
                    context,
                    candidate["text"],
                    int(candidate["id"][1:]),
                ),
                int(candidate["id"][1:]),
                candidate,
            )
            for candidate in eligible
        ]
        scored.sort(key=lambda item: (-item[0], item[1]))
        ranked_window = [item[2]["text"] for item in scored]
        ranked_window.extend(candidate["text"] for candidate in preserved)
        ranked_window.extend(candidates[self.top_k :])
        if len(scored) < 2:
            confidence = 1.0
        else:
            margin = scored[0][0] - scored[1][0]
            confidence = 1.0 / (1.0 + math.exp(-max(-30.0, min(30.0, margin))))
        return ranked_window, confidence

    def to_dict(self) -> dict[str, Any]:
        return {
            # schema v2 = legacy add-k terminal (bit-for-bit with the
            # f23fa49 artifacts); schema v3 = unigram-backoff terminal.
            # Bumping the version (instead of quietly adding keys) keeps
            # the repo fail-closed: a stale loader that only knows v2
            # refuses v3 instead of silently scoring with legacy terminal.
            "schema_version": (
                3 if self.unigram_terminal is not None else 2
            ),
            "model_type": "char-ngram-ranker",
            "dataset_sha256": self.dataset_sha256,
            "split_counts": self.split_counts,
            "hyperparameters": {
                "rank_weight": self.rank_weight,
                "frequency_weight": self.frequency_weight,
                "language_weight": self.language_weight,
                "orders": list(ORDERS),
                "max_context_characters": self.max_context_characters,
                "top_k": self.top_k,
                "smoothing": {
                    "method": "stupid-backoff",
                    "alpha": self.backoff_alpha,
                    "terminal_numerator": 0.1,
                    "terminal_denominator": 1000.0,
                    **(
                        {
                            "unigram_terminal": {
                                "add_k": self.unigram_terminal.add_k,
                                "discount": self.unigram_terminal.discount,
                            }
                        }
                        if self.unigram_terminal is not None
                        else {}
                    ),
                },
            },
            "candidate_frequencies": self.candidate_frequencies,
            **(
                {
                    "unigram_counts": dict(self.unigram_terminal.unigram_counts)
                }
                if self.unigram_terminal is not None
                else {}
            ),
            "ngram_counts": {
                str(order): self.ngram_counts[order] for order in ORDERS
            },
            "prefix_counts": {
                str(order): self.prefix_counts[order] for order in ORDERS
            },
        }


def _build_counts(
    samples: Iterable[dict[str, Any]],
) -> tuple[
    dict[str, int],
    dict[int, dict[str, int]],
    dict[int, dict[str, int]],
    dict[str, int],
]:
    frequencies: Counter[str] = Counter()
    ngram_counters = {order: Counter() for order in ORDERS}
    prefix_counters = {order: Counter() for order in ORDERS}
    unigram_counter: Counter[str] = Counter()
    for sample in samples:
        gold = sample["gold_text"]
        frequencies[gold] += 1
        text = "^" + sample["context"][-_TRAIN_CONTEXT_CHARACTERS:] + gold + "$"
        for character in text:
            unigram_counter[character] += 1
        for order in ORDERS:
            for start in range(len(text) - order + 1):
                gram = text[start : start + order]
                ngram_counters[order][gram] += 1
                prefix_counters[order][gram[:-1]] += 1
    return (
        dict(frequencies),
        {order: dict(counter) for order, counter in ngram_counters.items()},
        {order: dict(counter) for order, counter in prefix_counters.items()},
        dict(unigram_counter),
    )


def _validation_metrics(
    model: NGramRankerModel,
    samples: Sequence[dict[str, Any]],
) -> tuple[float, float, int]:
    covered = 0
    hits = 0
    reciprocal_rank = 0.0
    for sample in samples:
        candidates = sample["candidates"][: model.top_k]
        gold = sample["gold_text"]
        if gold not in candidates:
            continue
        covered += 1
        ranking, _ = model.rank(
            context=sample["context"],
            candidates=sample["candidates"],
        )
        if ranking[0] == gold:
            hits += 1
        reciprocal_rank += 1.0 / (ranking.index(gold) + 1)
    if covered == 0:
        raise NGramModelError(
            "validation split has no gold candidates in the Rime Top-10"
        )
    return hits / covered, reciprocal_rank / covered, covered


def check_extra_train_leakage(
    extra_train_samples: Sequence[dict[str, Any]],
    heldout_samples: Sequence[dict[str, Any]],
    heldout_name: str,
) -> dict[str, Any]:
    """Per-sample id/text overlap between extra corpus and a held-out split.

    Returns a structured result for the training report. The caller (and
    `train_ngram_model` itself, which runs this defensively for every
    dataset split it did not train on) treats any overlap as fatal: extra
    corpus material must never reach counting once it leaks a held-out
    sample by id or by whitespace-normalized context+gold text.
    """
    heldout_ids = {sample["id"] for sample in heldout_samples}
    heldout_texts = {
        _normalized_text(sample) for sample in heldout_samples
    }
    id_overlaps: list[str] = []
    text_overlaps: list[str] = []
    for sample in extra_train_samples:
        if sample["id"] in heldout_ids:
            id_overlaps.append(sample["id"])
        if _normalized_text(sample) in heldout_texts:
            text_overlaps.append(sample["id"])
    return {
        "heldout_split": heldout_name,
        "extra_train_samples": len(extra_train_samples),
        "heldout_samples": len(heldout_samples),
        "id_overlap_samples": len(id_overlaps),
        "id_overlap_examples": sorted(id_overlaps)[:10],
        "text_overlap_samples": len(text_overlaps),
        "text_overlap_examples": sorted(text_overlaps)[:10],
    }


def _dedupe_extra_train(
    train_samples: Sequence[dict[str, Any]],
    extra_train_samples: Sequence[dict[str, Any]],
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    """Drop extra-corpus samples already present in the primary train split.

    Deduplication key is the id first, then the whitespace-normalized
    context+gold text, so a re-captured sentence cannot double-count.
    """
    primary_ids = {sample["id"] for sample in train_samples}
    primary_texts = {
        _normalized_text(sample) for sample in train_samples
    }
    kept: list[dict[str, Any]] = []
    duplicate_ids = 0
    duplicate_texts = 0
    seen_ids: set[str] = set()
    seen_texts: set[str] = set()
    for sample in extra_train_samples:
        if sample["id"] in primary_ids or sample["id"] in seen_ids:
            duplicate_ids += 1
            continue
        normalized = _normalized_text(sample)
        if normalized in primary_texts or normalized in seen_texts:
            duplicate_texts += 1
            continue
        seen_ids.add(sample["id"])
        seen_texts.add(normalized)
        kept.append(sample)
    return kept, {
        "extra_train_input_samples": len(extra_train_samples),
        "duplicate_id_samples_dropped": duplicate_ids,
        "duplicate_text_samples_dropped": duplicate_texts,
        "extra_train_kept_samples": len(kept),
    }


def train_ngram_model(
    samples: Sequence[dict[str, Any]],
    *,
    dataset_sha256: str,
    extra_train_samples: Sequence[dict[str, Any]] = (),
    rank_weight_grid: Sequence[float] = _RANK_WEIGHTS,
    frequency_weight_grid: Sequence[float] = _FREQUENCY_WEIGHTS,
    language_weight_grid: Sequence[float] = _LANGUAGE_WEIGHTS,
    backoff_alpha_grid: Sequence[float] = _BACKOFF_ALPHAS,
    terminal_method_grid: Sequence[str] = (TERMINAL_LEGACY,),
    unigram_add_k_grid: Sequence[float] = _UNIGRAM_ADD_KS,
) -> tuple[NGramRankerModel, dict[str, Any]]:
    """Train the char n-gram ranker on train splits, select on validation.

    Default arguments reproduce the historical v2 trainer exactly: the
    legacy add-k terminal, the original weight/alpha grids, and no extra
    corpus. Pass `terminal_method_grid=("legacy", "unigram")` to also
    scan the unigram-backoff terminal (add_k and the derived alpha**3
    discount join the validation scan), and `extra_train_samples` to
    inject additional train-split-only corpora after a per-sample
    id/text leakage check against every non-train split of `samples`.
    """
    train_samples = [sample for sample in samples if sample["split"] == "train"]
    validation_samples = [
        sample for sample in samples if sample["split"] == "validation"
    ]
    test_samples = [sample for sample in samples if sample["split"] == "test"]
    if not train_samples:
        raise NGramModelError("dataset has no training samples")
    if not validation_samples:
        raise NGramModelError("dataset has no validation samples")
    extra_train: list[dict[str, Any]] = []
    extra_report: dict[str, Any] | None = None
    if extra_train_samples:
        for sample in extra_train_samples:
            if sample.get("split") != "train":
                raise NGramModelError(
                    "extra training corpus may only contain train split "
                    f"samples, got split '{sample.get('split')}' for id "
                    f"'{sample.get('id')}'"
                )
        deduped, dedupe_report = _dedupe_extra_train(
            train_samples, extra_train_samples
        )
        leak_checks = [
            check_extra_train_leakage(
                deduped, heldout, heldout_name
            )
            for heldout, heldout_name in (
                (validation_samples, "validation"),
                (test_samples, "test"),
            )
        ]
        for check in leak_checks:
            if check["id_overlap_samples"] or check["text_overlap_samples"]:
                raise NGramModelError(
                    "extra training corpus leaks held-out "
                    f"{check['heldout_split']} samples (ids: "
                    f"{check['id_overlap_examples']}, texts: "
                    f"{check['text_overlap_examples']}); clean the corpus "
                    "before training"
                )
        extra_train = deduped
        extra_report = {
            **dedupe_report,
            "leakage_checks": leak_checks,
        }
    counted_samples: list[dict[str, Any]] = [*train_samples, *extra_train]
    frequencies, ngram_counts, prefix_counts, unigram_counts = _build_counts(
        counted_samples
    )
    split_counts: dict[str, int] = {
        "train": len(train_samples),
        "validation": len(validation_samples),
    }
    if extra_train:
        split_counts["extra_train"] = len(extra_train)
    total_unigrams = sum(unigram_counts.values())
    vocabulary_size = len(unigram_counts)

    terminal_methods = tuple(terminal_method_grid)
    for method in terminal_methods:
        if method not in (TERMINAL_LEGACY, TERMINAL_UNIGRAM):
            raise NGramModelError(
                f"unknown terminal method '{method}'; expected "
                f"'{TERMINAL_LEGACY}' or '{TERMINAL_UNIGRAM}'"
            )

    best: (
        tuple[
            float,
            float,
            float,
            float,
            float,
            float,
            float,
            float,
            NGramRankerModel,
        ]
        | None
    ) = None
    for terminal_method in terminal_methods:
        add_k_values: Sequence[float] = (
            (0.0,)
            if terminal_method == TERMINAL_LEGACY
            else tuple(unigram_add_k_grid)
        )
        for backoff_alpha in backoff_alpha_grid:
            # The terminal discount follows the backoff chain (order 2
            # already pays alpha**3), so the unigram terminal keeps that
            # exponent: the discount under scan is alpha itself.
            for add_k in add_k_values:
                terminal = (
                    UnigramTerminal(
                        unigram_counts=unigram_counts,
                        total_count=total_unigrams,
                        vocabulary_size=vocabulary_size,
                        add_k=add_k,
                        discount=backoff_alpha**3,
                    )
                    if terminal_method == TERMINAL_UNIGRAM
                    else None
                )
                for rank_weight in rank_weight_grid:
                    for frequency_weight in frequency_weight_grid:
                        for language_weight in language_weight_grid:
                            model = NGramRankerModel(
                                dataset_sha256=dataset_sha256,
                                split_counts=split_counts,
                                rank_weight=rank_weight,
                                frequency_weight=frequency_weight,
                                language_weight=language_weight,
                                backoff_alpha=backoff_alpha,
                                unigram_terminal=terminal,
                                candidate_frequencies=frequencies,
                                ngram_counts=ngram_counts,
                                prefix_counts=prefix_counts,
                            )
                            accuracy, mrr, covered = _validation_metrics(
                                model, validation_samples
                            )
                            selection = (
                                accuracy,
                                mrr,
                                -float(terminal_method == TERMINAL_UNIGRAM),
                                -frequency_weight - language_weight,
                                rank_weight,
                                -language_weight,
                                -backoff_alpha,
                                -add_k if terminal_method == TERMINAL_UNIGRAM else 0.0,
                                model,
                            )
                            if best is None or selection[:-1] > best[:-1]:
                                best = selection
    assert best is not None
    selected_model = best[-1]
    validation_accuracy, validation_mrr, covered = _validation_metrics(
        selected_model, validation_samples
    )
    report = {
        "schema_version": 1,
        "model_type": "char-ngram-ranker",
        "dataset_sha256": dataset_sha256,
        "train_samples": len(train_samples),
        "validation_samples": len(validation_samples),
        "test_samples_used": 0,
        "validation": {
            "covered_samples": covered,
            "conditional_top1_accuracy": round(validation_accuracy, 6),
            "conditional_mrr": round(validation_mrr, 6),
        },
        "selected_hyperparameters": {
            "rank_weight": selected_model.rank_weight,
            "frequency_weight": selected_model.frequency_weight,
            "language_weight": selected_model.language_weight,
            "backoff_alpha": selected_model.backoff_alpha,
            "terminal_method": (
                TERMINAL_UNIGRAM
                if selected_model.unigram_terminal is not None
                else TERMINAL_LEGACY
            ),
            **(
                {
                    "unigram_add_k": selected_model.unigram_terminal.add_k,
                    "unigram_discount": selected_model.unigram_terminal.discount,
                }
                if selected_model.unigram_terminal is not None
                else {}
            ),
        },
        "smoothing_scan": {
            "terminal_method_grid": list(terminal_methods),
            "backoff_alpha_grid": list(backoff_alpha_grid),
            "unigram_add_k_grid": list(unigram_add_k_grid),
            "unigram_discount_rule": "alpha ** 3 (follows the backoff chain)",
        },
    }
    if extra_report is not None:
        report["extra_train"] = extra_report
    return selected_model, report


def write_ngram_model_atomic(path: Path, model: NGramRankerModel) -> str:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        dir=path.parent,
        prefix=f".{path.name}.",
        suffix=".tmp",
    )
    try:
        with os.fdopen(descriptor, "wb") as raw_file:
            with gzip.GzipFile(
                filename="",
                mode="wb",
                fileobj=raw_file,
                mtime=0,
            ) as compressed:
                payload = json.dumps(
                    model.to_dict(),
                    ensure_ascii=False,
                    separators=(",", ":"),
                    sort_keys=True,
                ).encode("utf-8")
                compressed.write(payload)
            raw_file.flush()
            os.fsync(raw_file.fileno())
        os.replace(temporary_name, path)
    except BaseException:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass
        raise
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _parse_unigram_terminal(
    smoothing: Mapping[str, Any],
    payload: Mapping[str, Any],
) -> UnigramTerminal | None:
    """Parse the optional unigram-backoff terminal from an artifact.

    Artifacts without the `unigram_terminal` smoothing hyperparameters
    keep the legacy add-k terminal, so pre-v3 artifacts load and score
    bit-for-bit. Present-but-malformed configurations fail closed.
    """
    config = smoothing.get("unigram_terminal")
    counts_payload = payload.get("unigram_counts")
    if config is None:
        if counts_payload is not None:
            raise NGramModelError(
                "model artifact carries unigram_counts without the "
                "unigram_terminal smoothing hyperparameters"
            )
        return None
    if (
        not isinstance(config, dict)
        or not isinstance(counts_payload, dict)
        or not counts_payload
    ):
        raise NGramModelError(
            "unigram_terminal smoothing requires a config object and a "
            "non-empty unigram_counts table in the artifact"
        )
    add_k = config.get("add_k")
    discount = config.get("discount")
    if (
        isinstance(add_k, bool)
        or not isinstance(add_k, (int, float))
        or not add_k > 0
        or not math.isfinite(add_k)
        or isinstance(discount, bool)
        or not isinstance(discount, (int, float))
        or not discount > 0
        or not math.isfinite(discount)
    ):
        raise NGramModelError("unigram_terminal parameters are invalid")
    unigram_counts: dict[str, int] = {}
    for key, value in counts_payload.items():
        if (
            not isinstance(key, str)
            or isinstance(value, bool)
            or not isinstance(value, int)
            or value < 1
        ):
            raise NGramModelError("unigram_counts entries are invalid")
        unigram_counts[key] = value
    return UnigramTerminal(
        unigram_counts=unigram_counts,
        total_count=sum(unigram_counts.values()),
        vocabulary_size=len(unigram_counts),
        add_k=float(add_k),
        discount=float(discount),
    )


def load_ngram_model(path: Path) -> NGramRankerModel:
    try:
        with gzip.open(path, "rt", encoding="utf-8") as model_file:
            payload = json.load(model_file)
    except (OSError, json.JSONDecodeError) as error:
        raise NGramModelError(f"cannot read model artifact '{path}'") from error
    if (
        not isinstance(payload, dict)
        or payload.get("schema_version") not in (2, 3)
        or payload.get("model_type") != "char-ngram-ranker"
    ):
        raise NGramModelError(
            "unsupported n-gram model artifact; retrain the model to "
            "produce a schema v2 (legacy terminal) or v3 (unigram "
            "terminal) artifact"
        )
    hyperparameters = payload.get("hyperparameters")
    if not isinstance(hyperparameters, dict):
        raise NGramModelError("model hyperparameters are missing")
    if hyperparameters.get("orders") != list(ORDERS):
        raise NGramModelError("model n-gram orders are incompatible")
    smoothing = hyperparameters.get("smoothing")
    if not isinstance(smoothing, dict):
        raise NGramModelError("model smoothing hyperparameters are missing")
    alpha = smoothing.get("alpha")
    if (
        smoothing.get("method") != "stupid-backoff"
        or isinstance(alpha, bool)
        or not isinstance(alpha, (int, float))
        or not 0 < alpha <= 1
    ):
        raise NGramModelError(
            "unsupported n-gram smoothing configuration; retrain the model "
            "to produce a schema v2 stupid-backoff artifact"
        )
    try:
        unigram_terminal = _parse_unigram_terminal(smoothing, payload)
    except NGramModelError:
        raise
    except (KeyError, TypeError, ValueError, AttributeError) as error:
        raise NGramModelError("model artifact fields are invalid") from error
    # Cross-check the terminal payload against the declared schema
    # version: v2 must stay legacy-only and v3 must actually carry the
    # unigram terminal. Hand-written or corrupted mixes fail closed
    # instead of silently picking one scoring semantic.
    if payload.get("schema_version") == 2 and unigram_terminal is not None:
        raise NGramModelError(
            "schema v2 artifact carries unigram_terminal smoothing; "
            "retrain the model to produce a schema v3 artifact"
        )
    if payload.get("schema_version") == 3 and unigram_terminal is None:
        raise NGramModelError(
            "schema v3 artifact is missing the unigram_terminal "
            "smoothing hyperparameters; retrain the model"
        )
    try:
        return NGramRankerModel(
            dataset_sha256=payload["dataset_sha256"],
            split_counts={
                str(key): int(value)
                for key, value in payload["split_counts"].items()
            },
            rank_weight=float(hyperparameters["rank_weight"]),
            frequency_weight=float(hyperparameters["frequency_weight"]),
            language_weight=float(hyperparameters["language_weight"]),
            backoff_alpha=float(smoothing["alpha"]),
            unigram_terminal=unigram_terminal,
            candidate_frequencies={
                str(key): int(value)
                for key, value in payload["candidate_frequencies"].items()
            },
            ngram_counts={
                order: {
                    str(key): int(value)
                    for key, value in payload["ngram_counts"][str(order)].items()
                }
                for order in ORDERS
            },
            prefix_counts={
                order: {
                    str(key): int(value)
                    for key, value in payload["prefix_counts"][str(order)].items()
                }
                for order in ORDERS
            },
            max_context_characters=int(
                hyperparameters["max_context_characters"]
            ),
            top_k=int(hyperparameters["top_k"]),
        )
    except (KeyError, TypeError, ValueError, AttributeError) as error:
        raise NGramModelError("model artifact fields are invalid") from error
