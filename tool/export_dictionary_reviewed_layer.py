#!/usr/bin/env python3
"""Export a completed human-review workbench packet as a reviewed layer.

This exporter is deliberately conservative.  It never copies a candidate into
the reviewed layer automatically: every output entry must contain a separate,
human-authored ``reviewed_entry`` and a complete review record.  The resulting
payload is passed through the independent reviewed-layer validator before it is
written to disk.
"""

from __future__ import annotations

import argparse
import copy
import datetime as _datetime
import importlib.util
import json
import pathlib
from collections import Counter
from collections.abc import Mapping, Sequence
from typing import Any


EXPORT_SCHEMA_VERSION = 1
_REVIEW_CHECKS = (
    "source",
    "license",
    "pronunciation",
    "meaning",
    "usage",
    "examples",
    "relations",
)


def _load_validator_module():
    path = pathlib.Path(__file__).with_name("validate_dictionary_reviewed_layer.py")
    spec = importlib.util.spec_from_file_location("dictionary_reviewed_layer", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"unable to load validator: {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


_VALIDATOR = _load_validator_module()


def _text(value: Any) -> str:
    return value.strip() if isinstance(value, str) else ""


def _mapping(value: Any) -> Mapping[str, Any] | None:
    return value if isinstance(value, Mapping) else None


def _list(value: Any) -> list[Any] | None:
    return list(value) if isinstance(value, list) else None


def _usable_text(value: Any) -> bool:
    return bool(_text(value))


class ReviewExportError(ValueError):
    """Raised when a workbench packet cannot be safely exported."""

    def __init__(self, report: Mapping[str, Any]):
        self.report = dict(report)
        super().__init__("reviewed layer export refused")


def _review_errors(review: Mapping[str, Any]) -> list[str]:
    errors: list[str] = []
    status = _text(review.get("status"))
    if status not in {"reviewed", "published"}:
        errors.append("review.status")
    if not _usable_text(review.get("reviewer")):
        errors.append("review.reviewer")
    reviewed_at = _text(review.get("reviewed_at"))
    try:
        _datetime.date.fromisoformat(reviewed_at)
    except (TypeError, ValueError):
        errors.append("review.reviewed_at")
    if review.get("human_review") is not True:
        errors.append("review.human_review")
    checks = _mapping(review.get("checks"))
    if checks is None or any(checks.get(name) is not True for name in _REVIEW_CHECKS):
        errors.append("review.checks")
    if _mapping(review.get("reviewed_entry")) is None:
        errors.append("review.reviewed_entry")
    return sorted(set(errors))


def _quality_from_review(review: Mapping[str, Any]) -> dict[str, Any]:
    quality: dict[str, Any] = {
        "status": _text(review.get("status")),
        "reviewer": _text(review.get("reviewer")),
        "reviewed_at": _text(review.get("reviewed_at")),
        "human_review": review.get("human_review"),
        "checks": {
            name: bool(_mapping(review.get("checks")) and review["checks"].get(name))
            for name in _REVIEW_CHECKS
        },
    }
    notes = _text(review.get("notes"))
    if notes:
        quality["notes"] = notes
    return quality


def _report(
    *,
    batch_id: str,
    total: int,
    rejected: list[dict[str, Any]],
    global_errors: list[str],
    validation: Mapping[str, Any] | None,
    exported: int,
    passed: bool,
) -> dict[str, Any]:
    return {
        "schema_version": EXPORT_SCHEMA_VERSION,
        "batch_id": batch_id,
        "total_batch_entries": total,
        "exported_entries": exported,
        "rejected_entries": rejected,
        "global_errors": sorted(set(global_errors)),
        "validation": dict(validation) if validation is not None else None,
        "passed": passed,
        "rule": "只有独立人工填写的 reviewed_entry 和完整审校凭据可以进入 reviewed layer；candidate 不会自动晋级。",
    }


def _source_records(value: Any) -> list[Mapping[str, Any]]:
    if isinstance(value, Mapping):
        value = value.get("source_records")
    records = _list(value)
    if records is None or not all(isinstance(record, Mapping) for record in records):
        raise ValueError("source records must contain a list of mappings")
    return list(records)


def export_reviewed_layer(
    batch: Mapping[str, Any],
    source_records: Sequence[Mapping[str, Any]] | Mapping[str, Any],
) -> tuple[dict[str, Any], dict[str, Any]]:
    """Export one completed packet and return ``(payload, report)``.

    The packet may represent a partial batch.  Completeness across all 5,759
    candidate lemmas is enforced later by the validator's ``require_all`` gate.
    """

    batch_id = _text(batch.get("batch_id")) if isinstance(batch, Mapping) else ""
    raw_entries = _list(batch.get("entries")) if isinstance(batch, Mapping) else None
    if not isinstance(batch, Mapping):
        report = _report(
            batch_id="",
            total=0,
            rejected=[],
            global_errors=["batch"],
            validation=None,
            exported=0,
            passed=False,
        )
        raise ReviewExportError(report)
    if batch.get("schema_version") != EXPORT_SCHEMA_VERSION:
        report = _report(
            batch_id=batch_id,
            total=0,
            rejected=[],
            global_errors=["batch.schema_version"],
            validation=None,
            exported=0,
            passed=False,
        )
        raise ReviewExportError(report)
    if _text(batch.get("layer")) != "yixue-editorial-review-workbench":
        report = _report(
            batch_id=batch_id,
            total=0,
            rejected=[],
            global_errors=["batch.layer"],
            validation=None,
            exported=0,
            passed=False,
        )
        raise ReviewExportError(report)
    if raw_entries is None or not raw_entries or not all(
        isinstance(entry, Mapping) for entry in raw_entries
    ):
        report = _report(
            batch_id=batch_id,
            total=len(raw_entries or []),
            rejected=[],
            global_errors=["batch.entries"],
            validation=None,
            exported=0,
            passed=False,
        )
        raise ReviewExportError(report)

    try:
        normalized_sources = _source_records(source_records)
    except ValueError:
        report = _report(
            batch_id=batch_id,
            total=len(raw_entries),
            rejected=[],
            global_errors=["source_records"],
            validation=None,
            exported=0,
            passed=False,
        )
        raise ReviewExportError(report) from None

    output_entries: list[dict[str, Any]] = []
    rejected: list[dict[str, Any]] = []
    seen_ids: Counter[str] = Counter()
    seen_lemmas: Counter[str] = Counter()
    language_pair = ""
    for index, raw_entry in enumerate(raw_entries):
        entry = raw_entry
        packet_lemma = _text(entry.get("lemma"))
        packet_entry_id = _text(entry.get("entry_id"))
        packet_pair = _text(entry.get("language_pair"))
        if packet_pair and not language_pair:
            language_pair = packet_pair
        fields: list[str] = []
        review = _mapping(entry.get("review"))
        if review is None:
            fields.append("review")
        else:
            fields.extend(_review_errors(review))
        candidate = _mapping(entry.get("candidate"))
        candidate_quality = _mapping(candidate.get("quality")) if candidate else None
        candidate_status = _text(candidate_quality.get("status")) if candidate_quality else ""
        if candidate_status in {"reviewed", "published"}:
            fields.append("candidate.status_mutation")

        reviewed_entry = _mapping(review.get("reviewed_entry")) if review else None
        if reviewed_entry is not None:
            if not packet_lemma or _text(reviewed_entry.get("lemma")).casefold() != packet_lemma.casefold():
                fields.append("reviewed_entry.lemma")
            if not packet_entry_id or _text(reviewed_entry.get("entry_id")) != packet_entry_id:
                fields.append("reviewed_entry.entry_id")
            if packet_pair and _text(reviewed_entry.get("language_pair")) != packet_pair:
                fields.append("reviewed_entry.language_pair")

        if fields:
            rejected.append(
                {
                    "index": index,
                    "entry_id": packet_entry_id,
                    "lemma": packet_lemma,
                    "fields": sorted(set(fields)),
                }
            )
            continue

        output_entry = copy.deepcopy(dict(reviewed_entry))
        output_entry["quality"] = _quality_from_review(review)
        output_entries.append(output_entry)
        if packet_entry_id:
            seen_ids[packet_entry_id] += 1
        if packet_lemma:
            seen_lemmas[packet_lemma.casefold()] += 1

    global_errors: list[str] = []
    if not language_pair:
        global_errors.append("language_pair")
    if len(seen_ids) != len(output_entries):
        global_errors.extend(
            f"duplicate_entry_id:{entry_id}" for entry_id, count in seen_ids.items() if count > 1
        )
    if len(seen_lemmas) != len(output_entries):
        global_errors.extend(
            f"duplicate_lemma:{lemma}" for lemma, count in seen_lemmas.items() if count > 1
        )
    if rejected or global_errors:
        report = _report(
            batch_id=batch_id,
            total=len(raw_entries),
            rejected=rejected,
            global_errors=global_errors,
            validation=None,
            exported=0,
            passed=False,
        )
        raise ReviewExportError(report)

    payload = {
        "schema_version": EXPORT_SCHEMA_VERSION,
        "layer": "yixue-authored-reviewed-v1",
        "language_pair": language_pair,
        "source_records": copy.deepcopy(normalized_sources),
        "entries": output_entries,
    }
    validation = _VALIDATOR.validate_layer(
        payload,
        expected_lemmas={_text(entry.get("lemma")) for entry in raw_entries},
        require_all=True,
    )
    if not validation["passed"]:
        report = _report(
            batch_id=batch_id,
            total=len(raw_entries),
            rejected=[],
            global_errors=[],
            validation=validation,
            exported=0,
            passed=False,
        )
        raise ReviewExportError(report)

    report = _report(
        batch_id=batch_id,
        total=len(raw_entries),
        rejected=[],
        global_errors=[],
        validation=validation,
        exported=len(output_entries),
        passed=True,
    )
    return payload, report


def _load_json(path: pathlib.Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=pathlib.Path, required=True)
    parser.add_argument("--source-records", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--report-output", type=pathlib.Path, default=None)
    return parser.parse_args()


def _write_json(path: pathlib.Path, payload: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def main() -> int:
    args = _parse_args()
    try:
        payload, report = export_reviewed_layer(
            _load_json(args.input),
            _load_json(args.source_records),
        )
    except (OSError, json.JSONDecodeError, ReviewExportError, ValueError) as error:
        if isinstance(error, ReviewExportError):
            report = error.report
        else:
            report = _report(
                batch_id="",
                total=0,
                rejected=[],
                global_errors=[f"input:{type(error).__name__}"],
                validation=None,
                exported=0,
                passed=False,
            )
        if args.report_output is not None:
            _write_json(args.report_output, report)
        print("REVIEWED_LAYER_EXPORT_REFUSED")
        print(json.dumps(report, ensure_ascii=True, sort_keys=True))
        return 1

    _write_json(args.output, payload)
    if args.report_output is not None:
        _write_json(args.report_output, report)
    print("REVIEWED_LAYER_EXPORT_PASS")
    print(json.dumps(report, ensure_ascii=True, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
