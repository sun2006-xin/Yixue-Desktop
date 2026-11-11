#!/usr/bin/env python3
"""Validate the human-reviewed dictionary layer before it can be published.

The candidate builders deliberately stop at ``draft``.  This validator is the
separate gate for a small, human-reviewed authoring layer.  It never promotes
candidate data and it does not copy text from a commercial dictionary.
"""

from __future__ import annotations

import argparse
import datetime as _datetime
import json
import pathlib
from collections import Counter
from collections.abc import Mapping, Sequence, Set
from typing import Any


REVIEWED_SCHEMA_VERSION = 1
REQUIRED_REVIEW_CHECKS = (
    "source",
    "license",
    "pronunciation",
    "meaning",
    "usage",
    "examples",
    "relations",
)
_EMPTY_OR_PLACEHOLDER = {
    "-",
    "—",
    "待补充",
    "待核对",
    "todo",
    "tbd",
    "n/a",
}


def _text(value: Any) -> str:
    return value.strip() if isinstance(value, str) else ""


def _usable_text(value: Any) -> bool:
    text = _text(value)
    return bool(text) and text.casefold() not in _EMPTY_OR_PLACEHOLDER and "�" not in text


def _as_mapping(value: Any) -> Mapping[str, Any] | None:
    return value if isinstance(value, Mapping) else None


def _as_list(value: Any) -> list[Any] | None:
    return list(value) if isinstance(value, list) else None


def _field_error(errors: list[str], field: str) -> None:
    if field not in errors:
        errors.append(field)


def _check_text_field(
    mapping: Mapping[str, Any],
    field: str,
    errors: list[str],
) -> None:
    if not _usable_text(mapping.get(field)):
        _field_error(errors, field)


def _validate_source_records(
    payload: Mapping[str, Any],
) -> tuple[dict[str, Mapping[str, Any]], list[str]]:
    errors: list[str] = []
    raw_sources = _as_list(payload.get("source_records"))
    if not raw_sources:
        return {}, ["source_records"]

    sources: dict[str, Mapping[str, Any]] = {}
    for index, raw_source in enumerate(raw_sources):
        source = _as_mapping(raw_source)
        if source is None:
            errors.append(f"source_records[{index}]")
            continue
        source_errors: list[str] = []
        for field in ("id", "name", "version", "license", "attribution"):
            _check_text_field(source, field, source_errors)
        source_id = _text(source.get("id"))
        if source_id and source_id in sources:
            errors.append(f"duplicate_source:{source_id}")
        elif source_id:
            sources[source_id] = source
        if source_errors:
            errors.extend(f"source_records[{index}].{field}" for field in source_errors)
    return sources, errors


def _validate_ipa(value: Any, errors: list[str]) -> None:
    ipa = _as_mapping(value)
    if not ipa:
        _field_error(errors, "ipa")
        return
    for dialect, notation in ipa.items():
        if not _usable_text(dialect) or not _usable_text(notation):
            _field_error(errors, "ipa")
            break


def _validate_senses(
    value: Any,
    source_ids: set[str],
    errors: list[str],
) -> None:
    senses = _as_list(value)
    if not senses:
        _field_error(errors, "senses")
        return
    for sense in senses:
        sense_mapping = _as_mapping(sense)
        if sense_mapping is None:
            _field_error(errors, "senses")
            continue
        for field in ("id", "usage", "domain"):
            _check_text_field(sense_mapping, field, errors)
        meanings = _as_list(sense_mapping.get("meanings"))
        if not meanings or not all(_usable_text(item) for item in meanings):
            _field_error(errors, "senses.meanings")
        examples = _as_list(sense_mapping.get("examples"))
        if not examples:
            _field_error(errors, "sense.examples")
            continue
        for example in examples:
            example_mapping = _as_mapping(example)
            if example_mapping is None:
                _field_error(errors, "sense.examples")
                continue
            for field in ("text", "translation"):
                if not _usable_text(example_mapping.get(field)):
                    _field_error(errors, "sense.examples")
            example_source = _text(example_mapping.get("source_id"))
            if not example_source or example_source not in source_ids:
                _field_error(errors, "sense.examples.source_id")


