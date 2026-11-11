#!/usr/bin/env python3
"""Build a streamed, editable draft index for every dictionary candidate.

The rich candidate JSON is intentionally large because it keeps the complete
source evidence for each word.  This command creates a small JSONL layer that
normalizes the fields an editor will fill and points back to the exact
candidate entry instead of copying the large payload.  It is an editorial
workbench, never a runtime or public dictionary layer: every record remains
``draft`` and ``human_review`` is always false.
"""

from __future__ import annotations

import argparse
import json
import pathlib
from collections import Counter
from collections.abc import Iterable, Iterator, Mapping
from typing import Any


DRAFT_SCHEMA_VERSION = 1
_JSON_CHUNK_SIZE = 1024 * 1024
_REVIEW_CHECKS = (
    "source",
    "license",
    "pronunciation",
    "meaning",
    "usage",
    "examples",
    "relations",
)
_COUNTED_CANDIDATE_FIELDS = (
    "pronunciation_candidates",
    "part_of_speech_candidates",
    "sense_candidates",
    "english_examples",
    "bilingual_examples",
    "collocation_candidates",
    "relation_candidates",
    "variants",
)


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


def _source_ids_from_candidates(values: Iterable[Any]) -> list[str]:
    source_ids: list[str] = []
    seen: set[str] = set()
    for value in values:
        item = _mapping(value)
        if item is None:
            continue
        source_id = _text(item.get("source_id"))
        if source_id and source_id not in seen:
            source_ids.append(source_id)
            seen.add(source_id)
        for nested_source_id in _list(item.get("source_ids")):
            nested = _text(nested_source_id)
            if nested and nested not in seen:
                source_ids.append(nested)
                seen.add(nested)
    return source_ids


def _candidate_metrics(rich: Mapping[str, Any]) -> dict[str, int]:
    return {
        field: len(_list(rich.get(field)))
        for field in _COUNTED_CANDIDATE_FIELDS
    }


def _base_source_id(source_ids: list[str]) -> str:
    # The base meanings are imported from the open ECDICT layer.  Keep the
    # fallback explicit for fixtures or future source adapters.
    if "open-ecdict" in source_ids:
        return "open-ecdict"
    return source_ids[0] if source_ids else ""


def build_editorial_draft_entry(
    candidate: Mapping[str, Any],
    *,
    candidate_source: str,
    candidate_index: int,
) -> dict[str, Any]:
    """Normalize one rich candidate into an editable, still-draft record."""

    rich = _mapping(candidate.get("rich_candidate"))
    if rich is None:
        raise ValueError("candidate missing rich_candidate")

    quality = _mapping(rich.get("quality")) or {}
    if _text(quality.get("status")) != "draft":
        raise ValueError(
            f"candidate must remain draft: {_text(rich.get('lemma')) or '<unknown>'}"
        )

    entry_id = _text(rich.get("entry_id")) or _text(candidate.get("entry_id"))
    language_pair = _text(rich.get("language_pair")) or "en-zh"
    lemma = _text(rich.get("lemma")) or _text(candidate.get("lemma"))
    if not entry_id or not lemma:
        raise ValueError("candidate missing entry_id or lemma")
    if candidate_index < 0:
        raise ValueError("candidate_index must not be negative")

    source_ids = _unique_texts(_list(rich.get("source_ids")))
    coverage_bands = _unique_texts(_list(rich.get("coverage_bands")))
    learning_tags = _unique_texts(_list(rich.get("learning_tags")))
    base = _mapping(candidate.get("base")) or {}
    base_ipa = _text(base.get("ipa"))
    base_pos = _text(base.get("part_of_speech"))
    meanings = _unique_texts(_list(base.get("meanings")))
    source_translations = _unique_texts(_list(base.get("source_translations")))
    base_source_id = _base_source_id(source_ids)

    meaning_candidates = [
        {
            "text": meaning,
            "source_ids": [base_source_id] if base_source_id else [],
            "needs_review": True,
        }
        for meaning in meanings
    ]
    source_evidence: dict[str, list[str]] = {}
    for field in _COUNTED_CANDIDATE_FIELDS:
        source_evidence[field] = _source_ids_from_candidates(_list(rich.get(field)))

    review_fields = _unique_texts(_list(quality.get("review_fields")))
    review = {
        "status": "draft",
        "reviewer": "",
        "reviewed_at": "",
        "human_review": False,
        "checks": {name: False for name in _REVIEW_CHECKS},
        "notes": "",
    }

    return {
        "schema_version": DRAFT_SCHEMA_VERSION,
        "layer": "yixue-editorial-draft-v1",
        "entry_id": entry_id,
        "language_pair": language_pair,
        "lemma": lemma,
        "coverage_bands": coverage_bands,
        "learning_tags": learning_tags,
        "candidate_ref": {
            "path": candidate_source.replace("\\", "/"),
            "entry_index": candidate_index,
            "entry_id": entry_id,
        },
        "editorial_draft": {
            "ipa": base_ipa,
            "part_of_speech": base_pos,
            "meaning_candidates": meaning_candidates,
            "source_translation_candidates": source_translations,
            "usage_register": [],
            "bilingual_examples": [],
            "collocations": [],
            "relations": [],
            "variant_candidates": [
                item for item in _list(rich.get("variants")) if isinstance(item, Mapping)
            ],
            "notes": "候选值仅供编辑核对；完成人工审校前不得作为正式释义发布。",
        },
        "candidate_metrics": _candidate_metrics(rich),
        "candidate_source_evidence": source_evidence,
        "source_ids": source_ids,
        "quality": {
            "status": "draft",
            "review_fields": review_fields,
            "human_review": False,
        },
        "review": review,
    }


