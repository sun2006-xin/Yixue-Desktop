#!/usr/bin/env python3
"""Normalize independent dictionary sources into a reviewable rich candidate.

This file is an editorial bridge, not a license merger and not a publisher.
Every source remains visible on each field, bilingual examples retain Tatoeba
attribution, and the resulting quality state is always ``draft``.
"""

from __future__ import annotations

import argparse
import copy
import json
import pathlib
from collections import Counter
from typing import Iterable, Mapping


RICH_SCHEMA_VERSION = 1
OPEN_SOURCE_ID = "open-ecdict"
ECDICT_SOURCE_ID = "ecdict-raw-master"
WORDNET_SOURCE_ID = "wordnet-3.0"
TATOEBA_SOURCE_ID = "tatoeba-cc-by-2.0-fr"
KAIKKI_SOURCE_ID = "wiktionary-kaikki-2026-09"


def _unique_strings(values: Iterable[object], *, limit: int | None = None) -> list[str]:
    result: list[str] = []
    seen: set[str] = set()
    for value in values:
        if not isinstance(value, str):
            continue
        text = " ".join(value.split()).strip()
        if not text or text in seen:
            continue
        seen.add(text)
        result.append(text)
        if limit is not None and len(result) >= limit:
            break
    return result


def _mapping(value: object) -> Mapping[str, object]:
    return value if isinstance(value, Mapping) else {}


def _list(value: object) -> list[object]:
    return value if isinstance(value, list) else []


def _normalize(value: object) -> str:
    return " ".join(str(value).strip().lower().split())


def _append_source(sources: list[str], source_id: str) -> None:
    if source_id and source_id not in sources:
        sources.append(source_id)


def _build_variants(entry: Mapping[str, object], kaikki_records: list[Mapping[str, object]]) -> list[dict[str, object]]:
    lemma = _normalize(entry.get("lemma", ""))
    merged: dict[str, dict[str, object]] = {}
    for value in _list(entry.get("variants")):
        if not isinstance(value, str):
            continue
        key = _normalize(value)
        if not key or key == lemma:
            continue
        row = merged.setdefault(key, {"form": value.strip(), "tags": [], "source_ids": []})
        _append_source(row["source_ids"], ECDICT_SOURCE_ID)  # type: ignore[arg-type]
    for record in kaikki_records:
        pos = str(record.get("pos", "")).strip()
        for form in _list(record.get("forms")):
            form_map = _mapping(form)
            value = form_map.get("form")
            if not isinstance(value, str):
                continue
            key = _normalize(value)
            if not key or key == lemma:
                continue
            row = merged.setdefault(key, {"form": value.strip(), "tags": [], "source_ids": []})
            tags = row["tags"]
            if isinstance(tags, list):
                tags[:] = _unique_strings([*tags, *(_list(form_map.get("tags")))])
            _append_source(row["source_ids"], KAIKKI_SOURCE_ID)  # type: ignore[arg-type]
            if pos:
                row["part_of_speech"] = pos
    return [merged[key] for key in sorted(merged)]


