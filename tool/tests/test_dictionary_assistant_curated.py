import importlib.util
import pathlib
import unittest


MODULE_PATH = pathlib.Path(__file__).parents[1] / "build_dictionary_assistant_curated_layer.py"
SPEC = importlib.util.spec_from_file_location("dictionary_assistant_curated", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


def _candidate(lemma="abandon"):
    return {
        "entry_id": f"yixue-editorial.en-zh.{lemma}",
        "lemma": lemma,
        "base": {
            "ipa": "/əˈbændən/",
            "part_of_speech": "verb",
        },
        "rich_candidate": {
            "entry_id": f"yixue-editorial.en-zh.{lemma}",
            "language_pair": "en-zh",
            "lemma": lemma,
            "coverage_bands": ["cet4"],
            "learning_tags": ["cet4"],
            "source_ids": ["open-ecdict", "wordnet-3.0", "tatoeba-cc-by-2.0-fr"],
            "pronunciation_candidates": [
                {
                    "value": "/əˈbændən/",
                    "dialect": "uk",
                    "notation": "ipa",
                    "source_id": "open-ecdict",
                }
            ],
            "part_of_speech_candidates": [
                {"value": "verb", "source_id": "wordnet-3.0"}
            ],
            "sense_candidates": [
                {
                    "source_id": "wordnet-3.0",
                    "sense_id": "1",
                    "part_of_speech": "verb",
                    "english_glosses": ["leave someone behind"],
                    "chinese_glosses": ["抛弃"],
                    "usage_tags": ["formal"],
                    "source_examples": ["He abandoned the plan."],
                    "synonyms": ["forsake"],
                    "antonyms": ["keep"],
                }
            ],
            "english_examples": [{"text": "He abandoned the plan.", "source_id": "wordnet-3.0"}],
            "bilingual_examples": [
                {
                    "example_id": "tatoeba:1:2",
                    "source_id": "tatoeba-cc-by-2.0-fr",
                    "english_text": "He abandoned the plan.",
                    "chinese_text": "他放弃了计划。",
                    "attribution": {"english_username": "a", "chinese_username": "b"},
                    "review_status": "candidate",
                }
            ],
            "collocation_candidates": [
                {
                    "text": "abandon a plan",
                    "source_id": "tatoeba-cc-by-2.0-fr",
                    "review_status": "candidate",
                }
            ],
            "relation_candidates": [
                {"relation": "similar_to", "term": "forsake", "source_id": "wordnet-3.0"}
            ],
            "variants": [
                {
                    "form": "abandoned",
                    "tags": ["past"],
                    "source_ids": ["open-ecdict"],
                    "part_of_speech": "verb",
                }
            ],
            "quality": {"status": "draft", "review_fields": ["human_review"]},
        },
    }


class DictionaryAssistantCuratedTest(unittest.TestCase):
    def test_consolidates_source_fields_without_promoting_quality(self):
        entry = MODULE.build_assistant_curated_entry(
            _candidate(), candidate_source="candidate.json", candidate_index=0
        )

        self.assertEqual(entry["part_of_speech"], "verb")
        self.assertEqual(entry["ipa"]["uk"], "/əˈbændən/")
        self.assertEqual(entry["senses"][0]["chinese_glosses"], ["抛弃"])
        self.assertEqual(entry["bilingual_examples"][0]["translation"], "他放弃了计划。")
        self.assertEqual(entry["collocations"], ["abandon a plan"])
        self.assertEqual(entry["relations"]["similar_to"], ["forsake"])
        self.assertEqual(entry["variants"], ["abandoned"])
        self.assertEqual(entry["quality"]["status"], "assistant_curated_draft")
        self.assertFalse(entry["quality"]["human_review"])
        self.assertIn("sense_alignment", entry["review_flags"])

    def test_uses_base_ipa_as_explicit_candidate_fallback(self):
        candidate = _candidate("fallback")
        candidate["rich_candidate"]["pronunciation_candidates"] = []
        entry = MODULE.build_assistant_curated_entry(
            candidate, candidate_source="candidate.json", candidate_index=0
        )

        self.assertEqual(entry["ipa"], {"base_candidate": "/əˈbændən/"})
        self.assertIn("pronunciation_candidates", entry["review_flags"])

    def test_recovers_english_examples_already_attached_to_senses(self):
        candidate = _candidate("sense-example")
        candidate["rich_candidate"]["english_examples"] = []
        entry = MODULE.build_assistant_curated_entry(
            candidate, candidate_source="candidate.json", candidate_index=0
        )

        self.assertEqual(entry["english_examples"][0]["text"], "He abandoned the plan.")
        self.assertNotIn("english_examples", entry["review_flags"])

    def test_rejects_duplicate_lemmas(self):
        second = _candidate("same")
        second["entry_id"] = "yixue-editorial.en-zh.same-2"
        second["rich_candidate"]["entry_id"] = "yixue-editorial.en-zh.same-2"
        with self.assertRaisesRegex(ValueError, "duplicate lemma"):
            list(
                MODULE.iter_assistant_curated_entries(
                    [_candidate("same"), second], candidate_source="candidate.json"
                )
            )


if __name__ == "__main__":
    unittest.main()
