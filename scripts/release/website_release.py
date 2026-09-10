#!/usr/bin/env python3
"""Publish only public, appcast-backed download metadata. No signing/build credentials."""
import base64
import json
import re
import sys
from urllib.parse import quote, unquote, urlsplit
from cloud_api import safe_diagnostic, API, ReleaseError
from cloud_configuration import metadata
from distribution import NS, item_build, parse_feed

WEBSITE_PATH = 'website/release.json'


def collection(github, path):
    # GitHub REST collections are arrays (unlike Apple's JSON:API collections).
    for page in range(1, 101):
        rows = github.request(f'{path}?per_page=100&page={page}')
        if not isinstance(rows, list):
            raise ReleaseError('Malformed GitHub release collection')
        yield from rows
        if len(rows) < 100:
            return
    raise ReleaseError('Too many GitHub releases or assets to safely select a download')


def version_order(identity):
    return (*map(int, identity['marketingVersion'].split('.')),
            identity.get('prereleaseNumber') or 0)


def public_asset(github, repo, published, items, uploaded=None):
    tag = published['tag_name']
    if published.get('draft') is not False or not published.get('published_at'):
        raise ReleaseError('Website download requires a published GitHub Release')
    identity = metadata(tag, 1)
    if published.get('prerelease') is not (identity['stage'] == 'beta'):
        raise ReleaseError('GitHub prerelease flag does not match the release channel')
    prefix = f'https://github.com/{repo}/releases/download/{tag}/'
    matches = []
    for item in items:
        enclosure = item.find('enclosure')
        if enclosure is not None and enclosure.get('url', '').startswith(prefix):
            matches.append((item, enclosure))
    if len(matches) != 1:
        raise ReleaseError('Published release is not uniquely present in the live appcast; repair the appcast first')
    item, enclosure = matches[0]
    identity = metadata(tag, item_build(item))
    url = enclosure.get('url', '')
    parsed = urlsplit(url)
    if (parsed.query or parsed.fragment or parsed.username or parsed.password
            or item.findtext(f'{{{NS}}}channel') != identity.get('channel')
            or item.findtext(f'{{{NS}}}shortVersionString') != identity['marketingVersion']
            or item.findtext(f'{{{NS}}}minimumSystemVersion') != '15.4'):
        raise ReleaseError('Website candidate has inconsistent appcast metadata')
    try:
        if len(base64.b64decode(enclosure.get(f'{{{NS}}}edSignature', ''), validate=True)) != 64:
            raise ValueError()
    except ValueError:
        raise ReleaseError('Website candidate is missing its published Sparkle signature') from None
    assets = list(collection(github, f'/repos/{repo}/releases/{published["id"]}/assets'))
    matches = [asset for asset in assets if asset.get('browser_download_url') == url]
    if len(matches) != 1:
        raise ReleaseError('Live appcast URL does not match exactly one uploaded GitHub asset')
    asset = matches[0]
    # The URL/name come from GitHub's asset response, not a filename template.
    if (asset.get('state') != 'uploaded' or not isinstance(asset.get('size'), int)
            or asset['size'] <= 0 or str(asset['size']) != enclosure.get('length')
            or not asset.get('name', '').endswith('.zip')
            or unquote(parsed.path.rsplit('/', 1)[-1]) != asset['name']
            or '/' in asset['name'] or '\\' in asset['name']
            or any(c in url + asset['name'] for c in '\r\n\t<>`')):
        raise ReleaseError('Published ZIP asset is incomplete or inconsistent with the live appcast')
    if uploaded is not None and any(asset.get(key) != uploaded.get(key)
                                    for key in ('id', 'name', 'browser_download_url', 'size')):
        raise ReleaseError('Published ZIP differs from the actual uploaded release asset')
    return identity, asset


