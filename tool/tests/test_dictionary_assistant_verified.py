import json
import importlib.util
import pathlib
import sys
import tempfile
import unittest


MODULE_PATH = pathlib.Path(__file__).parents[1] / "build_dictionary_assistant_verified_layer.py"
SPEC = importlib.util.spec_from_file_location("dictionary_assistant_verified", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


KNOWN_SOURCES = {
    "open-ecdict",
    "ecdict-raw-master",
    "wordnet-3.0",
    "tatoeba-cc-by-2.0-fr",
    "wiktionary-kaikki-2026-09",
}


def _entry(*, bilingual=True, english=True, collocations=True, variants=True):
    return {
        "schema_version": 1,
        "layer": "yixue-assistant-curated-draft-v1",
        "entry_id": "yixue-editorial.en-zh.dog",
        "language_pair": "en-zh",
        "lemma": "dog",
        "coverage_bands": ["cet4"],
        "learning_tags": ["cet4"],
        "part_of_speech": "n.",
        "part_of_speech_candidates": [
            {"value": "noun", "source_id": "wordnet-3.0"},
        ],
        "ipa": {"base": "/dɒɡ/"},
        "pronunciation_candidates": [
            {
                "value": "/dɒɡ/",
                "source_id": "open-ecdict",
                "exact_word_form": True,
            },
        ],
        "senses": [
            {
                "sense_id": "open-ecdict:record:dog",
                "source_id": "open-ecdict",
                "part_of_speech": "n.",
                "english_glosses": ["a domesticated canine"],
                "chinese_glosses": ["狗"],
                "usage_tags": [],
                "source_examples": [],
            },
            {
                "sense_id": "wordnet-3.0:02084071",
                "source_id": "wordnet-3.0",
                "part_of_speech": "noun",
                "english_glosses": ["a member of the genus Canis"],
                "chinese_glosses": [],
                "usage_tags": [],
                "source_examples": [],
            },
        ],
        "english_examples": (
            [{"text": "The dog waited by the door.", "source_id": "wordnet-3.0"}]
            if english
            else []
        ),
        "bilingual_examples": (
            [
                {
                    "example_id": "tatoeba:1:2",
                    "source_id": "tatoeba-cc-by-2.0-fr",
                    "text": "The dog waited.",
                    "translation": "狗在等待。",
                }
            ]
            if bilingual
            else []
        ),
        "collocations": ["dog owner"] if collocations else [],
        "collocation_candidates": [],
        "variants": ["dogs"] if variants else [],
        "variant_candidates": [],
        "relations": {"hypernyms": ["canine"]},
        "source_ids": ["open-ecdict", "wordnet-3.0"],
        "source_evidence": {
            "pronunciation": ["open-ecdict"],
            "part_of_speech": ["open-ecdict", "wordnet-3.0"],
            "senses": ["open-ecdict", "wordnet-3.0"],
            "english_examples": ["wordnet-3.0"],
            "bilingual_examples": [],
            "collocations": [],
            "relations": ["wordnet-3.0"],
            "variants": ["ecdict-raw-master"],
        },
        "candidate_metrics": {},
        "review_flags": ["human_review"],
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
            "entry_id": "yixue-editorial.en-zh.dog",
        },
    }


class DictionaryAssistantVerifiedTest(unittest.TestCase):
    def test_source_manifest_requires_license_and_attribution(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "sources.json"
            path.write_text(
                json.dumps(
                    {
                        "source_records": [
                            {"id": "open-ecdict", "license": "MIT"}
                        ]
                    }
                ),
                encoding="utf-8",
            )

            with self.assertRaisesRegex(ValueError, "has no attribution"):
                MODULE._source_ids_from_manifest(path)

    def test_audit_marks_core_entry_verified_and_keeps_enrichment_gaps_explicit(self):
        audited = MODULE.audit_entry(_entry(bilingual=False, variants=False), KNOWN_SOURCES)

        self.assertEqual(audited["assistant_review"]["status"], "assistant_verified")
        self.assertEqual(
            audited["assistant_review"]["remaining_flags"],
            ["bilingual_examples", "variants"],
        )
        self.assertFalse(audited["quality"]["human_review"])
        self.assertEqual(audited["quality"]["status"], "assistant_curated_draft")
        self.assertNotIn("human_review", audited["assistant_review"]["remaining_flags"])

    def test_audit_rejects_unknown_source_instead_of_importing_it(self):
        entry = _entry()
        entry["source_ids"] = ["open-ecdict", "unknown-source"]

        with self.assertRaisesRegex(ValueError, "unknown source_id"):
            MODULE.audit_entry(entry, KNOWN_SOURCES)

    def test_runtime_rows_are_bounded_and_render_as_assistant_verified(self):
        audited = MODULE.audit_entry(_entry(), KNOWN_SOURCES)
        rows = MODULE.build_runtime_review_rows([audited])

        self.assertEqual(rows[0]["word"], "dog")
        self.assertEqual(rows[0]["quality_status"], "assistant_verified")
        self.assertEqual(rows[0]["remaining_flags"], [])
        source = MODULE.render_runtime_review_shard(rows, 1)
        self.assertIn("OpenCetAssistantReviewRow", source)
        self.assertIn("qualityStatus: 'assistant_verified'", source)
        self.assertNotIn("human_review", source)

    def test_report_distinguishes_ai_verification_from_formal_publication(self):
        report = MODULE.build_report(
            [MODULE.audit_entry(_entry(bilingual=False), KNOWN_SOURCES)]
        )

        self.assertEqual(report["total_entries"], 1)
        self.assertEqual(report["assistant_verified_entries"], 1)
        self.assertEqual(report["runtime_import_ready_entries"], 1)
        self.assertEqual(report["human_reviewed_entries"], 0)
        self.assertEqual(report["published_entries"], 0)
        self.assertFalse(report["formal_release_ready"])
        self.assertEqual(report["remaining_gap_counts"], {"bilingual_examples": 1})


if __name__ == "__main__":
    unittest.main()
