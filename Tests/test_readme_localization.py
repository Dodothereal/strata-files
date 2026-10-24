import importlib.util
import json
from pathlib import Path
import re
import tempfile
import unittest
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('readme_localize', ROOT / 'scripts/readme-localize.py')
readme = importlib.util.module_from_spec(spec)
spec.loader.exec_module(readme)


class ReadmeLocalizationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'Localization').mkdir()
        (self.root / 'docs/readme/localization').mkdir(parents=True)
        self.source = '''<h1>Strata Files</h1>
<!-- readme-languages:start -->
<!-- readme-languages:end -->

## Get Strata

Open **files** with `strata .` and [help](docs/help.md).

Read [docs/help.md](docs/help.md) and [privacy](https://stratafiles.app/privacy/).

Keep `[literal](docs/help.md)` exactly.

- Keep the first line
  and its continuation.

| | |
|---|---|
| **Search** | Type `a|b` or an escaped a\\|b. |

<p><img src="docs/image.png" alt="A preview"></p>

```sh
git clone https://example.com/repo
# [do not rewrite](docs/help.md)
```
'''
        (self.root / 'README.md').write_text(self.source)
        self.keys = {unit.key for unit in readme.messages(self.source)}
        self.catalog('en', 'English')
        self.catalog('ja', '日本語', {'Get Strata': 'Strata を入手', 'A preview': 'プレビュー'})

    def catalog(self, code, name, changes=None):
        (self.root / f'Localization/{code}.json').write_text(json.dumps({'language': name}))
        path = self.root / f'docs/readme/localization/{code}.json'
        path.write_text(json.dumps({'code': code, 'strings': {**{key: key for key in self.keys}, **(changes or {})}}))

    def test_extracts_wrapped_prose_html_alts_and_table_cells_without_changing_commands(self):
        self.assertIn('Keep the first line and its continuation.', self.keys)
        self.assertIn('Type `a|b` or an escaped a\\|b.', self.keys)
        self.assertIn('A preview', self.keys)
        self.assertNotIn('Strata Files', self.keys)
        self.assertNotIn('git clone https://example.com/repo', self.keys)
        generated = readme.outputs(self.root)
        japanese = generated[Path('docs/readme/README.ja.md')]
        self.assertIn('## Strata を入手', japanese)
        self.assertIn('src="../image.png" alt="プレビュー"', japanese)
        self.assertIn('[help](../help.md)', japanese)
        self.assertIn('[docs/help.md](../help.md)', japanese)
        self.assertIn('[privacy](https://stratafiles.app/ja/privacy/)', japanese)
        self.assertIn('git clone https://example.com/repo', japanese)
        self.assertIn('`[literal](docs/help.md)`', japanese)
        self.assertIn('# [do not rewrite](docs/help.md)', japanese)
        self.assertIn('href="../../README.md">English</a>', japanese)
        self.assertIn('<strong>日本語</strong>', japanese)
        self.assertIn('href="docs/readme/README.ja.md">日本語</a>', generated[Path('README.md')])

    def test_a_new_catalog_automatically_gets_its_file_and_reciprocal_language_links(self):
        self.catalog('ru', 'Русский', {'Get Strata': 'Скачать Strata'})
        generated = readme.outputs(self.root)
        russian = generated[Path('docs/readme/README.ru.md')]
        self.assertIn('## Скачать Strata', russian)
        self.assertIn('href="README.ja.md">日本語</a>', russian)
        self.assertIn('href="README.ru.md">Русский</a>', generated[Path('docs/readme/README.ja.md')])
        self.assertIn('href="docs/readme/README.ru.md">Русский</a>', generated[Path('README.md')])

    def test_missing_blank_stale_unsafe_or_command_changing_translations_are_refused(self):
        key = 'Open **files** with `strata .` and [help](docs/help.md).'
        for bad in ['', '  ', 'Open **files** with `rm -rf .` and [help](docs/help.md).',
                    'Open **files** with `strata .` and [help](https://evil.example).',
                    '<script>alert(1)</script>', 'Open files with `strata .` and [help](docs/help.md).']:
            self.catalog('ja', '日本語', {key: bad})
            with self.subTest(value=bad), self.assertRaises(ValueError):
                readme.outputs(self.root)
        path = self.root / 'docs/readme/localization/ja.json'
        for mutation in ['missing', 'stale']:
            self.catalog('ja', '日本語')
            data = json.loads(path.read_text())
            if mutation == 'missing':
                data['strings'].pop(key)
            else:
                data['strings']['Obsolete'] = 'Obsolete'
            path.write_text(json.dumps(data))
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                readme.outputs(self.root)

    def test_english_search_examples_remain_usable_and_malformed_source_is_refused(self):
        example = 'Try *"pdfs from last month"*.'
        self.assertEqual(readme.signature(example)[3], (0, 2))
        self.source += '\n' + example + '\n'
        (self.root / 'README.md').write_text(self.source)
        self.keys.add(example)
        self.catalog('en', 'English')
        self.catalog('ja', '日本語', {example: '*"先月の PDF"* を検索。'})
        with self.assertRaisesRegex(ValueError, 'working English search'):
            readme.outputs(self.root)
        for source in ['```sh\necho unfinished\n', '<p>Unfinished\n']:
            with self.subTest(source=source), self.assertRaises(ValueError):
                readme.messages(source)

    def test_checked_in_translations_are_current_and_every_local_image_and_link_resolves(self):
        generated = readme.outputs(ROOT)
        for path, text in generated.items():
            self.assertEqual((ROOT / path).read_text(), text, f'Regenerate {path}')
            targets = re.findall(r'\b(?:href|src)="([^"]+)"', text) + [m[1] for m in readme.LINK.finditer(text)]
            for target in targets:
                parsed = urlsplit(target)
                if not parsed.scheme and parsed.path:
                    self.assertTrue((ROOT / path.parent / parsed.path).exists(), (path, target))
            if path != Path('README.md'):
                self.assertIn('<a id="get-strata"></a>', text)
                self.assertIn('href="#get-strata"', text)
                self.assertEqual(re.findall(r'^```.*?^```', text, re.M | re.S),
                                 re.findall(r'^```.*?^```', (ROOT / 'README.md').read_text(), re.M | re.S))


if __name__ == '__main__':
    unittest.main()
