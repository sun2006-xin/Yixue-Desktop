"""Audit the assistant-curated dictionary layer and build its runtime index.

This is an assistant verification layer, not a human-review or Oxford-derived
publication layer.  The audit checks source traceability, licence boundaries,
core meaning/POS integrity and usable pronunciation where available.  Missing
optional enrichment is kept as an explicit flag instead of being invented.
"""

from __future__ import annotations

import argparse
import datetime as _datetime
import json
import pathlib
import re
from collections import Counter
from collections.abc import Iterable, Mapping
from typing import Any


LAYER = "yixue-assistant-verified-v1"
SCHEMA_VERSION = 1
REVIEW_METHOD = "source-grounded multi-source audit"
REVIEWER = "译学 AI"
DEFAULT_INPUT = pathlib.Path("data/dictionary/editorial-assistant-curated-v1.jsonl")
DEFAULT_SOURCE_RECORDS = pathlib.Path("data/dictionary/editorial-source-records-v1.json")
DEFAULT_OUTPUT = pathlib.Path("data/dictionary/editorial-assistant-verified-v1.jsonl")
DEFAULT_REPORT = pathlib.Path(
    "data/dictionary/editorial-assistant-verified-v1.report.json"
)
DEFAULT_RUNTIME_OUTPUT = pathlib.Path("app/yixue_app/lib/core")
MAX_RUNTIME_FLAGS = 32
MAX_RUNTIME_SOURCE_IDS = 16
_CONTROL_RE = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f]")
_MISSING_IPA_VALUES = {"", "—", "-", "n/a", "na"}
_SOURCE_EVIDENCE_FIELDS = {
    "pronunciation",
    "part_of_speech",
    "senses",
    "english_examples",
    "bilingual_examples",
    "collocations",
    "relations",
    "variants",
}


def _mapping(value: object) -> Mapping[str, object]:
    return value if isinstance(value, Mapping) else {}


def _text(value: object) -> str:
    return value.strip() if isinstance(value, str) else ""


def _list(value: object) -> list[object]:
    return value if isinstance(value, list) else []


def _contains_bad_text(value: object) -> bool:
    if isinstance(value, str):
        return "\ufffd" in value or _CONTROL_RE.search(value) is not None
    if isinstance(value, Mapping):
        return any(
            _contains_bad_text(key) or _contains_bad_text(item)
            for key, item in value.items()
        )
    if isinstance(value, list):
        return any(_contains_bad_text(item) for item in value)
    return False


def _source_ids_from_manifest(path: pathlib.Path) -> set[str]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    records = payload.get("source_records") if isinstance(payload, Mapping) else None
    if not isinstance(records, list):
        raise ValueError("source manifest missing source_records list")
    result: set[str] = set()
    for index, record in enumerate(records):
        if not isinstance(record, Mapping):
            raise ValueError(f"source manifest record {index} is not an object")
        source_id = _text(record.get("id"))
        if not source_id:
            raise ValueError(f"source manifest record {index} has no id")
        if not _text(record.get("license")):
            raise ValueError(f"source manifest {source_id} has no license")
        if not _text(record.get("attribution")):
            raise ValueError(f"source manifest {source_id} has no attribution")
        result.add(source_id)
    if not result:
        raise ValueError("source manifest has no source IDs")
    return result


def _check_source_id(source_id: object, known_sources: set[str]) -> None:
    value = _text(source_id)
    if not value:
        raise ValueError("source_id is missing")
    if value not in known_sources:
        raise ValueError(f"unknown source_id {value}")


