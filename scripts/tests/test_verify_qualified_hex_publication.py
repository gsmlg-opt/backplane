import copy
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock
import zipfile


SCRIPT = Path(__file__).resolve().parents[1] / "verify_qualified_hex_publication.py"
SPEC = importlib.util.spec_from_file_location("qualified_hex", SCRIPT)
gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate)
SHA = "512066a9e0555b5350a5cd9167da869f03981496"
VERSION = "1.10.32"
RUN_ID = "39967944591"
WORKFLOW_SHA = "a" * 40


def evidence():
    # Exercise JSON-shaped API fixtures, including a failed publication job.
    return json.loads(json.dumps({
        "run": {"id": int(RUN_ID), "repository": {"full_name": "gsmlg-opt/backplane"},
                "path": ".github/workflows/release.yml", "head_sha": SHA,
                "head_branch": "main", "event": "workflow_dispatch", "status": "completed",
                "conclusion": "failure", "run_attempt": 2},
        "jobs": {"total_count": 9, "jobs": [
            {"name": name, "run_id": int(RUN_ID), "head_sha": SHA, "run_attempt": 2,
             "status": "completed", "conclusion": "success"}
            for name in sorted(gate.REQUIRED_JOBS)
        ] + [{"name": "Publish GitHub Release", "conclusion": "failure"}]},
        "tag_sha": SHA,
        "release": {"draft": False, "tag_name": f"v{VERSION}", "target_commitish": SHA,
                    "assets": [{"name": name, "state": "uploaded", "size": 100}
                               for name in sorted(gate.release_assets(VERSION))]},
        "artifacts": {"total_count": 1, "artifacts": [
            {"id": 123, "name": "memory-qualification", "expired": False,
             "digest": "sha256:" + "a" * 64,
             "workflow_run": {"id": int(RUN_ID), "head_sha": SHA}}
        ]},
    }))


def verify(data):
    return gate.validate_evidence("gsmlg-opt/backplane", SHA, VERSION, RUN_ID, **data)


def core_manifest():
    return {"schema_version": 1, "revision": SHA, "workflow_revision": WORKFLOW_SHA,
            "version": VERSION, "source_run_id": int(RUN_ID),
            "release_apps": "all", "host_agent": "async"}


def core_evidence(draft=True):
    data = evidence()
    data["manifest"] = core_manifest()
    data["run"]["head_sha"] = WORKFLOW_SHA
    data["jobs"]["jobs"] = [
        {"name": name, "run_id": int(RUN_ID), "head_sha": WORKFLOW_SHA,
         "run_attempt": 2, "status": "completed", "conclusion": "success"}
        for name in sorted(gate.CORE_REQUIRED_JOBS)
    ]
    data["jobs"]["total_count"] = len(data["jobs"]["jobs"])
    data["release"]["draft"] = draft
    data["release"]["assets"] = [
        {"name": name, "state": "uploaded", "size": 100}
        for name in sorted(gate.core_release_assets(VERSION))
    ]
    data["artifacts"]["artifacts"] = [{
        "id": 124, "name": "core-release-manifest", "expired": False,
        "digest": "sha256:" + "a" * 64,
        "workflow_run": {"id": int(RUN_ID), "head_sha": WORKFLOW_SHA},
    }]
    return data


def manifest_archive(manifest=None, extra_file=False):
    content = json.dumps(manifest or core_manifest()).encode()
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w") as archive:
        archive.writestr("release-manifest.json", content)
        if extra_file:
            archive.writestr("unqualified.json", b"{}")
    blob = output.getvalue()
    return blob, "sha256:" + hashlib.sha256(blob).hexdigest(), content


def qualification(revision=SHA, corrupt_report=False):
    reports = {name: b'{"qualified": true}\n' for name in gate.REPORTS}
    manifest = [f"revision={revision}",
                "qualification_tests=apps/backplane_memory/test/backplane/memory/qualification_test.exs",
                "outage_test=apps/backplane_api/test/backplane/api/memory_m18_outage_qualification_test.exs"]
    manifest += [f"{hashlib.sha256(data).hexdigest()}  artifacts/memory/{name}"
                 for name, data in sorted(reports.items())]
    if corrupt_report:
        reports["memory-m18-ci-smoke.json"] = b"changed after qualification"
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w") as archive:
        for name, data in reports.items():
            archive.writestr(name, data)
        archive.writestr("qualification-manifest.txt", "\n".join(manifest) + "\n")
    return output.getvalue()


