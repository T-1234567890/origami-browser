"""Checkout-based release infrastructure tests; no Apple accounts or network."""
import base64
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from cloud_api import ReleaseError
from distribution import NS
from website_release import update_website

REPO = 'test/repo'
EMPTY = dict(version=None, channel=None, downloadURL=None)


def contents(data):
    # GitHub Contents API wraps base64 with newlines.
    return dict(encoding='base64', content=base64.encodebytes(data).decode(), sha='file-sha')


class GitHub:
    def __init__(self, identities):
        self.private = False
        self.calls = []
        self.releases = []
        self.assets = {}
        self.root = ET.Element('rss'); channel = ET.SubElement(self.root, 'channel')
        self.current = contents(json.dumps(EMPTY).encode())
        self.fail_write = False
        for number, identity in enumerate(identities, 1):
            tag = identity['tag']
            self.releases.append(dict(id=number, tag_name=tag, draft=False, published_at='2026-09-10', prerelease=identity['stage'] == 'beta'))
            name = f'Actual-upload-{number}.zip'  # Deliberately not a filename template.
            url = f'https://github.com/{REPO}/releases/download/{tag}/{name}'
            self.assets[number] = [dict(id=number, name=name, browser_download_url=url, state='uploaded', size=42)]
            item = ET.SubElement(channel, 'item')
            for key, value in [('version', str(number)), ('shortVersionString', identity['marketingVersion']), ('minimumSystemVersion', '15.4')]:
                ET.SubElement(item, f'{{{NS}}}{key}').text = value
            if identity.get('channel'): ET.SubElement(item, f'{{{NS}}}channel').text = identity['channel']
            ET.SubElement(item, 'enclosure', {'url': url, 'length': '42', f'{{{NS}}}edSignature': base64.b64encode(bytes(64)).decode()})

    def request(self, path, method='GET', body=None, **kwargs):
        self.calls.append((path, method, body))
        if method != 'GET':
            assert method == 'PUT' and path == f'/repos/{REPO}/contents/website/release.json'
            assert body['sha'] == self.current['sha'] and body['branch'] == 'main'
            self.current = dict(encoding='base64', content=body['content'], sha='new-sha')
            if self.fail_write: raise ReleaseError('Ambiguous transport failure after successful write')
            return {}
        if path == f'/repos/{REPO}': return dict(private=self.private, default_branch='main')
        if '/contents/appcast.xml?' in path: return contents(ET.tostring(self.root))
        if '/contents/website/release.json?' in path: return self.current
        if '/releases/tags/' in path: return next(r for r in self.releases if r['tag_name'] == path.split('/')[-1])
        if path.endswith('/releases?per_page=100&page=1'): return self.releases
        if '/assets?' in path: return self.assets[int(path.split('/')[-2])]
        raise AssertionError(path)


class WebsiteReleaseTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.tool = Path(cls.temp.name) / 'version'
        root = Path(__file__).resolve().parents[3]
        subprocess.run(['swiftc', str(root / 'Origami/Updates/ReleaseIdentity.swift'), str(root / 'scripts/release/VersionTool.swift'), '-o', str(cls.tool)], check=True, capture_output=True)
    @classmethod
    def tearDownClass(cls): cls.temp.cleanup()
    def identity(self, tag, build=1):
        result = subprocess.run([str(self.tool), tag, str(build)], capture_output=True, text=True)
        if result.returncode: raise ValueError('Invalid tag')
        return json.loads(result.stdout)
    def setUp(self):
        self.patch = patch('website_release.metadata', self.identity); self.patch.start()
        self.addCleanup(self.patch.stop)
    def api(self, *tags): return GitHub([self.identity(tag) for tag in tags])
    def writes(self, api): return [call for call in api.calls if call[1] != 'GET']

    def test_first_beta_uses_actual_asset_and_retry_is_noop(self):
        api = self.api('v1.0.0-beta.1')
        result = update_website(api, REPO, 'v1.0.0-beta.1', api.assets[1][0])
        self.assertEqual(result['metadata'], dict(version='1.0.0-beta.1', channel='beta', downloadURL=api.assets[1][0]['browser_download_url']))
        self.assertEqual(update_website(api, REPO, 'v1.0.0-beta.1')['status'], 'already current')
        self.assertEqual(len(self.writes(api)), 1)

    def test_latest_beta_selected_even_on_older_retry(self):
        api = self.api('v1.0.0-beta.2', 'v1.0.0-beta.10')
        self.assertEqual(update_website(api, REPO, 'v1.0.0-beta.2')['metadata']['version'], '1.0.0-beta.10')

    def test_stable_preferred_even_with_empty_metadata(self):
        api = self.api('v1.0.0', 'v2.0.0-beta.1', 'v1.1.0')
        result = update_website(api, REPO, 'v2.0.0-beta.1')
        self.assertEqual(result['metadata']['version'], '1.1.0')
        self.assertEqual(result['releaseURL'], api.assets[2][0]['browser_download_url'])
        self.assertEqual(result['metadata']['downloadURL'], api.assets[3][0]['browser_download_url'])

    def test_stable_is_preserved_without_new_commit(self):
        api = self.api('v1.0.0', 'v2.0.0-beta.1')
        update_website(api, REPO, 'v1.0.0')
        self.assertEqual(update_website(api, REPO, 'v2.0.0-beta.1')['status'], 'already current')
        self.assertEqual(len(self.writes(api)), 1)

    def test_ambiguous_write_retry_does_not_duplicate_commit(self):
        api = self.api('v1.0.0'); api.fail_write = True
        with self.assertRaises(ReleaseError): update_website(api, REPO, 'v1.0.0')
        self.assertEqual(update_website(api, REPO, 'v1.0.0')['status'], 'already current')
        self.assertEqual(len(self.writes(api)), 1)

    def test_reject_unpublished_or_unverified_candidates(self):
        for failure in ('private', 'draft', 'unpublished', 'channel', 'missing-feed', 'signature', 'size', 'asset-url', 'asset-state', 'uploaded-mismatch', 'missing-metadata'):
            with self.subTest(failure=failure):
                api = self.api('v1.0.0'); uploaded = None
                if failure == 'private': api.private = True
                if failure == 'draft': api.releases[0]['draft'] = True
                if failure == 'unpublished': api.releases[0]['published_at'] = None
                if failure == 'channel': api.releases[0]['prerelease'] = True
                if failure == 'missing-feed': api.root.find('channel').clear()
                if failure == 'signature': api.root.find('channel/item/enclosure').set(f'{{{NS}}}edSignature', '')
                if failure == 'size': api.assets[1][0]['size'] = 43
                if failure == 'asset-url': api.assets[1][0]['browser_download_url'] = 'https://temporary.example/cloud.zip'
                if failure == 'asset-state': api.assets[1][0]['state'] = 'new'
                if failure == 'uploaded-mismatch': uploaded = dict(api.assets[1][0], id=999)
                if failure == 'missing-metadata': api.current = None
                with self.assertRaises(ReleaseError): update_website(api, REPO, 'v1.0.0', uploaded)
                self.assertEqual(self.writes(api), [])

    def test_never_downgrade_previous_stable(self):
        api = self.api('v2.0.0-beta.1')
        api.current = contents(json.dumps(dict(version='1.0.0', channel='stable', downloadURL='fixture')).encode())
        with self.assertRaisesRegex(ReleaseError, 'downgrade'): update_website(api, REPO, 'v2.0.0-beta.1')
        self.assertEqual(self.writes(api), [])

    def test_existing_stable_missing_feed_fails_instead_of_selecting_beta(self):
        api = self.api('v1.0.0', 'v2.0.0-beta.1')
        channel = api.root.find('channel'); channel.remove(channel.find('item'))
        with self.assertRaises(ReleaseError): update_website(api, REPO, 'v2.0.0-beta.1')
        self.assertEqual(self.writes(api), [])

    def test_concurrent_metadata_write_fails_without_other_mutations(self):
        api = self.api('v1.0.0'); original = api.request
        def request(path, method='GET', body=None, **kwargs):
            if method == 'PUT': raise ReleaseError('HTTP 409')
            return original(path, method, body, **kwargs)
        api.request = request
        with self.assertRaisesRegex(ReleaseError, '409'): update_website(api, REPO, 'v1.0.0')
        self.assertEqual(json.loads(base64.b64decode(api.current['content'])), EMPTY)
        self.assertEqual(self.writes(api), [])

    def test_summary_distinguishes_website_failure_from_published_release(self):
        import os
        from release import write_summary
        identity = self.identity('v1.0.0')
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'summary'
            with patch.dict(os.environ, {'GITHUB_STEP_SUMMARY': str(path)}):
                write_summary(identity, 'Website metadata publication', ReleaseError('Release is published; website update failed'), state=dict(checks={'GitHub Release':'✓ Published', 'Appcast':'✓ Updated', 'Website download link':'✗ Not updated'}, asset_name='actual.zip'))
            text = path.read_text()
            for expected in ['GitHub Release: ✓ Published', 'Appcast: ✓ Updated', 'Website download link: ✗ Not updated', 'Released ZIP asset: actual.zip', 'Release channel: stable']:
                self.assertIn(expected, text)
