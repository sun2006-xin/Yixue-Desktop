#!/usr/bin/env python3
"""Build a resumable Kaikki/Wiktionary candidate layer for target lemmas.

The downloader uses Kaikki's per-word JSONL pages instead of the 2.66 GB raw
English dump.  The result is an independent source layer: it keeps source
records and the CC BY-SA/GFDL boundary visible, while all editorial entries
remain ``draft``.  No source text is promoted to the Yixue public dictionary
without human review and a license decision.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import pathlib
import re
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from typing import Iterable, Mapping
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import Request, urlopen


KAIKKI_SOURCE_ID = "wiktionary-kaikki-2026-09"
KAIKKI_LICENSES = ("CC BY-SA 4.0", "GFDL")
KAIKKI_PAGE_BASE = "https://kaikki.org/dictionary/English/meaning"
KAIKKI_RAW_DATA_PAGE = "https://kaikki.org/dictionary/rawdata.html"
KAIKKI_FALLBACK_WORDS = {
    # The open CET source contains this apparent misspelling.  Keep the
    # requested lemma unchanged and expose the lookup as an alias candidate.
    "reservior": ("reservoir",),
    # These are audited lexical relationships used only to widen the local
    # candidate search.  The requested lemma remains the dictionary key, and
    # the resulting page is marked ``alias`` so editorial review can decide
    # whether the pronunciation transfers to the requested form.
    "intellectually": ("intellectual",),
    "inversely": ("inverse",),
    "living-room": ("living room",),
    "superficially": ("superficial",),
    "theatre": ("theater",),
    "uptodate": ("up-to-date",),
    "waggon": ("wagon",),
    "world-wide": ("worldwide",),
}

_UK_TAGS = {
    "australia",
    "british",
    "northern-england",
    "received-pronunciation",
    "scotland",
    "southern",
    "standard",
    "uk",
    "wales",
}
_US_TAGS = {"california", "general-american", "us"}
_ZH_CODES = {"cmn", "zh", "zh-hans", "zh-hant", "zh-cn", "zh-tw"}
_RELATION_KEYS = ("synonyms", "antonyms", "hypernyms", "hyponyms", "related", "derived")


@dataclass(frozen=True)
class FetchOptions:
    cache_dir: pathlib.Path
    base_url: str = KAIKKI_PAGE_BASE
    timeout: float = 30.0
    retries: int = 3
    refresh: bool = False


def normalize_word(value: str) -> str:
    """Normalize a target word without changing its lexical punctuation."""

    return re.sub(r"\s+", " ", str(value).strip().lower())


def build_kaikki_url(word: str, base_url: str = KAIKKI_PAGE_BASE) -> str:
    """Build Kaikki's stable per-word JSONL URL."""

    display_word = " ".join(str(word).strip().split())
    if not display_word:
        raise ValueError("word must not be empty")
    encoded_word = quote(display_word, safe="-_.~'")
    encoded_first = quote(display_word[0], safe="-_.~'")
    encoded_prefix = quote(display_word[:2], safe="-_.~'")
    return f"{base_url.rstrip('/')}/{encoded_first}/{encoded_prefix}/{encoded_word}.jsonl"


def _lookup_words(target: str) -> tuple[str, ...]:
    """Return exact, case-fallback, and explicitly audited alias lookups."""

    normalized = normalize_word(target)
    values = [normalized]
    if normalized and normalized[0].isalpha():
        capitalized = normalized[0].upper() + normalized[1:]
        if capitalized not in values:
            values.append(capitalized)
    values.extend(KAIKKI_FALLBACK_WORDS.get(normalized, ()))
    return tuple(dict.fromkeys(values))


def _unique_strings(values: Iterable[object], *, limit: int | None = None) -> list[str]:
    result: list[str] = []
    seen: set[str] = set()
    for value in values:
        if not isinstance(value, str):
            continue
        normalized = " ".join(value.split()).strip()
        if not normalized or normalized in seen:
            continue
        seen.add(normalized)
        result.append(normalized)
        if limit is not None and len(result) >= limit:
            break
    return result


