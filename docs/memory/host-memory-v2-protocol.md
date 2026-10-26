# Host memory protocol and authority

Backplane's `:backplane_memory` app owns canonical events, memories, partitions,
entitlements, revisions, and governance. The host agent owns a durable capture
spool, a separate provisional command outbox, and a bounded, non-authoritative
edge mirror. The three stores have different replay and retention rules; none
is a second canonical memory database.

| Operation | Connected route and authority | Disconnected behavior |
|---|---|---|
| `memory::remember` / `memory::forget` | Authenticated default or selected Access authority and immutable `memory_commands.v2` upload; Backplane resolves the canonical ID and applies canonical forget | Queue under the authenticated access/version/partition; report command identity and pending canonical ACK |
| `memory::recall`, `list`, `stats` | Authenticated `memory_call` to Backplane and canonical partition; recall uses Recall V2 | Only allowlisted transport failures may read the authorized active V2 mirror plus command overlay; cold authority and unavailable mirror fail closed |
| `lifecycle_context` | Bounded `MemoryProxy` call to Backplane | The injection path uses its separate `RecallCache` fallback/fail-open policy; it does not read the V2 mirror |
| `facet_tag` / `facet_query` | Canonical-only authenticated HubProxy operations; no provisional local facet store | Return connection error; no local fallback |
| Slots | Explicitly device-local `memory::*` operations | Device-local; no claim of canonical authority |
| Capture events | Durable capture spool, optionally encrypted when configured, then authenticated batch ingest | Spool until accepted/duplicate ACK; permanent rejects remain evidence |

Authorization, partition, validation, governance, and protocol errors never
trigger an offline read. The server derives `{memory_space_id, scope, namespace}`
from registered host entitlement; source project/runtime IDs remain provenance.
Host command ACKs bind the command ID, access ID, authority version and partition.
A committed ACK includes a canonical UUID and either a positive causal revision
with `mirror_status: "revisioned"`, or null revision with the explicit
`mirror_status: "not_eligible"`. The latter is a successful canonical mutation,
not a retryable transport failure. Exact retries return the saved receipt.
Deduplicated remembers receive a causal change for that command only when the
proposed row remains mirror eligible; no stale revision is substituted.

Default API responses keep `id`, bound `scope`, `sync_state` and `dedup` as
projections of this same command receipt. A pending remember's `id` is the command
UUID; after settlement it is the canonical ID. `dedup` reports reuse of the same
caller request key, not an inferred canonical success. Repeated saves without a
request key can create distinct commands that canonical settlement later deduplicates.
A forget of a pending command UUID retains an immutable remember dependency and
waits for that exact command's outcome; it never cancels an unacknowledged write.

## Access and commands

The [shared-access design](shared-host-access-design.md) supplies
`memory_access.v1` and `memory_commands.v2`. Both default private and explicitly
selected mutations use this single path. A host selects a registered entitlement with optional `memory_access_id`
on recall/list/stats/remember/forget. The server derives its exact canonical
partition and requires the matching independent capability; `deliver` additionally
requires `read`. Remember-only and forget-only grants disclose no existing content.
Omitting the selector retains the host's existing default private target.

Extended requests bind access ID and authority version. Mutations use immutable,
durable `memory_commands.v2` envelopes; reads, deliveries and ACKs carry the same
authority claim. Capability changes and revoke/regrant advance the version.
Revoke fences host mirrors and provisional overlays without deleting canonical
data. A regrant cannot revive commands, snapshots or ACKs from an older version.
Shared offline read leases default to zero and are bounded at 300 seconds; only
fresh authenticated authority can issue a lease. Cold shared startup is closed
until negotiation. See the design for complete envelopes, persistence and races.

## Negotiation and wire events

The host offers `memory_v2: {offers: ["host_memory.v2"],
max_frame_bytes: 524288, partitions: [...],
extensions: ["memory_access.v1", "memory_commands.v2"]}` on join.
The retired V1 `memory` offer is rejected. Each partition claim carries exact space/scope/namespace,
`applied_revision`, and optional snapshot continuation. A new host may offer
none. The server selects exactly one protocol and returns its canonical
entitlement inventory, current revisions, status, and negotiated limits
(`max_changes <= 100`, `max_frame_bytes <= 524288`). A missing space ID is
resolved only when the other fields identify one active entitlement; ambiguous,
revoked, foreign, or conflicting claims are rejected. The runtime has no V1 fallback.

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

## Configuration and protection

`memory.host_sync.enabled` is the single mirror-delivery control and defaults
true. Version-named settings are neither read nor migrated. Authenticated Access
and commands negotiate independently of that switch. With
mirror delivery disabled, the inventory exposes no `deliver` capability, no
delivery partitions and zero offline read lease; `memory_next` and `memory_ack`
return `protocol_disabled`. Enabling commands never enables an unprotected mirror.
V1 uploader, facts, wipes, receipts and reconciliation are retired runtime paths.
The edge mirror remains a separate protected Turso database with item/byte/type
quotas, priority and expiry eviction, and active-generation reads.

Command-store migration V7 preserves unbound historical rows and quarantines
unsettled rows instead of guessing their original authority. See the
[operator recovery boundary](../operations/host-memory-edge-runbook.md#retired-command-quarantine).
Old canonical `RememberRequest` records remain intact for verified historical
receipt lookup. Numeric migration versions and independent `memory_access.v1`,
source and capture protocol versions are not retired by this change.

Host edge persistence is default-disabled. Explicit plaintext opt-in works
only in dev/test and reports `plaintext_development`; production rejects it
before path creation, reports `protection_unavailable`, and keeps capture,
commands, and online recall available. Encryption support is tracked at
[concord#91](https://github.com/gsmlg-dev/concord/issues/91); the issue was
verified open during Task 18. No production plaintext fallback is approved.
See the [edge runbook](../operations/host-memory-edge-runbook.md) for recovery.