def _build_pronunciation(
    entry: Mapping[str, object],
    kaikki_records: list[Mapping[str, object]],
    kaikki_page: Mapping[str, object] | None = None,
) -> list[dict[str, object]]:
    result: list[dict[str, object]] = []
    seen: set[tuple[str, str, str]] = set()

    def add(
        value: object,
        dialect: str,
        source_id: str,
        notation: str = "ipa",
        pos: str = "",
    ) -> dict[str, object] | None:
        if not isinstance(value, str) or not value.strip():
            return None
        normalized = value.strip()
        key = (normalized, dialect, source_id)
        if key in seen:
            return None
        seen.add(key)
        item: dict[str, object] = {
            "value": normalized,
            "dialect": dialect,
            "notation": notation,
            "source_id": source_id,
        }
        if pos:
            item["part_of_speech"] = pos
        result.append(item)
        return item

    base = _mapping(entry.get("base"))
    base_ipa = base.get("ipa")
    if isinstance(base_ipa, str) and base_ipa.strip() not in {"", "—", "-"}:
        add(base_ipa, "base", OPEN_SOURCE_ID)
    ecdict = _mapping(entry.get("ecdict"))
    add(ecdict.get("phonetic"), "unspecified", ECDICT_SOURCE_ID, notation="legacy-phonetic")

    def add_kaikki_records(
        records: Iterable[Mapping[str, object]], source_word: str = ""
    ) -> None:
        for record in records:
            pos = str(record.get("pos", "")).strip()
            for dialect, values in _mapping(record.get("ipa")).items():
                for value in _list(values):
                    added = add(value, str(dialect), KAIKKI_SOURCE_ID, pos=pos)
                    if source_word and added is not None:
                        added["source_word"] = source_word
                        added["resolution"] = "audited_alias_candidate"

    alias_word = ""
    if isinstance(kaikki_page, Mapping) and kaikki_page.get("match_type") == "alias":
        resolved_word = _normalize(kaikki_page.get("resolved_word", ""))
        lemma = _normalize(entry.get("lemma", ""))
        if resolved_word and resolved_word != lemma:
            alias_word = resolved_word

    add_kaikki_records(kaikki_records, alias_word)
    if isinstance(kaikki_page, Mapping):
        for alias_page in _list(kaikki_page.get("pronunciation_alias_pages")):
            alias_map = _mapping(alias_page)
            source_word = _normalize(alias_map.get("resolved_word", ""))
            if not source_word:
                continue
            records = [
                _mapping(record)
                for record in _list(alias_map.get("records"))
                if isinstance(record, Mapping)
            ]
            add_kaikki_records(records, source_word)
    return result


def _build_pos_candidates(entry: Mapping[str, object], kaikki_records: list[Mapping[str, object]]) -> list[dict[str, str]]:
    result: list[dict[str, str]] = []
    seen: set[tuple[str, str]] = set()

    def add(value: object, source_id: str) -> None:
        text = str(value).strip() if value is not None else ""
        if not text or text == "待核对":
            return
        key = (text, source_id)
        if key not in seen:
            seen.add(key)
            result.append({"value": text, "source_id": source_id})

    base = _mapping(entry.get("base"))
    add(base.get("part_of_speech"), OPEN_SOURCE_ID)
    wordnet = _mapping(entry.get("wordnet"))
    for sense in _list(wordnet.get("senses")):
        add(_mapping(sense).get("part_of_speech"), WORDNET_SOURCE_ID)
    for record in kaikki_records:
        add(record.get("pos"), KAIKKI_SOURCE_ID)
    return result


def _build_sense_candidates(entry: Mapping[str, object], kaikki_records: list[Mapping[str, object]]) -> list[dict[str, object]]:
    result: list[dict[str, object]] = []
    base = _mapping(entry.get("base"))
    base_meanings = _unique_strings(_list(base.get("meanings")))
    if base_meanings:
        result.append(
            {
                "source_id": OPEN_SOURCE_ID,
                "kind": "chinese_glosses",
                "sense_id": "record:open-ecdict",
                "part_of_speech": str(base.get("part_of_speech", "")).strip(),
                "chinese_glosses": base_meanings,
            }
        )

    ecdict = _mapping(entry.get("ecdict"))
    definitions = _unique_strings(_list(ecdict.get("definitions")))
    translations = _unique_strings(_list(ecdict.get("translations")))
    if definitions or translations:
        result.append(
            {
                "source_id": ECDICT_SOURCE_ID,
                "kind": "source_candidate",
                "sense_id": "record:ecdict-raw-master",
                "english_glosses": definitions,
                "chinese_glosses": translations,
            }
        )

    wordnet = _mapping(entry.get("wordnet"))
    for sense in _list(wordnet.get("senses")):
        sense_map = _mapping(sense)
        definition = sense_map.get("definition")
        if not isinstance(definition, str) or not definition.strip():
            continue
        result.append(
            {
                "source_id": WORDNET_SOURCE_ID,
                "kind": "source_candidate",
                "sense_id": str(sense_map.get("synset_offset", "")),
                "part_of_speech": str(sense_map.get("part_of_speech", "")).strip(),
                "english_glosses": [definition.strip()],
                "source_examples": _unique_strings(_list(sense_map.get("examples")), limit=8),
                "relations": _mapping(sense_map.get("relations")),
            }
        )

    for record_index, record in enumerate(kaikki_records):
        pos = str(record.get("pos", "")).strip()
        for sense_index, sense in enumerate(_list(record.get("senses"))):
            sense_map = _mapping(sense)
            glosses = _unique_strings(_list(sense_map.get("glosses")), limit=8)
            translation_candidates = _list(record.get("translations_zh"))
            if not glosses and not translation_candidates:
                continue
            item: dict[str, object] = {
                "source_id": KAIKKI_SOURCE_ID,
                "kind": "source_candidate",
                "sense_id": f"{record_index}:{sense_index}",
                "part_of_speech": pos,
                "english_glosses": glosses,
                "chinese_translation_candidates": translation_candidates,
                "usage_tags": _unique_strings(_list(sense_map.get("tags"))),
                "source_examples": _unique_strings(_list(sense_map.get("examples")), limit=8),
                "synonyms": _unique_strings(_list(sense_map.get("synonyms"))),
                "antonyms": _unique_strings(_list(sense_map.get("antonyms"))),
            }
            qualifier = sense_map.get("qualifier")
            if isinstance(qualifier, str) and qualifier.strip():
                item["qualifier"] = qualifier.strip()
            result.append(item)
    return result


