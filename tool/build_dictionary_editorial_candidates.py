#!/usr/bin/env python3
"""Build traceable WordNet-backed editorial candidates for the CET vocabulary.

This tool deliberately produces an *editorial candidate* file, not a public
dictionary package.  Open ECDICT-derived Chinese meanings stay separate from
WordNet's English glosses and relations.  Every generated candidate remains
``draft`` until bilingual examples, usage, and human review are complete.
"""

from __future__ import annotations

import argparse
import bz2
import hashlib
import json
import pathlib
import re
from collections import Counter, defaultdict
from dataclasses import dataclass
from types import MappingProxyType
from typing import Iterable, Mapping


WORDNET_SOURCE_ID = "wordnet-3.0"
OPEN_SOURCE_ID = "open-ecdict"
EDITORIAL_SCHEMA_VERSION = 1

_POS_NAMES = {
    "n": "noun",
    "v": "verb",
    "a": "adjective",
    "s": "adjective",
    "r": "adverb",
}

_RELATION_NAMES = {
    "@": "hypernyms",
    "@i": "instance_hypernyms",
    "~": "hyponyms",
    "~i": "instance_hyponyms",
    "!": "antonyms",
    "&": "similar_to",
    "+": "derivations",
    "$": "verb_groups",
    "#m": "participle_of",
    "#s": "participle_of",
    "#p": "participle_of",
    ";c": "topic_domains",
    ";r": "region_domains",
    ";u": "usage_domains",
    "-c": "topic_members",
    "-r": "region_members",
    "-u": "usage_members",
}


@dataclass(frozen=True)
class WordNetPointer:
    symbol: str
    target_offset: str
    target_pos: str


@dataclass(frozen=True)
class WordNetSynset:
    offset: str
    part_of_speech: str
    lemmas: tuple[str, ...]
    definition: str
    examples: tuple[str, ...]
    pointers: tuple[WordNetPointer, ...]


@dataclass(frozen=True)
class WordNetSense:
    offset: str
    part_of_speech: str
    lemmas: tuple[str, ...]
    definition: str
    examples: tuple[str, ...]
    relations: Mapping[str, tuple[str, ...]]


@dataclass(frozen=True)
class OpenCetEntry:
    word: str
    ipa: str
    coverage_bands: tuple[str, ...]
    source_translations: tuple[str, ...]

    @property
    def part_of_speech(self) -> str:
        values: list[str] = []
        for value in self.source_translations:
            match = re.match(r"\s*(?:\[[^]]+\]\s*)?([A-Za-z]+(?:\s*/\s*[A-Za-z]+)*\.)", value)
            if match:
                normalized = re.sub(r"\s+", "", match.group(1).lower())
                if normalized not in values:
                    values.append(normalized)
        return "/".join(values) or "待核对"

    @property
    def meanings(self) -> tuple[str, ...]:
        meanings: list[str] = []
        for value in self.source_translations:
            text = re.sub(r"^\s*(?:\[[^]]+\]\s*)?([A-Za-z]+(?:\s*/\s*[A-Za-z]+)*\.)\s*", "", value)
            text = text.strip(" ,;；，")
            if not text:
                continue
            for item in re.split(r"[,，;；]", text):
                item = item.strip()
                if item and item not in meanings:
                    meanings.append(item)
        return tuple(meanings)


@dataclass(frozen=True)
class EcdictEntry:
    word: str
    phonetic: str
    definitions: tuple[str, ...]
    translations: tuple[str, ...]
    tags: tuple[str, ...]
    bnc_rank: int | None
    frequency_rank: int | None
    variants: tuple[str, ...]


def _split_lines(value: str) -> tuple[str, ...]:
    return tuple(item.strip() for item in value.replace("\r", "").split("\n") if item.strip())


def _parse_rank(value: str) -> int | None:
    try:
        rank = int(value.strip())
    except (TypeError, ValueError):
        return None
    return rank if rank > 0 else None


def _parse_exchange_variants(exchange: str, lemma: str) -> tuple[str, ...]:
    variants: list[str] = []
    for item in exchange.split("/"):
        if ":" not in item:
            continue
        _, value = item.split(":", 1)
        value = value.strip()
        normalized = normalize_lemma(value)
        if not normalized or normalized == normalize_lemma(lemma):
            continue
        if normalized not in {normalize_lemma(existing) for existing in variants}:
            variants.append(value)
    return tuple(variants)


