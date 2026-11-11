#!/usr/bin/env python3
"""Merge independently validated dictionary review batches.

Each input must already be a valid partial reviewed layer.  The merger keeps
source records explicit, rejects conflicting provenance and duplicate lemmas,
and can enforce the full candidate vocabulary with ``require_all``.
"""

from __future__ import annotations

import argparse
import copy
import importlib.util
import json
import pathlib
from collections import Counter
from collections.abc import Mapping, Sequence, Set
from typing import Any


MERGE_SCHEMA_VERSION = 1


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


class ReviewMergeError(ValueError):
    """Raised when reviewed layers cannot be merged safely."""

    def __init__(self, report: Mapping[str, Any]):
        self.report = dict(report)
        super().__init__("reviewed layer merge refused")


def _base_report(
    *,
    layer_count: int,
    total_input_entries: int,
    merged_entries: int,
    layer_reports: list[Mapping[str, Any]],
    global_errors: list[str],
    validation: Mapping[str, Any] | None,
    passed: bool,
) -> dict[str, Any]:
    return {
        "schema_version": MERGE_SCHEMA_VERSION,
        "layer_count": layer_count,
        "total_input_entries": total_input_entries,
        "merged_entries": merged_entries,
        "layer_reports": [dict(report) for report in layer_reports],
        "global_errors": sorted(set(global_errors)),
        "validation": dict(validation) if validation is not None else None,
        "passed": passed,
        "rule": "每个输入层必须先通过 reviewed 验收；合并时拒绝冲突来源、重复词形和缺失的全量目标词。",
    }


def merge_reviewed_layers(
    layers: Sequence[Mapping[str, Any]],
    *,
    expected_lemmas: Set[str] | None = None,
    require_all: bool = False,
) -> tuple[dict[str, Any], dict[str, Any]]:
    """Merge valid partial layers and return ``(payload, report)``."""

    if not layers:
        report = _base_report(
            layer_count=0,
            total_input_entries=0,
            merged_entries=0,
            layer_reports=[],
            global_errors=["inputs"],
            validation=None,
            passed=False,
        )
        raise ReviewMergeError(report)

    layer_reports: list[Mapping[str, Any]] = []
    global_errors: list[str] = []
    all_entries: list[dict[str, Any]] = []
    source_map: dict[str, Mapping[str, Any]] = {}
    layer_name = ""
    language_pair = ""
    total_input_entries = 0

    for index, layer in enumerate(layers):
        if not isinstance(layer, Mapping):
            layer_reports.append({"index": index, "passed": False, "global_errors": ["payload"]})
            global_errors.append(f"layer[{index}].payload")
            continue

        raw_entries = _list(layer.get("entries")) or []
        total_input_entries += len(raw_entries)
        validation = _VALIDATOR.validate_layer(layer)
        layer_reports.append(
            {
                "index": index,
                "layer": _text(layer.get("layer")),
                "language_pair": _text(layer.get("language_pair")),
                "total_entries": len(raw_entries),
                "passed": bool(validation["passed"]),
                "invalid_entries": validation["invalid_entries"],
                "global_errors": validation["global_errors"],
            }
        )
        if not validation["passed"]:
            global_errors.append(f"layer[{index}].validation")
            continue

        current_layer = _text(layer.get("layer"))
        current_pair = _text(layer.get("language_pair"))
        if not layer_name:
            layer_name = current_layer
        elif current_layer != layer_name:
            global_errors.append(f"layer_name_mismatch:{current_layer}")
        if not language_pair:
            language_pair = current_pair
        elif current_pair != language_pair:
            global_errors.append(f"language_pair_mismatch:{current_pair}")

        raw_sources = _list(layer.get("source_records")) or []
        for source in raw_sources:
            source_map_item = _mapping(source)
            if source_map_item is None:
                global_errors.append(f"source_records_invalid:layer[{index}]")
                continue
            source_id = _text(source_map_item.get("id"))
            if not source_id:
                global_errors.append(f"source_records_missing_id:layer[{index}]")
                continue
            existing = source_map.get(source_id)
            if existing is not None and dict(existing) != dict(source_map_item):
                global_errors.append(f"source_record_conflict:{source_id}")
            else:
                source_map[source_id] = copy.deepcopy(source_map_item)

        all_entries.extend(copy.deepcopy(dict(entry)) for entry in raw_entries if isinstance(entry, Mapping))

    if global_errors:
        report = _base_report(
            layer_count=len(layers),
            total_input_entries=total_input_entries,
            merged_entries=len(all_entries),
            layer_reports=layer_reports,
            global_errors=global_errors,
            validation=None,
            passed=False,
        )
        raise ReviewMergeError(report)

    entry_ids = Counter(_text(entry.get("entry_id")) for entry in all_entries)
    lemmas = Counter(_text(entry.get("lemma")).casefold() for entry in all_entries)
    duplicate_errors = [
        f"duplicate_entry_id:{entry_id}" for entry_id, count in entry_ids.items() if entry_id and count > 1
    ]
    duplicate_errors.extend(
        f"duplicate_lemma:{lemma}" for lemma, count in lemmas.items() if lemma and count > 1
    )
    all_entries.sort(key=lambda entry: (_text(entry.get("lemma")).casefold(), _text(entry.get("entry_id"))))
    payload = {
        "schema_version": 1,
        "layer": layer_name,
        "language_pair": language_pair,
        "source_records": [source_map[source_id] for source_id in sorted(source_map)],
        "entries": all_entries,
    }
    validation = _VALIDATOR.validate_layer(
        payload,
        expected_lemmas=expected_lemmas,
        require_all=require_all,
    )
    if duplicate_errors or not validation["passed"]:
        report = _base_report(
            layer_count=len(layers),
            total_input_entries=total_input_entries,
            merged_entries=len(all_entries),
            layer_reports=layer_reports,
            global_errors=duplicate_errors,
            validation=validation,
            passed=False,
        )
        raise ReviewMergeError(report)

    report = _base_report(
        layer_count=len(layers),
        total_input_entries=total_input_entries,
        merged_entries=len(all_entries),
        layer_reports=layer_reports,
        global_errors=[],
        validation=validation,
        passed=True,
    )
    return payload, report


