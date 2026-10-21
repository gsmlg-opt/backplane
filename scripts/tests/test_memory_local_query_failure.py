"""Driver safety contracts; no browser, service, or database access."""

import copy
import importlib.util
import time
import unittest
import urllib.parse
import uuid
from pathlib import Path
from unittest.mock import Mock


class QueryFailureTest(unittest.TestCase):
    def setUp(self):
        path = Path(__file__).resolve().parents[1] / "memory_local_query_failure.py"
        self.assertTrue(path.exists(), "query failure driver is missing")
        spec = importlib.util.spec_from_file_location("memory_local_query_failure", path)
        self.driver = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.driver)
        self.fixture = {"run_id": "query-fixture", "hosts": []}
        for suffix in ("primary", "isolated"):
            host = str(uuid.uuid4())
            self.fixture["hosts"].append({"partition": {
                "memory_space_id": str(uuid.uuid4()), "host_id": host,
                "client_id": "host:" + host, "scope": "memory_local_query-fixture_" + suffix,
                "namespace": "private"}})
        self.base = "http://127.0.0.1:4221"
        self.selection = self.driver.fixture_selection(self.fixture)
        self.original = self.base + "/memory/memories/" + str(uuid.uuid4()) + "?" + urllib.parse.urlencode(
            {**self.selection, "q": "e", "offset": "25", "type": "", "session": ""})

    def test_loopback_base_rejects_remote_credentialed_or_nonbase_urls(self):
        for value in (self.base, "http://localhost:4221/", "http://[::1]:4221"):
            self.assertEqual(self.driver.local_url(value), value.rstrip("/"))
        for value in ("https://localhost", "http://remote.invalid", "http://localhost/path",
                      "http://user:secret@localhost", "http://localhost?x=y", "http://localhost#x",
                      "http://localhost:0", "http://localhost:99999"):
            with self.subTest(value=value), self.assertRaises(self.driver.CheckFailed):
                self.driver.local_url(value)

    def test_fixture_requires_owned_partitions_and_distinct_spaces(self):
        for key, value in (("scope", "real-scope"), ("namespace", "public"),
                           ("client_id", "other-client"), ("host_id", "not-a-uuid")):
            fixture = copy.deepcopy(self.fixture)
            fixture["hosts"][0]["partition"][key] = value
            with self.subTest(key=key), self.assertRaises(self.driver.CheckFailed):
                self.driver.fixture_selection(fixture)
        fixture = copy.deepcopy(self.fixture)
        fixture["hosts"][1]["partition"]["memory_space_id"] = self.selection["memory_space_id"]
        with self.assertRaises(self.driver.CheckFailed):
            self.driver.fixture_selection(fixture)
        with self.assertRaises(self.driver.CheckFailed):
            self.driver.fixture_selection({**self.fixture, "run_id": "../bad"})

    def test_fault_url_changes_only_q_preserving_detail_and_all_other_params(self):
        fault = self.driver.fault_url(self.original, self.base, self.selection, "query-fixture")
        before, after = urllib.parse.urlsplit(self.original), urllib.parse.urlsplit(fault)
        self.assertEqual(before[:3], after[:3])
        old, new = self.driver.query(self.original), self.driver.query(fault)
        self.assertIn("\0", new.pop("q"))
        old.pop("q")
        self.assertEqual(old, new)
        self.assertIn("%00", fault)

    def test_fault_rejects_wrong_origin_partition_path_offset_or_duplicate_params(self):
        mutations = [self.original.replace(self.base, "http://remote.invalid"),
                     self.original.replace("/memory/memories/", "/memory/events/"),
                     self.original.replace("offset=25", "offset=0"),
                     self.original + "&q=second", self.original + "#fragment",
                     self.original.replace(self.selection["memory_space_id"], str(uuid.uuid4()))]
        for value in mutations:
            with self.subTest(value=value), self.assertRaises(self.driver.CheckFailed):
                self.driver.fault_url(value, self.base, self.selection, "query-fixture")

    def test_finally_restores_after_patch_or_error_observation_failure(self):
        for stage in ("patch", "observe_error"):
            ui = FakeUI(stage)
            report = {}
            with self.subTest(stage=stage), self.assertRaises(self.driver.CheckFailed):
                self.driver.controlled_fault(ui, "original", "fault", report)
            self.assertEqual(ui.calls[-2:], [("patch", "original"), ("observe_recovery", "original")])
            self.assertTrue(report["restoration"]["verified"])

    def test_restoration_failure_is_explicit_and_cannot_pass(self):
        ui, report = FakeUI("observe_recovery"), {}
        with self.assertRaisesRegex(self.driver.CheckFailed, "RESTORATION_NOT_PROVEN"):
            self.driver.controlled_fault(ui, "original", "fault", report)
        self.assertTrue(report["restoration"]["attempted"])
        self.assertFalse(report["restoration"]["verified"])
        self.assertEqual(self.driver.classify(report), "failed")

    def test_success_requires_fault_recovery_no_errors_and_closed_context(self):
        report = {}
        self.driver.controlled_fault(FakeUI(), "original", "fault", report)
        report.update(page_error_count=0, context_closed=True)
        self.assertEqual(self.driver.classify(report), "passed-corrective-filter-subset")
        for key, value in (("page_error_count", 1), ("context_closed", False), ("failure", "TimeoutError")):
            with self.subTest(key=key):
                self.assertEqual(self.driver.classify({**report, key: value}), "failed")
        for key in ("fault", "recovery", "restoration"):
            changed = dict(report)
            changed.pop(key)
            self.assertEqual(self.driver.classify(changed), "failed")

    def error_ui(self, body):
        page, report = Mock(), {"page_error_count": 0}
        alert, absent = Mock(), Mock()
        alert.inner_text.return_value = body
        absent.count.return_value = 0
        page.locator.side_effect = lambda selector: alert if selector == "#memories-error" else absent
        ui = self.driver.QueryUI(page, self.base, self.selection, Path("unused"), report)
        ui.started = time.monotonic()
        ui.deadline = ui.started + 15
        ui.screenshot = Mock(return_value="query-error.png")
        ui.ids = Mock(return_value=[])
        ui.retained = Mock(return_value={"exact_url_retained": True})
        return ui, report

    def test_error_accepts_readable_slot_body_without_title_in_inner_text(self):
        ui, report = self.error_ui("The bounded partition query failed.")
        result = ui.observe_error(self.original)
        self.assertTrue(result["observed"])
        self.assertEqual(result["screenshot"], "query-error.png")
        self.assertEqual(report["error_observation"]["screenshot"], "query-error.png")
        self.assertIsNone(result["sqlstate"])

    def test_error_screenshot_is_retained_before_rejecting_missing_readable_body(self):
        ui, report = self.error_ui("Unrelated alert")
        with self.assertRaisesRegex(self.driver.CheckFailed, "query_error_message_missing"):
            ui.observe_error(self.original)
        self.assertEqual(report["error_observation"], {"alert_visible": True, "screenshot": "query-error.png"})
        self.assertNotIn("fault", report)


class FakeUI:
    def __init__(self, fail=None):
        self.fail, self.calls = fail, []

    def patch(self, url):
        self.calls.append(("patch", url))
        if self.fail == "patch" and url == "fault":
            raise RuntimeError("patch may already have happened")

    def observe_error(self, url):
        self.calls.append(("observe_error", url))
        if self.fail == "observe_error":
            raise RuntimeError("observation failed")
        return {"observed": True}

    def observe_recovery(self, url):
        self.calls.append(("observe_recovery", url))
        if self.fail == "observe_recovery":
            raise RuntimeError("restoration failed")
        return {"observed": True}


if __name__ == "__main__":
    unittest.main()
