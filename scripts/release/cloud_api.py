"""ASC API orchestration. Errors intentionally exclude response bodies, tokens and URLs."""
import base64
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from urllib.parse import urlsplit


class ReleaseError(RuntimeError):
    pass


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ReleaseError('Unexpected API redirect')


def safe_environment():
    return {k: v for k, v in os.environ.items() if not k.startswith("APP_STORE_CONNECT_") and k not in ("SPARKLE_ED_PRIVATE_KEY", "GH_TOKEN", "GITHUB_TOKEN")}


def b64(data):
    return base64.urlsafe_b64encode(data).rstrip(b'=').decode()


def raw_ecdsa(der):
    # OpenSSL emits ASN.1 DER ECDSA; ES256 JWT requires two 32-byte unsigned integers.
    if len(der) < 8 or der[0] != 48 or der[1] != len(der) - 2:
        raise ReleaseError('Invalid ES256 signing result')
    offset, values = 2, []
    for _ in range(2):
        if der[offset] != 2:
            raise ReleaseError('Invalid ES256 signing result')
        size = der[offset + 1]
        value = der[offset + 2:offset + 2 + size]
        if len(value) != size or not value or value[0] & 128:
            raise ReleaseError('Invalid ES256 signing result')
        value = value.lstrip(b'\0')
        if len(value) > 32:
            raise ReleaseError('Invalid ES256 signing result')
        values.append(value.rjust(32, b'\0')); offset += size + 2
    if offset != len(der):
        raise ReleaseError('Invalid ES256 signing result')
    return b''.join(values)


class TeamToken:
    def __init__(self, key_id, issuer, private_key):
        self.key_id, self.issuer, self.private_key = key_id, issuer, private_key

    def __call__(self):
        now = int(time.time())
        header = b64(json.dumps(dict(alg='ES256', kid=self.key_id, typ='JWT')).encode())
        claims = b64(json.dumps(dict(iss=self.issuer, iat=now, exp=now + 600, aud='appstoreconnect-v1')).encode())
        message = f'{header}.{claims}'.encode()
        with tempfile.TemporaryDirectory(prefix='origami-asc-') as directory:
            key = Path(directory) / 'auth.p8'
            key.touch(mode=0o600); key.write_text(self.private_key)
            process = subprocess.run(['openssl', 'dgst', '-sha256', '-sign', str(key)], input=message, capture_output=True, env=safe_environment())
            if process.returncode:
                raise ReleaseError('App Store Connect token signing failed')
        return message.decode() + '.' + b64(raw_ecdsa(process.stdout))


class API:
    def __init__(self, base, token):
        self.base, self.token = base, token
        self.opener = urllib.request.build_opener(NoRedirect())

    def request(self, path, method='GET', body=None, missing=False):
        url = path if path.startswith('https://') else self.base + path
        if urlsplit(url).netloc != urlsplit(self.base).netloc or not url.startswith(self.base + '/'):
            raise ReleaseError('Unexpected API pagination location')
        headers = {'Authorization': 'Bearer ' + self.token(), 'Accept': 'application/json', 'Content-Type': 'application/json', 'User-Agent': 'Origami-Release'}
        request = urllib.request.Request(url, data=json.dumps(body).encode() if body is not None else None, headers=headers, method=method)
        # GET retries are safe. Never repeat a build-start POST after an ambiguous failure.
        for attempt in range(4):
            try:
                with self.opener.open(request, timeout=60) as response:
                    data = response.read(16 * 1024 * 1024)
                    return json.loads(data) if data else {}
            except urllib.error.HTTPError as error:
                if missing and error.code == 404:
                    return None
                if method == 'GET' and error.code in (429, 502, 503, 504) and attempt < 3:
                    time.sleep(2 ** attempt); continue
                raise ReleaseError(f'API {method} failed (HTTP {error.code})') from None
            except (OSError, ValueError):
                raise ReleaseError(f'API {method} transport or response failure') from None

    def all(self, path):
        seen = set()
        while path:
            if path in seen or len(seen) >= 1000:
                raise ReleaseError('Invalid API pagination')
            seen.add(path)
            page = self.request(path)
            if not isinstance(page.get('data'), list):
                raise ReleaseError('Malformed API collection')
            yield from page['data']
            path = page.get('links', {}).get('next')


