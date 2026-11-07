#!/usr/bin/env python3
"""Check existing source CI evidence; never execute tests during publication."""
import json
import os
import re
import subprocess

REQUIRED = {'.github/workflows/ci.yml', '.github/workflows/test.yml'}
OPTIONAL = {
    '.github/workflows/agent-runtime.yml', '.github/workflows/ai-protocol.yml',
    '.github/workflows/mcp-protocol.yml', '.github/workflows/skill-protocol.yml',
    '.github/workflows/audio.yml',
}


def api(path):
    result = subprocess.run(['gh', 'api', path], check=True, capture_output=True, text=True)
    return json.loads(result.stdout)


def validate_runs(runs, revision):
    latest = {}
    for run in runs:
        path = run['path']
        if path not in REQUIRED | OPTIONAL or run['head_sha'] != revision:
            continue
        if run.get('event') != 'push':
            continue
        previous = latest.get(path)
        if previous is None or (run['run_number'], run.get('run_attempt', 1)) > (
                previous['run_number'], previous.get('run_attempt', 1)):
            latest[path] = run
    missing = REQUIRED - latest.keys()
    if missing:
        raise ValueError('Missing source CI: ' + ', '.join(sorted(missing)))
    for path, run in latest.items():
        if run['status'] != 'completed' or run['conclusion'] != 'success':
            raise ValueError(f'Source CI is not successful: {path} ({run["html_url"]})')
    return latest


def main():
    revision = os.environ['SOURCE_REVISION']
    version = os.environ['RELEASE_VERSION']
    repo = os.environ['GITHUB_REPOSITORY']
    if not re.fullmatch(r'[0-9a-f]{40}', revision):
        raise ValueError('Source must be an immutable full SHA')
    response = api(f'repos/{repo}/actions/runs?head_sha={revision}&per_page=100')
    if response['total_count'] > len(response['workflow_runs']):
        raise ValueError('Incomplete source workflow listing')
    runs = validate_runs(response['workflow_runs'], revision)
    # A published version must never be rebuilt or overwritten by a fresh dispatch.
    releases = api(f'repos/{repo}/releases?per_page=100')
    for release in releases:
        if release['tag_name'] == f'v{version}' and not release['draft']:
            raise ValueError('Version is already public; retry its original failed jobs or select a new version')
    print(f'Source integrity checked: {revision}; {len(runs)} successful CI workflows')


if __name__ == '__main__':
    main()
