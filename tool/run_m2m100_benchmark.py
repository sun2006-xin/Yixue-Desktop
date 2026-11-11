#!/usr/bin/env python3
"""Run the fixed Yixue English-Chinese suite against a local M2M100 model."""

from __future__ import annotations

import argparse
import json
import math
import os
import pathlib
import statistics
import threading
import time
from datetime import datetime, timezone


LANGUAGE_CODES = {"english": "en", "chinese": "zh"}


def language_code(name: str) -> str:
    try:
        return LANGUAGE_CODES[name]
    except KeyError as exc:
        raise ValueError(f"Unsupported benchmark language: {name}") from exc


def preserve_checks(translation: str, required: list[str]) -> list[dict[str, object]]:
    return [{"token": token, "present": token in translation} for token in required]


def percentile(values: list[int], rank: int) -> int:
    if not values:
        return 0
    ordered = sorted(values)
    index = max(0, min(len(ordered) - 1, math.ceil(rank / 100 * len(ordered)) - 1))
    return ordered[index]


def directory_bytes(path: pathlib.Path) -> int:
    return sum(item.stat().st_size for item in path.rglob("*") if item.is_file())


def existing_path(value: str | os.PathLike[str]) -> pathlib.Path:
    """Return an absolute path without resolving a Windows junction target."""
    path = pathlib.Path(os.path.abspath(os.fspath(value)))
    if not path.exists():
        raise FileNotFoundError(path)
    return path


class MemorySampler:
    def __init__(self, process, interval_seconds: float = 0.01):
        self._process = process
        self._interval = interval_seconds
        self._stop = threading.Event()
        self.peak_bytes = process.memory_info().rss
        self._thread = threading.Thread(target=self._sample, daemon=True)

    def _sample(self) -> None:
        while not self._stop.wait(self._interval):
            self.peak_bytes = max(self.peak_bytes, self._process.memory_info().rss)

    def __enter__(self):
        self._thread.start()
        return self

    def __exit__(self, *_args):
        self._stop.set()
        self._thread.join(timeout=1)
        self.peak_bytes = max(self.peak_bytes, self._process.memory_info().rss)


def translate(translator, tokenizer, source: str, source_language: str, target_language: str) -> str:
    tokenizer.src_lang = language_code(source_language)
    source_ids = tokenizer.encode(source)
    source_tokens = tokenizer.convert_ids_to_tokens(source_ids)
    target_token = tokenizer.convert_ids_to_tokens(tokenizer.get_lang_id(language_code(target_language)))
    result = translator.translate_batch(
        [source_tokens],
        target_prefix=[[target_token]],
        beam_size=5,
        max_decoding_length=512,
    )[0]
    hypothesis = result.hypotheses[0]
    if hypothesis and hypothesis[0] == target_token:
        hypothesis = hypothesis[1:]
    target_ids = tokenizer.convert_tokens_to_ids(hypothesis)
    return tokenizer.decode(target_ids, skip_special_tokens=True).strip()


def write_markdown(report: dict, destination: pathlib.Path) -> None:
    summary = report["summary"]
    lines = [
        f"# {report['suite_id']} · M2M100 418M INT8 基准",
        "",
        f"- 样例：{summary['cases']}",
        f"- 延迟：平均 {summary['average_ms']} ms；P50 {summary['p50_ms']} ms；P95 {summary['p95_ms']} ms；最大 {summary['max_ms']} ms",
        f"- 首次加载：{report['model']['load_ms']} ms",
        f"- 峰值工作集：{summary['peak_working_set_mib']} MiB",
        f"- 模型包：{report['model']['size_mib']} MiB",
        f"- 格式保留：{summary['preserve_passed']}/{summary['preserve_total']}",
        "",
        "| ID | 原文 | 模型译文 | 参考译文 | 耗时 ms | 格式 | 人工评分 |",
        "|---|---|---|---|---:|---|---|",
    ]
    for item in report["cases"]:
        source = item["source"].replace("|", "\\|").replace("\n", " ")
        translation = item["translation"].replace("|", "\\|").replace("\n", " ")
        reference = item["references"][0].replace("|", "\\|")
        formatting = "—" if not item["preserve"] else ("通过" if item["preserve_pass"] else "失败")
        lines.append(
            f"| {item['id']} | {source} | {translation} | {reference} | "
            f"{item['elapsed_ms']} | {formatting} | 待盲评 |"
        )
    destination.write_text("\n".join(lines) + "\n", encoding="utf-8")