def _compact_word_refs(values: object, *, limit: int = 24) -> list[str]:
    if not isinstance(values, list):
        return []
    words: list[object] = []
    for value in values:
        if isinstance(value, Mapping):
            words.append(value.get("word", ""))
        else:
            words.append(value)
    return _unique_strings(words, limit=limit)


def _sound_bucket(tags: Iterable[object]) -> str:
    normalized = {str(tag).strip().lower() for tag in tags if str(tag).strip()}
    if normalized.intersection(_US_TAGS):
        return "us"
    if normalized.intersection(_UK_TAGS):
        return "uk"
    return "other"


def _compact_sounds(values: object) -> dict[str, list[str]]:
    buckets: dict[str, list[str]] = {"uk": [], "us": [], "other": []}
    if not isinstance(values, list):
        return {}
    for sound in values:
        if not isinstance(sound, Mapping):
            continue
        ipa = sound.get("ipa")
        if not isinstance(ipa, str) or not ipa.strip():
            continue
        bucket = _sound_bucket(sound.get("tags", []))
        if ipa.strip() not in buckets[bucket]:
            buckets[bucket].append(ipa.strip())
    return {key: value for key, value in buckets.items() if value}


def _compact_forms(values: object) -> list[dict[str, object]]:
    result: list[dict[str, object]] = []
    seen: set[tuple[str, tuple[str, ...]]] = set()
    if not isinstance(values, list):
        return result
    for form in values:
        if not isinstance(form, Mapping):
            continue
        word = form.get("form")
        if not isinstance(word, str) or not word.strip():
            continue
        tags = tuple(_unique_strings(form.get("tags", [])))
        key = (word.strip(), tags)
        if key in seen:
            continue
        seen.add(key)
        result.append({"form": word.strip(), "tags": list(tags)})
    return result[:32]


def _compact_senses(values: object) -> list[dict[str, object]]:
    result: list[dict[str, object]] = []
    if not isinstance(values, list):
        return result
    for sense in values:
        if not isinstance(sense, Mapping):
            continue
        glosses = _unique_strings(sense.get("glosses", sense.get("raw_glosses", [])), limit=8)
        examples: list[str] = []
        raw_examples = sense.get("examples", [])
        if isinstance(raw_examples, list):
            for example in raw_examples:
                if not isinstance(example, Mapping):
                    continue
                kind = str(example.get("type", "example")).strip().lower()
                if kind != "example":
                    continue
                text = example.get("text")
                if isinstance(text, str):
                    examples.extend([text])
        compact: dict[str, object] = {
            "glosses": glosses,
            "tags": _unique_strings(sense.get("tags", [])),
            "examples": _unique_strings(examples, limit=8),
            "synonyms": _compact_word_refs(sense.get("synonyms")),
            "antonyms": _compact_word_refs(sense.get("antonyms")),
        }
        qualifier = sense.get("qualifier")
        if isinstance(qualifier, str) and qualifier.strip():
            compact["qualifier"] = " ".join(qualifier.split())
        if any(compact[key] for key in ("glosses", "tags", "examples", "synonyms", "antonyms")):
            result.append(compact)
    return result[:64]


def _compact_translations(values: object) -> list[dict[str, object]]:
    result: list[dict[str, object]] = []
    seen: set[tuple[str, str, str]] = set()
    if not isinstance(values, list):
        return result
    for translation in values:
        if not isinstance(translation, Mapping):
            continue
        code = str(translation.get("lang_code", translation.get("code", ""))).strip().lower()
        if code not in _ZH_CODES:
            continue
        word = translation.get("word")
        if not isinstance(word, str) or not word.strip():
            continue
        sense = translation.get("sense", "")
        sense_text = " ".join(str(sense).split()) if isinstance(sense, str) else ""
        roman = translation.get("roman", "")
        roman_text = " ".join(str(roman).split()) if isinstance(roman, str) else ""
        key = (code, word.strip(), sense_text)
        if key in seen:
            continue
        seen.add(key)
        result.append(
            {
                "lang_code": code,
                "word": word.strip(),
                "sense": sense_text,
                "roman": roman_text,
                "tags": _unique_strings(translation.get("tags", [])),
            }
        )
    return result[:64]


