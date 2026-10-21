"""Pure acceptance guards only: no HTTP, database, lifecycle or worker calls."""

import copy
import argparse
import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import memory_local_governance as governance


HOST = "aab0c6fe-2f0d-459a-ad72-0e6adab53755"
SPACE = "fd3a7e13-ce64-675f-d1fe-9cbe070bf6b6"
TARGET = "13414b4f-e4f9-420f-a449-1e6b456604c8"


def fixture():
    return {"run_id": "guard-a", "hosts": [{"host_id": HOST, "partition": {
        "host_id": HOST, "memory_space_id": SPACE, "client_id": "host:" + HOST,
        "scope": "memory_local_guard-a_primary", "namespace": "private"}}]}


def original():
    return {"memories": [{"id": TARGET, "content_hash": "a" * 64, "deleted_at": None,
                          "lifecycle_state": "active"}],
            "candidates": [{"id": TARGET, "deleted_at": None}],
            "evidence": [{"id": "evidence-original", "memory_id": TARGET}],
            "events": [{"id": "event-original"}], "summaries": [{"id": "summary-original"}],
            "requests": [{"id": "request-original"}]}


def forgotten():
    snapshot = original()
    snapshot["memories"][0].update(deleted_at="2026-10-20", lifecycle_state="tombstoned")
    snapshot["candidates"][0]["deleted_at"] = "2026-10-20"
    return snapshot


class ReceiptEffects:
    def __init__(self):
        self.content = "Synthetic canonical PostgreSQL decision"
        self.result = {"mode": "online", "stale": False, "authority": "canonical",
                       "overlay_truncated": False, "pending_operations": 0,
                       "items": [{"id": TARGET, "content": self.content, "memory_type": "semantic",
                                  "scope": "memory_local_guard-a_primary"}]}
        self.calls, self.read_receipt, self.reject_forget = [], False, False

    def post(self, base, path, body, timeout):
        method = path.rsplit("/", 1)[-1]
        self.calls.append((method, body))
        if method == "list":
            self.read_receipt = any(row.get("id") == TARGET for row in self.result["items"])
            return 200, {"ok": True, "result": self.result}
        if method == "forget":
            if self.reject_forget or not self.read_receipt:
                return 400, {"ok": False, "error": "not_found"}
            return 200, {"ok": True, "result": {"id": TARGET, "canonical_id": TARGET, "sync_state": "synced"}}
        if method == "stats":
            return 200, {"ok": True, "result": {key: value for key, value in self.result.items() if key != "items"}}
        raise AssertionError("unexpected method")


def receipt_driver():
    args = argparse.Namespace(timeout=30, host_url="http://127.0.0.1:4222", target_id=TARGET)
    driver = governance.Governance(args)
    driver.fx = ReceiptEffects()
    driver.agent = "memory-local-guard-a"
    driver.partition = fixture()["hosts"][0]["partition"]
    driver.content = driver.fx.content
    driver.original_hash = hashlib.sha256(driver.content.encode()).hexdigest()
    return driver


class HealPage:
    """Bounded form double; never imports or launches Playwright."""

    def __init__(self, affected=1):
        self.url = "http://127.0.0.1:4221/memory"
        self.values, self.submissions, self.affected = {}, [], affected

    def locator(self, selector):
        self.selector = selector
        return self

    def fill(self, value, **_kwargs):
        self.values[self.selector] = value

    select_option = fill

    def get_by_role(self, role, name, exact):
        assert self.selector == "#memory-repair-operations form"
        assert (role, name, exact) == ("button", "Run repair", True)
        return self

    def click(self, **_kwargs):
        self.submissions.append(dict(self.values))
        status = "dispatched" if len(self.submissions) == 1 else "already_applied"
        self.result = "Repair completed\nSummary: " + status + "; affected " + str(self.affected)

    def wait_for_function(self, _function, **_kwargs):
        pass

    def count(self):
        assert self.selector == "#memory-repair-error"
        return 0

    def inner_text(self):
        assert self.selector == "#memory-repair-result"
        return self.result


