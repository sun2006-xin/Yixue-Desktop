import copy
import importlib.util
import pathlib
import unittest


MODULE_PATH = pathlib.Path(__file__).parents[1] / "export_dictionary_reviewed_layer.py"
SPEC = importlib.util.spec_from_file_location("dictionary_review_export", MODULE_PATH)
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


def _reviewed_entry(lemma="example"):
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
        "quality": {"status": "draft"},
    }


def _review():
    return {
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
        "notes": "逐字段核对并确认来源与许可记录。",
        "reviewed_entry": _reviewed_entry(),
    }


def _batch(review=None):
    return {
        "schema_version": 1,
        "layer": "yixue-editorial-review-workbench",
        "batch_id": "yixue-review-v1-001",
        "entries": [
            {
                "entry_id": "yixue-reviewed.example",
                "language_pair": "en-zh",
                "lemma": "example",
                "candidate": {"quality": {"status": "draft"}},
                "review": review or {
                    "status": "pending",
                    "reviewer": "",
                    "reviewed_at": "",
                    "human_review": False,
                    "checks": {},
                    "notes": "",
                    "reviewed_entry": None,
                },
            }
        ],
    }


class DictionaryReviewExportTest(unittest.TestCase):
    def test_refuses_pending_workbench(self):
        with self.assertRaises(MODULE.ReviewExportError) as context:
            MODULE.export_reviewed_layer(_batch(), [_source()])

        self.assertIn("review.status", context.exception.report["rejected_entries"][0]["fields"])

    def test_exports_only_a_complete_human_review_and_revalidates_it(self):
        payload, report = MODULE.export_reviewed_layer(_batch(_review()), [_source()])

        self.assertTrue(report["passed"])
        self.assertEqual(payload["layer"], "yixue-authored-reviewed-v1")
        self.assertEqual(payload["entries"][0]["quality"]["status"], "reviewed")
        self.assertTrue(payload["entries"][0]["quality"]["human_review"])
        self.assertEqual(report["validation"]["invalid_entries"], [])

    def test_does_not_accept_a_reviewed_entry_for_another_word(self):
        review = _review()
        review["reviewed_entry"] = copy.deepcopy(_reviewed_entry("different"))

        with self.assertRaises(MODULE.ReviewExportError) as context:
            MODULE.export_reviewed_layer(_batch(review), [_source()])

        self.assertIn("reviewed_entry.lemma", context.exception.report["rejected_entries"][0]["fields"])


if __name__ == "__main__":
    unittest.main()
