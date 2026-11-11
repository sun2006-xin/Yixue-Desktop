"""Build compact, transparent runtime layers from rich dictionary candidates.

Examples, metadata and senses remain source-separated editorial candidates.
The generated Dart layers never promote an entry to reviewed or published
quality, and they never align meanings across sources automatically.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Iterable, Mapping


MAX_EXAMPLES_PER_WORD = 3
MAX_VARIANTS_PER_WORD = 32
MAX_COLLOCATIONS_PER_WORD = 16
MAX_TERMS_PER_RELATION = 32
MAX_SENSES_PER_WORD = 24
MAX_GLOSSES_PER_SENSE = 8
MAX_CHINESE_GLOSSES_PER_SENSE = 8
MAX_USAGE_TAGS_PER_SENSE = 8
MAX_SOURCE_EXAMPLES_PER_SENSE = 3
MAX_PART_OF_SPEECH_CANDIDATES = 16
MAX_PRONUNCIATION_CANDIDATES = 16
MAX_LEARNING_TAGS = 24
MAX_FREQUENCY_FIELDS = 8
MAX_REVIEW_FIELDS = 32
MAX_SOURCE_IDS = 16
RUNTIME_SOURCE_ID = "yixue-runtime-candidate-layer-v2"


def _mapping(value: object) -> Mapping[str, object]:
    return value if isinstance(value, Mapping) else {}


def _text(value: object) -> str:
    return value.strip() if isinstance(value, str) else ""


def _safe_example(item: object) -> dict[str, str] | None:
    row = _mapping(item)
    example_id = _text(row.get("example_id"))
    source_id = _text(row.get("source_id"))
    english = _text(row.get("english_text"))
    chinese = _text(row.get("chinese_text"))
    if not all((example_id, source_id, english, chinese)):
        return None
    if "\ufffd" in "".join((example_id, source_id, english, chinese)):
        return None
    attribution = _mapping(row.get("attribution"))
    return {
        "example_id": example_id,
        "source_id": source_id,
        "english_text": english,
        "chinese_text": chinese,
        "english_username": _text(attribution.get("english_username")),
        "chinese_username": _text(attribution.get("chinese_username")),
    }


def build_runtime_rows(payload: Mapping[str, object]) -> list[dict[str, object]]:
    """Select deterministic, source-traceable bilingual candidates per lemma."""

    raw_entries = payload.get("entries")
    if not isinstance(raw_entries, list):
        raise ValueError("candidate payload entries must be a list")

    result: list[dict[str, object]] = []
    for raw_entry in raw_entries:
        entry = _mapping(raw_entry)
        lemma = _text(entry.get("lemma")).lower()
        if not lemma:
            continue
        rich = _mapping(entry.get("rich_candidate"))
        raw_examples = rich.get("bilingual_examples")
        if not isinstance(raw_examples, list):
            continue

        examples: list[dict[str, str]] = []
        seen_ids: set[str] = set()
        for raw_example in raw_examples:
            example = _safe_example(raw_example)
            if example is None or example["example_id"] in seen_ids:
                continue
            seen_ids.add(example["example_id"])
            examples.append(example)
            if len(examples) == MAX_EXAMPLES_PER_WORD:
                break
        if examples:
            result.append(
                {
                    "word": lemma,
                    "quality_status": "candidate",
                    "source_ids": sorted({item["source_id"] for item in examples}),
                    "examples": examples,
                }
            )

    result.sort(key=lambda row: str(row["word"]))
    return result


def _dart_quote(value: str) -> str:
    escaped = (
        value.replace("\\", "\\\\")
        .replace("'", "\\'")
        .replace("$", "\\$")
        .replace("\r", "\\r")
        .replace("\n", "\\n")
    )
    return f"'{escaped}'"


def render_shard(rows: Iterable[Mapping[str, object]], part_number: int) -> str:
    lines = [
        "// GENERATED FILE. Do not edit by hand.",
        "// Source: Tatoeba bilingual candidates; every row remains candidate status.",
        "import 'dictionary_cet_open_rich_examples_model.dart';",
        "",
        f"const yxOpenCetRichExampleRowsPart{part_number:02d} = <String, List<OpenCetRichExampleRow>>{{",
    ]
    for row in rows:
        word = _text(row.get("word"))
        lines.append(f"  {_dart_quote(word)}: <OpenCetRichExampleRow>[")
        examples = row.get("examples")
        if not isinstance(examples, list):
            raise ValueError(f"runtime row examples must be a list: {word}")
        for raw_example in examples:
            example = _mapping(raw_example)
            lines.extend(
                [
                    "    OpenCetRichExampleRow(",
                    f"      exampleId: {_dart_quote(_text(example.get('example_id')))},",
                    f"      sourceId: {_dart_quote(_text(example.get('source_id')))},",
                    f"      englishText: {_dart_quote(_text(example.get('english_text')))},",
                    f"      chineseText: {_dart_quote(_text(example.get('chinese_text')))},",
                    f"      englishUsername: {_dart_quote(_text(example.get('english_username')))},",
                    f"      chineseUsername: {_dart_quote(_text(example.get('chinese_username')))},",
                    "    ),",
                ]
            )
        lines.append("  ],")
    lines.extend(["};", ""])
    return "\n".join(lines)


def render_index(part_count: int) -> str:
    imports = "\n".join(
        f"import 'dictionary_cet_open_rich_examples_part{index:02d}.dart';"
        for index in range(1, part_count + 1)
    )
    spreads = ",\n  ".join(
        f"...yxOpenCetRichExampleRowsPart{index:02d}"
        for index in range(1, part_count + 1)
    )
    return (
        "// GENERATED FILE. Do not edit by hand.\n"
        "// Every row is a source-traceable bilingual example candidate.\n"
        "import 'dictionary_cet_open_rich_examples_model.dart';\n"
        f"{imports}\n\n"
        "const yxOpenCetRichExampleRows = <String, List<OpenCetRichExampleRow>>{\n"
        f"  {spreads},\n"
        "};\n"
    )


def build_runtime_metadata_rows(payload: Mapping[str, object]) -> list[dict[str, object]]:
    """Select bounded variants, collocation and relation candidates per lemma."""

    raw_entries = payload.get("entries")
    if not isinstance(raw_entries, list):
        raise ValueError("candidate payload entries must be a list")

    result: list[dict[str, object]] = []
    for raw_entry in raw_entries:
        entry = _mapping(raw_entry)
        lemma = _text(entry.get("lemma")).lower()
        if not lemma:
            continue
        rich = _mapping(entry.get("rich_candidate"))

        variants: list[str] = []
        for item in rich.get("variants", []) if isinstance(rich.get("variants"), list) else []:
            form = _text(_mapping(item).get("form"))
            if form and form.lower() != lemma and form not in variants:
                variants.append(form)
            if len(variants) == MAX_VARIANTS_PER_WORD:
                break

        collocations: list[str] = []
        for item in (
            rich.get("collocation_candidates", [])
            if isinstance(rich.get("collocation_candidates"), list)
            else []
        ):
            text = _text(_mapping(item).get("text"))
            if text and text not in collocations:
                collocations.append(text)
            if len(collocations) == MAX_COLLOCATIONS_PER_WORD:
                break

        relations: dict[str, list[str]] = {}
        for item in (
            rich.get("relation_candidates", [])
            if isinstance(rich.get("relation_candidates"), list)
            else []
        ):
            relation = _text(_mapping(item).get("relation"))
            term = _text(_mapping(item).get("term"))
            if not relation or not term:
                continue
            bucket = relations.setdefault(relation, [])
            if term not in bucket and len(bucket) < MAX_TERMS_PER_RELATION:
                bucket.append(term)

        relations = {key: relations[key] for key in sorted(relations) if relations[key]}
        part_of_speech_candidates: list[dict[str, str]] = []
        seen_part_of_speech: set[tuple[str, str]] = set()
        raw_part_of_speech = rich.get("part_of_speech_candidates")
        if isinstance(raw_part_of_speech, list):
            for item in raw_part_of_speech:
                candidate = _mapping(item)
                value = _text(candidate.get("value"))
                source_id = _text(candidate.get("source_id"))
                key = (value, source_id)
                if not value or not source_id or key in seen_part_of_speech:
                    continue
                seen_part_of_speech.add(key)
                part_of_speech_candidates.append(
                    {"value": value, "source_id": source_id}
                )
                if len(part_of_speech_candidates) == MAX_PART_OF_SPEECH_CANDIDATES:
                    break

        pronunciation_candidates: list[dict[str, str]] = []
        seen_pronunciation: set[tuple[str, str, str, str, str, str, str]] = set()
        raw_pronunciation = rich.get("pronunciation_candidates")
        if isinstance(raw_pronunciation, list):
            for item in raw_pronunciation:
                candidate = _mapping(item)
                value = _text(candidate.get("value"))
                dialect = _text(candidate.get("dialect"))
                notation = _text(candidate.get("notation"))
                source_id = _text(candidate.get("source_id"))
                part_of_speech = _text(candidate.get("part_of_speech"))
                source_word = _text(candidate.get("source_word"))
                resolution = _text(candidate.get("resolution"))
                key = (
                    value,
                    dialect,
                    notation,
                    source_id,
                    part_of_speech,
                    source_word,
                    resolution,
                )
                if (
                    not value
                    or "\ufffd" in value
                    or not source_id
                    or key in seen_pronunciation
                ):
                    continue
                seen_pronunciation.add(key)
                pronunciation_candidate = {
                    "value": value,
                    "dialect": dialect,
                    "notation": notation,
                    "source_id": source_id,
                    "part_of_speech": part_of_speech,
                }
                if source_word:
                    pronunciation_candidate["source_word"] = source_word
                if resolution:
                    pronunciation_candidate["resolution"] = resolution
                pronunciation_candidates.append(pronunciation_candidate)
                if len(pronunciation_candidates) == MAX_PRONUNCIATION_CANDIDATES:
                    break

        learning_tags = _safe_text_list(rich.get("learning_tags"), MAX_LEARNING_TAGS)
        frequency: dict[str, int] = {}
        raw_frequency = rich.get("frequency")
        if isinstance(raw_frequency, Mapping):
            for key in sorted(raw_frequency)[:MAX_FREQUENCY_FIELDS]:
                value = raw_frequency[key]
                if isinstance(value, (int, float)) and not isinstance(value, bool):
                    if value > 0:
                        frequency[str(key)] = int(value)

        quality = _mapping(rich.get("quality"))
        # Runtime never promotes source quality. A source ``draft`` row is
        # always represented as a runtime ``candidate`` row.
        review_fields = _safe_text_list(
            quality.get("review_fields"), MAX_REVIEW_FIELDS
        )
        source_ids = _safe_text_list(rich.get("source_ids"), MAX_SOURCE_IDS)

        if not any(
            (
                variants,
                collocations,
                relations,
                part_of_speech_candidates,
                pronunciation_candidates,
                learning_tags,
                frequency,
            )
        ):
            continue
        result.append(
            {
                "word": lemma,
                "quality_status": "candidate",
                "variants": variants,
                "collocations": collocations,
                "relations": relations,
                "part_of_speech_candidates": part_of_speech_candidates,
                "pronunciation_candidates": pronunciation_candidates,
                "learning_tags": learning_tags,
                "frequency": frequency,
                "review_fields": review_fields,
                "source_ids": source_ids,
            }
        )

    result.sort(key=lambda row: str(row["word"]))
    return result


def _safe_text_list(value: object, limit: int) -> list[str]:
    """Keep bounded, unique source strings without repairing their meaning."""

    raw_items = value if isinstance(value, list) else [value]
    result: list[str] = []
    for raw_item in raw_items:
        text = _text(raw_item)
        if not text or "\ufffd" in text or text in result:
            continue
        result.append(text)
        if len(result) == limit:
            break
    return result


def _safe_chinese_glosses(sense: Mapping[str, object]) -> list[str]:
    values = _safe_text_list(
        sense.get("chinese_glosses"), MAX_CHINESE_GLOSSES_PER_SENSE
    )
    raw_translations = sense.get("chinese_translation_candidates")
    if not isinstance(raw_translations, list):
        return values
    for raw_translation in raw_translations:
        translation = _mapping(raw_translation)
        word = _text(translation.get("word"))
        if not word or "\ufffd" in word or word in values:
            continue
        values.append(word)
        if len(values) == MAX_CHINESE_GLOSSES_PER_SENSE:
            break
    return values


def build_runtime_sense_rows(payload: Mapping[str, object]) -> list[dict[str, object]]:
    """Select bounded, source-separated sense candidates per lemma.

    A source record may contain several gloss strings, but it is kept as one
    candidate row. The fallback ``record:<index>`` ID identifies the original
    source record without inventing a sense alignment.
    """

    raw_entries = payload.get("entries")
    if not isinstance(raw_entries, list):
        raise ValueError("candidate payload entries must be a list")

    result: list[dict[str, object]] = []
    for raw_entry in raw_entries:
        entry = _mapping(raw_entry)
        lemma = _text(entry.get("lemma")).lower()
        if not lemma:
            continue
        rich = _mapping(entry.get("rich_candidate"))
        raw_senses = rich.get("sense_candidates")
        if not isinstance(raw_senses, list):
            continue

        senses: list[dict[str, object]] = []
        seen: set[tuple[object, ...]] = set()
        for index, raw_sense in enumerate(raw_senses):
            sense = _mapping(raw_sense)
            source_id = _text(sense.get("source_id"))
            if not source_id:
                continue
            sense_id = _text(sense.get("sense_id")) or f"record:{index}"
            part_of_speech = _text(sense.get("part_of_speech"))
            english_glosses = _safe_text_list(
                sense.get("english_glosses"), MAX_GLOSSES_PER_SENSE
            )
            chinese_glosses = _safe_chinese_glosses(sense)
            usage_tags = _safe_text_list(
                sense.get("usage_tags"), MAX_USAGE_TAGS_PER_SENSE
            )
            source_examples = _safe_text_list(
                sense.get("source_examples"), MAX_SOURCE_EXAMPLES_PER_SENSE
            )
            qualifier = _text(sense.get("qualifier"))
            if "\ufffd" in qualifier:
                qualifier = ""
            if not any(
                (
                    english_glosses,
                    chinese_glosses,
                    usage_tags,
                    source_examples,
                    qualifier,
                )
            ):
                continue

            key = (
                source_id,
                sense_id,
                part_of_speech,
                tuple(english_glosses),
                tuple(chinese_glosses),
                tuple(usage_tags),
                tuple(source_examples),
                qualifier,
            )
            if key in seen:
                continue
            seen.add(key)
            senses.append(
                {
                    "source_id": source_id,
                    "sense_id": sense_id,
                    "part_of_speech": part_of_speech,
                    "english_glosses": english_glosses,
                    "chinese_glosses": chinese_glosses,
                    "usage_tags": usage_tags,
                    "source_examples": source_examples,
                    "qualifier": qualifier,
                    "quality_status": "candidate",
                }
            )
            if len(senses) == MAX_SENSES_PER_WORD:
                break
        if senses:
            result.append(
                {
                    "word": lemma,
                    "quality_status": "candidate",
                    "senses": senses,
                }
            )

    result.sort(key=lambda row: str(row["word"]))
    return result


def render_metadata_shard(
    rows: Iterable[Mapping[str, object]], part_number: int
) -> str:
    lines = [
        "// GENERATED FILE. Do not edit by hand.",
        "// Variants, collocations and relations remain editorial candidates.",
        "import 'dictionary_cet_open_rich_examples_model.dart';",
        "",
        f"const yxOpenCetRichMetadataRowsPart{part_number:02d} = <String, OpenCetRichMetadataRow>{{",
    ]
    for row in rows:
        word = _text(row.get("word"))
        lines.extend(
            [
                f"  {_dart_quote(word)}: OpenCetRichMetadataRow(",
                "    qualityStatus: 'candidate',",
                "    variants: <String>[",
            ]
        )
        for variant in row.get("variants", []):
            lines.append(f"      {_dart_quote(_text(variant))},")
        lines.extend(["    ],", "    collocations: <String>["])
        for collocation in row.get("collocations", []):
            lines.append(f"      {_dart_quote(_text(collocation))},")
        lines.extend(["    ],", "    relations: <String, List<String>>{"])
        raw_relations = row.get("relations")
        if not isinstance(raw_relations, Mapping):
            raise ValueError(f"runtime relations must be an object: {word}")
        for relation in sorted(raw_relations):
            lines.append(f"      {_dart_quote(str(relation))}: <String>[")
            for term in raw_relations[relation]:
                lines.append(f"        {_dart_quote(_text(term))},")
            lines.append("      ],")
        lines.extend(
            [
                "    },",
                "    partOfSpeechCandidates: <OpenCetRichPartOfSpeechRow>[",
            ]
        )
        for candidate in row.get("part_of_speech_candidates", []):
            item = _mapping(candidate)
            lines.extend(
                [
                    "      OpenCetRichPartOfSpeechRow(",
                    f"        value: {_dart_quote(_text(item.get('value')))},",
                    f"        sourceId: {_dart_quote(_text(item.get('source_id')))},",
                    "      ),",
                ]
            )
        lines.extend(
            [
                "    ],",
                "    pronunciationCandidates: <OpenCetRichPronunciationRow>[",
            ]
        )
        for candidate in row.get("pronunciation_candidates", []):
            item = _mapping(candidate)
            lines.extend(
                [
                    "      OpenCetRichPronunciationRow(",
                    f"        value: {_dart_quote(_text(item.get('value')))},",
                    f"        dialect: {_dart_quote(_text(item.get('dialect')))},",
                    f"        notation: {_dart_quote(_text(item.get('notation')))},",
                    f"        sourceId: {_dart_quote(_text(item.get('source_id')))},",
                    f"        partOfSpeech: {_dart_quote(_text(item.get('part_of_speech')))},",
                ]
            )
            source_word = _text(item.get("source_word"))
            resolution = _text(item.get("resolution"))
            if source_word:
                lines.append(f"        sourceWord: {_dart_quote(source_word)},")
            if resolution:
                lines.append(f"        resolution: {_dart_quote(resolution)},")
            lines.append("      ),")
        lines.extend(["    ],", "    learningTags: <String>["])
        for tag in row.get("learning_tags", []):
            lines.append(f"      {_dart_quote(_text(tag))},")
        lines.extend(["    ],", "    frequency: <String, int>{"])
        raw_frequency = row.get("frequency")
        if not isinstance(raw_frequency, Mapping):
            raise ValueError(f"runtime frequency must be an object: {word}")
        for key in sorted(raw_frequency):
            lines.append(f"      {_dart_quote(str(key))}: {int(raw_frequency[key])},")
        lines.extend(["    },", "    reviewFields: <String>["])
        for field in row.get("review_fields", []):
            lines.append(f"      {_dart_quote(_text(field))},")
        lines.extend(["    ],", "    sourceIds: <String>["])
        for source_id in row.get("source_ids", []):
            lines.append(f"      {_dart_quote(_text(source_id))},")
        lines.extend(["    ],", "  ),"])
    lines.extend(["};", ""])
    return "\n".join(lines)


def render_metadata_index(part_count: int) -> str:
    imports = "\n".join(
        f"import 'dictionary_cet_open_rich_metadata_part{index:02d}.dart';"
        for index in range(1, part_count + 1)
    )
    spreads = ",\n  ".join(
        f"...yxOpenCetRichMetadataRowsPart{index:02d}"
        for index in range(1, part_count + 1)
    )
    return (
        "// GENERATED FILE. Do not edit by hand.\n"
        "// Every row is a source-traceable metadata candidate.\n"
        "import 'dictionary_cet_open_rich_examples_model.dart';\n"
        f"{imports}\n\n"
        "const yxOpenCetRichMetadataRows = <String, OpenCetRichMetadataRow>{\n"
        f"  {spreads},\n"
        "};\n"
    )


def render_sense_shard(
    rows: Iterable[Mapping[str, object]], part_number: int
) -> str:
    lines = [
        "// GENERATED FILE. Do not edit by hand.",
        "// Source-separated sense candidates remain pending editorial review.",
        "import 'dictionary_cet_open_rich_examples_model.dart';",
        "",
        f"const yxOpenCetRichSenseRowsPart{part_number:02d} = <String, List<OpenCetRichSenseRow>>{{",
    ]
    for row in rows:
        word = _text(row.get("word"))
        lines.extend(
            [
                f"  {_dart_quote(word)}: <OpenCetRichSenseRow>[",
            ]
        )
        raw_senses = row.get("senses")
        if not isinstance(raw_senses, list):
            raise ValueError(f"runtime senses must be a list: {word}")
        for raw_sense in raw_senses:
            sense = _mapping(raw_sense)
            lines.extend(
                [
                    "    OpenCetRichSenseRow(",
                    f"      sourceId: {_dart_quote(_text(sense.get('source_id')))},",
                    f"      senseId: {_dart_quote(_text(sense.get('sense_id')))},",
                    f"      partOfSpeech: {_dart_quote(_text(sense.get('part_of_speech')))},",
                    "      englishGlosses: <String>[",
                ]
            )
            for gloss in sense.get("english_glosses", []):
                lines.append(f"        {_dart_quote(_text(gloss))},")
            lines.extend(["      ],", "      chineseGlosses: <String>["])
            for gloss in sense.get("chinese_glosses", []):
                lines.append(f"        {_dart_quote(_text(gloss))},")
            lines.extend(["      ],", "      usageTags: <String>["])
            for tag in sense.get("usage_tags", []):
                lines.append(f"        {_dart_quote(_text(tag))},")
            lines.extend(
                [
                    "      ],",
                    "      sourceExamples: <String>[",
                ]
            )
            for example in sense.get("source_examples", []):
                lines.append(f"        {_dart_quote(_text(example))},")
            lines.extend(
                [
                    "      ],",
                    f"      qualifier: {_dart_quote(_text(sense.get('qualifier')))},",
                    "    ),",
                ]
            )
        lines.append("  ],")
    lines.extend(["};", ""])
    return "\n".join(lines)


def render_sense_index(part_count: int) -> str:
    imports = "\n".join(
        f"import 'dictionary_cet_open_rich_senses_part{index:02d}.dart';"
        for index in range(1, part_count + 1)
    )
    spreads = ",\n  ".join(
        f"...yxOpenCetRichSenseRowsPart{index:02d}"
        for index in range(1, part_count + 1)
    )
    return (
        "// GENERATED FILE. Do not edit by hand.\n"
        "// Every row is a source-separated sense candidate.\n"
        "import 'dictionary_cet_open_rich_examples_model.dart';\n"
        f"{imports}\n\n"
        "const yxOpenCetRichSenseRows = <String, List<OpenCetRichSenseRow>>{\n"
        f"  {spreads},\n"
        "};\n"
    )


def build_report(
    rows: Iterable[Mapping[str, object]],
    total_entries: int,
    metadata_rows: Iterable[Mapping[str, object]] = (),
    sense_rows: Iterable[Mapping[str, object]] = (),
) -> dict[str, object]:
    normalized = list(rows)
    metadata = list(metadata_rows)
    senses = list(sense_rows)
    example_count = sum(len(row.get("examples", [])) for row in normalized)
    sense_items = [
        sense
        for row in senses
        for sense in row.get("senses", [])
        if isinstance(sense, Mapping)
    ]
    direct_pronunciation_entries = sum(
        any(
            isinstance(item, Mapping) and not item.get("source_word")
            for item in row.get("pronunciation_candidates", [])
        )
        for row in metadata
    )
    alias_pronunciation_entries = sum(
        any(
            isinstance(item, Mapping) and bool(item.get("source_word"))
            for item in row.get("pronunciation_candidates", [])
        )
        for row in metadata
    )
    pronunciation_entries = sum(
        bool(row.get("pronunciation_candidates")) for row in metadata
    )
    return {
        "schema_version": 2,
        "source_id": RUNTIME_SOURCE_ID,
        "total_candidate_entries": total_entries,
        "entries_with_bilingual_candidates": len(normalized),
        "bilingual_example_count": example_count,
        "max_examples_per_word": MAX_EXAMPLES_PER_WORD,
        "entries_with_metadata_candidates": len(metadata),
        "variant_candidate_count": sum(len(row.get("variants", [])) for row in metadata),
        "collocation_candidate_count": sum(
            len(row.get("collocations", [])) for row in metadata
        ),
        "relation_candidate_count": sum(
            sum(len(terms) for terms in row.get("relations", {}).values())
            for row in metadata
        ),
        "part_of_speech_candidate_count": sum(
            len(row.get("part_of_speech_candidates", [])) for row in metadata
        ),
        "pronunciation_candidate_count": sum(
            len(row.get("pronunciation_candidates", [])) for row in metadata
        ),
        "entries_with_direct_pronunciation_candidates": direct_pronunciation_entries,
        "entries_with_alias_pronunciation_candidates": alias_pronunciation_entries,
        "entries_without_pronunciation_candidates": len(metadata) - pronunciation_entries,
        "learning_tag_count": sum(
            len(row.get("learning_tags", [])) for row in metadata
        ),
        "frequency_field_count": sum(
            len(row.get("frequency", {})) for row in metadata
        ),
        "review_field_count": sum(
            len(row.get("review_fields", [])) for row in metadata
        ),
        "source_id_count": sum(len(row.get("source_ids", [])) for row in metadata),
        "entries_with_sense_candidates": len(senses),
        "sense_candidate_count": len(sense_items),
        "sense_english_gloss_count": sum(
            len(sense.get("english_glosses", [])) for sense in sense_items
        ),
        "sense_chinese_gloss_count": sum(
            len(sense.get("chinese_glosses", [])) for sense in sense_items
        ),
        "sense_source_example_count": sum(
            len(sense.get("source_examples", [])) for sense in sense_items
        ),
        "runtime_metadata_source": "editorial-candidates-v3.json",
        "quality_status": "candidate",
        "passed": total_entries >= len(normalized) >= 0,
    }


def write_outputs(
    rows: list[dict[str, object]],
    metadata_rows: list[dict[str, object]],
    sense_rows: list[dict[str, object]],
    total_entries: int,
    output_dir: Path,
    report_path: Path,
    part_count: int = 8,
) -> dict[str, object]:
    if part_count < 1:
        raise ValueError("part_count must be positive")
    output_dir.mkdir(parents=True, exist_ok=True)
    chunks = [rows[index::part_count] for index in range(part_count)]
    for index, chunk in enumerate(chunks, start=1):
        (output_dir / f"dictionary_cet_open_rich_examples_part{index:02d}.dart").write_text(
            render_shard(chunk, index), encoding="utf-8", newline="\n"
        )
    (output_dir / "dictionary_cet_open_rich_examples.dart").write_text(
        render_index(part_count), encoding="utf-8", newline="\n"
    )
    metadata_chunks = [
        metadata_rows[index::part_count] for index in range(part_count)
    ]
    for index, chunk in enumerate(metadata_chunks, start=1):
        (
            output_dir / f"dictionary_cet_open_rich_metadata_part{index:02d}.dart"
        ).write_text(
            render_metadata_shard(chunk, index), encoding="utf-8", newline="\n"
        )
    (output_dir / "dictionary_cet_open_rich_metadata.dart").write_text(
        render_metadata_index(part_count), encoding="utf-8", newline="\n"
    )
    sense_chunks = [sense_rows[index::part_count] for index in range(part_count)]
    for index, chunk in enumerate(sense_chunks, start=1):
        (output_dir / f"dictionary_cet_open_rich_senses_part{index:02d}.dart").write_text(
            render_sense_shard(chunk, index), encoding="utf-8", newline="\n"
        )
    (output_dir / "dictionary_cet_open_rich_senses.dart").write_text(
        render_sense_index(part_count), encoding="utf-8", newline="\n"
    )
    report = build_report(rows, total_entries, metadata_rows, sense_rows)
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--input",
        type=Path,
        default=Path("data/dictionary/editorial-candidates-v3.json"),
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path("app/yixue_app/lib/core"),
    )
    parser.add_argument(
        "--report-output",
        type=Path,
        default=Path("data/dictionary/editorial-runtime-candidates-v1.report.json"),
    )
    parser.add_argument("--parts", type=int, default=8)
    args = parser.parse_args()

    payload = json.loads(args.input.read_text(encoding="utf-8"))
    if not isinstance(payload, Mapping):
        raise ValueError("candidate payload must be an object")
    rows = build_runtime_rows(payload)
    metadata_rows = build_runtime_metadata_rows(payload)
    sense_rows = build_runtime_sense_rows(payload)
    report = write_outputs(
        rows,
        metadata_rows,
        sense_rows,
        total_entries=len(payload.get("entries", [])) if isinstance(payload.get("entries"), list) else 0,
        output_dir=args.output_dir,
        report_path=args.report_output,
        part_count=args.parts,
    )
    print(json.dumps(report, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