def _build_english_examples(entry: Mapping[str, object], kaikki_records: list[Mapping[str, object]]) -> list[dict[str, object]]:
    result: list[dict[str, object]] = []
    seen: set[tuple[str, str]] = set()
    wordnet = _mapping(entry.get("wordnet"))
    for sense in _list(wordnet.get("senses")):
        sense_map = _mapping(sense)
        sense_id = str(sense_map.get("synset_offset", ""))
        for index, text in enumerate(_unique_strings(_list(sense_map.get("examples")), limit=8)):
            key = (WORDNET_SOURCE_ID, text)
            if key not in seen:
                seen.add(key)
                result.append(
                    {
                        "example_id": f"wordnet:{sense_id}:{index}",
                        "source_id": WORDNET_SOURCE_ID,
                        "text": text,
                        "sense_id": sense_id,
                    }
                )
    for record_index, record in enumerate(kaikki_records):
        pos = str(record.get("pos", "")).strip()
        for sense_index, sense in enumerate(_list(record.get("senses"))):
            sense_map = _mapping(sense)
            for index, text in enumerate(_unique_strings(_list(sense_map.get("examples")), limit=8)):
                key = (KAIKKI_SOURCE_ID, text)
                if key not in seen:
                    seen.add(key)
                    result.append(
                        {
                            "example_id": f"wiktionary:{record_index}:{sense_index}:{index}",
                            "source_id": KAIKKI_SOURCE_ID,
                            "text": text,
                            "part_of_speech": pos,
                        }
                    )
    return result


def _build_bilingual_examples(entry: Mapping[str, object]) -> list[dict[str, object]]:
    result: list[dict[str, object]] = []
    for item in _list(entry.get("tatoeba_examples")):
        example = _mapping(item)
        english_id = str(example.get("english_id", "")).strip()
        chinese_id = str(example.get("chinese_id", "")).strip()
        english_text = example.get("english_text")
        chinese_text = example.get("chinese_text")
        if not english_id or not chinese_id or not isinstance(english_text, str) or not isinstance(chinese_text, str):
            continue
        result.append(
            {
                "example_id": f"tatoeba:{english_id}:{chinese_id}",
                "source_id": TATOEBA_SOURCE_ID,
                "english_text": english_text,
                "chinese_text": chinese_text,
                "attribution": {
                    "english_username": str(example.get("english_username", "")),
                    "chinese_username": str(example.get("chinese_username", "")),
                    "english_date_modified": str(example.get("english_date_modified", "")),
                    "chinese_date_modified": str(example.get("chinese_date_modified", "")),
                },
                "review_status": "candidate",
            }
        )
    return result


def _build_collocation_candidates(entry: Mapping[str, object]) -> list[dict[str, object]]:
    return [
        {"text": text, "source_id": TATOEBA_SOURCE_ID, "review_status": "candidate"}
        for text in _unique_strings(_list(entry.get("collocation_candidates")), limit=32)
    ]