def parse_ecdict_row(row: Mapping[str, str]) -> EcdictEntry:
    word = normalize_lemma(row.get("word", ""))
    if not word:
        raise ValueError("ECDICT row needs a word")
    return EcdictEntry(
        word=word,
        phonetic=row.get("phonetic", "").strip(),
        definitions=_split_lines(row.get("definition", "")),
        translations=_split_lines(row.get("translation", "")),
        tags=tuple(item for item in row.get("tag", "").split() if item.strip()),
        bnc_rank=_parse_rank(row.get("bnc", "")),
        frequency_rank=_parse_rank(row.get("frq", "")),
        variants=_parse_exchange_variants(row.get("exchange", ""), word),
    )


def load_ecdict_entries(
    path: pathlib.Path,
    target_lemmas: Iterable[str],
) -> dict[str, EcdictEntry]:
    import csv

    targets = {normalize_lemma(item) for item in target_lemmas if normalize_lemma(item)}
    records: dict[str, EcdictEntry] = {}
    with path.open(encoding="utf-8", newline="") as handle:
        for row in csv.DictReader(handle):
            word = normalize_lemma(row.get("word", ""))
            if word not in targets or word in records:
                continue
            records[word] = parse_ecdict_row(row)
    return records


@dataclass(frozen=True)
class TatoebaSentence:
    sentence_id: str
    language: str
    text: str
    username: str
    date_added: str
    date_modified: str


@dataclass(frozen=True)
class TatoebaExample:
    english_id: str
    chinese_id: str
    english_text: str
    chinese_text: str
    english_username: str
    chinese_username: str
    english_date_modified: str
    chinese_date_modified: str


def parse_tatoeba_sentence_line(line: str) -> TatoebaSentence | None:
    fields = line.rstrip("\n").split("\t")
    if len(fields) < 6 or not fields[0].strip().isdigit():
        return None
    sentence = TatoebaSentence(
        sentence_id=fields[0].strip(),
        language=fields[1].strip(),
        text=fields[2].strip(),
        username=fields[3].strip(),
        date_added=fields[4].strip(),
        date_modified=fields[5].strip(),
    )
    if not sentence.language or not sentence.text:
        return None
    return sentence


def _parse_tatoeba_link_line(line: str) -> tuple[str, str] | None:
    fields = line.rstrip("\n").split("\t")
    if len(fields) < 2 or not fields[0].strip().isdigit() or not fields[1].strip().isdigit():
        return None
    return fields[0].strip(), fields[1].strip()


_TATOEBA_WORD_RE = re.compile(r"[a-z]+(?:['’-][a-z]+)*", re.IGNORECASE)
_COLLOCATION_STOPWORDS = {
    "a", "an", "and", "are", "as", "at", "be", "by", "for", "from",
    "in", "is", "it", "of", "on", "or", "that", "the", "to", "was",
    "were", "with",
}


def _matched_lemmas(text: str, targets: set[str]) -> set[str]:
    tokens = [normalize_lemma(item) for item in _TATOEBA_WORD_RE.findall(text)]
    if not tokens:
        return set()
    max_words = max((len(item.split()) for item in targets), default=1)
    matches: set[str] = set()
    for start in range(len(tokens)):
        for length in range(1, max_words + 1):
            end = start + length
            if end > len(tokens):
                break
            phrase = " ".join(tokens[start:end])
            if phrase in targets:
                matches.add(phrase)
    return matches


