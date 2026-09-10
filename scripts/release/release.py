#!/usr/bin/env python3
"""Orchestrate one release. Requires explicit credentials; never signs Apple code."""
import base64
import hashlib
import html
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import urllib.request
from urllib.parse import quote
from cloud_api import safe_diagnostic, API, NoRedirect, ReleaseError, TeamToken, download, run_cloud
from cloud_configuration import metadata, public_configuration
from distribution import command, ensure_order, generate_feed, package, parse_feed, sparkle_tools
from website_release import update_website

FEED_BRANCH = 'appcast'
FEED_PATH = 'appcast.xml'


def required(name):
    value = os.environ.get(name, '')
    if not value:
        raise ReleaseError('Missing configuration: ' + name)
    return value


def read_feed(github, repo):
    ref = github.request(f'/repos/{repo}/git/ref/heads/{FEED_BRANCH}', missing=True)
    if ref is None:
        return None, None
    content = github.request(f'/repos/{repo}/contents/{FEED_PATH}?ref={FEED_BRANCH}')
    if content.get('encoding') != 'base64':
        raise ReleaseError('Unsupported appcast storage')
    data = base64.b64decode(content['content'])
    parse_feed(data)
    return data, ref['object']['sha']


def publish_feed(github, repo, data, previous_head, tag):
    """Git data API gives a first-class, feed-only branch and compare-before-write protection."""
    current = github.request(f'/repos/{repo}/git/ref/heads/{FEED_BRANCH}', missing=True)
    if (current['object']['sha'] if current else None) != previous_head:
        raise ReleaseError('Appcast branch changed; retry publication after reviewing the new feed')
    blob = github.request(f'/repos/{repo}/git/blobs', 'POST', dict(content=base64.b64encode(data).decode(), encoding='base64'))
    tree = github.request(f'/repos/{repo}/git/trees', 'POST', dict(tree=[dict(path=FEED_PATH, mode='100644', type='blob', sha=blob['sha'])]))
    commit = github.request(f'/repos/{repo}/git/commits', 'POST', dict(message=f'Publish appcast for {tag}', tree=tree['sha'], parents=[previous_head] if previous_head else []))
    if previous_head:
        # Non-fast-forward rejection protects against another writer between the preceding GET and PATCH.
        github.request(f'/repos/{repo}/git/refs/heads/{FEED_BRANCH}', 'PATCH', dict(sha=commit['sha'], force=False))
    else:
        github.request(f'/repos/{repo}/git/refs', 'POST', dict(ref='refs/heads/' + FEED_BRANCH, sha=commit['sha']))


def upload(github, release, path):
    url = release['upload_url'].split('{')[0]
    if not url.startswith('https://uploads.github.com/repos/'):
        raise ReleaseError('Unexpected GitHub upload location')
    request = urllib.request.Request(url + '?name=' + quote(path.name), data=path.read_bytes(), method='POST',
                                    headers={'Authorization': 'Bearer ' + github.token(), 'Content-Type': 'application/octet-stream', 'User-Agent': 'Origami-Release'})
    try:
        with urllib.request.build_opener(NoRedirect()).open(request, timeout=300) as response:
            asset = json.load(response)
        if asset.get('state') != 'uploaded' or asset.get('size') != path.stat().st_size:
            raise ReleaseError('GitHub asset upload is incomplete')
        return asset
    except Exception:
        raise ReleaseError('GitHub Release asset upload failed; appcast was not changed') from None


