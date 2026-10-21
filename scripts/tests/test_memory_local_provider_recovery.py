"""Safety contracts only; never contact browsers, providers, services, or databases."""

import copy
import importlib.util
import sys
import unittest
import uuid
from pathlib import Path
from unittest.mock import patch


SCRIPTS = Path(__file__).resolve().parents[1]
TARGET = "84114c64-48b3-44fc-9f6b-9c676e33889c"


class ProviderRecoveryTest(unittest.TestCase):
    def setUp(self):
        path = SCRIPTS / "memory_local_provider_recovery.py"
        self.assertTrue(path.exists(), "provider recovery driver is missing")
        spec = importlib.util.spec_from_file_location("memory_local_provider_recovery", path)
        self.driver = importlib.util.module_from_spec(spec)
        with patch.object(sys, "path", [str(SCRIPTS), *sys.path]):
            spec.loader.exec_module(self.driver)
        host = str(uuid.uuid4())
        self.fixture = {"run_id": "different-fixture", "models": [
            "memory-local-different-fixture/openai/gpt-4.1-mini",
            "memory-local-different-fixture/openai/text-embedding-3-large"],
            "settings": {"memory.embed_model": "memory-local-different-fixture/openai/text-embedding-3-large"},
            "hosts": [{"partition": {"memory_space_id": str(uuid.uuid4()), "host_id": host,
                       "client_id": "host:" + host, "scope": "memory_local_different-fixture_primary",
                       "namespace": "private"}}]}
        self.form = {"name": "memory-local-different-fixture", "credential": "memory-local-different-fixture-upstream",
                     "base_url": "https://openrouter.ai/api/v1", "enabled": True, "model_enabled": True,
                     "model": "openai/text-embedding-3-large", "display_name": "", "default_headers": "{}",
                     "metadata": '{"dimensions":2560}'}

    def result(self, degraded=False):
        return {"mode": "online", "recall_run_id": str(uuid.uuid4()), "results": [{"id": TARGET}],
                "used_tokens": 64, "token_budget": 2048,
                "channels": {"fts": {"status": "ok", "count": 2, "duration_us": 1},
                             "vector": {"status": "error" if degraded else "ok", "count": 0 if degraded else 3,
                                        "duration_us": 50}}}

    def test_fixture_identity_and_form_require_dedicated_provider_model_partition(self):
        identity = self.driver.fixture_identity(self.fixture)
        self.assertEqual(identity["provider"], self.form["name"])
        self.driver.validate_form(self.form, identity)
        for key, value in (("name", "another-provider"), ("credential", "another-key"),
                           ("enabled", False), ("model_enabled", False), ("model", "another-model")):
            with self.subTest(key=key), self.assertRaises(self.driver.CheckError):
                self.driver.validate_form({**self.form, key: value}, identity)
        for key, value in (("scope", "another-scope"), ("namespace", "public"), ("client_id", "another-host")):
            fixture = copy.deepcopy(self.fixture)
            fixture["hosts"][0]["partition"][key] = value
            with self.subTest(key=key), self.assertRaises(self.driver.CheckError):
                self.driver.fixture_identity(fixture)
        fixture = copy.deepcopy(self.fixture)
        fixture["models"][1] = "unrelated/openai/text-embedding-3-large"
        with self.assertRaises(self.driver.CheckError):
            self.driver.fixture_identity(fixture)

    def test_urls_are_loopback_and_fault_preserves_only_approved_origin(self):
        for value in ("http://127.0.0.1:4221", "http://localhost:4222/", "http://[::1]:4221"):
            self.assertEqual(self.driver.local_url(value), value.rstrip("/"))
        for value in ("https://localhost:4221", "http://remote.invalid", "http://user:secret@localhost",
                      "http://localhost/path", "http://localhost?x=y", "http://localhost:0"):
            with self.subTest(value=value), self.assertRaises(self.driver.CheckError):
                self.driver.local_url(value)
        self.assertEqual(self.driver.failure_url(self.form["base_url"], "different-fixture"),
                         "https://openrouter.ai/api/v1/__memory_local_different-fixture_failure")
        for value in ("https://other.invalid/api/v1", "http://openrouter.ai/api/v1",
                      "https://openrouter.ai:8443/api/v1", "https://secret@openrouter.ai/api/v1",
                      "https://openrouter.ai/api/v1?token=secret"):
            with self.subTest(value=value), self.assertRaises(self.driver.CheckError):
                self.driver.failure_url(value, "different-fixture")

    def test_healthy_and_degraded_predicates_require_real_channel_states(self):
        for degraded in (False, True):
            result = self.result(degraded)
            metrics = self.driver.validate_recall(result, degraded, {TARGET}, 20.0)
            self.assertEqual(metrics["result_ids"], [TARGET])
            self.assertEqual(metrics["vector"]["status"], "error" if degraded else "ok")
            result["channels"]["vector"]["status"] = "unavailable"
            with self.assertRaises(self.driver.CheckError):
                self.driver.validate_recall(result, degraded, {TARGET}, 20.0)

    def test_recall_rejects_offline_bad_trace_miss_budget_latency_or_false_recovery(self):
        mutations = [lambda row: row.update(mode="offline"), lambda row: row.update(recall_run_id=None),
                     lambda row: row.update(results=[]), lambda row: row.update(used_tokens=0),
                     lambda row: row.update(used_tokens=True), lambda row: row.update(used_tokens=2049),
                     lambda row: row.update(token_budget=4096),
                     lambda row: row["channels"]["vector"].update(count=0),
                     lambda row: row["channels"]["vector"].update(status="timeout")]
        for mutation in mutations:
            result = self.result()
            mutation(result)
            with self.assertRaises(self.driver.CheckError):
                self.driver.validate_recall(result, False, {TARGET}, 20.0)
        for elapsed in (-1, 15000, float("inf"), float("nan")):
            with self.subTest(elapsed=elapsed), self.assertRaises(self.driver.CheckError):
                self.driver.validate_recall(self.result(), False, {TARGET}, elapsed)
        for mutation in (lambda row: row["channels"]["fts"].update(count=0),
                         lambda row: row["channels"]["fts"].update(status="error"),
                         lambda row: row["channels"]["vector"].update(count=1),
                         lambda row: row["channels"]["vector"].update(status="ok")):
            result = self.result(True)
            mutation(result)
            with self.assertRaises(self.driver.CheckError):
                self.driver.validate_recall(result, True, {TARGET}, 20.0)

    def test_form_report_is_hashed_without_credential_or_header_values(self):
        form = {**self.form, "default_headers": '{"authorization":"secret-value"}'}
        summary = self.driver.form_summary(form)
        self.assertNotIn("secret-value", str(summary))
        self.assertNotIn(form["credential"], str(summary))
        self.assertEqual(len(summary["sha256"]), 64)
        self.assertNotEqual(summary["sha256"], self.driver.form_summary(self.form)["sha256"])

    def test_restores_even_when_fault_check_or_mutation_raises(self):
        for fail_save in (False, True):
            ui = FakeUI(self.form, fail_save=fail_save)
            report = {}
            def fail_check():
                raise self.driver.CheckError("fault_check_failed")
            with self.subTest(fail_save=fail_save), self.assertRaises(self.driver.CheckError):
                self.driver.controlled_fault(ui, self.form, "https://openrouter.ai/api/v1/__fault", fail_check, report)
            self.assertEqual(ui.form, self.form)
            self.assertTrue(report["restoration"]["verified"])
            self.assertEqual(ui.saved[-1], self.form["base_url"])

    def test_restoration_failure_never_claims_success(self):
        ui = FakeUI(self.form, cannot_restore=True)
        report = {}
        with self.assertRaisesRegex(self.driver.CheckError, "RESTORATION_NOT_PROVEN"):
            self.driver.controlled_fault(ui, self.form, "https://openrouter.ai/api/v1/__fault", lambda: None, report)
        self.assertTrue(report["restoration"]["attempted"])
        self.assertFalse(report["restoration"]["verified"])

    def test_fault_changes_only_base_url_and_returns_callback_result(self):
        ui = FakeUI(self.form)
        report = {}
        def check():
            self.assertEqual({key: value for key, value in ui.form.items() if key != "base_url"},
                             {key: value for key, value in self.form.items() if key != "base_url"})
            return "observed"
        self.assertEqual(self.driver.controlled_fault(ui, self.form, "https://openrouter.ai/api/v1/__fault", check, report), "observed")
        self.assertEqual(ui.form, self.form)
        self.assertTrue(report["restoration"]["verified"])


class FakeUI:
    def __init__(self, original, fail_save=False, cannot_restore=False):
        self.form = copy.deepcopy(original)
        self.original_url = original["base_url"]
        self.fail_save = fail_save
        self.cannot_restore = cannot_restore
        self.saved = []

    def read_form(self):
        return copy.deepcopy(self.form)

    def set_base_url(self, value):
        self.saved.append(value)
        if value == self.original_url and self.cannot_restore:
            return
        self.form["base_url"] = value
        if value != self.original_url and self.fail_save:
            raise RuntimeError("mutation may already have committed")


if __name__ == "__main__":
    unittest.main()