def _check_source_lists(entry: Mapping[str, object], known_sources: set[str]) -> None:
    source_ids = {_text(item) for item in _list(entry.get("source_ids"))}
    if not source_ids or "" in source_ids:
        raise ValueError(f"{_text(entry.get('lemma'))}: source_ids is empty")
    for source_id in source_ids:
        _check_source_id(source_id, known_sources)

    evidence = _mapping(entry.get("source_evidence"))
    missing = _SOURCE_EVIDENCE_FIELDS.difference(evidence)
    if missing:
        raise ValueError(
            f"{_text(entry.get('lemma'))}: source_evidence missing {sorted(missing)}"
        )
    for field in _SOURCE_EVIDENCE_FIELDS:
        values = _list(evidence.get(field))
        for source_id in values:
            _check_source_id(source_id, known_sources)

    for field in ("part_of_speech_candidates", "pronunciation_candidates"):
        for candidate in _list(entry.get(field)):
            if not isinstance(candidate, Mapping):
                raise ValueError(f"{_text(entry.get('lemma'))}: invalid {field}")
            if not _text(candidate.get("value")):
                raise ValueError(f"{_text(entry.get('lemma'))}: empty {field} value")
            _check_source_id(candidate.get("source_id"), known_sources)

    for field in ("english_examples", "bilingual_examples", "collocation_candidates"):
        for candidate in _list(entry.get(field)):
            if not isinstance(candidate, Mapping):
                raise ValueError(f"{_text(entry.get('lemma'))}: invalid {field}")
            _check_source_id(candidate.get("source_id"), known_sources)

    for candidate in _list(entry.get("variant_candidates")):
        if not isinstance(candidate, Mapping):
            raise ValueError(f"{_text(entry.get('lemma'))}: invalid variant_candidates")
        for source_id in _list(candidate.get("source_ids")):
            _check_source_id(source_id, known_sources)

    for sense in _list(entry.get("senses")):
        if not isinstance(sense, Mapping):
            raise ValueError(f"{_text(entry.get('lemma'))}: invalid sense")
        _check_source_id(sense.get("source_id"), known_sources)


def _usable_ipa(ipa: object) -> bool:
    if not isinstance(ipa, Mapping):
        return False
    values = [_text(value).casefold() for value in ipa.values()]
    return any(value and value not in _MISSING_IPA_VALUES for value in values)


def _core_checks(entry: Mapping[str, object]) -> dict[str, bool]:
    evidence = _mapping(entry.get("source_evidence"))
    senses = _list(entry.get("senses"))
    has_chinese_meaning = any(
        isinstance(sense, Mapping) and _list(sense.get("chinese_glosses"))
        for sense in senses
    )
    has_english_meaning = any(
        isinstance(sense, Mapping) and _list(sense.get("english_glosses"))
        for sense in senses
    )
    sense_sources = {
        _text(source_id) for source_id in _list(evidence.get("senses")) if _text(source_id)
    }
    pos_sources = {
        _text(source_id)
        for source_id in _list(evidence.get("part_of_speech"))
        if _text(source_id)
    }
    source_ids = {
        _text(source_id) for source_id in _list(entry.get("source_ids")) if _text(source_id)
    }
    return {
        "source_traceability": bool(source_ids),
        "license_boundary": bool(source_ids),
        "meaning_cross_source": len(sense_sources) >= 2
        and has_chinese_meaning
        and has_english_meaning,
        "part_of_speech": bool(_text(entry.get("part_of_speech")))
        and bool(_list(entry.get("part_of_speech_candidates")))
        and len(pos_sources) >= 2,
        "pronunciation": _usable_ipa(entry.get("ipa")),
        "content_integrity": not _contains_bad_text(entry),
    }


def _remaining_flags(
    entry: Mapping[str, object], checks: Mapping[str, bool] | None = None
) -> list[str]:
    flags: list[str] = [
        key for key, value in (checks or {}).items() if value is False
    ]
    if not _usable_ipa(entry.get("ipa")) and "pronunciation" not in flags:
        flags.append("pronunciation")
    if not _list(entry.get("pronunciation_candidates")):
        flags.append("pronunciation_candidates")
    if not _list(entry.get("english_examples")):
        flags.append("english_examples")
    if not _list(entry.get("bilingual_examples")):
        flags.append("bilingual_examples")
    if not _list(entry.get("collocations")):
        flags.append("collocations")
    if not _list(entry.get("variants")):
        flags.append("variants")
    if not _mapping(entry.get("relations")) or not any(
        _list(value) for value in _mapping(entry.get("relations")).values()
    ):
        flags.append("relations")
    return flags


def audit_entry(
    entry: Mapping[str, object],
    known_sources: set[str],
    *,
    reviewed_at: str | None = None,
) -> dict[str, object]:
    """Attach an independent assistant audit without changing source text."""

    result = dict(entry)
    lemma = _text(result.get("lemma"))
    if not lemma:
        raise ValueError("entry lemma is missing")
    if _mapping(result.get("quality")).get("human_review") is not False:
        raise ValueError(f"{lemma}: human_review must remain false")
    if _mapping(result.get("quality")).get("status") != "assistant_curated_draft":
        raise ValueError(f"{lemma}: input quality status must remain assistant_curated_draft")
    _check_source_lists(result, known_sources)
    checks = _core_checks(result)

    remaining_flags = _remaining_flags(result, checks)
    result["assistant_review"] = {
        "schema_version": SCHEMA_VERSION,
        "status": "assistant_verified" if all(checks.values()) else "assistant_verified_with_gaps",
        "review_method": REVIEW_METHOD,
        "reviewer": REVIEWER,
        "reviewed_at": reviewed_at or _datetime.date.today().isoformat(),
        "scope": "来源可追溯、许可证边界、核心义项/词性/音标和文本完整性核对；扩展字段缺口保留并显式标注。",
        "checks": checks,
        "remaining_flags": remaining_flags,
    }
    return result


