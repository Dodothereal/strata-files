import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("theme_color_audit", ROOT / "scripts/audit-theme-colors.py")
AUDIT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AUDIT)


class ThemeColorAuditTests(unittest.TestCase):
    def test_inspector_gray_text_is_rejected_including_cached_attributed_strings(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "Sources/Strata/Dev/ProjectInspectorView.swift"
            path.parent.mkdir(parents=True)
            for code in ["label.textColor = .secondaryLabelColor",
                         "let attributes = [.foregroundColor: NSColor.tertiaryLabelColor]"]:
                path.write_text(code)
                self.assertTrue(any("InspectorColors" in issue for issue in AUDIT.check(root, [])))
            path.write_text("label.textColor = InspectorColors.secondary")
            self.assertEqual(AUDIT.check(root, []), [])

    def test_direct_backgrounds_borders_and_aliases_require_review(self):
        for code in ["view.backgroundColor = .gray", "layer?.borderColor = NSColor.black.cgColor",
                     "table.backgroundColors = [.controlBackgroundColor]", "box.fillColor = .white",
                     "view.backgroundColor = chosenColor", "layer?.backgroundColor =\n    NSColor.gray.cgColor",
                     "NSColor.controlBackgroundColor.setFill()", "NSColor.separatorColor.setStroke()",
                     ".background(Color.gray)", ".background(\n    Color.gray)",
                     "NSColor.controlBackgroundColor\n    .setFill()",
                     "view.backgroundColor = ThemeStyle.surface(.content); box.fillColor = .white",
                     "override var dividerColor: NSColor { .separatorColor }"]:
            with self.subTest(code=code):
                self.assertEqual(len(AUDIT.findings(code)), 1)

    def test_theme_colors_and_transparent_parents_pass(self):
        for code in ["box.fillColor = ThemeStyle.surface(.preview)",
                     "layer.borderColor = ThemeStyle.border.cgColor", "view.backgroundColor = .clear",
                     "table.backgroundColors = [.clear]", "layer.backgroundColor = nil",
                     "ThemeStyle.surface(.chrome).setFill()"]:
            with self.subTest(code=code):
                self.assertEqual(AUDIT.findings(code), [])

    def test_comments_and_strings_do_not_hide_real_code(self):
        source = '''// view.backgroundColor = .gray
/* outer /* view.fillColor = .gray */ comment */
let example = "view.borderColor = .black"
let address = "sftp://my-server.example"
view.backgroundColor = .gray
'''
        self.assertEqual(AUDIT.findings(source), [(5, "view.backgroundColor = .gray")])

    def test_new_duplicate_and_stale_uses_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "Sources/Strata/Views/Test.swift"
            source.parent.mkdir(parents=True)
            code = "view.backgroundColor = .gray"
            source.write_text(code)
            entries = [{"file": str(source.relative_to(root)), "code": code, "count": 1,
                        "reason": "Native color captured before ThemeStyle binds the view."}]
            self.assertEqual(AUDIT.check(root, entries), [])
            source.write_text(code + "\n" + code)
            self.assertTrue(AUDIT.check(root, entries))
            source.write_text("")
            self.assertTrue(AUDIT.check(root, entries))
            source.write_text(code + "\nbox.fillColor = .white")
            self.assertTrue(AUDIT.check(root, entries))

    def test_exceptions_require_a_reason_and_valid_count(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            entry = {"file": "Sources/Strata/Test.swift", "code": "view.backgroundColor = .gray", "count": 0, "reason": " "}
            self.assertTrue(AUDIT.check(root, [entry]))
            self.assertTrue(AUDIT.check(root, [entry, entry]))

    def test_the_repository_has_no_unreviewed_surface_colors(self):
        entries = json.loads((ROOT / "Tests/theme-colors.json").read_text())
        self.assertEqual(AUDIT.check(ROOT, entries), [])

    def test_the_reported_gray_disk_usage_footer_would_fail(self):
        path = "Sources/Strata/Views/TreemapViewController.swift"
        entries = [entry for entry in json.loads((ROOT / "Tests/theme-colors.json").read_text()) if entry["file"] == path]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            copy = root / path
            copy.parent.mkdir(parents=True)
            source = (ROOT / path).read_text()
            copy.write_text(source)
            self.assertEqual(AUDIT.check(root, entries), [])
            index = source.rfind("ThemeStyle.surface(.content).setFill()")
            self.assertGreater(index, 0)
            copy.write_text(source[:index] + source[index:].replace(
                "ThemeStyle.surface(.content).setFill()", "NSColor.controlBackgroundColor.setFill()", 1))
            self.assertTrue(any("Use ThemeStyle" in problem for problem in AUDIT.check(root, entries)))
