import importlib.util
import pathlib
import unittest


MODULE_PATH = pathlib.Path(__file__).parents[1] / "build_blind_translation_review.py"
SPEC = importlib.util.spec_from_file_location("blind_translation_review", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def report(model_prefix, count=4, suite_id="suite-v2"):
    return {
        "suite_id": suite_id,
        "cases": [
            {
                "id": f"case-{index}",
                "category": "terminology",
                "source_language": "english",
                "target_language": "chinese",
                "source": f"source {index}",
                "references": [f"reference {index}"],
                "translation": f"{model_prefix} output {index}",
            }
            for index in range(count)
        ],
    }


class BlindReviewTest(unittest.TestCase):
    def test_build_is_deterministic_and_position_balanced(self):
        rows, key = MODULE.build_review(report("left"), report("right"), "OPUS", "candidate", 17)
        repeated_rows, repeated_key = MODULE.build_review(
            report("left"), report("right"), "OPUS", "candidate", 17
        )
        self.assertEqual(rows, repeated_rows)
        self.assertEqual(key, repeated_key)
        self.assertEqual(sum(item["a_model"] == "candidate" for item in key["assignments"]), 2)

    def test_review_rows_hide_model_names_and_include_blank_scores(self):
        rows, _ = MODULE.build_review(report("left"), report("right"), "OPUS", "candidate", 7)
        serialized = repr(rows)
        self.assertNotIn("OPUS", serialized)
        self.assertNotIn("candidate", serialized)
        self.assertEqual(rows[0]["accuracy_a_1_to_5"], "")
        self.assertEqual(rows[0]["reviewer_notes"], "")

    def test_rejects_mismatched_suite_or_cases(self):
        with self.assertRaisesRegex(ValueError, "suite IDs"):
            MODULE.build_review(report("left"), report("right", suite_id="other"), "a", "b", 1)
        with self.assertRaisesRegex(ValueError, "case IDs"):
            MODULE.build_review(report("left"), report("right", count=3), "a", "b", 1)

    def test_rejects_source_drift_for_same_case(self):
        changed = report("right")
        changed["cases"][0]["source"] = "changed source"
        with self.assertRaisesRegex(ValueError, "source differs"):
            MODULE.build_review(report("left"), changed, "a", "b", 1)


if __name__ == "__main__":
    unittest.main()
