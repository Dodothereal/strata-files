import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("localize", ROOT / "scripts" / "localize.py")
localize = importlib.util.module_from_spec(spec)
spec.loader.exec_module(localize)

GERMAN_COLUMNS = {"Date Added": "Hinzugefügt am", "Width": "Breite", "Height": "Höhe", "Duration": "Dauer"}
NEW_LABELS = [
    "Applies to all windows.", "Date Added", "Duration", "Folder info", "Height", "Icon size", "Item count",
    "List columns", "Pictures and movies show their dimensions. Other files show their size.",
    "Show View Options…", "Show item info", "Total size", "View Options", "Width",
    "/usr/local/bin/strata isn’t Strata’s command, so it was left as it is. Remove or rename it, then install again.",
    "Another “strata” is installed.",
]


class CatalogTranslationTests(unittest.TestCase):
    def test_supported_languages_have_every_source_translation(self):
        english = localize.load(localize.SOURCE)["strings"]
        for path in localize.language_files():
            with self.subTest(language=path.stem):
                data = localize.load(path)
                strings = data["strings"]
                self.assertEqual(set(strings), set(english))
                required, _ = localize.plural_rules(path.stem, data)
                for key, source in english.items():
                    value = strings[key]
                    if isinstance(source, dict):
                        self.assertIsInstance(value, dict, (path.stem, key))
                        for category in required:
                            self.assertTrue(isinstance(value.get(category), str) and value[category].strip(),
                                            (path.stem, key, category))
                    else:
                        self.assertTrue(isinstance(value, str) and value.strip(), (path.stem, key))

    def test_reported_german_column_names_match_the_contribution(self):
        german = localize.load(localize.FOLDER / "de.json")["strings"]
        self.assertEqual({key: german.get(key) for key in GERMAN_COLUMNS}, GERMAN_COLUMNS)

    @unittest.skipUnless(sys.platform == "darwin", "plutil validates the macOS app's strings resources")
    def test_generated_resources_include_new_controls_and_columns_in_every_language(self):
        with tempfile.TemporaryDirectory(prefix="strata-translations-") as scratch:
            with contextlib.redirect_stdout(io.StringIO()):
                localize.build(scratch)
            for path in localize.language_files():
                with self.subTest(language=path.stem):
                    resource = Path(scratch) / f"{path.stem}.lproj" / "Localizable.strings"
                    result = subprocess.run(["plutil", "-convert", "json", "-o", "-", str(resource)],
                                            capture_output=True, text=True, check=True)
                    strings = json.loads(result.stdout)
                    expected = localize.load(path)["strings"]
                    self.assertTrue(all(strings.get(key) for key in NEW_LABELS),
                                    [key for key in NEW_LABELS if not strings.get(key)])
                    self.assertEqual({key: strings.get(key) for key in NEW_LABELS},
                                     {key: expected[key] for key in NEW_LABELS})
                    if path.stem == "de":
                        self.assertEqual({key: strings.get(key) for key in GERMAN_COLUMNS}, GERMAN_COLUMNS)


if __name__ == "__main__":
    unittest.main()
