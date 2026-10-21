import contextlib
import importlib.util
import json
import sqlite3
import tempfile
import unittest
import urllib.error
import uuid
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "memory_local_pending_restart.py"
spec = importlib.util.spec_from_file_location("pending_restart", SCRIPT)
pending = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pending)

LOCAL, EVENT, CANONICAL, SURVIVOR, GENERATION = [str(uuid.uuid4()) for _ in range(5)]


class FakeEffects:
    def __init__(self, state):
        self.state = state
        self.clock = 0
        self.calls = []
        self.starts = 0
        self.attempts = 0
        self.duplicate_id = LOCAL
        self.tombstone_count = 0
        self.on_stop = None
        self.empty_mirror = False
        self.unowned = set()
        self.advance_mirror = False
        self.offline_restoration_reads = 0
        self.capture_attempts = 0
        self.duplicate_event_id = EVENT
        self.restoration_replies = []
        self.restoration_calls = 0
        self.observation_sources = []

    def now(self):
        return self.clock

    def sleep(self, seconds):
        self.clock += seconds

    def read_state(self, state_dir):
        return self.state

    def owns(self, record):
        return record["name"] not in self.unowned

    def host_service(self, state_dir, action, timeout):
        self.calls.append(action)
        self.clock += 1
        host = next(row for row in self.state["processes"] if row["name"] == "host")
        host["stopped"] = action == "stop"
        if action == "start":
            self.starts += 1
            host["birth"] = str(self.starts)
        elif self.on_stop:
            self.on_stop()

    def post(self, base, path, body, timeout):
        if path.endswith("remember"):
            value = LOCAL if self.calls.count("start") == 1 else self.duplicate_id
            return 200, {"ok": True, "result": {"id": value, "sync_state": "pending",
                        "authority": "provisional", "consistency": "pending_canonical_ack"}}
        if path.endswith("SessionStart"):
            return 202, {"ok": True, "event_id": EVENT if self.starts == 1 else self.duplicate_event_id,
                         "status": "accepted" if self.calls.count("start") == 1 else "duplicate"}
        baseline = body["q"].startswith("MEMORY-LOCAL-")
        if baseline and self.starts >= 3:
            self.restoration_calls += 1
            if self.restoration_replies:
                reply = self.restoration_replies.pop(0)
                if isinstance(reply, Exception):
                    raise reply
                return reply
        if baseline and self.starts >= 3 and self.offline_restoration_reads:
            self.offline_restoration_reads -= 1
            return 200, {"ok": True, "result": {"mode": "offline", "results": []}}
        return 200, {"ok": True, "result": {"mode": "online", "results": [
            {"id": SURVIVOR if baseline else CANONICAL,
             "content": "baseline" if baseline else body["q"] + " durable pending command"}]}}

    def owner_snapshot(self, base, request, timeout):
        self.observation_sources.append("owner_connection")
        assert not self.state["processes"][1].get("stopped"), "owner read while stopped"
        return {"observation_source": "owner_connection",
                "commands": self.probe("commands", request, timeout),
                "capture": self.probe("capture", request, timeout),
                "mirror": self.probe("mirror", request, timeout),
                "tombstones": self.tombstones(None, None, timeout)}

    def probe(self, operation, request, timeout):
        normal = self.starts >= 3
        if operation == "commands":
            return {"outbox": [{"seq": 41, "op": "remember", "memory_id": LOCAL,
                     "state": "done" if normal else "pending", "attempts": self.attempts,
                     "ack_canonical_id": CANONICAL if normal else None,
                     "ack_revision": 8 if normal else None}],
                    "memories": [{"id": LOCAL, "remote_id": CANONICAL if normal else None,
                     "sync_state": "synced" if normal else "pending", "deleted": False,
                     "content_hash": "synthetic"}], "tombstones": 0}
        if operation == "capture":
            return {"rows": [{"event_id": EVENT, "state": "acknowledged" if normal else "pending",
                              "attempts": self.capture_attempts, "acknowledged": normal}], "missing_or_compacted": 0}
        return {"partition": {"active_generation": GENERATION, "applied_revision": 7 + int(self.advance_mirror and self.starts > 0),
                 "snapshot_id": None, "snapshot_revision": 7, "sync_status": "live"},
                "active_target_ids": [] if self.empty_mirror else [SURVIVOR]}

    def tombstones(self, path, scope, timeout):
        return {"count": self.tombstone_count, "digest": "synthetic"}

    def canonical(self, runner, timeout):
        return {"memory_ids": [CANONICAL], "event_ids": [EVENT]} if self.starts else {"memory_ids": [], "event_ids": []}


class PendingRestartTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        self.state_dir = self.root / "state"
        self.state_dir.mkdir(mode=0o700)
        hosts = []
        for suffix in ("primary", "isolated"):
            folder = self.root / suffix
            folder.mkdir(mode=0o700)
            host_id, space_id = str(uuid.uuid4()), str(uuid.uuid4())
            config = folder / "host.yaml"
            config.write_text(f"agent:\n  host_id: {host_id}\n  hub_url: http://localhost:4220\n"
                              f"  http_bind: 127.0.0.1\n  http_port: 4222\n  interval_ms: 5000\n"
                              f"memory:\n  enabled: true\n  db_path: {folder}/commands.db\n"
                              f"  bound_scope: memory_local_test_{suffix}\n  sync_interval_ms: 1000\n"
                              f"  host_sync_v2:\n    enabled: true\n    db_path: {folder}/mirror.db\n"
                              "    sync_interval_ms: 1000\ncapture:\n  enabled: true\n"
                              f"  db_path: {folder}/capture-spool.db\n  upload_interval_ms: 1000\n")
            config.chmod(0o600)
            hosts.append({"name": "memory-local-test-" + suffix, "host_id": host_id,
                          "config": str(config), "partition": {"host_id": host_id,
                          "client_id": "host:" + host_id, "memory_space_id": space_id,
                          "scope": "memory_local_test_" + suffix, "namespace": "private"}})
            for filename in ("commands.db", "capture-spool.db", "mirror.db"):
                path = folder / filename
                path.write_bytes(b"synthetic")
                path.chmod(0o600)
        self.fixture = self.root / "fixture.json"
        self.fixture.write_text(json.dumps({"run_id": "test", "hosts": hosts}))
        self.fixture.chmod(0o600)
        self.config = Path(hosts[0]["config"])
        self.original = self.config.read_bytes()
        state = {"config": str(self.config), "urls": {
                 "public": "http://127.0.0.1:4220/", "admin": "http://127.0.0.1:4221/",
                 "host": "http://127.0.0.1:4222/"}, "processes": [
                 {"name": "gateway", "birth": "unchanged", "pid": 11},
                 {"name": "host", "birth": "original", "pid": 12}]}
        (self.state_dir / "state.json").write_text(json.dumps(state))
        (self.state_dir / "state.json").chmod(0o600)
        self.effects = FakeEffects(state)

    def tearDown(self):
        self.temp.cleanup()

    def runner(self):
        return pending.Runner(self.fixture, self.state_dir, "case", effects=self.effects,
                              output=self.root / "output")

    def test_exact_two_scalar_patch_preserves_nested_and_other_bytes(self):
        held = pending.delayed_config(self.original)
        self.assertEqual(held, self.original.replace(b"  sync_interval_ms: 1000\n", b"  sync_interval_ms: 600000\n", 1)
                         .replace(b"  upload_interval_ms: 1000\n", b"  upload_interval_ms: 600000\n", 1))
        self.assertIn(b"    sync_interval_ms: 1000\n", held)
        with self.assertRaises(pending.CheckFailed):
            pending.delayed_config(self.original.replace(b"  upload_interval_ms: 1000", b"  other: 1000"))

    def test_complete_subset_restores_exact_bytes_and_only_operates_host(self):
        runner = self.runner()
        report = runner.run()
        self.assertEqual(report["status"], "passed-pending-restart-subset")
        self.assertEqual(self.config.read_bytes(), self.original)
        self.assertEqual(self.effects.calls, ["stop", "start", "stop", "start", "stop", "start"])
        self.assertFalse(report["tombstone_survival_proven"])
        self.assertFalse(report["complete_L11_L12_L18"])
        self.assertFalse(runner.backup.exists())

    def test_live_snapshots_use_owner_connection_and_stopped_reads_are_distinct(self):
        probe = self.effects.probe
        tombstones = self.effects.tombstones
        in_owner = [False]
        owner = self.effects.owner_snapshot
        def owner_snapshot(base, request, timeout):
            in_owner[0] = True
            try:
                return owner(base, request, timeout)
            finally:
                in_owner[0] = False
        def stopped_only(operation, request, timeout):
            if not in_owner[0]:
                self.assertTrue(self.effects.state["processes"][1].get("stopped"))
            return probe(operation, request, timeout)
        def tombstones_stopped_only(path, scope, timeout):
            if not in_owner[0]:
                self.assertTrue(self.effects.state["processes"][1].get("stopped"))
            return tombstones(path, scope, timeout)
        self.effects.owner_snapshot = owner_snapshot
        self.effects.probe = stopped_only
        self.effects.tombstones = tombstones_stopped_only
        report = self.runner().run()
        self.assertEqual(report["status"], "passed-pending-restart-subset")
        sources = {row["phase"]: row.get("observation_source") for row in report["phases"]}
        self.assertEqual(sources["before_stop"], "owner_connection")
        self.assertEqual(sources["while_host_down"], "stopped_store")
        self.assertEqual(sources["after_delayed_restart"], "owner_connection")
        self.assertGreaterEqual(len(self.effects.observation_sources), 5)

    def test_pending_assertion_failure_retains_safe_acceptance_receipts(self):
        self.effects.attempts = 1
        report = self.runner().run()
        phases = report["phases"]
        direct = next(row for row in phases if row["phase"] == "direct_receipt" and row["method"] == "remember")
        capture = next(row for row in phases if row["phase"] == "capture_receipt")
        self.assertEqual(direct["receipt"]["result"]["id"], LOCAL)
        self.assertEqual(capture["receipt"]["event_id"], EVENT)
        self.assertNotIn("durable pending command", json.dumps(report))
        self.assertNotIn("content_hash", json.dumps(report))

    def test_owner_unavailable_refuses_before_config_or_lifecycle_mutation(self):
        def unavailable(*args):
            raise pending.CheckFailed("owner_diagnostics_unavailable")
        self.effects.owner_snapshot = unavailable
        report = self.runner().run()
        self.assertEqual(report["failure"], "owner_diagnostics_unavailable")
        self.assertEqual(self.effects.calls, [])
        self.assertEqual(self.config.read_bytes(), self.original)

    def test_owner_snapshot_provenance_is_required(self):
        owner = self.effects.owner_snapshot
        def wrong_source(*args):
            return {**owner(*args), "observation_source": "stopped_store"}
        self.effects.owner_snapshot = wrong_source
        report = self.runner().run()
        self.assertEqual(report["failure"], "owner_diagnostics_shape_required")
        self.assertEqual(self.effects.calls, [])

    def test_positive_existing_tombstones_are_proven(self):
        self.effects.tombstone_count = 2
        self.assertTrue(self.runner().run()["tombstone_survival_proven"])

    def test_normal_mirror_cursor_advance_preserves_membership(self):
        self.effects.advance_mirror = True
        self.assertEqual(self.runner().run()["status"], "passed-pending-restart-subset")

    def test_unowned_services_refuse_lifecycle_before_mutation(self):
        for service in ("gateway", "host"):
            with self.subTest(service=service):
                self.effects.unowned = {service}
                report = self.runner().run()
                self.assertEqual(report["failure"], "owned_" + service + "_required")
                self.assertEqual(self.effects.calls, [])
                self.assertEqual(self.config.read_bytes(), self.original)

    def test_recorded_config_mismatch_refuses_lifecycle(self):
        self.effects.state["config"] = str(self.config.with_name("different.yaml"))
        self.assertEqual(self.runner().run()["failure"], "fixture_lifecycle_mismatch")
        self.assertEqual(self.effects.calls, [])

    def test_fixture_scope_mismatch_refuses_lifecycle(self):
        fixture = json.loads(self.fixture.read_text())
        fixture["hosts"][0]["partition"]["scope"] = "foreign"
        self.fixture.write_text(json.dumps(fixture))
        self.assertEqual(self.runner().run()["failure"], "fixture_partition_not_owned")
        self.assertEqual(self.effects.calls, [])

    def test_gateway_identity_change_refuses_further_lifecycle_and_retains_backup(self):
        def changed_gateway():
            self.effects.state["processes"][0]["birth"] = "replacement"
        self.effects.on_stop = changed_gateway
        runner = self.runner()
        report = runner.run()
        self.assertEqual(report["failure"], "gateway_identity_changed")
        self.assertEqual(self.effects.calls, ["stop"])
        self.assertFalse(report["cleanup"]["verified"])
        self.assertEqual(runner.backup.read_bytes(), self.original)
        self.assertEqual(self.config.read_bytes(), self.original)

    def test_restoration_waits_for_online_channel_and_preserved_survivors(self):
        self.effects.offline_restoration_reads = 2
        report = self.runner().run()
        self.assertEqual(report["status"], "passed-pending-restart-subset")
        self.assertEqual(self.effects.offline_restoration_reads, 0)

    def test_restoration_retries_initial_http_503_then_proves_online(self):
        self.effects.restoration_replies = [urllib.error.HTTPError("http://localhost/", 503, "private response", {}, None)]
        report = self.runner().run()
        self.assertEqual(report["status"], "passed-pending-restart-subset")
        self.assertEqual(self.effects.restoration_calls, 2)
        self.assertNotIn("private response", json.dumps(report))

    def test_restoration_retries_connection_refused_then_proves_online(self):
        self.effects.restoration_replies = [urllib.error.URLError(ConnectionRefusedError("private transport"))]
        report = self.runner().run()
        self.assertEqual(report["status"], "passed-pending-restart-subset")
        self.assertEqual(self.effects.restoration_calls, 2)
        self.assertNotIn("private transport", json.dumps(report))

    def test_restoration_retries_returned_503_then_proves_online(self):
        self.effects.restoration_replies = [(503, {"ok": False})]
        self.assertEqual(self.runner().run()["status"], "passed-pending-restart-subset")
        self.assertEqual(self.effects.restoration_calls, 2)

    def test_permanent_startup_http_failures_are_not_retried(self):
        for status in (400, 401, 403):
            for raised in (False, True):
                with self.subTest(status=status, raised=raised):
                    runner = self.runner()
                    runner.host_url, runner.run_id, runner.scope = "http://localhost:4222", "test", "memory_local_test_primary"
                    self.effects.starts = 3
                    self.effects.restoration_calls = 0
                    self.effects.restoration_replies = [
                        urllib.error.HTTPError("http://localhost/", status, "private error", {}, None)
                        if raised else (status, {"ok": False})]
                    with self.assertRaisesRegex(pending.CheckFailed, "restored_host_http_success_required"):
                        runner.restoration_listing()
                    self.assertEqual(self.effects.restoration_calls, 1)
                    self.assertEqual(self.effects.clock, 0)

    def test_normal_direct_requests_do_not_retry_startup_failures(self):
        runner = self.runner()
        runner.host_url, runner.agent, runner.scope = "http://localhost:4222", "agent", "scope"
        self.effects.starts = 3
        self.effects.restoration_replies = [(503, {"ok": False})]
        with self.assertRaisesRegex(pending.CheckFailed, "direct_http_success_required"):
            runner.direct("list", {"q": "MEMORY-LOCAL-test"})
        self.assertEqual(self.effects.restoration_calls, 1)

    def test_permanent_startup_failure_cannot_pass_after_healthy_cleanup(self):
        self.effects.restoration_replies = [(403, {"ok": False})]
        report = self.runner().run()
        self.assertEqual(report["status"], "failed")
        self.assertEqual(report["failure"], "restored_host_http_success_required")
        self.assertTrue(report["cleanup"]["verified"])

    def test_persistent_startup_503_stops_at_cleanup_deadline(self):
        post = self.effects.post
        def unavailable(base, path, body, timeout):
            if self.effects.starts >= 3 and body.get("q", "").startswith("MEMORY-LOCAL-"):
                return 503, {"ok": False}
            return post(base, path, body, timeout)
        self.effects.post = unavailable
        report = self.runner().run()
        self.assertEqual(report["status"], "failed")
        self.assertEqual(report["failure"], "scenario_deadline_exceeded")
        self.assertFalse(report["cleanup"]["verified"])
        self.assertEqual(report["elapsed_ms"], 300000)
        self.assertEqual(self.config.read_bytes(), self.original)

    def test_main_deadline_reserves_time_for_host_and_exact_config_cleanup(self):
        probe = self.effects.probe
        def expire_main(operation, request, timeout):
            result = probe(operation, request, timeout)
            if operation == "capture" and self.effects.starts > 0:
                self.effects.clock = 211
            return result
        self.effects.probe = expire_main
        report = self.runner().run()
        self.assertEqual(report["failure"], "scenario_deadline_exceeded")
        self.assertTrue(report["cleanup"]["verified"])
        self.assertLess(report["elapsed_ms"], 300000)
        self.assertEqual(self.config.read_bytes(), self.original)

    def test_tombstones_subprocess_reads_only_scoped_existing_rows(self):
        path = self.root / "tombstones.db"
        with contextlib.closing(sqlite3.connect(path)) as db, db:
            db.execute("CREATE TABLE tombstones(scope TEXT, content_hash TEXT)")
            db.executemany("INSERT INTO tombstones VALUES (?, ?)", [("ours", "a"), ("ours", "b"), ("other", "c")])
        before = path.read_bytes()
        result = pending.Effects().tombstones(path, "ours", 3)
        self.assertEqual(result["count"], 2)
        self.assertEqual(len(result["digest"]), 64)
        self.assertEqual(path.read_bytes(), before)

    def test_capture_pending_attempts_zero_required(self):
        self.effects.capture_attempts = 1
        report = self.runner().run()
        self.assertEqual(report["failure"], "capture_pending_attempts_zero_required")
        self.assertTrue(report["cleanup"]["verified"])

    def test_capture_duplicate_must_retain_identity(self):
        self.effects.duplicate_event_id = str(uuid.uuid4())
        report = self.runner().run()
        self.assertEqual(report["failure"], "capture_duplicate_identity")
        self.assertTrue(report["cleanup"]["verified"])

    def test_populated_mirror_required_before_mutation(self):
        self.effects.empty_mirror = True
        report = self.runner().run()
        self.assertEqual(report["failure"], "populated_existing_mirror_required")
        self.assertEqual(self.effects.calls, [])
        self.assertEqual(self.config.read_bytes(), self.original)

    def test_actual_pending_attempts_zero_required_and_failure_recovers(self):
        self.effects.attempts = 1
        report = self.runner().run()
        self.assertEqual(report["status"], "failed")
        self.assertEqual(report["failure"], "command_pending_attempts_zero_required")
        self.assertTrue(report["cleanup"]["verified"])
        self.assertEqual(self.config.read_bytes(), self.original)
        self.assertEqual(self.effects.calls, ["stop", "start", "stop", "start"])

    def test_duplicate_identity_mismatch_fails_and_recovers(self):
        self.effects.duplicate_id = str(uuid.uuid4())
        report = self.runner().run()
        self.assertEqual(report["failure"], "command_duplicate_identity")
        self.assertTrue(report["cleanup"]["verified"])

    def test_external_config_edit_is_never_overwritten(self):
        def external_edit():
            if self.effects.starts == 1:
                self.config.write_bytes(b"external concurrent edit\n")
        self.effects.on_stop = external_edit
        runner = self.runner()
        report = runner.run()
        self.assertEqual(report["status"], "failed")
        self.assertFalse(report["cleanup"]["verified"])
        self.assertEqual(self.config.read_bytes(), b"external concurrent edit\n")
        self.assertEqual(runner.backup.read_bytes(), self.original)

    def test_symlink_input_rejected_before_mutation(self):
        original = self.config.with_suffix(".real")
        self.config.rename(original)
        self.config.symlink_to(original)
        self.assertEqual(self.runner().run()["status"], "failed")
        self.assertEqual(self.effects.calls, [])

    def test_delayed_host_window_and_global_deadline_are_bounded(self):
        runner = self.runner()
        runner.started = 0
        runner.held_started = 0
        self.effects.clock = 120
        with self.assertRaisesRegex(pending.CheckFailed, "delayed_host_window_exceeded"):
            runner.remaining()
        runner.held_started = None
        self.effects.clock = 300
        with self.assertRaisesRegex(pending.CheckFailed, "scenario_deadline_exceeded"):
            runner.remaining(cleanup=True)


if __name__ == "__main__":
    unittest.main()
