import json
from pathlib import Path
import unittest


class StoreMetadataTests(unittest.TestCase):
    def test_localized_metadata_matches_the_store_build(self):
        root = Path(__file__).resolve().parents[1]
        data = json.loads((root/'app-store/metadata.json').read_text())
        project = (root/'project.yml').read_text()
        self.assertIn('MARKETING_VERSION: "' + data['version'] + '"', project)
        self.assertIn('CURRENT_PROJECT_VERSION: "' + data['build'] + '"', project)
        self.assertEqual(data['bundleId'], 'com.goldenrabbit.omopensnap.mas')
        self.assertEqual(set(data['localizations']), {'en-US', 'ko'})
        for locale, text in data['localizations'].items():
            with self.subTest(locale=locale):
                self.assertLessEqual(len(text['name']), 30)
                self.assertLessEqual(len(text['subtitle']), 30)
                self.assertLessEqual(len(text['description']), 4000)
                self.assertLessEqual(len(text['promotionalText']), 170)
                self.assertLessEqual(len(text['keywords'].encode()), 100)
                for path in text['screenshots']:
                    self.assertTrue((root/'app-store'/path).is_file())
