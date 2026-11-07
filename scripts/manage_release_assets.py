#!/usr/bin/env python3
"""Stage immutable core assets, publish a complete release, and append async host assets."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tarfile

HOST_TARGETS = ('linux-x64', 'linux-arm64', 'macos-x64', 'macos-arm64')
DOCS = {'memory-operations.md', 'memory-release.md', 'memory-qualification.md',
        'host-memory-protocol.md', 'host-memory-edge-runbook.md'}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def api(path, method='GET', data=None):
    command = ['gh', 'api', '--method', method, path]
    if data is not None:
        command += ['--input', '-']
    result = subprocess.run(command, input=json.dumps(data) if data is not None else None,
                            capture_output=True, text=True)
    if result.returncode:
        if '(HTTP 404)' in result.stderr:
            return None
        raise RuntimeError(f'GitHub API request failed: {method} {path}: {result.stderr.strip()}')
    return json.loads(result.stdout) if result.stdout.strip() else None


def core_assets(version):
    archives = {f'backplane-{version}-{target}.tar.gz' for target in HOST_TARGETS[:2]}
    return archives | {name + '.sha256' for name in archives} | DOCS | {
        f'backplane-{version}-deploy.md', f'host_agent-{version}-deploy.md', 'release-manifest.json'}


def host_assets(version):
    archives = {f'host_agent-{version}-{target}.tar.gz' for target in HOST_TARGETS}
    return archives | {name + '.sha256' for name in archives}


def release(repo, tag):
    result = api(f'repos/{repo}/releases/tags/{tag}')
    if result is not None:
        return result
    # Drafts are not guaranteed to be returned by the tag route.
    matches = [item for item in api(f'repos/{repo}/releases?per_page=100') or []
               if item['tag_name'] == tag]
    require(len(matches) <= 1, 'Duplicate releases for version')
    return matches[0] if matches else None


def sha256(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def asset_digest(repo, asset):
    digest = asset.get('digest')
    if digest and re.fullmatch(r'sha256:[0-9a-f]{64}', digest):
        return digest.removeprefix('sha256:')
    command = ['gh', 'api', '-H', 'Accept: application/octet-stream',
               f'repos/{repo}/releases/assets/{asset["id"]}']
    with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE) as process:
        digest = hashlib.sha256()
        while chunk := process.stdout.read(1024 * 1024):
            digest.update(chunk)
        error = process.stderr.read().decode()
        require(process.wait() == 0, f'Could not verify existing asset: {error}')
        return digest.hexdigest()


def validate_inventory(assets, expected, optional=()):
    names = [asset['name'] for asset in assets]
    require(len(names) == len(set(names)), 'Duplicate release assets')
    require(expected <= set(names), 'Required release assets are missing')
    require(set(names) <= expected | set(optional), 'Unexpected release assets')
    require(all(asset['state'] == 'uploaded' and asset['size'] > 0 for asset in assets),
            'Release contains incomplete assets')


def validate_archives(directory, names, version, application):
    for name in names:
        if not name.endswith('.tar.gz'):
            continue
        archive = directory / name
        require(archive.is_file() and (directory / (name + '.sha256')).is_file(),
                'Archive is missing its checksum partner')
        checksum_line = (directory / (name + '.sha256')).read_text().strip().split()
        require(len(checksum_line) == 2 and Path(checksum_line[1].lstrip('*')).name == name,
                'Malformed archive checksum file')
        require(checksum_line[0] == sha256(archive), 'Archive checksum mismatch')
        # Inspect the package without starting its executable or running tests.
        with tarfile.open(archive) as package:
            contents = {member.name.removeprefix('./'): member for member in package.getmembers()}
        executable = contents.get(f'{application}/bin/{application}')
        boot = contents.get(f'{application}/releases/{version}/start.boot')
        require(executable is not None and executable.isfile() and executable.mode & 0o111,
                'Release executable is missing or is not an executable regular file')
        require(boot is not None and boot.isfile(),
                'Release version inventory does not match the requested version')


def published_host_archive(repo, current, version, target):
    require(target in HOST_TARGETS, 'Unknown Host Agent platform')
    archive_name = f'host_agent-{version}-{target}.tar.gz'
    by_name = {asset['name']: asset for asset in current['assets']}
    archive = by_name.get(archive_name)
    checksum = by_name.get(archive_name + '.sha256')
    require(archive is not None or checksum is None,
            f'Host Agent checksum exists without its archive: {target}')
    if archive is None:
        return None, None
    digest = asset_digest(repo, archive)
    if checksum is not None:
        result = subprocess.run(['gh', 'api', '-H', 'Accept: application/octet-stream',
                                 f'repos/{repo}/releases/assets/{checksum["id"]}'],
                                check=True, capture_output=True, text=True)
        fields = result.stdout.strip().split()
        require(len(fields) == 2 and fields[0] == digest
                and Path(fields[1].lstrip('*')).name == archive_name,
                f'Published Host Agent archive/checksum pair differs: {target}')
    return digest, checksum


def host_build_needed(repo, current, version, target):
    validate_inventory(current['assets'], core_assets(version), host_assets(version))
    digest, checksum = published_host_archive(repo, current, version, target)
    return digest is None or checksum is None


def reconcile_host_uploads(repo, current, directory, names, version):
    # A previous attach can stop after the archive upload. Its verified bytes are
    # immutable even if a retry rebuilt a tarball with different timestamps.
    pending = set(names)
    for target in HOST_TARGETS:
        digest, checksum = published_host_archive(repo, current, version, target)
        if digest is None:
            continue
        archive_name = f'host_agent-{version}-{target}.tar.gz'
        pending.discard(archive_name)
        pending.discard(archive_name + '.sha256')
        if checksum is None:
            directory.mkdir(parents=True, exist_ok=True)
            (directory / (archive_name + '.sha256')).write_text(f'{digest}  {archive_name}\n')
            pending.add(archive_name + '.sha256')
    return pending


def ensure_tag(repo, tag, revision, allow_create=True):
    ref = api(f'repos/{repo}/git/ref/tags/{tag}')
    if ref is None:
        require(allow_create, 'Published release tag is missing; refusing to recreate it')
        api(f'repos/{repo}/git/refs', 'POST', {'ref': f'refs/tags/{tag}', 'sha': revision})
    else:
        obj = ref['object']
        for _ in range(5):
            if obj['type'] == 'commit':
                break
            require(obj['type'] == 'tag', 'Invalid release tag type')
            obj = api(f'repos/{repo}/git/tags/{obj["sha"]}')['object']
        require(obj['type'] == 'commit' and obj['sha'] == revision,
                'Release tag points to another revision')


def upload(repo, current, directory, names):
    existing = {asset['name']: asset for asset in current['assets']}
    for name in sorted(names):
        path = directory / name
        require(path.is_file() and path.stat().st_size > 0, f'Missing or empty asset: {name}')
        if name in existing:
            require(asset_digest(repo, existing[name]) == sha256(path),
                    f'Existing asset differs; refusing overwrite: {name}')
            continue
        subprocess.run(['gh', 'release', 'upload', current['tag_name'], str(path),
                        '--repo', repo], check=True)


def validate_identity(repo, current, revision, version):
    require(current is not None, 'Release does not exist')
    require(current['target_commitish'] == revision and current['tag_name'] == f'v{version}',
            'Release source does not match the requested revision and version')
    ensure_tag(repo, f'v{version}', revision, allow_create=False)
    matches = [asset for asset in current['assets'] if asset['name'] == 'release-manifest.json']
    require(len(matches) == 1, 'Release manifest is missing or duplicated')
    result = subprocess.run(['gh', 'api', '-H', 'Accept: application/octet-stream',
                             f'repos/{repo}/releases/assets/{matches[0]["id"]}'],
                            check=True, capture_output=True)
    manifest = json.loads(result.stdout)
    require(manifest['schema_version'] == 1 and manifest['revision'] == revision
            and manifest['version'] == version and manifest['host_agent'] == 'async',
            'Release manifest identity mismatch')
    return manifest


def replace_status(body, status):
    start, end = '<!-- host-agent-status:start -->', '<!-- host-agent-status:end -->'
    replacement = f'{start}\n{status}\n{end}'
    require(body.count(start) == 1 and body.count(end) == 1, 'Host Agent status markers are missing or duplicated')
    return re.sub(re.escape(start) + r'.*?' + re.escape(end), lambda _: replacement, body, flags=re.S)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('command', choices=['stage', 'finalize', 'check-host', 'host'])
    parser.add_argument('--directory', type=Path, default=Path('dist'))
    args = parser.parse_args()
    repo, revision, version = (os.environ[key] for key in
                               ['GITHUB_REPOSITORY', 'RELEASE_REVISION', 'RELEASE_VERSION'])
    require(re.fullmatch(r'[0-9a-f]{40}', revision), 'Revision must be a full immutable SHA')
    require(re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?', version),
            'Invalid release version')
    tag = f'v{version}'
    current = release(repo, tag)
    if args.command == 'stage':
        names = {path.name for path in args.directory.iterdir() if path.is_file()}
        require(names == core_assets(version), 'Staged core asset inventory is incomplete or unexpected')
        manifest = json.loads((args.directory / 'release-manifest.json').read_text())
        require(manifest['revision'] == revision and manifest['version'] == version,
                'Staged manifest identity mismatch')
        validate_archives(args.directory, names, version, 'backplane')
        ensure_tag(repo, tag, revision)
        require(current is None or current['draft'], 'Cannot stage over an already public release')
        if current is None:
            current = api(f'repos/{repo}/releases', 'POST', {
                'tag_name': tag, 'target_commitish': revision, 'name': f'Backplane {tag}',
                'body': Path('release-notes-header.md').read_text(), 'draft': True,
                'prerelease': '-' in version.split('+')[0], 'generate_release_notes': True,
            })
        else:
            require(current['target_commitish'] == revision, 'Draft belongs to another source revision')
        upload(repo, current, args.directory, names)
        return
    validate_identity(repo, current, revision, version)
    if args.command == 'check-host':
        require(not current['draft'], 'Host Agent builds require a public main release')
        needed = host_build_needed(repo, current, version, os.environ['HOST_TARGET'])
        with open(os.environ['GITHUB_OUTPUT'], 'a', encoding='utf-8') as output:
            output.write(f'needed={str(needed).lower()}\n')
        return
    if args.command == 'finalize':
        validate_inventory(current['assets'], core_assets(version), host_assets(version))
        digest = os.environ['IMAGE_DIGEST']
        require(re.fullmatch(r'sha256:[0-9a-f]{64}', digest), 'Docker publication has no verified digest')
        body = current.get('body') or ''
        section = f'<!-- docker:start -->\n## Docker image\n\n`ghcr.io/gsmlg-dev/backplane:{version}`\n\nDigest: `{digest}`\n<!-- docker:end -->'
        if '<!-- docker:start -->' in body:
            body = re.sub(r'<!-- docker:start -->.*?<!-- docker:end -->', lambda _: section, body, flags=re.S)
        else:
            body += '\n\n' + section
        api(f'repos/{repo}/releases/{current["id"]}', 'PATCH', {
            'body': body, 'draft': False,
            'make_latest': 'false' if current['prerelease'] else 'true',
        })
        return
    require(not current['draft'], 'Cannot attach Host Agent packages before main publication')
    names = {path.name for path in args.directory.glob('*') if path.is_file()}
    require(names <= host_assets(version), 'Unexpected Host Agent assets')
    require(all((name.removesuffix('.sha256') if name.endswith('.sha256') else name + '.sha256') in names
                for name in names), 'Incomplete local Host Agent archive/checksum pair')
    validate_archives(args.directory, names, version, 'host_agent')
    validate_inventory(current['assets'], core_assets(version), host_assets(version))
    names = reconcile_host_uploads(repo, current, args.directory, names, version)
    upload(repo, current, args.directory, names)
    current = release(repo, tag)
    validate_inventory(current['assets'], core_assets(version), host_assets(version))
    available = {asset['name'] for asset in current['assets']}
    complete = [target for target in HOST_TARGETS
                if {f'host_agent-{version}-{target}.tar.gz', f'host_agent-{version}-{target}.tar.gz.sha256'} <= available]
    status = ('Host Agent packages: complete.' if len(complete) == 4 else
              'Host Agent packages: partial; missing platforms can be retried independently.')
    status += '\n\nAvailable platforms: ' + (', '.join(complete) or 'none') + '.'
    api(f'repos/{repo}/releases/{current["id"]}', 'PATCH', {
        'body': replace_status(current.get('body') or '', status),
    })


if __name__ == '__main__':
    main()
