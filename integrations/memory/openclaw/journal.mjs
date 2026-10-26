import { DatabaseSync } from "node:sqlite";
import { mkdirSync, chmodSync } from "node:fs";
import { dirname } from "node:path";
import { canonicalJson, digest, uuid } from "./contract.mjs";

/** Immutable delivery and source/cursor state only. Never used as a recall store. */
export class DeliveryJournal {
  constructor(path, identity, { maxEvents = 4096, maxBytes = 32 * 1024 * 1024 } = {}) {
    this.maxEvents = maxEvents;
    this.maxBytes = maxBytes;
    mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
    this.db = new DatabaseSync(path);
    chmodSync(path, 0o600);
    this.db.exec(`PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA busy_timeout=5000;
      PRAGMA journal_size_limit=16777216;
      CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY,value TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS delivery(
        sequence INTEGER PRIMARY KEY AUTOINCREMENT,event_id TEXT UNIQUE NOT NULL,
        path TEXT NOT NULL,payload TEXT NOT NULL,digest TEXT NOT NULL,binding TEXT NOT NULL,
        state TEXT NOT NULL DEFAULT 'local_pending',attempts INTEGER NOT NULL DEFAULT 0,
        next_at INTEGER NOT NULL DEFAULT 0,error_code TEXT,receipt TEXT);
      CREATE TABLE IF NOT EXISTS operations(identity TEXT PRIMARY KEY,digest TEXT NOT NULL,event_id TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS sources(namespace TEXT NOT NULL,target TEXT NOT NULL,entry_id TEXT PRIMARY KEY,
        revision INTEGER NOT NULL DEFAULT 0,active INTEGER NOT NULL DEFAULT 0,content_hash TEXT,
        canonical_id TEXT,kind TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS turns(identity TEXT PRIMARY KEY,payload TEXT NOT NULL,completed INTEGER NOT NULL DEFAULT 0);
      CREATE INDEX IF NOT EXISTS delivery_due ON delivery(state,next_at,sequence);`);
    const pageSize = this.db.prepare("PRAGMA page_size").get().page_size;
    this.db.exec(`PRAGMA max_page_count=${Math.max(256, Math.floor((maxBytes + 16 * 1024 * 1024) / pageSize))}`);
    try {
      this.transaction(() => {
        const saved = this.get("identity");
        if (saved && canonicalJson(saved) !== canonicalJson(identity)) throw new Error("journal_identity_changed");
        this.set("identity", identity);
        if (!this.get("installation_id")) this.set("installation_id", uuid());
      });
      this.installationId = this.get("installation_id");
    } catch (error) { this.db.close(); throw error; }
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
  enqueue(eventId, path, payload, binding) {
    return this.transaction(() => {
      const encoded = canonicalJson(payload);
      if (Buffer.byteLength(encoded) > 480000) throw new Error("payload_too_large");
      const hash = digest({ path, payload, binding });
      const existing = this.db.prepare("SELECT digest FROM delivery WHERE event_id=?").get(eventId);
      if (existing) {
        if (existing.digest !== hash) throw new Error("immutable_event_conflict");
        return eventId;
      }
      const used = this.db.prepare("SELECT count(*) AS count,coalesce(sum(length(CAST(payload AS BLOB))),0) AS bytes FROM delivery WHERE state!='canonical_committed'").get();
      if (used.count >= this.maxEvents || used.bytes + Buffer.byteLength(encoded) > this.maxBytes) throw new Error("delivery_journal_full");
      this.db.prepare("INSERT INTO delivery(event_id,path,payload,digest,binding) VALUES (?,?,?,?,?)").run(eventId, path, encoded, hash, canonicalJson(binding));
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
  due(now = Date.now(), limit = 32) {
    return this.db.prepare(`SELECT * FROM delivery WHERE state IN ('local_pending','host_accepted','deferred') AND next_at<=?
      AND sequence<coalesce((SELECT min(sequence) FROM delivery WHERE state IN ('local_pending','deferred') AND next_at>?),9223372036854775807)
      ORDER BY sequence LIMIT ?`).all(now, now, limit);
  }
  row(eventId) { return this.db.prepare("SELECT * FROM delivery WHERE event_id=?").get(eventId); }
  accept(eventId, receipt) {
    const state = { pending: "host_accepted", committed: "canonical_committed", rejected: "rejected" }[receipt.status];
    if (!state || receipt.event_id !== eventId) throw new Error("invalid_delivery_receipt");
    const safe = Object.fromEntries(["protocol", "event_id", "status", "canonical_id", "command_id", "outcome", "revision", "source_revision", "authority", "consistency"].filter((key) => receipt[key] !== undefined).map((key) => [key, receipt[key]]));
    this.transaction(() => {
      this.db.prepare("UPDATE delivery SET state=?,receipt=?,next_at=?,error_code=? WHERE event_id=?")
        .run(state, canonicalJson(safe), Date.now() + 500, state === "rejected" ? "request_rejected" : null, eventId);
      if (receipt.canonical_id) {
        const payload = JSON.parse(this.row(eventId).payload);
        if (payload.entry_id) this.db.prepare("UPDATE sources SET canonical_id=? WHERE entry_id=?").run(receipt.canonical_id, payload.entry_id);
        for (const entry of payload.entries || []) this.db.prepare("UPDATE sources SET canonical_id=coalesce(canonical_id,?) WHERE entry_id=?").run(receipt.canonical_id, entry.entry_id);
      }
    });
  }
  fail(eventId, code, { terminal = false, deferred = false } = {}) {
    const row = this.row(eventId);
    const attempts = row.attempts + (deferred ? 0 : 1);
    const state = terminal ? "rejected" : attempts >= 12 ? "dead_letter" : deferred ? "deferred" : row.state;
    this.db.prepare("UPDATE delivery SET state=?,attempts=?,error_code=?,next_at=? WHERE event_id=?")
      .run(state, attempts, attempts >= 12 ? "retry_exhausted" : code, Date.now() + Math.min(300000, 1000 * 2 ** Math.min(attempts, 8)), eventId);
  }
  sources(namespace) { return this.db.prepare("SELECT * FROM sources WHERE namespace=?").all(namespace); }
  status() {
    const counts = Object.fromEntries(this.db.prepare("SELECT state,count(*) AS count FROM delivery GROUP BY state").all().map((row) => [row.state, row.count]));
    const errors = this.db.prepare("SELECT DISTINCT error_code FROM delivery WHERE error_code IS NOT NULL").all().map((row) => row.error_code);
    return { ...Object.fromEntries(["local_pending", "host_accepted", "canonical_committed", "deferred", "rejected", "dead_letter"].map((state) => [state, counts[state] || 0])), error_codes: errors };
  }
  close() { if (this.db) { this.db.close(); this.db = null; } }
}
