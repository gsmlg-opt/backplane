import importlib.util
import json
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "memory_local_partition_appearance.py"
spec = importlib.util.spec_from_file_location("partition_appearance", SCRIPT)
module = importlib.util.module_from_spec(spec)


class PartitionAppearanceTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec.loader.exec_module(module)

    def fixture(self):
        host = "11111111-1111-4111-8111-111111111111"
        return {"run_id": "synthetic-a", "hosts": [{"name": "memory-local-synthetic-a-primary",
            "host_id": host, "partition": {"memory_space_id": "22222222-2222-4222-8222-222222222222",
            "host_id": host, "client_id": "host:" + host,
            "scope": "memory_local_synthetic-a_primary", "namespace": "private"}}]}

    def test_names_are_unique_safe_and_fixture_scoped(self):
        a = module.make_identity("synthetic-a")
        b = module.make_identity("synthetic-a")
        self.assertNotEqual(a["name"], b["name"])
        self.assertTrue(a["name"].startswith("memory-local-synthetic-a-appearance-"))
        self.assertRegex(a["scope"], r"^memory_local_synthetic-a_appearance_[a-z0-9-]+$")
        for unsafe in ("../bad", "has space", "UPPER", "x" * 51):
            with self.assertRaises(module.CheckFailed):
                module.make_identity(unsafe)

    def test_fixture_validates_bound_host_and_discards_unneeded_secrets(self):
        data = self.fixture()
        data["hosts"][0]["token"] = "bha_should_never_be_loaded"
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fixture.json"
            path.write_text(json.dumps(data))
            run, partition = module.load_fixture(path)
            self.assertEqual(run, "synthetic-a")
            self.assertNotIn("bha_", json.dumps(partition))
            data["hosts"][0]["partition"]["client_id"] = "host:another-host"
            path.write_text(json.dumps(data))
            with self.assertRaises(module.CheckFailed):
                module.load_fixture(path)

    def test_choice_must_match_exact_new_host_scope_and_loopback_surface(self):
        host = "33333333-3333-4333-8333-333333333333"
        identity = {"host_id": host, "scope": "synthetic-new"}
        href = "/memory/sessions?memory_space_id=44444444-4444-4444-8444-444444444444&host=" + host + "&client=host%3A" + host + "&scope=synthetic-new&namespace=private"
        selection = module.validated_choice(href, "http://127.0.0.1:4221", identity)
        self.assertEqual(selection["host"], host)
        for bad in ("http://remote.test" + href, href.replace("synthetic-new", "another"),
                    href.replace("private", "public"), href + "&token=bha_private"):
            with self.assertRaises(module.CheckFailed):
                module.validated_choice(bad, "http://127.0.0.1:4221", identity)

    def test_redaction_scrubs_nested_tokens_and_bearer_values(self):
        raw = {"error": "bha_private-secret Bearer secret-value", "rows": ["bha_another_secret"]}
        encoded = json.dumps(module.redact(raw))
        self.assertNotIn("private-secret", encoded)
        self.assertNotIn("secret-value", encoded)
        self.assertNotIn("another_secret", encoded)
        self.assertIn("[REDACTED]", encoded)

    def report(self):
        state = {"url": "fixture", "document": {"marker": "stable", "time_origin": 1},
                 "filters": {"q": "e"}, "selected_id": "fixture-id", "detail_visible": True}
        return {"creation": {"confirmed": True}, "page_error_count": 0,
                "pages": {name: {"before": state, "after": state, "navigation_requests": 0,
                                  "choice_href": "/fixture", "choice_visible": True, "appearance_ms": 2000}
                          for name in ("sessions", "memories")},
                "empty_partition": {"selection_matches": True, "count": 0, "empty_visible": True}}

    def test_stale_memories_picker_fails_despite_sessions_and_empty_success(self):
        report = self.report()
        self.assertTrue(module.evaluate_report(report)["passed"])
        report["pages"]["memories"]["choice_href"] = None
        result = module.evaluate_report(report)
        self.assertFalse(result["passed"])
        self.assertTrue(result["pages"]["sessions"]["passed"])
        self.assertFalse(result["pages"]["memories"]["passed"])

    def test_hidden_choice_is_discovered_then_shown_by_expanding_existing_picker(self):
        host = "33333333-3333-4333-8333-333333333333"
        href = "/memory/sessions?memory_space_id=44444444-4444-4444-8444-444444444444&host=" + host + "&client=host%3A" + host + "&scope=synthetic-new&namespace=private"
        clock = [101]

        class Picker:
            opened = False
            clicks = 0
            include_hidden = False

            def get_by_role(self, role, *, name, exact, include_hidden=False):
                self.include_hidden = include_hidden
                return self

            def count(self):
                return int(self.opened or self.include_hidden)

            def get_attribute(self, name, **_kwargs):
                return href if name == "href" else ("" if self.opened else None)

            def locator(self, _selector):
                return self

            def click(self, **_kwargs):
                self.opened = True
                self.clicks += 1
                clock[0] = 102

            def is_visible(self):
                return self.opened

        picker = Picker()
        driver = module.Appearance.__new__(module.Appearance)
        driver.base = "http://127.0.0.1:4221"
        driver.identity = {"name": "synthetic-host", "host_id": host, "scope": "synthetic-new"}
        driver.primary = {"memory_space_id": "22222222-2222-4222-8222-222222222222"}
        driver.started = 100
        row = {"choice_href": None, "choice_visible": False}
        with patch.object(module.time, "monotonic", side_effect=lambda: clock[0]):
            driver.observe_choice(picker, row, 108)
        self.assertTrue(picker.include_hidden)
        self.assertEqual(picker.clicks, 1)
        self.assertTrue(row["dom_present"])
        self.assertEqual(row["dom_discovery_ms"], 1000)
        self.assertEqual(row["appearance_ms"], 2000)
        self.assertEqual(row["choice_href"], href)
        self.assertTrue(row["choice_visible"])

    def test_reload_state_loss_slow_discovery_and_nonempty_partition_fail(self):
        for mutation in ("reload", "filter", "slow", "nonempty"):
            report = self.report()
            if mutation == "reload":
                report["pages"]["sessions"]["navigation_requests"] = 1
            elif mutation == "filter":
                report["pages"]["memories"]["after"] = {"url": "changed"}
            elif mutation == "slow":
                report["pages"]["memories"]["appearance_ms"] = 6000
            else:
                report["empty_partition"]["count"] = 1
            self.assertFalse(module.evaluate_report(report)["passed"], mutation)


if __name__ == "__main__":
    unittest.main()