def run(args: argparse.Namespace) -> tuple[pathlib.Path, pathlib.Path, dict]:
    import ctranslate2
    import psutil
    from transformers import M2M100Tokenizer

    suite_path = existing_path(args.suite)
    model_path = existing_path(args.model)
    tokenizer_path = existing_path(args.tokenizer)
    output_path = pathlib.Path(os.path.abspath(os.fspath(args.output)))
    output_path.mkdir(parents=True, exist_ok=True)

    suite = json.loads(suite_path.read_text(encoding="utf-8"))
    if suite.get("schema_version") not in (1, 2) or not suite.get("cases"):
        raise ValueError("Benchmark suite schema is unsupported or empty")

    process = psutil.Process(os.getpid())
    load_started = time.perf_counter()
    with MemorySampler(process) as load_memory:
        translator = ctranslate2.Translator(str(model_path), device="cpu", compute_type="int8")
        tokenizer = M2M100Tokenizer.from_pretrained(str(tokenizer_path), local_files_only=True)
    load_ms = round((time.perf_counter() - load_started) * 1000)

    results = []
    peak_bytes = load_memory.peak_bytes
    for case in suite["cases"]:
        started = time.perf_counter()
        with MemorySampler(process) as case_memory:
            translated = translate(
                translator,
                tokenizer,
                case["source"],
                case["source_language"],
                case["target_language"],
            )
        elapsed_ms = round((time.perf_counter() - started) * 1000)
        if not translated:
            raise RuntimeError(f"Translation returned empty text: {case['id']}")
        peak_bytes = max(peak_bytes, case_memory.peak_bytes)
        checks = preserve_checks(translated, case.get("preserve", []))
        results.append(
            {
                "id": case["id"],
                "category": case["category"],
                "source_language": case["source_language"],
                "target_language": case["target_language"],
                "source": case["source"],
                "references": case["references"],
                "translation": translated,
                "elapsed_ms": elapsed_ms,
                "peak_working_set_mib": round(case_memory.peak_bytes / 1024 / 1024, 2),
                "preserve": checks,
                "preserve_pass": all(check["present"] for check in checks),
                "manual_accuracy_1_to_5": None,
                "manual_naturalness_1_to_5": None,
                "manual_terminology_1_to_5": None,
                "manual_notes": "",
            }
        )

    elapsed = [item["elapsed_ms"] for item in results]
    preserve_cases = [item for item in results if item["preserve"]]
    report = {
        "schema_version": 1,
        "suite_id": suite["id"],
        "generated_at": datetime.now(timezone.utc).astimezone().isoformat(),
        "engine": f"CTranslate2 {ctranslate2.__version__} / INT8",
        "model": {
            "id": "facebook/m2m100_418M@55c2e61",
            "package": model_path.name,
            "size_mib": round(directory_bytes(model_path) / 1024 / 1024, 2),
            "load_ms": load_ms,
            "load_peak_working_set_mib": round(load_memory.peak_bytes / 1024 / 1024, 2),
        },
        "summary": {
            "cases": len(results),
            "average_ms": round(statistics.mean(elapsed), 2),
            "p50_ms": percentile(elapsed, 50),
            "p95_ms": percentile(elapsed, 95),
            "max_ms": max(elapsed),
            "peak_working_set_mib": round(peak_bytes / 1024 / 1024, 2),
            "preserve_passed": sum(item["preserve_pass"] for item in preserve_cases),
            "preserve_total": len(preserve_cases),
        },
        "cases": results,
    }

    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    base_name = f"{suite['id']}-m2m100-418m-int8-{stamp}"
    json_path = output_path / f"{base_name}.json"
    markdown_path = output_path / f"{base_name}.md"
    json_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    write_markdown(report, markdown_path)
    return json_path, markdown_path, report


def parse_args() -> argparse.Namespace:
    project = pathlib.Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--suite", default=project / "benchmarks/translation/en-zh-baseline-v1.json")
    parser.add_argument("--model", required=True)
    parser.add_argument("--tokenizer", required=True)
    parser.add_argument("--output", default=project / "benchmarks/results")
    return parser.parse_args()


if __name__ == "__main__":
    json_file, markdown_file, benchmark = run(parse_args())
    summary = benchmark["summary"]
    print(f"BENCHMARK_JSON={json_file}")
    print(f"BENCHMARK_MARKDOWN={markdown_file}")
    print(f"CASES={summary['cases']}")
    print(f"AVERAGE_MS={summary['average_ms']}")
    print(f"P95_MS={summary['p95_ms']}")
    print(f"PEAK_WORKING_SET_MIB={summary['peak_working_set_mib']}")
    print(f"PRESERVE={summary['preserve_passed']}/{summary['preserve_total']}")
