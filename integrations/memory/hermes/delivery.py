"""Profile-local delivery journal. This is transport state, never a recall store."""

from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import threading
import time
import uuid


def canonical_json(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":"))


class DeliveryJournal:
    def __init__(self, path, binding, *, max_pending=4096, max_bytes=32 * 1024 * 1024):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(self.path.parent, 0o700)
        self.lock = threading.RLock()
        self.max_pending, self.max_bytes = max_pending, max_bytes
        self.db = sqlite3.connect(str(self.path), timeout=5, check_same_thread=False, isolation_level=None)
        self.db.row_factory = sqlite3.Row
        os.chmod(self.path, 0o600)
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA synchronous=FULL")
        self.db.execute("PRAGMA journal_size_limit=16777216")
        page_size = self.db.execute("PRAGMA page_size").fetchone()[0]
        self.db.execute("PRAGMA max_page_count=" + str(max(256, max_bytes // page_size)))
        self.db.executescript("""
            CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS delivery (
                event_id TEXT PRIMARY KEY, path TEXT NOT NULL, payload TEXT NOT NULL,
                digest TEXT NOT NULL, state TEXT NOT NULL DEFAULT 'local_pending',
                attempts INTEGER NOT NULL DEFAULT 0, next_at REAL NOT NULL DEFAULT 0,
                receipt TEXT, error_code TEXT, created_at REAL NOT NULL);
            CREATE INDEX IF NOT EXISTS delivery_due ON delivery(state,next_at);
            CREATE TABLE IF NOT EXISTS source_entries (
                target TEXT NOT NULL, entry_id TEXT PRIMARY KEY, content TEXT NOT NULL,
                active INTEGER NOT NULL, revision INTEGER NOT NULL, retired INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE IF NOT EXISTS source_aliases (
                target TEXT NOT NULL, content TEXT NOT NULL, entry_id TEXT NOT NULL,
                PRIMARY KEY(target,content,entry_id));
            CREATE TABLE IF NOT EXISTS source_chains (
                entry_id TEXT PRIMARY KEY, target TEXT NOT NULL, expected_content TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS callbacks (
                id INTEGER PRIMARY KEY AUTOINCREMENT, target TEXT NOT NULL,
                payload TEXT NOT NULL, processed INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE IF NOT EXISTS messages (
                identity TEXT PRIMARY KEY, digest TEXT NOT NULL, text_digest TEXT NOT NULL, revision INTEGER NOT NULL,
                event_id TEXT NOT NULL, author TEXT);
            CREATE TABLE IF NOT EXISTS sessions (
                session_id TEXT PRIMARY KEY, snapshot TEXT NOT NULL);
        """)
        try:
            with self.transaction():
                # Existing journals already have SQLite insertion rowids. Backfill
                # them once without touching immutable payloads or wall timestamps.
                columns = {row[1] for row in self.db.execute('PRAGMA table_info(delivery)')}
                if 'queue_sequence' not in columns:
                    self.db.execute('ALTER TABLE delivery ADD COLUMN queue_sequence INTEGER')
                    self.db.execute('UPDATE delivery SET queue_sequence=rowid')
                self.db.execute('CREATE UNIQUE INDEX IF NOT EXISTS delivery_order ON delivery(queue_sequence)')
                last = self.db.execute('SELECT coalesce(max(queue_sequence),0) FROM delivery').fetchone()[0]
                self.set('sequence:delivery', max(last, int(self.get('sequence:delivery', '0'))))
                saved = self.get("binding")
                if saved and saved != canonical_json(binding):
                    raise ValueError("journal_binding_changed")
                self.set("binding", canonical_json(binding))
                for key in ("installation_id", "profile_id"):
                    if not self.get(key):
                        self.set(key, str(uuid.uuid4()))
                self.installation_id, self.profile_id = self.get("installation_id"), self.get("profile_id")
        except BaseException:
            self.db.close()
            raise

    @contextmanager
    def transaction(self):
        with self.lock:
            nested = self.db.in_transaction
            if not nested:
                self.db.execute("BEGIN IMMEDIATE")
            try:
                yield self
                if not nested:
                    self.db.execute("COMMIT")
            except BaseException:
                if not nested and self.db.in_transaction:
                    self.db.execute("ROLLBACK")
                raise

    def get(self, key, default=None):
        with self.lock:
            row = self.db.execute("SELECT value FROM meta WHERE key=?", (key,)).fetchone()
            return row[0] if row else default

    def set(self, key, value):
        with self.lock:
            self.db.execute("INSERT INTO meta VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", (key, str(value)))

    def sequence(self, key):
        value = int(self.get("sequence:" + key, "0")) + 1
        self.set("sequence:" + key, value)
        return value

    def enqueue(self, event_id, path, payload):
        encoded = canonical_json(payload)
        digest = hashlib.sha256((path + "\n" + encoded).encode()).hexdigest()
        with self.transaction():
            row = self.db.execute("SELECT digest FROM delivery WHERE event_id=?", (event_id,)).fetchone()
            if row:
                if row[0] != digest:
                    raise ValueError("immutable_event_conflict")
                return event_id
            count, size = self.db.execute("SELECT count(*),coalesce(sum(length(CAST(payload AS BLOB))),0) FROM delivery WHERE state!='canonical_committed'").fetchone()
            if count >= self.max_pending or size + len(encoded.encode()) > self.max_bytes:
                raise RuntimeError("delivery_journal_full")
            self.db.execute("INSERT INTO delivery(event_id,path,payload,digest,created_at,queue_sequence) VALUES (?,?,?,?,?,?)", (event_id, path, encoded, digest, time.time(), self.sequence('delivery')))
        return event_id

    def pending(self, *, now=None, limit=32):
        with self.lock:
            now = time.time() if now is None else now
            # Unaccepted work in backoff fences all later unsent stages. Already
            # host-accepted work may poll independently of subsequent handoffs.
            return [dict(row) for row in self.db.execute("SELECT * FROM delivery WHERE state IN ('local_pending','host_accepted') AND next_at<=? AND queue_sequence<coalesce((SELECT min(queue_sequence) FROM delivery WHERE state='local_pending' AND next_at>?),9223372036854775807) ORDER BY queue_sequence LIMIT ?", (now, now, limit))]

    def retry(self, event_id, code, *, now=None):
        with self.transaction():
            row = self.db.execute("SELECT attempts FROM delivery WHERE event_id=?", (event_id,)).fetchone()
            attempts = row[0] + 1
            state = "rejected" if attempts >= 12 else None
            deadline = (time.time() if now is None else now) + min(300, 2 ** min(attempts, 8))
            self.db.execute("UPDATE delivery SET attempts=?,next_at=?,error_code=?,state=coalesce(?,state) WHERE event_id=?", (attempts, deadline, "retry_exhausted" if state else code, state, event_id))

    def accept(self, event_id, receipt):
        status = receipt.get("status")
        state = {"pending": "host_accepted", "committed": "canonical_committed", "rejected": "rejected"}.get(status)
        if not state:
            raise ValueError("invalid_delivery_receipt")
        safe = {key: receipt[key] for key in ("status", "command_id", "canonical_id", "event_id", "outcome", "revision", "source_revision", "authority", "consistency") if key in receipt}
        code = "request_rejected" if receipt.get("error_code") else None
        if code:
            safe["error_code"] = code
        with self.transaction():
            self.db.execute("UPDATE delivery SET state=?,receipt=?,next_at=?,error_code=? WHERE event_id=?", (state, canonical_json(safe), time.time() + 1, code, event_id))

    def reject(self, event_id, code):
        with self.lock:
            self.db.execute("UPDATE delivery SET state='rejected',error_code=? WHERE event_id=?", (code, event_id))

    def status(self):
        with self.lock:
            counts = dict(self.db.execute("SELECT state,count(*) FROM delivery GROUP BY state"))
            errors = [row[0] for row in self.db.execute("SELECT DISTINCT error_code FROM delivery WHERE error_code IS NOT NULL")]
            unprocessed = self.db.execute("SELECT count(*) FROM callbacks WHERE processed=0").fetchone()[0]
            unprocessed += self.db.execute("SELECT count(*) FROM source_chains").fetchone()[0]
        return {**{key: counts.get(key, 0) for key in ("local_pending", "host_accepted", "canonical_committed", "rejected", "capture_deferred")}, "pending_reconciliation": unprocessed, "error_codes": errors, "source_snapshots": {target: self.get("source-state:" + target, "unverified") for target in ("memory", "user")}, "source_ambiguities": {target: int(self.get("source-ambiguities:" + target, "0")) for target in ("memory", "user")}, "capture_binding": self.get("capture_binding_state", "unverified")}

    def prune(self, retain=1024):
        with self.transaction():
            self.db.execute("DELETE FROM delivery WHERE event_id IN (SELECT event_id FROM (SELECT event_id,row_number() OVER (ORDER BY queue_sequence DESC) AS n,sum(length(CAST(payload AS BLOB))) OVER (ORDER BY queue_sequence DESC) AS bytes FROM delivery WHERE state='canonical_committed') WHERE n>? OR bytes>4194304)", (retain,))
            self.db.execute("DELETE FROM callbacks WHERE id IN (SELECT id FROM (SELECT id,row_number() OVER (ORDER BY id DESC) AS n,sum(length(CAST(payload AS BLOB))) OVER (ORDER BY id DESC) AS bytes FROM callbacks WHERE processed=1) WHERE n>? OR bytes>4194304)", (retain,))

    def close(self):
        with self.lock:
            if self.db is not None:
                self.db.close()
                self.db = None
