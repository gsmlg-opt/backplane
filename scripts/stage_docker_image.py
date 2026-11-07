#!/usr/bin/env python3
"""Stage a verified Docker image and publish that exact image after release gates."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess


IMAGE_ID = re.compile(r"sha256:[0-9a-f]{64}\Z")
REVISION = re.compile(r"[0-9a-f]{40}\Z")
VERSION = re.compile(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?\Z")
IMAGE_TAG = re.compile(r"[a-z0-9][a-z0-9./:_-]*:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}\Z")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def docker(*arguments):
    result = subprocess.run(["docker", *arguments], capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f"Docker {' '.join(arguments[:2])} failed:\n{result.stderr}{result.stdout}")
    return result.stdout


def checksum(path):
    digest = hashlib.sha256()
    with path.open("rb") as archive:
        for block in iter(lambda: archive.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def validate_inputs(revision, version, source_run_id, image):
    require(REVISION.fullmatch(revision), "revision must be a full lowercase SHA")
    require(VERSION.fullmatch(version), "version must be a semantic version usable as a Docker tag")
    prerelease = version.partition("-")[2]
    require(all(not part.isdigit() or part == "0" or not part.startswith("0")
                for part in prerelease.split(".")), "numeric prerelease identifiers cannot have leading zeroes")
    require(re.fullmatch(r"[1-9][0-9]*", source_run_id), "source run ID must be positive digits")
    require(IMAGE_TAG.fullmatch(image), "image must be an explicit Docker image tag")


def tags_for(image, version):
    return list(dict.fromkeys([image, image.rsplit(":", 1)[0] + ":" + version]))


def inspect_image(image, revision, version):
    inspected = json.loads(docker("image", "inspect", image))
    require(len(inspected) == 1, "expected exactly one loaded Docker image")
    info = inspected[0]
    require(IMAGE_ID.fullmatch(info["Id"]), "Docker image ID is invalid")
    labels = info.get("Config", {}).get("Labels") or {}
    require(labels.get("org.opencontainers.image.revision") == revision,
            "Docker image revision does not match qualified source")
    require(labels.get("org.opencontainers.image.version") == version,
            "Docker image version does not match release")
    return info["Id"]


def stage(directory, revision, version, source_run_id, image):
    validate_inputs(revision, version, source_run_id, image)
    directory.mkdir(parents=True, exist_ok=True)
    image_id = inspect_image(image, revision, version)
    archive = directory / "image.tar"
    docker("image", "save", "--output", str(archive), image_id)
    manifest = {"schema_version": 1, "revision": revision, "version": version,
                "source_run_id": source_run_id, "image_id": image_id,
                "tags": tags_for(image, version), "sha256": checksum(archive)}
    (directory / "manifest.json").write_text(json.dumps(manifest, sort_keys=True) + "\n", encoding="utf-8")
    return manifest


def load(directory, revision, version, source_run_id, image):
    validate_inputs(revision, version, source_run_id, image)
    manifest = json.loads((directory / "manifest.json").read_text(encoding="utf-8"))
    expected = {"schema_version": 1, "revision": revision, "version": version,
                "source_run_id": source_run_id, "tags": tags_for(image, version)}
    require(all(manifest.get(key) == value for key, value in expected.items()),
            "Docker artifact identity does not match qualified release")
    image_id = manifest.get("image_id", "")
    require(IMAGE_ID.fullmatch(image_id), "Docker artifact image ID is invalid")
    archive = directory / "image.tar"
    require(checksum(archive) == manifest.get("sha256"), "Docker archive checksum mismatch")
    docker("image", "load", "--input", str(archive))
    require(inspect_image(image_id, revision, version) == image_id,
            "loaded Docker image ID does not match artifact")
    return manifest


def remote_image_id(tag):
    result = subprocess.run(["docker", "manifest", "inspect", tag], capture_output=True, text=True)
    if result.returncode:
        require(re.search(r"manifest unknown|no such manifest", result.stderr, re.IGNORECASE),
                "Could not inspect existing Docker version: " + result.stderr.strip())
        return None
    manifest = json.loads(result.stdout)
    digest = manifest.get("config", {}).get("digest")
    require(IMAGE_ID.fullmatch(digest or ""), "existing Docker version is not a single staged image")
    return digest


def publish(directory, revision, version, source_run_id, image):
    manifest = load(directory, revision, version, source_run_id, image)
    image_id = manifest["image_id"]
    version_tag = image.rsplit(":", 1)[0] + ":" + version
    existing = remote_image_id(version_tag)
    require(existing in (None, image_id), "Docker version already exists with a different image")
    # Publish the version first. Mutable aliases are only moved after it verifies.
    for tag in list(dict.fromkeys([version_tag, *manifest["tags"]])):
        docker("image", "tag", image_id, tag)
        if tag != version_tag or existing is None:
            docker("image", "push", tag)
        require(remote_image_id(tag) == image_id, "published Docker image identity mismatch: " + tag)
    digest = docker("buildx", "imagetools", "inspect", version_tag,
                    "--format", "{{.Manifest.Digest}}").strip()
    require(IMAGE_ID.fullmatch(digest), "published Docker manifest digest is invalid")
    return {"digest": digest, "tags": ",".join(manifest["tags"]), "version": version}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("stage", "publish"))
    parser.add_argument("--directory", required=True, type=Path)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--source-run-id", required=True)
    parser.add_argument("--image", required=True)
    args = parser.parse_args()
    result = globals()[args.operation](args.directory, args.revision, args.version, args.source_run_id, args.image)
    if args.operation == "publish" and os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
            for key, value in result.items():
                output.write(f"{key}={value}\n")
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()
