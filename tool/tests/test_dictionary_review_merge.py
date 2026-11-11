import copy
import importlib.util
import pathlib
import unittest


MODULE_PATH = pathlib.Path(__file__).parents[1] / "merge_dictionary_reviewed_layers.py"
SPEC = importlib.util.spec_from_file_location("dictionary_review_merge", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


def _source(source_id="yixue-authored"):
    return {
        "id": source_id,
        "name": "译学自写",
        "version": "0.4.0",
        "license": "译学自写内容 · 译学项目许可",
        "attribution": "花鱼鱼",
    }


def _entry(lemma):
    return {
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
            "status": "reviewed",
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


def _layer(*entries, source_records=None):
    return {
        "schema_version": 1,
        "layer": "yixue-authored-reviewed-v1",
        "language_pair": "en-zh",
        "source_records": copy.deepcopy(source_records or [_source()]),
        "entries": [copy.deepcopy(entry) for entry in entries],
    }


class DictionaryReviewMergeTest(unittest.TestCase):
    def test_merges_valid_layers_and_keeps_entries_deterministic(self):
        payload, report = MODULE.merge_reviewed_layers(
            [_layer(_entry("beta")), _layer(_entry("alpha"))]
        )

        self.assertTrue(report["passed"])
        self.assertEqual([entry["lemma"] for entry in payload["entries"]], ["alpha", "beta"])
        self.assertEqual(report["validation"]["reviewed_entries"], 2)

    def test_rejects_duplicate_lemmas_across_layers(self):
        with self.assertRaises(MODULE.ReviewMergeError) as context:
            MODULE.merge_reviewed_layers([_layer(_entry("same")), _layer(_entry("same"))])

        self.assertIn("duplicate_lemma:same", context.exception.report["global_errors"])

    def test_rejects_invalid_layer_before_merging(self):
        draft = _entry("draft")
        draft["quality"]["status"] = "draft"
        with self.assertRaises(MODULE.ReviewMergeError) as context:
            MODULE.merge_reviewed_layers([_layer(draft)])

        self.assertFalse(context.exception.report["passed"])
        self.assertIsNotNone(context.exception.report["layer_reports"])

    def test_require_all_uses_candidate_scope(self):
        with self.assertRaises(MODULE.ReviewMergeError) as context:
            MODULE.merge_reviewed_layers(
                [_layer(_entry("one"))],
                expected_lemmas={"one", "two"},
                require_all=True,
            )

        self.assertIn("missing_expected_lemma:two", context.exception.report["validation"]["global_errors"])


if __name__ == "__main__":
    unittest.main()
