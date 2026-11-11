import importlib.util
import pathlib
import unittest


MODULE_PATH = pathlib.Path(__file__).parents[1] / "validate_dictionary_reviewed_layer.py"
SPEC = importlib.util.spec_from_file_location("dictionary_reviewed_layer", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


def _source(source_id="yixue-authored"):
    return {
        "id": source_id,
        "name": "译学自写",
        "version": "0.1.0",
        "license": "译学自写内容 · 译学项目许可",
        "attribution": "花鱼鱼",
    }


def _entry(lemma="example", status="reviewed", **overrides):
    entry = {
        "entry_id": f"yixue-reviewed.{lemma}",
        "language_pair": "en-zh",
        "lemma": lemma,
        "variants": [],
        "ipa": {"uk": "/ɪɡˈzɑːmpəl/"},
        "part_of_speech": "n. 名词",
        "senses": [
            {
                "id": f"{lemma}.1",
                "meanings": ["例子；示例"],
                "usage": "用于说明或帮助理解一个观点。",
                "domain": "日常 / 学习 / 阅读",
                "examples": [
                    {
                        "text": "This example clarifies the idea.",
                        "translation": "这个例子说明了这个观点。",
                        "source_id": "yixue-authored",
                    }
                ],
            }
        ],
        "collocations": ["give an example"],
        "learning_tags": ["学习"],
        "coverage_bands": ["cet4"],
        "relations": {"synonyms": ["instance"]},
        "source_ids": ["yixue-authored"],
        "quality": {
            "status": status,
            "reviewer": "译学编辑",
            "reviewed_at": "2026-09-15",
            "human_review": True,
            "checks": {
                "source": True,
                "license": True,
                "pronunciation": True,
                "meaning": True,
                "usage": True,
                "examples": True,
                "relations": True,
            },
        },
    }
    entry.update(overrides)
    return entry


def _payload(*entries):
    return {
        "schema_version": 1,
        "layer": "yixue-authored-reviewed-v1",
        "language_pair": "en-zh",
        "source_records": [_source()],
        "entries": list(entries),
    }


class DictionaryReviewedLayerTest(unittest.TestCase):
    def test_accepts_a_complete_human_reviewed_entry(self):
        report = MODULE.validate_layer(_payload(_entry()))

        self.assertTrue(report["passed"])
        self.assertEqual(report["reviewed_entries"], 1)
        self.assertEqual(report["invalid_entries"], [])

    def test_rejects_machine_draft_and_missing_human_evidence(self):
        draft = _entry(status="draft")
        draft["quality"]["human_review"] = False
        report = MODULE.validate_layer(_payload(draft))

        self.assertFalse(report["passed"])
        self.assertIn("quality.status", report["invalid_entries"][0]["fields"])
        self.assertIn("quality.human_review", report["invalid_entries"][0]["fields"])

    def test_rejects_unknown_sources_and_duplicate_lemmas(self):
        first = _entry("same")
        second = _entry("same", entry_id="yixue-reviewed.same-2")
        first["source_ids"] = ["missing-source"]
        report = MODULE.validate_layer(_payload(first, second))

        self.assertFalse(report["passed"])
        self.assertIn("source_ids", report["invalid_entries"][0]["fields"])
        self.assertTrue(
            any(error == "duplicate_lemma:same" for error in report["global_errors"])
        )

    def test_rejects_empty_bilingual_examples_and_placeholder_text(self):
        entry = _entry()
        entry["senses"][0]["examples"][0]["translation"] = ""
        entry["senses"][0]["usage"] = "�"
        report = MODULE.validate_layer(_payload(entry))

        self.assertFalse(report["passed"])
        fields = report["invalid_entries"][0]["fields"]
        self.assertIn("sense.examples", fields)
        self.assertIn("replacement_character", fields)

    def test_expected_lemmas_can_enforce_a_complete_review_batch(self):
        report = MODULE.validate_layer(
            _payload(_entry("one")),
            expected_lemmas={"one", "two"},
            require_all=True,
        )

        self.assertFalse(report["passed"])
        self.assertIn("missing_expected_lemma:two", report["global_errors"])


if __name__ == "__main__":
    unittest.main()
