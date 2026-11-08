"""Local regression tests for publication integrity helpers; never run by Release."""
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import urllib.error


ROOT = Path(__file__).resolve().parents[1]


def load_script(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


assets = load_script("manage_release_assets")
hex_package = load_script("publish_hex_package")
SHA = "a" * 40
VERSION = "1.10.59"
REPO = "gsmlg-opt/backplane"
INNER_CHECKSUM = "b" * 64


def release_assets(names):
    return [{"id": index, "name": name, "state": "uploaded", "size": 100}
            for index, name in enumerate(sorted(names), 1)]


def release_fixture():
    return {"id": 42, "tag_name": f"v{VERSION}", "target_commitish": SHA,
            "draft": False, "prerelease": False,
            "assets": release_assets(assets.core_assets(VERSION)),
            "body": "Deployment instructions.\n<!-- host-agent-status:start -->\nHost Agent pending.\n"
                    "<!-- host-agent-status:end -->\n\n<!-- docker:start -->\n"
                    "Docker publication details and digest stay unchanged.\n<!-- docker:end -->"}


def write_release_archive(directory, application="backplane", target="linux-x64", version=VERSION,
                          missing=(), member_type=tarfile.REGTYPE, executable=True):
    name = f"{application}-{VERSION}-{target}.tar.gz"
    path = directory / name
    with tarfile.open(path, "w:gz") as archive:
        for entry in [f"{application}/bin/{application}", f"{application}/releases/{version}/start.boot"]:
            if entry in missing:
                continue
            member = tarfile.TarInfo(entry)
            member.type = member_type
            member.mode = 0o755 if executable else 0o644
            content = b"packaged release content"
            member.size = len(content) if member_type == tarfile.REGTYPE else 0
            if member_type == tarfile.SYMTYPE:
                member.linkname = "/missing-file"
            archive.addfile(member, io.BytesIO(content) if member_type == tarfile.REGTYPE else None)
    (directory / (name + ".sha256")).write_text(f"{assets.sha256(path)}  {name}\n")
    return name


def hex_tar(inner_checksum=INNER_CHECKSUM):
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w") as archive:
        for name, content in [("VERSION", b"3"), ("CHECKSUM", inner_checksum.encode()),
                              ("metadata.config", b"package metadata"), ("contents.tar.gz", b"package content")]:
            member = tarfile.TarInfo(name)
            member.size = len(content)
            archive.addfile(member, io.BytesIO(content))
    return output.getvalue()


def published_hex(blob=None, has_docs=True):
    return {"checksum": hashlib.sha256(blob if blob is not None else hex_tar()).hexdigest(),
            "has_docs": has_docs}


class ReleaseAssetsTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)

    def test_core_inventory_needs_no_host_packages_and_accepts_partial_async_assets(self):
        core = assets.core_assets(VERSION)
        self.assertFalse(any(name.startswith("host_agent-") and name.endswith(".tar.gz") for name in core))
        assets.validate_inventory(release_assets(core), core, assets.host_assets(VERSION))
        one_platform = {f"host_agent-{VERSION}-linux-x64.tar.gz", f"host_agent-{VERSION}-linux-x64.tar.gz.sha256"}
        assets.validate_inventory(release_assets(core | one_platform), core, assets.host_assets(VERSION))

    def test_inventory_rejects_missing_duplicate_unfinished_and_unexpected_assets(self):
        core = assets.core_assets(VERSION)
        good = release_assets(core)
        unfinished = [{**item, "state": "new"} if index == 0 else item for index, item in enumerate(good)]
        for inventory in [good[:-1], good + [good[0]], unfinished,
                          good + release_assets({"memory-eval-ci-smoke.json"})]:
            with self.subTest(inventory=inventory):
                with self.assertRaises(ValueError):
                    assets.validate_inventory(inventory, core, assets.host_assets(VERSION))

    def test_archive_requires_checksum_and_requested_release_inventory(self):
        name = write_release_archive(self.directory)
        names = {name, name + ".sha256"}
        assets.validate_archives(self.directory, names, VERSION, "backplane")
        (self.directory / (name + ".sha256")).write_text("0" * 64 + "  " + name + "\n")
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            assets.validate_archives(self.directory, names, VERSION, "backplane")
        write_release_archive(self.directory, version="1.10.58")
        with self.assertRaisesRegex(ValueError, "version inventory"):
            assets.validate_archives(self.directory, names, VERSION, "backplane")
        (self.directory / (name + ".sha256")).unlink()
        with self.assertRaisesRegex(ValueError, "checksum partner"):
            assets.validate_archives(self.directory, names, VERSION, "backplane")

    def test_invalid_tar_or_checksum_filename_is_rejected(self):
        name = write_release_archive(self.directory)
        names = {name, name + ".sha256"}
        (self.directory / (name + ".sha256")).write_text(assets.sha256(self.directory / name) + "  other.tar.gz\n")
        with self.assertRaisesRegex(ValueError, "Malformed archive checksum"):
            assets.validate_archives(self.directory, names, VERSION, "backplane")
        (self.directory / name).write_bytes(b"not a tar archive")
        (self.directory / (name + ".sha256")).write_text(assets.sha256(self.directory / name) + "  " + name + "\n")
        with self.assertRaises(tarfile.TarError):
            assets.validate_archives(self.directory, names, VERSION, "backplane")

    def test_required_archive_members_must_be_real_files(self):
        for member_type in [tarfile.DIRTYPE, tarfile.SYMTYPE]:
            with self.subTest(member_type=member_type):
                name = write_release_archive(self.directory, member_type=member_type)
                with self.assertRaisesRegex(ValueError, "regular|executable"):
                    assets.validate_archives(self.directory, {name, name + ".sha256"}, VERSION, "backplane")

    def test_upload_skips_matching_assets_and_never_overwrites_conflicting_bytes(self):
        name = "release-manifest.json"
        path = self.directory / name
        path.write_text("release identity")
        current = {"tag_name": f"v{VERSION}", "assets": [{"name": name, "id": 1,
                    "digest": "sha256:" + assets.sha256(path)}]}
        with patch.object(assets.subprocess, "run") as run:
            assets.upload(REPO, current, self.directory, {name})
            run.assert_not_called()
        current["assets"][0]["digest"] = "sha256:" + "0" * 64
        with patch.object(assets.subprocess, "run") as run:
            with self.assertRaisesRegex(ValueError, "refusing overwrite"):
                assets.upload(REPO, current, self.directory, {name})
            run.assert_not_called()

    def test_new_upload_does_not_use_clobber(self):
        path = self.directory / "release-manifest.json"
        path.write_text("release identity")
        with patch.object(assets.subprocess, "run") as run:
            assets.upload(REPO, {"tag_name": f"v{VERSION}", "assets": []}, self.directory, {path.name})
        command = run.call_args.args[0]
        self.assertIn("upload", command)
        self.assertNotIn("--clobber", command)

    def test_tag_collision_is_rejected_and_matching_annotated_tag_is_accepted(self):
        with patch.object(assets, "api", return_value={"object": {"type": "commit", "sha": "c" * 40}}) as api:
            with self.assertRaisesRegex(ValueError, "another revision"):
                assets.ensure_tag(REPO, f"v{VERSION}", SHA)
            self.assertEqual(api.call_count, 1)
        with patch.object(assets, "api", side_effect=[
                {"object": {"type": "tag", "sha": "d" * 40}},
                {"object": {"type": "commit", "sha": SHA}}]) as api:
            assets.ensure_tag(REPO, f"v{VERSION}", SHA)
            self.assertEqual(api.call_count, 2)

    def test_missing_tag_is_created_at_exact_revision(self):
        with patch.object(assets, "api", side_effect=[None, {"ref": f"refs/tags/v{VERSION}"}]) as api:
            assets.ensure_tag(REPO, f"v{VERSION}", SHA)
        self.assertEqual(api.call_args.args,
                         (f"repos/{REPO}/git/refs", "POST", {"ref": f"refs/tags/v{VERSION}", "sha": SHA}))

    def test_host_identity_validation_never_recreates_a_missing_release_tag(self):
        with patch.object(assets, "api", return_value=None) as api, \
                patch.object(assets.subprocess, "run") as run:
            with self.assertRaisesRegex(ValueError, "refusing to recreate"):
                assets.validate_identity(REPO, release_fixture(), SHA, VERSION)
        api.assert_called_once_with(f"repos/{REPO}/git/ref/tags/v{VERSION}")
        run.assert_not_called()

    def test_partial_host_completion_updates_only_status_and_preserves_docker_notes(self):
        name = write_release_archive(self.directory, application="host_agent")
        current = release_fixture()
        patches = []

        def upload(_repo, release, directory, names):
            self.assertEqual(names, {name, name + ".sha256"})
            self.assertEqual(directory, self.directory)
            release["assets"] += release_assets(names)

        def api(path, method="GET", data=None):
            self.assertEqual(method, "PATCH")
            patches.append(data)

        env = {"GITHUB_REPOSITORY": REPO, "RELEASE_REVISION": SHA, "RELEASE_VERSION": VERSION}
        with patch.dict(os.environ, env), patch.object(sys, "argv", ["manage_release_assets.py", "host", "--directory", str(self.directory)]), \
                patch.object(assets, "release", return_value=current), \
                patch.object(assets, "validate_identity", return_value={}), \
                patch.object(assets, "upload", side_effect=upload), patch.object(assets, "api", side_effect=api):
            assets.main()
        self.assertEqual(len(patches), 1)
        self.assertEqual(set(patches[0]), {"body"})
        body = patches[0]["body"]
        self.assertIn("packages: partial", body)
        self.assertIn("Available platforms: linux-x64.", body)
        self.assertIn("Docker publication details and digest stay unchanged.", body)
        self.assertIn("Deployment instructions.", body)

    def test_status_replacement_rejects_missing_or_duplicate_markers(self):
        for body in ["no marker", release_fixture()["body"] + "<!-- host-agent-status:start -->"]:
            with self.subTest(body=body):
                with self.assertRaisesRegex(ValueError, "markers"):
                    assets.replace_status(body, "complete")

    def test_check_host_skips_verified_existing_platform_and_builds_only_missing_pairs(self):
        archive = f"host_agent-{VERSION}-linux-x64.tar.gz"
        digest = "d" * 64
        current = release_fixture()
        remote = {"id": 101, "name": archive, "state": "uploaded", "size": 100,
                  "digest": "sha256:" + digest}
        checksum_asset = {"id": 102, "name": archive + ".sha256", "state": "uploaded", "size": 100}
        output = self.directory / "output"
        env = {"GITHUB_REPOSITORY": REPO, "RELEASE_REVISION": SHA, "RELEASE_VERSION": VERSION,
               "HOST_TARGET": "linux-x64", "GITHUB_OUTPUT": str(output)}
        for remote_assets, needed in [([], True), ([remote], True), ([remote, checksum_asset], False)]:
            with self.subTest(needed=needed, asset_count=len(remote_assets)):
                current["assets"] = release_assets(assets.core_assets(VERSION)) + remote_assets
                output.write_text("")
                with patch.dict(os.environ, env), patch.object(sys, "argv", ["manage_release_assets.py", "check-host"]), \
                        patch.object(assets, "release", return_value=current), \
                        patch.object(assets, "validate_identity", return_value={}), \
                        patch.object(assets.subprocess, "run", return_value=subprocess.CompletedProcess(
                            [], 0, digest + "  dist/" + archive + "\n", "")) as run:
                    assets.main()
                self.assertEqual(output.read_text(), f"needed={str(needed).lower()}\n")
                self.assertEqual(run.call_count, int(len(remote_assets) == 2))

    def test_check_host_rejects_corrupt_remote_pair_and_orphan_checksum(self):
        archive = f"host_agent-{VERSION}-linux-x64.tar.gz"
        current = release_fixture()
        remote = {"id": 101, "name": archive, "state": "uploaded", "size": 100,
                  "digest": "sha256:" + "d" * 64}
        checksum_asset = {"id": 102, "name": archive + ".sha256", "state": "uploaded", "size": 100}
        current["assets"] += [remote, checksum_asset]
        with patch.object(assets.subprocess, "run", return_value=subprocess.CompletedProcess(
                [], 0, "0" * 64 + "  " + archive + "\n", "")):
            with self.assertRaisesRegex(ValueError, "archive/checksum pair differs"):
                assets.host_build_needed(REPO, current, VERSION, "linux-x64")
        current["assets"].remove(remote)
        with self.assertRaisesRegex(ValueError, "checksum exists without its archive"):
            assets.host_build_needed(REPO, current, VERSION, "linux-x64")

    def test_host_retry_repairs_remote_checksum_without_overwriting_existing_archive(self):
        name = write_release_archive(self.directory, application="host_agent")
        local_digest = assets.sha256(self.directory / name)
        published_digest = "d" * 64
        self.assertNotEqual(local_digest, published_digest)
        current = release_fixture()
        current["assets"] += [{"id": 101, "name": name, "state": "uploaded", "size": 100,
                               "digest": "sha256:" + published_digest}]
        uploaded = []
        patches = []

        def upload(_repo, release, directory, names):
            uploaded.extend(names)
            self.assertEqual(names, {name + ".sha256"})
            self.assertEqual((directory / (name + ".sha256")).read_text(), published_digest + "  " + name + "\n")
            self.assertEqual(assets.sha256(directory / name), local_digest)
            release["assets"] += release_assets(names)

        env = {"GITHUB_REPOSITORY": REPO, "RELEASE_REVISION": SHA, "RELEASE_VERSION": VERSION}
        with patch.dict(os.environ, env), patch.object(sys, "argv", ["manage_release_assets.py", "host", "--directory", str(self.directory)]), \
                patch.object(assets, "release", return_value=current), \
                patch.object(assets, "validate_identity", return_value={}), \
                patch.object(assets, "upload", side_effect=upload), \
                patch.object(assets, "api", side_effect=lambda _path, _method, data: patches.append(data)):
            assets.main()
        self.assertEqual(uploaded, [name + ".sha256"])
        self.assertEqual(set(patches[0]), {"body"})
        self.assertIn("Available platforms: linux-x64.", patches[0]["body"])
        self.assertIn("Docker publication details and digest stay unchanged.", patches[0]["body"])

    def test_checksum_repair_also_works_when_no_new_build_artifacts_exist(self):
        name = f"host_agent-{VERSION}-linux-x64.tar.gz"
        current = release_fixture()
        digest = "d" * 64
        current["assets"] += [{"id": 101, "name": name, "state": "uploaded", "size": 100,
                               "digest": "sha256:" + digest}]
        pending = assets.reconcile_host_uploads(REPO, current, self.directory, set(), VERSION)
        self.assertEqual(pending, {name + ".sha256"})
        self.assertEqual((self.directory / (name + ".sha256")).read_text(), digest + "  " + name + "\n")
        self.assertFalse((self.directory / name).exists())

    def test_retry_ignores_rebuilt_tar_timestamp_differences_for_verified_remote_pair(self):
        name = write_release_archive(self.directory, application="host_agent")
        current = release_fixture()
        digest = "d" * 64
        current["assets"] += [{"id": 101, "name": name, "state": "uploaded", "size": 100,
                               "digest": "sha256:" + digest},
                              {"id": 102, "name": name + ".sha256", "state": "uploaded", "size": 100}]
        with patch.object(assets.subprocess, "run", return_value=subprocess.CompletedProcess(
                [], 0, digest + "  " + name + "\n", "")):
            pending = assets.reconcile_host_uploads(REPO, current, self.directory, {name, name + ".sha256"}, VERSION)
        self.assertEqual(pending, set())


