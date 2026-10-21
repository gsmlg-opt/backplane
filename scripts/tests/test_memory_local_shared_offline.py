"""Offline scenario boundaries, without relay, services, browser or database access."""
import importlib.util
import asyncio
import contextlib
import io
import json
from pathlib import Path
from types import SimpleNamespace
import tempfile
import time
import unittest
import warnings
from unittest.mock import AsyncMock, Mock, patch

SCRIPT = Path(__file__).resolve().parents[1] / "memory_local_shared_offline.py"
spec = importlib.util.spec_from_file_location("memory_local_shared_offline", SCRIPT)
driver = importlib.util.module_from_spec(spec) if SCRIPT.exists() else None
if driver:
    spec.loader.exec_module(driver)

ACCESS = "11111111-1111-4111-8111-111111111111"
CANONICAL = "22222222-2222-4222-8222-222222222222"
COMMAND = "33333333-3333-4333-8333-333333333333"


class OfflineTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(driver, "offline driver implementation is missing")

    def diagnostic(self, status="complete"):
        mirror = {"status": status}
        if status == "complete":
            mirror.update(partition={"applied_revision": 4, "active_generation": CANONICAL,
                "snapshot_id": None, "snapshot_revision": None, "sync_status": "ready"},
                active_target_ids=[CANONICAL])
        return {"observation_source": "authority_owner", "access": {
            "access_id": ACCESS, "authority_version": 3, "capabilities": ["deliver", "read"],
            "status": "active" if status != "closed" else "closed", "fence_reason": None,
            "offline_read_lease_seconds": 15, "lease_remaining_ms": 10000},
            "commands": {"counts": {}, "rows": []}, "mirror": mirror}

    def test_diagnostics_require_populated_current_mirror_and_exact_content_free_shape(self):
        policy = {"access_id": ACCESS, "version": 3, "capabilities": ["deliver", "read"], "lease": 15}
        good = self.diagnostic()
        self.assertEqual(driver.owner_diagnostic(good, policy, [], [CANONICAL], "complete"), good)
        for altered in ({**good, "content": "protected"},
                        {**good, "access": {**good["access"], "authority_version": 2}},
                        {**good, "mirror": {**good["mirror"], "active_target_ids": []}},
                        {**good, "mirror": {**good["mirror"], "content": "protected"}}):
            with self.subTest(altered=altered), self.assertRaises(driver.CheckFailed):
                driver.owner_diagnostic(altered, policy, [], [CANONICAL], "complete")

    def test_no_delivery_requires_owner_incomplete_without_active_ids(self):
        policy = {"access_id": ACCESS, "version": 3, "capabilities": ["read"], "lease": 0}
        diag = self.diagnostic("incomplete")
        diag["access"].update(capabilities=["read"], offline_read_lease_seconds=0, lease_remaining_ms=0)
        driver.owner_diagnostic(diag, policy, [], [CANONICAL], "incomplete")
        diag["mirror"]["active_target_ids"] = [CANONICAL]
        with self.assertRaises(driver.CheckFailed):
            driver.owner_diagnostic(diag, policy, [], [CANONICAL], "incomplete")

    def test_lease_bounds_use_send_response_window_and_never_allow_zero_or_late_success(self):
        result = {"mode": "offline", "stale": True, "source": "edge_mirror", "authority": "canonical",
                  "consistency": "bounded_stale", "hits": [{"id": CANONICAL}]}
        driver.lease_observation(102, 103, 100, 15, result, CANONICAL)
        for start, end, lease in ((102, 116, 15), (102, 103, 0), (104, 103, 15), (102, 103, True)):
            with self.subTest(lease=lease, end=end), self.assertRaises(driver.CheckFailed):
                driver.lease_observation(start, end, 100, lease, result, CANONICAL)
        with self.assertRaises(driver.CheckFailed):
            driver.lease_observation(102, 103, 100, 15, {**result, "mode": "online"}, CANONICAL)

    def test_expiry_denial_is_distinct_from_transport_validation_and_content(self):
        self.assertEqual(driver.offline_denial("direct", 400,
            {"ok": False, "error": "access_lease_expired"}, "protected"), "access_lease_expired")
        for reply, status in (({"ok": False, "error": "invalid_request"}, 400),
                              ({"ok": False, "error": "canonical memory is unavailable"}, 503),
                              ({"ok": False, "error": "access_lease_expired", "content": "protected"}, 400)):
            with self.subTest(reply=reply), self.assertRaises(driver.CheckFailed):
                driver.offline_denial("direct", status, reply, "protected")

    def test_cold_unavailable_requires_positive_owner_closed_proof(self):
        body = {"ok": False, "error": "canonical memory is unavailable"}
        with self.assertRaises(driver.CheckFailed):
            driver.offline_denial("direct", 503, body, "protected", cold=True)
        self.assertEqual(driver.offline_denial("direct", 503, body, "protected", cold=True,
            owner_closed=True), "transport_unavailable_with_owner_closed")

    def test_mcp_expiry_binds_request_identity_and_exact_error_text(self):
        body = {"jsonrpc": "2.0", "id": 7, "result": {"isError": True,
            "content": [{"type": "text", "text": "hub unreachable: access_lease_expired"}]}}
        self.assertEqual(driver.offline_denial("mcp", 200, body, "protected", 7), "access_lease_expired")
        with self.assertRaises(driver.CheckFailed):
            driver.offline_denial("mcp", 200, body, "protected", 8)

    def test_rejected_command_rows_cannot_be_done_new_version_or_contain_receipt_content(self):
        diag = self.diagnostic()
        row = {"command_id": COMMAND, "authority_version": 3, "state": "dead_letter",
               "ack_canonical_id": None, "ack_revision": None, "has_error": 1}
        diag["commands"]["rows"] = [row]
        driver.command_outcome(diag, COMMAND, 3, "dead_letter")
        for altered in ({**row, "state": "done"}, {**row, "authority_version": 4},
                        {**row, "ack_canonical_id": CANONICAL}, {**row, "content": "protected"}):
            diag["commands"]["rows"] = [altered]
            with self.subTest(altered=altered), self.assertRaises(driver.CheckFailed):
                driver.command_outcome(diag, COMMAND, 3, "dead_letter")

    def test_relay_control_rejects_wrong_ports_mode_active_connections_and_extra_data(self):
        good = {"mode": "offline", "connections": 0, "listen_port": 4224, "upstream_port": 4220}
        self.assertEqual(driver.control_state(good, "offline"), good)
        for bad in ({**good, "connections": 1}, {**good, "mode": "online"},
                    {**good, "upstream_port": 4221}, {**good, "token": "secret"}):
            with self.subTest(bad=bad), self.assertRaises(driver.CheckFailed):
                driver.control_state(bad, "offline")

    def test_control_cannot_run_before_ownership_preflight(self):
        run = object.__new__(driver.OfflineMatrix)
        run.control_armed = False
        with patch.object(driver.relay, "control_request") as request:
            with self.assertRaises(driver.CheckFailed):
                run.control("offline")
            request.assert_not_called()

    def cleanup_run(self):
        run = object.__new__(driver.OfflineMatrix)
        run.control_armed = True
        run.control = Mock()
        run.restore_host = Mock()
        run.a, run.b, run.admin = Mock(), Mock(), Mock()
        run.report, run.access = {}, {"version": 3, "reason": "owned"}
        run.admin.current.return_value = run.access.copy()
        run.mutation_attempted = True
        run.owned_contents = {"exact owned content"}
        run.owned_private = {"private": "private exact"}
        run.created_ids = {CANONICAL}
        run.exact_rows = Mock(return_value=[])
        run.wait_absent = Mock()
        run.marker = "MEMORY-LOCAL-run-SHARED-case"
        return run

    def test_cleanup_restores_transport_before_host_and_preserves_operator_policy(self):
        run = self.cleanup_run()
        order = []
        run.control.side_effect = lambda mode: order.append(mode)
        run.restore_host.side_effect = lambda: order.append("host")
        run.admin.current.return_value = {"version": 4, "reason": "operator"}
        with self.assertRaisesRegex(driver.CheckFailed, "cleanup_grant_version_changed"):
            run.cleanup()
        self.assertEqual(order, ["online", "host"])
        run.admin.save.assert_not_called()
        run.admin.revoke.assert_not_called()
        run.a.call.assert_not_called()

    def test_cleanup_deletes_only_exact_owned_ids_contents_and_retains_neighbor(self):
        run = self.cleanup_run()
        run.exact_rows.return_value = [{"id": CANONICAL, "content": "exact owned content"},
            {"id": "neighbor", "content": "exact owned content-neighbor"}]
        run.cleanup()
        self.assertEqual(run.a.call.call_args.args, ("direct", "forget", {"id": CANONICAL}))
        self.assertEqual(run.b.call.call_args.args, ("direct", "forget", {"id": "private"}))
        run.admin.save.assert_not_called()

    def test_diagnostic_rejects_numeric_booleans_duplicate_ids_and_partial_generation(self):
        policy = {"access_id": ACCESS, "version": 3, "capabilities": ["deliver", "read"], "lease": 15}
        for section, key, value in (("access", "authority_version", True),
                                    ("access", "lease_remaining_ms", True),
                                    ("access", "lease_remaining_ms", 15001),
                                    ("access", "capabilities", ["deliver", "read", "read"]),
                                    ("access", "fence_reason", "raw provider error"),
                                    ("mirror", "active_target_ids", [CANONICAL, CANONICAL])):
            bad = self.diagnostic()
            bad[section][key] = value
            with self.subTest(key=key), self.assertRaises(driver.CheckFailed):
                driver.owner_diagnostic(bad, policy, [], [CANONICAL], "complete")
        bad = self.diagnostic()
        bad["mirror"]["partition"]["snapshot_id"] = ACCESS
        with self.assertRaises(driver.CheckFailed):
            driver.owner_diagnostic(bad, policy, [], [CANONICAL], "complete")

    def test_lease_rejects_nonfinite_timing_boundary_and_provisional_identity(self):
        result = {"mode": "offline", "stale": True, "source": "edge_mirror", "authority": "canonical",
                  "consistency": "bounded_stale", "hits": [{"id": CANONICAL}]}
        for start, end, sent in ((102, 115, 100), (102, float("nan"), 100),
                                (102, 103, float("inf")), (True, 103, 100), (99, 103, 100)):
            with self.subTest(start=start, end=end), self.assertRaises(driver.CheckFailed):
                driver.lease_observation(start, end, sent, 15, result, CANONICAL)
        with self.assertRaises(driver.CheckFailed):
            driver.lease_observation(102, 103, 100, 15, {**result, "hits": [{"id": COMMAND}]}, CANONICAL)

    def test_rpc_denial_rejects_extra_fields_and_boolean_request_identity(self):
        error = {"jsonrpc": "2.0", "id": 1, "error": {"code": -32000, "message": "access_lease_expired"}}
        self.assertEqual(driver.offline_denial("mcp", 200, error, "protected", 1), "access_lease_expired")
        for bad in ({**error, "id": True}, {**error, "extra": "untrusted"},
                    {**error, "error": {**error["error"], "data": "untrusted"}},
                    {"jsonrpc": "2.0", "id": 1, "result": {"isError": True, "content": [
                        {"type": "text", "text": "access_lease_expired", "data": "untrusted"}]}}):
            with self.subTest(bad=bad), self.assertRaises(driver.CheckFailed):
                driver.offline_denial("mcp", 200, bad, "protected", 1)

    def test_command_outcome_requires_one_typed_exact_command(self):
        row = {"command_id": COMMAND, "authority_version": 3, "state": "dead_letter",
               "ack_canonical_id": None, "ack_revision": None, "has_error": 1}
        diag = self.diagnostic()
        for rows in ([row, row], [{**row, "authority_version": True}],
                     [{**row, "has_error": True}], [{**row, "state": []}], [{**row, "has_error": 0}]):
            diag["commands"]["rows"] = rows
            with self.subTest(rows=rows), self.assertRaises(driver.CheckFailed):
                driver.command_outcome(diag, COMMAND, 3, "dead_letter")

    def test_relay_preflight_and_control_bind_original_socket_identity(self):
        run = driver.OfflineMatrix()
        status = {"mode": "online", "connections": 1, "listen_port": 4224, "upstream_port": 4220}
        identity = (5, 42, driver.os.getuid())
        path = Path("/synthetic/private/control.sock")
        with patch.object(driver, "relay_request_sync") as request:
            with self.assertRaises(driver.CheckFailed):
                run.arm_control(path, identity, (5, 43, identity[2]), status)
            self.assertFalse(run.control_armed)
            request.assert_not_called()
            run.arm_control(path, identity, identity, status)
            with patch.object(driver.relay, "socket_identity", return_value=(5, 43, identity[2])):
                with self.assertRaisesRegex(driver.CheckFailed, "relay_ownership_changed"):
                    run.control("offline")
            request.assert_not_called()
            request.return_value = {**status, "mode": "offline", "connections": 0}
            with patch.object(driver.relay, "socket_identity", return_value=identity):
                self.assertEqual(run.control("offline"), request.return_value)
            request.assert_called_once_with(path, "offline")

    def test_cleanup_stops_before_mutations_when_owned_content_changes(self):
        run = self.cleanup_run()
        run.exact_rows.return_value = [{"id": CANONICAL, "content": "changed content"}]
        with self.assertRaisesRegex(driver.CheckFailed, "cleanup_record_ownership_lost"):
            run.cleanup()
        run.a.call.assert_not_called()
        run.b.call.assert_not_called()
        run.admin.revoke.assert_not_called()

    def test_relay_cli_failures_and_invalid_responses_never_change_reported_fault_state(self):
        run = driver.OfflineMatrix()
        run.control_armed = True
        run.control_path = Path("/synthetic/private/control.sock")
        run.control_identity = (5, 42, driver.os.getuid())
        run.report = {"fault_active": True}
        status = {"mode": "online", "connections": 1, "listen_port": 4224, "upstream_port": 4220}
        for result in (SimpleNamespace(returncode=1, stdout="secret error"),
                       SimpleNamespace(returncode=0, stdout="secret malformed"),
                       SimpleNamespace(returncode=0, stdout="x" * 1025),
                       SimpleNamespace(returncode=0, stdout="[]"),
                       SimpleNamespace(returncode=0, stdout=json.dumps({**status, "secret": "value"})),
                       SimpleNamespace(returncode=0, stdout=json.dumps({**status, "upstream_port": 4221})),
                       SimpleNamespace(returncode=0, stdout=json.dumps({**status, "mode": "offline"}))):
            with self.subTest(result=result), \
                 patch.object(driver.relay, "socket_identity", return_value=run.control_identity), \
                 patch.object(driver.relay, "control_parent", side_effect=lambda path: path), \
                 patch.object(driver.subprocess, "run", return_value=result):
                with self.assertRaises(driver.CheckFailed) as error:
                    run.control("online")
                self.assertNotIn("secret", str(error.exception))
                self.assertTrue(run.report["fault_active"])
        for failure in (OSError("secret path"), driver.subprocess.TimeoutExpired("secret command", 10)):
            with self.subTest(failure=type(failure).__name__), \
                 patch.object(driver.relay, "socket_identity", return_value=run.control_identity), \
                 patch.object(driver.relay, "control_parent", side_effect=lambda path: path), \
                 patch.object(driver.subprocess, "run", side_effect=failure):
                with self.assertRaisesRegex(driver.CheckFailed, "^relay_control_cli_failed$"):
                    run.control("online")
                self.assertTrue(run.report["fault_active"])

    def test_relay_socket_replacement_after_cli_does_not_claim_online_restore(self):
        run = driver.OfflineMatrix()
        run.control_armed = True
        run.control_path = Path("/synthetic/private/control.sock")
        run.control_identity = (5, 42, driver.os.getuid())
        run.report = {"fault_active": True}
        status = {"mode": "online", "connections": 1, "listen_port": 4224, "upstream_port": 4220}
        with patch.object(driver.relay, "socket_identity", side_effect=[run.control_identity, (5, 43, driver.os.getuid())]), \
             patch.object(driver, "relay_request_sync", return_value=status) as request:
            with self.assertRaisesRegex(driver.CheckFailed, "relay_ownership_changed"):
                run.control("online")
        request.assert_called_once_with(run.control_path, "online")
        self.assertTrue(run.report["fault_active"])

    def test_cleanup_absence_failure_does_not_revoke_or_report_success(self):
        run = self.cleanup_run()
        run.wait_absent.side_effect = driver.CheckFailed("owned_records_remain")
        with self.assertRaisesRegex(driver.CheckFailed, "owned_records_remain"):
            run.cleanup()
        run.admin.revoke.assert_not_called()
        self.assertNotIn("cleanup", run.report)


