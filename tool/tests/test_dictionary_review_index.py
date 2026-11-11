import importlib.util
import pathlib
import unittest


MODULE_PATH = pathlib.Path(__file__).parents[1] / "build_dictionary_review_index.py"
SPEC = importlib.util.spec_from_file_location("dictionary_review_index", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


def _queue(lemma, priority):
    return {
        "entry_id": f"yixue-reviewed.{lemma}",
        "lemma": lemma,
        "priority": priority,
        "coverage_bands": ["cet4"],
    }


class DictionaryReviewIndexTest(unittest.TestCase):
    def test_assigns_every_lemma_once_in_deterministic_batches(self):
        queue = [
            _queue("zulu", "medium"),
            _queue("alpha", "high"),
            _queue("beta", "high"),
            _queue("gamma", "medium"),
            _queue("delta", "low"),
        ]

        index, report = MODULE.build_review_index(queue, batch_size=2)

        self.assertTrue(report["passed"])
        self.assertEqual(index["total_entries"], 5)
        self.assertEqual(index["total_batches"], 3)
        self.assertEqual(
            [lemma for batch in index["batches"] for lemma in batch["lemmas"]],
            ["alpha", "beta", "gamma", "zulu", "delta"],
        )
        self.assertEqual(index["pending_entries"], 5)
        self.assertTrue(all(batch["status"] == "pending" for batch in index["batches"]))

    def test_reports_partial_review_progress_without_promoting_candidates(self):
        queue = [_queue("alpha", "high"), _queue("beta", "medium"), _queue("gamma", "medium")]

        index, report = MODULE.build_review_index(
            queue,
            batch_size=2,
            reviewed_lemmas={"alpha"},
        )

        self.assertTrue(report["passed"])
        self.assertEqual(index["reviewed_entries"], 1)
        self.assertEqual(index["pending_entries"], 2)
        self.assertEqual(index["batches"][0]["status"], "in_progress")
        self.assertEqual(index["batches"][1]["status"], "pending")

    def test_rejects_duplicate_queue_lemmas(self):
        with self.assertRaisesRegex(ValueError, "duplicate lemma"):
            MODULE.build_review_index(
                [_queue("same", "high"), _queue("same", "medium")],
                batch_size=2,
            )

    def test_numeric_priority_uses_the_same_buckets_as_the_review_queue(self):
        queue = [
            _queue("normal", 45),
            _queue("high", 100),
            _queue("medium", 65),
            _queue("urgent", 80),
        ]

        index, _ = MODULE.build_review_index(queue, batch_size=4)

        self.assertEqual(
            index["batches"][0]["lemmas"], ["high", "urgent", "medium", "normal"]
        )
        self.assertEqual(index["batches"][0]["priority_counts"], {"high": 2, "medium": 2})


if __name__ == "__main__":
    unittest.main()