def _build_relation_candidates(entry: Mapping[str, object], kaikki_records: list[Mapping[str, object]]) -> list[dict[str, str]]:
    result: list[dict[str, str]] = []
    seen: set[tuple[str, str, str]] = set()

    def add(relation: object, term: object, source_id: str) -> None:
        relation_text = str(relation).strip()
        term_text = str(term).strip()
        if not relation_text or not term_text:
            return
        key = (relation_text, term_text, source_id)
        if key not in seen:
            seen.add(key)
            result.append({"relation": relation_text, "term": term_text, "source_id": source_id})

    for relation, values in _mapping(entry.get("relations")).items():
        for value in _list(values):
            add(relation, value, WORDNET_SOURCE_ID)
    for record in kaikki_records:
        for relation, values in _mapping(record.get("relations")).items():
            for value in _list(values):
                add(relation, value, KAIKKI_SOURCE_ID)
    return result


def build_rich_candidate(entry: Mapping[str, object]) -> dict[str, object]:
    lemma = _normalize(entry.get("lemma", ""))
    kaikki = _mapping(entry.get("kaikki"))
    kaikki_records = [
        _mapping(record)
        for record in _list(kaikki.get("records"))
        if isinstance(record, Mapping)
    ]
    pronunciation = _build_pronunciation(entry, kaikki_records, kaikki)
    pos_candidates = _build_pos_candidates(entry, kaikki_records)
    sense_candidates = _build_sense_candidates(entry, kaikki_records)
    english_examples = _build_english_examples(entry, kaikki_records)
    bilingual_examples = _build_bilingual_examples(entry)
    collocations = _build_collocation_candidates(entry)
    relations = _build_relation_candidates(entry, kaikki_records)
    variants = _build_variants(entry, kaikki_records)

    review_fields: list[str] = []
    has_direct_pronunciation = any(
        not item.get("source_word") for item in pronunciation
    )
    has_alias_pronunciation = any(
        bool(item.get("source_word")) for item in pronunciation
    )
    if not has_direct_pronunciation:
        review_fields.append("ipa")
    if has_alias_pronunciation:
        review_fields.append("pronunciation_alias_review")
    if not pos_candidates:
        review_fields.append("part_of_speech")
    if not sense_candidates:
        review_fields.extend(["english_senses", "chinese_senses"])
    if not english_examples:
        review_fields.append("english_examples")
    if not bilingual_examples:
        review_fields.append("bilingual_examples")
    if not variants:
        review_fields.append("variants")
    # Candidates and source glosses are never equivalent to approved editorial
    # collocations, usage/register notes, or a human bilingual review.
    review_fields.extend(["collocations", "usage_register", "sense_alignment", "human_review"])
    if kaikki.get("status") == "ok":
        review_fields.append("license_review")
    if kaikki.get("match_type") == "alias":
        review_fields.append("spelling_alias_review")

    source_ids: list[str] = []
    for source_id in _list(entry.get("source_ids")):
        if isinstance(source_id, str):
            _append_source(source_ids, source_id)
    if kaikki.get("status") == "ok":
        _append_source(source_ids, KAIKKI_SOURCE_ID)

    return {
        "schema_version": RICH_SCHEMA_VERSION,
        "entry_id": str(entry.get("entry_id", f"yixue-editorial.en-zh.{lemma}")),
        "language_pair": str(entry.get("language_pair", "en-zh")),
        "lemma": lemma,
        "coverage_bands": _unique_strings(_list(entry.get("base", {}).get("coverage_bands", [])))
        if isinstance(entry.get("base"), Mapping)
        else [],
        "learning_tags": _unique_strings(_list(entry.get("learning_tags"))),
        "frequency": dict(_mapping(entry.get("frequency"))),
        "variants": variants,
        "pronunciation_candidates": pronunciation,
        "part_of_speech_candidates": pos_candidates,
        "sense_candidates": sense_candidates,
        "english_examples": english_examples,
        "bilingual_examples": bilingual_examples,
        "collocation_candidates": collocations,
        "relation_candidates": relations,
        "source_ids": source_ids,
        "quality": {
            "status": "draft",
            "review_fields": review_fields,
            "notes": "多来源机器/开放数据候选；逐义项、语用、双语例句和许可复核前不得发布。",
        },
    }