def _compact_record(row: Mapping[str, object]) -> dict[str, object]:
    relations = {
        key: _compact_word_refs(row.get(key))
        for key in _RELATION_KEYS
        if _compact_word_refs(row.get(key))
    }
    return {
        "word": " ".join(str(row.get("word", "")).strip().split()),
        "pos": str(row.get("pos", "")).strip(),
        "ipa": _compact_sounds(row.get("sounds")),
        "forms": _compact_forms(row.get("forms")),
        "senses": _compact_senses(row.get("senses")),
        "translations_zh": _compact_translations(row.get("translations")),
        "relations": relations,
    }


def parse_kaikki_jsonl(
    text: str,
    target_word: str,
    *,
    accepted_words: Iterable[str] = (),
) -> tuple[dict[str, object], ...]:
    """Parse only matching English records and discard quotations/raw noise."""

    targets = {normalize_word(target_word)}
    targets.update(normalize_word(word) for word in accepted_words if normalize_word(word))
    records: list[dict[str, object]] = []
    for line in text.splitlines():
        try:
            row = json.loads(line)
        except (TypeError, json.JSONDecodeError):
            continue
        if not isinstance(row, Mapping):
            continue
        if str(row.get("lang_code", "")).strip().lower() != "en":
            continue
        if normalize_word(str(row.get("word", ""))) not in targets:
            continue
        records.append(_compact_record(row))
    records.sort(key=lambda item: (str(item.get("pos", "")), json.dumps(item, ensure_ascii=False, sort_keys=True)))
    return tuple(records)


def _sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def build_kaikki_entry(
    target_word: str,
    text: str,
    url: str,
    *,
    cache_file: str = "",
    sha256: str = "",
    bytes_count: int = 0,
    status: str | None = None,
    error: str = "",
    accepted_words: Iterable[str] = (),
    resolved_word: str = "",
) -> dict[str, object]:
    target = normalize_word(target_word)
    records = list(parse_kaikki_jsonl(text, target, accepted_words=accepted_words))
    resolved_status = status or ("ok" if records else "empty")
    result: dict[str, object] = {
        "source_id": KAIKKI_SOURCE_ID,
        "requested_word": target,
        "resolved_word": normalize_word(resolved_word) if resolved_word else target,
        "licenses": list(KAIKKI_LICENSES),
        "page_url": url,
        "cache_file": cache_file,
        "compressed_bytes": bytes_count,
        "sha256": sha256,
        "status": resolved_status,
        "records": records,
    }
    if error:
        result["error"] = error
    return result


def _cache_path(target: str, cache_dir: pathlib.Path) -> pathlib.Path:
    filename = quote(" ".join(str(target).strip().split()), safe="-_.~'_ ").replace(" ", "_") + ".jsonl"
    return cache_dir / filename


def _read_cached_page(
    target: str,
    path: pathlib.Path,
    url: str,
    *,
    accepted_words: Iterable[str] = (),
    resolved_word: str = "",
) -> dict[str, object]:
    try:
        raw = path.read_bytes()
        text = raw.decode("utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        return build_kaikki_entry(
            target,
            "",
            url,
            cache_file=str(path),
            status="error",
            error=str(exc),
            accepted_words=accepted_words,
            resolved_word=resolved_word,
        )
    return build_kaikki_entry(
        target,
        text,
        url,
        cache_file=str(path),
        sha256=_sha256_bytes(raw),
        bytes_count=len(raw),
        accepted_words=accepted_words,
        resolved_word=resolved_word,
    )


def _annotate_page_resolution(
    page: dict[str, object],
    target: str,
    lookup_word: str,
    base_url: str,
) -> dict[str, object]:
    """Make the recorded URL and resolution kind agree with page contents."""

    resolved_word = normalize_word(lookup_word)
    records = page.get("records", [])
    if isinstance(records, list):
        for record in records:
            if not isinstance(record, Mapping):
                continue
            actual_word = str(record.get("word", "")).strip()
            if actual_word and normalize_word(actual_word) == normalize_word(target):
                resolved_word = actual_word
                break
    page["resolved_word"] = resolved_word
    page["page_url"] = build_kaikki_url(resolved_word, base_url)
    if resolved_word == target:
        page["match_type"] = "exact"
    elif normalize_word(resolved_word) == normalize_word(target):
        page["match_type"] = "case_variant"
    else:
        page["match_type"] = "alias"
    return page