def build_tatoeba_examples(
    english_lines: Iterable[str],
    chinese_lines: Iterable[str],
    link_lines: Iterable[str],
    target_lemmas: Iterable[str],
    *,
    max_per_lemma: int = 3,
) -> dict[str, tuple[TatoebaExample, ...]]:
    """Build deterministic English-Chinese examples from Tatoeba exports."""

    if max_per_lemma <= 0:
        return {}
    targets = {normalize_lemma(item) for item in target_lemmas if normalize_lemma(item)}
    links_by_english: dict[str, set[str]] = defaultdict(set)
    chinese_ids: set[str] = set()
    for line in link_lines:
        link = _parse_tatoeba_link_line(line)
        if link is None:
            continue
        english_id, chinese_id = link
        links_by_english[english_id].add(chinese_id)
        chinese_ids.add(chinese_id)

    english_sentences: dict[str, TatoebaSentence] = {}
    for line in english_lines:
        sentence = parse_tatoeba_sentence_line(line)
        if sentence is not None and sentence.language == "eng" and sentence.sentence_id in links_by_english:
            english_sentences[sentence.sentence_id] = sentence

    chinese_sentences: dict[str, TatoebaSentence] = {}
    for line in chinese_lines:
        sentence = parse_tatoeba_sentence_line(line)
        if sentence is not None and sentence.language == "cmn" and sentence.sentence_id in chinese_ids:
            chinese_sentences[sentence.sentence_id] = sentence

    by_lemma: dict[str, list[TatoebaExample]] = defaultdict(list)
    for english_id in sorted(english_sentences, key=int):
        english = english_sentences[english_id]
        matched = _matched_lemmas(english.text, targets)
        if not matched:
            continue
        for chinese_id in sorted(links_by_english[english_id], key=int):
            chinese = chinese_sentences.get(chinese_id)
            if chinese is None:
                continue
            example = TatoebaExample(
                english_id=english.sentence_id,
                chinese_id=chinese.sentence_id,
                english_text=english.text,
                chinese_text=chinese.text,
                english_username=english.username,
                chinese_username=chinese.username,
                english_date_modified=english.date_modified,
                chinese_date_modified=chinese.date_modified,
            )
            for lemma in sorted(matched):
                by_lemma[lemma].append(example)

    result: dict[str, tuple[TatoebaExample, ...]] = {}
    for lemma, examples in sorted(by_lemma.items()):
        unique = {
            (example.english_id, example.chinese_id): example for example in examples
        }
        ordered = sorted(
            unique.values(),
            key=lambda item: (len(item.english_text), int(item.english_id), int(item.chinese_id)),
        )
        result[lemma] = tuple(ordered[:max_per_lemma])
    return result


def build_collocation_candidates(
    lemma: str,
    examples: Iterable[TatoebaExample],
    *,
    limit: int = 8,
) -> tuple[str, ...]:
    """Extract context phrases for editorial review, not approved collocations."""

    if limit <= 0:
        return ()
    target_tokens = tuple(normalize_lemma(lemma).split())
    if not target_tokens:
        return ()
    counts: Counter[str] = Counter()
    for example in examples:
        tokens = [normalize_lemma(item) for item in _TATOEBA_WORD_RE.findall(example.english_text)]
        width = len(target_tokens)
        for start in range(len(tokens) - width + 1):
            if tuple(tokens[start : start + width]) != target_tokens:
                continue
            for left in range(0, 3):
                for right in range(0, 3):
                    if left == 0 and right == 0:
                        continue
                    phrase_start = max(0, start - left)
                    phrase_end = min(len(tokens), start + width + right)
                    phrase_tokens = tokens[phrase_start:phrase_end]
                    if len(phrase_tokens) < 2:
                        continue
                    content_tokens = [
                        token for token in phrase_tokens if token not in _COLLOCATION_STOPWORDS
                    ]
                    if len(content_tokens) < 2:
                        continue
                    counts[" ".join(phrase_tokens)] += 1
    ordered = sorted(counts, key=lambda value: (-counts[value], len(value.split()), value))
    return tuple(ordered[:limit])


def normalize_lemma(value: str) -> str:
    """Normalize a WordNet or open-source lemma for exact matching."""

    return re.sub(r"\s+", " ", value.strip().lower().replace("_", " "))


def _canonical_pos(value: str) -> str:
    return "a" if value == "s" else value


def _parse_gloss(value: str) -> tuple[str, tuple[str, ...]]:
    gloss = " ".join(value.strip().split())
    examples = tuple(match.group(1).strip() for match in re.finditer(r'"([^"]+)"', gloss))
    definition = re.sub(r'\s*;\s*"[^"]+"', "", gloss).strip(" ;")
    return definition, examples