def merge_rich_layer(payload: Mapping[str, object]) -> dict[str, object]:
    merged = copy.deepcopy(dict(payload))
    raw_entries = merged.get("entries", [])
    if not isinstance(raw_entries, list):
        raise ValueError("candidate payload entries must be a list")
    entries: list[dict[str, object]] = []
    for raw_entry in raw_entries:
        if not isinstance(raw_entry, Mapping):
            continue
        entry = dict(raw_entry)
        entry["rich_candidate"] = build_rich_candidate(entry)
        entries.append(entry)
    merged["entries"] = entries
    source = dict(merged.get("source", {})) if isinstance(merged.get("source"), Mapping) else {}
    source["rich_candidate"] = {
        "source_id": "yixue-rich-candidate-v1",
        "role": "跨来源编辑候选视图，不是新的授权或公开发布包",
    }
    merged["source"] = source
    return merged


def build_rich_report(entries: Iterable[Mapping[str, object]]) -> dict[str, object]:
    rows = tuple(entries)
    rich_rows = [row.get("rich_candidate", {}) for row in rows]
    review_fields = Counter(
        field
        for rich in rich_rows
        if isinstance(rich, Mapping)
        for field in _list(_mapping(rich.get("quality")).get("review_fields"))
    )

    def count(field: str) -> int:
        return sum(bool(_mapping(rich).get(field)) for rich in rich_rows)

    draft_entries = sum(
        _mapping(_mapping(rich).get("quality")).get("status") == "draft"
        for rich in rich_rows
    )
    publishable_entries = sum(
        _mapping(_mapping(rich).get("quality")).get("status") == "published"
        and not _mapping(rich).get("quality", {}).get("review_fields", [])
        for rich in rich_rows
    )
    return {
        "schema_version": RICH_SCHEMA_VERSION,
        "total_entries": len(rows),
        "entries_with_rich_candidates": sum(bool(_mapping(rich).get("lemma")) for rich in rich_rows),
        "entries_with_pronunciation_candidates": count("pronunciation_candidates"),
        "entries_with_direct_pronunciation_candidates": sum(
            any(
                isinstance(item, Mapping) and not item.get("source_word")
                for item in _list(_mapping(rich).get("pronunciation_candidates"))
            )
            for rich in rich_rows
        ),
        "entries_with_alias_pronunciation_candidates": sum(
            any(
                isinstance(item, Mapping) and bool(item.get("source_word"))
                for item in _list(_mapping(rich).get("pronunciation_candidates"))
            )
            for rich in rich_rows
        ),
        "entries_with_part_of_speech_candidates": count("part_of_speech_candidates"),
        "entries_with_sense_candidates": count("sense_candidates"),
        "entries_with_english_examples": count("english_examples"),
        "entries_with_bilingual_examples": count("bilingual_examples"),
        "entries_with_collocation_candidates": count("collocation_candidates"),
        "entries_with_relation_candidates": count("relation_candidates"),
        "entries_with_variants": count("variants"),
        "draft_entries": draft_entries,
        "publishable_entries": publishable_entries,
        "review_field_counts": dict(sorted(review_fields.items())),
        "passed": False,
        "rule": "富语义候选必须逐义项人工复核、确认许可证和补齐正式搭配后才能转为 published。",
    }


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=pathlib.Path, default=pathlib.Path("data/dictionary/editorial-candidates-v2.json"))
    parser.add_argument("--output", type=pathlib.Path, default=pathlib.Path("data/dictionary/editorial-candidates-v3.json"))
    parser.add_argument("--report-output", type=pathlib.Path, default=pathlib.Path("data/dictionary/editorial-candidates-v3.report.json"))
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    payload = json.loads(args.input.resolve().read_text(encoding="utf-8"))
    if not isinstance(payload, Mapping) or not isinstance(payload.get("entries"), list):
        raise ValueError("input candidate JSON must contain an entries list")
    merged = merge_rich_layer(payload)
    report = build_rich_report(merged["entries"])
    merged_report = dict(merged.get("report", {})) if isinstance(merged.get("report"), Mapping) else {}
    merged_report["rich_candidate_layer"] = report
    merged["report"] = merged_report
    args.output.resolve().parent.mkdir(parents=True, exist_ok=True)
    args.report_output.resolve().parent.mkdir(parents=True, exist_ok=True)
    args.output.resolve().write_text(json.dumps(merged, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    args.report_output.resolve().write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, sort_keys=True))
    print(f"candidates={args.output.resolve()}")
    print(f"report={args.report_output.resolve()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
