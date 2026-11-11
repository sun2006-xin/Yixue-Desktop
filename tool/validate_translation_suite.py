#!/usr/bin/env python3
"""Validate Yixue fixed translation suites and prevent evaluation leakage."""

from __future__ import annotations

import argparse
import collections
import json
import pathlib
import re
import sys
import unicodedata


REQUIRED_CATEGORIES = ("completeness", "terminology", "academic", "formatting")
REQUIRED_DIRECTIONS = (("english", "chinese"), ("chinese", "english"))
ALLOWED_ORIGINS = {"project_authored", "public_domain", "licensed_dataset"}


def normalize_text(value: str) -> str:
    normalized = unicodedata.normalize("NFKC", value).casefold().strip()
    return re.sub(r"\s+", " ", normalized)


def validate_suite(suite: dict, registry: dict, training_texts: list[str]) -> list[str]:
    errors: list[str] = []
    cases = suite.get("cases")
    sources = registry.get("sources")
    if suite.get("schema_version") != 2:
        errors.append("suite schema_version must be 2")
    if suite.get("purpose") != "fixed_evaluation":
        errors.append("suite purpose must be fixed_evaluation")
    if not isinstance(cases, list):
        return errors + ["suite cases must be a list"]
    if len(cases) < 64:
        errors.append("fixed evaluation suite must contain at least 64 cases")
    if not isinstance(sources, list):
        return errors + ["source registry entries must be a list"]

    source_map = {}
    for source in sources:
        source_id = source.get("id")
        if not isinstance(source_id, str) or not source_id.strip():
            errors.append("source registry contains an empty id")
            continue
        if source_id in source_map:
            errors.append(f"source registry has duplicate id: {source_id}")
        source_map[source_id] = source
        if source.get("origin") not in ALLOWED_ORIGINS:
            errors.append(f"source {source_id} has unsupported origin")

    ids: set[str] = set()
    normalized_sources: set[str] = set()
    training_fingerprints = {normalize_text(text) for text in training_texts if text.strip()}
    quotas = collections.Counter()

    for index, case in enumerate(cases):
        label = case.get("id") or f"case[{index}]"
        case_id = case.get("id")
        if not isinstance(case_id, str) or not case_id.strip():
            errors.append(f"{label}: id must be non-empty")
        elif case_id in ids:
            errors.append(f"{label}: duplicate id")
        else:
            ids.add(case_id)

        source_text = case.get("source")
        if not isinstance(source_text, str) or not source_text.strip():
            errors.append(f"{label}: source must be non-empty")
        else:
            fingerprint = normalize_text(source_text)
            if fingerprint in normalized_sources:
                errors.append(f"{label}: duplicate source")
            normalized_sources.add(fingerprint)
            if fingerprint in training_fingerprints:
                errors.append(f"{label}: training overlap detected")

        direction = (case.get("source_language"), case.get("target_language"))
        category = case.get("category")
        if direction not in REQUIRED_DIRECTIONS:
            errors.append(f"{label}: unsupported language direction")
        if category not in REQUIRED_CATEGORIES:
            errors.append(f"{label}: unsupported category")
        if direction in REQUIRED_DIRECTIONS and category in REQUIRED_CATEGORIES:
            quotas[(direction, category)] += 1

        difficulty = case.get("difficulty")
        if difficulty not in (1, 2, 3):
            errors.append(f"{label}: difficulty must be 1, 2, or 3")
        references = case.get("references")
        if not isinstance(references, list) or not references or any(
            not isinstance(reference, str) or not reference.strip() for reference in references
        ):
            errors.append(f"{label}: references must contain non-empty strings")

        source_id = (case.get("provenance") or {}).get("source_id")
        registered_source = source_map.get(source_id)
        if registered_source is None:
            errors.append(f"{label}: unregistered source {source_id!r}")
        elif registered_source.get("redistribution") != "allowed":
            errors.append(f"{label}: source {source_id} is not redistributable")
        if case.get("contains_personal_data") is not False:
            errors.append(f"{label}: fixed evaluation data must not contain personal data")

        preserve = case.get("preserve", [])
        if category == "formatting" and (
            not isinstance(preserve, list)
            or not preserve
            or any(not isinstance(token, str) or not token.strip() for token in preserve)
        ):
            errors.append(f"{label}: formatting cases require non-empty preserve tokens")
        elif preserve and any(not isinstance(token, str) or not token.strip() for token in preserve):
            errors.append(f"{label}: preserve tokens must be non-empty strings")
        if isinstance(source_text, str) and isinstance(preserve, list):
            for token in preserve:
                if isinstance(token, str) and token.strip() and token not in source_text:
                    errors.append(f"{label}: preserve token is absent from source: {token!r}")

    for direction in REQUIRED_DIRECTIONS:
        for category in REQUIRED_CATEGORIES:
            count = quotas[(direction, category)]
            if count < 8:
                errors.append(
                    f"quota requires at least 8 cases for {direction[0]}-{direction[1]} "
                    f"{category}; found {count}"
                )
    return errors


def load_training_texts(paths: list[pathlib.Path]) -> list[str]:
    texts: list[str] = []
    for path in paths:
        with path.open("r", encoding="utf-8") as stream:
            for line_number, line in enumerate(stream, 1):
                if not line.strip():
                    continue
                item = json.loads(line)
                for field in ("source", "target"):
                    value = item.get(field)
                    if isinstance(value, str) and value.strip():
                        texts.append(value)
                if "source" not in item or "target" not in item:
                    raise ValueError(f"{path}:{line_number}: training row requires source and target")
    return texts


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("suite", type=pathlib.Path)
    parser.add_argument("--registry", required=True, type=pathlib.Path)
    parser.add_argument("--training", action="append", default=[], type=pathlib.Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    suite = json.loads(args.suite.read_text(encoding="utf-8"))
    registry = json.loads(args.registry.read_text(encoding="utf-8"))
    errors = validate_suite(suite, registry, load_training_texts(args.training))
    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        print(f"VALIDATION=FAIL ERRORS={len(errors)}", file=sys.stderr)
        return 1
    print(f"VALIDATION=PASS CASES={len(suite['cases'])}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
