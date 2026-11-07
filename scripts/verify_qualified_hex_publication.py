#!/usr/bin/env python3
"""Fail closed before recovering Hex publication from a qualified Release run."""

import argparse
import hashlib
import io
import json
import os
import re
import subprocess
import zipfile


TARGETS = {
    "backplane": ("linux-x64", "linux-arm64"),
    "host_agent": ("linux-x64", "linux-arm64", "macos-x64", "macos-arm64"),
}
REPORTS = {
    "memory-replay-browser.json",
    "memory-eval-ci-smoke.json",
    "memory-longmemeval.jsonl",
    "memory-longmemeval-sidecar.json",
    "memory-m18-ci-smoke.json",
}
QUALIFICATION_FILES = REPORTS | {"qualification-manifest.txt"}
REQUIRED_JOBS = {
    "Qualify Memory",
    "Installed release database migration smoke",
} | {f"{release} ({target})" for release, targets in TARGETS.items() for target in targets}
CORE_REQUIRED_JOBS = {
    "Check release integrity",
    "Stage draft GitHub Release",
} | {f"backplane ({target})" for target in TARGETS["backplane"]}
CORE_MANIFEST = "release-manifest.json"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate_inputs(revision, version, source_run_id):
    require(re.fullmatch(r"[0-9a-f]{40}", revision), "revision must be a full lowercase SHA")
    require(re.fullmatch(r"[1-9][0-9]*", source_run_id), "source_run_id must be positive digits")
    semver = re.fullmatch(
        r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
        r"(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?"
        r"(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?", version
    )
    require(semver, "version must be a semantic version without a leading v")
    prerelease = semver.group(4)
    require(not prerelease or all(
        not item.isdigit() or item == "0" or not item.startswith("0")
        for item in prerelease.split(".")
    ), "numeric prerelease identifiers cannot have leading zeroes")


def release_assets(version):
    archives = {
        f"{release}-{version}-{target}.tar.gz"
        for release, targets in TARGETS.items() for target in targets
    }
    return archives | {name + ".sha256" for name in archives} | QUALIFICATION_FILES | {
        f"backplane-{version}-deploy.md", f"host_agent-{version}-deploy.md",
        "memory-operations.md", "memory-release.md", "memory-qualification.md",
        "host-memory-protocol.md", "host-memory-edge-runbook.md",
    }


def host_agent_assets(version):
    host_archives = {f"host_agent-{version}-{target}.tar.gz" for target in TARGETS["host_agent"]}
    return host_archives | {name + ".sha256" for name in host_archives}


def core_release_assets(version):
    return (release_assets(version) - host_agent_assets(version)
            - QUALIFICATION_FILES) | {CORE_MANIFEST}


def qualified_artifact(artifacts, name, run_id, workflow_revision):
    require(artifacts["total_count"] == len(artifacts["artifacts"]), "incomplete source artifact listing")
    matches = [artifact for artifact in artifacts["artifacts"] if artifact["name"] == name]
    require(len(matches) == 1, f"missing or duplicate {name} artifact")
    artifact = matches[0]
    require(artifact["expired"] is False and artifact["workflow_run"]["id"] == run_id
            and artifact["workflow_run"]["head_sha"] == workflow_revision,
            f"{name} artifact is expired or has a different source")
    require(re.fullmatch(r"sha256:[0-9a-f]{64}", artifact["digest"] or ""),
            f"{name} artifact has no SHA-256 digest")
    return artifact


def validate_evidence(repo, revision, version, source_run_id, run, jobs, tag_sha, release,
                      artifacts, manifest=None):
    require(run["id"] == int(source_run_id), "source run ID mismatch")
    require(run["repository"]["full_name"] == repo, "source run repository mismatch")
    require(run["path"] == ".github/workflows/release.yml", "source workflow is not release.yml")
    asset_names = [asset["name"] for asset in release["assets"]]
    core = CORE_MANIFEST in asset_names
    if core:
        require(isinstance(manifest, dict), "core release manifest is missing")
        workflow_revision = manifest.get("workflow_revision")
        require(isinstance(workflow_revision, str)
                and re.fullmatch(r"[0-9a-f]{40}", workflow_revision),
                "invalid core manifest workflow revision")
        require(manifest == {
            "schema_version": 1, "revision": revision, "workflow_revision": workflow_revision,
            "version": version, "source_run_id": int(source_run_id),
            "release_apps": "all", "host_agent": "async",
        }, "core release manifest identity or schema mismatch")
        required_jobs = CORE_REQUIRED_JOBS
    else:
        require(manifest is None, "core manifest is not a release asset")
        workflow_revision = revision
        required_jobs = REQUIRED_JOBS
    require(run["head_sha"] == workflow_revision, "source run revision mismatch")
    require(run["head_branch"] == "main" and run["event"] == "workflow_dispatch",
            "source run must be a main branch release dispatch")
    require(run["status"] == "completed", "source run is not terminal")
    require(jobs["total_count"] == len(jobs["jobs"]), "incomplete source job listing")
    for name in required_jobs:
        matches = [job for job in jobs["jobs"] if job["name"] == name]
        require(len(matches) == 1, f"missing or duplicate source job: {name}")
        job = matches[0]
        # The latest-effective listing may retain a successful job from an older
        # attempt when only failed jobs were rerun. Never fall back past a failed
        # effective job to an older successful record.
        require(job["run_id"] == run["id"] and job["head_sha"] == workflow_revision
                and 1 <= job["run_attempt"] <= run["run_attempt"],
                f"source job identity mismatch: {name}")
        require(job["status"] == "completed" and job["conclusion"] == "success",
                f"source job did not succeed: {name}")
    require(tag_sha == revision, "version tag does not resolve to the qualified revision")
    require((core or release["draft"] is False) and isinstance(release["draft"], bool)
            and release["tag_name"] == f"v{version}"
            and release["target_commitish"] == revision, "release target or published state mismatch")
    assets = release["assets"]
    if core:
        required_assets = core_release_assets(version)
        allowed_assets = required_assets | host_agent_assets(version)
        require(len(asset_names) == len(set(asset_names))
                and required_assets <= set(asset_names) <= allowed_assets,
                "release must contain the complete core asset manifest with only known optional assets")
    else:
        require(len(assets) == 25 and set(asset_names) == release_assets(version),
                "release must contain the complete 25 asset manifest")
    require(all(asset["state"] == "uploaded" and asset["size"] > 0 for asset in assets),
            "release contains incomplete assets")
    artifact_name = "core-release-manifest" if core else "memory-qualification"
    return qualified_artifact(artifacts, artifact_name, run["id"], workflow_revision)


