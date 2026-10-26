import importlib.util
import json
import os
import tempfile
import unittest
import urllib.error
import uuid
from pathlib import Path
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "memory_local_host_first.py"
spec = importlib.util.spec_from_file_location("local_host_first", SCRIPT)
driver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)
LOCAL, EVENT, CANONICAL = [str(uuid.uuid4()) for _ in range(3)]
REVISION = "a" * 64


class FakeEffects:
    def __init__(self, state):
        self.state, self.clock = state, 0
        self.calls, self.post_calls = [], []
        self.unowned = set()
        self.accepted = False
        self.captured = False
        self.cold = False
        self.settlement_delay = 0
        self.projection_delay = 0
        self.duplicate_memory = False
        self.wrong_event = False
        self.wrong_duplicate = False
        self.foreign_source = False
        self.fail_capture = False
        self.lose_ownership = False
        self.mutate_host = False
        self.premature_gateway = False
        self.fail_stop = False
        self.fail_host_start = False
        self.failed_replacement = False
        self.occupied_replacement = False
        self.owner_calls = []
        self.diagnostics_delay = 0
        self.stats_replies = []
        self.stats_bodies = []
        self.on_service = None

    def now(self):
        return self.clock

    def sleep(self, seconds):
        self.clock += seconds

    def revision(self):
        return "b" * 40

    def read_state(self, _state_dir):
        return self.state

    def owns(self, record):
        return record["name"] not in self.unowned

    def stopped_empty(self, _record):
        return not self.occupied_replacement

    def row(self, name):
        return next(row for row in self.state["processes"] if row["name"] == name)

    def ready(self, url):
        name = "host" if ":4222" in url else "gateway"
        return not self.row(name).get("stopped")

    def reachable(self, port):
        assert port in (4220, 4221)
        return self.premature_gateway or not self.row("gateway").get("stopped")

    def service(self, _state_dir, name, action, timeout):
        assert 0 < timeout <= 60
        self.calls.append((name, action))
        self.clock += 1
        row = self.row(name)
        if name == "host" and action == "start" and self.fail_host_start:
            self.fail_host_start = False
            raise RuntimeError("SECRET child readiness error")
        row["stopped"] = action == "stop"
        if action == "start":
            row["pid"] += 100
            row["pgid"] = row["pid"]
            row["birth"] += ":new"
            if name == "host":
                self.cold = True
                if self.failed_replacement:
                    self.failed_replacement = False
                    row["stopped"] = True
                    raise RuntimeError("SECRET readiness failed after child was stopped")
            elif self.mutate_host:
                self.row("host")["birth"] += ":foreign"
        if self.on_service:
            self.on_service(name, action)
        if name == "gateway" and action == "stop" and self.fail_stop:
            self.fail_stop = False
            raise RuntimeError("SECRET stop diagnostic")

    def post(self, _base, path, body, timeout):
        assert 0 < timeout <= 8
        self.post_calls.append(path)
        if path.endswith("/list"):
            rows = [{"id": CANONICAL, "content": body["q"] + ": Cold host durable command before gateway arrival."}]
            return 200, {"ok": True, "result": {"mode": "online", "results": rows if self.accepted else []}}
        if path.endswith("/stats"):
            self.stats_bodies.append(body)
            assert body == {}, "stats has an empty discovered argument schema"
            if self.stats_replies:
                reply = self.stats_replies.pop(0)
                if isinstance(reply, Exception):
                    raise reply
                return reply
            return 200, {"ok": True, "result": {"mode": "online"}}
        if path.endswith("/remember"):
            assert self.cold, "write must follow cold host start"
            duplicate = self.accepted
            self.accepted = True
            return 200, {"ok": True, "result": {
                "id": str(uuid.uuid4()) if duplicate and self.wrong_duplicate else LOCAL,
                "authority": "provisional", "consistency": "pending_canonical_ack", "sync_state": "pending"}}
        if path.endswith("/SessionStart"):
            assert self.accepted
            if self.fail_capture:
                if self.lose_ownership:
                    self.unowned.add("host")
                raise RuntimeError("SECRET provider token and child diagnostic")
            assert body["session_id"].startswith("memory-local-oct20-a-host-first-")
            assert body["source_event_id"] == body["session_id"] + ":SessionStart"
            duplicate = self.captured
            self.captured = True
            return 202, {"ok": True, "status": "duplicate" if duplicate else "accepted", "event_id": EVENT}
        raise AssertionError("unsupported fake request")

    def owner_snapshot(self, _base, request, timeout):
        assert request["command_ids"] == [LOCAL] and request["event_ids"] == [EVENT]
        assert not self.row("host").get("stopped")
        online = not self.row("gateway").get("stopped")
        self.owner_calls.append(online)
        assert online, "targeted diagnostics requires authenticated negotiation after gateway start"
        if self.diagnostics_delay:
            self.diagnostics_delay -= 1
            return None
        if online and self.settlement_delay:
            self.settlement_delay -= 1
            online = False
        return {"observation_source": "owner_connection", "commands": {
            "outbox": [{"memory_id": LOCAL, "op": "remember", "state": "done" if online else "retry_wait",
                "ack_canonical_id": CANONICAL if online else None, "ack_revision": 7 if online else None}],
            "memories": [{"id": LOCAL, "remote_id": CANONICAL if online else None,
                "sync_state": "synced" if online else "pending", "deleted": False}]},
            "capture": {"missing_or_compacted": 0, "rows": [{"event_id": EVENT,
                "state": "acknowledged" if online else "pending", "acknowledged": online}]}}

    def canonical(self, _runner, timeout):
        assert 0 < timeout <= 8
        if not self.accepted:
            return {"database": "backplane_dev", "memory_ids": [CANONICAL] if self.foreign_source else [],
                    "events": [], "sessions": [], "stages": [], "jobs": []}
        assert not self.row("gateway").get("stopped"), "no DB probe while gateway is down"
        project = self.projection_delay == 0
        self.projection_delay = max(0, self.projection_delay - 1)
        return {"database": "backplane_dev", "memory_ids": [CANONICAL] * (2 if self.duplicate_memory else 1),
            "events": [{"id": str(uuid.uuid4()) if self.wrong_event else EVENT,
                        "source_sequence": 1, "event_type": "agent.session.started"}],
            "sessions": [{"status": "active", "source_sequence_max": 1, "gap_count": 0, "input_revision": REVISION}],
            "stages": [{"status": "complete" if project else "running", "finished": project,
                        "input_revision": REVISION}],
            "jobs": [{"id": 321, "state": "completed" if project else "executing", "attempt": 1, "finished": project}]}


class HostFirstTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        self.root_patch = patch.object(driver, "ROOT", self.root)
        self.root_patch.start()
        self.fixture = self.root / ".devenv/memory-local-fixtures/oct20-a/fixture.json"
        self.config = self.fixture.parent / "primary/host.yaml"
        self.config.parent.mkdir(parents=True, mode=0o700)
        self.state_dir = self.root / ".devenv/memory-local"
        self.state_dir.mkdir(mode=0o700)
        host, space = str(uuid.uuid4()), str(uuid.uuid4())
        partition = {"host_id": host, "memory_space_id": space, "client_id": "host:" + host,
            "scope": "memory_local_oct20-a_primary", "namespace": "private"}
        self.config.write_text(f"agent:\n  host_id: {host}\n  token: SECRET\n  http_bind: 127.0.0.1\n"
            f"  http_port: 4222\n  hub_url: http://localhost:4220\nmemory:\n  enabled: true\n"
            f"  bound_scope: {partition['scope']}\n  db_path: {self.config.parent}/commands.db\n"
            f"  host_sync:\n    enabled: true\n    development_plaintext: true\n    db_path: {self.config.parent}/mirror.db\n"
            f"capture:\n  enabled: true\n  db_path: {self.config.parent}/capture-spool.db\n")
        self.config.chmod(0o600)
        for filename in ("commands.db", "capture-spool.db", "mirror.db"):
            path = self.config.parent / filename
            path.write_bytes(b"existing synthetic data")
            path.chmod(0o600)
        self.fixture.write_text(json.dumps({"run_id": "oct20-a", "hosts": [
            {"name": "memory-local-oct20-a-primary", "host_id": host, "partition": partition,
             "config": str(self.config)}, {}]}))
        self.fixture.chmod(0o600)
        state = {"config": str(self.config), "urls": driver.lifecycle.endpoints(), "processes": [
            {"name": name, "pid": pid, "pgid": pid, "birth": "kernel:" + str(pid), "uid": os.getuid()}
            for name, pid in (("gateway", 11), ("host", 12))]}
        state_file = self.state_dir / "state.json"
        state_file.write_text(json.dumps(state))
        state_file.chmod(0o600)
        self.fx = FakeEffects(state)
        self.runner = driver.Runner(self.fixture, self.state_dir, "test-001", effects=self.fx)
        self.original = {path: path.read_bytes() for path in self.config.parent.iterdir()}

    def tearDown(self):
        self.root_patch.stop()
        self.temp.cleanup()

    def run_driver(self):
        report = self.runner.run()
        self.assertNotIn("SECRET", json.dumps(report))
        for path, original in self.original.items():
            if not path.is_symlink():
                self.assertEqual(path.read_bytes(), original)
        return report

    def test_cold_order_automatic_join_exactly_once_and_cleanup(self):
        self.fx.settlement_delay, self.fx.projection_delay, self.fx.diagnostics_delay = 2, 2, 2
        report = self.run_driver()
        self.assertEqual(report["status"], "passed-cold-host-first-subset")
        self.assertEqual(self.fx.calls, [("gateway", "stop"), ("host", "stop"), ("host", "start"), ("gateway", "start")])
        self.assertEqual(report["settlement"]["event_id"], EVENT)
        self.assertEqual(report["settlement"]["completed_normal_styx_job_ids"], [321])
        self.assertTrue(report["cleanup"]["verified"])
        before = next(row for row in report["phases"] if row["phase"] == "durable_before_gateway")
        self.assertEqual(before["cold_host_identity"], self.runner.expected["host"])
        self.assertFalse(report["complete_L01_L18"])
        self.assertTrue(self.fx.owner_calls and all(self.fx.owner_calls))
        self.assertEqual(report["acceptance"]["provisional_id"], LOCAL)
        self.assertEqual(report["acceptance"]["event_id"], EVENT)
        self.assertEqual(before["owner_diagnostics"], "deferred_until_authenticated_negotiation")
        self.assertEqual(before["durability_evidence"], "successful_local_transaction_ack_and_duplicate_identity")
        saved = json.loads((self.runner.output / "report.json").read_text())
        self.assertEqual(saved["status"], report["status"])

    def test_existing_canonical_marker_stops_before_any_lifecycle(self):
        self.fx.foreign_source = True
        report = self.run_driver()
        self.assertEqual(report["failure"], "fresh_canonical_case_required")
        self.assertEqual(self.fx.calls, [])

    def test_reserved_case_rejected_before_lifecycle(self):
        (self.state_dir / "host-first-case-test-001.json").touch(mode=0o600)
        self.assertEqual(self.run_driver()["status"], "failed")
        self.assertEqual(self.fx.calls, [])

    def test_unowned_initial_stack_refused(self):
        self.fx.unowned.add("host")
        self.assertEqual(self.run_driver()["failure"], "service_ownership_lost")
        self.assertEqual(self.fx.calls, [])

    def test_failure_after_stop_restores_without_restarting_healthy_host(self):
        self.fx.fail_stop = True
        report = self.run_driver()
        self.assertEqual(report["status"], "failed")
        self.assertTrue(report["cleanup"]["verified"])
        self.assertEqual(self.fx.calls, [("gateway", "stop"), ("gateway", "start")])

    def test_capture_exception_is_sanitized_and_gateway_restored(self):
        self.fx.fail_capture = True
        report = self.run_driver()
        self.assertEqual(report["failure"], "host_first_operation_failed")
        self.assertTrue(report["cleanup"]["verified"])
        self.assertEqual(self.fx.calls.count(("host", "start")), 1)
        self.assertEqual(report["acceptance"]["provisional_id"], LOCAL)
        self.assertNotIn("event_id", report["acceptance"])
        saved = json.loads((self.runner.output / "report.json").read_text())
        self.assertEqual(saved["acceptance"]["provisional_id"], LOCAL)

    def test_cold_host_start_failure_restores_both_owned_services(self):
        self.fx.fail_host_start = True
        report = self.run_driver()
        self.assertEqual(report["status"], "failed")
        self.assertTrue(report["cleanup"]["verified"])
        self.assertTrue(all(not row.get("stopped") for row in self.fx.state["processes"]))

    def test_failed_start_replacement_can_be_restored_when_proven_empty(self):
        self.fx.failed_replacement = True
        report = self.run_driver()
        self.assertEqual(report["status"], "failed")
        self.assertTrue(report["cleanup"]["verified"])
        self.assertEqual(self.fx.calls.count(("host", "start")), 2)

    def test_failed_start_replacement_with_occupied_group_is_not_adopted(self):
        self.fx.failed_replacement = self.fx.occupied_replacement = True
        report = self.run_driver()
        self.assertEqual(report["status"], "failed")
        self.assertEqual(report["cleanup"]["failure"], "RESTORATION_NOT_PROVEN")
        self.assertEqual(self.fx.calls.count(("host", "start")), 1)

    def test_lost_ownership_refuses_all_cleanup_lifecycle_actions(self):
        self.fx.fail_capture = self.fx.lose_ownership = True
        report = self.run_driver()
        self.assertEqual(report["cleanup"]["failure"], "RESTORATION_NOT_PROVEN")
        self.assertNotIn(("gateway", "start"), self.fx.calls)

    def test_host_replacement_during_gateway_start_cannot_pass(self):
        self.fx.mutate_host = True
        report = self.run_driver()
        self.assertEqual(report["failure"], "service_identity_changed")
        self.assertEqual(report["cleanup"]["failure"], "RESTORATION_NOT_PROVEN")
        self.assertEqual(self.fx.calls.count(("host", "start")), 1)

    def test_wrong_canonical_event_is_not_a_success(self):
        self.fx.wrong_event = True
        report = self.run_driver()
        self.assertEqual(report["failure"], "canonical_exactly_once_required")
        self.assertTrue(report["cleanup"]["verified"])

    def test_duplicate_canonical_memory_is_not_a_success(self):
        self.fx.duplicate_memory = True
        self.assertEqual(self.run_driver()["failure"], "canonical_exactly_once_required")

    def test_wrong_offline_retry_identity_restores_stack(self):
        self.fx.wrong_duplicate = True
        report = self.run_driver()
        self.assertEqual(report["failure"], "offline_retry_identity_required")
        self.assertTrue(report["cleanup"]["verified"])
        self.assertEqual(report["acceptance"]["provisional_id"], LOCAL)
        self.assertEqual(report["acceptance"]["event_id"], EVENT)

    def test_restore_retries_only_startup_availability_until_online(self):
        self.fx.stats_replies = [
            (503, {"ok": False, "error": "canonical memory is unavailable"}),
            urllib.error.URLError(ConnectionRefusedError("SECRET transient refusal")),
            (200, {"ok": True, "result": {"mode": "offline"}}),
            (200, {"ok": True, "result": {"mode": "online"}})]
        report = self.run_driver()
        self.assertEqual(report["status"], "passed-cold-host-first-subset")
        self.assertTrue(report["cleanup"]["verified"])
        self.assertEqual(report["cleanup"]["readiness_retries"], 2)
        self.assertEqual(self.fx.stats_bodies, [{}, {}, {}, {}])

    def test_restoration_does_not_retry_invalid_arguments_or_permission_denial(self):
        for status, reason in ((400, "invalid_arguments"), (403, "partition_mismatch"),
                               (503, "local memory is not configured")):
            with self.subTest(status=status):
                self.fx.stats_replies = [(status, {"ok": False, "error": reason})]
                self.fx.stats_bodies.clear()
                self.runner.preflight()
                with self.assertRaisesRegex(driver.CheckFailed, "restored_host_http_success_required"):
                    self.runner.restore()
                self.assertEqual(self.fx.stats_bodies, [{}])
                # This fixture's failed restore does not change processes or data;
                # use a fresh reserved case for the next independent subcase.
                self.runner = driver.Runner(self.fixture, self.state_dir, "deny-" + str(status) + "-" + reason.replace("_", "-").replace(" ", "-"), effects=self.fx)

    def test_permanent_restore_failure_leaves_failed_result_without_retry(self):
        self.fx.stats_replies = [(403, {"ok": False, "error": "SECRET permanent denial"})]
        report = self.run_driver()
        self.assertEqual(report["failure"], "restored_host_http_success_required")
        self.assertEqual(report["cleanup"]["failure"], "RESTORATION_NOT_PROVEN")
        self.assertEqual(self.fx.stats_bodies, [{}])

    def test_restore_does_not_retry_non_refused_network_error(self):
        self.fx.stats_replies = [urllib.error.URLError("SECRET TLS or routing error")]
        report = self.run_driver()
        self.assertEqual(report["status"], "failed")
        self.assertEqual(report["cleanup"]["failure"], "RESTORATION_NOT_PROVEN")
        self.assertEqual(self.fx.stats_bodies, [{}])

    def test_effect_diagnostics_retries_only_exact_unavailable_response(self):
        effects = driver.Effects()
        with patch.object(effects, "post", return_value=(503, {"ok": False, "error": "diagnostics unavailable"})):
            self.assertIsNone(effects.owner_snapshot("http://127.0.0.1:4222", {}, 1))
        for status in (400, 403):
            with patch.object(effects, "post", return_value=(status, {"ok": False, "error": "SECRET denied"})):
                with self.assertRaisesRegex(driver.CheckFailed, "owner_diagnostics_unavailable"):
                    effects.owner_snapshot("http://127.0.0.1:4222", {}, 1)

    def test_gateway_appearing_early_refuses_mutation(self):
        self.fx.premature_gateway = True
        report = self.run_driver()
        self.assertEqual(report["failure"], "gateway_must_remain_unreachable")
        self.assertFalse(self.fx.accepted)
        self.assertTrue(report["cleanup"]["verified"])

    def test_configuration_edit_causes_safe_restoration_refusal(self):
        def external_edit(name, action):
            if (name, action) == ("gateway", "stop"):
                self.config.write_bytes(self.config.read_bytes() + b"# external\n")
        self.fx.on_service = external_edit
        report = self.runner.run()
        self.assertEqual(report["failure"], "external_config_edit_refused")
        self.assertEqual(report["cleanup"]["failure"], "RESTORATION_NOT_PROVEN")
        self.assertEqual(self.fx.calls, [("gateway", "stop")])

    def test_incomplete_projection_has_bounded_failure_and_healthy_cleanup(self):
        self.fx.projection_delay = 10000
        report = self.run_driver()
        self.assertEqual(report["status"], "failed")
        self.assertTrue(report["cleanup"]["verified"])
        self.assertLess(self.fx.clock, 430)

    def test_symlink_store_rejected_before_lifecycle(self):
        path = self.config.parent / "commands.db"
        target = self.root / "other.db"
        target.write_bytes(path.read_bytes())
        target.chmod(0o600)
        path.unlink()
        path.symlink_to(target)
        self.assertEqual(self.run_driver()["failure"], "private_regular_nonsymlink_file_required")
        self.assertEqual(self.fx.calls, [])

    def test_foreign_fixture_and_nonlocal_socket_refused(self):
        self.runner.socket = "db.example:5432"
        self.assertEqual(self.run_driver()["failure"], "local_postgres_socket_required")
        self.assertEqual(self.fx.calls, [])

    def test_sql_is_bounded_read_only_and_scopes_event_identity(self):
        sql = driver.canonical_sql()
        self.assertIn("BEGIN READ ONLY", sql)
        self.assertIn("SET LOCAL statement_timeout='4s'", sql)
        self.assertIn("session_id=:'session'", sql)
        self.assertIn("client_id=:'client_id'", sql)
        self.assertIn("ProjectionRepairWorker", sql)
        self.assertIn("LIMIT 2", sql)
        self.assertNotIn("DELETE", sql)
        self.assertNotIn("UPDATE", sql)
        self.assertNotIn("INSERT", sql)


if __name__ == "__main__":
    unittest.main()
