# Host memory V2 protocol and authority

Backplane's `:backplane_memory` app owns canonical events, memories, partitions,
entitlements, revisions, and governance. The host agent owns a durable capture
spool, a separate provisional command outbox, and a bounded, non-authoritative
edge mirror. The three stores have different replay and retention rules; none
is a second canonical memory database.

| Operation | Connected route and authority | Disconnected behavior |
|---|---|---|
| `memory::remember` / `memory::forget` | Host provisional write and `host_memory.v1` command upload; Backplane resolves the canonical partition and ID, and applies canonical forget | Queue the command in Turso; report provisional identity and pending canonical ACK |
| `memory::recall`, `list`, `stats` | Authenticated `memory_call` to Backplane and canonical partition; recall uses Recall V2 | Only allowlisted transport failures may read the active V2 mirror plus provisional overlay; report `bounded_stale` or `provisional_only` |
| `lifecycle_context` | Bounded `MemoryProxy` call to Backplane | The injection path uses its separate `RecallCache` fallback/fail-open policy; it does not read the V2 mirror |
| Slots and facets | Explicitly device-local `memory::*` operations | Device-local; no claim of canonical authority |
| Capture events | Durable capture spool, optionally encrypted when configured, then authenticated batch ingest | Spool until accepted/duplicate ACK; permanent rejects remain evidence |

Authorization, partition, validation, governance, and protocol errors never
trigger an offline read. The server derives `{memory_space_id, scope, namespace}`
from registered host entitlement; source project/runtime IDs remain provenance.
Host command ACKs include `canonical_id` and an optional positive `revision`.
Eligible host-origin episodic memories get a durable revision/receipt;
edge-ineligible canonical memories, including oversized items, remain valid and
receive an ID-only ACK. Duplicate source requests reuse the receipt. Host
command-store V3 persists `remote_revision` atomically with outbox settlement;
an invalid revision cannot settle the row.

## Negotiation and wire events

The host offers `memory_v2: {offers: ["host_memory.v2"],
max_frame_bytes: 524288, partitions: [...]}` on join, separately from the V1
`memory` block. Each partition claim carries exact space/scope/namespace,
`applied_revision`, and optional snapshot continuation. A new host may offer
none. The server selects exactly one protocol and returns its canonical
entitlement inventory, current revisions, status, and negotiated limits
(`max_changes <= 100`, `max_frame_bytes <= 524288`). A missing space ID is
resolved only when the other fields identify one active entitlement; ambiguous,
revoked, foreign, or conflicting claims are rejected. A selected V2 connection
never silently falls back to V1.

`memory_next` requests a partition and host `applied_revision` and returns
`current`, `delta`, or `snapshot_chunk`. Each materialized delivery has a
durable `batch_id`; retries of an outstanding batch return identical content.
`memory_available` is a content-free wakeup hint, never a delivery or cursor
advance. `memory_ack` sends `batch_id`, `status` (`applied` or `progress`),
`applied_revision`, and snapshot progress fields when applicable. The server
validates host, partition, issued batch, revision, and hash before advancing
its cursor; stale, future, invented, or conflicting ACKs cannot advance it.

The JSON wire shape below uses a canonical partition object
`{"memory_space_id":"uuid","scope":"proj_local","namespace":"private"}`.
`memory_next` sends `{"protocol":"host_memory.v2","partition":P,
"applied_revision":N}`; it may add `snapshot_id` and `next_chunk_index`
for continuation, and positive `max_changes`/`max_frame_bytes` requests.
A delta reply is `{"protocol":"host_memory.v2","status":"batch",
"kind":"delta","batch_id":"uuid","partition":P,
"from_revision":N+1,"to_revision":R,"changes":[{"revision":N+1,
"op":"upsert|delete","memory_id":"uuid","payload":{...}}]}`.
A snapshot reply is `{"protocol":"host_memory.v2","status":"batch",
"kind":"snapshot_chunk","batch_id":"uuid","partition":P,
"snapshot_id":"uuid","chunk_index":I,"chunk_count":C,
"item_count":T,"base_revision":N,"to_revision":R,
"chunk_hash":"sha256:...","integrity_hash":"sha256:...",
"items":[...]}`. `memory_ack` echoes `protocol`, `partition`, and
`batch_id`. Delta ACKs carry `status=applied`, `applied_revision=R`, and null
snapshot/hash fields. Snapshot ACKs echo `snapshot_id`, `chunk_hash`, and
`integrity_hash`, carry `next_chunk_index=I+1`, and use
`status=progress, applied_revision=N` until the last chunk, then
`status=applied, applied_revision=R`.

For a delta, changes are contiguous from `applied_revision + 1` and bounded by
both count and encoded bytes. The host commits changed rows, tombstones, and
its local cursor in one Turso transaction *before* ACK. An exact duplicate
mutates nothing. A forward gap or overlap marks `snapshot_required`; a delta
cannot merge into a staging snapshot. Deletes retain canonical ID/revision so
an old upsert cannot resurrect content.

A snapshot is materialized under the partition revision lock from eligible
canonical rows in deterministic ID order at revision R. The server stores
bounded chunks, SHA-256 chunk hashes, and an ordered manifest hash before
issuing a chunk. `snapshot_id` plus `next_chunk_index` resumes an issued
snapshot. The host writes chunks to a hidden generation; an intermediate
committed chunk ACK is `progress` and does not advance the server revision.
Only complete manifest verification and atomic active-generation flip yields
`applied` at R. Missing history, expired snapshot, or incompatible host state
restarts a fresh snapshot. Partial staging never appears in recall.

The exact chunk hash is `"sha256:" <> lowercase_hex(SHA256(canonical_json(
{"items": items})))`. Canonical JSON sorts object keys lexically at every
level, keeps array order, uses JSON string encoding for keys, and joins without
whitespace. The manifest hash is `"sha256:" <>
lowercase_hex(SHA256(chunk_hash_0 <> chunk_hash_1 <> ...))`, where each
`chunk_hash_i` is its full ASCII `sha256:` string in chunk-index order.
The host recomputes both hashes and the total item count before activation.

`invalid_request`, `unsupported_protocol`, `protocol_disabled`,
`unauthorized`, `partition_mismatch`, `ambiguous_partition`,
`partition_not_ready`, `invalid_ack`, `batch_not_found`, `batch_conflict`, and
`payload_too_large` are permanent protocol results. `storage_unavailable`,
`transaction_conflict`, and `snapshot_build_unavailable` are retryable server
results. Host recovery results include `duplicate`, `snapshot_required`,
`snapshot_restart_required`, `edge_protection_unavailable`,
`edge_storage_unavailable`, and `integrity_mismatch`. Error envelopes contain
bounded identifiers, never memory content or secrets.

## Compatibility and protection

`memory.host_sync_v1.enabled` defaults true for legacy fact/wipe reconciliation;
`memory.host_sync_v2.enabled` defaults false. V1 fact/wipe receipt hashes bind
issued payloads and never act as V2 cursors. V1 command upload remains the
provisional write path. The V2 mirror is a separate Turso database from both
the command store and capture spool, with item/byte/type quotas, priority and
expiry eviction, and active-generation reads.

Host edge persistence is default-disabled. Explicit plaintext opt-in works
only in dev/test and reports `plaintext_development`; production rejects it
before path creation, reports `protection_unavailable`, and keeps capture,
commands, and online recall available. Encryption support is tracked at
[concord#91](https://github.com/gsmlg-dev/concord/issues/91); the issue was
verified open during Task 18. No production plaintext fallback is approved.
See the [edge runbook](../operations/host-memory-edge-runbook.md) for recovery.