def run_cloud(api, workflow_id, tag, commit, timeout=7200, clock=time.monotonic, sleep=time.sleep):
    workflow = api.request(f'/v1/ciWorkflows/{workflow_id}')['data']
    if not workflow['attributes'].get('isEnabled'):
        raise ReleaseError('Xcode Cloud workflow is disabled')
    repository = api.request(f'/v1/ciWorkflows/{workflow_id}/repository')['data']
    refs = [ref for ref in api.all(f'/v1/scmRepositories/{repository["id"]}/gitReferences')
            if ref['attributes'].get('canonicalName') == 'refs/tags/' + tag
            and ref['attributes'].get('kind') == 'TAG' and not ref['attributes'].get('isDeleted')]
    if len(refs) != 1:
        raise ReleaseError('Release tag was not uniquely resolved by Xcode Cloud')
    relationships = dict(workflow=dict(data=dict(type='ciWorkflows', id=workflow_id)),
                         sourceBranchOrTag=dict(data=dict(type='scmGitReferences', id=refs[0]['id'])))
    run = api.request('/v1/ciBuildRuns', 'POST', dict(data=dict(type='ciBuildRuns', attributes=dict(clean=True), relationships=relationships)))['data']
    print('Xcode Cloud build started; waiting for its notarized artifact.', flush=True)
    deadline = clock() + timeout
    while True:
        run = api.request('/v1/ciBuildRuns/' + run['id'])['data']
        attributes = run['attributes']
        if attributes.get('executionProgress') == 'COMPLETE':
            if attributes.get('completionStatus') != 'SUCCEEDED':
                raise ReleaseError('Xcode Cloud build did not succeed')
            if attributes.get('sourceCommit', {}).get('commitSha') != commit:
                raise ReleaseError('Xcode Cloud built a different commit')
            break
        if clock() >= deadline:
            raise ReleaseError('Xcode Cloud build timed out; inspect the run before retrying')
        sleep(30)
    artifacts = []
    for action in api.all(f'/v1/ciBuildRuns/{run["id"]}/actions'):
        if action['attributes'].get('actionType') == 'ARCHIVE' and action['attributes'].get('completionStatus') == 'SUCCEEDED':
            artifacts.extend(a for a in api.all(f'/v1/ciBuildActions/{action["id"]}/artifacts')
                             if a['attributes'].get('fileType') == 'STAPLED_NOTARIZED_ARCHIVE')
    if len(artifacts) != 1:
        raise ReleaseError('Expected exactly one stapled, notarized archive artifact')
    return run, artifacts[0]


def download(url, destination, expected_size=None):
    # No Authorization header is ever sent to artifact storage. Temporary URLs stay in memory.
    class HTTPSRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            validate(newurl)
            return super().redirect_request(req, fp, code, msg, headers, newurl)
    def validate(value):
        parts = urlsplit(value)
        if parts.scheme != 'https' or not parts.hostname or parts.username or parts.password:
            raise ReleaseError('Invalid artifact download location')
    validate(url)
    try:
        with urllib.request.build_opener(HTTPSRedirect()).open(url, timeout=120) as response, open(destination, 'wb') as output:
            count = 0
            while chunk := response.read(1024 * 1024):
                count += len(chunk)
                if count > 4 * 1024 ** 3:
                    raise ReleaseError('Artifact exceeds size limit')
                output.write(chunk)
        if not count or expected_size is not None and count != expected_size:
            raise ReleaseError('Artifact download size mismatch')
    except (OSError, urllib.error.URLError):
        raise ReleaseError('Artifact download failed') from None
