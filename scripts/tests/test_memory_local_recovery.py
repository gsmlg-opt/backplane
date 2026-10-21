"""Recovery-driver helper coverage; never starts or stops development services."""

import contextlib
import importlib.util
import json
import os
import sqlite3
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "memory_local_recovery.py"


class RecoveryHelpersTest(unittest.TestCase):
    def setUp(self):
        self.assertTrue(SCRIPT.is_file(), "recovery driver is missing")
        spec = importlib.util.spec_from_file_location("memory_local_recovery", SCRIPT)
        self.driver = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.driver)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_allowlist_drops_credentials_content_and_arbitrary_errors(self):
        response = {
            "ok": True, "token": "private-token", "error": "private-provider-error",
            "result": {"mode": "offline", "source": "edge_mirror", "pending_operations": 2,
                       "results": [{"id": "b2f51c49-628f-4972-b0af-b5fd970a5a29",
                                    "content": "private-memory", "token": "nested-token"}]},
        }
        safe = self.driver.safe_reply(response)
        encoded = json.dumps(safe)
        for secret in ("private-token", "private-provider-error", "private-memory", "nested-token"):
            self.assertNotIn(secret, encoded)
        self.assertEqual(safe["result"]["source"], "edge_mirror")
        self.assertEqual(len(safe["result"]["results"]), 1)

    def test_read_only_snapshot_filters_unrelated_rows_and_retains_tombstone_evidence(self):
        db = self.root / "commands.db"
        with contextlib.closing(sqlite3.connect(db)) as connection:
            connection.executescript("""
              CREATE TABLE memory_outbox(seq INTEGER, op TEXT, memory_id TEXT, state TEXT,
                attempts INTEGER, ack_canonical_id TEXT, ack_revision INTEGER);
              CREATE TABLE memories(id TEXT, remote_id TEXT, sync_state TEXT, deleted_at TEXT,
                content_hash TEXT);
              CREATE TABLE tombstones(content_hash TEXT, scope TEXT);
              INSERT INTO memory_outbox VALUES(1,'forget','target','pending',0,NULL,NULL);
              INSERT INTO memory_outbox VALUES(2,'remember','foreign','pending',0,NULL,NULL);
              INSERT INTO memories VALUES('target',NULL,'pending','now','hash-target');
              INSERT INTO memories VALUES('foreign',NULL,'pending',NULL,'hash-foreign');
              INSERT INTO tombstones VALUES('hash-target','scope-a');
              INSERT INTO tombstones VALUES('hash-foreign','scope-b');
            """)
        snapshot = self.driver.command_snapshot(db, ["target"], "scope-a")
        self.assertEqual([row["seq"] for row in snapshot["outbox"]], [1])
        self.assertTrue(snapshot["memories"][0]["deleted"])
        self.assertEqual(snapshot["tombstones"], 1)
        self.assertNotIn("foreign", json.dumps(snapshot))
        with self.driver.read_only(db) as connection:
            with self.assertRaises(sqlite3.OperationalError):
                connection.execute("DELETE FROM memories")
        with contextlib.closing(sqlite3.connect(db)) as connection:
            self.assertEqual(connection.execute("SELECT count(*) FROM memories").fetchone()[0], 2)

    def test_missing_store_is_not_created(self):
        missing = self.root / "missing.db"
        with self.assertRaises((OSError, sqlite3.OperationalError)):
            with self.driver.read_only(missing):
                pass
        self.assertFalse(missing.exists())

    def test_list_uses_items_and_recall_uses_results(self):
        run = object.__new__(self.driver.Recovery)
        run.ids = set()
        run.timeout = 0.01
        row = {"id": "target", "content": "synthetic"}
        run.listing = lambda: {"mode": "online", "pending_operations": 0, "items": [row]}
        self.assertEqual(run.settled({"content": "synthetic"}), row)
        run.marker = "synthetic"
        run.direct = lambda method, args: {"items" if method == "list" else "results": [row]}
        with self.assertRaisesRegex(self.driver.CheckFailed, "forgotten_memory_visible"):
            run.absent("target")
        safe = self.driver.safe_reply({"items": [{"id": "b2f51c49-628f-4972-b0af-b5fd970a5a29", "content": "secret"}]})
        self.assertEqual(len(safe["items"]), 1)
        self.assertNotIn("secret", json.dumps(safe))

    def test_acknowledged_only_capture_is_not_pending(self):
        run = object.__new__(self.driver.Recovery)
        snapshot = {"commands": {"outbox": [{"state": "pending"}]},
                    "capture": [{"state": "acknowledged", "acknowledged": 1}]}
        with self.assertRaisesRegex(self.driver.CheckFailed, "durable_pending_capture"):
            run.pending(snapshot)
        snapshot["capture"].append({"state": "pending", "acknowledged": 0})
        run.pending(snapshot)

    def test_deleted_provisional_id_resolves_canonical_ack_identity(self):
        snapshot = {"commands": {
            "outbox": [{"memory_id": "local", "ack_canonical_id": "remote"},
                       {"memory_id": "canonical:remote", "ack_canonical_id": "remote"}],
            "memories": [{"id": "local", "remote_id": "remote", "deleted": True}],
            "tombstones": 0}}
        self.assertEqual(self.driver.target_aliases(snapshot, "local"), {"local", "remote"})
        run = object.__new__(self.driver.Recovery)
        run.marker = "synthetic"
        run.direct = lambda method, args: {"items" if method == "list" else "results": [{"id": "remote"}]}
        with self.assertRaisesRegex(self.driver.CheckFailed, "forgotten_memory_visible"):
            run.absent("local", snapshot)

    def test_zero_tombstones_require_actual_durable_delete_fence(self):
        before = {"commands": {"outbox": [], "memories": [], "tombstones": 0}}
        with self.assertRaisesRegex(self.driver.CheckFailed, "durable_delete_fence"):
            self.driver.require_delete_fence(before, "target")
        before["commands"]["outbox"] = [{"op": "forget", "memory_id": "canonical:target"}]
        self.driver.require_delete_fence(before, "target")

    def test_store_probe_has_hard_deadline_and_reaps_child(self):
        blocker = self.root / "blocked.py"
        blocker.write_text("import time\ntime.sleep(30)\n")
        started = time.monotonic()
        children = []
        original = self.driver.subprocess.Popen
        def child(*args, **kwargs):
            process = original(*args, **kwargs)
            children.append(process)
            return process
        with patch.object(self.driver, "__file__", str(blocker)), patch.object(
            self.driver.subprocess, "Popen", side_effect=child
        ):
            with self.assertRaisesRegex(self.driver.CheckFailed, "store_probe_timeout"):
                self.driver.store_probe("commands", {"path": str(self.root / "absent.db")}, timeout=0.1)
        self.assertLess(time.monotonic() - started, 3)
        self.assertEqual(len(children), 1)
        self.assertIsNotNone(children[0].poll())
        self.assertFalse((self.root / "absent.db").exists())

    def test_capture_and_mirror_probes_filter_and_report_missing_rows(self):
        capture = self.root / "capture.db"
        with contextlib.closing(sqlite3.connect(capture)) as connection:
            connection.executescript("""
              CREATE TABLE capture_event_spool(event_id TEXT, state TEXT, attempts INTEGER,
                acknowledged_at TEXT, enqueue_id INTEGER);
              INSERT INTO capture_event_spool VALUES('event-a','acknowledged',1,'now',1);
              INSERT INTO capture_event_spool VALUES('foreign','pending',0,NULL,2);
            """)
        result = self.driver.store_probe("capture", {"path": str(capture), "ids": ["event-a", "compacted"]})
        self.assertEqual([row["event_id"] for row in result["rows"]], ["event-a"])
        self.assertEqual(result["missing_or_compacted"], 1)
        mirror = self.root / "mirror.db"
        with contextlib.closing(sqlite3.connect(mirror)) as connection:
            connection.executescript("""
              CREATE TABLE edge_partitions(memory_space_id TEXT, scope TEXT, namespace TEXT,
                applied_revision INTEGER, active_generation INTEGER, snapshot_id TEXT,
                snapshot_revision INTEGER, sync_status TEXT);
              CREATE TABLE edge_memories(memory_space_id TEXT, scope TEXT, namespace TEXT,
                generation INTEGER, lifecycle_state TEXT, canonical_id TEXT);
              INSERT INTO edge_partitions VALUES('space','scope','namespace',9,2,NULL,NULL,'synced');
              INSERT INTO edge_memories VALUES('space','scope','namespace',2,'active','target');
              INSERT INTO edge_memories VALUES('space','scope','namespace',1,'active','interrupted');
              INSERT INTO edge_memories VALUES('space','scope','namespace',2,'active','foreign');
            """)
        result = self.driver.store_probe("mirror", {"path": str(mirror),
            "partition": ["space", "scope", "namespace"], "ids": ["target", "interrupted"]})
        self.assertEqual(result["active_target_ids"], ["target"])
        self.assertEqual(result["partition"]["applied_revision"], 9)

    def test_actual_mirror_is_required_instead_of_acknowledged_command_fallback(self):
        result = {"mode": "offline", "source": "acknowledged_commands",
                  "consistency": "bounded_stale", "history_available": False,
                  "partition_revision": None, "results": [{"id": "target"}]}
        with self.assertRaisesRegex(self.driver.CheckFailed, "actual_edge_mirror"):
            self.driver.require_mirror(result, "target", 3)
        result.update(source="edge_mirror", history_available=True, partition_revision=3)
        self.driver.require_mirror(result, "target", 3)
        result["results"] = []
        with self.assertRaises(self.driver.CheckFailed):
            self.driver.require_mirror(result, "target", 3)

    def test_gateway_is_restored_after_scenario_assertion_failure(self):
        run = object.__new__(self.driver.Recovery)
        calls = []
        run.service = lambda name, action: calls.append((name, action))
        with self.assertRaisesRegex(self.driver.CheckFailed, "synthetic_failure"):
            with run.outage():
                raise self.driver.CheckFailed("synthetic_failure")
        self.assertEqual(calls, [("gateway", "stop"), ("gateway", "start")])

    def test_unowned_or_mismatched_lifecycle_is_rejected_before_faults(self):
        run = object.__new__(self.driver.Recovery)
        run.state_dir = self.root
        run.host_config = self.root / "fixture" / "host.yaml"
        run.host_url = "http://127.0.0.1:4222"
        state = {"config": str(self.root / "different.yaml"), "urls": {"host": run.host_url},
                 "processes": [{"name": "gateway"}, {"name": "host"}]}
        with patch.object(self.driver.lifecycle, "read_state", return_value=state), patch.object(
            self.driver.lifecycle, "owns", return_value=True
        ), patch.object(self.driver.lifecycle, "service") as operation:
            with self.assertRaisesRegex(self.driver.CheckFailed, "fixture_lifecycle_mismatch"):
                run.preflight()
            operation.assert_not_called()

    def test_reports_are_private_and_do_not_claim_full_acceptance(self):
        run = object.__new__(self.driver.Recovery)
        run.output = self.root
        run.run_id = "synthetic"
        run.case_id = "case-a"
        run.observations = [{"kind": "check", "name": "synthetic_only"}]
        with patch.object(self.driver.subprocess, "check_output", return_value="revision\n"):
            path = run.save("outage", "failed", "actual_edge_mirror")
        report = json.loads(path.read_text())
        self.assertFalse(report["complete_L10_L12"])
        self.assertEqual(report["status"], "failed")
        self.assertTrue(report["unexercised"])
        self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)


if __name__ == "__main__":
    unittest.main()