def _page_has_pronunciation(page: Mapping[str, object]) -> bool:
    records = page.get("records", [])
    if not isinstance(records, list):
        return False
    return any(
        isinstance(record, Mapping) and bool(record.get("ipa"))
        for record in records
    )


def _attach_audited_pronunciation_aliases(
    page: dict[str, object],
    target: str,
    options: FetchOptions,
) -> dict[str, object]:
    """Attach explicit alias pages without replacing the requested lemma page."""

    if page.get("status") != "ok" or page.get("match_type") == "alias":
        return page
    if _page_has_pronunciation(page):
        return page
    aliases = KAIKKI_FALLBACK_WORDS.get(normalize_word(target), ())
    if not aliases:
        return page

    alias_pages: list[dict[str, object]] = []
    for alias in aliases:
        alias_page = fetch_kaikki_page(alias, options)
        if alias_page.get("status") != "ok" or not alias_page.get("records"):
            continue
        alias_pages.append(
            {
                "source_id": KAIKKI_SOURCE_ID,
                "requested_word": normalize_word(target),
                "resolved_word": alias_page.get("resolved_word", normalize_word(alias)),
                "match_type": "alias",
                "page_url": alias_page.get("page_url", ""),
                "cache_file": alias_page.get("cache_file", ""),
                "sha256": alias_page.get("sha256", ""),
                "status": "ok",
                "records": alias_page.get("records", []),
            }
        )
    if alias_pages:
        page["pronunciation_alias_pages"] = alias_pages
    return page


def fetch_kaikki_page(target: str, options: FetchOptions) -> dict[str, object]:
    """Fetch one page with a cache, bounded retries and a 404 marker."""

    target = normalize_word(target)
    options.cache_dir.mkdir(parents=True, exist_ok=True)
    lookup_words = _lookup_words(target)
    attempts = max(1, options.retries)
    last_error = ""
    attempted_urls: list[str] = []
    for lookup_word in lookup_words:
        url = build_kaikki_url(lookup_word, options.base_url)
        cache_path = _cache_path(lookup_word, options.cache_dir)
        missing_marker = cache_path.with_suffix(".not-found")
        if not options.refresh and cache_path.is_file():
            page = _read_cached_page(
                target,
                cache_path,
                url,
                accepted_words=lookup_words,
                resolved_word=lookup_word,
            )
            resolved = _annotate_page_resolution(page, target, lookup_word, options.base_url)
            return _attach_audited_pronunciation_aliases(resolved, target, options)
        if not options.refresh and missing_marker.is_file():
            attempted_urls.append(url)
            continue
        for attempt in range(1, attempts + 1):
            try:
                request = Request(
                    url,
                    headers={"User-Agent": "YixueDictionaryBuilder/0.1 (local candidate pipeline)"},
                )
                with urlopen(request, timeout=options.timeout) as response:
                    raw = response.read()
                partial_path = cache_path.with_suffix(".jsonl.part")
                partial_path.write_bytes(raw)
                partial_path.replace(cache_path)
                if missing_marker.exists():
                    missing_marker.unlink()
                page = build_kaikki_entry(
                    target,
                    raw.decode("utf-8"),
                    url,
                    cache_file=str(cache_path),
                    sha256=_sha256_bytes(raw),
                    bytes_count=len(raw),
                    accepted_words=lookup_words,
                    resolved_word=lookup_word,
                )
                resolved = _annotate_page_resolution(page, target, lookup_word, options.base_url)
                return _attach_audited_pronunciation_aliases(resolved, target, options)
            except HTTPError as exc:
                if exc.code == 404:
                    missing_marker.write_text(url + "\n", encoding="utf-8")
                    attempted_urls.append(url)
                    break
                last_error = f"HTTP {exc.code}: {exc.reason}"
            except (OSError, UnicodeDecodeError, URLError) as exc:
                last_error = str(exc)
            if attempt < attempts:
                time.sleep(min(2.0, 0.5 * attempt))
        if last_error and not attempted_urls:
            break
    url = attempted_urls[-1] if attempted_urls else build_kaikki_url(target, options.base_url)
    return build_kaikki_entry(
        target,
        "",
        url,
        cache_file=str(_cache_path(target, options.cache_dir)),
        status="not_found" if attempted_urls and not last_error else "error",
        error=last_error or ("HTTP 404" if attempted_urls else "unknown fetch error"),
        accepted_words=lookup_words,
    )


