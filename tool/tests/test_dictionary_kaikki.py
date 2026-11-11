import importlib.util
import json
import pathlib
import sys
import tempfile
import unittest


MODULE_PATH = pathlib.Path(__file__).parents[1] / "build_dictionary_kaikki_layer.py"
SPEC = importlib.util.spec_from_file_location("dictionary_kaikki", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


SAMPLE_RECORD = {
    "word": "dog",
    "lang": "English",
    "lang_code": "en",
    "pos": "noun",
    "sounds": [
        {"ipa": "/dɒɡ/", "tags": ["UK"]},
        {"ipa": "/dɔːɡ/", "tags": ["US"]},
    ],
    "forms": [{"form": "dogs", "tags": ["plural"]}],
    "senses": [
        {
            "glosses": ["A domesticated animal."],
            "tags": ["countable"],
            "examples": [
                {"text": "The dog runs.", "type": "example"},
                {"text": "A quoted sentence.", "type": "quotation"},
            ],
            "synonyms": [{"word": "canine"}],
            "antonyms": [{"word": "cat"}],
        }
    ],
    "translations": [
        {
            "lang_code": "cmn",
            "word": "狗",
            "roman": "gǒu",
            "sense": "A domesticated animal",
        },
        {"lang_code": "fr", "word": "chien", "sense": "animal"},
    ],
}


class DictionaryKaikkiTest(unittest.TestCase):
    def test_builds_stable_target_url(self):
        self.assertEqual(
            MODULE.build_kaikki_url("well-being"),
            "https://kaikki.org/dictionary/English/meaning/w/we/well-being.jsonl",
        )
        self.assertEqual(
            MODULE.build_kaikki_url("Fahrenheit"),
            "https://kaikki.org/dictionary/English/meaning/F/Fa/Fahrenheit.jsonl",
        )

    def test_lookup_words_exposes_case_and_audited_spelling_fallbacks(self):
        self.assertEqual(MODULE._lookup_words("fahrenheit"), ("fahrenheit", "Fahrenheit"))
        self.assertEqual(
            MODULE._lookup_words("reservior"),
            ("reservior", "Reservior", "reservoir"),
        )

    def test_lookup_words_exposes_audited_pronunciation_aliases(self):
        self.assertEqual(
            MODULE._lookup_words("theatre"),
            ("theatre", "Theatre", "theater"),
        )
        self.assertEqual(
            MODULE._lookup_words("intellectually"),
            ("intellectually", "Intellectually", "intellectual"),
        )
        self.assertEqual(
            MODULE._lookup_words("world-wide"),
            ("world-wide", "World-wide", "worldwide"),
        )

    def test_compacts_english_senses_pronunciation_and_chinese_translation(self):
        records = MODULE.parse_kaikki_jsonl(
            json.dumps(SAMPLE_RECORD, ensure_ascii=False), "dog"
        )

        self.assertEqual(len(records), 1)
        record = records[0]
        self.assertEqual(record["pos"], "noun")
        self.assertEqual(record["ipa"]["uk"], ["/dɒɡ/"])
        self.assertEqual(record["ipa"]["us"], ["/dɔːɡ/"])
        self.assertEqual(record["forms"][0]["form"], "dogs")
        self.assertEqual(record["senses"][0]["examples"], ["The dog runs."])
        self.assertEqual(record["translations_zh"][0]["word"], "狗")
        self.assertEqual(record["senses"][0]["synonyms"], ["canine"])

    def test_does_not_count_missing_sounds_as_an_empty_ipa_map(self):
        record = {"word": "x-ray", "lang_code": "en", "pos": "noun", "sounds": None}

        parsed = MODULE.parse_kaikki_jsonl(json.dumps(record), "x-ray")

        self.assertEqual(parsed[0]["ipa"], {})

    def test_parser_can_attach_audited_alias_page_to_requested_word(self):
        records = MODULE.parse_kaikki_jsonl(
            json.dumps({**SAMPLE_RECORD, "word": "reservoir"}, ensure_ascii=False),
            "reservior",
            accepted_words=("reservoir",),
        )

        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]["word"], "reservoir")

    def test_page_resolution_uses_actual_case_from_cached_content(self):
        page = MODULE.build_kaikki_entry(
            "fahrenheit",
            json.dumps({**SAMPLE_RECORD, "word": "Fahrenheit"}, ensure_ascii=False),
            MODULE.build_kaikki_url("fahrenheit"),
        )

        resolved = MODULE._annotate_page_resolution(
            page, "fahrenheit", "fahrenheit", MODULE.KAIKKI_PAGE_BASE
        )

        self.assertEqual(resolved["match_type"], "case_variant")
        self.assertEqual(resolved["resolved_word"], "Fahrenheit")
        self.assertIn("/F/Fa/Fahrenheit.jsonl", resolved["page_url"])

    def test_exact_page_keeps_an_audited_alias_pronunciation_page(self):
        with tempfile.TemporaryDirectory() as directory:
            cache_dir = pathlib.Path(directory)
            target_path = MODULE._cache_path("theatre", cache_dir)
            alias_path = MODULE._cache_path("theater", cache_dir)
            target_path.write_text(
                json.dumps(
                    {"word": "theatre", "lang_code": "en", "pos": "noun", "sounds": []}
                )
                + "\n",
                encoding="utf-8",
            )
            alias_path.write_text(
                json.dumps(
                    {**SAMPLE_RECORD, "word": "theater"}, ensure_ascii=False
                )
                + "\n",
                encoding="utf-8",
            )

            page = MODULE.fetch_kaikki_page(
                "theatre",
                MODULE.FetchOptions(cache_dir=cache_dir, timeout=1, retries=1),
            )

        self.assertEqual(page["match_type"], "exact")
        self.assertEqual(page["records"][0]["word"], "theatre")
        self.assertEqual(page["pronunciation_alias_pages"][0]["resolved_word"], "theater")
        self.assertEqual(
            page["pronunciation_alias_pages"][0]["records"][0]["word"],
            "theater",
        )

    def test_ignores_non_target_and_malformed_json_lines(self):
        lines = "\n".join(
            [
                "not json",
                json.dumps({"word": "cat", "lang_code": "en", "pos": "noun"}),
                json.dumps(SAMPLE_RECORD, ensure_ascii=False),
            ]
        )

        records = MODULE.parse_kaikki_jsonl(lines, "dog")

        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]["word"], "dog")

    def test_merge_keeps_draft_and_source_layers_separate(self):
        payload = {
            "schema_version": 1,
            "entries": [
                {
                    "lemma": "dog",
                    "source_ids": ["open-ecdict", "wordnet-3.0"],
                    "quality": {"status": "draft"},
                    "missing_fields": ["bilingual_examples", "human_review"],
                }
            ],
        }
        page = MODULE.build_kaikki_entry(
            "dog",
            json.dumps(SAMPLE_RECORD, ensure_ascii=False),
            MODULE.build_kaikki_url("dog"),
            cache_file="dog.jsonl",
            sha256="abc",
        )

        merged = MODULE.merge_kaikki_layer(payload, {"dog": page})
        entry = merged["entries"][0]

        self.assertEqual(entry["quality"]["status"], "draft")
        self.assertIn("bilingual_examples", entry["missing_fields"])
        self.assertIn(MODULE.KAIKKI_SOURCE_ID, entry["source_ids"])
        self.assertEqual(entry["kaikki"]["records"][0]["translations_zh"][0]["word"], "狗")

    def test_report_counts_missing_pages_without_promoting_entries(self):
        payload = {
            "entries": [
                {"lemma": "dog", "quality": {"status": "draft"}},
                {"lemma": "cat", "quality": {"status": "draft"}},
            ]
        }
        page = MODULE.build_kaikki_entry(
            "dog", json.dumps(SAMPLE_RECORD, ensure_ascii=False), MODULE.build_kaikki_url("dog")
        )
        merged = MODULE.merge_kaikki_layer(payload, {"dog": page})
        report = MODULE.build_kaikki_report(merged["entries"])

        self.assertEqual(report["total_entries"], 2)
        self.assertEqual(report["matched_pages"], 1)
        self.assertEqual(report["missing_pages"], 1)
        self.assertEqual(report["entries_with_chinese_translations"], 1)
        self.assertEqual(report["draft_entries"], 2)


if __name__ == "__main__":
    unittest.main()
