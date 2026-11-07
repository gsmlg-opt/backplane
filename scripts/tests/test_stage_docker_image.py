import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "stage_docker_image.py"
SPEC = importlib.util.spec_from_file_location("docker_stage", SCRIPT)
image = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(image)
SHA = "a" * 40
IMAGE_ID = "sha256:" + "b" * 64
DIGEST = "sha256:" + "c" * 64
VERSION = "1.10.59"
RUN_ID = "123"
TAG = "ghcr.io/gsmlg-dev/backplane:latest"
VERSION_TAG = "ghcr.io/gsmlg-dev/backplane:" + VERSION


class DockerImageStageTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.inspection = [{"Id": IMAGE_ID, "Config": {"Labels": {
            "org.opencontainers.image.revision": SHA,
            "org.opencontainers.image.version": VERSION,
        }}}]
        self.commands = []
        self.mock_docker = patch.object(image, "docker", side_effect=self.docker).start()
        self.addCleanup(patch.stopall)

    def docker(self, *arguments):
        self.commands.append(arguments)
        if arguments[:2] == ("image", "inspect"):
            return json.dumps(self.inspection)
        if arguments[:2] == ("image", "save"):
            Path(arguments[3]).write_bytes(b"exact verified image archive")
        if arguments[:3] == ("buildx", "imagetools", "inspect"):
            return DIGEST + "\n"
        return ""

    def stage(self):
        return image.stage(self.directory, SHA, VERSION, RUN_ID, TAG)

    def load(self):
        return image.load(self.directory, SHA, VERSION, RUN_ID, TAG)

    def publish(self):
        return image.publish(self.directory, SHA, VERSION, RUN_ID, TAG)

    def manifest(self):
        return json.loads((self.directory / "manifest.json").read_text())

    def test_stages_image_by_id_and_binds_archive_to_release_and_run_without_starting_it(self):
        manifest = self.stage()
        self.assertEqual(self.manifest(), manifest)
        self.assertEqual(manifest["image_id"], IMAGE_ID)
        self.assertEqual(manifest["revision"], SHA)
        self.assertEqual(manifest["source_run_id"], RUN_ID)
        self.assertEqual(manifest["tags"], [TAG, VERSION_TAG])
        self.assertEqual(manifest["sha256"], hashlib.sha256(b"exact verified image archive").hexdigest())
        self.assertFalse(any(command[0] in ("run", "exec", "start") for command in self.commands))
        self.assertIn(("image", "save", "--output", str(self.directory / "image.tar"), IMAGE_ID), self.commands)

    def test_rejects_invalid_inputs_before_touching_docker(self):
        for revision, version, run_id, tag in [
            ("main", VERSION, RUN_ID, TAG),
            (SHA, "v1.10.59", RUN_ID, TAG),
            (SHA, "1.2.3-01", RUN_ID, TAG),
            (SHA, "1.2.3+build.1", RUN_ID, TAG),
            (SHA, VERSION, "123\nversion=other", TAG),
            (SHA, VERSION, RUN_ID, "repo:latest\nother=tag"),
        ]:
            with self.subTest(revision=revision, version=version, run_id=run_id, tag=tag):
                with self.assertRaises(ValueError):
                    image.stage(self.directory, revision, version, run_id, tag)
        self.assertEqual([], self.commands)
        image.validate_inputs(SHA, "1.2.3-rc.1", RUN_ID, TAG)

    def test_revision_or_version_label_mismatch_cannot_be_staged(self):
        for key in ["org.opencontainers.image.revision", "org.opencontainers.image.version"]:
            with self.subTest(key=key):
                labels = self.inspection[0]["Config"]["Labels"]
                previous = labels[key]
                labels[key] = "different"
                with self.assertRaises(ValueError):
                    self.stage()
                labels[key] = previous
        self.assertFalse((self.directory / "manifest.json").exists())
        self.assertFalse(any(command[:2] == ("image", "save") for command in self.commands))

    def test_archive_failure_never_creates_a_qualified_manifest(self):
        original = self.docker

        def failed_save(*arguments):
            if arguments[:2] == ("image", "save"):
                raise RuntimeError("disk is full")
            return original(*arguments)

        with patch.object(image, "docker", side_effect=failed_save):
            with self.assertRaisesRegex(RuntimeError, "disk is full"):
                self.stage()
        self.assertFalse((self.directory / "image.tar").exists())
        self.assertFalse((self.directory / "manifest.json").exists())

    def test_restore_rejects_wrong_source_version_run_or_tags_before_loading(self):
        self.stage()
        original = self.manifest()
        for key, value in [("revision", "d" * 40), ("version", "1.10.60"),
                           ("source_run_id", "124"), ("tags", ["other/image:latest"]),
                           ("schema_version", 2), ("image_id", "invalid")]:
            with self.subTest(key=key):
                (self.directory / "manifest.json").write_text(json.dumps({**original, key: value}))
                with self.assertRaises(ValueError):
                    self.load()
        self.assertFalse(any(command[:2] == ("image", "load") for command in self.commands))

    def test_restore_rejects_corrupt_archive_before_loading(self):
        self.stage()
        (self.directory / "image.tar").write_bytes(b"modified")
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            self.load()
        self.assertFalse(any(command[:2] == ("image", "load") for command in self.commands))

    def test_restore_checks_loaded_image_labels_and_id_again(self):
        self.stage()
        self.inspection[0]["Id"] = "sha256:" + "d" * 64
        with self.assertRaisesRegex(ValueError, "image ID does not match"):
            self.load()
        self.assertTrue(any(command[:2] == ("image", "load") for command in self.commands))

    def test_publish_pushes_version_then_mutable_alias_without_building(self):
        self.stage()
        self.commands.clear()
        with patch.object(image, "remote_image_id", side_effect=[None, IMAGE_ID, IMAGE_ID]):
            result = self.publish()
        pushes = [command for command in self.commands if command[:2] == ("image", "push")]
        self.assertEqual(pushes, [("image", "push", VERSION_TAG), ("image", "push", TAG)])
        self.assertFalse(any("build" in command for command in self.commands))
        self.assertFalse(any(command[0] in ("run", "exec", "start") for command in self.commands))
        self.assertEqual(result, {"digest": DIGEST, "tags": TAG + "," + VERSION_TAG, "version": VERSION})

    def test_resume_preserves_matching_version_and_refuses_different_existing_image(self):
        self.stage()
        self.commands.clear()
        with patch.object(image, "remote_image_id", return_value=IMAGE_ID):
            self.publish()
        pushes = [command for command in self.commands if command[:2] == ("image", "push")]
        self.assertEqual(pushes, [("image", "push", TAG)])
        self.commands.clear()
        with patch.object(image, "remote_image_id", return_value="sha256:" + "d" * 64):
            with self.assertRaisesRegex(ValueError, "different image"):
                self.publish()
        self.assertFalse(any(command[:2] == ("image", "push") for command in self.commands))

    def test_version_verification_failure_does_not_move_latest(self):
        self.stage()
        self.commands.clear()
        with patch.object(image, "remote_image_id", side_effect=[None, "sha256:" + "d" * 64]):
            with self.assertRaisesRegex(ValueError, "published Docker image identity mismatch"):
                self.publish()
        self.assertNotIn(("image", "push", TAG), self.commands)

    def test_registry_errors_are_not_treated_as_missing_versions(self):
        for error in ["unauthorized: authentication required", "connection timed out", "denied"]:
            with self.subTest(error=error):
                with patch.object(image.subprocess, "run", return_value=subprocess.CompletedProcess(
                        [], 1, "", error)):
                    with self.assertRaisesRegex(ValueError, "Could not inspect"):
                        image.remote_image_id(VERSION_TAG)
        with patch.object(image.subprocess, "run", return_value=subprocess.CompletedProcess(
                [], 1, "", "manifest unknown")):
            self.assertIsNone(image.remote_image_id(VERSION_TAG))


if __name__ == "__main__":
    unittest.main()
