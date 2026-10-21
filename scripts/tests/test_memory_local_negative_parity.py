"""Pure/fake negative-parity safety checks; no local services are contacted."""

import copy
import importlib.util
import json
import os
import tempfile
import unittest
import uuid
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "memory_local_negative_parity.py"
spec = importlib.util.spec_from_file_location("negative_parity", SCRIPT)
driver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)
LOCAL, CANONICAL, EXISTING, HOST, SPACE = (str(uuid.UUID(int=i)) for i in range(501, 506))


class FakeEffects:
    def __init__(self):
        self.clock, self.calls = 0, []
        self.created, self.deleted, self.forgets = False, False, []
        self.alive, self.acked, self.cleanup_acked = True, True, True
        self.change = lambda interface, method, args, status, reply: (status, reply)
        self.lose_create_reply = False
        self.replacement_content = None
        self.known_unknown_available = False

    def now(self):
        return self.clock

    def sleep(self, seconds):
        self.clock += seconds

    def revision(self):
        return "c7044093f0aedcb97434a0c0caba03b864c99bb3"

    def owns(self, row):
        return self.alive and row["uid"] == os.getuid()

    def post(self, base, path, body, timeout):
        self.calls.append((path, copy.deepcopy(body), timeout))
        if path == "/memory/diagnostics":
            outbox = [{"op": "remember", "memory_id": LOCAL, "state": "done" if self.acked else "inflight",
                       "ack_canonical_id": CANONICAL, "ack_revision": 1}]
            if self.deleted:
                outbox.append({"op": "forget", "memory_id": LOCAL,
                               "state": "done" if self.cleanup_acked else "inflight",
                               "ack_canonical_id": CANONICAL, "ack_revision": 2})
            return 200, {"ok": True, "result": {"observation_source": "owner_connection", "commands": {
                "outbox": outbox, "memories": [{"id": LOCAL, "remote_id": CANONICAL, "deleted": self.deleted}]}}}
        interface = "mcp" if path.endswith("/mcp") else "direct"
        if interface == "mcp" and body["method"] == "tools/list":
            return 200, {"jsonrpc": "2.0", "id": body["id"], "result": {"tools": []}}
        method = body["params"]["name"].split("::")[1] if interface == "mcp" else path.rsplit("/", 1)[1]
        args = body["params"]["arguments"] if interface == "mcp" else body
        error, status, result = None, 200, None
        if not isinstance(args, dict):
            error = "Invalid params for tools/call" if interface == "mcp" else "content is required"
        elif method == driver.UNKNOWN:
            error = ("unknown method: " + method if interface == "direct" else
                     "hub unreachable: Unknown tool: memory::" + method + ". Use tools/list to see available tools."
                     if self.known_unknown_available else "hub unreachable: unauthorized")
        elif method == "remember":
            if not isinstance(args.get("content"), str):
                error = "content is required"
            elif args.get("type") not in ("semantic", "procedural", "working", "episodic"):
                error = "unsupported memory type"
            elif (not isinstance(args.get("facets", []), list) or any(not isinstance(row.get("value"), str) for row in args.get("facets", []))):
                error = "facets must contain dimension and value strings"
            elif not isinstance(args.get("idempotency_key"), str):
                error = "idempotency_key must be a nonempty string"
            elif self.created and args != self.arguments:
                error = "idempotency_conflict"
            else:
                self.created, self.arguments = True, copy.deepcopy(args)
                result = {"id": LOCAL, "canonical_id": CANONICAL, "sync_state": "synced",
                          "authority": "canonical", "consistency": "canonical", "revision": 1}
                if self.lose_create_reply:
                    self.lose_create_reply = False
                    raise OSError("SECRET raw failure")
        elif method == "list":
            rows = [{"id": EXISTING, "content": "MEMORY-LOCAL-fixture existing unrelated",
                     "scope": "memory_local_fixture_primary", "memory_type": "semantic"}]
            if self.created and not self.deleted:
                rows.append({"id": CANONICAL, "content": self.replacement_content or self.arguments["content"], "scope": self.arguments["scope"],
                             "memory_type": "semantic"})
            rows = [row for row in rows if args.get("q", "") in row["content"]]
            result = {"mode": "online", "stale": False, "authority": "canonical", "consistency": "canonical",
                      "pending_operations": 0, "overlay_truncated": False, "items": rows}
        elif method == "forget":
            self.deleted = True
            self.forgets.append(args["id"])
            result = {"id": CANONICAL, "canonical_id": CANONICAL, "sync_state": "synced", "revision": 2,
                      "authority": "canonical", "consistency": "canonical"}
        else:
            raise AssertionError(method)
        if interface == "direct":
            status = (404 if method == driver.UNKNOWN else 400) if error else 200
            reply = {"ok": False, "error": error} if error else {"ok": True, "result": result}
        else:
            reply = {"jsonrpc": "2.0", "id": body["id"]}
            if error and method == driver.UNKNOWN:
                reply["result"] = {"isError": True, "content": [{"type": "text", "text": error}]}
            elif error:
                reply["error"] = {"code": -32602 if not isinstance(args, dict) else -32000, "message": error}
            else:
                reply["result"] = {"isError": False, "content": [{"type": "text", "text": json.dumps(result)}]}
        return self.change(interface, method, args, status, reply)


class NegativeParityTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.fixture = self.root / "fixture.json"
        (self.root / "primary").mkdir(mode=0o700)
        self.config = self.root / "primary/host.yaml"
        self.config.write_text("private token never read by this probe\n")
        self.config.chmod(0o600)
        self.partition = {"memory_space_id": SPACE, "host_id": HOST, "client_id": "host:" + HOST,
                          "scope": "memory_local_fixture_primary", "namespace": "private"}
        self.fixture.write_text(json.dumps({"run_id": "fixture", "hosts": [{"host_id": HOST,
            "name": "memory-local-fixture-primary", "partition": self.partition, "config": str(self.config)}]}))
        self.fixture.chmod(0o600)
        self.state_dir = self.root / "state"
        self.state_dir.mkdir(mode=0o700)
        self.state_file = self.state_dir / "state.json"
        self.state = {"owner": driver.lifecycle.OWNER, "root": str(driver.ROOT), "uid": os.getuid(),
                      "config": str(self.config), "urls": driver.lifecycle.endpoints(), "processes": [
                          {"name": name, "pid": 510 + i, "pgid": 510 + i, "birth": "fake-birth", "uid": os.getuid()}
                          for i, name in enumerate(("gateway", "host"))]}
        self.save_state()
        self.fx = FakeEffects()
        self.output = self.root / "report.json"

    def save_state(self):
        self.state_file.write_text(json.dumps(self.state))
        self.state_file.chmod(0o600)

    def run_driver(self, **options):
        self.runner = driver.Runner(self.fixture, "case-50", state_dir=self.state_dir,
                                    effects=self.fx, output=self.output, **options)
        return self.runner.run()

    def test_success_checks_eight_pairs_owner_settlement_and_cleans_only_owned_record(self):
        # A hypothetical dispatcher that can report the actual unknown tool;
        # the default fake preserves today's scope-before-dispatch denial.
        self.fx.known_unknown_available = True
        report = self.run_driver()
        self.assertEqual(report["status"], "passed-negative-parity-subset", report)
        self.assertEqual(report["paired_negative_cases_passed"], 8)
        self.assertFalse(report["complete_L02"])
        self.assertFalse(report["complete_L01_L18"])
        self.assertEqual(report["cleanup"], {"status": "passed", "only_owned_marker_forgotten": True, "owner_forget_ack": True})
        self.assertTrue(self.fx.forgets)
        self.assertEqual(set(self.fx.forgets), {CANONICAL})
        self.assertEqual(os.stat(self.output).st_mode & 0o777, 0o600)
        self.assertTrue(all(0 < timeout <= 20 for _, _, timeout in self.fx.calls))
        self.assertNotIn("Synthetic original", self.output.read_text())
        self.assertNotIn("private token", self.output.read_text())

    def test_source_accurate_unknown_scope_denial_stays_failed_and_conflict_is_still_checked(self):
        report = self.run_driver()
        self.assertEqual(report["status"], "failed")
        self.assertEqual(report["error"], "paired_negative_parity_failed")
        pairs = [row for row in report["observations"] if row["phase"] == "paired_error"]
        unknown = next(row for row in pairs if row["case"] == "unknown_operation")
        self.assertFalse(unknown["parity"])
        self.assertEqual(unknown["direct"]["meaning"], "unknown_operation")
        self.assertEqual(unknown["mcp"]["meaning"], "permission_denied")
        self.assertEqual(unknown["failure"], "paired_error_meaning_mismatch")
        self.assertTrue(next(row for row in pairs if row["case"] == "same_key_different_content")["parity"])
        self.assertEqual(report["paired_negative_cases_checked"], 8)
        self.assertEqual(report["paired_negative_cases_passed"], 7)
        self.assertEqual(report["cleanup"]["status"], "passed")
        self.assertNotIn("hub unreachable", self.output.read_text())

    def test_unrecognized_errors_keep_only_fixed_envelope_metadata(self):
        raw = {"jsonrpc": "2.0", "id": 7, "result": {"isError": True, "content": [
            {"type": "text", "text": "SECRET bearer error"}]}}
        safe = driver.error_shape(raw)
        self.assertEqual(safe, {"object": True, "has_rpc_error": False, "has_result": True,
                                "tool_error": True, "content_count": 1, "message_is_string": True,
                                "message_length": 19})
        self.assertNotIn("SECRET", json.dumps(safe))

    def test_invalid_error_codes_or_success_cannot_be_promoted_to_parity(self):
        def change(interface, method, args, status, reply):
            if interface == "mcp" and method == "remember" and args.get("content") == 42:
                reply = {"jsonrpc": "2.0", "id": reply["id"], "result": {"isError": False, "content": []}}
            return status, reply
        self.fx.change = lambda i, m, a, s, r: change(i, m, a, s, r) if isinstance(a, dict) else (s, r)
        report = self.run_driver()
        self.assertEqual(report["error"], "mcp_tool_error_required")
        self.assertEqual(report["status"], "failed")
        self.assertEqual(report["cleanup"]["status"], "passed")

    def test_generic_transport_failure_is_not_unknown_operation(self):
        def change(interface, method, args, status, reply):
            if interface == "mcp" and method == driver.UNKNOWN:
                reply["result"]["content"][0]["text"] = "hub unreachable: not_connected SECRET"
            return status, reply
        self.fx.change = change
        report = self.run_driver()
        self.assertEqual(report["error"], "unrecognized_error_meaning")
        self.assertEqual(report["cleanup"]["status"], "passed")
        self.assertNotIn("SECRET", self.output.read_text())

    def test_conflict_error_does_not_hide_replacement(self):
        def change(interface, method, args, status, reply):
            if (method == "remember" and isinstance(args, dict) and isinstance(args.get("content"), str)
                    and args["content"].endswith("use unbounded workers.")):
                self.fx.replacement_content = args["content"]
            return status, reply
        self.fx.change = change
        report = self.run_driver()
        self.assertEqual(report["status"], "failed")
        self.assertEqual(report["error"], "unique_owned_record_required")
        self.assertEqual(report["cleanup"]["status"], "failed")
        self.assertEqual(self.fx.forgets, [])

    def test_lost_initial_response_retries_exact_key_and_cleans_owned_record(self):
        self.fx.lose_create_reply = True
        report = self.run_driver()
        self.assertEqual(report["error"], "http_transport_failed")
        self.assertEqual(report["cleanup"]["status"], "passed")
        self.assertEqual(set(self.fx.forgets), {CANONICAL})
        self.assertNotIn("SECRET", self.output.read_text())

    def test_owner_ack_required_even_when_lists_show_canonical(self):
        self.fx.acked = False
        report = self.run_driver(timeout=12, cleanup_timeout=4)
        self.assertEqual(report["status"], "failed")
        self.assertEqual(report["error"], "work_deadline")
        self.assertNotIn("paired_negative_cases_passed", report)
        self.assertEqual(report["cleanup"]["status"], "passed")

    def test_cleanup_requires_owner_forget_ack_and_reports_timeout(self):
        self.fx.cleanup_acked = False
        report = self.run_driver(timeout=12, cleanup_timeout=4)
        self.assertEqual(report["status"], "failed")
        self.assertEqual(report["cleanup"]["error"], "cleanup_deadline")
        self.assertTrue(report["cleanup"]["retained_marker_requires_inspection"])
        self.assertLessEqual(report["elapsed_seconds"], 12)

    def test_state_ownership_refuses_before_any_request(self):
        self.state["owner"] = "someone-else"
        self.save_state()
        report = self.run_driver()
        self.assertEqual(report["error"], "owned_fixture_state_required")
        self.assertEqual(self.fx.calls, [])

    def test_fixture_partition_refuses_before_any_request(self):
        data = json.loads(self.fixture.read_text())
        data["hosts"][0]["partition"]["scope"] = "global"
        self.fixture.write_text(json.dumps(data))
        self.assertEqual(self.run_driver()["error"], "fixture_partition_required")
        self.assertEqual(self.fx.calls, [])

    def test_unsafe_loopback_refuses_before_any_request(self):
        report = self.run_driver(host_url="http://example.com:4222")
        self.assertEqual(report["error"], "fixture_loopback_endpoint_required")
        self.assertEqual(self.fx.calls, [])

    def test_private_state_and_config_required(self):
        self.state_file.chmod(0o644)
        self.assertEqual(self.run_driver()["error"], "private_input_required")
        self.assertEqual(self.fx.calls, [])
        self.output.unlink()
        self.state_file.chmod(0o600)
        self.config.chmod(0o644)
        self.assertEqual(self.run_driver()["error"], "private_fixture_config_required")
        self.assertEqual(self.fx.calls, [])

    def test_ownership_loss_prevents_cleanup_mutation(self):
        def change(interface, method, args, status, reply):
            if method == driver.UNKNOWN:
                self.fx.alive = False
            return status, reply
        self.fx.change = change
        report = self.run_driver()
        self.assertEqual(report["status"], "failed")
        self.assertEqual(report["cleanup"]["error"], "owned_running_process_required")
        self.assertEqual(self.fx.forgets, [])

    def test_paired_meanings_and_parameter_details_must_match(self):
        direct = {"meaning": "invalid_arguments", "detail": "content_required"}
        other = {"meaning": "unknown_operation", "detail": "unknown_operation"}
        with self.assertRaisesRegex(driver.CheckFailed, "paired_error_meaning_mismatch"):
            driver.paired_errors(direct, other, "invalid_arguments", ("content_required", "invalid_argument_shape"))
        with self.assertRaisesRegex(driver.CheckFailed, "paired_error_detail_mismatch"):
            driver.paired_errors(direct, direct, "invalid_arguments", ("content_required", "invalid_argument_shape"))

    def test_wrong_rpc_id_and_code_are_rejected(self):
        reply = {"jsonrpc": "2.0", "id": 9, "error": {"code": -32000, "message": "idempotency_conflict"}}
        with self.assertRaisesRegex(driver.CheckFailed, "mcp_error_envelope_required"):
            driver.error_meaning("mcp", 200, reply, 8)
        reply["error"]["code"] = -32603
        with self.assertRaisesRegex(driver.CheckFailed, "unexpected_rpc_error_code"):
            driver.error_meaning("mcp", 200, reply, 9)


if __name__ == "__main__":
    unittest.main()