class GuardTests(unittest.TestCase):
    def test_admin_heal_submits_exact_partition_session_and_same_key_twice(self):
        driver = receipt_driver()
        driver.args.session = "memory-local-guard-a-session"
        driver.args.case_id = "repair-2"
        page = HealPage()
        driver.heal_page(page)
        self.assertEqual(page.submissions[0], page.submissions[1])
        self.assertEqual(page.submissions[0], {
            "#repair-memory-space": SPACE, "#repair-host": HOST, "#repair-client": "host:" + HOST,
            "#repair-scope": "memory_local_guard-a_primary", "#repair-namespace": "private",
            "#repair-session": driver.args.session,
            "#repair-idempotency-key": "local-governance:repair-2:" + TARGET, "#repair-kind": "summary"})
        self.assertEqual(driver.report["heal"]["outcomes"], ["dispatched", "already_applied"])
        self.assertEqual(driver.fx.calls, [])

    def test_admin_heal_rejects_wrong_origin_and_nonexact_affected_count(self):
        driver = receipt_driver()
        driver.args.session, driver.args.case_id = "memory-local-guard-a-session", "repair-2"
        page = HealPage()
        page.url = "http://example.invalid/memory"
        with self.assertRaisesRegex(governance.CheckFailed, "trusted_loopback_admin_url_required"):
            driver.heal_page(page)
        self.assertEqual(page.submissions, [])
        with self.assertRaisesRegex(governance.CheckFailed, "admin_summary_heal_result_mismatch"):
            driver.heal_page(HealPage(affected=10))

    def test_forget_obtains_same_agent_supported_read_receipt_before_write(self):
        driver = receipt_driver()
        driver.forget_selected()
        self.assertEqual([method for method, _ in driver.fx.calls], ["list", "forget"])
        self.assertEqual(driver.fx.calls[1][1], {"id": TARGET})
        self.assertTrue(driver.report["positive_target_read"]["same_agent_as_forget"])

    def test_missing_changed_offline_or_truncated_target_read_never_forgets(self):
        for case in ("missing", "changed", "wrong_type", "offline", "truncated"):
            driver = receipt_driver()
            if case == "missing":
                driver.fx.result["items"] = []
            elif case == "changed":
                driver.fx.result["items"][0]["content"] = "Changed decision"
            elif case == "wrong_type":
                driver.fx.result["items"][0]["memory_type"] = "procedural"
            elif case == "offline":
                driver.fx.result["mode"] = "offline"
            else:
                driver.fx.result["items"] *= 100
            with self.subTest(case=case), self.assertRaises(governance.CheckFailed):
                driver.forget_selected()
            self.assertEqual([method for method, _ in driver.fx.calls], ["list"])
            self.assertFalse(driver.forget_attempted)

    def test_rejected_cleanup_forget_still_checks_health_and_preserves_failure(self):
        driver = receipt_driver()
        driver.forget_attempted = True
        driver.fx.reject_forget = True
        driver.report["error"] = "original_failure"
        driver.finish_health()
        self.assertEqual([method for method, _ in driver.fx.calls], ["forget", "stats"])
        self.assertEqual(driver.report["status"], "failed")
        self.assertEqual(driver.report["error"], "original_failure")
        self.assertTrue(driver.report["final_health"]["online"])
        self.assertEqual(driver.report["final_health"]["pending_operations"], 0)

    def test_cross_run_and_wrong_partition_are_rejected(self):
        governance.selected_partition(fixture(), "memory-local-guard-a-session", TARGET)
        for session in ("real-session", "memory-local-other-session", "memory-local-guard-a-\n"):
            with self.subTest(session=session), self.assertRaises(governance.CheckFailed):
                governance.selected_partition(fixture(), session, TARGET)
        for key, value in (("client_id", "other"), ("scope", "global"), ("namespace", "shared")):
            changed = fixture()
            changed["hosts"][0]["partition"][key] = value
            with self.subTest(key=key), self.assertRaises(governance.CheckFailed):
                governance.selected_partition(changed, "memory-local-guard-a-session", TARGET)

    def test_private_report_guard_rejects_shared_file_and_symlink(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fixture.json"
            path.write_text(json.dumps(fixture()))
            path.chmod(0o600)
            self.assertEqual(governance.private_json(path), fixture())
            link = path.with_name("link.json")
            link.symlink_to(path)
            with self.assertRaises(governance.CheckFailed):
                governance.private_json(link)
            path.chmod(0o644)
            with self.assertRaises(governance.CheckFailed):
                governance.private_json(path)

    def test_forget_guard_preserves_source_but_rejects_exact_hash_replacement(self):
        snapshot = forgotten()
        snapshot["summaries"].append({"id": "new-summary"})
        snapshot["events"].append({"id": "late-event"})
        result = governance.assert_governed(snapshot, original(), TARGET)
        self.assertEqual(result["new_worker_requests_to_original_tombstone"], [])
        snapshot["candidates"].append({"id": "replacement", "deleted_at": None})
        with self.assertRaisesRegex(governance.CheckFailed, "same_candidate_resurrected"):
            governance.assert_governed(snapshot, original(), TARGET)

    def test_tombstone_requires_original_hash_and_evidence_and_historical_summary(self):
        for field in ("hash", "evidence", "history"):
            snapshot = forgotten()
            if field == "hash":
                snapshot["memories"][0]["content_hash"] = "b" * 64
            elif field == "evidence":
                snapshot["evidence"] = []
            else:
                snapshot["summaries"] = []
            with self.subTest(field=field), self.assertRaises(governance.CheckFailed):
                governance.assert_governed(snapshot, original(), TARGET)

    def test_worker_completion_does_not_accept_old_jobs_or_window_summary(self):
        baseline = {"jobs": [{"id": 1, "worker": "Backplane.Memory.Workers.SummaryWorker", "state": "scheduled"}]}
        current = copy.deepcopy(baseline)
        current["jobs"][0]["state"] = "completed"
        current["jobs"].append({"id": 2, "worker": "Backplane.Memory.Workers.WindowSummaryWorker", "state": "completed"})
        self.assertEqual(governance.new_worker_completions(current, baseline), {"WindowSummaryWorker"})
        current["jobs"].append({"id": 3, "worker": "Backplane.Memory.Workers.SummaryWorker", "state": "completed"})
        self.assertIn("SummaryWorker", governance.new_worker_completions(current, baseline))

    def test_current_derived_revision_ignores_history_but_not_stale_current_crystal(self):
        snapshot = {"summaries": [{"processing_version": "summary-v1", "superseded_at": None,
                                   "input_revision": "new", "output_revision": "summary-output",
                                   "source_complete": True, "source_gap_count": 0}],
                    "stages": [{"projector": name, "status": "complete", "input_revision": "new",
                                "output_revision": "summary-output"}
                               for name in ("observations", "session", "activity", "replay", "summary", "episodic", "crystal", "graph")],
                    "crystals": [{"processing_version": "crystal-v1@old", "status": "complete", "input_revision": "old"},
                                 {"processing_version": "crystal-v1", "status": "complete", "input_revision": "new"}],
                    "nodes": [{"id": "node"}]}
        self.assertTrue(governance.derived_ready(snapshot, "new"))
        snapshot["crystals"][1]["input_revision"] = "old"
        self.assertFalse(governance.derived_ready(snapshot, "new"))

    def test_sql_uses_quoted_parameters_and_exact_canonical_partition(self):
        sql = governance.snapshot_sql()
        for key in governance.PARTITION_KEYS:
            self.assertIn("=:'" + key + "'", sql)
        self.assertIn("s.session_id=:'session'", sql)
        self.assertIn("e.session_id=:'session'", sql)
        self.assertIn("m.id=:'target_id'::uuid", sql)
        self.assertNotIn("raw_envelope", sql)
        self.assertNotIn("j.args,", sql)
        self.assertNotIn("UPDATE ", sql)
        self.assertNotIn("DELETE ", sql)


if __name__ == "__main__":
    unittest.main()