def fetch_targets(
    targets: Iterable[str],
    options: FetchOptions,
    *,
    workers: int = 6,
) -> dict[str, dict[str, object]]:
    normalized_targets = sorted({normalize_word(target) for target in targets if normalize_word(target)})
    if not normalized_targets:
        return {}
    results: dict[str, dict[str, object]] = {}
    started = time.monotonic()
    completed = 0
    with ThreadPoolExecutor(max_workers=max(1, min(workers, 12))) as executor:
        futures = {
            executor.submit(fetch_kaikki_page, target, options): target
            for target in normalized_targets
        }
        for future in as_completed(futures):
            target = futures[future]
            try:
                results[target] = future.result()
            except Exception as exc:  # keep one bad page from stopping the batch
                results[target] = build_kaikki_entry(
                    target,
                    "",
                    build_kaikki_url(target, options.base_url),
                    status="error",
                    error=f"unhandled fetch error: {exc}",
                )
            completed += 1
            if completed == len(normalized_targets) or completed % 100 == 0:
                ok = sum(page.get("status") == "ok" for page in results.values())
                missing = sum(page.get("status") == "not_found" for page in results.values())
                elapsed = time.monotonic() - started
                print(f"kaikki-progress {completed}/{len(normalized_targets)} ok={ok} not_found={missing} elapsed_s={elapsed:.1f}")
    return dict(sorted(results.items()))


def build_missing_page_entry(target: str, base_url: str = KAIKKI_PAGE_BASE) -> dict[str, object]:
    return build_kaikki_entry(
        target,
        "",
        build_kaikki_url(target, base_url),
        status="not_requested",
        error="target page was not fetched",
    )


def merge_kaikki_layer(
    payload: Mapping[str, object],
    pages: Mapping[str, Mapping[str, object]],
) -> dict[str, object]:
    """Attach the independent source layer without promoting or overwriting fields."""

    merged = copy.deepcopy(dict(payload))
    raw_entries = merged.get("entries", [])
    if not isinstance(raw_entries, list):
        raise ValueError("candidate payload entries must be a list")
    entries: list[dict[str, object]] = []
    for raw_entry in raw_entries:
        if not isinstance(raw_entry, Mapping):
            continue
        entry = dict(raw_entry)
        lemma = normalize_word(str(entry.get("lemma", "")))
        page = dict(pages.get(lemma, build_missing_page_entry(lemma)))
        entry["kaikki"] = page
        source_ids = list(entry.get("source_ids", []))
        if page.get("status") == "ok" and page.get("records") and KAIKKI_SOURCE_ID not in source_ids:
            source_ids.append(KAIKKI_SOURCE_ID)
        entry["source_ids"] = source_ids
        entries.append(entry)
    entries.sort(key=lambda item: normalize_word(str(item.get("lemma", ""))))
    merged["entries"] = entries
    source = dict(merged.get("source", {})) if isinstance(merged.get("source"), Mapping) else {}
    source["kaikki"] = {
        "source_id": KAIKKI_SOURCE_ID,
        "licenses": list(KAIKKI_LICENSES),
        "raw_data_page": KAIKKI_RAW_DATA_PAGE,
        "per_word_page_base": KAIKKI_PAGE_BASE,
        "role": "独立候选层；未审校前不得进入译学公开包",
    }
    merged["source"] = source
    return merged