def write_summary(release, stage, error=None, commit='', state=None):
    location = os.environ.get('GITHUB_STEP_SUMMARY')
    if not location:
        return
    title = release['displayVersion'] if release else 'Origami release'
    lines = ['# ' + title, '']
    if error:
        lines += ['✗ Xcode Cloud build could not be started' if stage == 'App Store Connect API' else '✗ Release did not complete', '', 'Stage: ' + stage]
        if getattr(error, 'status', None):
            lines.append(f'HTTP: {error.status}')
        lines += ['', '<pre>' + html.escape(safe_diagnostic(str(error))) + '</pre>']
    else:
        beta = release['stage'] == 'beta'
        lines += ['✓ Xcode Cloud completed', '✓ Tests passed', '✓ Developer ID signature verified',
                  '✓ Apple notarization verified', '✓ Sparkle update signed',
                  '✓ GitHub prerelease published' if beta else '✓ GitHub release published', '✓ Appcast updated', '',
                  'Version: ' + title.removeprefix('Origami '), f'Build: {release["buildNumber"]}',
                  'Commit: ' + commit[:12], 'Channel: ' + ('Beta' if beta else 'Stable'), 'Minimum macOS: 15.4']
    if state:
        checks = state.get('checks', {})
        lines += ['', '## Publication status', '']
        for label in ('Xcode Cloud', 'Tests', 'Developer ID', 'Notarization', 'Sparkle', 'GitHub Release', 'Appcast', 'Website download link'):
            status = checks.get(label, 'Not completed')
            lines.append(f'{label}: {status}')
        if release:
            lines += ['Release version: ' + release.get('tag', title).removeprefix('v'),
                      'Release channel: ' + release.get('stage', 'unknown')]
        if state.get('asset_name'):
            lines.append('Released ZIP asset: ' + state['asset_name'])
        if state.get('asset_url'):
            lines.append('Published release download: ' + state['asset_url'])
        website = state.get('website')
        if website:
            lines += ['Website version: ' + website['metadata']['version'],
                      'Website channel: ' + website['metadata']['channel'],
                      'Final website download URL: ' + website['metadata']['downloadURL']]
        else:
            lines.append('Final website download URL: not updated / unavailable')
    with open(location, 'a') as output:
        output.write('  \n'.join(lines) + '\n')


def main():
    state = dict(release=None, stage='Configuration', checks={})
    try:
        execute(state)
    except Exception as error:
        diagnostic = error if isinstance(error, ReleaseError) else ReleaseError('Unexpected provider, artifact or configuration response')
        write_summary(state['release'], state['stage'], diagnostic, state=state)
        raise


