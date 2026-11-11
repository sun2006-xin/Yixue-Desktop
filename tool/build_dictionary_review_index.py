#!/usr/bin/env python3
"""Build a small deterministic progress index for the dictionary review queue.

The index contains only batch metadata and lemmas.  It is not a dictionary
layer and never promotes candidate entries.  Optional reviewed inputs are
validated before their lemmas are counted as reviewed.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import pathlib
from collections import Counter
from collections.abc import Iterable, Mapping, Set
from math import ceil
from typing import Any


INDEX_SCHEMA_VERSION = 1
_TEXT_PRIORITY_SCORE = {"high": 100, "medium": 65, "low": 45, "normal": 0}


def _text(value: Any) -> str:
    return value.strip() if isinstance(value, str) else ""


def _mapping(value: Any) -> Mapping[str, Any] | None:
    return value if isinstance(value, Mapping) else None


def _normalize_lemma(value: Any) -> str:
    return " ".join(_text(value).casefold().split())


def _priority_score(value: Any) -> int:
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return int(value)
    text = _text(value).casefold()
    if text in _TEXT_PRIORITY_SCORE:
        return _TEXT_PRIORITY_SCORE[text]
    try:
        return int(text)
    except ValueError:
        return -1


def _priority_bucket(value: Any) -> str:
    score = _priority_score(value)
    if score >= 80:
        return "high"
    if score >= 45:
        return "medium"
    if score >= 0:
        return "normal"
    return "unknown"


def _queue_key(item: Mapping[str, Any]) -> tuple[int, str, str]:
    return (
        -_priority_score(item.get("priority")),
        _normalize_lemma(item.get("lemma")),
        _text(item.get("entry_id")).casefold(),
    )


def build_review_index(
    queue: Iterable[Mapping[str, Any]],
    *,
    batch_size: int = 50,
    reviewed_lemmas: Set[str] | None = None,
) -> tuple[dict[str, Any], dict[str, Any]]:
    """Build an index and report without changing the queue or candidate layer."""

    if batch_size < 1:
        raise ValueError("batch_size must be positive")

    raw_queue = list(queue)
    if not all(isinstance(item, Mapping) for item in raw_queue):
        raise ValueError("queue entries must be mappings")
    ordered = list(raw_queue)

    lemmas_by_key: dict[str, str] = {}
    for item in ordered:
        lemma = _text(item.get("lemma"))
        normalized = _normalize_lemma(lemma)
        if not normalized:
            raise ValueError("queue entry missing lemma")
        if normalized in lemmas_by_key:
            raise ValueError(f"duplicate lemma: {normalized}")
        lemmas_by_key[normalized] = lemma

    ordered = sorted(ordered, key=_queue_key)
    reviewed = {_normalize_lemma(value) for value in (reviewed_lemmas or set()) if _normalize_lemma(value)}
    unknown_reviewed = sorted(reviewed - set(lemmas_by_key))
    if unknown_reviewed:
        raise ValueError(f"reviewed lemma outside queue: {unknown_reviewed[0]}")

    total_entries = len(ordered)
    total_batches = ceil(total_entries / batch_size) if total_entries else 0
    batches: list[dict[str, Any]] = []
    for batch_number in range(1, total_batches + 1):
        start = (batch_number - 1) * batch_size
        selected = ordered[start : start + batch_size]
        selected_lemmas = [_text(item.get("lemma")) for item in selected]
        selected_keys = [_normalize_lemma(lemma) for lemma in selected_lemmas]
        reviewed_count = sum(lemma in reviewed for lemma in selected_keys)
        if reviewed_count == len(selected):
            status = "complete"
        elif reviewed_count:
            status = "in_progress"
        else:
            status = "pending"
        priority_counts = Counter(_priority_bucket(item.get("priority")) for item in selected)
        batches.append(
            {
                "batch_id": f"yixue-review-v1-{batch_number:03d}",
                "batch_number": batch_number,
                "start_index": start,
                "end_index": start + len(selected) - 1,
                "selected_entries": len(selected),
                "reviewed_entries": reviewed_count,
                "pending_entries": len(selected) - reviewed_count,
                "status": status,
                "priority_counts": dict(sorted(priority_counts.items())),
                "lemmas": selected_lemmas,
            }
        )

    index = {
        "schema_version": INDEX_SCHEMA_VERSION,
        "layer": "yixue-editorial-review-index-v1",
        "source": "yixue-editorial-review-queue-v1",
        "batch_size": batch_size,
        "total_entries": total_entries,
        "total_batches": total_batches,
        "reviewed_entries": len(reviewed),
        "pending_entries": total_entries - len(reviewed),
        "batches": batches,
        "rule": "索引只记录审校进度，不改变 candidate/draft 状态；reviewed 统计只接受已通过验收的 reviewed layer。",
    }
    report = {
        "schema_version": INDEX_SCHEMA_VERSION,
        "total_entries": total_entries,
        "total_batches": total_batches,
        "batch_size": batch_size,
        "reviewed_entries": len(reviewed),
        "pending_entries": total_entries - len(reviewed),
        "all_lemmas_exactly_once": len(lemmas_by_key) == total_entries,
        "passed": True,
    }
    return index, report


def _load_json(path: pathlib.Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def _load_queue(path: pathlib.Path) -> list[Mapping[str, Any]]:
    payload = _load_json(path)
    values = payload.get("entries") if isinstance(payload, Mapping) else payload
    if not isinstance(values, list) or not all(isinstance(value, Mapping) for value in values):
        raise ValueError(f"{path} must contain a list of entries")
    return list(values)


def _load_validator_module():
    path = pathlib.Path(__file__).with_name("validate_dictionary_reviewed_layer.py")
    spec = importlib.util.spec_from_file_location("dictionary_reviewed_layer", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"unable to load validator: {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _load_reviewed_lemmas(paths: list[pathlib.Path]) -> set[str]:
    if not paths:
        return set()
    validator = _load_validator_module()
    result: set[str] = set()
    for path in paths:
        payload = _load_json(path)
        if not isinstance(payload, Mapping):
            raise ValueError(f"{path} must contain a reviewed layer object")
        validation = validator.validate_layer(payload)
        if not validation["passed"]:
            raise ValueError(f"reviewed input failed validation: {path}")
        entries = payload.get("entries")
        if not isinstance(entries, list):
            raise ValueError(f"{path} has no entries")
        for entry in entries:
            if not isinstance(entry, Mapping):
                raise ValueError(f"{path} has an invalid entry")
            lemma = _normalize_lemma(entry.get("lemma"))
            if lemma in result:
                raise ValueError(f"duplicate reviewed lemma: {lemma}")
            result.add(lemma)
    return result


def _write_json(path: pathlib.Path, payload: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--queue-input",
        type=pathlib.Path,
        default=pathlib.Path("data/dictionary/editorial-review-queue-v1.json"),
    )
    parser.add_argument("--batch-size", type=int, default=50)
    parser.add_argument("--reviewed-input", type=pathlib.Path, action="append", default=[])
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--report-output", type=pathlib.Path, default=None)
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    try:
        queue = _load_queue(args.queue_input)
        reviewed = _load_reviewed_lemmas(args.reviewed_input)
        index, report = build_review_index(
            queue,
            batch_size=args.batch_size,
            reviewed_lemmas=reviewed,
        )
    except (OSError, json.JSONDecodeError, ValueError) as error:
        report = {
            "schema_version": INDEX_SCHEMA_VERSION,
            "passed": False,
            "error": f"{type(error).__name__}: {error}",
        }
        if args.report_output is not None:
            _write_json(args.report_output, report)
        print("REVIEW_INDEX_REFUSED")
        print(json.dumps(report, ensure_ascii=True, sort_keys=True))
        return 1

    _write_json(args.output, index)
    if args.report_output is not None:
        _write_json(args.report_output, report)
    print("REVIEW_INDEX_BUILD_PASS")
    print(json.dumps(report, ensure_ascii=True, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
