import base64
import io
import json
import os
from pathlib import Path
import plistlib
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch, Mock
import xml.etree.ElementTree as ET
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from cloud_api import API, ReleaseError, TeamToken, raw_ecdsa, run_cloud
from cloud_configuration import metadata, public_configuration
from distribution import NS, ensure_order, generate_feed, safe_extract, verify_app
from release import publish_feed, main


class MockCloud:
    def __init__(self, status='SUCCEEDED', kind='STAPLED_NOTARIZED_ARCHIVE', commit='fixture-commit', progress='COMPLETE'):
        self.status, self.kind, self.commit, self.progress = status, kind, commit, progress
        self.posts = []
    def request(self, path, method='GET', body=None, **kwargs):
        if path.endswith('/repository'): return {'data': {'id': 'repo'}}
        if path.startswith('/v1/ciWorkflows/'): return {'data': {'attributes': {'isEnabled': True}}}
        if method == 'POST': self.posts.append(body)
        return {'data': {'id': 'run', 'attributes': {'number': 123, 'executionProgress': self.progress, 'completionStatus': self.status, 'sourceCommit': {'commitSha': self.commit}}}}
    def all(self, path):
        if path.endswith('/gitReferences'): return [{'id': 'tag-id', 'attributes': {'canonicalName': 'refs/tags/v1.0.0', 'kind': 'TAG'}}]
        if path.endswith('/actions'): return [{'id': 'archive', 'attributes': {'actionType': 'ARCHIVE', 'completionStatus': 'SUCCEEDED'}}]
        return [{'id': 'artifact', 'attributes': {'fileType': self.kind}}]


def feed(build=100, tag='v1.0.0-beta.1', channel='beta'):
    channel_xml = f'<sparkle:channel>{channel}</sparkle:channel>' if channel else ''
    return f'<rss xmlns:sparkle="{NS}"><channel><title>Origami</title><item><sparkle:version>{build}</sparkle:version>{channel_xml}<enclosure url="https://github.com/test/repo/releases/download/{tag}/Origami.zip" length="1" /></item></channel></rss>'.encode()


class ReleaseTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.tool = Path(cls.temp.name) / 'version'
        root = Path(__file__).resolve().parents[3]
        subprocess.run(['swiftc', str(root / 'Origami/Updates/ReleaseIdentity.swift'), str(root / 'scripts/release/VersionTool.swift'), '-o', str(cls.tool)], check=True, capture_output=True)
    @classmethod
    def tearDownClass(cls): cls.temp.cleanup()
    def version(self, tag, build=101):
        result = subprocess.run([str(self.tool), tag, str(build)], capture_output=True, text=True)
        if result.returncode: raise ValueError('Invalid version')
        return json.loads(result.stdout)
    def test_tag_contract(self):
        for tag, title, stage in [('v1.0.0', 'Origami 1.0', 'stable'), ('v1.0.0-beta.1', 'Origami 1.0 Beta 1', 'beta'), ('v1.0.0-beta.12', 'Origami 1.0 Beta 12', 'beta')]:
            with self.subTest(tag=tag):
                result = self.version(tag)
                self.assertEqual(result['displayVersion'], title); self.assertEqual(result['marketingVersion'], '1.0.0'); self.assertEqual(result['stage'], stage)
    def test_reject_tags(self):
        for tag in ['1.0.0', 'v1', 'v1.0', 'v1.0.0-beta', 'v1.0.0-beta.0', 'v1.0.0-random.1', 'v1.0.0\n', 'v01.0.0', 'v1.0.0-rc.1', 'v1.0.0-alpha.1', 'v1.00.0', 'v1.0.00', 'v1.0.0-beta.01', 'v1.0.0-beta.-1']:
            with self.subTest(tag=tag), self.assertRaises(ValueError): self.version(tag)
    def test_cloud_success_and_tag_relationship(self):
        api = MockCloud(); run, artifact = run_cloud(api, 'workflow', 'v1.0.0', 'fixture-commit')
        self.assertEqual(run['attributes']['number'], 123)
        self.assertEqual(artifact['attributes']['fileType'], 'STAPLED_NOTARIZED_ARCHIVE')
        self.assertEqual(api.posts[0]['data']['relationships']['sourceBranchOrTag']['data']['id'], 'tag-id')
    def test_cloud_failures(self):
        for arguments in [dict(status='FAILED'), dict(status='CANCELED'), dict(kind='ARCHIVE'), dict(commit='wrong')]:
            with self.subTest(arguments=arguments), self.assertRaises(ReleaseError): run_cloud(MockCloud(**arguments), 'workflow', 'v1.0.0', 'fixture-commit')
    def test_cloud_timeout(self):
        with self.assertRaisesRegex(ReleaseError, 'timed out'):
            run_cloud(MockCloud(progress='RUNNING'), 'workflow', 'v1.0.0', 'fixture-commit', clock=Mock(side_effect=[0, 7201]), sleep=Mock())
    def test_missing_tag_no_build_started(self):
        api = MockCloud()
        with self.assertRaises(ReleaseError): run_cloud(api, 'workflow', 'v2.0.0', 'fixture-commit')
        self.assertEqual(api.posts, [])
    def test_invalid_config(self):
        key = base64.b64encode(bytes(32)).decode()
        for value in ['', 'http://example.org/feed', 'https://user:pass@example.org/feed', 'https://example.org/feed?token=x', 'https://example.org/\nINJECT=YES']:
            with self.assertRaises(ValueError): public_configuration(value, key)
        self.assertEqual(public_configuration('https://example.org/appcast.xml', key)[1], key)
    def test_order_and_channels(self):
        with patch('distribution.metadata', self.version):
            ensure_order(feed(), self.version('v1.0.0'))
            for tag, build in [('v1.0.0', 99), ('v1.0.0-beta.1', 102), ('v0.9.0', 103)]:
                with self.assertRaises(ReleaseError): ensure_order(feed(), self.version(tag, build))
    def test_unsafe_archives(self):
        for name in ['../escape', '/absolute', 'dir/../../escape']:
            with tempfile.TemporaryDirectory() as directory:
                archive = Path(directory) / 'archive.zip'
                with zipfile.ZipFile(archive, 'w') as z: z.writestr(name, b'fixture')
                with patch('distribution.command') as run, self.assertRaises(ReleaseError): safe_extract(archive, Path(directory) / 'extract')
                run.assert_not_called()
    def test_symlink_escape(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / 'archive.zip'
            with zipfile.ZipFile(archive, 'w') as z:
                link = zipfile.ZipInfo('link'); link.external_attr = (stat.S_IFLNK | 0o777) << 16; z.writestr(link, '../escape')
            with self.assertRaises(ReleaseError): safe_extract(archive, Path(directory) / 'extract')
    def test_feed_concurrent_writer_rejected(self):
        api = Mock(); api.request.return_value = {'object': {'sha': 'changed'}}
        with self.assertRaises(ReleaseError): publish_feed(api, 'test/repo', b'<rss/>', 'expected', 'v1.0.0')
        self.assertEqual(api.request.call_count, 1)
    def test_first_feed_branch_and_no_force_push(self):
        api = Mock(); api.request.side_effect = [None, {'sha': 'blob'}, {'sha': 'tree'}, {'sha': 'commit'}, {}]
        publish_feed(api, 'test/repo', b'<rss/>', None, 'v1.0.0')
        self.assertEqual(api.request.call_args.args[2]['ref'], 'refs/heads/appcast')
        api = Mock(); api.request.side_effect = [{'object': {'sha': 'old'}}, {'sha': 'blob'}, {'sha': 'tree'}, {'sha': 'commit'}, {}]
        publish_feed(api, 'test/repo', b'<rss/>', 'old', 'v1.0.0')
        self.assertFalse(api.request.call_args.args[2]['force'])
    def test_jwt_der_conversion(self):
        self.assertEqual(raw_ecdsa(bytes([48, 6, 2, 1, 1, 2, 1, 2])), bytes(31) + b'\1' + bytes(31) + b'\2')
        with self.assertRaises(ReleaseError): raw_ecdsa(b'invalid')
    def test_token_private_file_removed_and_no_key_argument(self):
        def sign(args, **kwargs):
            path = Path(args[-1]); self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertNotIn('synthetic-key-input', args)
            self.key_path = path
            return Mock(returncode=0, stdout=bytes([48, 6, 2, 1, 1, 2, 1, 2]))
        with patch('cloud_api.subprocess.run', side_effect=sign):
            token = TeamToken('fixture', 'fixture', 'synthetic-key-input')()
        self.assertEqual(len(token.split('.')), 3); self.assertFalse(self.key_path.exists())
    def test_api_does_not_expose_error_body(self):
        import urllib.error
        api = API('https://api.appstoreconnect.apple.com', lambda: 'synthetic-token')
        api.opener.open = Mock(side_effect=urllib.error.HTTPError('https://example.org', 401, 'sensitive body', {}, io.BytesIO(b'sensitive body')))
        with self.assertRaisesRegex(ReleaseError, r'HTTP 401') as error: api.request('/v1/ciWorkflows/fixture')
        self.assertNotIn('sensitive', str(error.exception))
    def test_api_post_not_retried(self):
        import urllib.error
        api = API('https://api.appstoreconnect.apple.com', lambda: 'synthetic-token')
        api.opener.open = Mock(side_effect=urllib.error.HTTPError('https://example.org', 503, '', {}, None))
        with self.assertRaises(ReleaseError): api.request('/v1/ciBuildRuns', 'POST', {})
        self.assertEqual(api.opener.open.call_count, 1)
    def test_tag_validation_before_credentials(self):
        with patch.dict(os.environ, {'RELEASE_TAG': 'invalid'}, clear=True), patch('release.metadata', side_effect=ValueError), patch('release.API') as api:
            with self.assertRaises(ValueError): main()
            api.assert_not_called()

    def test_verify_app_checks_identity_signature_and_notarization(self):
        release = self.version('v1.0.0')
        config = dict(bundle='org.example.fixture', team='0000000000', feed='https://example.org/appcast.xml', public_key='fixture')
        info = dict(CFBundleIdentifier=config['bundle'], CFBundleVersion='101', CFBundleShortVersionString='1.0.0', OrigamiReleaseTag='v1.0.0', OrigamiReleaseStage='stable', OrigamiPrereleaseNumber='', SUFeedURL=config['feed'], SUPublicEDKey='fixture', LSMinimumSystemVersion='15.4')
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / 'Origami.app'; (app / 'Contents').mkdir(parents=True)
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
            with patch('distribution.command', return_value=plistlib.dumps({})) as run:
                verify_app(app, release, config)
                self.assertEqual([call.args[0][0] for call in run.call_args_list], ['codesign', 'spctl', 'xcrun', 'codesign'])
            with patch('distribution.command', side_effect=ReleaseError('signature failed')):
                with self.assertRaises(ReleaseError): verify_app(app, release, config)
            info['OrigamiReleaseStage'] = 'beta'; (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
            with patch('distribution.command') as run:
                with self.assertRaises(ReleaseError): verify_app(app, release, config)
                run.assert_not_called()

    def test_generated_appcast_channels_and_secret_stdin(self):
        for tag in ['v1.0.0', 'v1.0.0-beta.2']:
            with tempfile.TemporaryDirectory() as directory:
                release = self.version(tag)
                archive = Path(directory) / release['assetName']; archive.write_bytes(b'fixture')
                previous = feed()
                def tool(args, **kwargs):
                    self.assertEqual(kwargs['input'], b'synthetic-key-input')
                    self.assertNotIn('synthetic-key-input', args)
                    self.assertNotIn('SPARKLE_ED_PRIVATE_KEY', kwargs['env'])
                    if str(args[0]).endswith('sign_update'):
                        self.assertIn('--verify', args); return
                    self.assertEqual('--channel' in args, release['stage'] != 'stable')
                    root = ET.fromstring(previous); item = ET.SubElement(root.find('channel'), 'item')
                    ET.SubElement(item, f'{{{NS}}}version').text = '101'
                    ET.SubElement(item, f'{{{NS}}}minimumSystemVersion').text = '15.4'
                    ET.SubElement(item, f'{{{NS}}}shortVersionString').text = release['marketingVersion']
                    if release.get('channel'): ET.SubElement(item, f'{{{NS}}}channel').text = 'beta'
                    ET.SubElement(item, 'enclosure', {'url': f'https://github.com/test/repo/releases/download/{tag}/{archive.name}', 'length': '7', f'{{{NS}}}edSignature': base64.b64encode(bytes(64)).decode()})
                    (archive.parent / 'appcast.xml').write_bytes(ET.tostring(root))
                with patch('distribution.metadata', self.version), patch('distribution.command', side_effect=tool):
                    output = generate_feed(archive, previous, release, 'test/repo', 'synthetic-key-input', Path('/fixture-tools'))
                    self.assertEqual(len(ET.fromstring(output).findall('channel/item')), 2)
                with patch('distribution.metadata', self.version), patch('distribution.command', side_effect=ReleaseError('signing failed')):
                    with self.assertRaises(ReleaseError): generate_feed(archive, previous, release, 'test/repo', 'synthetic-key-input', Path('/fixture-tools'))

    def test_unsigned_appcast_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            release = self.version('v1.0.0'); archive = Path(directory) / release['assetName']; archive.write_bytes(b'x')
            def tool(*args, **kwargs): (archive.parent / 'appcast.xml').write_bytes(feed(101, 'v1.0.0', None))
            with patch('distribution.command', side_effect=tool), self.assertRaises(ReleaseError):
                generate_feed(archive, None, release, 'test/repo', 'synthetic-key-input', Path('/fixture-tools'))

    def test_publication_order_and_upload_failure(self):
        for tag, fail_upload in [("v1.0.0", False), ("v1.0.0-beta.1", False), ("v1.0.0", True), ("v1.0.0-beta.1", True)]:
            events = []
            environment = dict(RELEASE_TAG=tag, GITHUB_REPOSITORY='test/repo', GITHUB_TOKEN='synthetic-token', SPARKLE_FEED_URL='https://raw.githubusercontent.com/test/repo/appcast/appcast.xml', SPARKLE_PUBLIC_ED_KEY=base64.b64encode(bytes(32)).decode(), APPLE_TEAM_ID='0000000000', BUNDLE_IDENTIFIER='org.example.fixture', XCODE_CLOUD_WORKFLOW_ID='fixture', SPARKLE_ED_PRIVATE_KEY='synthetic-key-input', APP_STORE_CONNECT_KEY_ID='fixture', APP_STORE_CONNECT_ISSUER_ID='fixture', APP_STORE_CONNECT_PRIVATE_KEY='synthetic-key-input')
            api = Mock()
            def request(path, method='GET', body=None, **kwargs):
                if method == 'GET': return None
                if method == 'POST':
                    self.assertEqual(body['prerelease'], '-beta.' in tag)
                    self.assertEqual(body['name'], self.version(tag)['displayVersion'])
                else:
                    self.assertFalse(body['draft'])
                    self.assertEqual(body['make_latest'], 'false' if '-beta.' in tag else 'true')
                events.append('draft' if method == 'POST' else 'publish')
                return {'id': 1, 'upload_url': 'https://uploads.github.com/repos/test/repo/releases/1/assets{?name}'}
            api.request.side_effect = request
            def fake_package(artifact, work, release, config):
                archive = work / release['assetName']; archive.write_bytes(b'fixture'); return archive
            def fake_upload(*args):
                events.append('upload')
                if fail_upload: raise ReleaseError('upload failed')
            from contextlib import ExitStack
            with ExitStack() as stack:
                stack.enter_context(patch.dict(os.environ, environment, clear=True))
                for target, value in [('metadata', self.version), ('API', Mock(return_value=api)), ('read_feed', Mock(return_value=(None, None))), ('command', Mock(return_value=b'fixture-commit')), ('run_cloud', Mock(return_value=({'id':'run', 'attributes':{'number':101}}, {'attributes':{'downloadUrl':'https://example.org/artifact'}}))), ('download', Mock()), ('package', fake_package), ('sparkle_tools', Mock()), ('generate_feed', Mock(return_value=b'<rss/>')), ('upload', fake_upload), ('publish_feed', lambda *args: events.append('feed'))]:
                    stack.enter_context(patch('release.' + target, value))
                if fail_upload:
                    with self.assertRaises(ReleaseError): main()
                    self.assertNotIn('publish', events); self.assertNotIn('feed', events)
                else:
                    main()
                    self.assertEqual(events, ['draft', 'upload', 'upload', 'upload', 'upload', 'publish', 'feed'])

    def test_cloud_configuration_is_public_and_numeric(self):
        import cloud_configuration
        public_key = base64.b64encode(bytes(32)).decode()
        for tag, build, stage, number in [('v1.0.0-beta.1', '101', 'beta', '1'), ('v1.0.0', '102', 'stable', '')]:
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory); (root / 'Configuration').mkdir()
                with patch.object(cloud_configuration, 'ROOT', root), patch.object(cloud_configuration, 'metadata', self.version), patch.dict(os.environ, {'CI_TAG':tag, 'CI_BUILD_NUMBER':build, 'SPARKLE_FEED_URL':'https://example.org/appcast.xml', 'SPARKLE_PUBLIC_ED_KEY':public_key}):
                    cloud_configuration.main()
                contents = (root / 'Configuration/Release.generated.xcconfig').read_text()
                self.assertIn(f'ORIGAMI_BUILD_NUMBER = {build}\n', contents)
                self.assertIn('ORIGAMI_MARKETING_VERSION = 1.0.0\n', contents)
                self.assertIn(f'ORIGAMI_RELEASE_STAGE = {stage}\n', contents)
                self.assertIn(f'ORIGAMI_PRERELEASE_NUMBER = {number}\n', contents)
                self.assertIn('ORIGAMI_FEED_URL = https:/$()/example.org/appcast.xml\n', contents)
                self.assertNotIn('PRIVATE', contents)

    def test_workflow_configuration_contract(self):
        import re
        root = Path(__file__).resolve().parents[3]
        workflow = (root / '.github/workflows/release.yml').read_text()
        self.assertEqual(set(re.findall(r'secrets\.([A-Z_]+)', workflow)), {'APP_STORE_CONNECT_KEY_ID', 'APP_STORE_CONNECT_ISSUER_ID', 'APP_STORE_CONNECT_PRIVATE_KEY', 'SPARKLE_ED_PRIVATE_KEY'})
        self.assertEqual(set(re.findall(r'vars\.([A-Z_]+)', workflow)), {'XCODE_CLOUD_WORKFLOW_ID', 'APPLE_TEAM_ID', 'BUNDLE_IDENTIFIER', 'SPARKLE_PUBLIC_ED_KEY', 'SPARKLE_FEED_URL'})
        self.assertIn('GITHUB_TOKEN: ${{ github.token }}', workflow)
        project = (root / 'Origami.xcodeproj/project.pbxproj').read_text()
        self.assertEqual(project.count('MARKETING_VERSION = "$(ORIGAMI_MARKETING_VERSION)";'), 2)
        self.assertEqual(project.count('CURRENT_PROJECT_VERSION = "$(ORIGAMI_BUILD_NUMBER)";'), 2)
        public = (root / 'Configuration/Updates.xcconfig').read_text()
        self.assertIn('ORIGAMI_PUBLIC_ED_KEY = owJi4/Wlx+Pswrme3fv9UkDT9iLXLRTGtD9Alwecla8=', public)

    def test_missing_configuration_stops_before_api(self):
        with patch.dict(os.environ, {'RELEASE_TAG':'v1.0.0-beta.1'}, clear=True), patch('release.metadata', self.version), patch('release.API') as api:
            with self.assertRaisesRegex(ReleaseError, 'Missing configuration'): main()
            api.assert_not_called()

    def test_workflow_lookup_failure_does_not_start_build(self):
        api = Mock(); api.request.side_effect = ReleaseError('API GET failed (HTTP 404)')
        with self.assertRaises(ReleaseError): run_cloud(api, 'workflow', 'v1.0.0-beta.1', 'fixture-commit')
        self.assertEqual(api.request.call_count, 1)
        self.assertEqual(api.request.call_args.args, ('/v1/ciWorkflows/workflow',))

    def test_download_failure_hides_temporary_url(self):
        import cloud_api
        import urllib.error
        with tempfile.TemporaryDirectory() as directory, patch('cloud_api.urllib.request.build_opener') as opener:
            opener.return_value.open.side_effect = urllib.error.URLError('sensitive temporary token')
            with self.assertRaises(ReleaseError) as error:
                cloud_api.download('https://example.org/archive?synthetic-token=fixture', Path(directory) / 'cloud.zip')
            self.assertNotIn('token', str(error.exception))