def build_kaikki_report(entries: Iterable[Mapping[str, object]]) -> dict[str, object]:
    rows = tuple(entries)
    pages = [row.get("kaikki", {}) for row in rows]
    ok_pages = [page for page in pages if isinstance(page, Mapping) and page.get("status") == "ok"]
    records = [
        record
        for page in ok_pages
        for record in page.get("records", [])
        if isinstance(page.get("records", []), list) and isinstance(record, Mapping)
    ]
    with_senses = sum(bool(record.get("senses")) for record in records)
    with_zh = sum(bool(record.get("translations_zh")) for record in records)
    with_examples = sum(
        any(bool(sense.get("examples")) for sense in record.get("senses", []) if isinstance(sense, Mapping))
        for record in records
    )
    with_ipa = sum(bool(record.get("ipa")) for record in records)
    with_forms = sum(bool(record.get("forms")) for record in records)
    draft_entries = sum(
        isinstance(row.get("quality"), Mapping) and row.get("quality", {}).get("status") == "draft"
        for row in rows
    )
    status_counts = {}
    for page in pages:
        status = str(page.get("status", "missing")) if isinstance(page, Mapping) else "missing"
        status_counts[status] = status_counts.get(status, 0) + 1
    return {
        "source_id": KAIKKI_SOURCE_ID,
        "licenses": list(KAIKKI_LICENSES),
        "total_entries": len(rows),
        "matched_pages": len(ok_pages),
        "missing_pages": len(rows) - len(ok_pages),
        "alias_resolved_pages": sum(
            page.get("match_type") == "alias" for page in ok_pages if isinstance(page, Mapping)
        ),
        "case_variant_pages": sum(
            page.get("match_type") == "case_variant" for page in ok_pages if isinstance(page, Mapping)
        ),
        "status_counts": dict(sorted(status_counts.items())),
        "total_records": len(records),
        "entries_with_english_senses": with_senses,
        "entries_with_chinese_translations": with_zh,
        "entries_with_english_examples": with_examples,
        "entries_with_ipa": with_ipa,
        "entries_with_forms": with_forms,
        "draft_entries": draft_entries,
        "all_records_are_candidates": True,
        "quality_note": "Kaikki/Wiktionary 内容保留为独立候选层；CC BY-SA/GFDL 义务与人工复核完成前不得发布。",
    }


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=pathlib.Path, default=pathlib.Path("data/dictionary/editorial-candidates-v1.json"))
    parser.add_argument("--output", type=pathlib.Path, default=pathlib.Path("data/dictionary/editorial-candidates-v2.json"))
    parser.add_argument("--report-output", type=pathlib.Path, default=pathlib.Path("data/dictionary/editorial-candidates-v2.report.json"))
    parser.add_argument("--cache-dir", type=pathlib.Path, default=pathlib.Path(".tmp/dictionary-sources/kaikki-2026-09/words"))
    parser.add_argument("--workers", type=int, default=6)
    parser.add_argument("--timeout", type=float, default=30.0)
    parser.add_argument("--retries", type=int, default=3)
    parser.add_argument("--refresh", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    payload = json.loads(args.input.resolve().read_text(encoding="utf-8"))
    if not isinstance(payload, Mapping) or not isinstance(payload.get("entries"), list):
        raise ValueError("input candidate JSON must contain an entries list")
    targets = [str(entry.get("lemma", "")) for entry in payload["entries"] if isinstance(entry, Mapping)]
    options = FetchOptions(
        cache_dir=args.cache_dir.resolve(),
        timeout=max(1.0, args.timeout),
        retries=max(1, args.retries),
        refresh=args.refresh,
    )
    pages = fetch_targets(targets, options, workers=args.workers)
    merged = merge_kaikki_layer(payload, pages)
    report = build_kaikki_report(merged["entries"])
    merged_report = dict(merged.get("report", {})) if isinstance(merged.get("report"), Mapping) else {}
    merged_report["kaikki_layer"] = report
    merged["report"] = merged_report
    args.output.resolve().parent.mkdir(parents=True, exist_ok=True)
    args.report_output.resolve().parent.mkdir(parents=True, exist_ok=True)
    args.output.resolve().write_text(
        json.dumps(merged, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    args.report_output.resolve().write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(json.dumps(report, ensure_ascii=False, sort_keys=True))
    print(f"candidates={args.output.resolve()}")
    print(f"report={args.report_output.resolve()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
