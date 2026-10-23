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
    "memory-v2-replay-browser.json",
    "memory-v2-eval-ci-smoke.json",
    "memory-v2-longmemeval.jsonl",
    "memory-v2-longmemeval-sidecar.json",
    "memory-v2-m18-ci-smoke.json",
}
QUALIFICATION_FILES = REPORTS | {"qualification-manifest.txt"}
REQUIRED_JOBS = {
    "Qualify Memory V2",
    "Installed release database migration smoke",
} | {f"{release} ({target})" for release, targets in TARGETS.items() for target in targets}


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
        "memory-v2-operations.md", "memory-v2-release.md", "memory-v2-qualification.md",
        "host-memory-v2-protocol.md", "host-memory-edge-runbook.md",
    }


def validate_evidence(repo, revision, version, source_run_id, run, jobs, tag_sha, release, artifacts):
    require(run["id"] == int(source_run_id), "source run ID mismatch")
    require(run["repository"]["full_name"] == repo, "source run repository mismatch")
    require(run["path"] == ".github/workflows/release.yml", "source workflow is not release.yml")
    require(run["head_sha"] == revision, "source run revision mismatch")
    require(run["head_branch"] == "main" and run["event"] == "workflow_dispatch",
            "source run must be a main branch release dispatch")
    require(run["status"] == "completed", "source run is not terminal")
    require(jobs["total_count"] == len(jobs["jobs"]), "incomplete source job listing")
    for name in REQUIRED_JOBS:
        matches = [job for job in jobs["jobs"] if job["name"] == name]
        require(len(matches) == 1, f"missing or duplicate source job: {name}")
        job = matches[0]
        # The latest-effective listing may retain a successful job from an older
        # attempt when only failed jobs were rerun. Never fall back past a failed
        # effective job to an older successful record.
        require(job["run_id"] == run["id"] and job["head_sha"] == revision
                and 1 <= job["run_attempt"] <= run["run_attempt"],
                f"source job identity mismatch: {name}")
        require(job["status"] == "completed" and job["conclusion"] == "success",
                f"source job did not succeed: {name}")
    require(tag_sha == revision, "version tag does not resolve to the qualified revision")
    require(release["draft"] is False and release["tag_name"] == f"v{version}"
            and release["target_commitish"] == revision, "release target or published state mismatch")
    assets = release["assets"]
    require(len(assets) == 25 and {asset["name"] for asset in assets} == release_assets(version),
            "release must contain the complete 25 asset manifest")
    require(all(asset["state"] == "uploaded" and asset["size"] > 0 for asset in assets),
            "release contains incomplete assets")
    require(artifacts["total_count"] == len(artifacts["artifacts"]), "incomplete source artifact listing")
    matches = [artifact for artifact in artifacts["artifacts"]
               if artifact["name"] == "memory-v2-qualification"]
    require(len(matches) == 1, "missing or duplicate qualification artifact")
    artifact = matches[0]
    require(artifact["expired"] is False and artifact["workflow_run"]["id"] == run["id"]
            and artifact["workflow_run"]["head_sha"] == revision,
            "qualification artifact is expired or has a different source")
    require(re.fullmatch(r"sha256:[0-9a-f]{64}", artifact["digest"] or ""),
            "qualification artifact has no SHA-256 digest")
    return artifact


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
            match = re.fullmatch(r"([0-9a-f]{64})  artifacts/memory-v2/([^/]+)", line)
            require(match is not None, "invalid qualification report checksum")
            checksum, name = match.groups()
            require(name in REPORTS and name not in checked, "unexpected qualification report")
            require(hashlib.sha256(archive.read(name)).hexdigest() == checksum,
                    f"qualification report hash mismatch: {name}")
            checked.add(name)
        require(checked == REPORTS, "qualification reports are incomplete")


def api(path, binary=False):
    result = subprocess.run(["gh", "api", path], check=True, capture_output=True, timeout=120)
    return result.stdout if binary else json.loads(result.stdout)


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
    tag = api(f"{base}/git/ref/tags/v{args.version}")["object"]
    for _ in range(5):
        if tag["type"] == "commit":
            break
        require(tag["type"] == "tag", "version tag is not a commit or annotated tag")
        tag = api(f"{base}/git/tags/{tag['sha']}")["object"]
    require(tag["type"] == "commit", "version tag nesting exceeds limit")
    artifact = validate_evidence(
        repo, args.revision, args.version, args.source_run_id, run, jobs, tag["sha"],
        api(f"{base}/releases/tags/v{args.version}"), api(f"{run_path}/artifacts?per_page=100"),
    )
    verify_qualification(api(f"{base}/actions/artifacts/{artifact['id']}/zip", binary=True),
                         artifact["digest"], args.revision)
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
        output.write(f"sha={args.revision}\nversion={args.version}\n")
    print(f"Qualified Hex publication: {repo}@{args.revision} v{args.version}")


if __name__ == "__main__":
    main()
