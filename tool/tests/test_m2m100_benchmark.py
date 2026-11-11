import importlib.util
import pathlib
import unittest


MODULE_PATH = pathlib.Path(__file__).parents[1] / "run_m2m100_benchmark.py"
SPEC = importlib.util.spec_from_file_location("m2m100_benchmark", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class BenchmarkHelpersTest(unittest.TestCase):
    def test_language_mapping_is_bidirectional(self):
        self.assertEqual(MODULE.language_code("english"), "en")
        self.assertEqual(MODULE.language_code("chinese"), "zh")

    def test_preserve_check_reports_each_required_token(self):
        checks = MODULE.preserve_checks("API E-104", ["API", "45", "E-104"])
        self.assertEqual(
            checks,
            [
                {"token": "API", "present": True},
                {"token": "45", "present": False},
                {"token": "E-104", "present": True},
            ],
        )

    def test_nearest_rank_percentile(self):
        self.assertEqual(MODULE.percentile([10, 20, 30, 40], 50), 20)
        self.assertEqual(MODULE.percentile([10, 20, 30, 40], 95), 40)
        self.assertEqual(MODULE.percentile([], 95), 0)

    def test_existing_path_does_not_resolve_workspace_junction(self):
        path = MODULE.existing_path(pathlib.Path(__file__).parents[2])
        self.assertEqual(path.name, "YixueDev")


if __name__ == "__main__":
    unittest.main()