def parse_wordnet_data_line(line: str) -> WordNetSynset | None:
    """Parse one WordNet ``data.*`` row; comments and malformed rows return None."""

    stripped = line.strip()
    if not stripped or not stripped[0].isdigit():
        return None
    left, separator, raw_gloss = stripped.partition("|")
    fields = left.split()
    if len(fields) < 4:
        return None
    offset, raw_pos = fields[0], fields[2]
    part_of_speech = _POS_NAMES.get(raw_pos)
    if part_of_speech is None:
        return None
    try:
        word_count = int(fields[3], 16)
    except ValueError:
        return None
    cursor = 4
    lemmas: list[str] = []
    for _ in range(word_count):
        if cursor + 1 >= len(fields):
            return None
        lemmas.append(fields[cursor].replace("_", " "))
        cursor += 2
    if cursor >= len(fields):
        return None
    try:
        pointer_count = int(fields[cursor])
    except ValueError:
        return None
    cursor += 1
    pointers: list[WordNetPointer] = []
    for _ in range(pointer_count):
        if cursor + 3 >= len(fields):
            return None
        pointers.append(
            WordNetPointer(
                symbol=fields[cursor],
                target_offset=fields[cursor + 1],
                target_pos=_canonical_pos(fields[cursor + 2]),
            )
        )
        cursor += 4
    definition, examples = _parse_gloss(raw_gloss if separator else "")
    return WordNetSynset(
        offset=offset,
        part_of_speech=part_of_speech,
        lemmas=tuple(lemmas),
        definition=definition,
        examples=examples,
        pointers=tuple(pointers),
    )


def _iter_synsets(data_by_name: Mapping[str, str]) -> Iterable[WordNetSynset]:
    for text in data_by_name.values():
        for line in text.splitlines():
            synset = parse_wordnet_data_line(line)
            if synset is not None:
                yield synset


def build_wordnet_index(data_by_name: Mapping[str, str]) -> dict[str, tuple[WordNetSense, ...]]:
    """Parse WordNet data files and resolve relation offsets to lemma names."""

    synsets = tuple(_iter_synsets(data_by_name))
    by_offset = {
        (synset.offset, synset.part_of_speech): synset for synset in synsets
    }

    index: dict[str, list[WordNetSense]] = defaultdict(list)
    for synset in synsets:
        relations: dict[str, set[str]] = defaultdict(set)
        for pointer in synset.pointers:
            relation_name = _RELATION_NAMES.get(pointer.symbol)
            target = by_offset.get(
                (pointer.target_offset, _POS_NAMES.get(pointer.target_pos, pointer.target_pos))
            )
            if relation_name and target:
                relations[relation_name].update(
                    lemma
                    for lemma in target.lemmas
                    if normalize_lemma(lemma) not in {normalize_lemma(item) for item in synset.lemmas}
                )
        frozen_relations = MappingProxyType(
            {
                key: tuple(sorted(values, key=normalize_lemma))
                for key, values in sorted(relations.items())
                if values
            }
        )
        sense = WordNetSense(
            offset=synset.offset,
            part_of_speech=synset.part_of_speech,
            lemmas=tuple(synset.lemmas),
            definition=synset.definition,
            examples=synset.examples,
            relations=frozen_relations,
        )
        for lemma in synset.lemmas:
            normalized = normalize_lemma(lemma)
            if normalized:
                index[normalized].append(sense)

    return {
        lemma: tuple(sorted(senses, key=lambda item: (item.offset, item.part_of_speech)))
        for lemma, senses in sorted(index.items())
    }


def parse_open_cet_wire_row(wire: str) -> OpenCetEntry:
    fields = wire.split("|", 3)
    if len(fields) != 4:
        raise ValueError(f"invalid open CET row: {wire}")
    word, ipa, raw_bands, raw_translations = (field.strip() for field in fields)
    translations = tuple(item.strip() for item in raw_translations.split("~") if item.strip())
    bands = tuple(item.strip() for item in raw_bands.split(",") if item.strip())
    if not word or not translations or not bands:
        raise ValueError(f"open CET row has empty required field: {wire}")
    return OpenCetEntry(
        word=word,
        ipa=ipa,
        coverage_bands=bands,
        source_translations=translations,
    )


def load_open_cet_entries(repo_root: pathlib.Path) -> tuple[OpenCetEntry, ...]:
    """Load the generated open-layer rows without importing Flutter code."""

    directory = repo_root / "app" / "yixue_app" / "lib" / "core"
    entries: list[OpenCetEntry] = []
    for path in sorted(directory.glob("dictionary_cet_open_entries_part*.dart")):
        for line in path.read_text(encoding="utf-8").splitlines():
            stripped = line.strip()
            if not stripped.startswith('"'):
                continue
            literal = stripped.rstrip(",")
            try:
                wire = json.loads(literal)
            except json.JSONDecodeError:
                continue
            entries.append(parse_open_cet_wire_row(wire))
    if not entries:
        raise FileNotFoundError("no open CET dictionary rows found")
    return tuple(entries)


