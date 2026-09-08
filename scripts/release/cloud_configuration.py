"""Public metadata injection, before Xcode builds/signs. No credentials required."""
import base64
import json
import os
from pathlib import Path
import subprocess
import sys
from urllib.parse import urlsplit
from cloud_api import safe_environment

ROOT = Path(__file__).resolve().parents[2]


def metadata(tag, build):
    result = subprocess.run([str(ROOT / 'scripts/release/version-tool.sh'), tag, str(build)], capture_output=True, text=True, env=safe_environment())
    if result.returncode:
        raise ValueError('Invalid release tag or build number')
    return json.loads(result.stdout)


def public_configuration(feed, key):
    url = urlsplit(feed)
    if (url.scheme != 'https' or not url.hostname or url.username or url.password or url.query or url.fragment
            or any(c in feed for c in '\r\n\t $(){}\\') or url.hostname.endswith('.invalid')):
        raise ValueError('A public HTTPS appcast URL is required')
    if len(base64.b64decode(key, validate=True)) != 32:
        raise ValueError('A 32-byte Sparkle public key is required')
    return feed, key


def main():
    release = metadata(os.environ['CI_TAG'], os.environ['CI_BUILD_NUMBER'])
    feed, key = public_configuration(os.environ['SPARKLE_FEED_URL'], os.environ['SPARKLE_PUBLIC_ED_KEY'])
    # xcconfig interprets // as a comment; the empty build-setting expression prevents it.
    values = dict(ORIGAMI_MARKETING_VERSION=release['marketingVersion'], ORIGAMI_BUILD_NUMBER=str(release['buildNumber']),
                  ORIGAMI_RELEASE_TAG=release['tag'], ORIGAMI_RELEASE_STAGE=release['stage'],
                  ORIGAMI_PRERELEASE_NUMBER=str(release.get('prereleaseNumber', '')),
                  ORIGAMI_FEED_URL=feed.replace('://', ':/$()/'), ORIGAMI_PUBLIC_ED_KEY=key)
    (ROOT / 'Configuration/Release.generated.xcconfig').write_text(''.join(f'{k} = {v}\n' for k, v in values.items()))
    print('Release metadata validated and configured before signing.')


if __name__ == '__main__':
    try:
        main()
    except Exception:
        sys.exit('Release configuration failed. Check the tag, build number, feed URL and public key.')
