#!/usr/bin/env python3
"""Export a bounded, deterministic human-review batch from dictionary candidates.

The output is a workbench packet, not a public dictionary package.  Every
selected candidate remains ``draft`` and receives an empty review form.  A
reviewer can turn the edited packet into the independent reviewed layer that
``validate_dictionary_reviewed_layer.py`` accepts.
"""

from __future__ import annotations

import argparse
import copy
import json
import pathlib
from collections.abc import Iterable, Mapping
from math import ceil
from typing import Any


REVIEW_BATCH_SCHEMA_VERSION = 1
_REVIEW_CHECKS = (
    "source",
    "license",
    "pronunciation",
    "meaning",
    "usage",
    "examples",
    "relations",
)
_TEXT_PRIORITY_SCORE = {"high": 100, "medium": 65, "low": 45, "normal": 0}


def _text(value: Any) -> str:
    return value.strip() if isinstance(value, str) else ""


def _mapping(value: Any) -> Mapping[str, Any] | None:
    return value if isinstance(value, Mapping) else None


def _list(value: Any) -> list[Any]:
    return list(value) if isinstance(value, list) else []


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


def _queue_key(item: Mapping[str, Any]) -> tuple[int, str, str]:
    lemma = _text(item.get("lemma")).casefold()
    entry_id = _text(item.get("entry_id")).casefold()
    return (-_priority_score(item.get("priority")), lemma, entry_id)


def _review_template() -> dict[str, Any]:
    return {
        "status": "pending",
        "reviewer": "",
        "reviewed_at": "",
        "human_review": False,
        "checks": {name: False for name in _REVIEW_CHECKS},
        "notes": "",
        "reviewed_entry": None,
    }


def build_review_batch(
    candidates: Iterable[Mapping[str, Any]],
    queue: Iterable[Mapping[str, Any]],
    *,
    batch_number: int,
    batch_size: int,
) -> dict[str, Any]:
    """Build one review packet without changing candidate quality states."""

    if batch_number < 1:
        raise ValueError("batch_number must be positive")
    if batch_size < 1:
        raise ValueError("batch_size must be positive")

    candidate_map: dict[str, Mapping[str, Any]] = {}
    for candidate in candidates:
        lemma = _text(candidate.get("lemma")).casefold()
        if not lemma:
            raise ValueError("candidate missing lemma")
        if lemma in candidate_map:
            raise ValueError(f"duplicate candidate: {lemma}")
        candidate_map[lemma] = candidate

    ordered_queue = sorted(
        (item for item in queue if _text(item.get("lemma"))),
        key=_queue_key,
    )
    total_queue_entries = len(ordered_queue)
    total_batches = ceil(total_queue_entries / batch_size) if total_queue_entries else 0
    if batch_number > max(total_batches, 1):
        raise ValueError(f"batch_number {batch_number} exceeds {total_batches} batches")

    start = (batch_number - 1) * batch_size
    selected_queue = ordered_queue[start : start + batch_size]
    entries: list[dict[str, Any]] = []
    for queue_item in selected_queue:
        lemma = _text(queue_item.get("lemma")).casefold()
        candidate = candidate_map.get(lemma)
        if candidate is None:
            raise ValueError(f"missing candidate: {lemma}")
        rich_candidate = _mapping(candidate.get("rich_candidate"))
        if rich_candidate is None:
            raise ValueError(f"candidate missing rich_candidate: {lemma}")
        entries.append(
            {
                "entry_id": _text(queue_item.get("entry_id"))
                or _text(candidate.get("entry_id")),
                "language_pair": _text(candidate.get("language_pair")) or "en-zh",
                "lemma": _text(queue_item.get("lemma")),
                "priority": copy.deepcopy(queue_item.get("priority")),
                "review_fields": copy.deepcopy(_list(queue_item.get("review_fields"))),
                "recommended_action": _text(queue_item.get("recommended_action")),
                "coverage_bands": copy.deepcopy(_list(queue_item.get("coverage_bands"))),
                "learning_tags": copy.deepcopy(_list(queue_item.get("learning_tags"))),
                "candidate": copy.deepcopy(rich_candidate),
                "candidate_metrics": copy.deepcopy(
                    _mapping(queue_item.get("candidate_metrics")) or {}
                ),
                "source_evidence": copy.deepcopy(
                    _mapping(queue_item.get("source_evidence")) or {}
                ),
                "source_ids": copy.deepcopy(_list(queue_item.get("source_ids"))),
                "source_urls": copy.deepcopy(_list(queue_item.get("source_urls"))),
                "review": _review_template(),
            }
        )

    return {
        "schema_version": REVIEW_BATCH_SCHEMA_VERSION,
        "layer": "yixue-editorial-review-workbench",
        "batch_id": f"yixue-review-v1-{batch_number:03d}",
        "batch_number": batch_number,
        "batch_size": batch_size,
        "total_queue_entries": total_queue_entries,
        "total_batches": total_batches,
        "selected_entries": len(entries),
        "entries": entries,
        "review_contract": {
            "candidate_status_is_immutable": True,
            "required_checks": list(_REVIEW_CHECKS),
            "next_step": "填写 review 后导出独立 reviewed layer，并用 validate_dictionary_reviewed_layer.py 验收",
        },
    }


def _load_entries(path: pathlib.Path, key: str) -> list[Mapping[str, Any]]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if isinstance(payload, Mapping):
        values = payload.get(key)
    else:
        values = payload
    if not isinstance(values, list) or not all(isinstance(item, Mapping) for item in values):
        raise ValueError(f"{path} must contain a list of {key}")
    return list(values)


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--candidate-input",
        type=pathlib.Path,
        default=pathlib.Path("data/dictionary/editorial-candidates-v3.json"),
    )
    parser.add_argument(
        "--queue-input",
        type=pathlib.Path,
        default=pathlib.Path("data/dictionary/editorial-review-queue-v1.json"),
    )
    parser.add_argument("--batch-number", type=int, required=True)
    parser.add_argument("--batch-size", type=int, default=50)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--report-output", type=pathlib.Path, default=None)
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    candidates = _load_entries(args.candidate_input, "entries")
    queue = _load_entries(args.queue_input, "entries")
    batch = build_review_batch(
        candidates,
        queue,
        batch_number=args.batch_number,
        batch_size=args.batch_size,
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(batch, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    report = {
        "schema_version": REVIEW_BATCH_SCHEMA_VERSION,
        "batch_id": batch["batch_id"],
        "total_queue_entries": batch["total_queue_entries"],
        "total_batches": batch["total_batches"],
        "selected_entries": batch["selected_entries"],
        "all_selected_reviews_pending": all(
            entry["review"]["status"] == "pending" for entry in batch["entries"]
        ),
        "passed": True,
    }
    if args.report_output is not None:
        args.report_output.parent.mkdir(parents=True, exist_ok=True)
        args.report_output.write_text(
            json.dumps(report, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
    print("REVIEW_BATCH_BUILD_PASS")
    print(json.dumps(report, ensure_ascii=True, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