class ReadinessRecoveryTests(unittest.TestCase):
    def result(self, offline=False):
        return {"mode": "offline" if offline else "online", "stale": offline,
                "authority": "canonical", "source": "edge_mirror" if offline else "canonical",
                "consistency": "bounded_stale" if offline else "canonical", "pending_operations": 0,
                "items": [{"id": CANONICAL, "content": "do not retain this content"}]}

    def run_fixture(self):
        run = driver.OfflineMatrix()
        run.agent, run.marker, run.private_sentinel = "fixture", "fixture-marker", CANONICAL
        run.b, run.check_topology, run.save_report = Mock(), Mock(), Mock()
        run.report = {}
        run.deadline = time.monotonic() + 120
        run.hosts = [{}, {"partition": {"memory_space_id": ACCESS, "scope": "own-private",
                                     "namespace": "private"}}]
        return run

    def private_owner(self):
        return {"observation_source": "owner_connection", "commands": {"outbox": [], "memories": []},
                "capture": {"rows": [], "expected": 0, "missing_or_compacted": 0},
                "tombstones": {"count": 0, "digest": "0" * 64},
                "mirror": {"partition": {"applied_revision": 4, "active_generation": COMMAND,
                    "snapshot_id": None, "snapshot_revision": None, "sync_status": "ready"},
                    "active_target_ids": [CANONICAL]}}

    def test_restore_retries_offline_success_until_canonical_settled_private_list(self):
        run = self.run_fixture()
        run.b.post.side_effect = [(200, {"ok": True, "result": row}) for row in
            (self.result(True), {**self.result(), "pending_operations": 1,
                "authority": "canonical_with_provisional", "consistency": "read_your_writes"}, self.result())]
        with patch.object(driver.time, "sleep"):
            run.restore_host()
        self.assertEqual(run.b.post.call_count, 3)
        self.assertTrue(all(call.args[0].endswith("/call/list") for call in run.b.post.call_args_list))
        self.assertTrue(all("memory_access_id" not in call.args[1] for call in run.b.post.call_args_list))
        run.check_topology.assert_called()

    def test_restore_retries_canonical_id_only_mirror_until_online(self):
        run = self.run_fixture()
        offline = {**self.result(True), "items": [{"canonical_id": CANONICAL}]}
        run.b.post.side_effect = [(200, {"ok": True, "result": row})
                                 for row in (offline, self.result())]
        with patch.object(driver.time, "sleep"):
            run.restore_host()
        self.assertEqual(run.b.post.call_count, 2)
        self.assertEqual(run.report["restore_observations"][0]["ids"], [CANONICAL])

    def test_list_observations_accept_supported_identity_aliases_without_content(self):
        for row in ({"id": CANONICAL}, {"canonical_id": CANONICAL},
                    {"id": CANONICAL, "canonical_id": CANONICAL}):
            result = {**self.result(True), "items": [{**row, "content": "unretained-secret"}],
                      "results": [{"canonical_id": CANONICAL}]}
            with self.subTest(row=row):
                observation = driver.list_observation(result)
                self.assertTrue(observation["valid_ids"])
                self.assertEqual(observation["ids"], [CANONICAL])
                self.assertNotIn("unretained-secret", json.dumps(observation))

    def test_list_observations_reject_invalid_conflicting_duplicate_and_cross_array_ids(self):
        for row in ({}, {"canonical_id": "not-an-id-secret"}, {"id": None, "canonical_id": CANONICAL},
                    {"id": CANONICAL, "canonical_id": COMMAND},
                    {"id": CANONICAL, "canonical_id": False}, {"canonical_id": []}):
            with self.subTest(row=row):
                observation = driver.list_observation({**self.result(True), "items": [row]})
                self.assertFalse(observation["valid_ids"])
                self.assertEqual(observation["ids"], [])
                self.assertNotIn("not-an-id-secret", json.dumps(observation))
        for updates in ({"items": [{"id": CANONICAL}, {"canonical_id": CANONICAL}]},
                        {"results": [{"canonical_id": COMMAND}]},
                        {"results": [{"id": CANONICAL, "canonical_id": COMMAND}]}):
            with self.subTest(updates=updates):
                self.assertFalse(driver.list_observation({**self.result(True), **updates})["valid_ids"])

    def test_canonical_id_fallback_still_requires_only_the_exact_private_sentinel(self):
        for ids in ([CANONICAL], [CANONICAL, COMMAND]):
            run = self.run_fixture()
            result = {**self.result(True), "items": [{"canonical_id": value} for value in ids]}
            run.b.raw.side_effect = [(200, {"ok": True, "result": result}, 1),
                (200, {"jsonrpc": "2.0", "id": 2, "result": {"isError": False,
                    "content": [{"type": "text", "text": json.dumps(result)}]}}, 2)]
            if len(ids) == 1:
                run.private_fallback()
            else:
                with self.assertRaisesRegex(driver.CheckFailed, "private_omitted_selector_fallback_required"):
                    run.private_fallback()
            for observation in run.report["private_fallback_observations"]:
                self.assertTrue(observation["valid_ids"])
                self.assertEqual(observation["ids"], ids)

    def test_restore_offline_forever_times_out_without_claiming_recovery(self):
        run = self.run_fixture()
        run.deadline = 1000
        run.b.post.return_value = (200, {"ok": True, "result": self.result(True)})
        with patch.object(driver.time, "monotonic", side_effect=[0, 0, 30, 61]), \
             patch.object(driver.time, "sleep"):
            with self.assertRaisesRegex(driver.CheckFailed, "restored_host_not_connected"):
                run.restore_host()

    def test_restore_does_not_retry_permanent_malformed_or_lost_ownership(self):
        for status, body in [(400, {"ok": False, "error": "partition_not_ready"}),
                             (503, {"ok": False, "error": "unauthorized"}),
                             (200, {"ok": True, "result": {}})]:
            run = self.run_fixture()
            run.b.post.return_value = status, body
            with self.subTest(body=body), self.assertRaises(driver.CheckFailed):
                run.restore_host()
            self.assertEqual(run.b.post.call_count, 1)
        run = self.run_fixture()
        run.check_topology.side_effect = driver.CheckFailed("owned_stack_identity_changed")
        with self.assertRaisesRegex(driver.CheckFailed, "owned_stack_identity_changed"):
            run.restore_host()
        run.b.post.assert_not_called()

    def test_private_readiness_waits_for_requested_id_and_committed_generation(self):
        run = self.run_fixture()
        incomplete = self.private_owner()
        incomplete["mirror"]["active_target_ids"] = []
        snapshot = self.private_owner()
        snapshot["mirror"]["partition"]["snapshot_id"] = ACCESS
        snapshot["mirror"]["partition"]["snapshot_revision"] = 5
        run.b.post.side_effect = [(200, {"ok": True, "result": item})
                                for item in (incomplete, snapshot, self.private_owner())]
        with patch.object(driver.time, "sleep"):
            run.wait_private_mirror()
        self.assertEqual(run.b.post.call_count, 3)
        request = run.b.post.call_args.args[1]
        self.assertEqual(request, {"partition": run.hosts[1]["partition"], "command_ids": [],
                                  "event_ids": [], "mirror_ids": [CANONICAL]})

    def test_private_readiness_rejects_unrelated_ids_or_wrong_owner_shape(self):
        for altered in ({**self.private_owner(), "observation_source": "stopped_store"},
                        {**self.private_owner(), "mirror": {"partition": None, "active_target_ids": [COMMAND]}}):
            run = self.run_fixture()
            run.b.post.return_value = 200, {"ok": True, "result": altered}
            with self.subTest(altered=altered), self.assertRaises(driver.CheckFailed):
                run.wait_private_mirror()

    def test_fallback_observes_both_interfaces_before_rejecting_each_wrong_field(self):
        invalid = {"mode": "online", "stale": False, "authority": "provisional",
                   "source": "local", "consistency": "provisional_only", "pending_operations": 1,
                   "items": [{"id": COMMAND}]}
        for key, value in invalid.items():
            run = self.run_fixture()
            bad = {**self.result(True), key: value}
            run.b.raw.side_effect = [(200, {"ok": True, "result": bad}, 1),
                (200, {"jsonrpc": "2.0", "id": 2, "result": {"isError": False,
                    "content": [{"type": "text", "text": json.dumps(self.result(True))}]}}, 2)]
            with self.subTest(key=key), self.assertRaises(driver.CheckFailed):
                run.private_fallback()
            observed = run.report["private_fallback_observations"]
            self.assertEqual([row["interface"] for row in observed], ["direct", "mcp"])
            self.assertNotIn("do not retain", json.dumps(observed))
            self.assertTrue(observed[1]["rpc_identity_matches"])

    def test_fallback_retains_sanitized_rpc_id_mismatch_and_never_raw_content(self):
        run = self.run_fixture()
        run.b.raw.side_effect = [(200, {"ok": True, "result": self.result(True)}, 1),
            (200, {"jsonrpc": "2.0", "id": True, "result": {"isError": False,
                "content": [{"type": "text", "text": "secret malformed response"}]}}, 1)]
        with self.assertRaises(driver.CheckFailed):
            run.private_fallback()
        observed = run.report["private_fallback_observations"]
        self.assertFalse(observed[1]["rpc_identity_matches"])
        self.assertEqual(observed[1]["decode_failure"], "rpc_identity_mismatch")
        self.assertNotIn("secret", json.dumps(observed))