def _wordnet_sense_json(sense: WordNetSense) -> dict[str, object]:
    return {
        "synset_offset": sense.offset,
        "part_of_speech": sense.part_of_speech,
        "lemmas": list(sense.lemmas),
        "definition": sense.definition,
        "examples": list(sense.examples),
        "relations": {key: list(value) for key, value in sense.relations.items()},
    }


def build_candidate(
    base: OpenCetEntry,
    wordnet_index: Mapping[str, tuple[WordNetSense, ...]],
    tatoeba_examples: Mapping[str, tuple[TatoebaExample, ...]] | None = None,
    ecdict_index: Mapping[str, EcdictEntry] | None = None,
) -> dict[str, object]:
    """Create a traceable candidate; never claim a machine candidate is ready."""

    lemma = normalize_lemma(base.word)
    senses = wordnet_index.get(lemma, ())
    sentence_examples = (tatoeba_examples or {}).get(lemma, ())
    ecdict_record = (ecdict_index or {}).get(lemma)
    relation_values: dict[str, set[str]] = defaultdict(set)
    for sense in senses:
        for relation, values in sense.relations.items():
            relation_values[relation].update(values)

    missing_fields: list[str] = []
    if not base.ipa.strip():
        missing_fields.append("ipa")
    if not base.meanings:
        missing_fields.append("chinese_senses")
    if not base.part_of_speech or base.part_of_speech == "待核对":
        missing_fields.append("part_of_speech")
    if not senses:
        missing_fields.append("english_senses")
    if not any(sense.examples for sense in senses):
        missing_fields.append("english_examples")
    # WordNet examples are English-only.  Tatoeba pairs can close the
    # bilingual-example gap, but still need editorial review before release.
    if not sentence_examples:
        missing_fields.append("bilingual_examples")
    missing_fields.extend(["collocations", "human_review"])

    variants = list(ecdict_record.variants if ecdict_record else ())
    learning_tags = sorted(
        set(base.coverage_bands).union(ecdict_record.tags if ecdict_record else ())
    )
    if not variants:
        missing_fields.append("variants")

    source_ids = [OPEN_SOURCE_ID]
    if senses:
        source_ids.append(WORDNET_SOURCE_ID)
    if sentence_examples:
        source_ids.append("tatoeba-cc-by-2.0-fr")
    if ecdict_record:
        source_ids.append("ecdict-raw-master")

    return {
        "schema_version": EDITORIAL_SCHEMA_VERSION,
        "entry_id": f"yixue-editorial.en-zh.{lemma}",
        "language_pair": "en-zh",
        "lemma": lemma,
        "variants": variants,
        "learning_tags": learning_tags,
        "frequency": {
            "bnc_rank": ecdict_record.bnc_rank if ecdict_record else None,
            "modern_rank": ecdict_record.frequency_rank if ecdict_record else None,
        },
        "base": {
            "ipa": base.ipa,
            "part_of_speech": base.part_of_speech,
            "meanings": list(base.meanings),
            "source_translations": list(base.source_translations),
            "coverage_bands": list(base.coverage_bands),
        },
        "ecdict": {
            "source_id": "ecdict-raw-master",
            "found": ecdict_record is not None,
            "phonetic": ecdict_record.phonetic if ecdict_record else "",
            "definitions": list(ecdict_record.definitions if ecdict_record else ()),
            "translations": list(ecdict_record.translations if ecdict_record else ()),
            "tags": list(ecdict_record.tags if ecdict_record else ()),
        },
        "wordnet": {
            "source_id": WORDNET_SOURCE_ID,
            "sense_count": len(senses),
            "senses": [_wordnet_sense_json(sense) for sense in senses],
        },
        "tatoeba_examples": [
            {
                "english_id": example.english_id,
                "chinese_id": example.chinese_id,
                "english_text": example.english_text,
                "chinese_text": example.chinese_text,
                "english_username": example.english_username,
                "chinese_username": example.chinese_username,
                "english_date_modified": example.english_date_modified,
                "chinese_date_modified": example.chinese_date_modified,
            }
            for example in sentence_examples
        ],
        "collocation_candidates": list(
            build_collocation_candidates(lemma, sentence_examples)
        ),
        "relations": {
            key: sorted(values, key=normalize_lemma)
            for key, values in sorted(relation_values.items())
        },
        "source_ids": source_ids,
        "quality": {
            "status": "draft",
            "reviewer": "",
            "reviewed_at": "",
            "notes": "机器扩展候选；双语例句、语用和人工复核完成前不得进入发布索引。",
        },
        "missing_fields": missing_fields,
    }