def _load_json(path: pathlib.Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def _candidate_lemmas(path: pathlib.Path) -> set[str]:
    payload = _load_json(path)
    raw_entries = payload.get("entries") if isinstance(payload, Mapping) else payload
    if not isinstance(raw_entries, list):
        raise ValueError(f"{path} must contain entries")
    return {
        _text(entry.get("lemma")).casefold()
        for entry in raw_entries
        if isinstance(entry, Mapping) and _text(entry.get("lemma"))
    }


def _write_json(path: pathlib.Path, payload: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=pathlib.Path, action="append", required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--report-output", type=pathlib.Path, default=None)
    parser.add_argument("--candidate-input", type=pathlib.Path, default=None)
    parser.add_argument("--require-all", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    try:
        layers = [_load_json(path) for path in args.input]
        expected = _candidate_lemmas(args.candidate_input) if args.candidate_input else None
        payload, report = merge_reviewed_layers(
            layers,
            expected_lemmas=expected,
            require_all=args.require_all,
        )
    except (OSError, json.JSONDecodeError, ValueError, ReviewMergeError) as error:
        if isinstance(error, ReviewMergeError):
            report = error.report
        else:
            report = _base_report(
                layer_count=0,
                total_input_entries=0,
                merged_entries=0,
                layer_reports=[],
                global_errors=[f"input:{type(error).__name__}"],
                validation=None,
                passed=False,
            )
        if args.report_output is not None:
            _write_json(args.report_output, report)
        print("REVIEWED_LAYER_MERGE_REFUSED")
        print(json.dumps(report, ensure_ascii=True, sort_keys=True))
        return 1

    _write_json(args.output, payload)
    if args.report_output is not None:
        _write_json(args.report_output, report)
    print("REVIEWED_LAYER_MERGE_PASS")
    print(json.dumps(report, ensure_ascii=True, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
