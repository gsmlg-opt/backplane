"""Online core driver safety contracts; no services, providers or databases."""

import copy
import importlib.util
import json
import os
import tempfile
import unittest
import uuid
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "memory_local_core_parity.py"
spec = importlib.util.spec_from_file_location("memory_local_core_parity", SCRIPT)
driver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)
LOCAL, TARGET, EXISTING = (str(uuid.UUID(int=i)) for i in (31, 32, 33))


def discovery():
    fields = {
        "remember": {"content": "string", "agent_id": "string", "type": "string",
                     "scope": "string", "idempotency_key": "string", "facets": "array"},
        "recall": {"query": "string", "limit": "integer", "token_budget": "integer"},
        "list": {"scope": "string", "q": "string", "agent_id": "string", "limit": "integer"},
        "stats": {}, "forget": {"id": "string"},
        "facet_query": {"facets": "array", "limit": "integer"},
    }
    required = {"remember": ["content", "agent_id"], "recall": ["query"],
                "forget": ["id"], "facet_query": ["facets"]}
    tools = []
    for name, properties in fields.items():
        schema = {"type": "object", "properties": {key: {"type": value} for key, value in properties.items()},
                  "required": required.get(name, [])}
        if name in ("remember", "recall"):
            schema["additionalProperties"] = False
        if name == "remember":
            schema["properties"]["facets"]["items"] = {
                "type": "object", "properties": {"dimension": {"type": "string"}, "value": {"type": "string"}},
                "required": ["dimension", "value"]}
        tools.append({"name": "memory::" + name, "inputSchema": schema,
                      "_meta": {"backplane": {"permission": "memory.write" if name in ("remember", "forget") else "memory.read",
                                               "authority": "canonical", "consistency": "canonical_or_bounded_stale",
                                               "availability": "online_or_offline"}}})
    return tools


class FakeEffects:
    def __init__(self):
        self.clock, self.calls, self.created, self.deleted = 0, [], False, False
        self.pending_reads, self.forgets, self.recalls = 1, [], 0
        self.change = lambda interface, method, args, result: None
        self.tools = discovery()
        self.never_settle = False
        self.cleanup_fails = False

    def now(self):
        return self.clock

    def sleep(self, seconds):
        self.clock += seconds

    def revision(self):
        return "c7044093f0aedcb97434a0c0caba03b864c99bb3"

    def post(self, base, path, body, timeout):
        self.calls.append((path, copy.deepcopy(body), timeout))
        interface = "mcp" if path.endswith("/mcp") else "direct"
        if interface == "mcp" and body["method"] in ("initialize", "tools/list"):
            result = {"protocolVersion": "2025-11-25"} if body["method"] == "initialize" else {"tools": self.tools}
            return 200, {"jsonrpc": "2.0", "id": body["id"], "result": result}
        method = body["params"]["name"].split("::")[1] if interface == "mcp" else path.rsplit("/", 1)[1]
        args = body["params"]["arguments"] if interface == "mcp" else body
        result = {"mode": "online", "stale": False, "authority": "canonical",
                  "consistency": "canonical", "pending_operations": 0, "overlay_truncated": False}
        if method == "remember":
            self.created, self.arguments = True, copy.deepcopy(args)
            result = {"id": LOCAL, "scope": args["scope"], "sync_state": "pending",
                      "authority": "provisional", "consistency": "pending_canonical_ack"}
        elif method == "list":
            row = {"id": EXISTING, "content": "MEMORY-LOCAL-fixture preexisting", "scope": "memory_local_fixture_primary",
                   "memory_type": "semantic"}
            rows = [row]
            if self.created and not self.deleted:
                pending = self.never_settle or self.pending_reads > 0
                self.pending_reads -= 1
                target = {"id": LOCAL if pending else TARGET, "content": self.arguments["content"],
                          "scope": self.arguments["scope"], "memory_type": self.arguments["type"]}
                rows.append(target)
                if pending:
                    result.update(authority="canonical_with_provisional", consistency="read_your_writes", pending_operations=1)
            if args.get("q"):
                rows = [row for row in rows if args["q"] in row["content"]]
            if args.get("agent_id"):
                rows = [row for row in rows if row["id"] != EXISTING and args["agent_id"] == self.arguments["agent_id"]]
            result.update(items=rows, results=copy.deepcopy(rows))
        elif method == "stats":
            result["stats"] = [{"memory_type": "semantic", "count": 1}]
            if self.created and not self.deleted:
                result["stats"].append({"memory_type": "procedural", "count": 1})
        elif method == "facet_query":
            result = {"results": [{"id": TARGET, "content": self.arguments["content"], "scope": self.arguments["scope"]}]
                      if self.created and not self.deleted and args["facets"] == self.arguments["facets"] else []}
        elif method == "recall":
            self.recalls += 1
            result.update(results=[{"id": TARGET}], channels={"vector": {"status": "ok"}},
                          recall_run_id=str(uuid.UUID(int=100 + self.recalls)), used_tokens=50, token_budget=2048)
        elif method == "forget":
            self.forgets.append(args["id"])
            if self.cleanup_fails:
                raise OSError("SECRET bearer raw provider failure")
            self.deleted = True
            synced = len(self.forgets) > 1
            result = {"id": args["id"], "canonical_id": args["id"],
                      "sync_state": "synced" if synced else "pending", "revision": 7 if synced else None,
                      "authority": "canonical" if synced else "provisional",
                      "consistency": "canonical" if synced else "pending_canonical_ack"}
        else:
            raise AssertionError(method)
        self.change(interface, method, args, result)
        if interface == "mcp":
            result = {"jsonrpc": "2.0", "id": body["id"], "result": {
                "isError": False, "content": [{"type": "text", "text": json.dumps(result)}]}}
        else:
            result = {"ok": True, "result": result}
        return 200, result


class CoreParityTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.fixture = self.root / "fixture.json"
        host = str(uuid.UUID(int=40))
        self.partition = {"memory_space_id": str(uuid.UUID(int=41)), "host_id": host,
                          "client_id": "host:" + host, "scope": "memory_local_fixture_primary", "namespace": "private"}
        self.fixture.write_text(json.dumps({"run_id": "fixture", "hosts": [{"host_id": host, "partition": self.partition}]}))
        self.fixture.chmod(0o600)
        self.fx = FakeEffects()

    def run_driver(self, **options):
        self.runner = driver.Runner(self.fixture, "case-31", effects=self.fx,
                                    output=self.root / "report.json", **options)
        return self.runner.run()

    def test_full_online_subset_is_bounded_preserves_existing_and_uses_exact_retry(self):
        report = self.run_driver()
        self.assertEqual(report["status"], "passed-subset", report)
        self.assertFalse(report["complete_L02"])
        self.assertFalse(report["complete_L01_L18"])
        self.assertEqual(report["canonical_id"], TARGET)
        self.assertEqual(self.fx.recalls, 2)
        self.assertTrue(self.fx.forgets and set(self.fx.forgets) == {TARGET})
        remembered = []
        for path, body, timeout in self.fx.calls:
            self.assertGreater(timeout, 0)
            self.assertLessEqual(timeout, 20)
            if path.endswith("/call/remember"):
                remembered.append(body)
            elif path.endswith("/mcp") and body["method"] == "tools/call" and body["params"]["name"] == "memory::remember":
                remembered.append(body["params"]["arguments"])
        self.assertEqual(len(remembered), 2)
        self.assertEqual(remembered[0], remembered[1])
        self.assertEqual(remembered[0]["type"], "procedural")
        self.assertEqual(os.stat(self.root / "report.json").st_mode & 0o777, 0o600)

    def test_unsafe_endpoints_and_nonfixture_partitions_refuse_before_any_request(self):
        for url in ("https://127.0.0.1:4222", "http://example.com:4222", "http://user@127.0.0.1:4222", "http://127.0.0.1:4222/other"):
            with self.subTest(url=url):
                report = self.run_driver(host_url=url)
                self.assertEqual(report["status"], "failed")
                self.assertEqual(self.fx.calls, [])
                (self.root / "report.json").unlink()
        data = json.loads(self.fixture.read_text())
        data["hosts"][0]["partition"]["scope"] = "global"
        self.fixture.write_text(json.dumps(data))
        self.assertEqual(self.run_driver()["error"], "fixture_partition_required")
        self.assertEqual(self.fx.calls, [])

    def test_nonprivate_and_symlink_fixtures_refuse_before_requests(self):
        self.fixture.chmod(0o644)
        self.assertEqual(self.run_driver()["status"], "failed")
        self.assertEqual(self.fx.calls, [])
        (self.root / "report.json").unlink()
        self.fixture.chmod(0o600)
        original = self.root / "original.json"
        self.fixture.rename(original)
        self.fixture.symlink_to(original)
        self.assertEqual(self.run_driver()["error"], "private_fixture_required")
        self.assertEqual(self.fx.calls, [])

    def test_report_allowlists_partition_fields_instead_of_copying_fixture_secrets(self):
        data = json.loads(self.fixture.read_text())
        data["hosts"][0]["partition"]["provider_metadata"] = {"secret": "SECRET-FIXTURE-KEY"}
        self.fixture.write_text(json.dumps(data))
        self.assertEqual(self.run_driver()["status"], "passed-subset")
        self.assertNotIn("SECRET-FIXTURE-KEY", (self.root / "report.json").read_text())

    def test_ambiguous_accepted_write_response_is_cleaned_through_unique_owned_content(self):
        def lost_response(interface, method, args, result):
            if interface == "direct" and method == "remember":
                raise OSError("SECRET accepted write response lost")
        self.fx.change = lost_response
        report = self.run_driver()
        self.assertEqual(report["error"], "http_transport_failed")
        self.assertEqual(report["cleanup"]["status"], "passed")
        self.assertEqual(set(self.fx.forgets), {TARGET})

    def test_nonunique_owned_marker_is_never_deleted_speculatively(self):
        def duplicate(interface, method, args, result):
            if method == "list" and self.fx.created and result.get("pending_operations") == 0:
                for key in ("items", "results"):
                    result[key] += [{**row, "id": str(uuid.UUID(int=50))}
                                    for row in result[key] if row["id"] == TARGET]
        self.fx.change = duplicate
        report = self.run_driver()
        self.assertEqual(report["error"], "unique_owned_record_required")
        self.assertEqual(report["cleanup"]["status"], "failed")
        self.assertEqual(self.fx.forgets, [])

    def test_discovery_field_loss_refuses_before_mutation(self):
        self.fx.tools[0]["inputSchema"]["properties"].pop("facets")
        report = self.run_driver()
        self.assertEqual(report["error"], "discovery_schema_mismatch")
        self.assertFalse(self.fx.created)

    def test_offline_baseline_refuses_before_remember(self):
        self.fx.change = lambda interface, method, args, result: result.update(mode="offline") if method == "list" else None
        self.assertEqual(self.run_driver()["error"], "online_read_required")
        self.assertFalse(self.fx.created)

    def test_reused_marker_refuses_before_remember_or_forget(self):
        def reused(interface, method, args, result):
            if method == "list" and "CORE-PARITY" in args.get("q", ""):
                result.update(items=[{"id": EXISTING}], results=[{"id": EXISTING}])
        self.fx.change = reused
        self.assertEqual(self.run_driver()["error"], "fresh_case_required")
        self.assertFalse(self.fx.created)
        self.assertEqual(self.fx.forgets, [])

    def test_idempotent_identity_mismatch_fails_but_only_own_record_is_cleaned(self):
        self.fx.change = lambda interface, method, args, result: result.update(id=EXISTING) if interface == "mcp" and method == "remember" else None
        report = self.run_driver()
        self.assertEqual(report["error"], "remember_identity_mismatch")
        self.assertEqual(report["cleanup"]["status"], "passed")
        self.assertEqual(set(self.fx.forgets), {TARGET})

    def test_contradictory_remember_consistency_cannot_pass_as_online_parity(self):
        self.fx.change = lambda interface, method, args, result: result.update(authority="canonical", consistency="canonical") if method == "remember" else None
        report = self.run_driver()
        self.assertEqual(report.get("error"), "remember_receipt_required")
        self.assertEqual(report["status"], "failed")
        self.assertEqual(report["cleanup"]["status"], "passed")

    def test_field_loss_is_not_accepted_and_cleans_only_synthetic_record(self):
        def lose_type(interface, method, args, result):
            if method == "list" and self.fx.created:
                for row in result.get("items", []):
                    if row["id"] in (LOCAL, TARGET):
                        row["memory_type"] = "semantic"
        self.fx.change = lose_type
        self.assertEqual(self.run_driver()["error"], "accepted_type_lost")
        self.assertEqual(set(self.fx.forgets), {TARGET})

    def test_missing_facet_and_wrong_agent_proof_fail_honestly(self):
        for method, error in (("facet_query", "accepted_facets_lost"), ("list", "accepted_agent_lost")):
            with self.subTest(method=method):
                def lose(interface, operation, args, result):
                    if operation == method and (method != "list" or args.get("agent_id") == self.runner.agent):
                        result.update(results=[], items=[])
                self.fx.change = lose
                self.assertEqual(self.run_driver()["error"], error)
                self.assertEqual(set(self.fx.forgets), {TARGET})
                (self.root / "report.json").unlink()
                self.fx = FakeEffects()

    def test_stats_mismatch_fails_and_never_forgets_preexisting_record(self):
        def change(interface, method, args, result):
            if method == "stats" and interface == "mcp":
                result["stats"][0]["count"] += 1
        self.fx.change = change
        self.assertEqual(self.run_driver()["error"], "stats_parity_mismatch")
        self.assertEqual(set(self.fx.forgets), {TARGET})

    def test_recall_provider_failure_is_not_retried_or_reported_as_parity(self):
        def fail(interface, method, args, result):
            if method == "recall":
                result["channels"]["vector"]["status"] = "error"
        self.fx.change = fail
        report = self.run_driver()
        self.assertEqual(report["error"], "configured_vector_required")
        self.assertEqual(self.fx.recalls, 1)
        self.assertEqual(report["cleanup"]["status"], "passed")

    def test_pending_settlement_exhausts_deadline_and_reports_cleanup_failure(self):
        self.fx.never_settle = True
        report = self.run_driver(timeout=12, cleanup_timeout=4)
        self.assertEqual(report["status"], "failed")
        self.assertEqual(report["cleanup"]["status"], "failed")
        self.assertLessEqual(self.fx.clock, 12)
        self.assertEqual(self.fx.forgets, [])

    def test_cleanup_failure_is_explicit_and_raw_errors_are_never_saved(self):
        self.fx.cleanup_fails = True
        report = self.run_driver()
        self.assertEqual(report["status"], "failed")
        self.assertEqual(report["cleanup"]["status"], "failed")
        raw = (self.root / "report.json").read_text()
        self.assertNotIn("SECRET", raw)
        self.assertNotIn("bearer", raw)

    def test_forget_preserves_known_local_id_with_explicit_canonical_mapping(self):
        def local_receipt(interface, method, args, result):
            if method == "forget" and result["sync_state"] == "pending":
                result["id"] = LOCAL
        self.fx.change = local_receipt
        report = self.run_driver()
        self.assertEqual(report["status"], "passed-subset", report)
        receipts = [row for row in report["observations"] if row["phase"] == "tool_receipt" and row["tool_name"] == "memory::forget"]
        self.assertEqual(receipts[0]["receipt"]["id"], LOCAL)
        self.assertEqual(receipts[0]["receipt"]["canonical_id"], TARGET)

    def test_forget_rejects_missing_or_wrong_canonical_mapping_and_unknown_local_ids(self):
        for change in (lambda row: row.pop("canonical_id"),
                       lambda row: row.update(canonical_id=EXISTING),
                       lambda row: row.update(id=EXISTING)):
            with self.subTest(change=change):
                self.fx.change = lambda interface, method, args, result: change(result) if method == "forget" else None
                report = self.run_driver()
                self.assertEqual(report["error"], "forget_receipt_required")
                self.assertEqual(report["status"], "failed")
                self.assertFalse(report.get("online_canonical_forget", False))
                (self.root / "report.json").unlink()
                self.fx = FakeEffects()

    def test_forget_rejects_pending_canonical_claim_and_stale_positive_revision(self):
        for fields in ({"authority": "canonical", "consistency": "canonical"}, {"revision": 9}):
            with self.subTest(fields=fields):
                self.fx.change = lambda interface, method, args, result: result.update(fields) if method == "forget" and result["sync_state"] == "pending" else None
                report = self.run_driver()
                self.assertEqual(report["error"], "forget_pending_receipt_required")
                self.assertEqual(report["status"], "failed")
                (self.root / "report.json").unlink()
                self.fx = FakeEffects()

    def test_failed_forget_keeps_safe_receipt_tool_names_and_cleanup_boundaries(self):
        def invalid(interface, method, args, result):
            if method == "forget" and interface == "direct":
                result.update(canonical_id=EXISTING, token="SECRET-RECEIPT-KEY", content="SECRET-CONTENT")
        self.fx.change = invalid
        report = self.run_driver()
        rows = report["observations"]
        failure_receipt = next(row for row in rows if row["phase"] == "tool_receipt" and row["tool_name"] == "memory::forget")
        self.assertEqual(failure_receipt["receipt"]["canonical_id"], EXISTING)
        self.assertFalse(failure_receipt["cleanup"])
        start = next(i for i, row in enumerate(rows) if row["phase"] == "cleanup_start")
        end = next(i for i, row in enumerate(rows) if row["phase"] == "cleanup_end")
        self.assertLess(start, end)
        calls = [row for row in rows if row["phase"] == "http" and row.get("method") == "tools/call"]
        self.assertTrue(all(row.get("tool_name", "").startswith("memory::") for row in calls))
        self.assertTrue(any(row.get("cleanup") for row in calls))
        self.assertNotIn("SECRET", json.dumps(report))

    def test_deletion_requires_canonical_ack_not_only_overlay_absence(self):
        self.fx.change = lambda interface, method, args, result: result.update(sync_state="pending", authority="provisional", consistency="pending_canonical_ack", revision=None) if method == "forget" else None
        report = self.run_driver(timeout=12, cleanup_timeout=4)
        self.assertEqual(report["status"], "failed")
        self.assertFalse(report.get("online_canonical_forget", False))


if __name__ == "__main__":
    unittest.main()
