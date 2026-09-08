"""Verify trusted Cloud products, package without mutation, and generate the Sparkle feed."""
import base64
import hashlib
import os
from pathlib import Path, PurePosixPath
import plistlib
import stat
import subprocess
from urllib.parse import unquote, urlsplit
import xml.etree.ElementTree as ET
import zipfile
from cloud_api import ReleaseError, download, safe_environment
from cloud_configuration import metadata

SPARKLE_VERSION = '2.9.6'
SPARKLE_SHA256 = '52bf9e88cdd972fc0c81501377a880e90d47031bd8ca5462488f843e2609e192'
NS = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', NS)


def command(args, **kwargs):
    kwargs.setdefault("env", safe_environment())
    result = subprocess.run([str(a) for a in args], capture_output=True, **kwargs)
    if result.returncode:
        # Tool output may contain temporary URLs, signing material or filesystem paths.
        raise ReleaseError(Path(str(args[0])).name + ' failed')
    return result.stdout


def safe_extract(archive, destination):
    """Preflight paths, symlinks and expanded size before ditto preserves Apple metadata."""
    with zipfile.ZipFile(archive) as zip_file:
        entries = zip_file.infolist()
        if sum(entry.file_size for entry in entries) > 8 * 1024 ** 3:
            raise ReleaseError('Expanded artifact exceeds size limit')
        links, names = set(), set()
        for entry in entries:
            path = PurePosixPath(entry.filename)
            if path.is_absolute() or '..' in path.parts or '\\' in entry.filename or '\0' in entry.filename:
                raise ReleaseError('Unsafe archive path')
            if entry.filename in names:
                raise ReleaseError('Duplicate archive path')
            names.add(entry.filename)
            if stat.S_ISLNK(entry.external_attr >> 16):
                target = zip_file.read(entry).decode('utf-8')
                resolved = os.path.normpath(str(path.parent / target))
                if target.startswith('/') or resolved == '..' or resolved.startswith('../'):
                    raise ReleaseError('Unsafe archive symlink')
                links.add(path)
        for entry in entries:
            if any(parent in links for parent in PurePosixPath(entry.filename).parents):
                raise ReleaseError('Archive writes through a symlink')
    destination.mkdir()
    command(['ditto', '-x', '-k', archive, destination])


def verify_app(app, release, config):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    expected = {'CFBundleIdentifier': config['bundle'], 'CFBundleVersion': str(release['buildNumber']),
                'CFBundleShortVersionString': release['marketingVersion'], 'OrigamiReleaseTag': release['tag'],
                'OrigamiReleaseStage': release['stage'], 'OrigamiPrereleaseNumber': str(release.get('prereleaseNumber', '')),
                'SUFeedURL': config['feed'], 'SUPublicEDKey': config['public_key']}
    if any(info.get(key) != value for key, value in expected.items()):
        raise ReleaseError('Signed app identity or updater configuration does not match the release')
    if info.get('LSMinimumSystemVersion') != '15.4':
        raise ReleaseError('Unexpected minimum macOS version')
    requirement = 'anchor apple generic and certificate leaf[subject.OU] = "' + config['team'] + '" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists'
    command(['codesign', '--verify', '--deep', '--strict', '--test-requirement', requirement, app])
    command(['spctl', '--assess', '--type', 'execute', app])
    command(['xcrun', 'stapler', 'validate', app])
    # Inspect the executable's signed entitlements, not a mutable provisioning file.
    entitlements = plistlib.loads(command(['codesign', '-d', '--entitlements', ':-', app]))
    if entitlements.get('com.apple.security.get-task-allow'):
        raise ReleaseError('Distribution app allows debugging')


