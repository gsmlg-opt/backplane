#!/usr/bin/env python3
"""Publish only a preflight-matching Hex package; safely resume an existing version."""
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.request


def checksum(path):
    with tarfile.open(path) as archive:
        value = archive.extractfile('CHECKSUM').read().decode().strip().lower()
    if not re.fullmatch(r'[0-9a-f]{64}', value):
        raise ValueError('Invalid Hex package checksum')
    return value


def published(package, version):
    try:
        with urllib.request.urlopen(f'https://hex.pm/api/packages/{package}/releases/{version}', timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        raise


def verify_registry_package(package, version, expected, release):
    with urllib.request.urlopen(f'https://repo.hex.pm/tarballs/{package}-{version}.tar', timeout=30) as response:
        with tempfile.NamedTemporaryFile() as download:
            outer = hashlib.sha256()
            while chunk := response.read(1024 * 1024):
                outer.update(chunk)
                download.write(chunk)
            download.flush()
            if outer.hexdigest() != release['checksum'].lower():
                raise ValueError('Registry package archive differs from the Hex API checksum')
            if checksum(download.name) != expected:
                raise ValueError('Published Hex version differs from the qualified package; use a new version')


def compare_release(release, expected, package, version):
    if release is not None:
        verify_registry_package(package, version, expected, release)


def await_registry(package, version, expected, attempts=12):
    for attempt in range(attempts):
        release = published(package, version)
        if release and release.get('has_docs'):
            try:
                compare_release(release, expected, package, version)
                return
            except urllib.error.HTTPError as error:
                # The API and tarball CDN may become visible at different times.
                if error.code != 404:
                    raise
        if attempt + 1 < attempts:
            time.sleep(10)
    raise ValueError('Hex publication or documentation is not available after the bounded wait')


def main():
    directory, version = sys.argv[1:]
    # Work in the package selected by the workflow, including standalone runtime staging.
    manifest = Path('mix.exs').read_text()
    package = re.search(r'app:\s*:(\w+)', manifest).group(1)
    if not re.fullmatch(r'[a-z][a-z0-9_]*', package):
        raise ValueError('Invalid package name')
    expected = checksum(Path(directory) / f'{package}-{version}.tar')
    with tempfile.TemporaryDirectory(prefix='backplane-hex-check-') as temporary:
        local = Path(temporary) / 'package.tar'
        subprocess.run(['mix', 'hex.build', '--output', str(local)], check=True)
        if checksum(local) != expected:
            raise ValueError('Package differs from the preflight artifact')
    release = published(package, version)
    compare_release(release, expected, package, version)
    if release is None:
        subprocess.run(['mix', 'hex.publish', '--yes'], check=True)
    elif not release.get('has_docs'):
        subprocess.run(['mix', 'hex.publish', 'docs', '--yes'], check=True)
    else:
        print(f'{package} {version}: matching package and documentation already published')
    await_registry(package, version, expected)


if __name__ == '__main__':
    main()
