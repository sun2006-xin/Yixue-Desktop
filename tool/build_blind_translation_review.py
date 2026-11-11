#!/usr/bin/env python3
"""Build a model-neutral A/B translation review sheet and a separate reveal key."""

from __future__ import annotations

import argparse
import csv
import json
import pathlib
import random
from datetime import datetime


SCORE_FIELDS = (
    "accuracy_a_1_to_5",
    "accuracy_b_1_to_5",
    "naturalness_a_1_to_5",
    "naturalness_b_1_to_5",
    "terminology_a_1_to_5",
    "terminology_b_1_to_5",
    "formatting_a_1_to_5",
    "formatting_b_1_to_5",
    "serious_error_a_yes_no",
    "serious_error_b_yes_no",
    "preferred_a_b_tie",
    "reviewer_notes",
)


def _case_map(report: dict) -> dict[str, dict]:
    cases = report.get("cases")
    if not isinstance(cases, list):
        raise ValueError("report cases must be a list")
    result = {}
    for case in cases:
        case_id = case.get("id")
        if not case_id or case_id in result:
            raise ValueError("report contains an empty or duplicate case ID")
        result[case_id] = case
    return result


def build_review(
    first_report: dict,
    second_report: dict,
    first_label: str,
    second_label: str,
    seed: int,
) -> tuple[list[dict[str, object]], dict[str, object]]:
    if not first_label or not second_label or first_label == second_label:
        raise ValueError("model labels must be non-empty and distinct")
    if first_report.get("suite_id") != second_report.get("suite_id"):
        raise ValueError("report suite IDs differ")

    first_cases = _case_map(first_report)
    second_cases = _case_map(second_report)
    if set(first_cases) != set(second_cases):
        raise ValueError("report case IDs differ")

    ordered_ids = [case["id"] for case in first_report["cases"]]
    shuffled_ids = list(ordered_ids)
    random.Random(seed).shuffle(shuffled_ids)
    swapped = set(shuffled_ids[: len(shuffled_ids) // 2])
    rows = []
    assignments = []

    for index, case_id in enumerate(ordered_ids, 1):
        first = first_cases[case_id]
        second = second_cases[case_id]
        if first.get("source") != second.get("source"):
            raise ValueError(f"source differs for case {case_id}")
        if first.get("source_language") != second.get("source_language") or first.get(
            "target_language"
        ) != second.get("target_language"):
            raise ValueError(f"language direction differs for case {case_id}")
        first_translation = first.get("translation")
        second_translation = second.get("translation")
        if not isinstance(first_translation, str) or not first_translation.strip():
            raise ValueError(f"first report has empty translation for {case_id}")
        if not isinstance(second_translation, str) or not second_translation.strip():
            raise ValueError(f"second report has empty translation for {case_id}")

        should_swap = case_id in swapped
        translation_a = second_translation if should_swap else first_translation
        translation_b = first_translation if should_swap else second_translation
        label_a = second_label if should_swap else first_label
        label_b = first_label if should_swap else second_label
        pair_id = f"B{index:03d}"
        row = {
            "pair_id": pair_id,
            "case_id": case_id,
            "category": first.get("category", ""),
            "source_language": first.get("source_language", ""),
            "target_language": first.get("target_language", ""),
            "source": first["source"],
            "reference": " || ".join(first.get("references", [])),
            "translation_a": translation_a,
            "translation_b": translation_b,
        }
        row.update({field: "" for field in SCORE_FIELDS})
        rows.append(row)
        assignments.append(
            {"pair_id": pair_id, "case_id": case_id, "a_model": label_a, "b_model": label_b}
        )

    key = {
        "schema_version": 1,
        "suite_id": first_report.get("suite_id"),
        "seed": seed,
        "models": [first_label, second_label],
        "assignments": assignments,
    }
    return rows, key


def write_review(rows: list[dict[str, object]], destination: pathlib.Path) -> None:
    if not rows:
        raise ValueError("review rows must not be empty")
    with destination.open("w", encoding="utf-8-sig", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("first_report", type=pathlib.Path)
    parser.add_argument("second_report", type=pathlib.Path)
    parser.add_argument("--first-label", required=True)
    parser.add_argument("--second-label", required=True)
    parser.add_argument("--seed", type=int, default=20260911)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    first = json.loads(args.first_report.read_text(encoding="utf-8"))
    second = json.loads(args.second_report.read_text(encoding="utf-8"))
    rows, key = build_review(first, second, args.first_label, args.second_label, args.seed)
    args.output.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    review_path = args.output / f"blind-review-{stamp}.csv"
    key_path = args.output / f"blind-review-key-{stamp}.json"
    write_review(rows, review_path)
    key_path.write_text(json.dumps(key, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"BLIND_REVIEW={review_path}")
    print(f"REVEAL_KEY={key_path}")
    print(f"CASES={len(rows)}")
    print(f"SWAPPED={sum(item['a_model'] == args.second_label for item in key['assignments'])}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
