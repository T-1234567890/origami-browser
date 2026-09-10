#!/usr/bin/env python3
"""Explicit repair after binary publication succeeds but feed publication fails. No Cloud run."""
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
from cloud_api import API, ReleaseError
from cloud_configuration import metadata, public_configuration
from distribution import command, generate_feed, safe_extract, sparkle_tools, verify_app
from release import read_feed, publish_feed, required
from website_release import update_website


def main():
    tag = required('RELEASE_TAG'); metadata(tag, 1)
    repository = required('GITHUB_REPOSITORY')
    github = API('https://api.github.com', lambda: required('GITHUB_TOKEN'))
    published = github.request(f'/repos/{repository}/releases/tags/{tag}')
    if published['draft']:
        raise ReleaseError('Recovery requires a completely published binary release')
    old, head = read_feed(github, repository)
    feed, key = public_configuration(required('SPARKLE_FEED_URL'), required('SPARKLE_PUBLIC_ED_KEY'))
    if feed != f'https://raw.githubusercontent.com/{repository}/appcast/appcast.xml':
        raise ReleaseError('Feed does not match the publication branch')
    config = dict(feed=feed, public_key=key, team=required('APPLE_TEAM_ID'), bundle=required('BUNDLE_IDENTIFIER'))
    with tempfile.TemporaryDirectory(prefix='origami-feed-recovery-') as temporary:
        work = Path(temporary)
        environment = {**os.environ, 'GH_TOKEN': required('GITHUB_TOKEN')}
        # gh handles authenticated private-release download and temporary storage redirects.
        for name in (metadata(tag, 1)['assetName'], 'SHA256SUMS.txt', 'release.json'):
            command(['gh', 'release', 'download', tag, '--repo', repository, '--pattern', name, '--dir', work], env=environment)
        provenance = json.loads((work / 'release.json').read_text())
        release = metadata(tag, provenance['release']['buildNumber'])
        if provenance['release'] != release:
            raise ReleaseError('Release recovery metadata is inconsistent')
        archive = work / release['assetName']
        checksum = hashlib.sha256(archive.read_bytes()).hexdigest() + '  ' + archive.name + '\n'
        if (work / 'SHA256SUMS.txt').read_text() != checksum:
            raise ReleaseError('Published artifact checksum mismatch')
        extracted = work / 'verified'; safe_extract(archive, extracted)
        verify_app(extracted / 'Origami.app', release, config)
        updates = work / 'updates'; updates.mkdir()
        archive = archive.rename(updates / archive.name)
        data = generate_feed(archive, old, release, repository, required('SPARKLE_ED_PRIVATE_KEY'), sparkle_tools(work))
        publish_feed(github, repository, data, head, tag)
    try:
        result = update_website(github, repository, tag)
    except Exception:
        message = ('Release is published and appcast is repaired, but the website download URL was not updated. '
                   'Run Update Website Download; do not rebuild or rerun appcast recovery.')
        if os.environ.get('GITHUB_STEP_SUMMARY'):
            with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as output:
                output.write('## Appcast recovery\n\nAppcast: updated\n\nWebsite download link: failed\n\n' + message + '\n')
        raise ReleaseError(message) from None
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as output:
            output.write('## Appcast recovery\n\nAppcast: updated\n\nWebsite download link: ' + result['status'] +
                         '\n\nDownload: ' + result['metadata']['downloadURL'] + '\n')
    print('Published appcast repaired and website metadata updated without rebuilding or replacing the binary.')


if __name__ == '__main__':
    try:
        main()
    except ReleaseError as error:
        sys.exit(str(error))
    except Exception:
        sys.exit('Feed recovery failed; no sensitive diagnostics were printed.')