class HostAgentWorkflowRetryTest(unittest.TestCase):
    def test_artifact_listing_skips_only_confirmed_empty_results_and_fails_on_bad_evidence(self):
        workflow = ROOT.parent / ".github/workflows/host-agent-release.yml"
        section = re.search(r"      - name: List successful platform artifacts\n(.*?)      - name: Download successful platform builds", workflow.read_text(), re.S).group(1)
        script = re.search(r"          python3 - <<'PY'\n(.*?)          PY", section, re.S).group(1)
        script = "\n".join(line.removeprefix("          ") for line in script.splitlines())
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            output = directory / "output"
            for listing, expected in [
                ({"total_count": 0, "artifacts": []}, "available=false\n"),
                ({"total_count": 1, "artifacts": [{"name": "host_agent-linux-x64", "expired": False}]}, "available=true\n"),
                ({"total_count": 2, "artifacts": []}, None),
                ({"total_count": 1, "artifacts": [{"name": "host_agent-linux-x64", "expired": True}]}, None),
            ]:
                with self.subTest(listing=listing):
                    (directory / "platform-artifacts.json").write_text(json.dumps(listing))
                    output.write_text("")
                    with contextlib.chdir(directory), patch.dict(os.environ, {"GITHUB_OUTPUT": str(output)}):
                        if expected is None:
                            with self.assertRaises(ValueError):
                                exec(compile(script, str(workflow), "exec"), {})
                            self.assertEqual(output.read_text(), "")
                        else:
                            exec(compile(script, str(workflow), "exec"), {})
                            self.assertEqual(output.read_text(), expected)


class HexPublicationTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.artifacts = self.directory / "artifacts"
        self.artifacts.mkdir()
        self.package = "backplane_plugin_protocol"
        (self.directory / "mix.exs").write_text(
            f'def project, do: [app: :{self.package}, version: "{VERSION}"]\n')
        (self.artifacts / f"{self.package}-{VERSION}.tar").write_bytes(hex_tar())
        self.old_directory = Path.cwd()
        os.chdir(self.directory)
        self.addCleanup(os.chdir, self.old_directory)

    def run_main(self, release, local_checksum=INNER_CHECKSUM, verification_error=None,
                 publish_output="", publish_status=0):
        calls = []
        self.mix_calls = calls

        def mix(command, **kwargs):
            calls.append(command)
            if command[:2] == ["mix", "hex.build"]:
                Path(command[3]).write_bytes(hex_tar(local_checksum))
            if command[:2] == ["mix", "hex.publish"]:
                result = subprocess.CompletedProcess(command, publish_status, stdout=publish_output)
                if kwargs.get("check"):
                    result.check_returncode()
                return result
            return subprocess.CompletedProcess(command, 0)

        with patch.object(sys, "argv", ["publish_hex_package.py", str(self.artifacts), VERSION]), \
                patch.object(hex_package.subprocess, "run", side_effect=mix), \
                patch.object(hex_package, "published", return_value=release) as lookup, \
                patch.object(hex_package, "verify_registry_package", side_effect=verification_error) as verify, \
                patch.object(hex_package, "await_registry") as wait, contextlib.redirect_stdout(io.StringIO()):
            self.registry_lookup = lookup
            self.registry_verification = verify
            self.registry_wait = wait
            hex_package.main()
        return calls, wait

    def test_checksum_reads_inner_checksum_not_the_outer_archive_hash(self):
        path = self.artifacts / f"{self.package}-{VERSION}.tar"
        path.write_bytes(hex_tar(INNER_CHECKSUM.upper() + "\n"))
        self.assertEqual(hex_package.checksum(path), INNER_CHECKSUM)
        self.assertNotEqual(hashlib.sha256(path.read_bytes()).hexdigest(), INNER_CHECKSUM)
        path.write_bytes(hex_tar("not-a-checksum"))
        with self.assertRaisesRegex(ValueError, "Invalid Hex package checksum"):
            hex_package.checksum(path)

    def test_existing_mismatched_hex_version_is_rejected_before_publication(self):
        with self.assertRaisesRegex(ValueError, "use a new version"):
            self.run_main(published_hex(), verification_error=ValueError(
                "Published Hex version differs from the qualified package; use a new version"))
        self.assertEqual([command[1] for command in self.mix_calls], ["hex.build"])

    def test_local_package_must_match_preflight_bytes_before_registry_lookup(self):
        with self.assertRaisesRegex(ValueError, "differs from the preflight artifact"):
            self.run_main(None, local_checksum="c" * 64)
        self.registry_lookup.assert_not_called()
        self.assertEqual([command[1] for command in self.mix_calls], ["hex.build"])

    def test_matching_package_and_docs_skips_publication_but_still_waits_for_registry(self):
        release = published_hex()
        calls, wait = self.run_main(release)
        self.assertEqual([command[1] for command in calls], ["hex.build"])
        self.registry_verification.assert_called_once_with(self.package, VERSION, INNER_CHECKSUM, release)
        wait.assert_called_once_with(self.package, VERSION, INNER_CHECKSUM)

    def test_missing_package_publishes_and_existing_missing_docs_only_publishes_docs(self):
        for release, expected in [(None, ["mix", "hex.publish", "--yes"]),
                                  (published_hex(has_docs=False), ["mix", "hex.publish", "docs", "--yes"])]:
            with self.subTest(release=release):
                calls, wait = self.run_main(release)
                self.assertEqual(calls[-1], expected)
                wait.assert_called_once_with(self.package, VERSION, INNER_CHECKSUM)
                if release is None:
                    self.registry_verification.assert_not_called()
                else:
                    self.registry_verification.assert_called_once_with(self.package, VERSION, INNER_CHECKSUM, release)

    def test_staged_package_or_docs_reports_approval_instead_of_waiting_for_registry(self):
        for release, label, suffix in [(None, "Package", ""),
                                       (published_hex(has_docs=False), "Documentation", "/docs")]:
            with self.subTest(label=label):
                url = f"https://hex.pm/dashboard/staged-releases/hexpm/{self.package}/{VERSION}{suffix}"
                output = f"\x1b[32m{label} staged for approval at {url} (expires tomorrow)\x1b[0m\n"
                summary = self.directory / "summary.md"
                summary.write_text("")
                with patch.dict(os.environ, {"GITHUB_STEP_SUMMARY": str(summary)}):
                    with self.assertRaisesRegex(ValueError, "Hex approval required") as error:
                        self.run_main(release, publish_output=output)
                self.assertIn(url, str(error.exception))
                self.assertIn("Re-run failed jobs", summary.read_text())
                self.assertIn(f"https://hex.pm/packages/{self.package}/staged-publishing", summary.read_text())
                self.registry_wait.assert_not_called()

    def test_failed_publish_keeps_its_exit_status_and_does_not_wait_for_registry(self):
        with self.assertRaises(subprocess.CalledProcessError) as error:
            self.run_main(None, publish_status=1, publish_output="** (Mix) authentication failed\n")
        self.assertEqual(error.exception.returncode, 1)
        self.registry_wait.assert_not_called()

    def test_registry_download_verifies_api_outer_checksum_and_qualified_inner_checksum(self):
        blob = hex_tar(INNER_CHECKSUM.upper() + "\n")
        release = published_hex(blob)
        with patch.object(hex_package.urllib.request, "urlopen", return_value=io.BytesIO(blob)) as urlopen:
            hex_package.verify_registry_package(self.package, VERSION, INNER_CHECKSUM, release)
        urlopen.assert_called_once_with(f"https://repo.hex.pm/tarballs/{self.package}-{VERSION}.tar", timeout=30)
        self.assertNotEqual(release["checksum"], INNER_CHECKSUM)

    def test_registry_download_rejects_outer_mismatch_even_when_inner_matches(self):
        blob = hex_tar()
        release = {**published_hex(blob), "checksum": "0" * 64}
        with patch.object(hex_package.urllib.request, "urlopen", return_value=io.BytesIO(blob)):
            with self.assertRaisesRegex(ValueError, "outer|API|checksum"):
                hex_package.verify_registry_package(self.package, VERSION, INNER_CHECKSUM, release)

    def test_registry_download_rejects_inner_mismatch_even_when_outer_matches_api(self):
        blob = hex_tar("c" * 64)
        with patch.object(hex_package.urllib.request, "urlopen", return_value=io.BytesIO(blob)):
            with self.assertRaisesRegex(ValueError, "qualified package|new version"):
                hex_package.verify_registry_package(self.package, VERSION, INNER_CHECKSUM, published_hex(blob))

    def test_registry_wait_checks_docs_then_downloads_and_verifies_actual_package(self):
        releases = [None, published_hex(has_docs=False), published_hex()]
        with patch.object(hex_package, "published", side_effect=releases), \
                patch.object(hex_package.time, "sleep") as sleep, \
                patch.object(hex_package.urllib.request, "urlopen", return_value=io.BytesIO(hex_tar())) as urlopen:
            hex_package.await_registry(self.package, VERSION, INNER_CHECKSUM, attempts=3)
        self.assertEqual(sleep.call_count, 2)
        urlopen.assert_called_once_with(f"https://repo.hex.pm/tarballs/{self.package}-{VERSION}.tar", timeout=30)

    def test_registry_wait_is_bounded_and_rejects_different_downloaded_package(self):
        with patch.object(hex_package, "published", return_value=None), \
                patch.object(hex_package.time, "sleep") as sleep:
            with self.assertRaisesRegex(ValueError, "bounded wait"):
                hex_package.await_registry(self.package, VERSION, INNER_CHECKSUM, attempts=2)
            sleep.assert_called_once_with(10)
        blob = hex_tar("c" * 64)
        with patch.object(hex_package, "published", return_value=published_hex(blob)), \
                patch.object(hex_package.urllib.request, "urlopen", return_value=io.BytesIO(blob)):
            with self.assertRaisesRegex(ValueError, "qualified package|new version"):
                hex_package.await_registry(self.package, VERSION, INNER_CHECKSUM, attempts=1)

    def test_registry_wait_retries_cdn_404_but_does_not_swallow_cdn_service_errors(self):
        missing = urllib.error.HTTPError("https://repo.hex.pm/tarballs/example.tar", 404, "not yet visible", {}, None)
        with patch.object(hex_package, "published", return_value=published_hex()), \
                patch.object(hex_package.time, "sleep") as sleep, \
                patch.object(hex_package.urllib.request, "urlopen", side_effect=[missing, io.BytesIO(hex_tar())]) as download:
            hex_package.await_registry(self.package, VERSION, INNER_CHECKSUM, attempts=2)
        self.assertEqual(download.call_count, 2)
        sleep.assert_called_once_with(10)
        unavailable = urllib.error.HTTPError("https://repo.hex.pm/tarballs/example.tar", 503, "unavailable", {}, None)
        with patch.object(hex_package, "published", return_value=published_hex()), \
                patch.object(hex_package.time, "sleep") as sleep, \
                patch.object(hex_package.urllib.request, "urlopen", side_effect=unavailable):
            with self.assertRaises(urllib.error.HTTPError):
                hex_package.await_registry(self.package, VERSION, INNER_CHECKSUM, attempts=2)
            sleep.assert_not_called()

    def test_registry_auth_or_service_errors_are_not_treated_as_missing_packages(self):
        for status in [403, 503]:
            error = urllib.error.HTTPError("https://hex.pm/api/example", status, "failure", {}, None)
            with self.subTest(status=status), patch.object(hex_package.urllib.request, "urlopen", side_effect=error):
                with self.assertRaises(urllib.error.HTTPError):
                    hex_package.published(self.package, VERSION)
        error = urllib.error.HTTPError("https://hex.pm/api/example", 404, "missing", {}, None)
        with patch.object(hex_package.urllib.request, "urlopen", side_effect=error):
            self.assertIsNone(hex_package.published(self.package, VERSION))


if __name__ == "__main__":
    unittest.main()
