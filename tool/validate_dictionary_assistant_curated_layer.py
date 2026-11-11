"""Validate the source-grounded assistant-curated dictionary JSONL layer.

This validator intentionally checks a structural/editorial-draft contract only.
It must never promote an assistant-curated entry to reviewed or published.
The formal release gate remains validate_dictionary_reviewed_layer.py.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
from collections import Counter
from collections.abc import Mapping
from typing import Any


LAYER = "yixue-assistant-curated-draft-v1"
SCHEMA_VERSION = 1
REQUIRED_FIELDS = {
    "schema_version",
    "layer",
    "entry_id",
    "language_pair",
    "lemma",
    "coverage_bands",
    "learning_tags",
    "part_of_speech",
    "part_of_speech_candidates",
    "ipa",
    "pronunciation_candidates",
    "senses",
    "english_examples",
    "bilingual_examples",
    "collocations",
    "collocation_candidates",
    "variants",
    "variant_candidates",
    "relations",
    "source_ids",
    "source_evidence",
    "candidate_metrics",
    "review_flags",
    "quality",
    "candidate_ref",
}
REQUIRED_REVIEW_FLAGS = {"human_review", "license_review", "sense_alignment", "usage_register"}
REQUIRED_SENSE_FIELDS = {
    "source_id",
    "part_of_speech",
    "english_glosses",
    "chinese_glosses",
    "usage_tags",
    "source_examples",
}
REQUIRED_EVIDENCE_FIELDS = {
    "pronunciation",
    "part_of_speech",
    "senses",
    "english_examples",
    "bilingual_examples",
    "collocations",
    "relations",
    "variants",
}
QUALITY_CHECKS = {
    "source",
    "license",
    "pronunciation",
    "meaning",
    "usage",
    "examples",
    "relations",
}
_CONTROL_RE = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f]")


def _text(value: Any) -> str:
    return value.strip() if isinstance(value, str) else ""


def _list(value: Any) -> list[Any]:
    return value if isinstance(value, list) else []


def _mapping(value: Any) -> Mapping[str, Any] | None:
    return value if isinstance(value, Mapping) else None


def _contains_bad_text(value: Any) -> bool:
    if isinstance(value, str):
        return "\ufffd" in value or _CONTROL_RE.search(value) is not None
    if isinstance(value, Mapping):
        return any(_contains_bad_text(key) or _contains_bad_text(item) for key, item in value.items())
    if isinstance(value, list):
        return any(_contains_bad_text(item) for item in value)
    return False


def _source_ids_from_manifest(path: pathlib.Path) -> set[str]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    records = payload.get("source_records") if isinstance(payload, Mapping) else None
    if not isinstance(records, list):
        raise ValueError("source manifest missing source_records list")
    result = {
        _text(record.get("id"))
        for record in records
        if isinstance(record, Mapping) and _text(record.get("id"))
    }
    if not result:
        raise ValueError("source manifest has no source IDs")
    return result


def _require_string_list(value: Any, field: str, line_number: int) -> None:
    values = _list(value)
    if any(not _text(item) for item in values):
        raise ValueError(f"line {line_number}: {field} must contain non-empty strings")


def _check_source_id(value: Any, field: str, line_number: int, known_sources: set[str]) -> None:
    source_id = _text(value)
    if not source_id:
        raise ValueError(f"line {line_number}: {field} missing source_id")
    if source_id not in known_sources:
        raise ValueError(f"line {line_number}: unknown source_id {source_id}")


def _validate_entry(entry: Mapping[str, Any], line_number: int, known_sources: set[str]) -> None:
    missing = REQUIRED_FIELDS.difference(entry)
    if missing:
        raise ValueError(f"line {line_number}: missing fields {sorted(missing)}")
    if entry.get("schema_version") != SCHEMA_VERSION:
        raise ValueError(f"line {line_number}: schema_version")
    if entry.get("layer") != LAYER:
        raise ValueError(f"line {line_number}: layer")
    for field in ("entry_id", "lemma", "language_pair", "part_of_speech"):
        if not _text(entry.get(field)):
            raise ValueError(f"line {line_number}: {field} must be non-empty")
    if entry.get("language_pair") != "en-zh":
        raise ValueError(f"line {line_number}: unsupported language_pair")
    if _contains_bad_text(entry):
        raise ValueError(f"line {line_number}: replacement character or control character")

    for field in ("coverage_bands", "learning_tags", "source_ids", "review_flags"):
        _require_string_list(entry.get(field), field, line_number)
    source_ids = set(_list(entry.get("source_ids")))
    if not source_ids:
        raise ValueError(f"line {line_number}: source_ids must not be empty")
    for source_id in source_ids:
        _check_source_id(source_id, "source_ids", line_number, known_sources)

    pos_candidates = _list(entry.get("part_of_speech_candidates"))
    if not pos_candidates:
        raise ValueError(f"line {line_number}: part_of_speech_candidates must not be empty")
    for item in pos_candidates:
        if not isinstance(item, Mapping) or not _text(item.get("value")):
            raise ValueError(f"line {line_number}: invalid part_of_speech_candidates")
        _check_source_id(item.get("source_id"), "part_of_speech_candidates", line_number, known_sources)

    ipa = _mapping(entry.get("ipa"))
    if not ipa:
        raise ValueError(f"line {line_number}: ipa must contain an explicit candidate")
    if any(not _text(key) or not _text(value) for key, value in ipa.items()):
        raise ValueError(f"line {line_number}: ipa contains empty value")
    for item in _list(entry.get("pronunciation_candidates")):
        if not isinstance(item, Mapping) or not _text(item.get("value")):
            raise ValueError(f"line {line_number}: invalid pronunciation_candidates")
        _check_source_id(item.get("source_id"), "pronunciation_candidates", line_number, known_sources)

    senses = _list(entry.get("senses"))
    if not senses:
        raise ValueError(f"line {line_number}: senses must not be empty")
    sense_ids: set[str] = set()
    for sense in senses:
        if not isinstance(sense, Mapping):
            raise ValueError(f"line {line_number}: invalid sense")
        missing_sense = REQUIRED_SENSE_FIELDS.difference(sense)
        if missing_sense:
            raise ValueError(f"line {line_number}: sense missing fields {sorted(missing_sense)}")
        sense_id = _text(sense.get("sense_id")) or _text(sense.get("id"))
        if not sense_id or sense_id in sense_ids:
            raise ValueError(f"line {line_number}: duplicate or empty sense_id")
        sense_ids.add(sense_id)
        _check_source_id(sense.get("source_id"), "sense", line_number, known_sources)
        for field in ("english_glosses", "chinese_glosses", "usage_tags", "source_examples"):
            _require_string_list(sense.get(field), f"sense.{field}", line_number)

    for item in _list(entry.get("english_examples")):
        if not isinstance(item, Mapping) or not _text(item.get("text")):
            raise ValueError(f"line {line_number}: invalid english_examples")
        _check_source_id(item.get("source_id"), "english_examples", line_number, known_sources)
    for item in _list(entry.get("bilingual_examples")):
        if not isinstance(item, Mapping):
            raise ValueError(f"line {line_number}: invalid bilingual_examples")
        for field in ("example_id", "source_id", "translation"):
            if not _text(item.get(field)):
                raise ValueError(f"line {line_number}: bilingual example missing {field}")
        if not (_text(item.get("text")) or _text(item.get("english_text"))):
            raise ValueError(f"line {line_number}: bilingual example missing english text")
        _check_source_id(item.get("source_id"), "bilingual_examples", line_number, known_sources)

    for field in ("collocations", "variants"):
        _require_string_list(entry.get(field), field, line_number)
    for item in _list(entry.get("collocation_candidates")):
        if not isinstance(item, Mapping) or not _text(item.get("text")):
            raise ValueError(f"line {line_number}: invalid collocation_candidates")
        _check_source_id(item.get("source_id"), "collocation_candidates", line_number, known_sources)
    for item in _list(entry.get("variant_candidates")):
        if not isinstance(item, Mapping) or not _text(item.get("form")):
            raise ValueError(f"line {line_number}: invalid variant_candidates")
        for source_id in _list(item.get("source_ids")):
            _check_source_id(source_id, "variant_candidates", line_number, known_sources)

    relations = _mapping(entry.get("relations"))
    if relations is None or any(not _text(key) or not isinstance(value, list) for key, value in relations.items()):
        raise ValueError(f"line {line_number}: invalid relations")
    evidence = _mapping(entry.get("source_evidence"))
    if evidence is None or REQUIRED_EVIDENCE_FIELDS.difference(evidence):
        raise ValueError(f"line {line_number}: incomplete source_evidence")
    for field in REQUIRED_EVIDENCE_FIELDS:
        _require_string_list(evidence.get(field), f"source_evidence.{field}", line_number)
        for source_id in _list(evidence.get(field)):
            _check_source_id(source_id, f"source_evidence.{field}", line_number, known_sources)

    if not isinstance(entry.get("candidate_metrics"), Mapping):
        raise ValueError(f"line {line_number}: candidate_metrics")
    for flag in REQUIRED_REVIEW_FLAGS:
        if flag not in _list(entry.get("review_flags")):
            raise ValueError(f"line {line_number}: missing review flag {flag}")

    quality = _mapping(entry.get("quality"))
    if quality is None or quality.get("status") != "assistant_curated_draft":
        raise ValueError(f"line {line_number}: quality status must remain assistant_curated_draft")
    if quality.get("human_review") is not False:
        raise ValueError(f"line {line_number}: human_review must remain false")
    checks = _mapping(quality.get("checks"))
    if checks is None or set(checks) != QUALITY_CHECKS or any(value is not False for value in checks.values()):
        raise ValueError(f"line {line_number}: quality checks must remain false")
    if not _text(quality.get("reviewer")) or not _text(quality.get("review_method")):
        raise ValueError(f"line {line_number}: missing curation provenance")

    reference = _mapping(entry.get("candidate_ref"))
    if reference is None or not _text(reference.get("path")) or not isinstance(reference.get("entry_index"), int):
        raise ValueError(f"line {line_number}: invalid candidate_ref")
    if reference.get("entry_id") != entry.get("entry_id"):
        raise ValueError(f"line {line_number}: candidate_ref entry_id mismatch")


def validate_assistant_curated_layer(
    layer_path: pathlib.Path,
    source_records_path: pathlib.Path,
    *,
    expected_entries: int | None = None,
) -> dict[str, Any]:
    known_sources = _source_ids_from_manifest(source_records_path)
    total = 0
    ids: set[str] = set()
    lemmas: set[str] = set()
    status_counts: Counter[str] = Counter()
    review_flags: Counter[str] = Counter()
    source_counts: Counter[str] = Counter()
    with layer_path.open("r", encoding="utf-8") as stream:
        for line_number, line in enumerate(stream, start=1):
            if not line.strip():
                raise ValueError(f"line {line_number}: blank line")
            try:
                entry = json.loads(line)
            except json.JSONDecodeError as exc:
                raise ValueError(f"line {line_number}: invalid JSON: {exc.msg}") from exc
            if not isinstance(entry, Mapping):
                raise ValueError(f"line {line_number}: entry must be an object")
            _validate_entry(entry, line_number, known_sources)
            entry_id = _text(entry.get("entry_id"))
            lemma_key = " ".join(_text(entry.get("lemma")).casefold().split())
            if entry_id in ids:
                raise ValueError(f"line {line_number}: duplicate entry_id {entry_id}")
            if lemma_key in lemmas:
                raise ValueError(f"line {line_number}: duplicate lemma {lemma_key}")
            ids.add(entry_id)
            lemmas.add(lemma_key)
            total += 1
            quality = _mapping(entry.get("quality")) or {}
            status_counts[_text(quality.get("status"))] += 1
            review_flags.update(_list(entry.get("review_flags")))
            source_counts.update(_list(entry.get("source_ids")))

    if expected_entries is not None and total != expected_entries:
        raise ValueError(f"entry count {total} != expected {expected_entries}")
    return {
        "schema_version": SCHEMA_VERSION,
        "layer": LAYER,
        "path": layer_path.as_posix(),
        "source_records": source_records_path.as_posix(),
        "total_entries": total,
        "unique_entry_ids": len(ids),
        "unique_lemmas": len(lemmas),
        "human_reviewed_entries": 0,
        "published_entries": 0,
        "status_counts": dict(sorted(status_counts.items())),
        "review_flag_counts": dict(sorted(review_flags.items())),
        "source_id_counts": dict(sorted(source_counts.items())),
        "known_source_ids": sorted(known_sources),
        "structurally_valid": True,
        "passed": True,
        "release_ready": False,
        "rule": "此层仅表示来源归并与 AI 编辑初审；必须通过独立人工审校闸门后才能 reviewed/published。",
    }


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=pathlib.Path, required=True)
    parser.add_argument("--source-records", type=pathlib.Path, required=True)
    parser.add_argument("--expected-entries", type=int)
    parser.add_argument("--report-output", type=pathlib.Path)
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    try:
        report = validate_assistant_curated_layer(
            args.input,
            args.source_records,
            expected_entries=args.expected_entries,
        )
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"ASSISTANT_CURATED_VALIDATION_FAIL: {exc}")
        return 1
    if args.report_output:
        args.report_output.parent.mkdir(parents=True, exist_ok=True)
        args.report_output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print("ASSISTANT_CURATED_VALIDATION_PASS")
    print(json.dumps(report, ensure_ascii=True, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