def _validate_string_list(
    mapping: Mapping[str, Any],
    field: str,
    errors: list[str],
    *,
    required: bool,
) -> None:
    values = _as_list(mapping.get(field))
    if values is None or (required and not values):
        _field_error(errors, field)
        return
    if not all(_usable_text(value) for value in values):
        _field_error(errors, field)


def _validate_relations(value: Any, errors: list[str]) -> None:
    relations = _as_mapping(value)
    if relations is None:
        _field_error(errors, "relations")
        return
    for relation, values in relations.items():
        if not _usable_text(relation):
            _field_error(errors, "relations")
            continue
        values_list = _as_list(values)
        if values_list is None or not all(_usable_text(item) for item in values_list):
            _field_error(errors, f"relations.{relation}")


def _validate_quality(value: Any, errors: list[str]) -> str:
    quality = _as_mapping(value)
    if quality is None:
        _field_error(errors, "quality")
        return ""
    status = _text(quality.get("status"))
    if status not in {"reviewed", "published"}:
        _field_error(errors, "quality.status")
    _check_text_field(quality, "reviewer", errors)
    reviewed_at = _text(quality.get("reviewed_at"))
    try:
        _datetime.date.fromisoformat(reviewed_at)
    except (TypeError, ValueError):
        _field_error(errors, "quality.reviewed_at")
    if quality.get("human_review") is not True:
        _field_error(errors, "quality.human_review")
    checks = _as_mapping(quality.get("checks"))
    if checks is None or any(checks.get(field) is not True for field in REQUIRED_REVIEW_CHECKS):
        _field_error(errors, "quality.checks")
    return status


def _validate_entry(
    entry: Mapping[str, Any],
    source_ids: set[str],
) -> tuple[list[str], str]:
    errors: list[str] = []
    for field in ("entry_id", "language_pair", "lemma", "part_of_speech"):
        _check_text_field(entry, field, errors)
    _validate_ipa(entry.get("ipa"), errors)
    _validate_senses(entry.get("senses"), source_ids, errors)
    _validate_string_list(entry, "variants", errors, required=False)
    _validate_string_list(entry, "collocations", errors, required=True)
    _validate_string_list(entry, "learning_tags", errors, required=True)
    _validate_string_list(entry, "coverage_bands", errors, required=True)
    _validate_relations(entry.get("relations"), errors)

    entry_source_ids = _as_list(entry.get("source_ids"))
    if not entry_source_ids or not all(
        _usable_text(source_id) and source_id in source_ids
        for source_id in entry_source_ids
    ):
        _field_error(errors, "source_ids")

    if "�" in json.dumps(entry, ensure_ascii=False):
        _field_error(errors, "replacement_character")
    status = _validate_quality(entry.get("quality"), errors)
    return errors, status