def execute(state):
    tag = required('RELEASE_TAG')
    # Validation happens before credentials, network calls or expensive builds.
    release = metadata(tag, 1)
    state['release'] = release
    if '--validate' in sys.argv:
        print(json.dumps(release)); return
    repo = required('GITHUB_REPOSITORY')
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repo):
        raise ReleaseError('Invalid repository name')
    feed, public_key = public_configuration(required('SPARKLE_FEED_URL'), required('SPARKLE_PUBLIC_ED_KEY'))
    if feed != f'https://raw.githubusercontent.com/{repo}/{FEED_BRANCH}/{FEED_PATH}':
        raise ReleaseError('Feed URL must match the configured GitHub appcast branch')
    config = dict(feed=feed, public_key=public_key, team=required('APPLE_TEAM_ID'), bundle=required('BUNDLE_IDENTIFIER'))
    if not re.fullmatch(r'[A-Z0-9]{10}', config['team']):
        raise ReleaseError('Invalid Apple team identifier')
    workflow = required('XCODE_CLOUD_WORKFLOW_ID')
    if not re.fullmatch(r'[A-Za-z0-9-]+', workflow):
        raise ReleaseError('Invalid workflow identifier')
    sparkle_key = required('SPARKLE_ED_PRIVATE_KEY')
    token = TeamToken(required('APP_STORE_CONNECT_KEY_ID'), required('APP_STORE_CONNECT_ISSUER_ID'), required('APP_STORE_CONNECT_PRIVATE_KEY'))
    github = API('https://api.github.com', lambda: required('GITHUB_TOKEN'))
    old, head = read_feed(github, repo)
    ensure_order(old, metadata(tag, sys.maxsize))
    existing = github.request(f'/repos/{repo}/releases/tags/{tag}', missing=True)
    if existing:
        raise ReleaseError('A release already exists for this tag. Use the documented feed-recovery procedure or remove only the failed draft.')
    commit = command(['git', 'rev-parse', tag + '^{commit}']).decode().strip()
    state['stage'] = 'App Store Connect API'
    run, artifact = run_cloud(API('https://api.appstoreconnect.apple.com', token), workflow, tag, commit,
                              on_started=lambda: state.update(stage='Xcode Cloud build / artifact discovery'))
    release = metadata(tag, run['attributes']['number'])
    state.setdefault('checks', {}).update({'Xcode Cloud': '✓ Completed', 'Tests': '✓ Passed (configured Xcode Cloud workflow)'})
    state.update(release=release, stage='Artifact download / verification / Sparkle packaging')
    ensure_order(old, release)
    with tempfile.TemporaryDirectory(prefix='origami-release-') as temporary:
        work = Path(temporary)
        archive = work / 'cloud.zip'
        download(artifact['attributes']['downloadUrl'], archive, artifact['attributes'].get('fileSize'))
        binary = package(archive, work, release, config)
        state['checks'].update({'Developer ID': '✓ Verified', 'Notarization': '✓ Verified'})
        tools = sparkle_tools(work)
        data = generate_feed(binary, old, release, repo, sparkle_key, tools)
        state['checks']['Sparkle'] = '✓ Signed and verified'
        checksum = work / 'SHA256SUMS.txt'
        checksum.write_text(hashlib.sha256(binary.read_bytes()).hexdigest() + '  ' + binary.name + '\n')
        # Keep a recovery copy alongside each release; it is not the updater's feed URL.
        recovery = work / 'appcast.xml'; recovery.write_bytes(data)
        provenance = work / 'release.json'
        provenance.write_text(json.dumps(dict(release=release, commit=commit, cloudBuild=run['id']), indent=2) + '\n')
        state['stage'] = 'GitHub release publication'
        draft = github.request(f'/repos/{repo}/releases', 'POST', dict(tag_name=tag, target_commitish=commit,
                 name=release['displayVersion'], draft=True, prerelease=release['stage'] == 'beta', generate_release_notes=True))
        uploaded_binary = None
        for asset in (binary, checksum, recovery, provenance):
            uploaded = upload(github, draft, asset)
            if asset == binary:
                uploaded_binary = uploaded
                state.update(asset_name=uploaded['name'], asset_url=uploaded['browser_download_url'])
        github.request(f'/repos/{repo}/releases/{draft["id"]}', 'PATCH', dict(draft=False, make_latest='false' if release['stage'] != 'stable' else 'true'))
        state['checks']['GitHub Release'] = '✓ Prerelease published' if release['stage'] == 'beta' else '✓ Published'
        # Never expose an appcast entry until all binary assets are published successfully.
        state['stage'] = 'Appcast publication (binary already published)'
        publish_feed(github, repo, data, head, tag)
        state['checks']['Appcast'] = '✓ Updated'
        # Website publication is last. Failure must never roll back the release/feed.
        state['stage'] = 'Website metadata publication (release and appcast already published)'
        try:
            state['website'] = update_website(github, repo, tag, uploaded_binary)
            state['checks']['Website download link'] = '✓ ' + state['website']['status']
        except Exception:
            state['checks']['Website download link'] = '✗ Not updated'
            raise ReleaseError('Release is published and appcast is updated, but the website download URL was not updated. '
                               'Do not rerun the release build or roll back publication. Run Update Website Download for this tag; '
                               'check public repository visibility and default-branch write access.') from None
    write_summary(release, 'Complete', commit=commit, state=state)
    print('Release, appcast and website download metadata published successfully.')


if __name__ == '__main__':
    try:
        main()
    except ReleaseError as error:
        sys.exit(safe_diagnostic(str(error)))
    except Exception:
        sys.exit('Release failed: unexpected provider, artifact or configuration response. No diagnostics containing credentials were printed.')
