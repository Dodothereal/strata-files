import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]


def load_script(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


mutate = load_script("mutate")
audit = load_script("audit-destructive")


class MutationRunnerTests(unittest.TestCase):
    def test_no_tests_is_not_a_surviving_mutation(self):
        run = subprocess.CompletedProcess([], 0, "✔ Test run with 0 tests in 0 suites passed", "")
        with contextlib.redirect_stdout(io.StringIO()), patch.object(mutate, "sh", return_value=run):
            self.assertIsNone(mutate.tests_fail("MissingTests"))

    def test_only_a_test_failure_counts_as_caught(self):
        for output, code, expected in [
            ("✔ Test run with 1 test in 1 suite passed", 0, False),
            ("✘ Test run with 1 test in 1 suite failed", 1, True),
            ("error: fatalError", 1, None),
            ("Process crashed", -9, None),
        ]:
            with self.subTest(output=output), contextlib.redirect_stdout(io.StringIO()), patch.object(mutate, "sh", return_value=subprocess.CompletedProcess([], code, output, "")):
                self.assertIs(mutate.tests_fail("SafetyTests"), expected)

    def test_timeout_stops_children_holding_the_output_pipes(self):
        # Killing only the parent leaves communicate waiting a minute for its child's inherited pipes.
        command = "import subprocess, sys, time; subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)']); time.sleep(60)"
        start = time.monotonic()
        with self.assertRaises(subprocess.TimeoutExpired):
            mutate.sh([sys.executable, "-c", command], timeout=0.5)
        self.assertLess(time.monotonic() - start, 5)

    def test_interrupt_restores_the_source(self):
        with tempfile.TemporaryDirectory(prefix="strata-mutation-runner-") as folder:
            root = Path(folder)
            source = root / "Sources" / "Safety.swift"
            source.parent.mkdir()
            source.write_text("guard safe else { return }\n")
            (root / "Tests").mkdir()
            (root / "Tests" / "mutations.json").write_text(json.dumps([{
                "file": "Safety.swift", "find": "guard safe", "replace": "guard true",
                "rule": "Safety check", "tests": "SafetyTests",
            }]))
            for arguments in [["init", "-q"], ["add", "."], ["-c", "user.name=t", "-c", "user.email=t@t",
                              "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "-qm", "fixture"]]:
                subprocess.run(["git", "-C", folder] + arguments, check=True, capture_output=True)

            def tests_fail(_, report=False):
                if "guard true" in source.read_text():
                    raise KeyboardInterrupt()
                return False

            with patch.object(mutate, "ROOT", folder), patch.object(mutate, "tests_fail", side_effect=tests_fail), patch.object(sys, "argv", ["mutate.py"]):
                with self.assertRaises(KeyboardInterrupt):
                    mutate.main()
            self.assertEqual(source.read_text(), "guard safe else { return }\n")


class MutationAuditTests(unittest.TestCase):
    def test_an_exemption_requires_a_reason(self):
        with tempfile.TemporaryDirectory(prefix="strata-mutation-audit-") as folder:
            root = Path(folder)
            (root / "docs").mkdir()
            page = root / "docs" / "destructive-actions.md"
            previous = os.getcwd()
            try:
                os.chdir(folder)
                page.write_text("## Not mutated, and why\n\n| `Model/Safety :: remove` | |\n")
                self.assertEqual(audit.exempt_functions(), set())
                page.write_text("## Not mutated, and why\n\n| `Model/Safety :: remove` | Only removes its own scratch files. |\n")
                self.assertEqual(audit.exempt_functions(), {("Model/Safety", "remove")})
            finally:
                os.chdir(previous)

    def test_the_changed_function_is_covered_instead_of_its_context(self):
        with tempfile.TemporaryDirectory(prefix="strata-mutation-audit-") as folder:
            root = Path(folder)
            (root / "Sources").mkdir()
            (root / "Tests").mkdir()
            source = "func first() {}\nfunc second() {\n    guard safe else { return }\n}\n"
            (root / "Sources" / "Safety.swift").write_text(source)
            (root / "Tests" / "mutations.json").write_text(json.dumps([{
                "file": "Safety.swift", "find": source, "replace": source.replace("guard safe", "guard true"),
            }]))
            previous = os.getcwd()
            try:
                os.chdir(folder)
                self.assertEqual(audit.mutated_functions(), {("Safety", "second")})
            finally:
                os.chdir(previous)


if __name__ == "__main__":
    unittest.main()