class QualifiedHexPublicationTest(unittest.TestCase):
    def test_inputs_are_strict_and_cannot_inject_outputs_or_api_paths(self):
        gate.validate_inputs(SHA, VERSION, RUN_ID)
        gate.validate_inputs(SHA, "1.2.3-rc.1+build.03", RUN_ID)
        for revision, version, run_id in [
            ("main", VERSION, RUN_ID), (SHA, "v1.10.32", RUN_ID),
            (SHA, "1.2.3-01", RUN_ID), (SHA, "1.2.3\nsha=other", RUN_ID),
            (SHA, VERSION, "1/jobs"), (SHA, VERSION, "0"),
        ]:
            with self.subTest(revision=revision, version=version, run_id=run_id):
                with self.assertRaises(ValueError):
                    gate.validate_inputs(revision, version, run_id)

    def test_failed_publication_can_recover_only_after_all_gates_pass(self):
        self.assertEqual(123, verify(evidence())["id"])

    def test_core_release_recovers_without_async_host_agent_builds_or_assets(self):
        self.assertEqual(12, len(gate.core_release_assets(VERSION)))
        self.assertTrue(gate.core_release_assets(VERSION).isdisjoint(gate.QUALIFICATION_FILES))
        self.assertEqual(4, len(gate.CORE_REQUIRED_JOBS))
        self.assertNotIn("Qualify Memory", gate.CORE_REQUIRED_JOBS)
        self.assertNotIn("Installed release database migration smoke", gate.CORE_REQUIRED_JOBS)
        for draft in [True, False]:
            with self.subTest(draft=draft):
                self.assertEqual(124, verify(core_evidence(draft))["id"])

    def test_core_release_accepts_only_known_optional_host_agent_assets(self):
        data = core_evidence()
        for name in sorted(gate.host_agent_assets(VERSION)):
            data["release"]["assets"].append({"name": name, "state": "uploaded", "size": 100})
            self.assertEqual(124, verify(data)["id"])
        data["release"]["assets"].append({
            "name": "host_agent-other-version-linux-x64.tar.gz", "state": "uploaded", "size": 100,
        })
        with self.assertRaisesRegex(ValueError, "asset manifest"):
            verify(data)

    def test_core_release_does_not_mix_legacy_memory_reports_into_its_asset_contract(self):
        data = core_evidence()
        data["release"]["assets"].append({
            "name": "memory-m18-ci-smoke.json", "state": "uploaded", "size": 100,
        })
        with self.assertRaisesRegex(ValueError, "asset manifest"):
            verify(data)

    def test_core_evidence_cannot_bypass_required_jobs_or_identity(self):
        for index in range(len(gate.CORE_REQUIRED_JOBS)):
            for key, value in [("conclusion", "failure"), ("conclusion", "skipped"),
                               ("status", "in_progress"), ("run_attempt", 0),
                               ("head_sha", SHA), ("run_id", 1)]:
                with self.subTest(index=index, key=key):
                    data = core_evidence()
                    data["jobs"]["jobs"][index][key] = value
                    with self.assertRaises(ValueError):
                        verify(data)
        for key, value in [("revision", "0" * 40), ("workflow_revision", SHA),
                           ("version", "9.9.9"), ("source_run_id", 1),
                           ("release_apps", "backplane"), ("host_agent", "required"),
                           ("schema_version", 2)]:
            with self.subTest(manifest_key=key):
                data = core_evidence()
                data["manifest"][key] = value
                with self.assertRaises(ValueError):
                    verify(data)

    def test_core_manifest_marker_does_not_relax_legacy_gates(self):
        data = evidence()
        data["manifest"] = core_manifest()
        with self.assertRaises(ValueError):
            verify(data)
        data = core_evidence()
        data.pop("manifest")
        with self.assertRaisesRegex(ValueError, "manifest"):
            verify(data)

    def test_core_assets_and_manifest_artifact_remain_complete_and_unique(self):
        for kind in ["missing_core_asset", "duplicate_asset", "missing_manifest_artifact",
                     "expired_manifest_artifact", "wrong_manifest_artifact_source"]:
            with self.subTest(kind=kind):
                data = core_evidence()
                if kind == "missing_core_asset":
                    data["release"]["assets"].pop(0)
                elif kind == "duplicate_asset":
                    data["release"]["assets"].append(data["release"]["assets"][0])
                elif kind == "missing_manifest_artifact":
                    data["artifacts"]["artifacts"].pop()
                    data["artifacts"]["total_count"] -= 1
                elif kind == "expired_manifest_artifact":
                    data["artifacts"]["artifacts"][-1]["expired"] = True
                else:
                    data["artifacts"]["artifacts"][-1]["workflow_run"]["head_sha"] = SHA
                with self.assertRaises(ValueError):
                    verify(data)

    def test_core_manifest_archive_digest_and_release_asset_bytes_are_verified(self):
        blob, digest, content = manifest_archive()
        self.assertEqual(core_manifest(), gate.verify_core_manifest(blob, digest, content))
        with self.assertRaisesRegex(ValueError, "digest"):
            gate.verify_core_manifest(blob, "sha256:" + "0" * 64, content)
        with self.assertRaisesRegex(ValueError, "release asset"):
            gate.verify_core_manifest(blob, digest, b"{}")
        blob, digest, content = manifest_archive(extra_file=True)
        with self.assertRaisesRegex(ValueError, "file manifest"):
            gate.verify_core_manifest(blob, digest, content)

    def test_core_cli_downloads_both_manifests_and_qualifies_the_bumped_revision(self):
        data = core_evidence()
        blob, digest, content = manifest_archive()
        data["artifacts"]["artifacts"][-1]["digest"] = digest
        for asset in data["release"]["assets"]:
            if asset["name"] == "release-manifest.json":
                asset["id"] = 125
        base = "repos/gsmlg-opt/backplane"
        run_path = f"{base}/actions/runs/{RUN_ID}"
        responses = {
            run_path: data["run"],
            f"{run_path}/jobs?filter=latest&per_page=100": data["jobs"],
            f"{base}/releases/tags/v{VERSION}": data["release"],
            f"{run_path}/artifacts?per_page=100": data["artifacts"],
            f"{base}/actions/artifacts/124/zip": blob,
            f"{base}/releases/assets/125": content,
            f"{base}/git/ref/tags/v{VERSION}": {"object": {"type": "commit", "sha": SHA}},
        }
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "output"
            with mock.patch.dict(os.environ, {"GITHUB_REPOSITORY": "gsmlg-opt/backplane",
                                               "GITHUB_OUTPUT": str(output)}), \
                    mock.patch("sys.argv", [str(SCRIPT), "--revision", SHA, "--version", VERSION,
                                             "--source-run-id", RUN_ID]), \
                    mock.patch.object(gate, "api", side_effect=lambda path, **kwargs: responses[path]) as api:
                gate.main()
            self.assertEqual(f"sha={SHA}\nversion={VERSION}\n", output.read_text())
            api.assert_any_call(f"{base}/releases/assets/125", binary=True, asset=True)
            self.assertNotIn(mock.call(f"{base}/actions/artifacts/123/zip", binary=True), api.call_args_list)

    def test_release_asset_download_explicitly_requests_binary_content(self):
        with mock.patch.object(gate.subprocess, "run") as run:
            run.return_value.stdout = b"manifest bytes"
            self.assertEqual(b"manifest bytes", gate.api("repos/example/releases/assets/125",
                                                        binary=True, asset=True))
            self.assertEqual(["gh", "api", "repos/example/releases/assets/125", "--header",
                              "Accept: application/octet-stream"], run.call_args.args[0])

    def test_draft_lookup_falls_back_only_for_a_missing_tag_endpoint(self):
        release = core_evidence()["release"]
        missing = subprocess.CalledProcessError(1, ["gh", "api"], stderr=b"gh: Not Found (HTTP 404)")
        with mock.patch.object(gate, "api", side_effect=[missing, [release]]) as api:
            self.assertEqual(release, gate.release_for_tag("repos/example", f"v{VERSION}"))
            api.assert_called_with("repos/example/releases?per_page=100")
        forbidden = subprocess.CalledProcessError(1, ["gh", "api"], stderr=b"gh: Forbidden (HTTP 403)")
        with mock.patch.object(gate, "api", side_effect=forbidden) as api:
            with self.assertRaises(subprocess.CalledProcessError):
                gate.release_for_tag("repos/example", f"v{VERSION}")
            self.assertEqual(1, api.call_count)
        for releases in [[], [release, release], [{**release, "draft": False}]]:
            with self.subTest(releases=releases):
                with mock.patch.object(gate, "api", side_effect=[missing, releases]):
                    with self.assertRaisesRegex(ValueError, "missing or duplicate draft"):
                        gate.release_for_tag("repos/example", f"v{VERSION}")

    def test_unqualified_source_and_incomplete_release_fail_closed(self):
        cases = [
            ("run", "path", ".github/workflows/test.yml"),
            ("run", "head_sha", "0" * 40),
            ("run", "repository", {"full_name": "other/repo"}),
            ("run", "status", "in_progress"),
            ("run", "event", "pull_request"),
            ("release", "draft", True),
            ("release", "target_commitish", "main"),
            ("release", "assets", []),
            ("artifacts", "total_count", 101),
        ]
        for section, key, value in cases:
            with self.subTest(section=section, key=key):
                data = evidence()
                data[section][key] = value
                with self.assertRaises(ValueError):
                    verify(data)
        data = evidence()
        data["tag_sha"] = "0" * 40
        with self.assertRaises(ValueError):
            verify(data)

    def test_every_effective_required_job_must_succeed_for_the_exact_source(self):
        for index in range(8):
            for key, value in [("conclusion", "failure"), ("conclusion", "skipped"),
                               ("status", "in_progress"), ("run_attempt", 0),
                               ("run_attempt", 3), ("run_id", 1),
                               ("head_sha", "0" * 40)]:
                with self.subTest(index=index, key=key, value=value):
                    data = evidence()
                    data["jobs"]["jobs"][index][key] = value
                    with self.assertRaises(ValueError):
                        verify(data)
        data = evidence()
        data["jobs"]["jobs"].pop(0)
        data["jobs"]["total_count"] -= 1
        with self.assertRaises(ValueError):
            verify(data)

    def test_failed_only_rerun_retains_prior_successes_without_accepting_stale_fallbacks(self):
        data = evidence()
        for job in data["jobs"]["jobs"][:8]:
            job["run_attempt"] = 1
        self.assertEqual(123, verify(data)["id"])

        # A failed latest-effective record cannot be rescued by its old success.
        failed = copy.deepcopy(data["jobs"]["jobs"][0])
        failed.update(run_attempt=2, conclusion="failure")
        data["jobs"]["jobs"][0] = failed
        with self.assertRaisesRegex(ValueError, "did not succeed"):
            verify(data)
        old_success = {**failed, "run_attempt": 1, "conclusion": "success"}
        data["jobs"]["jobs"].append(old_success)
        data["jobs"]["total_count"] += 1
        with self.assertRaisesRegex(ValueError, "duplicate source job"):
            verify(data)

    def test_asset_and_artifact_integrity_fail_closed(self):
        for kind in ["duplicate_asset", "unfinished_asset", "expired", "wrong_source", "no_digest"]:
            with self.subTest(kind=kind):
                data = copy.deepcopy(evidence())
                artifact = data["artifacts"]["artifacts"][0]
                if kind == "duplicate_asset":
                    data["release"]["assets"][0] = data["release"]["assets"][1]
                elif kind == "unfinished_asset":
                    data["release"]["assets"][0]["state"] = "new"
                elif kind == "expired":
                    artifact["expired"] = True
                elif kind == "wrong_source":
                    artifact["workflow_run"]["head_sha"] = "0" * 40
                else:
                    artifact["digest"] = None
                with self.assertRaises(ValueError):
                    verify(data)

    def test_qualification_archive_revision_and_each_report_hash_are_checked(self):
        blob = qualification()
        digest = "sha256:" + hashlib.sha256(blob).hexdigest()
        gate.verify_qualification(blob, digest, SHA)
        with self.assertRaisesRegex(ValueError, "archive digest"):
            gate.verify_qualification(blob, "sha256:" + "0" * 64, SHA)
        for blob, message in [(qualification(revision="0" * 40), "revision"),
                              (qualification(corrupt_report=True), "report hash")]:
            with self.subTest(message=message):
                with self.assertRaisesRegex(ValueError, message):
                    gate.verify_qualification(blob, "sha256:" + hashlib.sha256(blob).hexdigest(), SHA)


if __name__ == "__main__":
    unittest.main()
