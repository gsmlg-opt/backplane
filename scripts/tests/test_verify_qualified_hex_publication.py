import copy
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import unittest
import zipfile


SCRIPT = Path(__file__).resolve().parents[1] / "verify_qualified_hex_publication.py"
SPEC = importlib.util.spec_from_file_location("qualified_hex", SCRIPT)
gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate)
SHA = "512066a9e0555b5350a5cd9167da869f03981496"
VERSION = "1.10.32"
RUN_ID = "39967944591"


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
            {"id": 123, "name": "memory-v2-qualification", "expired": False,
             "digest": "sha256:" + "a" * 64,
             "workflow_run": {"id": int(RUN_ID), "head_sha": SHA}}
        ]},
    }))


def verify(data):
    return gate.validate_evidence("gsmlg-opt/backplane", SHA, VERSION, RUN_ID, **data)


def qualification(revision=SHA, corrupt_report=False):
    reports = {name: b'{"qualified": true}\n' for name in gate.REPORTS}
    manifest = [f"revision={revision}",
                "qualification_tests=apps/backplane_memory/test/backplane/memory/qualification_test.exs",
                "outage_test=apps/backplane_api/test/backplane/api/memory_m18_outage_qualification_test.exs"]
    manifest += [f"{hashlib.sha256(data).hexdigest()}  artifacts/memory-v2/{name}"
                 for name, data in sorted(reports.items())]
    if corrupt_report:
        reports["memory-v2-m18-ci-smoke.json"] = b"changed after qualification"
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
