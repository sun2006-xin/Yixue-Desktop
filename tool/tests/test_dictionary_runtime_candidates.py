import importlib.util
import pathlib
import sys
import unittest


MODULE_PATH = pathlib.Path(__file__).parents[1] / "build_dictionary_runtime_candidates.py"
SPEC = importlib.util.spec_from_file_location("dictionary_runtime_candidates", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def _payload():
    return {
        "entries": [
            {
                "lemma": "dog",
                "rich_candidate": {
                    "bilingual_examples": [
                        {
                            "example_id": "tatoeba:1:2",
                            "source_id": "tatoeba-cc-by-2.0-fr",
                            "english_text": "The dog's name is O'Reilly.",
                            "chinese_text": "这只狗的名字是奥莱利。",
                            "attribution": {
                                "english_username": "alice",
                                "chinese_username": "bob",
                            },
                        },
                        {
                            "example_id": "tatoeba:1:2",
                            "source_id": "tatoeba-cc-by-2.0-fr",
                            "english_text": "duplicate",
                            "chinese_text": "重复",
                        },
                        {
                            "example_id": "tatoeba:3:4",
                            "source_id": "tatoeba-cc-by-2.0-fr",
                            "english_text": "A quotation candidate.",
                            "chinese_text": "引文候选。",
                        },
                    ],
                    "sense_candidates": [
                        {
                            "source_id": "wordnet-3.0",
                            "sense_id": "12345678",
                            "part_of_speech": "noun",
                            "english_glosses": ["a domesticated canine animal"],
                            "chinese_glosses": ["狗", "损坏 � 文本"],
                            "usage_tags": ["countable", "countable"],
                            "source_examples": ["The dog waited by the door."],
                            "qualifier": "common usage",
                        },
                        {
                            "source_id": "wiktionary-kaikki-2026-09",
                            "chinese_translation_candidates": [
                                {"lang_code": "cmn", "word": "狗"},
                                {"lang_code": "cmn", "word": "坏 � 文本"},
                            ],
                        },
                    ],
                },
            },
            {
                "lemma": "bad",
                "rich_candidate": {
                    "bilingual_examples": [
                        {
                            "example_id": "tatoeba:5:6",
                            "source_id": "tatoeba-cc-by-2.0-fr",
                            "english_text": "broken � text",
                            "chinese_text": "不应进入运行时",
                        }
                    ]
                },
            },
            {
                "lemma": "cat",
                "rich_candidate": {
                    "variants": [
                        {"form": "cats"},
                        {"form": "cat"},
                    ],
                    "collocation_candidates": [
                        {"text": "black cat"},
                        {"text": "black cat"},
                    ],
                    "relation_candidates": [
                        {"relation": "hypernyms", "term": "animal"},
                        {"relation": "hypernyms", "term": "animal"},
                        {"relation": "hyponyms", "term": "kitten"},
                    ],
                    "part_of_speech_candidates": [
                        {"value": "noun", "source_id": "wordnet-3.0"},
                        {"value": "noun", "source_id": "wordnet-3.0"},
                    ],
                    "pronunciation_candidates": [
                        {
                            "value": "/kæt/",
                            "dialect": "uk",
                            "notation": "ipa",
                            "source_id": "wiktionary-kaikki-2026-09",
                            "part_of_speech": "noun",
                            "source_word": "cat",
                            "resolution": "audited_alias_candidate",
                        },
                        {
                            "value": "broken � ipa",
                            "dialect": "us",
                            "notation": "ipa",
                            "source_id": "bad-source",
                        },
                    ],
                    "learning_tags": ["cet4", "cet4", "bad � tag"],
                    "frequency": {"bnc_rank": 10, "modern_rank": 20},
                    "quality": {
                        "status": "draft",
                        "review_fields": ["ipa", "human_review", "ipa"],
                    },
                    "source_ids": ["open-ecdict", "wordnet-3.0"],
                },
            },
        ]
    }


class DictionaryRuntimeCandidatesTest(unittest.TestCase):
    def test_selects_stable_bilingual_candidates_and_deduplicates_ids(self):
        rows = MODULE.build_runtime_rows(_payload())

        self.assertEqual([row["word"] for row in rows], ["dog"])
        self.assertEqual(len(rows[0]["examples"]), 2)
        self.assertEqual(rows[0]["examples"][0]["example_id"], "tatoeba:1:2")
        self.assertEqual(rows[0]["examples"][0]["english_username"], "alice")

    def test_render_escapes_dart_interpolation_and_keeps_candidate_marker(self):
        rows = MODULE.build_runtime_rows(_payload())
        source = MODULE.render_shard(rows, 1)

        self.assertIn("Source: Tatoeba bilingual candidates", source)
        self.assertIn("O\\'Reilly", source)
        self.assertNotIn("�", source)
        self.assertIn("OpenCetRichExampleRow", source)

    def test_report_never_calls_candidates_published(self):
        rows = MODULE.build_runtime_rows(_payload())
        report = MODULE.build_report(rows, total_entries=2)

        self.assertEqual(report["quality_status"], "candidate")
        self.assertEqual(report["entries_with_bilingual_candidates"], 1)
        self.assertNotIn("published_entries", report)

    def test_selects_bounded_metadata_without_self_variant_or_duplicate_terms(self):
        rows = MODULE.build_runtime_metadata_rows(_payload())

        self.assertEqual([row["word"] for row in rows], ["cat"])
        self.assertEqual(rows[0]["variants"], ["cats"])
        self.assertEqual(rows[0]["collocations"], ["black cat"])
        self.assertEqual(rows[0]["relations"], {
            "hypernyms": ["animal"],
            "hyponyms": ["kitten"],
        })
        self.assertEqual(
            [(item["value"], item["source_id"]) for item in rows[0]["part_of_speech_candidates"]],
            [("noun", "wordnet-3.0")],
        )
        self.assertEqual(rows[0]["pronunciation_candidates"][0]["value"], "/kæt/")
        self.assertEqual(rows[0]["pronunciation_candidates"][0]["source_word"], "cat")
        self.assertEqual(
            rows[0]["pronunciation_candidates"][0]["resolution"],
            "audited_alias_candidate",
        )
        self.assertEqual(rows[0]["learning_tags"], ["cet4"])
        self.assertEqual(rows[0]["frequency"], {"bnc_rank": 10, "modern_rank": 20})
        self.assertEqual(rows[0]["review_fields"], ["ipa", "human_review"])
        self.assertEqual(rows[0]["source_ids"], ["open-ecdict", "wordnet-3.0"])

        report = MODULE.build_report(
            [],
            total_entries=3,
            metadata_rows=rows,
        )
        self.assertEqual(report["entries_with_direct_pronunciation_candidates"], 0)
        self.assertEqual(report["entries_with_alias_pronunciation_candidates"], 1)
        self.assertEqual(report["entries_without_pronunciation_candidates"], 0)

        source = MODULE.render_metadata_shard(rows, 1)
        self.assertIn("OpenCetRichPartOfSpeechRow", source)
        self.assertIn("OpenCetRichPronunciationRow", source)
        self.assertIn("sourceWord: 'cat'", source)
        self.assertIn("resolution: 'audited_alias_candidate'", source)
        self.assertIn("reviewFields: <String>[", source)
        self.assertIn("'human_review',", source)
        self.assertNotIn("�", source)

    def test_selects_source_separated_senses_and_filters_corrupt_text(self):
        rows = MODULE.build_runtime_sense_rows(_payload())

        self.assertEqual([row["word"] for row in rows], ["dog"])
        self.assertEqual(len(rows[0]["senses"]), 2)
        first = rows[0]["senses"][0]
        self.assertEqual(first["source_id"], "wordnet-3.0")
        self.assertEqual(first["sense_id"], "12345678")
        self.assertEqual(first["chinese_glosses"], ["狗"])
        self.assertEqual(first["usage_tags"], ["countable"])
        self.assertEqual(first["quality_status"], "candidate")
        self.assertTrue(all("�" not in str(value) for value in first.values()))

    def test_render_senses_and_report_keep_candidate_boundary(self):
        rows = MODULE.build_runtime_sense_rows(_payload())
        source = MODULE.render_sense_shard(rows, 1)
        report = MODULE.build_report([], total_entries=3, sense_rows=rows)

        self.assertIn("OpenCetRichSenseRow", source)
        self.assertIn("sourceId: 'wordnet-3.0'", source)
        self.assertNotIn("�", source)
        self.assertEqual(report["entries_with_sense_candidates"], 1)
        self.assertEqual(report["sense_candidate_count"], 2)
        self.assertEqual(report["quality_status"], "candidate")


if __name__ == "__main__":
    unittest.main()
