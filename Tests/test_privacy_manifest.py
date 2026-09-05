import plistlib
from pathlib import Path
import unittest


class PrivacyManifestTests(unittest.TestCase):
    def test_local_storage_and_settings_have_declared_reasons(self):
        root = Path(__file__).resolve().parents[1]
        with (root/'Resources/PrivacyInfo.xcprivacy').open('rb') as stream:
            manifest = plistlib.load(stream)
        self.assertIs(manifest['NSPrivacyTracking'], False)
        self.assertEqual(manifest['NSPrivacyCollectedDataTypes'], [])
        reasons = {item['NSPrivacyAccessedAPIType']: set(item['NSPrivacyAccessedAPITypeReasons'])
                   for item in manifest['NSPrivacyAccessedAPITypes']}
        self.assertEqual(reasons, {'NSPrivacyAccessedAPICategoryUserDefaults': {'CA92.1'},
                                  'NSPrivacyAccessedAPICategoryFileTimestamp': {'C617.1', '3B52.1'}})