def validate_layer(
    payload: Mapping[str, Any],
    *,
    expected_lemmas: Set[str] | None = None,
    require_all: bool = False,
) -> dict[str, Any]:
    """Return a deterministic validation report for a reviewed layer.

    ``expected_lemmas`` can be supplied from the 5,759-word candidate layer.
    A partial reviewed batch is allowed by default; ``require_all`` turns the
    same check into the final full-coverage gate.
    """

    global_errors: list[str] = []
    if not isinstance(payload, Mapping):
        return {
            "schema_version": REVIEWED_SCHEMA_VERSION,
            "total_entries": 0,
            "reviewed_entries": 0,
            "published_entries": 0,
            "invalid_entries": [],
            "global_errors": ["payload"],
            "passed": False,
        }
    if payload.get("schema_version") != REVIEWED_SCHEMA_VERSION:
        global_errors.append("schema_version")
    if not _usable_text(payload.get("layer")):
        global_errors.append("layer")
    language_pair = _text(payload.get("language_pair"))
    if not language_pair:
        global_errors.append("language_pair")

    source_map, source_errors = _validate_source_records(payload)
    global_errors.extend(source_errors)
    raw_entries = _as_list(payload.get("entries"))
    if raw_entries is None:
        raw_entries = []
        global_errors.append("entries")
    if not raw_entries:
        global_errors.append("entries_empty")

    invalid_entries: list[dict[str, Any]] = []
    seen_ids: Counter[str] = Counter()
    seen_lemmas: Counter[str] = Counter()
    reviewed_entries = 0
    published_entries = 0
    actual_lemmas: set[str] = set()
    for index, raw_entry in enumerate(raw_entries):
        entry = _as_mapping(raw_entry)
        if entry is None:
            invalid_entries.append({"index": index, "fields": ["entry"]})
            continue
        lemma = _text(entry.get("lemma")).casefold()
        entry_id = _text(entry.get("entry_id"))
        if lemma:
            actual_lemmas.add(lemma)
            seen_lemmas[lemma] += 1
        if entry_id:
            seen_ids[entry_id] += 1
        fields, status = _validate_entry(entry, set(source_map))
        if language_pair and _text(entry.get("language_pair")) != language_pair:
            _field_error(fields, "language_pair")
        if fields:
            invalid_entries.append(
                {
                    "index": index,
                    "entry_id": entry_id,
                    "lemma": _text(entry.get("lemma")),
                    "fields": sorted(fields),
                }
            )
        if status in {"reviewed", "published"}:
            reviewed_entries += 1
        if status == "published":
            published_entries += 1

    for entry_id, count in sorted(seen_ids.items()):
        if count > 1:
            global_errors.append(f"duplicate_entry_id:{entry_id}")
    for lemma, count in sorted(seen_lemmas.items()):
        if count > 1:
            global_errors.append(f"duplicate_lemma:{lemma}")

    expected: set[str] | None = None
    if expected_lemmas is not None:
        expected = {str(lemma).strip().casefold() for lemma in expected_lemmas if str(lemma).strip()}
        for lemma in sorted(expected - actual_lemmas):
            if require_all:
                global_errors.append(f"missing_expected_lemma:{lemma}")
        for lemma in sorted(actual_lemmas - expected):
            global_errors.append(f"unexpected_lemma:{lemma}")

    global_errors = sorted(set(global_errors))
    return {
        "schema_version": REVIEWED_SCHEMA_VERSION,
        "layer": _text(payload.get("layer")),
        "language_pair": language_pair,
        "total_entries": len(raw_entries),
        "reviewed_entries": reviewed_entries,
        "published_entries": published_entries,
        "expected_entries": len(expected) if expected is not None else None,
        "missing_expected_entries": len(expected - actual_lemmas) if expected is not None else None,
        "invalid_entries": invalid_entries,
        "global_errors": global_errors,
        "passed": not global_errors and not invalid_entries,
        "rule": "只有具备完整字段、合法来源、人工审校凭据且状态为 reviewed/published 的条目才能通过；候选 draft 不得自动提升。",
    }


def _load_json(path: pathlib.Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=pathlib.Path, required=True)
    parser.add_argument("--report-output", type=pathlib.Path, default=None)
    parser.add_argument(
        "--candidate-input",
        type=pathlib.Path,
        default=None,
        help="optional candidate JSON used as the allowed vocabulary scope",
    )
    parser.add_argument(
        "--require-all",
        action="store_true",
        help="require every candidate lemma to exist in the reviewed layer",
    )
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    payload = _load_json(args.input)
    expected = None
    if args.candidate_input is not None:
        candidate = _load_json(args.candidate_input)
        candidate_entries = candidate.get("entries", []) if isinstance(candidate, Mapping) else []
        expected = {
            _text(item.get("lemma"))
            for item in candidate_entries
            if isinstance(item, Mapping) and _usable_text(item.get("lemma"))
        }
    report = validate_layer(payload, expected_lemmas=expected, require_all=args.require_all)
    if args.report_output is not None:
        args.report_output.parent.mkdir(parents=True, exist_ok=True)
        args.report_output.write_text(
            json.dumps(report, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
    print("REVIEWED_LAYER_VALIDATION_PASS" if report["passed"] else "REVIEWED_LAYER_VALIDATION_FAIL")
    # Keep stdout ASCII-safe on Windows terminals whose active code page may
    # not represent IPA or Chinese; the optional report file remains UTF-8.
    print(json.dumps(report, ensure_ascii=True, sort_keys=True))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
