import importlib.util
import json
import pathlib
import tempfile
import unittest


MODULE_PATH = pathlib.Path(__file__).parents[1] / "build_dictionary_editorial_draft.py"
SPEC = importlib.util.spec_from_file_location("dictionary_editorial_draft", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


def _candidate(lemma="abandon", *, status="draft"):
    return {
        "entry_id": f"yixue-editorial.en-zh.{lemma}",
        "lemma": lemma,
        "base": {
            "ipa": "/əˈbændən/",
            "part_of_speech": "verb",
            "meanings": ["放弃", "抛弃"],
            "source_translations": ["vt. 放弃, 抛弃"],
            "coverage_bands": ["cet4", "cet6"],
        },
        "rich_candidate": {
            "entry_id": f"yixue-editorial.en-zh.{lemma}",
            "language_pair": "en-zh",
            "lemma": lemma,
            "coverage_bands": ["cet4", "cet6"],
            "learning_tags": ["cet4", "cet6"],
            "source_ids": ["open-ecdict", "wordnet-3.0"],
            "pronunciation_candidates": [
                {"value": "/əˈbændən/", "source_id": "open-ecdict"}
            ],
            "part_of_speech_candidates": [
                {"value": "verb", "source_id": "wordnet-3.0"}
            ],
            "sense_candidates": [
                {"source_id": "wordnet-3.0", "sense_id": "1"}
            ],
            "english_examples": [],
            "bilingual_examples": [],
            "collocation_candidates": [],
            "relation_candidates": [],
            "variants": [],
            "quality": {
                "status": status,
                "review_fields": ["usage_register", "human_review"],
            },
        },
    }


class DictionaryEditorialDraftTest(unittest.TestCase):
    def test_normalizes_one_entry_without_promoting_it(self):
        entries, report = MODULE.build_editorial_draft(
            [_candidate()], candidate_source="data/dictionary/editorial-candidates-v3.json"
        )

        self.assertTrue(report["passed"])
        self.assertEqual(report["total_entries"], 1)
        self.assertEqual(entries[0]["candidate_ref"]["entry_index"], 0)
        self.assertEqual(entries[0]["editorial_draft"]["meaning_candidates"][0]["text"], "放弃")
        self.assertEqual(entries[0]["quality"]["status"], "draft")
        self.assertFalse(entries[0]["quality"]["human_review"])
        self.assertFalse(entries[0]["review"]["human_review"])

    def test_rejects_duplicate_lemma(self):
        duplicate = _candidate("same")
        duplicate["entry_id"] = "yixue-editorial.en-zh.same-2"
        duplicate["rich_candidate"]["entry_id"] = "yixue-editorial.en-zh.same-2"
        with self.assertRaisesRegex(ValueError, "duplicate lemma"):
            MODULE.build_editorial_draft(
                [_candidate("same"), duplicate],
                candidate_source="candidate.json",
            )

    def test_rejects_non_draft_candidate(self):
        with self.assertRaisesRegex(ValueError, "must remain draft"):
            MODULE.build_editorial_draft(
                [_candidate(status="reviewed")], candidate_source="candidate.json"
            )

    def test_stream_parser_reads_entries_without_loading_payload(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "candidate.json"
            path.write_text(
                json.dumps({"report": {"total_entries": 1}, "entries": [_candidate()]}, ensure_ascii=False),
                encoding="utf-8",
            )
            values = list(MODULE.iter_candidate_entries(path))

        self.assertEqual(len(values), 1)
        self.assertEqual(values[0]["lemma"], "abandon")


if __name__ == "__main__":
    unittest.main()
