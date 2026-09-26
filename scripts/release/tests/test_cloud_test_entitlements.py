import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    'cloud_test_entitlements', Path(__file__).resolve().parents[1] / 'cloud_test_entitlements.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class CloudTestEntitlementsTests(unittest.TestCase):
    def test_test_host_preserves_other_entitlements_and_archive_rejects_stripped_copy(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'Configuration/Origami.entitlements'
            path.parent.mkdir()
            values = {module.PASSKEY: True, 'com.apple.security.app-sandbox': True,
                      'com.apple.security.print': True, 'custom-array': ['fixture']}
            original = plistlib.dumps(values)
            path.write_bytes(original)
            for action in ('archive', 'build', 'analyze', 'test-without-building', None):
                module.configure(directory, action)
                self.assertEqual(path.read_bytes(), original)
            module.configure(directory, 'build-for-testing')
            self.assertEqual(plistlib.loads(path.read_bytes()),
                             {key: value for key, value in values.items() if key != module.PASSKEY})
            with self.assertRaises(ValueError):
                module.configure(directory, 'archive')
            module.configure(directory, 'build-for-testing')  # Idempotent retry.