def _entries_array_prefix(stream: Any) -> str:
    """Read up to the entries array and return text immediately after ``[``."""

    marker = '"entries"'
    buffer = ""
    while True:
        chunk = stream.read(_JSON_CHUNK_SIZE)
        if not chunk:
            raise ValueError("candidate JSON has no entries array")
        buffer += chunk
        marker_index = buffer.find(marker)
        if marker_index < 0:
            # Keep enough text for a marker split across chunk boundaries.
            buffer = buffer[-len(marker) :]
            continue
        colon_index = buffer.find(":", marker_index + len(marker))
        if colon_index < 0:
            buffer = buffer[marker_index:]
            continue
        array_index = buffer.find("[", colon_index + 1)
        if array_index < 0:
            buffer = buffer[colon_index:]
            continue
        return buffer[array_index + 1 :]


def iter_candidate_entries(path: pathlib.Path) -> Iterator[Mapping[str, Any]]:
    """Yield top-level candidate entries without loading the whole JSON file."""

    decoder = json.JSONDecoder()
    with path.open("r", encoding="utf-8") as stream:
        buffer = _entries_array_prefix(stream)
        while True:
            while True:
                stripped = buffer.lstrip()
                if stripped != buffer:
                    buffer = stripped
                if buffer:
                    break
                more = stream.read(_JSON_CHUNK_SIZE)
                if not more:
                    raise ValueError("candidate entries array ended unexpectedly")
                buffer += more

            if buffer.startswith("]"):
                return
            if buffer.startswith(","):
                buffer = buffer[1:]
                continue

            while True:
                try:
                    value, end = decoder.raw_decode(buffer)
                except json.JSONDecodeError as error:
                    more = stream.read(_JSON_CHUNK_SIZE)
                    if not more:
                        raise ValueError(
                            f"candidate entry JSON ended unexpectedly: {error.msg}"
                        ) from error
                    buffer += more
                    continue
                if not isinstance(value, Mapping):
                    raise ValueError("candidate entries must be objects")
                yield value
                buffer = buffer[end:]
                break


def _new_stats(candidate_source: str) -> dict[str, Any]:
    return {
        "schema_version": DRAFT_SCHEMA_VERSION,
        "layer": "yixue-editorial-draft-v1",
        "candidate_source": candidate_source.replace("\\", "/"),
        "total_entries": 0,
        "draft_entries": 0,
        "entries_with_editable_record": 0,
        "entries_with_base_ipa": 0,
        "entries_with_base_part_of_speech": 0,
        "entries_with_base_meanings": 0,
        "review_status_counts": Counter(),
        "review_field_counts": Counter(),
        "duplicate_entry_ids": [],
        "duplicate_lemmas": [],
    }


def _add_stats(stats: dict[str, Any], entry: Mapping[str, Any]) -> None:
    stats["total_entries"] += 1
    if _text((_mapping(entry.get("quality")) or {}).get("status")) == "draft":
        stats["draft_entries"] += 1
    if _text(entry.get("layer")) == "yixue-editorial-draft-v1":
        stats["entries_with_editable_record"] += 1
    editorial = _mapping(entry.get("editorial_draft")) or {}
    if _text(editorial.get("ipa")):
        stats["entries_with_base_ipa"] += 1
    if _text(editorial.get("part_of_speech")):
        stats["entries_with_base_part_of_speech"] += 1
    if _list(editorial.get("meaning_candidates")):
        stats["entries_with_base_meanings"] += 1
    quality = _mapping(entry.get("quality")) or {}
    stats["review_status_counts"][_text(quality.get("status")) or "missing"] += 1
    stats["review_field_counts"].update(_list(quality.get("review_fields")))