def package(artifact, work, release, config):
    extracted = work / 'cloud-product'
    safe_extract(artifact, extracted)
    candidates = [path for path in extracted.rglob('Origami.app') if path.is_dir() and not path.is_symlink()]
    if len(candidates) != 1:
        raise ReleaseError('Expected exactly one Origami application')
    app = candidates[0]
    verify_app(app, release, config)
    archives = work / 'updates'; archives.mkdir()
    archive = archives / release['assetName']
    command(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', app, archive])
    # Verify the final packaging can round-trip without invalidating the signature or ticket.
    roundtrip = work / 'roundtrip'; safe_extract(archive, roundtrip)
    verify_app(roundtrip / 'Origami.app', release, config)
    return archive


def parse_feed(data):
    if len(data) > 8 * 1024 * 1024 or b'<!DOCTYPE' in data.upper() or b'<!ENTITY' in data.upper():
        raise ReleaseError('Invalid appcast XML')
    root = ET.fromstring(data)
    if root.tag != 'rss' or root.find('channel') is None:
        raise ReleaseError('Invalid appcast structure')
    return root


def item_build(item):
    value = item.findtext(f'{{{NS}}}version')
    if value is None:
        enclosure = item.find('enclosure')
        value = enclosure.get(f'{{{NS}}}version') if enclosure is not None else None
    if not value or not value.isascii() or not value.isdigit() or int(value) < 1:
        raise ReleaseError('Invalid existing appcast build number')
    return int(value)


def ensure_order(old, release):
    if not old:
        return
    for item in parse_feed(old).findall('channel/item'):
        if item_build(item) >= release['buildNumber']:
            raise ReleaseError('Release build number must exceed every published appcast build')
        enclosure = item.find('enclosure')
        if enclosure is None:
            raise ReleaseError('Missing existing appcast enclosure')
        old_tag = unquote(urlsplit(enclosure.get('url', '')).path.split('/')[-2])
        previous = metadata(old_tag, item_build(item))
        def order(info):
            return (*map(int, info['marketingVersion'].split('.')), {'beta': 0, 'stable': 1}[info['stage']], info.get('prereleaseNumber', 0))
        if order(release) <= order(previous):
            raise ReleaseError('Release identity must advance beyond the current feed; backports need a separate policy')


def sparkle_tools(work):
    archive = work / 'sparkle.tar.xz'
    download(f'https://github.com/sparkle-project/Sparkle/releases/download/{SPARKLE_VERSION}/Sparkle-{SPARKLE_VERSION}.tar.xz', archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != SPARKLE_SHA256:
        raise ReleaseError('Sparkle tool checksum mismatch')
    destination = work / 'sparkle'; destination.mkdir()
    # The upstream, checksum-verified distribution contains framework symlinks.
    command(['tar', '-xf', archive, '-C', destination])
    return destination / 'bin'


def generate_feed(archive, old, release, repository, private_key, tools):
    ensure_order(old, release)
    feed = archive.parent / 'appcast.xml'
    if old:
        feed.write_bytes(old)
    prefix = f'https://github.com/{repository}/releases/download/{release["tag"]}/'
    args = [tools / 'generate_appcast', '--ed-key-file', '-', '--maximum-versions', '0', '--maximum-deltas', '0',
            '--versions', str(release['buildNumber']), '--download-url-prefix', prefix]
    if release.get('channel'):
        args += ['--channel', release['channel']]
    args.append(archive.parent)
    # Key on stdin, with a scrubbed environment. No persistent key file or secret arguments.
    environment = {k: v for k, v in os.environ.items() if k not in ('SPARKLE_ED_PRIVATE_KEY', 'APP_STORE_CONNECT_PRIVATE_KEY', 'GH_TOKEN', 'GITHUB_TOKEN')}
    command(args, input=private_key.encode(), env=environment)
    data = feed.read_bytes(); root = parse_feed(data)
    matches = [item for item in root.findall('channel/item') if item_build(item) == release['buildNumber']]
    if len(matches) != 1:
        raise ReleaseError('Generated appcast is missing the release')
    item = matches[0]; enclosure = item.find('enclosure')
    if (enclosure is None or enclosure.get('url') != prefix + release['assetName']
            or enclosure.get('length') != str(archive.stat().st_size)
            or len(base64.b64decode(enclosure.get(f'{{{NS}}}edSignature', ''), validate=True)) != 64
            or item.findtext(f'{{{NS}}}channel') != release.get('channel')
            or item.findtext(f'{{{NS}}}minimumSystemVersion') != '15.4'
            or item.findtext(f'{{{NS}}}shortVersionString') != release['marketingVersion']):
        raise ReleaseError('Generated appcast metadata is incorrect')
    command([tools / 'sign_update', '--verify', '--ed-key-file', '-', archive, enclosure.get(f'{{{NS}}}edSignature')], input=private_key.encode(), env=environment)
    # Ensure the tool retained both existing channels and every old update unchanged.
    if old:
        for previous in parse_feed(old).findall('channel/item'):
            current = next((i for i in root.findall('channel/item') if item_build(i) == item_build(previous)), None)
            if current is None or current.find('enclosure').attrib != previous.find('enclosure').attrib or current.findtext(f'{{{NS}}}channel') != previous.findtext(f'{{{NS}}}channel'):
                raise ReleaseError('Existing appcast item was not preserved')
    return data