def build_runtime_review_rows(
    entries: Iterable[Mapping[str, object]],
) -> list[dict[str, object]]:
    """Build a small word-keyed approval index for the Flutter runtime."""

    rows: list[dict[str, object]] = []
    seen: set[str] = set()
    for entry in entries:
        word = _text(entry.get("lemma")).lower()
        review = _mapping(entry.get("assistant_review"))
        if not word or word in seen:
            raise ValueError(f"duplicate or empty runtime word: {word}")
        if review.get("status") not in {
            "assistant_verified",
            "assistant_verified_with_gaps",
        }:
            raise ValueError(f"{word}: entry is not assistant verified")
        seen.add(word)
        rows.append(
            {
                "word": word,
                "quality_status": _text(review.get("status")),
                "remaining_flags": [
                    _text(value)
                    for value in _list(review.get("remaining_flags"))
                    if _text(value)
                ][:MAX_RUNTIME_FLAGS],
                "source_ids": [
                    _text(value)
                    for value in _list(entry.get("source_ids"))
                    if _text(value)
                ][:MAX_RUNTIME_SOURCE_IDS],
            }
        )
    rows.sort(key=lambda row: str(row["word"]))
    return rows


def _dart_quote(value: str) -> str:
    escaped = (
        value.replace("\\", "\\\\")
        .replace("'", "\\'")
        .replace("$", "\\$")
        .replace("\r", "\\r")
        .replace("\n", "\\n")
    )
    return f"'{escaped}'"


def render_runtime_review_shard(
    rows: Iterable[Mapping[str, object]], part_number: int
) -> str:
    lines = [
        "// GENERATED FILE. Do not edit by hand.",
        "// Assistant verification index; this is not human-review publication.",
        "import 'dictionary_cet_open_rich_examples_model.dart';",
        "",
        f"const yxOpenCetAssistantReviewRowsPart{part_number:02d} = <String, OpenCetAssistantReviewRow>{{",
    ]
    for row in rows:
        word = _text(row.get("word"))
        lines.extend(
            [
                f"  {_dart_quote(word)}: OpenCetAssistantReviewRow(",
                f"    qualityStatus: {_dart_quote(_text(row.get('quality_status')))},",
                "    remainingFlags: <String>[",
            ]
        )
        for flag in _list(row.get("remaining_flags")):
            lines.append(f"      {_dart_quote(_text(flag))},")
        lines.extend(["    ],", "    sourceIds: <String>["])
        for source_id in _list(row.get("source_ids")):
            lines.append(f"      {_dart_quote(_text(source_id))},")
        lines.extend(["    ],", "  ),"])
    lines.extend(["};", ""])
    return "\n".join(lines)


def render_runtime_review_index(part_count: int) -> str:
    imports = "\n".join(
        f"import 'dictionary_cet_open_assistant_verified_part{index:02d}.dart';"
        for index in range(1, part_count + 1)
    )
    spreads = ",\n  ".join(
        f"...yxOpenCetAssistantReviewRowsPart{index:02d}"
        for index in range(1, part_count + 1)
    )
    return (
        "// GENERATED FILE. Do not edit by hand.\n"
        "// Every row is an independently auditable assistant-verification result.\n"
        "import 'dictionary_cet_open_rich_examples_model.dart';\n"
        f"{imports}\n\n"
        "const yxOpenCetAssistantReviewRows = <String, OpenCetAssistantReviewRow>{\n"
        f"  {spreads},\n"
        "};\n"
    )


