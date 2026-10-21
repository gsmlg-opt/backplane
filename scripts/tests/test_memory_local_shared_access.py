"""Shared acceptance response contracts; no services or database mutations."""

import importlib.util
import json
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import Mock


SCRIPT = Path(__file__).resolve().parents[1] / "memory_local_shared_access.py"
spec = importlib.util.spec_from_file_location("memory_local_shared_access", SCRIPT)
driver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)


class ResponseTests(unittest.TestCase):
    @staticmethod
    def receipt():
        return {"command_id": "11111111-1111-4111-8111-111111111111", "status": "committed",
                "canonical_id": "22222222-2222-4222-8222-222222222222", "revision": 1,
                "authority": "canonical", "consistency": "canonical"}

    @staticmethod
    def policy():
        return {"access_id": "fixture", "version": 2, "status": "active",
                "capabilities": ["read"], "lease": 0, "reason": "owned"}

    def test_direct_and_mcp_success_return_structured_payload(self):
        result = {"memories": [{"id": "fixture"}]}
        self.assertEqual(driver.decode_reply("direct", 200, {"ok": True, "result": result}), result)
        reply = {"jsonrpc": "2.0", "id": 7, "result": {
            "isError": False, "content": [{"type": "text", "text": json.dumps(result)}]}}
        self.assertEqual(driver.decode_reply("mcp", 200, reply, 7), result)

    def test_only_permanent_denial_counts_as_authorization_evidence(self):
        for status, message in ((503, "not_connected"), (504, "timeout"), (400, "invalid_request")):
            with self.subTest(message=message), self.assertRaises(driver.CheckFailed):
                driver.assert_denied("direct", status, {"ok": False, "error": message}, "protected")
        self.assertEqual(driver.assert_denied("direct", 403,
                         {"ok": False, "error": "unauthorized"}, "protected"), "unauthorized")

    def test_mcp_denial_binds_request_and_tool_error_shape(self):
        reply = {"jsonrpc": "2.0", "id": 3, "result": {
            "isError": True, "content": [{"type": "text", "text": "hub unreachable: unauthorized"}]}}
        self.assertEqual(driver.assert_denied("mcp", 200, reply, "protected", 3), "unauthorized")
        with self.assertRaises(driver.CheckFailed):
            driver.assert_denied("mcp", 200, reply, "protected", 4)

    def test_denial_cannot_hide_protected_content_or_success(self):
        for reply in ({"ok": False, "error": "unauthorized", "result": {}},
                      {"ok": False, "error": "unauthorized", "content": "another private record"},
                      {"ok": False, "error": "unauthorized", "detail": "protected"}):
            with self.subTest(reply=reply), self.assertRaises(driver.CheckFailed):
                driver.assert_denied("direct", 403, reply, "protected")

    def test_ambiguous_mcp_content_is_rejected(self):
        reply = {"jsonrpc": "2.0", "id": 1, "result": {"isError": False,
                 "content": [{"type": "text", "text": "{}"}, {"type": "text", "text": "{}"}]}}
        with self.assertRaises(driver.CheckFailed):
            driver.decode_reply("mcp", 200, reply, 1)

    def test_access_rows_require_exact_recipient_and_unique_identity(self):
        rows = [["Host B\nhost-b", "access-b", "active", "read", "0s", "2", "reason", "Edit"]]
        self.assertEqual(driver.access_row(rows, "host-b")["version"], 2)
        with self.assertRaises(driver.CheckFailed):
            driver.access_row(rows, "host")
        with self.assertRaises(driver.CheckFailed):
            driver.access_row(rows + rows, "host-b")

    def test_unchanged_policy_preserves_authority_version_without_fabricated_audit(self):
        run = object.__new__(driver.OnlineMatrix)
        run.access = {"access_id": "fixture", "version": 2, "status": "active", "capabilities": ["read"], "lease": 0}
        run.admin = Mock()
        run.admin.current.return_value = run.access.copy()
        run.report = {"policies": []}
        run.policy(["read"], "same-policy")
        run.admin.save.assert_not_called()
        self.assertTrue(run.report["policies"][0]["unchanged"])
        self.assertEqual(run.report["policies"][0]["version"], 2)

    def test_concurrent_operator_change_stops_before_authority_write(self):
        run = object.__new__(driver.OnlineMatrix)
        run.access = {"access_id": "fixture", "version": 2}
        run.admin = Mock()
        run.admin.current.return_value = {"access_id": "fixture", "version": 3}
        with self.assertRaisesRegex(driver.CheckFailed, "operator_changed_test_grant"):
            run.policy(["forget"], "new-policy")
        run.admin.save.assert_not_called()

    def test_save_never_adopts_operator_version_between_policy_check_and_edit(self):
        expected = self.policy()
        page = Mock()
        admin = driver.AdminAccess(page, {}, "host-b")
        admin.current = Mock(return_value={**expected, "version": 3})
        run = object.__new__(driver.OnlineMatrix)
        run.access, run.admin, run.marker = expected, admin, "MEMORY-LOCAL-run-SHARED-case"
        # policy's first read succeeds, then the real edit observes a new version.
        admin.current.side_effect = [expected.copy(), {**expected, "version": 3}]
        with self.assertRaisesRegex(driver.CheckFailed, "operator_changed_test_grant"):
            run.policy(["forget"], "next")
        page.locator.assert_not_called()

    def test_save_and_revoke_recheck_policy_and_editor_before_submit(self):
        for action in ("save", "revoke"):
            for changed_row, editor_version in ((True, "2"), (False, "3")):
                with self.subTest(action=action, changed_row=changed_row):
                    expected = self.policy()
                    page = Mock()
                    elements = {}
                    page.locator.side_effect = lambda selector: elements.setdefault(selector, Mock())
                    page.locator("#memory-access-version").input_value.return_value = editor_version
                    admin = driver.AdminAccess(page, {}, "host-b")
                    admin.current = Mock(side_effect=[expected.copy(),
                        {**expected, "version": 3} if changed_row else expected.copy()])
                    with self.assertRaises(driver.CheckFailed):
                        if action == "save":
                            admin.save(["forget"], "new reason", expected=expected)
                        else:
                            admin.revoke("new reason", expected=expected)
                    self.assertNotIn("#memory-access-" + action, elements)
                    self.assertEqual(expected["version"], 2)

    def test_submission_uses_expected_version_for_server_cas(self):
        expected = self.policy()
        page = Mock()
        elements = {}
        page.locator.side_effect = lambda selector: elements.setdefault(selector, Mock())
        page.locator("#memory-access-version").input_value.return_value = "2"
        admin = driver.AdminAccess(page, {}, "host-b")
        admin.current = Mock(return_value=expected.copy())
        admin.wait_policy = Mock(return_value={**expected, "version": 3})
        admin.save(["forget"], "new reason", expected=expected)
        self.assertEqual(admin.wait_policy.call_args.args[-1], expected)
        # The driver verifies the existing hidden CAS value; it never fills it.
        elements["#memory-access-version"].fill.assert_not_called()
        elements["#memory-access-save"].click.assert_called_once()

    def test_subset_report_explicitly_leaves_source_provenance_unverified(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = root / "fixture.json"
            host_ids = ["11111111-1111-4111-8111-111111111111",
                        "22222222-2222-4222-8222-222222222222"]
            fixture.write_text(json.dumps({"run_id": "run", "hosts": [
                {"host_id": host, "partition": {"host_id": host, "client_id": "host:" + host,
                    "namespace": "private", "memory_space_id": "space-" + host}}
                for host in host_ids]}))
            run = driver.OnlineMatrix(fixture, "case", root / "output", 120)
            self.assertIs(run.report["source_provenance_verified"], False)
            self.assertIn("source-provenance", run.report["limits"])

    def test_mutation_receipts_are_content_free_and_bind_identity_status(self):
        committed = self.receipt()
        self.assertEqual(driver.shared_receipt(committed), committed)
        pending = {**committed, "status": "pending", "canonical_id": None, "revision": None,
                   "authority": "provisional", "consistency": "pending_canonical_ack"}
        self.assertEqual(driver.shared_receipt(pending), pending)
        for invalid in ({**committed, "content": "protected sentinel"},
                        {**committed, "command_id": 1}, {**committed, "canonical_id": "content"},
                        {**committed, "revision": True}, {**committed, "status": "rejected"},
                        {**pending, "consistency": "protected sentinel"}):
            with self.subTest(invalid=invalid), self.assertRaises(driver.CheckFailed):
                driver.shared_receipt(invalid)

    def test_both_mutation_interfaces_reject_content_leaking_receipts(self):
        for operation in ("remember", "forget"):
            run = object.__new__(driver.OnlineMatrix)
            run.marker, run.agent = "MEMORY-LOCAL-run-SHARED-case", "test-agent"
            run.access = {"access_id": "access"}
            run.owned_contents = set()
            run.b, run.wait_rows = Mock(), Mock()
            run.b.call.side_effect = [self.receipt(), {**self.receipt(), "content": "protected"}]
            with self.subTest(operation=operation), self.assertRaisesRegex(
                    driver.CheckFailed, "bounded_shared_receipt_required"):
                if operation == "remember":
                    run.write_shared("remember-only-write")
                else:
                    run.delete_shared(self.receipt()["canonical_id"], run.marker + ":write")
            self.assertEqual([call.args[0] for call in run.b.call.call_args_list], ["direct", "mcp"])
            run.wait_rows.assert_not_called()

    def test_delete_replays_one_operation_key_across_interfaces_and_separates_records(self):
        run = object.__new__(driver.OnlineMatrix)
        run.access = {"access_id": "fixture-access"}
        run.b, run.wait_rows = Mock(), Mock()
        run.b.call.side_effect = lambda *_args: self.receipt()
        marker = "MEMORY-LOCAL-run-SHARED-case:write"
        first_id = self.receipt()["canonical_id"]
        second_id = "33333333-3333-4333-8333-333333333333"

        run.delete_shared(first_id, marker)
        run.delete_shared(second_id, marker)
        run.delete_shared(first_id, marker)

        calls = run.b.call.call_args_list
        self.assertEqual([call.args[:2] for call in calls],
                         [(interface, "forget") for interface in ("direct", "mcp")] * 3)
        keys = []
        for offset, canonical_id in ((0, first_id), (2, second_id), (4, first_id)):
            direct, mcp = (calls[offset + index].args[2] for index in (0, 1))
            self.assertEqual(direct, mcp)
            self.assertEqual(direct["id"], canonical_id)
            self.assertEqual(direct["memory_access_id"], "fixture-access")
            key = direct.get("idempotency_key")
            self.assertIsInstance(key, str)
            self.assertTrue(key)
            self.assertLessEqual(len(key), 512)
            self.assertNotEqual(key, marker)  # Remember uses the marker as its key.
            keys.append(key)
        self.assertNotEqual(keys[0], keys[1])
        self.assertEqual(keys[0], keys[2])
        self.assertEqual(run.wait_rows.call_count, 3)

    def test_delete_rejects_changed_or_empty_replay_command_identity(self):
        for command_id in ("33333333-3333-4333-8333-333333333333", ""):
            with self.subTest(command_id=command_id):
                run = object.__new__(driver.OnlineMatrix)
                run.access = {"access_id": "fixture-access"}
                run.b, run.wait_rows = Mock(), Mock()
                run.b.call.side_effect = [self.receipt(),
                                         {**self.receipt(), "command_id": command_id}]
                expected = ("shared_duplicate_command_identity_changed" if command_id
                            else "receipt_command_identity_required")
                with self.assertRaisesRegex(driver.CheckFailed, expected):
                    run.delete_shared(self.receipt()["canonical_id"], "owned:write")
                run.wait_rows.assert_not_called()

    def test_delete_propagates_each_interface_failure_without_claiming_absence(self):
        for interface in ("direct", "mcp"):
            with self.subTest(interface=interface):
                run = object.__new__(driver.OnlineMatrix)
                run.access = {"access_id": "fixture-access"}
                run.b, run.wait_rows = Mock(), Mock()
                error = driver.CheckFailed("rpc_result_required")
                run.b.call.side_effect = [error] if interface == "direct" else [self.receipt(), error]
                with self.assertRaisesRegex(driver.CheckFailed, "rpc_result_required"):
                    run.delete_shared(self.receipt()["canonical_id"], "owned:write")
                self.assertEqual(run.b.call.call_count, 1 if interface == "direct" else 2)
                run.wait_rows.assert_not_called()

    def test_cleanup_deletes_only_tracked_exact_case_contents_not_prefix_neighbor(self):
        run = object.__new__(driver.OnlineMatrix)
        run.marker = "MEMORY-LOCAL-run-SHARED-a"
        own = {"id": "own", "content": run.marker + ":sentinel"}
        neighbor = {"id": "neighbor", "content": run.marker + "-long:sentinel"}
        run.owned_contents, run.created_ids = {own["content"]}, set()
        run.deadline, run.mutation_attempted, run.report = time.monotonic() + 30, False, {}
        run.a, run.b, run.wait_rows = Mock(), Mock(), Mock()
        run.a.call.side_effect = [
            {"mode": "online", "stale": False, "authority": "canonical",
             "results": [own, neighbor], "pending_operations": 0}, {}]
        run.cleanup()
        self.assertEqual(run.created_ids, {"own"})
        self.assertEqual(run.a.call.call_args_list[0].args[2]["q"], run.marker + ":")
        self.assertEqual(run.a.call.call_args_list[1].args, ("direct", "forget", {"id": "own"}))
        run.b.call.assert_not_called()

    def test_cleanup_refuses_untracked_same_case_record_before_any_deletion(self):
        run = object.__new__(driver.OnlineMatrix)
        run.marker = "MEMORY-LOCAL-run-SHARED-case"
        run.owned_contents, run.created_ids = set(), set()
        run.mutation_attempted, run.report = False, {}
        run.a, run.b = Mock(), Mock()
        run.own_rows = Mock(return_value=[{"id": "untracked", "content": run.marker + ":sentinel"}])
        with self.assertRaisesRegex(driver.CheckFailed, "cleanup_record_ownership_lost"):
            run.cleanup()
        run.a.call.assert_not_called()
        run.b.call.assert_not_called()

    def test_failed_preflight_retains_report_without_browser_or_cleanup(self):
        run = object.__new__(driver.OnlineMatrix)
        run.report = {"status": "failed"}
        run.preflight = Mock(side_effect=driver.CheckFailed("owned_ready_stack_required"))
        run.cleanup = Mock()
        with tempfile.TemporaryDirectory() as directory:
            run.output = Path(directory)
            report = json.loads(run.execute("primary", "secondary").read_text())
        self.assertEqual(report["failure"], "owned_ready_stack_required")
        self.assertEqual(report["status"], "failed")
        self.assertIn("revision", report)
        run.cleanup.assert_not_called()

    def test_any_execution_failure_overrides_previously_passed_subset_status(self):
        # Covers the outer failure handler also used after a successful matrix's cleanup fails.
        for error in (driver.CheckFailed("cleanup_failed"), RuntimeError("cleanup failed")):
            run = object.__new__(driver.OnlineMatrix)
            run.report = {"status": "passed-subset", "cleanup": {"status": "failed"}}
            run.preflight = Mock(side_effect=error)
            with tempfile.TemporaryDirectory() as directory:
                run.output = Path(directory)
                report = json.loads(run.execute("primary", "secondary").read_text())
            self.assertEqual(report["status"], "failed")
            self.assertEqual(report["cleanup"]["status"], "failed")
            self.assertIn("failure", report)


if __name__ == "__main__":
    unittest.main()
