#!/usr/bin/env python3
"""Create a deterministic human-review queue for rich dictionary candidates."""

from __future__ import annotations

import argparse
import json
import pathlib
from collections import Counter
from typing import Iterable, Mapping


QUEUE_SCHEMA_VERSION = 1


def _mapping(value: object) -> Mapping[str, object]:
    return value if isinstance(value, Mapping) else {}


def _list(value: object) -> list[object]:
    return value if isinstance(value, list) else []


def _unique_strings(values: Iterable[object]) -> list[str]:
    result: list[str] = []
    seen: set[str] = set()
    for value in values:
        if not isinstance(value, str):
            continue
        text = " ".join(value.split()).strip()
        if text and text not in seen:
            seen.add(text)
            result.append(text)
    return result


_FIELD_WEIGHTS = {
    "ipa": 100,
    "part_of_speech": 95,
    "english_senses": 95,
    "chinese_senses": 95,
    "pronunciation_alias_review": 90,
    "variants": 80,
    "english_examples": 70,
    "bilingual_examples": 65,
    "spelling_alias_review": 60,
    "collocations": 45,
    "usage_register": 40,
    "sense_alignment": 35,
    "license_review": 30,
    "human_review": 25,
}

_ACTION_BY_FIELD = {
    "ipa": "核对英音/美音音标并登记来源",
    "part_of_speech": "核对词性、可数性和必要语法信息",
    "english_senses": "补充并核对英文义项边界",
    "chinese_senses": "为每个核心义项撰写或核对中文释义",
    "pronunciation_alias_review": "核对别名或派生词音标是否适用于当前词形",
    "variants": "核对词形变化和常见变体",
    "english_examples": "补充自然且适合学习的英文例句",
    "bilingual_examples": "核对双语句对并确认可分发许可/署名",
    "spelling_alias_review": "确认原词是否为拼写错误并保留纠错关系",
    "collocations": "从候选共现中筛出真实搭配并补中文用法",
    "usage_register": "补充正式、口语、学术、专业等语域语用",
    "sense_alignment": "把中文义项、英文义项和例句按语境逐项对齐",
    "license_review": "核对来源许可证、署名和独立词包边界",
    "human_review": "完成整条词条的人工审校和回归查询",
}


def _priority(review_fields: list[str]) -> int:
    if not review_fields:
        return 0
    return max(_FIELD_WEIGHTS.get(field, 20) for field in review_fields)


def _recommended_action(review_fields: list[str]) -> str:
    ordered = sorted(review_fields, key=lambda field: (-_FIELD_WEIGHTS.get(field, 20), field))
    return _ACTION_BY_FIELD.get(ordered[0], "按词条质量准则完成审校") if ordered else "复核并确认可发布"


def _candidate_source_ids(values: object) -> list[str]:
    result: list[str] = []
    for value in _list(values):
        row = _mapping(value)
        source_id = row.get("source_id")
        if isinstance(source_id, str) and source_id.strip():
            result.append(source_id.strip())
        for nested in _list(row.get("source_ids")):
            if isinstance(nested, str) and nested.strip():
                result.append(nested.strip())
    return _unique_strings(result)


def _source_evidence(rich: Mapping[str, object]) -> dict[str, list[str]]:
    fields = (
        "pronunciation_candidates",
        "part_of_speech_candidates",
        "sense_candidates",
        "english_examples",
        "bilingual_examples",
        "collocation_candidates",
        "relation_candidates",
        "variants",
    )
    return {
        field: _candidate_source_ids(rich.get(field))
        for field in fields
        if _candidate_source_ids(rich.get(field))
    }


