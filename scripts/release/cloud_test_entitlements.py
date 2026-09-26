"""Limit the Cloud test-host entitlement adjustment to its disposable checkout."""
import os
from pathlib import Path
import plistlib

PASSKEY = 'com.apple.developer.web-browser.public-key-credential'


def configure(root, action):
    if action not in ('build-for-testing', 'archive'):
        return
    path = Path(root) / 'Configuration/Origami.entitlements'
    values = plistlib.loads(path.read_bytes())
    if action == 'archive':
        if values.get(PASSKEY) is not True:
            raise ValueError('Archive requires the approved browser passkey entitlement')
        print('Archive passkey entitlement verified; signing configuration unchanged.')
        return
    # Preserve sandbox, file access, printing, and updater entitlements.
    values.pop(PASSKEY, None)
    path.write_bytes(plistlib.dumps(values, sort_keys=False))
    print('Cloud unit-test host only: omitted restricted passkey entitlement. Archive unchanged.')


if __name__ == '__main__':
    if os.environ.get('CI') == 'TRUE':
        configure(os.environ['CI_PRIMARY_REPOSITORY_PATH'], os.environ.get('CI_XCODEBUILD_ACTION'))
