import importlib.util
import pathlib
import sys
import unittest


MODULE_PATH = pathlib.Path(__file__).parents[1] / "build_dictionary_review_queue.py"
SPEC = importlib.util.spec_from_file_location("dictionary_review_queue", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def _entry(lemma, review_fields):
    return {
        "lemma": lemma,
        "entry_id": f"yixue-editorial.en-zh.{lemma}",
        "source_ids": ["open-ecdict"],
        "quality": {"status": "draft"},
        "kaikki": {
            "status": "ok",
            "page_url": f"https://kaikki.org/{lemma}.jsonl",
            "resolved_word": lemma,
        },
        "rich_candidate": {
            "lemma": lemma,
            "quality": {"status": "draft", "review_fields": review_fields},
            "pronunciation_candidates": [] if "ipa" in review_fields else [{"value": "/a/", "source_id": "wordnet-3.0"}],
            "sense_candidates": [
                {"source_id": "open-ecdict"},
                {"source_id": "wordnet-3.0"},
            ],
            "english_examples": [] if "english_examples" in review_fields else [{"text": "A."}],
            "bilingual_examples": [] if "bilingual_examples" in review_fields else [{"english_text": "A."}],
            "variants": [] if "variants" in review_fields else [{"form": "as"}],
        },
    }


class DictionaryReviewQueueTest(unittest.TestCase):
    def test_priority_puts_structural_gaps_before_example_gaps(self):
        structural = MODULE.build_review_item(_entry("alpha", ["ipa", "human_review"]))
        example = MODULE.build_review_item(_entry("beta", ["bilingual_examples", "human_review"]))

        self.assertGreater(structural["priority"], example["priority"])
        self.assertEqual(structural["status"], "pending")
        self.assertEqual(structural["quality_status"], "draft")
        self.assertIn("sense_candidates", structural["source_evidence"])
        self.assertIn("wordnet-3.0", structural["source_evidence"]["sense_candidates"])
        self.assertIn("https://kaikki.org/alpha.jsonl", structural["source_urls"])

    def test_build_report_counts_all_pending_items(self):
        rows = [
            MODULE.build_review_item(_entry("alpha", ["ipa", "human_review"])),
            MODULE.build_review_item(_entry("beta", ["bilingual_examples", "human_review"])),
        ]

        report = MODULE.build_review_report(rows)

        self.assertEqual(report["total_entries"], 2)
        self.assertEqual(report["pending_entries"], 2)
        self.assertEqual(report["missing_field_counts"]["ipa"], 1)
        self.assertEqual(report["missing_field_counts"]["bilingual_examples"], 1)

    def test_alias_pronunciation_review_is_structural_and_actionable(self):
        item = MODULE.build_review_item(
            _entry("theatre", ["pronunciation_alias_review", "human_review"])
        )

        self.assertEqual(item["priority"], 90)
        self.assertEqual(
            item["recommended_action"],
            "核对别名或派生词音标是否适用于当前词形",
        )


if __name__ == "__main__":
    unittest.main()