def update_website(github, repo, tag, uploaded=None):
    """Idempotent, one-file Contents API write, preserving concurrent branch work."""
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repo):
        raise ReleaseError('Invalid repository name')
    metadata(tag, 1)
    repository = github.request(f'/repos/{repo}')
    if repository.get('private') is not False:
        raise ReleaseError('Website download requires a public repository and public release assets')
    branch = repository['default_branch']
    feed = github.request(f'/repos/{repo}/contents/appcast.xml?ref=appcast')
    if feed.get('encoding') != 'base64':
        raise ReleaseError('Unsupported appcast storage')
    items = parse_feed(base64.b64decode(''.join(feed['content'].split()), validate=True)).findall('channel/item')
    requested = github.request(f'/repos/{repo}/releases/tags/{quote(tag, safe="")}')
    if requested.get('tag_name') != tag:
        raise ReleaseError('GitHub returned the wrong release tag')
    requested_identity, requested_asset = public_asset(github, repo, requested, items, uploaded)

    # Inspect all public release channels, not just existing website metadata.
    # Thus an initial/stale website file cannot let Beta replace an existing Stable.
    candidates = []
    for release in collection(github, f'/repos/{repo}/releases'):
        if release.get('draft') or not release.get('published_at'):
            continue
        try:
            identity = metadata(release.get('tag_name', ''), 1)
        except ValueError:
            continue  # Non-Origami tags do not participate in download selection.
        candidates.append((identity, release))
    if not candidates:
        raise ReleaseError('No public Origami release is available')
    stable = [pair for pair in candidates if pair[0]['stage'] == 'stable']
    _, selected = max(stable or candidates, key=lambda pair: version_order(pair[0]))
    if selected['id'] == requested['id']:
        identity, asset = requested_identity, requested_asset
    else:
        identity, asset = public_asset(github, repo, selected, items)
    desired = dict(version=identity['tag'][1:], channel=identity['stage'],
                   downloadURL=asset['browser_download_url'])
    path = f'/repos/{repo}/contents/{WEBSITE_PATH}'
    current = github.request(path + '?ref=' + quote(branch, safe=''), missing=True)
    if current is None:
        raise ReleaseError('Website release.json must be committed on the default branch before releasing')
    if current.get('encoding') != 'base64':
        raise ReleaseError('Unsupported website metadata storage')
    try:
        previous = json.loads(base64.b64decode(''.join(current['content'].split()), validate=True))
        if not isinstance(previous, dict):
            raise ValueError()
        if previous.get('version'):
            old = metadata('v' + previous['version'], 1)
            if old['stage'] != previous.get('channel'):
                raise ValueError()
            if ((old['stage'] == 'stable' and identity['stage'] != 'stable')
                    or (old['stage'] == identity['stage'] and version_order(old) > version_order(identity))):
                raise ReleaseError('Refusing to downgrade the website download; review public release state')
    except (ValueError, TypeError, KeyError):
        raise ReleaseError('Existing website metadata is invalid; review it before retrying') from None
    result = dict(metadata=desired, assetName=requested_asset['name'],
                  releaseURL=requested_asset['browser_download_url'], status='already current')
    if previous == desired:
        return result
    payload = dict(message=f'Update website download to {identity["tag"]}', branch=branch,
                   sha=current['sha'], content=base64.b64encode(
                       (json.dumps(desired, indent=2) + '\n').encode()).decode())
    # SHA rejects a concurrent metadata edit. A transport failure after acceptance
    # is safe to retry: the next run sees desired and makes no duplicate commit.
    github.request(path, 'PUT', payload)
    result['status'] = 'updated'
    return result


def main():
    from release import required
    import os
    tag = required('RELEASE_TAG')
    try:
        result = update_website(API('https://api.github.com', lambda: required('GITHUB_TOKEN')),
                                required('GITHUB_REPOSITORY'), tag)
    except Exception:
        message = ('Website download metadata was not updated. Existing GitHub Releases and appcasts were not changed. '
                   'Verify public release/appcast availability and default-branch write access, then retry this website-only workflow.')
        if os.environ.get('GITHUB_STEP_SUMMARY'):
            with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as output:
                output.write('## Website download recovery\n\n' + message + '\n')
        raise ReleaseError(message) from None
    summary = ('## Website download recovery\n\n'
               f'Requested release: {tag}\n\n'
               f'Website download link: {result["status"]}\n\n'
               f'Website version: {result["metadata"]["version"]}\n\n'
               f'Website channel: {result["metadata"]["channel"]}\n\n'
               f'Download: {result["metadata"]["downloadURL"]}\n')
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as output:
            output.write(summary)
    print(summary)


if __name__ == '__main__':
    try:
        main()
    except ReleaseError as error:
        sys.exit(safe_diagnostic(str(error)))

    except Exception:
        sys.exit("Website update failed: unexpected provider or configuration response.")
