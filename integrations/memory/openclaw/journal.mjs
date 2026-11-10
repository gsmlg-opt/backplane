import { DatabaseSync } from "node:sqlite";
import { mkdirSync, chmodSync } from "node:fs";
import { dirname } from "node:path";
import { canonicalJson, digest, uuid } from "./contract.mjs";

const RETRYABLE_ATTEMPTS = 12;

/** Ordered, immutable capture delivery state. Never used as a memory store. */
export class DeliveryJournal {
  constructor(path, identity, { maxEvents = 4096, maxBytes = 32 * 1024 * 1024 } = {}) {
    this.maxEvents = maxEvents;
    this.maxBytes = maxBytes;
    mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
    this.db = new DatabaseSync(path);
    chmodSync(path, 0o600);
    // `binding` is kept for journals written by the previous version; new rows store "{}".
    this.db.exec(`PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA busy_timeout=5000;
      PRAGMA journal_size_limit=16777216;
      CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY,value TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS delivery(
        sequence INTEGER PRIMARY KEY AUTOINCREMENT,event_id TEXT UNIQUE NOT NULL,
        path TEXT NOT NULL,payload TEXT NOT NULL,digest TEXT NOT NULL,binding TEXT NOT NULL,
        state TEXT NOT NULL DEFAULT 'local_pending',attempts INTEGER NOT NULL DEFAULT 0,
        next_at INTEGER NOT NULL DEFAULT 0,error_code TEXT,receipt TEXT);
      CREATE TABLE IF NOT EXISTS operations(identity TEXT PRIMARY KEY,digest TEXT NOT NULL,event_id TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS turns(identity TEXT PRIMARY KEY,payload TEXT NOT NULL,completed INTEGER NOT NULL DEFAULT 0);
      CREATE INDEX IF NOT EXISTS delivery_due ON delivery(state,next_at,sequence);`);
    const pageSize = this.db.prepare("PRAGMA page_size").get().page_size;
    this.db.exec(`PRAGMA max_page_count=${Math.max(256, Math.floor((maxBytes + 16 * 1024 * 1024) / pageSize))}`);
    try {
      this.transaction(() => {
        // Compare only what this version keys a journal by, so a journal written by
        // the previous version (which stored more identity fields) still opens.
        const saved = this.get("identity");
        if (saved && Object.keys(identity).some((key) => canonicalJson(saved[key] ?? null) !== canonicalJson(identity[key] ?? null))) throw new Error("journal_identity_changed");
        this.set("identity", identity);
        if (!this.get("installation_id")) this.set("installation_id", uuid());
        this.retireOldWork();
      });
      this.installationId = this.get("installation_id");
    } catch (error) { this.db.close(); throw error; }
  }
  retireOldWork() {
    // retired: the previous version mirrored native files through host source_* calls that no longer exist.
    this.db.exec(`DROP TABLE IF EXISTS sources;
      DELETE FROM delivery WHERE path NOT LIKE '/capture/%' AND state NOT IN ('canonical_committed','rejected','dead_letter');
      UPDATE delivery SET state='local_pending' WHERE state='deferred';
      DELETE FROM meta WHERE key LIKE 'binding:%' OR key LIKE 'native_blocked:%' OR key LIKE 'sequence:source:%';`);
  }
  transaction(fn) {
    if (this.inTransaction) return fn();
    this.db.exec("BEGIN IMMEDIATE");
    this.inTransaction = true;
    try { const result = fn(); this.db.exec("COMMIT"); return result; }
    catch (error) { if (this.db.isTransaction) this.db.exec("ROLLBACK"); throw error; }
    finally { this.inTransaction = false; }
  }
  get(key) {
    const row = this.db.prepare("SELECT value FROM meta WHERE key=?").get(key);
    return row ? JSON.parse(row.value) : undefined;
  }
  set(key, value) { this.db.prepare("INSERT INTO meta VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value").run(key, canonicalJson(value)); }
  next(key) {
    const value = (this.get(`sequence:${key}`) || 0) + 1;
    if (!Number.isSafeInteger(value)) throw new Error("sequence_exhausted");
    this.set(`sequence:${key}`, value);
    return value;
  }
  enqueue(eventId, path, payload) {
    return this.transaction(() => {
      const encoded = canonicalJson(payload);
      if (Buffer.byteLength(encoded) > 480000) throw new Error("payload_too_large");
      const hash = digest({ path, payload });
      const existing = this.db.prepare("SELECT digest FROM delivery WHERE event_id=?").get(eventId);
      if (existing) {
        if (existing.digest !== hash) throw new Error("immutable_event_conflict");
        return eventId;
      }
      const used = this.db.prepare("SELECT count(*) AS count,coalesce(sum(length(CAST(payload AS BLOB))),0) AS bytes FROM delivery WHERE state IN ('local_pending','host_accepted')").get();
      if (used.count >= this.maxEvents || used.bytes + Buffer.byteLength(encoded) > this.maxBytes) throw new Error("delivery_journal_full");
      this.db.prepare("INSERT INTO delivery(event_id,path,payload,digest,binding) VALUES (?,?,?,?,'{}')").run(eventId, path, encoded, hash);
      return eventId;
    });
  }
  operation(identity, immutable, prepare) {
    return this.transaction(() => {
      const hash = digest(immutable);
      const old = this.db.prepare("SELECT * FROM operations WHERE identity=?").get(identity);
      if (old) {
        if (old.digest !== hash) throw new Error("immutable_event_conflict");
        return old.event_id;
      }
      const eventId = prepare();
      this.db.prepare("INSERT INTO operations VALUES (?,?,?)").run(identity, hash, eventId);
      return eventId;
    });
  }
  /** Due rows in order; a pending row waiting for its retry holds every later row. */
  due(now = Date.now(), limit = 32) {
    return this.db.prepare(`SELECT * FROM delivery WHERE state IN ('local_pending','host_accepted') AND next_at<=?
      AND sequence<coalesce((SELECT min(sequence) FROM delivery WHERE state='local_pending' AND next_at>?),9223372036854775807)
      ORDER BY sequence LIMIT ?`).all(now, now, limit);
  }
  row(eventId) { return this.db.prepare("SELECT * FROM delivery WHERE event_id=?").get(eventId); }
  /** Record a host receipt; `delay` is when a host_accepted row next asks whether it committed. */
  settle(eventId, state, receipt = {}, { delay = 500 } = {}) {
    if (!["host_accepted", "canonical_committed", "rejected"].includes(state)) throw new Error("invalid_delivery_receipt");
    this.db.prepare("UPDATE delivery SET state=?,receipt=?,next_at=?,error_code=? WHERE event_id=?")
      .run(state, canonicalJson(receipt), Date.now() + delay, state === "rejected" ? (receipt.error_code || "request_rejected") : null, eventId);
  }
  fail(eventId, code, { terminal = false } = {}) {
    const row = this.row(eventId);
    const attempts = row.attempts + 1;
    const exhausted = !terminal && attempts >= RETRYABLE_ATTEMPTS;
    const state = terminal ? "rejected" : exhausted ? "dead_letter" : row.state;
    this.db.prepare("UPDATE delivery SET state=?,attempts=?,error_code=?,next_at=? WHERE event_id=?")
      .run(state, attempts, exhausted ? "retry_exhausted" : code, Date.now() + Math.min(300000, 1000 * 2 ** Math.min(attempts, 8)), eventId);
  }
  close() { if (this.db) { this.db.close(); this.db = null; } }
}
