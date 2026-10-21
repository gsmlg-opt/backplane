import copy
import importlib.util
import json
import os
import tempfile
import unittest
import uuid
from pathlib import Path
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "memory_local_policy.py"
spec = importlib.util.spec_from_file_location("local_capture_policy", SCRIPT)
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)
EVENT = str(uuid.uuid4())


class FakeEffects:
    def __init__(self, state):
        self.state, self.clock, self.starts = state, 0, 0
        self.calls, self.seen = [], False
        self.unowned = set()
        self.fail_start = False
        self.disabled_accepts = False
        self.disabled_canonical = False
        self.wrong_duplicate = False
        self.fail_canonical = False
        self.ack_pending = 0
        self.lose_host_ownership = False

    def now(self):
        return self.clock

    def sleep(self, seconds):
        self.clock += seconds

    def read_state(self, _path):
        return self.state

    def owns(self, record):
        return record["name"] not in self.unowned

    def host_service(self, _state_dir, action, timeout):
        assert 0 < timeout <= 45
        self.calls.append(action)
        self.clock += 1
        host = self.state["processes"][1]
        host["stopped"] = action == "stop"
        if action == "start":
            self.starts += 1
            host["birth"] = str(self.starts)
            if self.fail_start and self.starts == 1:
                raise RuntimeError("arbitrary private child output SECRET")

    def canonical(self, _runner, timeout):
        assert 0 < timeout <= 10
        if self.fail_canonical and self.starts == 1:
            raise RuntimeError("SECRET DB diagnostic")
        return {"database": "backplane_dev", "disabled_ids": [EVENT] if self.disabled_canonical and self.starts else [],
                "restored_ids": [EVENT] if self.seen else []}

    def post(self, _base, path, body, timeout):
        assert 0 < timeout <= 8
        if path == "/memory/diagnostics":
            assert body["event_ids"] == [EVENT] and body["command_ids"] == body["mirror_ids"] == []
            pending = self.ack_pending > 0
            self.ack_pending = max(0, self.ack_pending - 1)
            return 200, {"ok": True, "result": {"observation_source": "owner_connection",
                "capture": {"missing_or_compacted": 0, "rows": [{"event_id": EVENT,
                    "acknowledged": not pending, "state": "pending" if pending else "acknowledged"}]}}}
        assert path == "/capture/v1/hooks/codex/SessionStart"
        assert body["cwd"].startswith("/synthetic/") and body["source_event_id"].endswith(":SessionStart")
        if "disabled" in body["session_id"] and not self.disabled_accepts:
            if self.lose_host_ownership:
                self.unowned.add("host")
            return 503, {"ok": False, "error": "capture persistence unavailable"}
        duplicate = self.seen
        self.seen = True
        return 202, {"ok": True, "status": "duplicate" if duplicate else "accepted",
                     "event_id": str(uuid.uuid4()) if duplicate and self.wrong_duplicate else EVENT}


class FakeUI:
    def __init__(self, runner):
        self.runner = runner
        self.captures = []
        self.changed_central = False
        self.changed_document = False
        self.no_stale = False
        self.old_fresh_report = False

    def snapshot(self):
        fx = self.runner.fx
        local = copy.deepcopy(self.runner.expected_local)
        local["capture"]["enabled"] = policy.parse_yaml(self.runner.config.read_bytes())["capture"]["enabled"]
        generation = 0 if self.old_fresh_report else fx.starts
        applied = f"2026-10-20T01:00:{generation * 2:02}Z"
        received = f"2026-10-20T01:00:{generation * 2 + 1:02}Z"
        local.update(local_applied_at=applied, report_received_at=received,
                     negotiation={"selected": "host_memory.v2", "applied_at": applied})
        stale = bool(fx.state["processes"][1].get("stopped")) and not self.no_stale
        return {"central": {key: {"configured": "true", "effective": "true"} for key in policy.CENTRAL}
                if not self.changed_central or not fx.starts else {}, "policy": local,
                "documents": {"config": {"url": "/config", "document": "changed" if self.changed_document and fx.starts else "original"}},
                "stale": stale, "health_stale": stale}

    def screenshots(self, _output, phase):
        self.captures.append(phase)


class LocalPolicyTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        self.root_patch = patch.object(policy, "ROOT", self.root)
        self.root_patch.start()
        folder = self.root / ".devenv/memory-local-fixtures/oct20-a"
        primary = folder / "primary"
        primary.mkdir(parents=True, mode=0o700)
        self.state_dir = self.root / ".devenv/memory-local"
        self.state_dir.mkdir(mode=0o700)
        host, space = str(uuid.uuid4()), str(uuid.uuid4())
        self.config = primary / "host.yaml"
        self.original = (f"# preserve exact bytes\nagent:\n  host_id: {host}\n"
            "  machine_name: memory-local-oct20-a-primary\n  hub_url: http://localhost:4220\n"
            "  token: SECRET\n  http_bind: 127.0.0.1\n  http_port: 4222\n"
            f"memory:\n  enabled: true\n  bound_scope: memory_local_oct20-a_primary\n  db_path: {primary}/commands.db\n"
            "  sync_interval_ms: 1000\n  host_sync_v2:\n    enabled: true\n    development_plaintext: true\n"
            f"    db_path: {primary}/mirror.db\n    sync_interval_ms: 1000\n"
            f"capture:\n  enabled: true # keep comment\n  db_path: {primary}/capture-spool.db\n"
            "  upload_interval_ms: 1000\n  inject_context: false\ntargets: []\n").encode()
        self.config.write_bytes(self.original)
        self.config.chmod(0o600)
        for filename in ("commands.db", "capture-spool.db", "mirror.db"):
            path = primary / filename
            path.write_bytes(b"private fixture")
            path.chmod(0o600)
        partition = {"host_id": host, "memory_space_id": space, "client_id": "host:" + host,
                     "scope": "memory_local_oct20-a_primary", "namespace": "private"}
        self.fixture = folder / "fixture.json"
        self.fixture.write_text(json.dumps({"run_id": "oct20-a", "hosts": [
            {"name": "memory-local-oct20-a-primary", "host_id": host, "config": str(self.config), "partition": partition}, {}]}))
        self.fixture.chmod(0o600)
        state = {"config": str(self.config), "urls": {"public": "http://127.0.0.1:4220/",
            "admin": "http://127.0.0.1:4221/", "host": "http://127.0.0.1:4222/"}, "processes": [
            {"name": "gateway", "pid": 11, "pgid": 11, "birth": "gateway", "uid": os.getuid()},
            {"name": "host", "pid": 12, "pgid": 12, "birth": "original", "uid": os.getuid()}]}
        state_path = self.state_dir / "state.json"
        state_path.write_text(json.dumps(state))
        state_path.chmod(0o600)
        self.fx = FakeEffects(state)

    def tearDown(self):
        self.root_patch.stop()
        self.temp.cleanup()

    def prepared(self):
        runner = policy.Runner(self.fixture, self.state_dir, "case", effects=self.fx)
        runner.preflight()
        return runner, FakeUI(runner)

    def test_capture_only_edit_preserves_comments_crlf_and_other_enabled_flags(self):
        original = self.original.replace(b"\n", b"\r\n")
        changed = policy.disabled_config(original)
        self.assertEqual(changed, original.replace(b"  enabled: true # keep comment", b"  enabled: false # keep comment"))

    def test_duplicate_yaml_and_alias_edit_refused(self):
        for raw in (b"capture:\n  enabled: true\n  enabled: true\n",
                    b"flag: &flag true\ncapture:\n  enabled: *flag\n"):
            with self.assertRaises(policy.CheckFailed):
                policy.disabled_config(raw)

    def test_private_file_rejects_symlinks_permissions_and_hardlinks(self):
        link = self.config.parent / "link"
        link.symlink_to(self.config)
        with self.assertRaises(policy.CheckFailed):
            policy.private_read(link)
        self.config.chmod(0o644)
        with self.assertRaises(policy.CheckFailed):
            policy.private_read(self.config)
        self.config.chmod(0o600)
        link.unlink()
        os.link(self.config, link)
        with self.assertRaises(policy.CheckFailed):
            policy.private_read(self.config)

    def test_guard_restores_original_bytes_and_refuses_external_edits(self):
        backup = self.state_dir / "guard.private"
        guard = policy.ConfigGuard(self.config, backup)
        guard.save_backup()
        self.assertEqual(backup.stat().st_mode & 0o777, 0o600)
        guard.replace(guard.disabled)
        guard.replace(guard.original)
        self.assertEqual(self.config.read_bytes(), self.original)
        self.config.write_bytes(b"external user edit")
        with self.assertRaisesRegex(policy.CheckFailed, "external_config_edit_refused"):
            guard.replace(guard.original)
        self.assertEqual(self.config.read_bytes(), b"external user edit")

    def test_happy_path_cleans_config_host_and_private_backup(self):
        runner, ui = self.prepared()
        self.fx.ack_pending = 2
        report = runner.execute(ui)
        self.assertEqual(report["status"], "passed-host-capture-policy-subset")
        self.assertTrue(report["cleanup"]["verified"])
        self.assertEqual(self.fx.calls, ["stop", "start", "stop", "start"])
        self.assertEqual(self.config.read_bytes(), self.original)
        self.assertFalse(runner.guard.backup.exists())
        self.assertFalse(self.fx.state["processes"][1].get("stopped"))
        self.assertEqual(ui.captures, ["baseline", "stopped_report", "disabled_report", "restored_report"])
        encoded = json.dumps(report)
        self.assertNotIn("SECRET", encoded)
        self.assertNotIn("db_path", encoded)
        self.assertFalse(report["complete_L01_L18"])

    def test_partial_start_failure_still_restores_running_host_and_sanitizes_error(self):
        runner, ui = self.prepared()
        self.fx.fail_start = True
        report = runner.execute(ui)
        self.assertEqual(report["status"], "failed")
        self.assertEqual(report["error"], "policy_probe_failed")
        self.assertTrue(report["cleanup"]["verified"])
        self.assertEqual(self.fx.calls, ["stop", "start", "stop", "start"])
        self.assertEqual(self.config.read_bytes(), self.original)
        self.assertNotIn("SECRET", json.dumps(report))

    def test_disabled_capture_unexpected_success_is_failure_after_restoration(self):
        runner, ui = self.prepared()
        self.fx.disabled_accepts = True
        report = runner.execute(ui)
        self.assertEqual(report["error"], "disabled_capture_behavior_wrong")
        self.assertTrue(report["cleanup"]["verified"])
        self.assertEqual(self.config.read_bytes(), self.original)

    def test_disabled_canonical_effect_cannot_pass(self):
        runner, ui = self.prepared()
        self.fx.disabled_canonical = True
        report = runner.execute(ui)
        self.assertEqual(report["error"], "disabled_capture_became_canonical")
        self.assertTrue(report["cleanup"]["verified"])

    def test_failed_read_after_disabled_probe_still_restores(self):
        runner, ui = self.prepared()
        self.fx.fail_canonical = True
        report = runner.execute(ui)
        self.assertEqual(report["error"], "policy_probe_failed")
        self.assertTrue(report["cleanup"]["verified"])

    def test_duplicate_id_mismatch_does_not_pass(self):
        runner, ui = self.prepared()
        self.fx.wrong_duplicate = True
        report = runner.execute(ui)
        self.assertEqual(report["error"], "duplicate_capture_id_changed")
        self.assertTrue(report["cleanup"]["verified"])

    def test_ownership_loss_refuses_signals_and_retains_private_recovery_copy(self):
        runner, ui = self.prepared()
        self.fx.lose_host_ownership = True
        report = runner.execute(ui)
        self.assertEqual(report["status"], "failed")
        self.assertEqual(report["error"], "owned_host_required")
        self.assertEqual(report["cleanup"]["error"], "RESTORATION_NOT_PROVEN")
        self.assertFalse(report["cleanup"]["verified"])
        self.assertEqual(self.fx.calls, ["stop", "start"])
        self.assertEqual(policy.private_read(runner.guard.backup), self.original)
        self.assertEqual(report["cleanup"]["recovery_copy"], str(runner.guard.backup))

    def test_disconnected_report_must_be_stale_and_fresh_report_must_advance(self):
        runner, ui = self.prepared()
        baseline = ui.snapshot()
        self.fx.state["processes"][1]["stopped"] = True
        stale = ui.snapshot()
        policy.validate_report(stale, baseline, True, stale=True)
        ui.no_stale = True
        with self.assertRaisesRegex(policy.CheckFailed, "staleness"):
            policy.validate_report(ui.snapshot(), baseline, True, stale=True)
        self.fx.state["processes"][1]["stopped"] = False
        with self.assertRaisesRegex(policy.CheckFailed, "fresh_report"):
            policy.validate_report(baseline, baseline, True, fresh_after=stale)

    def test_central_and_document_changes_are_immediate_failures_with_cleanup(self):
        for attribute, expected in (("changed_central", "central_settings_changed"),
                                    ("changed_document", "browser_document_or_url_changed")):
            runner, ui = self.prepared()
            setattr(ui, attribute, True)
            report = runner.execute(ui)
            self.assertEqual(report["status"], "failed")
            # UI invariance is also required during restoration; do not claim cleanup verified.
            self.assertEqual(report["error"], expected)
            self.assertEqual(report["cleanup"]["error"], "RESTORATION_NOT_PROVEN")
            self.assertEqual(self.config.read_bytes(), self.original)
            self.assertFalse(self.fx.state["processes"][1].get("stopped"))
            runner.guard.backup.unlink()
            self.fx.starts = 0
            self.fx.calls.clear()

    def test_preflight_rejects_unowned_process_wrong_fixture_and_public_file(self):
        self.fx.unowned.add("gateway")
        with self.assertRaisesRegex(policy.CheckFailed, "owned_gateway_required"):
            self.prepared()
        self.assertEqual(self.fx.calls, [])
        self.fx.unowned.clear()
        self.fixture.chmod(0o644)
        with self.assertRaises(policy.CheckFailed):
            self.prepared()
        wrong = policy.Runner(self.config, self.state_dir, "case", effects=self.fx)
        with self.assertRaisesRegex(policy.CheckFailed, "oct20_a_fixture_only"):
            wrong.preflight()

    def test_yaml_report_allowlist_excludes_tokens_paths_and_unavailable_timestamps(self):
        payload = {"agent": {"host_id": "host", "token": "SECRET"}, "capture": {"enabled": True, "db_path": "/private"},
            "memory": {"enabled": True, "bound_scope": "scope", "host_sync_v2": {"enabled": True}},
            "local_settings_applied_at": "2026-10-20T01:00:00Z",
            "memory_negotiation": {"selected": "host_memory.v2", "applied_at": "2026-10-20T01:00:01Z"}}
        value = policy.report_values(payload, "2026-10-20T01:00:00Z Report received: 2026-10-20T01:00:02Z",
                                     "host_memory.v2 2026-10-20T01:00:01Z", "host")
        self.assertNotIn("SECRET", json.dumps(value))
        self.assertNotIn("/private", json.dumps(value))
        with self.assertRaises(policy.CheckFailed):
            policy.report_values(payload, "Unavailable", "Unavailable", "host")


if __name__ == "__main__":
    unittest.main()
