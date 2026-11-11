import importlib.util
import pathlib
import sys
import unittest


MODULE_PATH = pathlib.Path(__file__).parents[1] / "build_dictionary_editorial_candidates.py"
SPEC = importlib.util.spec_from_file_location("dictionary_editorial", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


WORDNET_NOUN = """\
00000001 03 n 02 dog 0 canine 0 01 @ 00000002 n 0000 | a domesticated animal; \"The dog runs.\"
00000002 03 n 01 animal 0 00 | a living organism that feeds on organic matter
"""


class DictionaryEditorialTest(unittest.TestCase):
    def test_parses_wordnet_senses_examples_and_relations(self):
        index = MODULE.build_wordnet_index({"noun": WORDNET_NOUN})

        dog = index["dog"]
        self.assertEqual(dog[0].part_of_speech, "noun")
        self.assertEqual(dog[0].definition, "a domesticated animal")
        self.assertEqual(dog[0].examples, ("The dog runs.",))
        self.assertIn("animal", dog[0].relations["hypernyms"])
        self.assertIn("canine", index)

    def test_candidate_keeps_open_meanings_and_never_promotes_machine_text(self):
        index = MODULE.build_wordnet_index({"noun": WORDNET_NOUN})
        base = MODULE.OpenCetEntry(
            word="dog",
            ipa="/dɒɡ/",
            coverage_bands=("cet4",),
            source_translations=("n. 狗",),
        )

        candidate = MODULE.build_candidate(base, index)

        self.assertEqual(candidate["lemma"], "dog")
        self.assertEqual(candidate["quality"]["status"], "draft")
        self.assertEqual(candidate["wordnet"]["sense_count"], 1)
        self.assertIn("bilingual_examples", candidate["missing_fields"])
        self.assertIn("human_review", candidate["missing_fields"])
        self.assertEqual(candidate["source_ids"], ["open-ecdict", "wordnet-3.0"])

    def test_matches_tatoeba_sentence_pairs_and_records_attribution_fields(self):
        examples = MODULE.build_tatoeba_examples(
            ["10\teng\tThe dog runs.\talice\t2020-01-01\t2020-01-02\n"],
            ["20\tcmn\t这只狗在跑。\tbob\t2020-01-01\t2020-01-03\n"],
            ["10\t20\n"],
            ["dog"],
        )

        self.assertEqual(examples["dog"][0].chinese_text, "这只狗在跑。")
        self.assertEqual(examples["dog"][0].english_username, "alice")
        self.assertEqual(examples["dog"][0].chinese_username, "bob")

        base = MODULE.OpenCetEntry(
            word="dog",
            ipa="/dɒɡ/",
            coverage_bands=("cet4",),
            source_translations=("n. 狗",),
        )
        candidate = MODULE.build_candidate(base, MODULE.build_wordnet_index({"noun": WORDNET_NOUN}), examples)

        self.assertNotIn("bilingual_examples", candidate["missing_fields"])
        self.assertIn("tatoeba-cc-by-2.0-fr", candidate["source_ids"])
        self.assertEqual(candidate["tatoeba_examples"][0]["chinese_id"], "20")
        self.assertIn("dog runs", candidate["collocation_candidates"])

    def test_extracts_ecdict_variants_tags_and_frequency(self):
        record = MODULE.parse_ecdict_row(
            {
                "word": "abandon",
                "phonetic": "ә'bændәn",
                "definition": "v. forsake, leave behind",
                "translation": "vt. 放弃, 抛弃",
                "pos": "",
                "tag": "gk cet4 cet6 ky",
                "bnc": "2057",
                "frq": "2182",
                "exchange": "d:abandoned/p:abandoned/i:abandoning/3:abandons",
                "detail": "",
            }
        )

        self.assertEqual(record.variants, ("abandoned", "abandoning", "abandons"))
        self.assertEqual(record.tags, ("gk", "cet4", "cet6", "ky"))
        self.assertEqual(record.bnc_rank, 2057)
        self.assertEqual(record.frequency_rank, 2182)

    def test_candidate_exposes_ecdict_learning_metadata_separately(self):
        base = MODULE.OpenCetEntry(
            word="abandon",
            ipa="/əˈbændən/",
            coverage_bands=("cet4", "cet6"),
            source_translations=("vt. 放弃, 抛弃",),
        )
        record = MODULE.parse_ecdict_row(
            {
                "word": "abandon",
                "phonetic": "ә'bændәn",
                "definition": "v. forsake, leave behind",
                "translation": "vt. 放弃, 抛弃",
                "pos": "",
                "tag": "gk cet4 cet6 ky",
                "bnc": "2057",
                "frq": "2182",
                "exchange": "d:abandoned/p:abandoned/i:abandoning/3:abandons",
                "detail": "",
            }
        )

        candidate = MODULE.build_candidate(
            base,
            {},
            ecdict_index={"abandon": record},
        )

        self.assertEqual(candidate["variants"], ["abandoned", "abandoning", "abandons"])
        self.assertIn("cet4", candidate["learning_tags"])
        self.assertEqual(candidate["frequency"]["bnc_rank"], 2057)
        self.assertIn("ecdict-raw-master", candidate["source_ids"])

    def test_quality_gate_blocks_draft_candidates_from_public_release(self):
        base = MODULE.OpenCetEntry(
            word="dog",
            ipa="/dɒɡ/",
            coverage_bands=("cet4",),
            source_translations=("n. 狗",),
        )
        candidate = MODULE.build_candidate(base, {})
        gate = MODULE.build_quality_gate([candidate])

        self.assertFalse(gate["passed"])
        self.assertEqual(gate["draft_entries"], 1)
        self.assertEqual(gate["publishable_entries"], 0)
        self.assertEqual(gate["duplicate_lemmas"], [])


if __name__ == "__main__":
    unittest.main()
