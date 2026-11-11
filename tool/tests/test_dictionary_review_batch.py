import importlib.util
import pathlib
import unittest


MODULE_PATH = pathlib.Path(__file__).parents[1] / "build_dictionary_review_batch.py"
SPEC = importlib.util.spec_from_file_location("dictionary_review_batch", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


def _candidate(lemma):
    return {
        "entry_id": f"yixue-editorial.en-zh.{lemma}",
        "lemma": lemma,
        "coverage_bands": ["cet4"],
        "source_ids": ["open-ecdict"],
        "rich_candidate": {
            "lemma": lemma,
            "quality": {"status": "draft"},
            "sense_candidates": [{"source_id": "open-ecdict"}],
        },
    }


def _queue(lemma, priority):
    return {
        "entry_id": f"yixue-editorial.en-zh.{lemma}",
        "lemma": lemma,
        "priority": priority,
        "status": "pending",
        "quality_status": "draft",
        "review_fields": ["human_review"],
        "candidate_metrics": {"sense_candidates": 1},
        "source_evidence": {"sense_candidates": ["open-ecdict"]},
        "source_ids": ["open-ecdict"],
        "source_urls": [],
        "coverage_bands": ["cet4"],
        "learning_tags": ["cet4"],
    }


class DictionaryReviewBatchTest(unittest.TestCase):
    def test_selects_deterministic_queue_slice_and_keeps_pending_template(self):
        candidates = [_candidate("alpha"), _candidate("beta"), _candidate("gamma")]
        queue = [_queue("alpha", "high"), _queue("beta", "high"), _queue("gamma", "medium")]

        batch = MODULE.build_review_batch(candidates, queue, batch_number=1, batch_size=2)

        self.assertEqual(batch["batch_id"], "yixue-review-v1-001")
        self.assertEqual([item["lemma"] for item in batch["entries"]], ["alpha", "beta"])
        self.assertEqual(batch["entries"][0]["candidate"]["quality"]["status"], "draft")
        self.assertEqual(batch["entries"][0]["priority"], "high")
        self.assertEqual(batch["entries"][0]["review_fields"], ["human_review"])
        self.assertEqual(batch["entries"][0]["recommended_action"], "")
        self.assertEqual(batch["entries"][0]["review"]["status"], "pending")
        self.assertIsNone(batch["entries"][0]["review"]["reviewed_entry"])
        self.assertFalse(batch["entries"][0]["review"]["human_review"])
        self.assertTrue(all(value is False for value in batch["entries"][0]["review"]["checks"].values()))

    def test_rejects_candidate_or_queue_mismatch(self):
        with self.assertRaisesRegex(ValueError, "missing candidate"):
            MODULE.build_review_batch(
                [_candidate("alpha")],
                [_queue("beta", "high")],
                batch_number=1,
                batch_size=1,
            )

    def test_rejects_invalid_batch_arguments(self):
        with self.assertRaises(ValueError):
            MODULE.build_review_batch([], [], batch_number=0, batch_size=1)
        with self.assertRaises(ValueError):
            MODULE.build_review_batch([], [], batch_number=1, batch_size=0)

    def test_numeric_priority_keeps_high_risk_words_first(self):
        candidates = [_candidate("low"), _candidate("high"), _candidate("medium")]
        queue = [_queue("low", "45"), _queue("high", "100"), _queue("medium", "65")]

        batch = MODULE.build_review_batch(candidates, queue, batch_number=1, batch_size=2)

        self.assertEqual([item["lemma"] for item in batch["entries"]], ["high", "medium"])
        self.assertEqual(batch["entries"][0]["priority"], "100")


if __name__ == "__main__":
    unittest.main()