def build_candidates(
    entries: Iterable[OpenCetEntry],
    wordnet_index: Mapping[str, tuple[WordNetSense, ...]],
    tatoeba_examples: Mapping[str, tuple[TatoebaExample, ...]] | None = None,
    ecdict_index: Mapping[str, EcdictEntry] | None = None,
) -> tuple[dict[str, object], ...]:
    candidates = [
        build_candidate(entry, wordnet_index, tatoeba_examples, ecdict_index)
        for entry in entries
    ]
    candidates.sort(key=lambda item: str(item["lemma"]))
    return tuple(candidates)


def build_quality_gate(candidates: Iterable[Mapping[str, object]]) -> dict[str, object]:
    """Summarize whether candidates are allowed to enter a public package."""

    rows = tuple(candidates)
    lemmas = [str(row.get("lemma", "")) for row in rows]
    duplicate_lemmas = sorted(
        lemma for lemma, count in Counter(lemmas).items() if lemma and count > 1
    )
    invalid_rows = []
    for row in rows:
        lemma = str(row.get("lemma", ""))
        quality = row.get("quality", {})
        status = quality.get("status") if isinstance(quality, Mapping) else None
        missing = row.get("missing_fields", [])
        if not lemma or status not in {"draft", "reviewed", "published", "withdrawn"}:
            invalid_rows.append(lemma or "<missing lemma>")
        if "�" in json.dumps(row, ensure_ascii=False):
            invalid_rows.append(lemma or "<missing lemma>")
        if not isinstance(missing, list):
            invalid_rows.append(lemma or "<missing lemma>")

    draft_entries = sum(
        row.get("quality", {}).get("status") == "draft"  # type: ignore[union-attr]
        for row in rows
    )
    publishable_entries = sum(
        row.get("quality", {}).get("status") == "published"  # type: ignore[union-attr]
        and not row.get("missing_fields")
        for row in rows
    )
    return {
        "total_entries": len(rows),
        "draft_entries": draft_entries,
        "publishable_entries": publishable_entries,
        "duplicate_lemmas": duplicate_lemmas,
        "invalid_rows": sorted(set(invalid_rows)),
        "passed": not duplicate_lemmas and not invalid_rows and publishable_entries == len(rows),
        "rule": "所有条目必须无缺口、来源可追溯、状态为 published，才允许导出公开包。",
    }


def build_report(candidates: Iterable[Mapping[str, object]]) -> dict[str, object]:
    rows = tuple(candidates)
    missing = Counter(
        field
        for row in rows
        for field in row.get("missing_fields", [])
    )
    matched = sum(bool(row["wordnet"]["sense_count"]) for row in rows)  # type: ignore[index]
    with_english_examples = sum(
        any(sense["examples"] for sense in row["wordnet"]["senses"])  # type: ignore[index]
        for row in rows
    )
    with_bilingual_examples = sum(bool(row.get("tatoeba_examples")) for row in rows)
    with_collocation_candidates = sum(bool(row.get("collocation_candidates")) for row in rows)
    with_variants = sum(bool(row.get("variants")) for row in rows)
    with_ecdict = sum(bool(row.get("ecdict", {}).get("found")) for row in rows)  # type: ignore[union-attr]
    source_ids = [OPEN_SOURCE_ID, WORDNET_SOURCE_ID]
    if with_bilingual_examples:
        source_ids.append("tatoeba-cc-by-2.0-fr")
    if with_ecdict:
        source_ids.append("ecdict-raw-master")
    return {
        "schema_version": EDITORIAL_SCHEMA_VERSION,
        "total_entries": len(rows),
        "wordnet_matched_entries": matched,
        "wordnet_unmatched_entries": len(rows) - matched,
        "entries_with_english_examples": with_english_examples,
        "entries_with_bilingual_examples": with_bilingual_examples,
        "entries_with_collocation_candidates": with_collocation_candidates,
        "entries_with_variants": with_variants,
        "entries_with_ecdict_metadata": with_ecdict,
        "all_candidates_draft": all(row["quality"]["status"] == "draft" for row in rows),  # type: ignore[index]
        "quality_gate": build_quality_gate(rows),
        "missing_field_counts": dict(sorted(missing.items())),
        "source_ids": source_ids,
    }