def verify_core_manifest(blob, digest, release_blob):
    require("sha256:" + hashlib.sha256(blob).hexdigest() == digest,
            "core manifest artifact archive digest mismatch")
    with zipfile.ZipFile(io.BytesIO(blob)) as archive:
        require(archive.namelist() == [CORE_MANIFEST], "core manifest artifact file manifest mismatch")
        content = archive.read(CORE_MANIFEST)
    require(content == release_blob, "core manifest release asset differs from source artifact")
    manifest = json.loads(content)
    require(isinstance(manifest, dict), "core release manifest must be an object")
    return manifest


def verify_qualification(blob, digest, revision):
    require("sha256:" + hashlib.sha256(blob).hexdigest() == digest,
            "qualification artifact archive digest mismatch")
    with zipfile.ZipFile(io.BytesIO(blob)) as archive:
        require(len(archive.namelist()) == 6 and set(archive.namelist()) == QUALIFICATION_FILES,
                "qualification artifact file manifest mismatch")
        manifest = archive.read("qualification-manifest.txt").decode("utf-8").splitlines()
        require(len(manifest) == 8 and manifest[:3] == [
            f"revision={revision}",
            "qualification_tests=apps/backplane_memory/test/backplane/memory/qualification_test.exs",
            "outage_test=apps/backplane_api/test/backplane/api/memory_m18_outage_qualification_test.exs",
        ], "qualification manifest revision or source tests mismatch")
        checked = set()
        for line in manifest[3:]:
            match = re.fullmatch(r"([0-9a-f]{64})  artifacts/memory/([^/]+)", line)
            require(match is not None, "invalid qualification report checksum")
            checksum, name = match.groups()
            require(name in REPORTS and name not in checked, "unexpected qualification report")
            require(hashlib.sha256(archive.read(name)).hexdigest() == checksum,
                    f"qualification report hash mismatch: {name}")
            checked.add(name)
        require(checked == REPORTS, "qualification reports are incomplete")


def api(path, binary=False, asset=False):
    command = ["gh", "api", path]
    if asset:
        command += ["--header", "Accept: application/octet-stream"]
    result = subprocess.run(command, check=True, capture_output=True, timeout=120)
    return result.stdout if binary else json.loads(result.stdout)


def release_for_tag(base, tag):
    try:
        return api(f"{base}/releases/tags/{tag}")
    except subprocess.CalledProcessError as error:
        # The tag endpoint may omit unpublished drafts. Only an explicit 404
        # permits looking for the exact draft in the bounded recent inventory.
        if b"HTTP 404" not in (error.stderr or b""):
            raise
    matches = [release for release in api(f"{base}/releases?per_page=100")
               if release["tag_name"] == tag and release["draft"] is True]
    require(len(matches) == 1, "missing or duplicate draft release in recent inventory")
    return matches[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--source-run-id", required=True)
    args = parser.parse_args()
    validate_inputs(args.revision, args.version, args.source_run_id)
    repo = os.environ["GITHUB_REPOSITORY"]
    base = f"repos/{repo}"
    run_path = f"{base}/actions/runs/{args.source_run_id}"
    run = api(run_path)
    jobs = api(f"{run_path}/jobs?filter=latest&per_page=100")
    release = release_for_tag(base, f"v{args.version}")
    artifacts = api(f"{run_path}/artifacts?per_page=100")
    manifest_assets = [asset for asset in release["assets"] if asset["name"] == CORE_MANIFEST]
    manifest = None
    if manifest_assets:
        require(len(manifest_assets) == 1, "duplicate core release manifest asset")
        source = qualified_artifact(artifacts, "core-release-manifest", run["id"], run["head_sha"])
        manifest = verify_core_manifest(
            api(f"{base}/actions/artifacts/{source['id']}/zip", binary=True), source["digest"],
            api(f"{base}/releases/assets/{manifest_assets[0]['id']}", binary=True, asset=True),
        )
    tag = api(f"{base}/git/ref/tags/v{args.version}")["object"]
    for _ in range(5):
        if tag["type"] == "commit":
            break
        require(tag["type"] == "tag", "version tag is not a commit or annotated tag")
        tag = api(f"{base}/git/tags/{tag['sha']}")["object"]
    require(tag["type"] == "commit", "version tag nesting exceeds limit")
    artifact = validate_evidence(
        repo, args.revision, args.version, args.source_run_id, run, jobs, tag["sha"],
        release, artifacts, manifest=manifest,
    )
    if manifest is None:
        verify_qualification(api(f"{base}/actions/artifacts/{artifact['id']}/zip", binary=True),
                             artifact["digest"], args.revision)
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
        output.write(f"sha={args.revision}\nversion={args.version}\n")
    print(f"Qualified Hex publication: {repo}@{args.revision} v{args.version}")


if __name__ == "__main__":
    main()
