import json
import importlib.util
import pathlib
import tempfile
import unittest


MODULE_PATH = pathlib.Path(__file__).parents[1] / "validate_dictionary_assistant_curated_layer.py"
SPEC = importlib.util.spec_from_file_location("dictionary_assistant_curated_validation", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


def _entry(**overrides):
    entry = {
        "schema_version": 1,
        "layer": "yixue-assistant-curated-draft-v1",
        "entry_id": "yixue-editorial.en-zh.demo",
        "language_pair": "en-zh",
        "lemma": "demo",
        "coverage_bands": ["cet4"],
        "learning_tags": ["cet4"],
        "part_of_speech": "noun",
        "part_of_speech_candidates": [{"value": "noun", "source_id": "open-ecdict"}],
        "ipa": {"uk": "/ˈdeməʊ/"},
        "pronunciation_candidates": [
            {"value": "/ˈdeməʊ/", "source_id": "open-ecdict", "notation": "ipa"}
        ],
        "senses": [
            {
                "sense_id": "wordnet-1",
                "source_id": "wordnet-3.0",
                "part_of_speech": "noun",
                "english_glosses": ["a demonstration"],
                "chinese_glosses": ["示例"],
                "usage_tags": ["general"],
                "source_examples": ["This is a demo."],
            }
        ],
        "english_examples": [{"text": "This is a demo.", "source_id": "wordnet-3.0"}],
        "bilingual_examples": [
            {
                "example_id": "tatoeba:1:2",
                "source_id": "tatoeba-cc-by-2.0-fr",
                "english_text": "This is a demo.",
                "translation": "这是一个示例。",
                "review_status": "candidate",
            }
        ],
        "collocations": ["demo version"],
        "collocation_candidates": [
            {"text": "demo version", "source_id": "open-ecdict", "review_status": "candidate"}
        ],
        "variants": ["demos"],
        "variant_candidates": [
            {"form": "demos", "source_ids": ["open-ecdict"], "part_of_speech": "noun"}
        ],
        "relations": {"similar_to": ["example"]},
        "source_ids": ["open-ecdict", "wordnet-3.0", "tatoeba-cc-by-2.0-fr"],
        "source_evidence": {
            "pronunciation": ["open-ecdict"],
            "part_of_speech": ["open-ecdict"],
            "senses": ["wordnet-3.0"],
            "english_examples": ["wordnet-3.0"],
            "bilingual_examples": ["tatoeba-cc-by-2.0-fr"],
            "collocations": ["open-ecdict"],
            "relations": ["wordnet-3.0"],
            "variants": ["open-ecdict"],
        },
        "candidate_metrics": {"sense_candidates": 1},
        "review_flags": [
            "usage_register",
            "sense_alignment",
            "license_review",
            "human_review",
        ],
        "quality": {
            "status": "assistant_curated_draft",
            "review_method": "source-grounded assistant consolidation",
            "reviewer": "译学 AI 编辑初审",
            "human_review": False,
            "checks": {
                "source": False,
                "license": False,
                "pronunciation": False,
                "meaning": False,
                "usage": False,
                "examples": False,
                "relations": False,
            },
        },
        "candidate_ref": {
            "path": "data/dictionary/editorial-candidates-v3.json",
            "entry_index": 0,
            "entry_id": "yixue-editorial.en-zh.demo",
        },
    }
    entry.update(overrides)
    return entry


class DictionaryAssistantCuratedValidationTest(unittest.TestCase):
    def _write_case(self, entries, source_records=None):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = pathlib.Path(temp_dir)
            layer = root / "layer.jsonl"
            source = root / "sources.json"
            with layer.open("w", encoding="utf-8", newline="\n") as stream:
                for entry in entries:
                    stream.write(json.dumps(entry, ensure_ascii=False) + "\n")
            source.write_text(
                json.dumps(
                    {"source_records": source_records or [{"id": "open-ecdict"}, {"id": "wordnet-3.0"}, {"id": "tatoeba-cc-by-2.0-fr"}]},
                    ensure_ascii=False,
                ),
                encoding="utf-8",
            )
            return MODULE.validate_assistant_curated_layer(layer, source, expected_entries=len(entries))

    def test_accepts_structurally_valid_assistant_draft(self):
        report = self._write_case([_entry()])
        self.assertTrue(report["passed"])
        self.assertEqual(report["total_entries"], 1)
        self.assertEqual(report["human_reviewed_entries"], 0)

    def test_rejects_replacement_character(self):
        broken = _entry(lemma="dem�")
        with self.assertRaisesRegex(ValueError, "replacement character"):
            self._write_case([broken])

    def test_rejects_promoted_quality_status(self):
        broken = _entry(quality={"status": "published", "human_review": True, "checks": {}})
        with self.assertRaisesRegex(ValueError, "status"):
            self._write_case([broken])

    def test_rejects_duplicate_entry_id(self):
        with self.assertRaisesRegex(ValueError, "duplicate entry_id"):
            self._write_case([_entry(), _entry(lemma="other")])


if __name__ == "__main__":
    unittest.main()