def _sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=pathlib.Path, default=pathlib.Path(__file__).parents[1])
    parser.add_argument("--wordnet-dir", type=pathlib.Path, required=True)
    parser.add_argument(
        "--tatoeba-dir",
        type=pathlib.Path,
        default=None,
        help="optional directory containing the three official Tatoeba .tsv.bz2 exports",
    )
    parser.add_argument(
        "--ecdict-csv",
        type=pathlib.Path,
        default=None,
        help="optional official ECDICT CSV snapshot for variants and frequency metadata",
    )
    parser.add_argument(
        "--output",
        type=pathlib.Path,
        default=None,
        help="defaults to data/dictionary/editorial-candidates-v1.json",
    )
    parser.add_argument("--report-output", type=pathlib.Path, default=None)
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    repo_root = args.repo_root.resolve()
    wordnet_dir = args.wordnet_dir.resolve()
    data_by_name: dict[str, str] = {}
    for name in ("noun", "verb", "adj", "adv"):
        path = wordnet_dir / f"data.{name}"
        if not path.is_file():
            raise FileNotFoundError(f"missing WordNet data file: {path}")
        data_by_name[name] = path.read_text(encoding="utf-8", errors="replace")

    entries = load_open_cet_entries(repo_root)
    index = build_wordnet_index(data_by_name)
    ecdict_index: dict[str, EcdictEntry] = {}
    if args.ecdict_csv is not None:
        ecdict_index = load_ecdict_entries(
            args.ecdict_csv.resolve(),
            (entry.word for entry in entries),
        )
    tatoeba_examples: dict[str, tuple[TatoebaExample, ...]] = {}
    if args.tatoeba_dir is not None:
        tatoeba_dir = args.tatoeba_dir.resolve()
        required_tatoeba = (
            "eng_sentences_detailed.tsv.bz2",
            "cmn_sentences_detailed.tsv.bz2",
            "eng-cmn_links.tsv.bz2",
        )
        paths = [tatoeba_dir / name for name in required_tatoeba]
        if any(not path.is_file() for path in paths):
            raise FileNotFoundError("missing Tatoeba export in " + str(tatoeba_dir))
        with bz2.open(paths[0], "rt", encoding="utf-8", errors="strict") as english:
            with bz2.open(paths[1], "rt", encoding="utf-8", errors="strict") as chinese:
                with bz2.open(paths[2], "rt", encoding="utf-8", errors="strict") as links:
                    tatoeba_examples = build_tatoeba_examples(
                        english,
                        chinese,
                        links,
                        (entry.word for entry in entries),
                    )
    candidates = build_candidates(entries, index, tatoeba_examples, ecdict_index)
    report = build_report(candidates)
    report["wordnet_data_sha256"] = {
        f"data.{name}": _sha256(wordnet_dir / f"data.{name}")
        for name in ("noun", "verb", "adj", "adv")
    }
    if args.tatoeba_dir is not None:
        report["tatoeba_export_sha256"] = {
            path.name: _sha256(path)
            for path in paths
        }
    output = (args.output or repo_root / "data" / "dictionary" / "editorial-candidates-v1.json").resolve()
    report_output = (args.report_output or output.with_name("editorial-candidates-v1.report.json")).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    report_output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(
            {
                "schema_version": EDITORIAL_SCHEMA_VERSION,
                "source": {
                    "open_layer": OPEN_SOURCE_ID,
                    "wordnet": WORDNET_SOURCE_ID,
                    "tatoeba": "tatoeba-cc-by-2.0-fr" if tatoeba_examples else None,
                    "ecdict": "ecdict-raw-master" if ecdict_index else None,
                    "tool": "yixue-editorial-candidates-0.1.0",
                },
                "report": report,
                "entries": list(candidates),
            },
            ensure_ascii=False,
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    report_output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, sort_keys=True))
    print(f"candidates={output}")
    print(f"report={report_output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
