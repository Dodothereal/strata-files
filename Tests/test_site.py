"""Packaging checks: URLs survive deploys and downloaded assets are verified."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from urllib.error import HTTPError

spec = importlib.util.spec_from_file_location('site_assets', Path(__file__).resolve().parents[1] / 'scripts/site-assets.py')
assets = importlib.util.module_from_spec(spec)
spec.loader.exec_module(assets)


class SiteAssetsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def fixture(self, javascript='window.ready = true;'):
        for name, data in {
            'index.html': '<meta charset="utf-8"><link rel="stylesheet" href="styles.css"><script src="main.js"></script><img src="image.png" srcset="image.png 800w">',
            'privacy/index.html': '<meta charset="utf-8"><link rel="stylesheet" href="../styles.css">',
            'styles.css': 'body { background: url("image.png"); }',
            'main.js': javascript,
            'image.png': 'demo image bytes',
            'site.webmanifest': json.dumps({'icons': [{'src': 'image.png'}]}),
        }.items():
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(data)

    def test_references_and_every_filename_match_contents(self):
        self.fixture()
        assets.prepare(self.root)
        manifest = json.loads((self.root / 'asset-manifest.json').read_text())
        names = {name.split('-', 1)[1]: '/' + name for name in manifest}
        for name in manifest:
            self.assertEqual(assets.ASSET.fullmatch(name)[1], hashlib.sha256((self.root / name).read_bytes()).hexdigest())
        home = (self.root / 'index.html').read_text()
        self.assertIn('src="' + names['main.js'] + '"', home)
        self.assertIn('srcset="' + names['image.png'] + ' 800w"', home)
        self.assertIn('url("' + names['image.png'] + '")', home)
        self.assertIn('href="' + names['styles.css'] + '"', (self.root / 'privacy/index.html').read_text())
        self.assertLess(home.index('Content-Security-Policy'), home.index('<script'))
        self.assertEqual(json.loads((self.root / 'site.webmanifest').read_text())['icons'][0]['src'], names['image.png'])

    def test_changed_asset_gets_new_url_and_old_url_survives(self):
        self.fixture()
        assets.prepare(self.root)
        before = json.loads((self.root / 'asset-manifest.json').read_text())
        previous = {name: (self.root / name).read_bytes() for name in before}
        self.fixture('window.ready = false;')
        assets.prepare(self.root)
        after = json.loads((self.root / 'asset-manifest.json').read_text())
        self.assertTrue(set(before) < set(after))
        for name, contents in previous.items():
            self.assertEqual((self.root / name).read_bytes(), contents)

    def test_inline_javascript_is_rejected(self):
        self.fixture()
        with (self.root / 'index.html').open('a') as page:
            page.write('<script>alert(1)</script>')
        with self.assertRaisesRegex(ValueError, 'inline JavaScript'):
            assets.prepare(self.root)

    def test_previous_asset_is_verified_and_restored(self):
        data = b'old script'
        name = 'immutable/' + hashlib.sha256(data).hexdigest() + '-main.js'
        def fetch(url, limit):
            return json.dumps([name]).encode() if url.endswith('asset-manifest.json') else data
        with patch.object(assets, 'fetch', side_effect=fetch):
            assets.restore_previous(self.root, 'https://stratafiles.app')
        self.assertEqual((self.root / name).read_bytes(), data)

    def test_invalid_manifest_is_refused_before_downloads(self):
        valid = 'immutable/' + 'a' * 64 + '-main.js'
        for manifest in [['../escaped.js'], [valid, '../escape'], [valid, valid], {'files': []}, [None], [valid] * 2001]:
            with self.subTest(manifest=str(manifest)[:80]):
                with patch.object(assets, 'fetch', return_value=json.dumps(manifest).encode()) as fetch:
                    with self.assertRaises(ValueError):
                        assets.restore_previous(self.root, 'https://stratafiles.app')
                    self.assertEqual(fetch.call_count, 1)
        self.assertEqual(list(self.root.iterdir()), [])

    def test_wrong_digest_is_not_written(self):
        name = 'immutable/' + 'a' * 64 + '-main.js'
        with patch.object(assets, 'fetch', side_effect=[json.dumps([name]).encode(), b'wrong bytes']):
            with self.assertRaisesRegex(ValueError, 'does not match'):
                assets.restore_previous(self.root, 'https://stratafiles.app')
        self.assertEqual(list(self.root.iterdir()), [])

    def test_only_missing_manifest_is_allowed(self):
        for code in [404, 503]:
            with patch.object(assets, 'fetch', side_effect=HTTPError('https://stratafiles.app', code, '', {}, None)):
                if code == 404:
                    assets.restore_previous(self.root, 'https://stratafiles.app')
                else:
                    with self.assertRaises(HTTPError):
                        assets.restore_previous(self.root, 'https://stratafiles.app')
        with patch.object(assets, 'fetch') as fetch:
            with self.assertRaisesRegex(ValueError, 'HTTPS'):
                assets.restore_previous(self.root, 'http://stratafiles.app')
            fetch.assert_not_called()
