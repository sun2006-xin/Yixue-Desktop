import importlib.util
import json
import pathlib
import sys
import unittest


MODULE_PATH = pathlib.Path(__file__).parents[1] / "build_dictionary_rich_candidates.py"
SPEC = importlib.util.spec_from_file_location("dictionary_rich", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def _entry():
    return {
        "lemma": "dog",
        "learning_tags": ["cet4"],
        "variants": ["dogs"],
        "frequency": {"bnc_rank": 100, "modern_rank": 200},
        "base": {
            "ipa": "/dɒɡ/",
            "part_of_speech": "n.",
            "meanings": ["狗"],
            "source_translations": ["n. 狗"],
            "coverage_bands": ["cet4"],
        },
        "ecdict": {
            "source_id": "ecdict-raw-master",
            "found": True,
            "phonetic": "dɔg",
            "definitions": ["n. a domesticated animal"],
            "translations": ["n. 狗"],
            "tags": ["cet4"],
        },
        "wordnet": {
            "source_id": "wordnet-3.0",
            "sense_count": 1,
            "senses": [
                {
                    "synset_offset": "00000001",
                    "part_of_speech": "noun",
                    "lemmas": ["dog", "canine"],
                    "definition": "a domesticated animal",
                    "examples": ["The dog runs."],
                    "relations": {"hypernyms": ["animal"]},
                }
            ],
        },
        "tatoeba_examples": [
            {
                "english_id": "10",
                "chinese_id": "20",
                "english_text": "The dog runs.",
                "chinese_text": "这只狗在跑。",
                "english_username": "alice",
                "chinese_username": "bob",
                "english_date_modified": "2020-01-02",
                "chinese_date_modified": "2020-01-03",
            }
        ],
        "collocation_candidates": ["dog runs"],
        "relations": {"hypernyms": ["animal"]},
        "source_ids": ["open-ecdict", "wordnet-3.0", "tatoeba-cc-by-2.0-fr", "ecdict-raw-master"],
        "quality": {"status": "draft"},
        "missing_fields": ["collocations", "human_review"],
        "kaikki": {
            "source_id": "wiktionary-kaikki-2026-09",
            "status": "ok",
            "requested_word": "dog",
            "resolved_word": "dog",
            "match_type": "exact",
            "records": [
                {
                    "word": "dog",
                    "pos": "noun",
                    "ipa": {"uk": ["/dɒɡ/"]},
                    "forms": [{"form": "dogs", "tags": ["plural"]}],
                    "senses": [
                        {
                            "glosses": ["A domesticated animal."],
                            "tags": ["countable"],
                            "examples": ["The dog runs."],
                            "synonyms": ["canine"],
                            "antonyms": [],
                        }
                    ],
                    "translations_zh": [
                        {"lang_code": "cmn", "word": "狗", "sense": "animal", "roman": "gǒu", "tags": []}
                    ],
                    "relations": {"hypernyms": ["animal"]},
                }
            ],
        },
    }


class DictionaryRichCandidateTest(unittest.TestCase):
    def test_builds_source_separated_rich_fields(self):
        rich = MODULE.build_rich_candidate(_entry())

        self.assertEqual(rich["lemma"], "dog")
        self.assertIn("/dɒɡ/", [item["value"] for item in rich["pronunciation_candidates"]])
        self.assertIn("狗", rich["sense_candidates"][0]["chinese_glosses"])
        self.assertTrue(any(item["source_id"] == "wordnet-3.0" for item in rich["sense_candidates"]))
        self.assertTrue(any(item["source_id"] == "wiktionary-kaikki-2026-09" for item in rich["sense_candidates"]))
        self.assertTrue(all(item.get("sense_id") for item in rich["sense_candidates"]))
        self.assertEqual(rich["sense_candidates"][0]["sense_id"], "record:open-ecdict")
        self.assertEqual(rich["bilingual_examples"][0]["attribution"]["english_username"], "alice")

    def test_does_not_mark_candidates_as_reviewed_or_published(self):
        rich = MODULE.build_rich_candidate(_entry())

        self.assertEqual(rich["quality"]["status"], "draft")
        self.assertIn("human_review", rich["quality"]["review_fields"])
        self.assertIn("collocations", rich["quality"]["review_fields"])

    def test_alias_pronunciation_keeps_requested_word_and_source_word(self):
        pronunciation = MODULE._build_pronunciation(
            {"lemma": "theatre"},
            [{"pos": "noun", "ipa": {"uk": ["/ˈθiː.ə.tə/"]}}],
            {
                "match_type": "alias",
                "resolved_word": "theater",
            },
        )

        self.assertEqual(pronunciation[0]["value"], "/ˈθiː.ə.tə/")
        self.assertEqual(pronunciation[0]["source_word"], "theater")
        self.assertEqual(pronunciation[0]["resolution"], "audited_alias_candidate")

    def test_merge_and_report_cover_all_entries_without_mutating_source_status(self):
        payload = {"entries": [_entry()]}
        merged = MODULE.merge_rich_layer(payload)
        report = MODULE.build_rich_report(merged["entries"])

        self.assertIn("rich_candidate", merged["entries"][0])
        self.assertEqual(merged["entries"][0]["quality"]["status"], "draft")
        self.assertEqual(report["total_entries"], 1)
        self.assertEqual(report["entries_with_rich_candidates"], 1)
        self.assertEqual(report["draft_entries"], 1)
        self.assertFalse(report["publishable_entries"])


if __name__ == "__main__":
    unittest.main()
