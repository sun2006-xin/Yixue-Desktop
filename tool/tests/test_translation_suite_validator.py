import copy
import importlib.util
import pathlib
import unittest


MODULE_PATH = pathlib.Path(__file__).parents[1] / "validate_translation_suite.py"
SPEC = importlib.util.spec_from_file_location("translation_suite_validator", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def valid_registry():
    return {
        "schema_version": 1,
        "sources": [
            {
                "id": "yixue-authored-v1",
                "origin": "project_authored",
                "redistribution": "allowed",
            }
        ],
    }


def valid_suite():
    cases = []
    counter = 0
    for source_language, target_language, prefix in (
        ("english", "chinese", "en-zh"),
        ("chinese", "english", "zh-en"),
    ):
        for category in MODULE.REQUIRED_CATEGORIES:
            for index in range(8):
                counter += 1
                case = {
                    "id": f"{prefix}-{category}-{index + 1:02d}",
                    "category": category,
                    "difficulty": (index % 3) + 1,
                    "source_language": source_language,
                    "target_language": target_language,
                    "source": f"Unique source {counter}",
                    "references": [f"Unique reference {counter}"],
                    "provenance": {"source_id": "yixue-authored-v1"},
                    "contains_personal_data": False,
                }
                if category == "formatting":
                    case["preserve"] = [str(counter)]
                    case["source"] += f" value {counter}"
                cases.append(case)
    return {
        "schema_version": 2,
        "id": "valid-suite",
        "purpose": "fixed_evaluation",
        "cases": cases,
    }


class TranslationSuiteValidatorTest(unittest.TestCase):
    def test_balanced_project_authored_suite_is_valid(self):
        self.assertEqual(MODULE.validate_suite(valid_suite(), valid_registry(), []), [])

    def test_rejects_duplicate_id_and_normalized_source(self):
        suite = valid_suite()
        suite["cases"][1]["id"] = suite["cases"][0]["id"]
        suite["cases"][1]["source"] = "  UNIQUE   SOURCE 1  "
        errors = MODULE.validate_suite(suite, valid_registry(), [])
        self.assertTrue(any("duplicate id" in error for error in errors))
        self.assertTrue(any("duplicate source" in error for error in errors))

    def test_rejects_unregistered_or_nonredistributable_source(self):
        suite = valid_suite()
        suite["cases"][0]["provenance"]["source_id"] = "missing"
        registry = valid_registry()
        registry["sources"][0]["redistribution"] = "internal_only"
        errors = MODULE.validate_suite(suite, registry, [])
        self.assertTrue(any("unregistered source" in error for error in errors))
        self.assertTrue(any("not redistributable" in error for error in errors))

    def test_rejects_personal_data_and_missing_format_token(self):
        suite = valid_suite()
        suite["cases"][0]["contains_personal_data"] = True
        formatting_case = next(case for case in suite["cases"] if case["category"] == "formatting")
        formatting_case["preserve"] = [" "]
        errors = MODULE.validate_suite(suite, valid_registry(), [])
        self.assertTrue(any("personal data" in error for error in errors))
        self.assertTrue(any("non-empty preserve" in error for error in errors))

    def test_rejects_preserve_token_that_is_absent_from_source(self):
        suite = valid_suite()
        formatting_case = next(case for case in suite["cases"] if case["category"] == "formatting")
        formatting_case["preserve"] = ["NOT-IN-SOURCE"]
        errors = MODULE.validate_suite(suite, valid_registry(), [])
        self.assertTrue(any("preserve token is absent from source" in error for error in errors))

    def test_rejects_missing_direction_category_quota(self):
        suite = valid_suite()
        suite["cases"] = suite["cases"][:-1]
        errors = MODULE.validate_suite(suite, valid_registry(), [])
        self.assertTrue(any("at least 64" in error for error in errors))
        self.assertTrue(any("quota" in error for error in errors))

    def test_rejects_normalized_training_overlap(self):
        suite = valid_suite()
        training_texts = [" unique source 1 "]
        errors = MODULE.validate_suite(suite, valid_registry(), training_texts)
        self.assertTrue(any("training overlap" in error for error in errors))


if __name__ == "__main__":
    unittest.main()
