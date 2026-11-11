#!/usr/bin/env python3
"""Build a source-grounded assistant-curated dictionary layer.

This layer is an editorial consolidation produced from the project's open
candidate sources.  It is deliberately not the reviewed/published layer:
every entry keeps unresolved flags, ``human_review`` is false, and source
evidence remains attached to each field.  The output is JSONL and is built
from the candidate file with the streaming reader used by the draft layer.
"""

from __future__ import annotations

import argparse
import json
import pathlib
from collections import Counter, defaultdict
from collections.abc import Iterable, Iterator, Mapping
from typing import Any


CURATED_SCHEMA_VERSION = 1
_REVIEW_CHECKS = (
    "source",
    "license",
    "pronunciation",
    "meaning",
    "usage",
    "examples",
    "relations",
)
_COUNTED_FIELDS = (
    "pronunciation_candidates",
    "part_of_speech_candidates",
    "sense_candidates",
    "english_examples",
    "bilingual_examples",
    "collocation_candidates",
    "relation_candidates",
    "variants",
)


def _load_draft_module():
    import importlib.util

    path = pathlib.Path(__file__).with_name("build_dictionary_editorial_draft.py")
    spec = importlib.util.spec_from_file_location("dictionary_editorial_draft", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"unable to load streaming candidate reader: {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _text(value: Any) -> str:
    return value.strip() if isinstance(value, str) else ""


def _mapping(value: Any) -> Mapping[str, Any] | None:
    return value if isinstance(value, Mapping) else None


def _list(value: Any) -> list[Any]:
    return list(value) if isinstance(value, list) else []


def _unique_texts(values: Iterable[Any]) -> list[str]:
    result: list[str] = []
    seen: set[str] = set()
    for value in values:
        text = _text(value)
        if text and text not in seen:
            result.append(text)
            seen.add(text)
    return result


def _source_ids(values: Iterable[Any]) -> list[str]:
    result: list[str] = []
    seen: set[str] = set()
    for value in values:
        item = _mapping(value)
        if item is None:
            continue
        direct = _text(item.get("source_id"))
        if direct and direct not in seen:
            result.append(direct)
            seen.add(direct)
        for nested in _list(item.get("source_ids")):
            source_id = _text(nested)
            if source_id and source_id not in seen:
                result.append(source_id)
                seen.add(source_id)
    return result


def _variant_candidates(values: Iterable[Any]) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    seen: set[tuple[str, str]] = set()
    for value in values:
        item = _mapping(value)
        if item is None:
            continue
        form = _text(item.get("form"))
        if not form:
            continue
        key = (form.casefold(), _text(item.get("part_of_speech")).casefold())
        if key in seen:
            continue
        seen.add(key)
        result.append(
            {
                "form": form,
                "part_of_speech": _text(item.get("part_of_speech")),
                "tags": _unique_texts(_list(item.get("tags"))),
                "source_ids": _unique_texts(_list(item.get("source_ids"))),
                "needs_review": True,
            }
        )
    return result


def _chinese_translation_candidates(value: Any) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    for raw in _list(value):
        item = _mapping(raw)
        if item is None:
            continue
        word = _text(item.get("word"))
        sense = _text(item.get("sense"))
        if not word and not sense:
            continue
        result.append(
            {
                "word": word,
                "sense": sense,
                "roman": _text(item.get("roman")),
                "tags": _unique_texts(_list(item.get("tags"))),
            }
        )
    return result


def _normalize_sense(value: Any) -> dict[str, Any] | None:
    item = _mapping(value)
    if item is None:
        return None
    source_id = _text(item.get("source_id"))
    sense_id = _text(item.get("sense_id"))
    if not source_id or not sense_id:
        return None
    chinese = _unique_texts(_list(item.get("chinese_glosses")))
    english = _unique_texts(_list(item.get("english_glosses")))
    translations = _chinese_translation_candidates(item.get("chinese_translation_candidates"))
    usage_tags = _unique_texts(_list(item.get("usage_tags")))
    source_examples = _unique_texts(_list(item.get("source_examples")))
    return {
        "id": f"{source_id}:{sense_id}",
        "source_id": source_id,
        "part_of_speech": _text(item.get("part_of_speech")),
        "english_glosses": english,
        "chinese_glosses": chinese,
        "chinese_translation_candidates": translations,
        "usage_tags": usage_tags,
        "source_examples": source_examples,
        "synonyms": _unique_texts(_list(item.get("synonyms"))),
        "antonyms": _unique_texts(_list(item.get("antonyms"))),
        "needs_sense_alignment_review": True,
    }


def _normalize_pronunciation(values: Iterable[Any]) -> tuple[dict[str, str], list[dict[str, Any]]]:
    exact: dict[str, str] = {}
    candidates: list[dict[str, Any]] = []
    seen: set[tuple[str, str, str]] = set()
    for raw in values:
        item = _mapping(raw)
        if item is None:
            continue
        value = _text(item.get("value"))
        dialect = _text(item.get("dialect")) or "unspecified"
        notation = _text(item.get("notation"))
        source_id = _text(item.get("source_id"))
        if not value or not source_id:
            continue
        source_word = _text(item.get("source_word"))
        key = (value, dialect, source_word)
        if key in seen:
            continue
        seen.add(key)
        candidates.append(
            {
                "value": value,
                "dialect": dialect,
                "notation": notation,
                "source_id": source_id,
                "source_word": source_word,
                "resolution": _text(item.get("resolution")),
                "exact_word_form": not bool(source_word),
            }
        )
        if notation == "ipa" and not source_word and dialect not in exact:
            exact[dialect] = value
    return exact, candidates


def _normalize_bilingual_examples(values: Iterable[Any]) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    seen: set[str] = set()
    for raw in values:
        item = _mapping(raw)
        if item is None:
            continue
        example_id = _text(item.get("example_id"))
        english = _text(item.get("english_text"))
        chinese = _text(item.get("chinese_text"))
        source_id = _text(item.get("source_id"))
        if not example_id or not english or not chinese or not source_id or example_id in seen:
            continue
        seen.add(example_id)
        attribution = _mapping(item.get("attribution")) or {}
        result.append(
            {
                "example_id": example_id,
                "text": english,
                "translation": chinese,
                "source_id": source_id,
                "attribution": {
                    key: _text(value) for key, value in attribution.items() if _text(value)
                },
                "review_status": _text(item.get("review_status")) or "candidate",
            }
        )
    return result


def _normalize_english_examples(
    values: Iterable[Any], senses: Iterable[Mapping[str, Any]]
) -> list[dict[str, Any]]:
    """Collect top-level examples and recover examples already on source senses."""

    result: list[dict[str, Any]] = []
    seen: set[tuple[str, str]] = set()

    def add(text: Any, source_id: Any, sense_id: Any, example_id: Any) -> None:
        example_text = _text(text)
        source = _text(source_id)
        if not example_text or not source:
            return
        key = (example_text.casefold(), source)
        if key in seen:
            return
        seen.add(key)
        result.append(
            {
                "example_id": _text(example_id) or f"{source}:example:{len(result)}",
                "text": example_text,
                "source_id": source,
                "sense_id": _text(sense_id),
                "review_status": "candidate",
            }
        )

    for raw in values:
        item = _mapping(raw)
        if item is None:
            continue
        add(
            item.get("text"),
            item.get("source_id"),
            item.get("sense_id"),
            item.get("example_id"),
        )
    for sense in senses:
        source_id = _text(sense.get("source_id"))
        sense_id = _text(sense.get("id"))
        for offset, text in enumerate(_list(sense.get("source_examples"))):
            add(text, source_id, sense_id, f"{sense_id}:source-example:{offset}")
    return result


def _normalize_terms(values: Iterable[Any], field: str) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    seen: set[str] = set()
    for raw in values:
        item = _mapping(raw)
        if item is None:
            continue
        text = _text(item.get("text")) or _text(item.get("term"))
        if not text or text.casefold() in seen:
            continue
        seen.add(text.casefold())
        result.append(
            {
                "text": text,
                "source_id": _text(item.get("source_id")),
                "review_status": _text(item.get("review_status")) or "candidate",
                "kind": field,
            }
        )
    return result


def _normalize_relations(values: Iterable[Any]) -> dict[str, list[str]]:
    result: dict[str, list[str]] = defaultdict(list)
    seen: set[tuple[str, str]] = set()
    for raw in values:
        item = _mapping(raw)
        if item is None:
            continue
        relation = _text(item.get("relation"))
        term = _text(item.get("term"))
        if not relation or not term or (relation, term.casefold()) in seen:
            continue
        seen.add((relation, term.casefold()))
        result[relation].append(term)
    return {key: sorted(value, key=str.casefold) for key, value in sorted(result.items())}


def build_assistant_curated_entry(
    candidate: Mapping[str, Any],
    *,
    candidate_source: str,
    candidate_index: int,
) -> dict[str, Any]:
    rich = _mapping(candidate.get("rich_candidate"))
    if rich is None:
        raise ValueError("candidate missing rich_candidate")
    quality = _mapping(rich.get("quality")) or {}
    if _text(quality.get("status")) != "draft":
        raise ValueError("assistant curation only accepts draft candidates")

    base = _mapping(candidate.get("base")) or {}
    entry_id = _text(rich.get("entry_id")) or _text(candidate.get("entry_id"))
    lemma = _text(rich.get("lemma")) or _text(candidate.get("lemma"))
    language_pair = _text(rich.get("language_pair")) or "en-zh"
    if not entry_id or not lemma:
        raise ValueError("candidate missing entry_id or lemma")

    source_ids = _unique_texts(_list(rich.get("source_ids")))
    exact_ipa, pronunciation_candidates = _normalize_pronunciation(
        _list(rich.get("pronunciation_candidates"))
    )
    base_ipa = _text(base.get("ipa"))
    if base_ipa and not exact_ipa:
        exact_ipa = {"base_candidate": base_ipa}
    senses = [
        normalized
        for raw in _list(rich.get("sense_candidates"))
        if (normalized := _normalize_sense(raw)) is not None
    ]
    english_examples = _normalize_english_examples(
        _list(rich.get("english_examples")), senses
    )
    bilingual_examples = _normalize_bilingual_examples(
        _list(rich.get("bilingual_examples"))
    )
    collocations = _normalize_terms(
        _list(rich.get("collocation_candidates")), "collocation"
    )
    variants = _variant_candidates(_list(rich.get("variants")))
    relations = _normalize_relations(_list(rich.get("relation_candidates")))
    pos_candidates = [
        {
            "value": _text(item.get("value")),
            "source_id": _text(item.get("source_id")),
        }
        for item in _list(rich.get("part_of_speech_candidates"))
        if isinstance(item, Mapping) and _text(item.get("value")) and _text(item.get("source_id"))
    ]

    metrics = {
        field: len(_list(rich.get(field))) for field in _COUNTED_FIELDS
    }
    missing_flags: list[str] = []
    if not pronunciation_candidates:
        missing_flags.append("pronunciation_candidates")
    if not bilingual_examples:
        missing_flags.append("bilingual_examples")
    if not english_examples:
        missing_flags.append("english_examples")
    if not collocations:
        missing_flags.append("collocations")
    if not variants:
        missing_flags.append("variants")
    if not relations:
        missing_flags.append("relations")
    if any(item.get("source_word") for item in pronunciation_candidates):
        missing_flags.append("pronunciation_alias_review")
    if not exact_ipa:
        missing_flags.append("ipa")
    missing_flags.extend(
        ["usage_register", "sense_alignment", "license_review", "human_review"]
    )

    return {
        "schema_version": CURATED_SCHEMA_VERSION,
        "layer": "yixue-assistant-curated-draft-v1",
        "entry_id": entry_id,
        "language_pair": language_pair,
        "lemma": lemma,
        "coverage_bands": _unique_texts(_list(rich.get("coverage_bands"))),
        "learning_tags": _unique_texts(_list(rich.get("learning_tags"))),
        "part_of_speech": _text(base.get("part_of_speech")),
        "part_of_speech_candidates": pos_candidates,
        "ipa": exact_ipa,
        "pronunciation_candidates": pronunciation_candidates,
        "senses": senses,
        "english_examples": english_examples,
        "bilingual_examples": bilingual_examples,
        "collocations": [item["text"] for item in collocations],
        "collocation_candidates": collocations,
        "variants": [item["form"] for item in variants],
        "variant_candidates": variants,
        "relations": relations,
        "source_ids": source_ids,
        "source_evidence": {
            "pronunciation": _source_ids(pronunciation_candidates),
            "part_of_speech": _source_ids(pos_candidates),
            "senses": _source_ids(senses),
            "english_examples": _source_ids(english_examples),
            "bilingual_examples": _source_ids(bilingual_examples),
            "collocations": _source_ids(collocations),
            "relations": _source_ids(
                _list(rich.get("relation_candidates"))
            ),
            "variants": _source_ids(variants),
        },
        "candidate_metrics": metrics,
        "review_flags": _unique_texts(missing_flags),
        "quality": {
            "status": "assistant_curated_draft",
            "review_method": "source-grounded assistant consolidation",
            "reviewer": "译学 AI 编辑初审",
            "human_review": False,
            "checks": {name: False for name in _REVIEW_CHECKS},
            "notes": "已按来源归并并保留候选证据；未宣称独立人工终审或正式发布。",
        },
        "candidate_ref": {
            "path": candidate_source.replace("\\", "/"),
            "entry_index": candidate_index,
            "entry_id": entry_id,
        },
    }


def iter_assistant_curated_entries(
    candidates: Iterable[Mapping[str, Any]],
    *,
    candidate_source: str,
) -> Iterator[dict[str, Any]]:
    seen_ids: set[str] = set()
    seen_lemmas: set[str] = set()
    for index, candidate in enumerate(candidates):
        entry = build_assistant_curated_entry(
            candidate,
            candidate_source=candidate_source,
            candidate_index=index,
        )
        entry_id = _text(entry.get("entry_id"))
        lemma = " ".join(_text(entry.get("lemma")).casefold().split())
        if entry_id in seen_ids:
            raise ValueError(f"duplicate entry_id: {entry_id}")
        if lemma in seen_lemmas:
            raise ValueError(f"duplicate lemma: {lemma}")
        seen_ids.add(entry_id)
        seen_lemmas.add(lemma)
        yield entry


def _new_stats(candidate_source: str) -> dict[str, Any]:
    return {
        "schema_version": CURATED_SCHEMA_VERSION,
        "layer": "yixue-assistant-curated-draft-v1",
        "candidate_source": candidate_source.replace("\\", "/"),
        "total_entries": 0,
        "assistant_curated_entries": 0,
        "human_reviewed_entries": 0,
        "published_entries": 0,
        "review_flag_counts": Counter(),
        "candidate_field_counts": Counter(),
        "source_id_counts": Counter(),
    }


def _add_stats(stats: dict[str, Any], entry: Mapping[str, Any]) -> None:
    stats["total_entries"] += 1
    quality = _mapping(entry.get("quality")) or {}
    status = _text(quality.get("status"))
    if status == "assistant_curated_draft":
        stats["assistant_curated_entries"] += 1
    if quality.get("human_review") is True:
        stats["human_reviewed_entries"] += 1
    if status == "published":
        stats["published_entries"] += 1
    stats["review_flag_counts"].update(_list(entry.get("review_flags")))
    metrics = _mapping(entry.get("candidate_metrics")) or {}
    for field, value in metrics.items():
        if isinstance(value, int):
            stats["candidate_field_counts"][field] += value
    stats["source_id_counts"].update(_list(entry.get("source_ids")))


def finalize_stats(stats: dict[str, Any]) -> dict[str, Any]:
    result = dict(stats)
    result["review_flag_counts"] = dict(sorted(stats["review_flag_counts"].items()))
    result["candidate_field_counts"] = dict(sorted(stats["candidate_field_counts"].items()))
    result["source_id_counts"] = dict(sorted(stats["source_id_counts"].items()))
    result["all_entries_are_assistant_curated_draft"] = (
        stats["total_entries"] > 0
        and stats["assistant_curated_entries"] == stats["total_entries"]
    )
    result["no_entry_is_human_reviewed"] = stats["human_reviewed_entries"] == 0
    result["no_entry_is_published"] = stats["published_entries"] == 0
    result["passed"] = bool(
        result["all_entries_are_assistant_curated_draft"]
        and result["no_entry_is_human_reviewed"]
        and result["no_entry_is_published"]
    )
    result["source_records_ref"] = "data/dictionary/editorial-source-records-v1.json"
    result["rule"] = (
        "assistant_curated_draft 只表示来源归并和 AI 编辑初审；"
        "必须由独立人工审校层重新填写并通过 reviewed 验收后才能发布。"
    )
    return result


def _write_json(path: pathlib.Path, payload: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


def write_assistant_curated_layer(
    candidate_input: pathlib.Path,
    output: pathlib.Path,
    report_output: pathlib.Path,
) -> dict[str, Any]:
    draft_module = _load_draft_module()
    stats = _new_stats(candidate_input.as_posix())
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_name(f".{output.name}.tmp")
    temporary.unlink(missing_ok=True)
    try:
        with temporary.open("w", encoding="utf-8", newline="\n") as stream:
            entries = draft_module.iter_candidate_entries(candidate_input)
            for entry in iter_assistant_curated_entries(
                entries,
                candidate_source=candidate_input.as_posix(),
            ):
                stream.write(
                    json.dumps(entry, ensure_ascii=False, separators=(",", ":"))
                )
                stream.write("\n")
                _add_stats(stats, entry)
        report = finalize_stats(stats)
        if not report["passed"]:
            raise ValueError("assistant-curated layer invariants failed")
        temporary.replace(output)
        _write_json(report_output, report)
        return report
    except Exception:
        temporary.unlink(missing_ok=True)
        raise


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--candidate-input",
        type=pathlib.Path,
        default=pathlib.Path("data/dictionary/editorial-candidates-v3.json"),
    )
    parser.add_argument(
        "--output",
        type=pathlib.Path,
        default=pathlib.Path("data/dictionary/editorial-assistant-curated-v1.jsonl"),
    )
    parser.add_argument(
        "--report-output",
        type=pathlib.Path,
        default=pathlib.Path(
            "data/dictionary/editorial-assistant-curated-v1.report.json"
        ),
    )
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    try:
        report = write_assistant_curated_layer(
            args.candidate_input,
            args.output,
            args.report_output,
        )
    except (OSError, UnicodeError, ValueError, json.JSONDecodeError) as error:
        print("ASSISTANT_CURATED_BUILD_REFUSED")
        print(
            json.dumps(
                {"passed": False, "error": f"{type(error).__name__}: {error}"},
                ensure_ascii=True,
            )
        )
        return 1
    print("ASSISTANT_CURATED_BUILD_PASS")
    print(json.dumps(report, ensure_ascii=True, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