class RecallIdentityTests(unittest.TestCase):
    def run_fixture(self, arrays):
        run = driver.OfflineMatrix()
        run.report, run.save_report, run.b = {}, Mock(), Mock()
        run.marker, run.sentinel = "fixture", CANONICAL
        run.access = {"access_id": ACCESS}
        result = {"mode": "offline", "stale": True, "source": "edge_mirror", "authority": "canonical",
                  "consistency": "bounded_stale", "pending_operations": 0, **arrays}
        run.b.call.return_value = result
        return run, result

    def test_recall_and_lease_accept_identity_aliases_in_each_supported_array(self):
        for field in ("hits", "results", "items"):
            for row in ({"id": CANONICAL}, {"canonical_id": CANONICAL},
                        {"id": CANONICAL, "canonical_id": CANONICAL}):
                for interface in ("direct", "mcp"):
                    with self.subTest(field=field, row=row, interface=interface):
                        run, result = self.run_fixture({field: [{**row, "content": "secret-content"}]})
                        self.assertIs(run.read(interface)[2], result)
                        self.assertIs(driver.lease_observation(102, 103, 100, 15, result, CANONICAL), result)
                        observed = run.report["recall_observations"][0]
                        self.assertEqual(observed["interface"], interface)
                        self.assertEqual(observed["ids"], [CANONICAL])
                        self.assertEqual(observed["row_count"], 1)
                        self.assertTrue(observed["valid_ids"])
                        self.assertNotIn("secret-content", json.dumps(observed))

    def test_recall_and_lease_reject_malformed_duplicate_conflicting_and_disagreeing_rows(self):
        invalid = [{}, {"hits": None}, {"hits": []}, {"hits": "secret-rows"}]
        invalid += [{"hits": [row]} for row in (None, {}, {"canonical_id": False},
            {"canonical_id": "secret-id"}, {"id": None, "canonical_id": CANONICAL},
            {"id": CANONICAL, "canonical_id": COMMAND}, {"id": CANONICAL, "canonical_id": None},
            {"id": COMMAND})]
        invalid += [{"hits": [{"id": CANONICAL}, {"canonical_id": CANONICAL}]}]
        for field in ("results", "items"):
            invalid += [{"hits": [{"id": CANONICAL}], field: other}
                        for other in (None, [], [{"id": COMMAND}],
                                      [{"id": CANONICAL, "canonical_id": COMMAND}])]
        invalid += [{"results": [{"id": CANONICAL}], "items": [{"canonical_id": COMMAND}]},
                    {"hits": [{"id": CANONICAL}, {"id": COMMAND}],
                     "results": [{"id": COMMAND}, {"id": CANONICAL}]}]
        for arrays in invalid:
            with self.subTest(arrays=arrays):
                run, result = self.run_fixture(arrays)
                with self.assertRaisesRegex(driver.CheckFailed, "shared_recall_identity_required"):
                    run.read("direct")
                with self.assertRaisesRegex(driver.CheckFailed, "offline_canonical_identity_required"):
                    driver.lease_observation(102, 103, 100, 15, result, CANONICAL)
                self.assertEqual(len(run.report["recall_observations"]), 1)
                run.save_report.assert_called_once_with()
                self.assertNotIn("secret", json.dumps(run.report))

    def test_matching_arrays_accept_the_same_ids_and_recall_bound_remains_100(self):
        ids = [CANONICAL] + [str(driver.uuid.UUID(int=value)) for value in range(1, 100)]
        arrays = {"hits": [{"canonical_id": value} for value in ids],
                  "results": [{"id": value} for value in ids],
                  "items": [{"id": value, "canonical_id": value} for value in ids]}
        run, result = self.run_fixture(arrays)
        self.assertIs(run.read("direct")[2], result)
        driver.lease_observation(102, 103, 100, 15, result, CANONICAL)
        self.assertEqual(run.report["recall_observations"][0]["row_count"], 100)
        oversized = arrays["hits"] + [{"id": COMMAND}]
        run, result = self.run_fixture({"hits": oversized})
        with self.assertRaises(driver.CheckFailed):
            run.read("mcp")
        with self.assertRaises(driver.CheckFailed):
            driver.lease_observation(102, 103, 100, 15, result, CANONICAL)
        self.assertIsNone(run.report["recall_observations"][0]["row_count"])
        self.assertEqual(run.report["recall_observations"][0]["ids"], [])

    def test_failed_recall_observations_are_bounded_and_metadata_is_sanitized(self):
        run, result = self.run_fixture({"hits": [{"canonical_id": COMMAND, "content": "secret-content"}],
                                       "mode": "secret-mode", "pending_operations": "secret-count"})
        for _ in range(10):
            with self.assertRaises(driver.CheckFailed):
                run.read("direct")
        observations = run.report["recall_observations"]
        self.assertEqual(len(observations), 8)
        self.assertEqual(observations[-1]["ids"], [COMMAND])
        self.assertIsNone(observations[-1]["mode"])
        self.assertIsNone(observations[-1]["pending_operations"])
        self.assertNotIn("secret", json.dumps(observations))