def _report_from_entries(entries: Iterable[Mapping[str, object]]) -> dict[str, Any]:
    total = 0
    status_counts: Counter[str] = Counter()
    gap_counts: Counter[str] = Counter()
    check_counts: Counter[str] = Counter()
    source_counts: Counter[str] = Counter()
    for entry in entries:
        total += 1
        review = _mapping(entry.get("assistant_review"))
        status_counts[_text(review.get("status"))] += 1
        gap_counts.update(
            _text(flag)
            for flag in _list(review.get("remaining_flags"))
            if _text(flag)
        )
        check_counts.update(
            key
            for key, value in _mapping(review.get("checks")).items()
            if value is True
        )
        source_counts.update(
            _text(source_id)
            for source_id in _list(entry.get("source_ids"))
            if _text(source_id)
        )
    return {
        "schema_version": SCHEMA_VERSION,
        "layer": LAYER,
        "total_entries": total,
        "assistant_verified_entries": status_counts["assistant_verified"],
        "assistant_verified_with_gaps_entries": status_counts[
            "assistant_verified_with_gaps"
        ],
        "runtime_import_ready_entries": sum(status_counts.values()),
        "human_reviewed_entries": 0,
        "published_entries": 0,
        "status_counts": dict(sorted(status_counts.items())),
        "remaining_gap_counts": dict(sorted(gap_counts.items())),
        "passed_core_check_counts": dict(sorted(check_counts.items())),
        "source_id_counts": dict(sorted(source_counts.items())),
        "formal_release_ready": False,
        "human_review_required": False,
        "rule": "assistant_verified 仅表示译学 AI 已按开放来源完成结构与核心字段核对；不等同人工审校，不复制牛津受版权保护的词条内容。",
    }


def build_report(entries: Iterable[Mapping[str, object]]) -> dict[str, Any]:
    return _report_from_entries(entries)


def _write_runtime_index(
    rows: list[dict[str, object]], output_dir: pathlib.Path, part_count: int
) -> None:
    if part_count < 1:
        raise ValueError("part_count must be positive")
    output_dir.mkdir(parents=True, exist_ok=True)
    chunks = [rows[index::part_count] for index in range(part_count)]
    for index, chunk in enumerate(chunks, start=1):
        (output_dir / f"dictionary_cet_open_assistant_verified_part{index:02d}.dart").write_text(
            render_runtime_review_shard(chunk, index), encoding="utf-8", newline="\n"
        )
    (output_dir / "dictionary_cet_open_assistant_verified.dart").write_text(
        render_runtime_review_index(part_count), encoding="utf-8", newline="\n"
    )


def build_assistant_verified_layer(
    input_path: pathlib.Path,
    source_records_path: pathlib.Path,
    output_path: pathlib.Path,
    report_path: pathlib.Path,
    *,
    runtime_output_dir: pathlib.Path | None = None,
    part_count: int = 8,
) -> dict[str, Any]:
    known_sources = _source_ids_from_manifest(source_records_path)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    runtime_rows: list[dict[str, object]] = []
    audited_entries: list[dict[str, object]] = []
    with input_path.open("r", encoding="utf-8") as source, output_path.open(
        "w", encoding="utf-8", newline="\n"
    ) as target:
        for line_number, line in enumerate(source, start=1):
            if not line.strip():
                raise ValueError(f"line {line_number}: blank line")
            try:
                entry = json.loads(line)
            except json.JSONDecodeError as exc:
                raise ValueError(f"line {line_number}: invalid JSON") from exc
            if not isinstance(entry, Mapping):
                raise ValueError(f"line {line_number}: entry must be an object")
            audited = audit_entry(entry, known_sources)
            target.write(json.dumps(audited, ensure_ascii=False, sort_keys=True) + "\n")
            audited_entries.append(audited)
            runtime_rows.append(audited)

    report = _report_from_entries(audited_entries)
    report.update(
        {
            "input_layer": input_path.as_posix(),
            "output_layer": output_path.as_posix(),
            "source_records": source_records_path.as_posix(),
            "runtime_index_entries": len(runtime_rows),
            "review_method": REVIEW_METHOD,
            "reviewer": REVIEWER,
        }
    )
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    if runtime_output_dir is not None:
        _write_runtime_index(
            build_runtime_review_rows(runtime_rows), runtime_output_dir, part_count
        )
    return report


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=pathlib.Path, default=DEFAULT_INPUT)
    parser.add_argument(
        "--source-records", type=pathlib.Path, default=DEFAULT_SOURCE_RECORDS
    )
    parser.add_argument("--output", type=pathlib.Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--report-output", type=pathlib.Path, default=DEFAULT_REPORT)
    parser.add_argument(
        "--runtime-output-dir", type=pathlib.Path, default=DEFAULT_RUNTIME_OUTPUT
    )
    parser.add_argument("--parts", type=int, default=8)
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    try:
        report = build_assistant_verified_layer(
            args.input,
            args.source_records,
            args.output,
            args.report_output,
            runtime_output_dir=args.runtime_output_dir,
            part_count=args.parts,
        )
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"ASSISTANT_VERIFIED_BUILD_FAIL: {exc}")
        return 1
    print("ASSISTANT_VERIFIED_BUILD_PASS")
    print(json.dumps(report, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
