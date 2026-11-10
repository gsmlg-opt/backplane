"""Durable Hermes delivery journal acceptance, independent of BEAM."""

import importlib.util
from contextlib import closing
import json
from importlib import import_module
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch


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

    def test_binding_changes_do_not_replay_to_another_host_or_agent(self):
        self.journal()
        with self.assertRaisesRegex(ValueError, "journal_binding_changed"):
            plugin.DeliveryJournal(self.path, {"url": "http://localhost:4222", "agent_id": "other"})

    def test_journal_from_the_retired_protocol_is_upgraded_in_place(self):
        import sqlite3
        retired_binding = {"url": "http://localhost:4222", "agent_id": "hermes", "retired_selector": "x"}
        old = plugin.DeliveryJournal(self.path, retired_binding)
        installation = old.installation_id
        old.enqueue("capture", "/capture/v1/hooks/hermes/message", {"event_id": "capture"})
        old.enqueue("deferred", "/capture/v1/hooks/hermes/message", {"event_id": "deferred"})
        old.enqueue("native", "/memory/hermes/call/source_mutate", {"event_id": "native"})
        old.db.execute("UPDATE delivery SET state='capture_deferred' WHERE event_id='deferred'")
        old.db.executescript("CREATE TABLE source_entries (entry_id TEXT); CREATE TABLE callbacks (id INTEGER);")
        old.close()
        journal = self.journal()
        self.assertEqual(journal.installation_id, installation)
        self.assertEqual([row["event_id"] for row in journal.pending(now=10**12)], ["capture", "deferred"])
        tables = {row[0] for row in journal.db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        self.assertFalse({"source_entries", "source_aliases", "source_chains", "callbacks"} & tables)
        self.assertEqual(set(journal.status()) - {"error_codes"}, {"local_pending", "host_accepted", "canonical_committed", "rejected"})

    def test_constant_and_backward_clocks_preserve_insert_order_after_restart(self):
        delivery=import_module(plugin.__name__+'.delivery')
        for clocks in ([100,100,100],[100,90,80]):
            with self.subTest(clocks=clocks):
                journal=self.journal()
                with patch.object(delivery.time,'time',side_effect=clocks):
                    for event,phase in [('z-begin','begin'),('a-page','page'),('m-commit','commit')]:
                        journal.enqueue(event,'/capture/v1/hooks/hermes/message',{'event_id':event,'phase':phase})
                expected=['z-begin','a-page','m-commit']
                self.assertEqual([row['event_id'] for row in journal.pending(now=200)],expected)
                journal.close()
                reopened=self.journal()
                self.assertEqual([row['event_id'] for row in reopened.pending(now=200)],expected)
                reopened.close()
                # Each subcase uses an independent persisted journal.
                for suffix in ('','-wal','-shm'):
                    Path(str(self.path)+suffix).unlink(missing_ok=True)

    def test_old_journal_is_upgraded_using_original_insertion_order(self):
        import sqlite3
        with closing(sqlite3.connect(self.path)) as db:
            db.execute("CREATE TABLE delivery (event_id TEXT PRIMARY KEY,path TEXT NOT NULL,payload TEXT NOT NULL,digest TEXT NOT NULL,state TEXT NOT NULL DEFAULT 'local_pending',attempts INTEGER NOT NULL DEFAULT 0,next_at REAL NOT NULL DEFAULT 0,receipt TEXT,error_code TEXT,created_at REAL NOT NULL)")
            for event,clock in [('z-begin',100),('a-page',90),('m-commit',80)]:
                db.execute('INSERT INTO delivery(event_id,path,payload,digest,created_at) VALUES (?,?,?,?,?)',(event,'/capture/v1/hooks/hermes/message',json.dumps({'event_id':event}),'original-digest',clock))
            db.commit()
        journal=self.journal()
        journal.enqueue('new-last','/capture/v1/hooks/hermes/message',{'event_id':'new-last'})
        self.assertEqual([row['event_id'] for row in journal.pending(now=10**12)],['z-begin','a-page','m-commit','new-last'])
        self.assertEqual(journal.db.execute("SELECT digest FROM delivery WHERE event_id='a-page'").fetchone()[0],'original-digest')

    def test_lost_ack_backoff_blocks_unsent_later_stages(self):
        journal=self.journal()
        for event in ('begin','page','commit'):
            journal.enqueue(event,'/capture/v1/hooks/hermes/message',{'event_id':event})
        journal.retry('begin','request_failed',now=10)
        self.assertEqual(journal.pending(now=11),[])
        self.assertEqual([row['event_id'] for row in journal.pending(now=12)],['begin','page','commit'])

    def test_queue_limit_is_atomic_and_never_discards_accepted_payload(self):
        journal = self.journal(max_pending=1)
        journal.enqueue("a", "/capture/test", {"event_id": "a"})
        with self.assertRaisesRegex(RuntimeError, "delivery_journal_full"):
            journal.enqueue("b", "/capture/test", {"event_id": "b"})
        self.assertEqual([row["event_id"] for row in journal.pending()], ["a"])

    def test_status_distinguishes_local_host_and_canonical(self):
        journal = self.journal()
        journal.enqueue("a", "/capture/test", {"event_id": "a"})
        self.assertEqual(journal.status()["local_pending"], 1)
        journal.accept("a", {"status": "pending", "command_id": "cmd-1"})
        self.assertEqual(journal.status()["host_accepted"], 1)
        journal.accept("a", {"status": "committed", "canonical_id": "mem-1"})
        self.assertEqual(journal.status()["canonical_committed"], 1)
        self.assertNotIn("content", json.dumps(journal.status()))

    def test_retry_exhaustion_retains_payload_and_reports_terminal_state(self):
        journal=self.journal()
        journal.enqueue("a","/capture/test",{"event_id":"a","content":"private payload"})
        for _ in range(12):
            journal.retry("a","request_failed",now=10)
        self.assertEqual(journal.status()["rejected"],1)
        self.assertIn("retry_exhausted",journal.status()["error_codes"])
        self.assertEqual(journal.pending(now=100000),[])
        self.assertIn("private payload",journal.db.execute("SELECT payload FROM delivery WHERE event_id='a'").fetchone()[0])
        self.assertNotIn("private payload",json.dumps(journal.status()))


if __name__ == "__main__":
    unittest.main()