class RunnerTests(unittest.TestCase):
    def bare_run(self):
        run = driver.OfflineMatrix()
        run.report = {"status": "failed", "checks": {}, "policies": [], "fault_active": False,
                      "complete_L13": False, "complete_L18": False}
        run.access = {"access_id": ACCESS, "version": 3, "capabilities": ["deliver", "read"], "lease": 15}
        run.marker, run.sentinel, run.agent = "MEMORY-LOCAL-run-SHARED-case", CANONICAL, "memory-local-run"
        run.queued, run.owned_contents, run.created_ids = [], set(), {CANONICAL}
        run.a, run.b, run.admin = Mock(), Mock(), Mock()
        run.deadline = time.monotonic() + 120
        run.args = SimpleNamespace(lease=15)
        run.checked = Mock()
        return run

    def test_failed_online_gate_precedes_topology_controls_and_mutations(self):
        run = self.bare_run()
        run.fixture = {"run_id": "run"}
        run.args = SimpleNamespace(lease=15,
            fixture=driver.online.ROOT / ".devenv/memory-local-fixtures/run/fixture-relay.json",
            online_report=Path("/synthetic/online-report.json"))
        records = [json.dumps(run.fixture).encode(), json.dumps({"status": "failed"}).encode()]
        with patch.object(driver.pending, "private_read", side_effect=records), \
             patch.object(driver.subprocess, "check_output", return_value="revision"), \
             patch.object(driver.lifecycle, "read_state") as state, \
             patch.object(driver.relay, "control_request", new_callable=AsyncMock) as request, \
             patch.object(driver.inventory, "snapshot") as snapshot:
            with self.assertRaisesRegex(driver.CheckFailed, "passing_current_online_matrix_required"):
                run.preflight()
            state.assert_not_called()
            request.assert_not_called()
            snapshot.assert_not_called()
        run.admin.save.assert_not_called()
        run.b.call.assert_not_called()

    def test_topology_refuses_changed_processes_before_lifecycle_actions(self):
        run = self.bare_run()
        run.files = {}
        state_dir = Path("/synthetic/primary")
        original = {"run_id": "original", "config": "/synthetic/a.yaml", "processes": [{"pid": 123}]}
        run.expected_states = {state_dir: original}
        run.hosts = [{"config": "/synthetic/a.yaml"}]
        with patch.object(driver.lifecycle, "read_state", return_value={**original, "processes": [{"pid": 124}]}), \
             patch.object(driver.lifecycle, "service") as service:
            with self.assertRaisesRegex(driver.CheckFailed, "owned_stack_identity_changed"):
                run.check_topology()
            service.assert_not_called()

    @contextlib.contextmanager
    def topology_probe(self, replies):
        run = self.bare_run()
        run.files, run.expected_states, run.hosts = {}, {}, []
        run.save_report = Mock()
        for index in range(2):
            config = f"/synthetic/{index}.yaml"
            urls = driver.lifecycle.endpoints(4222 + index)
            if index:
                urls = {"host": urls["host"]}
            run.hosts.append({"config": config})
            run.expected_states[Path(f"/synthetic/{index}")] = {
                "run_id": "original", "config": config, "urls": urls,
                "processes": [{"name": name, "pid": index * 10 + number}
                    for number, name in enumerate(("gateway", "host") if index == 0 else ("host",))]}
        clock = [0]
        run.deadline = 100
        with patch.object(driver.lifecycle, "read_state", side_effect=lambda path: run.expected_states[path]) as read, \
             patch.object(driver.lifecycle, "owns", return_value=True) as owns, \
             patch.object(driver.lifecycle, "status", side_effect=replies) as status, \
             patch.object(driver.time, "monotonic", side_effect=lambda: clock[0]), \
             patch.object(driver.time, "sleep", side_effect=lambda seconds: clock.__setitem__(0, clock[0] + seconds)) as sleep:
            yield run, read, owns, status, sleep, clock

    def test_topology_retries_transient_readiness_and_records_failed_endpoint(self):
        primary = {"public": True, "admin": False, "host": True}
        replies = [{"http_ready": primary}, {"http_ready": {"host": True}},
                   {"http_ready": {**primary, "admin": True}}, {"http_ready": {"host": True}}]
        with self.topology_probe(replies) as (run, read, owns, status, sleep, clock):
            run.check_topology()
            self.assertEqual(status.call_count, 4)
            sleep.assert_called_once_with(0.2)
            observed = run.report["topology_readiness_observations"]
            self.assertEqual(observed[0]["primary"], primary)
            self.assertEqual(observed[0]["secondary"], {"host": True})
            self.assertTrue(all(all(stack.values()) for stack in observed[-1].values()))
            self.assertEqual(run.report["last_topology_not_ready"], observed[0])
            self.assertGreaterEqual(read.call_count, 4)

    def test_topology_permanent_http_failure_obeys_poll_and_driver_deadlines(self):
        def reply(path):
            return {"http_ready": {"public": True, "admin": False, "host": True}
                    if path.name == "0" else {"host": True}}
        for deadline, expected_end in [(100, 30), (0.5, 0.5)]:
            with self.subTest(deadline=deadline), self.topology_probe(reply) as (run, read, owns, status, sleep, clock):
                run.deadline = deadline
                with self.assertRaisesRegex(driver.CheckFailed, "owned_stack_not_ready"):
                    run.check_topology()
                self.assertGreaterEqual(clock[0], expected_end)
                self.assertLess(clock[0], expected_end + 0.21)
                self.assertLessEqual(len(run.report["topology_readiness_observations"]), 8)
                self.assertFalse(run.report["last_topology_not_ready"]["primary"]["admin"])

    def test_topology_rechecks_ownership_files_and_config_before_retrying_http(self):
        codes = ["owned_stack_identity_changed", "owned_stack_required",
                 "fixture_file_identity_changed", "fixture_config_changed"]
        for code in codes:
            with self.subTest(code=code), self.topology_probe([
                    {"http_ready": {"public": True, "admin": False, "host": True}},
                    {"http_ready": {"host": True}}]) as (run, read, owns, status, sleep, clock):
                def change(_seconds):
                    if code == "owned_stack_identity_changed":
                        read.side_effect = lambda path: {**run.expected_states[path], "run_id": "changed"}
                    elif code == "owned_stack_required":
                        owns.return_value = False
                    else:
                        run.files = {Path("/synthetic/config"): (1, 2, "old-digest")}
                sleep.side_effect = change
                inode = 3 if code == "fixture_file_identity_changed" else 2
                with patch.object(driver.pending, "private_file", return_value=SimpleNamespace(st_dev=1, st_ino=inode)), \
                     patch.object(driver.pending, "private_read", return_value=b"changed-config"):
                    with self.assertRaisesRegex(driver.CheckFailed, code):
                        run.check_topology()
                self.assertEqual(status.call_count, 2)
                sleep.assert_called_once_with(0.2)

    def test_topology_readiness_observations_exclude_untrusted_status_fields(self):
        replies = [{"http_ready": {"public": True, "admin": "secret-value", "host": True,
                                    "secret-key": False}, "config": "secret-config"}]
        with self.topology_probe(replies) as (run, read, owns, status, sleep, clock):
            with self.assertRaisesRegex(driver.CheckFailed, "owned_stack_readiness_invalid"):
                run.check_topology()
            observed = run.report["topology_readiness_observations"]
            self.assertIsNone(observed[0]["primary"]["admin"])
            self.assertNotIn("secret", json.dumps(observed))
            sleep.assert_not_called()

    def test_queued_mutations_use_exact_target_version_and_stable_distinct_keys(self):
        run = self.bare_run()
        run.b.call.side_effect = [{"command_id": value, "status": "pending", "canonical_id": None,
            "revision": None, "authority": "provisional", "consistency": "pending_canonical_ack"}
            for value in (COMMAND, ACCESS)]
        run.queue_pair("withdrawn-intent")
        remember, forget = [call.args for call in run.b.call.call_args_list]
        self.assertEqual(remember[:2], ("direct", "remember"))
        self.assertEqual(forget[:2], ("mcp", "forget"))
        self.assertEqual(remember[2]["memory_access_id"], ACCESS)
        self.assertEqual(forget[2]["memory_access_id"], ACCESS)
        self.assertEqual(remember[2]["idempotency_key"], run.marker + ":withdrawn-intent:remember")
        self.assertEqual(forget[2]["idempotency_key"], run.marker + ":withdrawn-intent:forget")
        self.assertEqual(forget[2]["id"], CANONICAL)
        self.assertEqual([row["version"] for row in run.queued], [3, 3])

    def test_missing_or_wrong_version_owner_observation_cannot_become_success(self):
        run = self.bare_run()
        reply = OfflineTests().diagnostic()
        reply["access"]["authority_version"] = 4
        run.b.post.return_value = 200, {"ok": True, "result": reply}
        run.poll = lambda operation, code: operation()
        with self.assertRaisesRegex(driver.CheckFailed, "current_owner_authority_required"):
            run.wait_owner("complete")
        run.checked.assert_not_called()

    def test_successful_owner_evidence_is_validated_and_bounded(self):
        run = self.bare_run()
        reply = OfflineTests().diagnostic()
        run.b.post.return_value = 200, {"ok": True, "result": reply}
        run.poll = lambda operation, code: operation()
        self.assertEqual(run.wait_owner("complete"), reply)
        self.assertEqual(run.report["owner_observations"], [reply])
        for _ in range(15):
            run.wait_owner("complete")
        with self.assertRaisesRegex(driver.CheckFailed, "owner_observation_limit"):
            run.wait_owner("complete")
        self.assertEqual(len(run.report["owner_observations"]), 16)

    def test_regrant_rejects_done_command_instead_of_accepting_new_snapshot_alone(self):
        run = self.bare_run()
        run.queued = [{"command_id": COMMAND, "version": 2}]
        reply = OfflineTests().diagnostic()
        reply["commands"]["rows"] = [{"command_id": COMMAND, "authority_version": 2, "state": "done",
            "ack_canonical_id": CANONICAL, "ack_revision": 4, "has_error": 0}]
        run.b.post.return_value = 200, {"ok": True, "result": reply}
        run.poll = lambda operation, code: operation()
        with self.assertRaisesRegex(driver.CheckFailed, "exact_command_outcome_required"):
            run.wait_owner("complete", rejected=True)

    def test_work_failure_still_runs_bounded_cleanup_and_keeps_original_failure(self):
        run = self.bare_run()
        run.scenario_started = True
        run.run_matrix = Mock(side_effect=driver.CheckFailed("missing_mirror"))
        run.cleanup = Mock()
        with self.assertRaisesRegex(driver.CheckFailed, "missing_mirror"):
            run.run_and_cleanup()
        run.cleanup.assert_called_once_with()
        self.assertEqual(run.report["work_failure"], "missing_mirror")
        self.assertEqual(run.a.deadline, run.deadline)
        self.assertEqual(run.b.deadline, run.deadline)

    def test_cleanup_restores_relay_inside_running_event_loop_without_replacing_work_failure(self):
        run = self.bare_run()
        run.scenario_started, run.control_armed, run.mutation_attempted = True, True, False
        run.control_path = Path("/synthetic/private/control.sock")
        run.control_identity = (5, 42, driver.os.getuid())
        run.run_matrix = Mock(side_effect=driver.CheckFailed("missing_mirror"))
        run.restore_host, run.discover_private_rows, run.wait_absent = Mock(), Mock(), Mock()
        run.owned_private = {}
        run.exact_rows = Mock(return_value=[])
        status = {"mode": "online", "connections": 1, "listen_port": 4224, "upstream_port": 4220}
        process = SimpleNamespace(returncode=0, stdout=json.dumps(status))
        async def in_browser_loop():
            self.assertIsNotNone(asyncio.get_running_loop())
            with self.assertRaisesRegex(driver.CheckFailed, "missing_mirror"):
                run.run_and_cleanup()
        with patch.object(driver.relay, "socket_identity", return_value=run.control_identity), \
             patch.object(driver.relay, "control_parent", side_effect=lambda path: path), \
             patch.object(driver.relay, "control_request", new_callable=AsyncMock) as async_request, \
             patch.object(driver.subprocess, "run", return_value=process) as command, \
             warnings.catch_warnings(record=True) as emitted:
            warnings.simplefilter("always")
            asyncio.run(in_browser_loop())
        async_request.assert_not_called()
        command.assert_called_once()
        self.assertEqual(command.call_args.args[0][:2],
                         [driver.sys.executable, str(Path(driver.relay.__file__).resolve())])
        self.assertEqual(command.call_args.args[0][2:], ["online", "--control", str(run.control_path)])
        self.assertGreater(command.call_args.kwargs["timeout"], 0)
        self.assertLessEqual(command.call_args.kwargs["timeout"], 10)
        self.assertFalse(emitted)
        run.restore_host.assert_called_once_with()
        self.assertEqual(run.report["work_failure"], "missing_mirror")
        self.assertEqual(run.report["cleanup"]["status"], "passed")
        self.assertFalse(run.report["fault_active"])

    def test_failure_codes_allow_only_explicit_fixed_code_classes(self):
        self.assertEqual(driver.OfflineMatrix.failure_code(
            driver.pending.CheckFailed("private_regular_nonsymlink_file_required")),
            "private_regular_nonsymlink_file_required")
        self.assertEqual(driver.OfflineMatrix.failure_code(RuntimeError("secret value")), "RuntimeError")

    def test_cleanup_failure_is_retained_separately_from_work_failure(self):
        run = self.bare_run()
        run.scenario_started = True
        run.run_matrix = Mock(side_effect=driver.CheckFailed("missing_mirror"))
        run.cleanup = Mock(side_effect=driver.CheckFailed("relay_ownership_changed"))
        with self.assertRaisesRegex(driver.CheckFailed, "relay_ownership_changed"):
            run.run_and_cleanup()
        self.assertEqual(run.report["work_failure"], "missing_mirror")
        self.assertEqual(run.report["cleanup"], {"status": "failed", "failure": "relay_ownership_changed"})

    def test_declared_scenario_orders_disconnection_before_withdrawal_revoke_and_restart(self):
        run = self.bare_run()
        events, phase = [], ["start"]
        run.seed = lambda: events.append("seed")
        def policy(caps, name, lease=0, observe=True):
            events.append(name)
            phase[0] = name
            run.access = {**run.access, "version": run.access["version"] + 1,
                          "capabilities": sorted(caps), "lease": lease}
        run.policy = policy
        run.control = lambda mode: events.append(mode)
        run.deny_read = lambda interface, code, **opts: events.append(("denial", code, opts.get("cold", False)))
        run.read = lambda interface: (100, 101, {"mode": "online", "stale": False})
        run.private_fallback = lambda: events.append("private-fallback")
        run.wait_private_mirror = lambda: events.append("private-mirror-ready")
        run.queue_pair = lambda name: events.append(name)
        run.wait_owner = lambda status, **opts: events.append(("owner", status, opts.get("rejected", False)))
        run.canonical_unchanged = lambda: events.append("canonical-unchanged")
        def revoke(name):
            events.append(name)
            run.access = {**run.access, "version": run.access["version"] + 1}
        run.revoke = revoke
        run.restart_host = lambda: events.append("restart")
        run.diagnostic = lambda policy, status: events.append(("diagnostic", status))
        def raw(interface, operation, arguments):
            if interface == "direct":
                return 400, {"ok": False, "error": "invalid_request"}, 1
            return 200, {"jsonrpc": "2.0", "id": 1, "result": {"isError": True,
                "content": [{"type": "text", "text": "invalid_request"}]}}, 1
        run.b.raw.side_effect = raw
        ticks = iter(range(0, 1000, 20))
        with patch.object(driver.time, "monotonic", side_effect=lambda: next(ticks)), \
             patch.object(driver.time, "sleep") as sleep, \
             patch.object(driver, "lease_observation") as lease:
            run.run_matrix()
        self.assertEqual(run.report["status"], "passed-subset")
        self.assertFalse(run.report["complete_L13"])
        self.assertFalse(run.report["complete_L18"])
        self.assertLess(events.index("withdrawn-intent"), events.index("withdraw-mutations"))
        self.assertEqual(events[events.index("withdrawn-intent") - 1], "private-fallback")
        self.assertLess(events.index("revoked-intent"), events.index("disconnected-revoke"))
        self.assertLess(events.index("disconnected-revoke"), events.index("restart"))
        self.assertLess(events.index("restart"), events.index("newer-regrant"))
        self.assertEqual(events[events.index("newer-regrant") + 1], "online")
        self.assertEqual(lease.call_count, 2)
        window = next(call.kwargs for call in run.checked.call_args_list
                      if call.args == ("bounded_stale_lease",))
        self.assertEqual(window["lease_seconds"], 15)
        self.assertEqual([row["interface"] for row in window["windows"]], ["direct", "mcp"])
        self.assertTrue(all(row["read_finished_monotonic"] < row["deadline_monotonic"]
                            for row in window["windows"]))
        self.assertEqual(events.count(("owner", "complete", True)), 2)
        sleep.assert_not_called()

    def test_execute_reports_block_and_closes_report_without_claiming_preservation(self):
        run = self.bare_run()
        run.output, run.report_fd = Path("/synthetic/evidence"), 37
        run.preflight = Mock(side_effect=driver.CheckFailed("passing_current_online_matrix_required"))
        run.with_browser, run.save_report = Mock(), Mock()
        with patch.object(driver.os, "close") as close, patch.object(driver.inventory, "snapshot") as snapshot:
            self.assertEqual(run.execute(), run.output / "report.json")
            close.assert_called_once_with(37)
            snapshot.assert_not_called()
        run.with_browser.assert_not_called()
        self.assertEqual(run.report["status"], "failed")
        self.assertEqual(run.report["failure"], "passing_current_online_matrix_required")
        self.assertNotIn("preservation", run.report)

    def test_cli_requires_explicit_topology_and_returns_failure_without_invoking_real_runner(self):
        args = ["--fixture", "/private/fixture.json", "--case-id", "case", "--control", "/private/control.sock",
            "--primary-state", "/private/a", "--secondary-state", "/private/b", "--online-report", "/private/online.json",
            "--socket", "/tmp/devenv-test/postgres", "--output", "/private/evidence"]
        fake = Mock(report={"status": "failed"})
        fake.execute.return_value = Path("/private/evidence/report.json")
        with patch.object(driver, "OfflineMatrix", return_value=fake) as constructor, \
             contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(driver.main(args), 1)
        fake.execute.assert_called_once_with()
        self.assertEqual(constructor.call_args.args[0].secondary_state, Path("/private/b"))
        self.assertEqual(output.getvalue().strip(), "/private/evidence/report.json")


if __name__ == "__main__":
    unittest.main()
