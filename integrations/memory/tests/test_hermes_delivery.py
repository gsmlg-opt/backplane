"""Durable Hermes delivery/source identity acceptance, independent of BEAM."""

import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest


def load_plugin():
    name = "backplane_hermes_delivery_test"
    spec = importlib.util.spec_from_file_location(
        name, Path(__file__).parents[1] / "hermes" / "__init__.py"
    )
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


plugin = load_plugin()


class DeliveryJournalTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / "delivery.sqlite3"

    def journal(self, **kwargs):
        self.assertTrue(hasattr(plugin, "DeliveryJournal"), "durable delivery journal is missing")
        journal = plugin.DeliveryJournal(self.path, {"url": "http://localhost:4222", "agent_id": "hermes"}, **kwargs)
        self.addCleanup(journal.close)
        return journal

    def test_immutable_retry_and_restart_retain_payload_and_installation(self):
        first = self.journal()
        event = {"event_id": "event-1", "content": "private fact", "occurred_at": "2026-10-24T00:00:00Z"}
        first.enqueue("event-1", "/capture/test", event)
        first.enqueue("event-1", "/capture/test", dict(event))
        with self.assertRaisesRegex(ValueError, "immutable_event_conflict"):
            first.enqueue("event-1", "/capture/test", {**event, "content": "changed"})
        first.retry("event-1", "request_failed", now=10)
        second = self.journal()
        self.assertEqual(first.installation_id, second.installation_id)
        rows = second.pending(now=100)
        self.assertEqual(len(rows), 1)
        self.assertEqual(json.loads(rows[0]["payload"]), event)
        self.assertEqual(rows[0]["attempts"], 1)

    def test_binding_changes_do_not_replay_prior_partition(self):
        self.journal()
        with self.assertRaisesRegex(ValueError, "journal_binding_changed"):
            plugin.DeliveryJournal(self.path, {"url": "http://localhost:4222", "agent_id": "other"})

    def test_queue_limit_is_atomic_and_never_discards_accepted_payload(self):
        journal = self.journal(max_pending=1)
        journal.enqueue("a", "/test", {"event_id": "a"})
        with self.assertRaisesRegex(RuntimeError, "delivery_journal_full"):
            journal.enqueue("b", "/test", {"event_id": "b"})
        self.assertEqual([row["event_id"] for row in journal.pending()], ["a"])

    def test_status_distinguishes_local_host_and_canonical(self):
        journal = self.journal()
        journal.enqueue("a", "/test", {"event_id": "a"})
        self.assertEqual(journal.status()["local_pending"], 1)
        journal.accept("a", {"status": "pending", "command_id": "cmd-1"})
        self.assertEqual(journal.status()["host_accepted"], 1)
        journal.accept("a", {"status": "committed", "canonical_id": "mem-1"})
        self.assertEqual(journal.status()["canonical_committed"], 1)
        self.assertNotIn("content", json.dumps(journal.status()))

    def test_retry_exhaustion_retains_payload_and_reports_terminal_state(self):
        journal=self.journal()
        journal.enqueue("a","/test",{"event_id":"a","content":"private payload"})
        for _ in range(12):
            journal.retry("a","request_failed",now=10)
        self.assertEqual(journal.status()["rejected"],1)
        self.assertIn("retry_exhausted",journal.status()["error_codes"])
        self.assertEqual(journal.pending(now=100000),[])
        self.assertIn("private payload",journal.db.execute("SELECT payload FROM delivery WHERE event_id='a'").fetchone()[0])
        self.assertNotIn("private payload",json.dumps(journal.status()))


if __name__ == "__main__":
    unittest.main()
