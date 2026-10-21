"""Mocked recall acceptance contracts; no network, database, or provider calls."""

import copy
import importlib.util
import json
import sys
import tempfile
import unittest
import uuid
from pathlib import Path
from unittest.mock import Mock, patch


SCRIPT = Path(__file__).resolve().parents[1] / "memory_local_acceptance.py"
TARGET = "84114c64-48b3-44fc-9f6b-9c676e33889c"
OTHER = "481a2882-80e8-4760-a131-95668824c9ac"


class RecallAcceptanceTest(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location("memory_local_acceptance", SCRIPT)
        self.driver = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.driver)
        self.assertTrue(hasattr(self.driver.Acceptance, "recall"), "recall phase is missing")
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.fixture = root / "fixture.json"
        self.partition = {"memory_space_id": str(uuid.uuid4()), "host_id": str(uuid.uuid4()),
                          "client_id": "host:synthetic", "scope": "scope-different-fixture",
                          "namespace": "private"}
        self.fixture.write_text(json.dumps({"run_id": "different-fixture", "hosts": [{"partition": self.partition}]}))
        with patch.object(self.driver, "ROOT", root):
            self.run = self.driver.Acceptance(self.fixture, "http://127.0.0.1:4222", 30)
        self.inventory = {"mode": "online", "pending_operations": 0, "items": [
            {"id": TARGET, "scope": self.partition["scope"],
             "content": "This project prefers bounded OTP workers over unlimited tasks."},
            {"id": OTHER, "scope": self.partition["scope"], "content": "An unrelated record."}]}
        self.calls = []
        self.case_number = 0
        self.mutate = lambda result, interface, query: None
        self.second_inventory = None
        self.inventory_calls = 0
        self.run.post = self.post
        for name in ("provider", "discover", "write", "capture"):
            setattr(self.run, name, Mock(side_effect=AssertionError("unexpected mutation or preflight")))

    def post(self, path, body):
        self.calls.append((path, copy.deepcopy(body)))
        if path.endswith("/call/list"):
            self.inventory_calls += 1
            result = self.second_inventory if self.inventory_calls > 1 and self.second_inventory else self.inventory
            return {"ok": True, "result": copy.deepcopy(result)}
        interface = "mcp" if path.endswith("/mcp") else "direct"
        args = body["params"]["arguments"] if interface == "mcp" else body
        self.case_number += 1
        result = {"mode": "online", "pending_operations": 0,
                  "recall_run_id": str(uuid.UUID(int=self.case_number)),
                  "results": [{"id": TARGET}], "used_tokens": 64,
                  "token_budget": 2048, "channels": {"vector": {"status": "ok", "count": 3, "duration_us": 45}}}
        self.mutate(result, interface, args["query"])
        if interface == "mcp":
            return {"jsonrpc": "2.0", "id": body["id"], "result": {
                "isError": False, "content": [{"type": "text", "text": json.dumps(result)}]}}
        return {"ok": True, "result": result}

    def test_discovers_fixture_ids_and_runs_four_read_only_schema_correct_cases(self):
        detail = self.run.recall()
        self.assertEqual(detail["expected_ids"], [TARGET])
        self.assertEqual(len(detail["cases"]), 4)
        self.assertEqual({(row["interface"], row["case"]) for row in detail["cases"]},
                         {("direct", "exact"), ("direct", "paraphrase"), ("mcp", "exact"), ("mcp", "paraphrase")})
        self.assertTrue(all(row["meaningful_hit"] for row in detail["cases"]))
        self.assertTrue(all(row["selected_identities_match"] for row in detail["comparisons"]))
        for path, body in self.calls:
            if path.endswith("/call/list"):
                self.assertEqual(body, {"scope": self.partition["scope"], "q": "bounded OTP", "limit": 50})
            else:
                args = body["params"]["arguments"] if path.endswith("/mcp") else body
                self.assertEqual(set(args), {"query", "limit", "token_budget"})
                self.assertEqual(args["token_budget"], 2048)
        for row in detail["cases"]:
            self.assertIn(self.partition["memory_space_id"], row["ui_url"])
            self.assertIn(row["trace"], row["ui_url"])

    def test_rejects_offline_mirror_even_with_useful_results(self):
        self.mutate = lambda result, *_: result.update(mode="offline", source="edge_mirror")
        with self.assertRaisesRegex(RuntimeError, "recall_online_required"):
            self.run.recall()

    def test_rejects_legacy_or_invalid_trace(self):
        for trace in (None, "not-a-uuid"):
            with self.subTest(trace=trace):
                self.mutate = lambda result, *_, value=trace: result.update(recall_run_id=value)
                with self.assertRaisesRegex(RuntimeError, "recall_v2_trace_required"):
                    self.run.recall()

    def test_rejects_vector_timeout(self):
        self.mutate = lambda result, *_: result.update(channels={"vector": {"status": "timeout"}})
        with self.assertRaisesRegex(RuntimeError, "recall_vector_required"):
            self.run.recall()

    def test_rejects_result_without_discovered_preference(self):
        self.mutate = lambda result, *_: result.update(results=[{"id": OTHER}])
        with self.assertRaisesRegex(RuntimeError, "recall_expected_knowledge_missing"):
            self.run.recall()

    def test_rejects_invalid_usage_and_returned_budget(self):
        for usage, budget in ((2049, 2048), (0, 2048), (True, 2048), (float("nan"), 2048), (64, 4096)):
            with self.subTest(usage=usage, budget=budget):
                self.mutate = lambda result, *_, u=usage, b=budget: result.update(used_tokens=u, token_budget=b)
                with self.assertRaisesRegex(RuntimeError, "recall_token_budget"):
                    self.run.recall()

    def test_rejects_nonfinite_or_over_budget_elapsed(self):
        for elapsed in (15.0, float("inf"), float("nan"), -1.0):
            with self.subTest(elapsed=elapsed), patch.object(self.driver.time, "monotonic", side_effect=[0.0, elapsed]):
                with self.assertRaisesRegex(RuntimeError, "recall_latency_budget"):
                    self.run.recall()

    def test_rejects_inventory_without_matching_scope_preference(self):
        self.inventory["items"][0]["scope"] = "another-scope"
        with self.assertRaisesRegex(RuntimeError, "recall_fixture_knowledge_missing"):
            self.run.recall()
        self.assertEqual(self.case_number, 0)

    def test_rejects_stable_direct_mcp_identity_disagreement(self):
        def mutate(result, interface, query):
            if interface == "mcp":
                result["results"].append({"id": OTHER})
        self.mutate = mutate
        with self.assertRaisesRegex(RuntimeError, "recall_direct_mcp_identity_mismatch"):
            self.run.recall()

    def test_reports_comparison_as_skipped_when_fixture_inventory_changes(self):
        self.second_inventory = copy.deepcopy(self.inventory)
        self.second_inventory["items"].append({"id": str(uuid.uuid4()), "scope": self.partition["scope"],
                                               "content": "Another bounded OTP worker preference."})
        detail = self.run.recall()
        self.assertFalse(detail["fixture_inventory_stable"])
        self.assertTrue(all(not row["compared"] for row in detail["comparisons"]))

    def test_evidence_remains_api_subset_with_four_cases(self):
        detail = self.run.recall()
        with patch.object(self.driver.subprocess, "check_output", return_value="baseline\n"):
            self.run.save("recall", "passed-subset", detail=detail)
        path = next(self.run.output.glob("api-recall-*.json"))
        report = json.loads(path.read_text())
        self.assertFalse(report["complete_L01_L18"])
        self.assertEqual(report["evidence_level"], "live-host-http-subset")
        self.assertEqual(len(report["detail"]["cases"]), 4)
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(detail["separate_checks"], ["browser trace agreement", "database embedding model provenance"])

    def browser_report(self):
        spec = importlib.util.spec_from_file_location("memory_local_browser", SCRIPT.with_name("memory_local_browser.py"))
        browser = importlib.util.module_from_spec(spec)
        with patch.dict(sys.modules, {"memory_local_acceptance": self.driver}):
            spec.loader.exec_module(browser)
        self.assertTrue(hasattr(browser, "load_recall_report"), "recall browser report parser is missing")
        report = {"run_id": self.run.run_id, "phase": "recall", "status": "passed-subset",
                  "complete_L01_L18": False, "detail": self.run.recall()}
        path = Path(self.temp.name) / "recall.json"
        return browser, report, path

    def test_browser_consumes_four_valid_cases_without_trusting_report_urls(self):
        browser, report, path = self.browser_report()
        report["detail"]["cases"][0]["ui_url"] = "https://untrusted.invalid/trace"
        path.write_text(json.dumps(report))
        cases = browser.load_recall_report(path, self.run.run_id)
        self.assertEqual(len(cases), 4)
        self.assertTrue(all(row["expected_ids"] == [TARGET] for row in cases))
        self.assertTrue(all("ui_url" not in row for row in cases))

    def test_browser_rejects_other_run_or_incomplete_reports(self):
        browser, report, path = self.browser_report()
        for change in ({"run_id": "another-run"}, {"status": "failed"}, {"complete_L01_L18": True}):
            with self.subTest(change=change):
                path.write_text(json.dumps({**report, **change}))
                with self.assertRaises(ValueError):
                    browser.load_recall_report(path, self.run.run_id)

    def test_browser_rejects_duplicate_or_invalid_trace_cases(self):
        browser, report, path = self.browser_report()
        for mutate in (lambda rows: rows.pop(),
                       lambda rows: rows[0].update(trace="not-a-uuid"),
                       lambda rows: rows[0].update(trace=rows[1]["trace"]),
                       lambda rows: rows[0].update(interface=rows[1]["interface"], case=rows[1]["case"]),
                       lambda rows: rows[0].update(result_ids=[OTHER])):
            changed = copy.deepcopy(report)
            mutate(changed["detail"]["cases"])
            path.write_text(json.dumps(changed))
            with self.assertRaises(ValueError):
                browser.load_recall_report(path, self.run.run_id)


if __name__ == "__main__":
    unittest.main()