def build_review_item(entry: Mapping[str, object]) -> dict[str, object]:
    rich = _mapping(entry.get("rich_candidate"))
    quality = _mapping(rich.get("quality"))
    review_fields = _unique_strings(_list(quality.get("review_fields")))
    kaikki = _mapping(entry.get("kaikki"))
    source_urls = []
    page_url = kaikki.get("page_url")
    if isinstance(page_url, str) and page_url.strip():
        source_urls.append(page_url.strip())
    return {
        "queue_schema_version": QUEUE_SCHEMA_VERSION,
        "entry_id": str(entry.get("entry_id", rich.get("entry_id", ""))),
        "lemma": str(entry.get("lemma", rich.get("lemma", ""))).strip(),
        "coverage_bands": _unique_strings(_list(rich.get("coverage_bands"))),
        "learning_tags": _unique_strings(_list(rich.get("learning_tags"))),
        "priority": _priority(review_fields),
        "status": "pending",
        "quality_status": str(quality.get("status", "draft")),
        "review_fields": review_fields,
        "recommended_action": _recommended_action(review_fields),
        "source_ids": _unique_strings(_list(entry.get("source_ids"))),
        "source_urls": source_urls,
        "source_evidence": _source_evidence(rich),
        "candidate_metrics": {
            "pronunciation_candidates": len(_list(rich.get("pronunciation_candidates"))),
            "part_of_speech_candidates": len(_list(rich.get("part_of_speech_candidates"))),
            "sense_candidates": len(_list(rich.get("sense_candidates"))),
            "english_examples": len(_list(rich.get("english_examples"))),
            "bilingual_examples": len(_list(rich.get("bilingual_examples"))),
            "collocation_candidates": len(_list(rich.get("collocation_candidates"))),
            "relation_candidates": len(_list(rich.get("relation_candidates"))),
            "variants": len(_list(rich.get("variants"))),
        },
    }


def build_review_report(items: Iterable[Mapping[str, object]]) -> dict[str, object]:
    rows = tuple(items)
    missing = Counter(field for row in rows for field in _list(row.get("review_fields")))
    priorities = Counter(
        "high" if int(row.get("priority", 0)) >= 80 else "medium" if int(row.get("priority", 0)) >= 45 else "normal"
        for row in rows
    )
    return {
        "schema_version": QUEUE_SCHEMA_VERSION,
        "total_entries": len(rows),
        "pending_entries": sum(row.get("status") == "pending" for row in rows),
        "missing_field_counts": dict(sorted(missing.items())),
        "priority_counts": dict(sorted(priorities.items())),
        "ordered_deterministically": True,
        "publishable_entries": 0,
        "note": "队列只描述人工审校工作，不改变候选词条的 draft 状态。",
    }


def build_review_queue(payload: Mapping[str, object]) -> dict[str, object]:
    raw_entries = payload.get("entries", [])
    if not isinstance(raw_entries, list):
        raise ValueError("candidate payload entries must be a list")
    items = [
        build_review_item(entry)
        for entry in raw_entries
        if isinstance(entry, Mapping)
    ]
    items.sort(key=lambda item: (-int(item["priority"]), str(item["lemma"])))
    report = build_review_report(items)
    return {
        "schema_version": QUEUE_SCHEMA_VERSION,
        "source_candidate_file": "editorial-candidates-v3.json",
        "entries": items,
        "report": report,
    }


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=pathlib.Path, default=pathlib.Path("data/dictionary/editorial-candidates-v3.json"))
    parser.add_argument("--output", type=pathlib.Path, default=pathlib.Path("data/dictionary/editorial-review-queue-v1.json"))
    parser.add_argument("--report-output", type=pathlib.Path, default=pathlib.Path("data/dictionary/editorial-review-queue-v1.report.json"))
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    payload = json.loads(args.input.resolve().read_text(encoding="utf-8"))
    if not isinstance(payload, Mapping):
        raise ValueError("input must be a JSON object")
    queue = build_review_queue(payload)
    report = queue["report"]
    args.output.resolve().parent.mkdir(parents=True, exist_ok=True)
    args.report_output.resolve().parent.mkdir(parents=True, exist_ok=True)
    args.output.resolve().write_text(json.dumps(queue, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    args.report_output.resolve().write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, sort_keys=True))
    print(f"queue={args.output.resolve()}")
    print(f"report={args.report_output.resolve()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
