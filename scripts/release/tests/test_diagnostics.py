import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch
import urllib.error
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from cloud_api import API, api_error, ReleaseError, run_cloud
from release import write_summary
from test_release import MockCloud


class DiagnosticTests(unittest.TestCase):
    def test_multiple_safe_json_errors(self):
        error = api_error(409, 'POST', json.dumps({'errors': [
            {'code': 'ENTITY_ERROR', 'title': 'Conflict', 'detail': 'Workflow cannot build this tag', 'source': {'pointer': '/data/relationships/sourceBranchOrTag'}, 'other': 'hidden'},
            {'code': 'SECOND_ERROR', 'title': 'Invalid condition'}]}))
        self.assertEqual(error.status, 409)
        for value in ['HTTP 409', 'ENTITY_ERROR', 'Conflict', 'Workflow cannot build this tag', '/data/relationships/sourceBranchOrTag', 'Apple error 2', 'SECOND_ERROR']:
            self.assertIn(value, str(error))
        self.assertNotIn('hidden', str(error))

    def test_short_configured_secrets_are_redacted_without_labels(self):
        fixtures = {'OPENAI_API_KEY': 'fixture-key-123',
                    'APP_STORE_CONNECT_KEY_ID': 'fixture-id-456',
                    'APP_STORE_CONNECT_ISSUER_ID': 'fixture-issuer-789',
                    'AWS_ACCESS_KEY_ID': 'fixture-access-123'}
        with patch.dict(os.environ, fixtures):
            error = api_error(409, 'POST', json.dumps({'errors': [
                {'detail': 'Provider echoed ' + ' '.join(fixtures.values())}]}))
        for value in fixtures.values():
            self.assertNotIn(value, str(error))
        self.assertIn('HTTP 409', str(error))
        self.assertIn('[redacted]', str(error))

    def test_summary_redacts_even_unsanitized_release_errors(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / 'summary.md'
            with patch.dict(os.environ, {'GITHUB_STEP_SUMMARY': str(destination), 'GITHUB_TOKEN': 'fixture-summary-secret'}):
                write_summary(None, 'App Store Connect API', ReleaseError('Provider echoed fixture-summary-secret', status=409))
            text = destination.read_text()
            self.assertNotIn('fixture-summary-secret', text)
            self.assertIn('[redacted]', text)
            self.assertIn('409', text)

    def test_invalid_bodies(self):
        for body in [b'not JSON sensitive', b'\xff', b'[]', b'{"errors":null}', b'{"errors":[1,{"title":{}}]}']:
            self.assertEqual(str(api_error(409, 'POST', body)), 'API POST failed (HTTP 409)')

    def test_secret_redaction_in_allowed_fields(self):
        secret = 'synthetic-private-value'
        with patch.dict(os.environ, {'SPARKLE_ED_PRIVATE_KEY': secret}):
            error = api_error(409, 'POST', json.dumps({'errors': [{'detail':
                secret + ' Bearer synthetic-jwt https://storage.example/file?signature=signed-secret '
                '-----BEGIN PRIVATE KEY-----\nprivate-content\n-----END PRIVATE KEY----- '
                'password=synthetic-password', 'title': 'actual-token'}]}), ('actual-token',))
        for value in [secret, 'synthetic-jwt', 'signed-secret', 'private-content', 'synthetic-password', 'actual-token']:
            self.assertNotIn(value, str(error))

    def test_409_post_is_not_retried_and_token_is_redacted(self):
        api = API('https://api.appstoreconnect.apple.com', lambda: 'fixture-token')
        api.opener = Mock()
        api.opener.open.side_effect = urllib.error.HTTPError(api.base, 409, 'Conflict', {}, io.BytesIO(json.dumps({'errors': [{'detail': 'Conflict fixture-token'}]}).encode()))
        with self.assertRaises(ReleaseError) as failure:
            api.request('/v1/ciBuildRuns', 'POST', {})
        self.assertNotIn('fixture-token', str(failure.exception))
        self.assertIn('Conflict', str(failure.exception))
        self.assertEqual(api.opener.open.call_count, 1)

    def test_preflight_rejects_invalid_conditions_and_references(self):
        for change in ['disabled', 'manual-disabled', 'manual-mismatch', 'wrong-repository', 'wrong-kind', 'duplicate']:
            api = MockCloud()
            request, collection = api.request, api.all
            def fake_request(path, *args, **kwargs):
                result = request(path, *args, **kwargs)
                if path.endswith('/workflow'):
                    attrs = result['data']['attributes']
                    if change == 'disabled': attrs['isEnabled'] = False
                    if change == 'manual-disabled': attrs['manualTagStartCondition'] = None
                    if change == 'manual-mismatch': attrs['manualTagStartCondition'] = {'source': {'patterns': [{'pattern': 'other', 'isPrefix': True}]}}
                return result
            def fake_all(path):
                result = collection(path)
                if path.endswith('/gitReferences'):
                    if change == 'wrong-repository': result[0]['relationships'] = {'repository': {'data': {'id': 'another'}}}
                    if change == 'wrong-kind': result[0]['attributes']['kind'] = 'BRANCH'
                    if change == 'duplicate': result = result * 2
                return result
            api.request, api.all = fake_request, fake_all
            with self.subTest(change=change), self.assertRaises(ReleaseError):
                run_cloud(api, 'workflow', 'v1.0.0', 'fixture-commit')
            self.assertEqual(api.posts, [])

    def test_manual_tag_matching_and_start_callback(self):
        for source in [{'isAllMatch': True}, {'patterns': [{'pattern': 'v1.', 'isPrefix': True}]}, {'patterns': [{'pattern': 'v1.0.0', 'isPrefix': False}]}]:
            api = MockCloud(); original = api.request
            def request(path, *args, **kwargs):
                result = original(path, *args, **kwargs)
                if path.endswith('/workflow'): result['data']['attributes']['manualTagStartCondition'] = {'source': source}
                return result
            api.request = request
            started = Mock()
            run_cloud(api, 'workflow', 'v1.0.0', 'fixture-commit', on_started=started)
            started.assert_called_once()

    def test_summaries(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {'GITHUB_STEP_SUMMARY': str(Path(directory) / 'summary')}):
            for stage in ['stable', 'beta']:
                path = Path(directory) / 'summary'; path.unlink(missing_ok=True)
                title = 'Origami 1.0.0' + (' Beta 1' if stage == 'beta' else '')
                identity = dict(displayVersion=title, stage=stage, buildNumber=123)
                write_summary(identity, 'Complete', commit='0123456789abcdef')
                text = path.read_text()
                self.assertIn('# ' + title, text)
                self.assertIn('Tests passed', text)
                self.assertIn('Build: 123', text)
                self.assertIn('GitHub prerelease published' if stage == 'beta' else 'GitHub release published', text)
                path.unlink()
                write_summary(identity, 'App Store Connect API', api_error(409, 'POST', b'{"errors":[{"title":"Conflict"}]}'))
                text = path.read_text()
                for value in ['could not be started', 'HTTP: 409', 'Conflict']: self.assertIn(value, text)
                self.assertNotIn('✓', text)

    def test_checkout_and_generated_notes(self):
        root = Path(__file__).resolve().parents[3]
        import re
        for path in (root / '.github/workflows').glob('*.yml'):
            text = path.read_text()
            for pin in re.findall(r'actions/checkout@(\S+)', text):
                self.assertEqual(pin, '3d3c42e5aac5ba805825da76410c181273ba90b1')
            self.assertNotIn('ACTIONS_ALLOW_USE_UNSECURE_NODE_VERSION', text)
        self.assertIn('generate_release_notes=True', (root / 'scripts/release/release.py').read_text())

    def test_main_records_startup_failure_without_success(self):
        from release import main
        def fail(state):
            state.update(release={'displayVersion': 'Origami 1.0.0 Beta 1'}, stage='App Store Connect API')
            raise api_error(409, 'POST', b'{"errors":[{"title":"Workflow conflict"}]}')
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'summary'
            with patch.dict(os.environ, {'GITHUB_STEP_SUMMARY': str(path)}), patch('release.execute', fail):
                with self.assertRaises(ReleaseError): main()
            text = path.read_text()
            self.assertIn('Origami 1.0.0 Beta 1', text)
            self.assertIn('Workflow conflict', text)
            self.assertIn('could not be started', text)
            self.assertNotIn('✓', text)