def finalize_stats(stats: dict[str, Any]) -> dict[str, Any]:
    result = dict(stats)
    result["review_status_counts"] = dict(sorted(stats["review_status_counts"].items()))
    result["review_field_counts"] = dict(sorted(stats["review_field_counts"].items()))
    result["all_entries_are_draft"] = (
        stats["total_entries"] > 0
        and stats["draft_entries"] == stats["total_entries"]
    )
    result["all_entries_have_editable_records"] = (
        stats["total_entries"] > 0
        and stats["entries_with_editable_record"] == stats["total_entries"]
    )
    result["passed"] = bool(
        result["all_entries_are_draft"]
        and result["all_entries_have_editable_records"]
        and not stats["duplicate_entry_ids"]
        and not stats["duplicate_lemmas"]
    )
    result["rule"] = (
        "草稿层只提供统一编辑结构和候选回指；所有条目保持 draft，"
        "必须完成独立人工审校后才能进入 reviewed/published layer。"
    )
    return result


def iter_editorial_draft_entries(
    candidates: Iterable[Mapping[str, Any]],
    *,
    candidate_source: str,
) -> Iterator[dict[str, Any]]:
    """Yield normalized entries and reject duplicate IDs or lemmas."""

    seen_ids: set[str] = set()
    seen_lemmas: set[str] = set()
    for index, candidate in enumerate(candidates):
        if not isinstance(candidate, Mapping):
            raise ValueError("candidate entries must be objects")
        draft = build_editorial_draft_entry(
            candidate,
            candidate_source=candidate_source,
            candidate_index=index,
        )
        entry_id = _text(draft.get("entry_id"))
        lemma = " ".join(_text(draft.get("lemma")).casefold().split())
        if entry_id in seen_ids:
            raise ValueError(f"duplicate entry_id: {entry_id}")
        if lemma in seen_lemmas:
            raise ValueError(f"duplicate lemma: {lemma}")
        seen_ids.add(entry_id)
        seen_lemmas.add(lemma)
        yield draft


def build_editorial_draft(
    candidates: Iterable[Mapping[str, Any]],
    *,
    candidate_source: str,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    """Build a small in-memory fixture-friendly draft layer and report."""

    stats = _new_stats(candidate_source)
    entries: list[dict[str, Any]] = []
    for entry in iter_editorial_draft_entries(
        candidates,
        candidate_source=candidate_source,
    ):
        entries.append(entry)
        _add_stats(stats, entry)
    return entries, finalize_stats(stats)


def _write_json(path: pathlib.Path, payload: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def write_editorial_draft(
    candidate_input: pathlib.Path,
    output: pathlib.Path,
    report_output: pathlib.Path,
) -> dict[str, Any]:
    """Stream candidates to a temporary JSONL and publish only on success."""

    candidate_source = candidate_input.as_posix()
    stats = _new_stats(candidate_source)
    output.parent.mkdir(parents=True, exist_ok=True)
    temp_output = output.with_name(f".{output.name}.tmp")
    temp_output.unlink(missing_ok=True)
    try:
        with temp_output.open("w", encoding="utf-8", newline="\n") as stream:
            for entry in iter_editorial_draft_entries(
                iter_candidate_entries(candidate_input),
                candidate_source=candidate_source,
            ):
                stream.write(json.dumps(entry, ensure_ascii=False, separators=(",", ":")))
                stream.write("\n")
                _add_stats(stats, entry)
        report = finalize_stats(stats)
        if not report["passed"]:
            raise ValueError("editorial draft report failed its invariants")
        temp_output.replace(output)
        _write_json(report_output, report)
        return report
    except Exception:
        temp_output.unlink(missing_ok=True)
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
        default=pathlib.Path("data/dictionary/editorial-draft-v1.jsonl"),
    )
    parser.add_argument(
        "--report-output",
        type=pathlib.Path,
        default=pathlib.Path("data/dictionary/editorial-draft-v1.report.json"),
    )
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    try:
        report = write_editorial_draft(
            args.candidate_input,
            args.output,
            args.report_output,
        )
    except (OSError, UnicodeError, ValueError, json.JSONDecodeError) as error:
        print("EDITORIAL_DRAFT_BUILD_REFUSED")
        print(json.dumps({"passed": False, "error": f"{type(error).__name__}: {error}"}, ensure_ascii=True))
        return 1
    print("EDITORIAL_DRAFT_BUILD_PASS")
    print(json.dumps(report, ensure_ascii=True, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
