# Host memory edge operations

Run source commands from the repository root; inspect a host's YAML and its
actual `work_dir` before opening a database. Preserve host identity, capture
spool, command store, and edge database separately. Never edit a live Turso
file. Back up and stop the host agent before any local database inspection.
Production plaintext edge persistence is blocked while
[concord#91](https://github.com/gsmlg-dev/concord/issues/91) remains open.

## Diagnose a stuck cursor or stale mirror

Use read-only server queries with the exact host and partition; do not infer
entitlement from a scope string. A cursor can legitimately lag during outage.

```sh
psql "$DATABASE_URL" -v host_id=HOST_UUID -v space_id=SPACE_UUID \
  -v scope=SCOPE -v namespace=NAMESPACE -v ON_ERROR_STOP=1 <<'SQL'
SELECT r.current_revision, r.first_available_revision,
       c.applied_revision, c.acknowledged_at,
       r.current_revision - COALESCE(c.applied_revision,0) AS lag,
       c.active_snapshot_id, c.snapshot_next_chunk_index
FROM bpm_memory_partition_revisions r
LEFT JOIN bpm_host_memory_cursors c
  ON c.host_id=:'host_id'::uuid AND c.memory_space_id=r.memory_space_id
 AND c.scope=r.scope AND c.namespace=r.namespace
WHERE r.memory_space_id=:'space_id'::uuid
  AND r.scope=:'scope' AND r.namespace=:'namespace';

SELECT id, kind, status, from_revision, to_revision, snapshot_id,
       chunk_index, issued_at, acknowledged_at
FROM bpm_host_memory_deliveries
WHERE host_id=:'host_id'::uuid AND memory_space_id=:'space_id'::uuid
  AND scope=:'scope' AND namespace=:'namespace'
ORDER BY issued_at DESC LIMIT 20;
SQL
```

Compare each exact host diagnostic `edge.partitions[]` entry's
`applied_revision` and `last_sync_at`, along with aggregate `edge.items`/
`edge.bytes`, protection status, and snapshot progress, with these rows. A pending
issued delivery should be retried byte-for-byte by `memory_next`. Check the
connection's selected protocol, host entitlement, edge Syncer status/backoff,
and the server's `partition_not_ready` issues before intervention. A wakeup
hint is not proof of delivery. A stale mirror may be expected when the host is
offline; online recall must still use Backplane.

For retention or snapshot expiry, inspect the exact partition's materialized
snapshots and ordered chunks; a ready snapshot is the recovery baseline after
old changes are pruned:

```sh
psql "$DATABASE_URL" -v space_id=SPACE_UUID -v scope=SCOPE \
  -v namespace=NAMESPACE -v ON_ERROR_STOP=1 <<'SQL'
SELECT s.id, s.revision, s.status, s.item_count, s.chunk_count,
       s.expires_at, count(c.chunk_index) AS stored_chunks
FROM bpm_memory_snapshots s
LEFT JOIN bpm_memory_snapshot_chunks c ON c.snapshot_id=s.id
WHERE s.memory_space_id=:'space_id'::uuid
  AND s.scope=:'scope' AND s.namespace=:'namespace'
GROUP BY s.id ORDER BY s.revision DESC LIMIT 20;
SQL
```

## Force a recoverable snapshot

First save the cursor, issued delivery, partition revision, and host diagnostic
evidence. Revoke/repair entitlement or backfill issues before retrying. The
server selects a snapshot automatically when the host cursor is behind
`first_available_revision`, ahead of the server, or inconsistent with retained
history. If an operator must force that path, perform a reviewed transaction
for **one host and exact partition** after the host agent is stopped: expire
its issued delivery and clear its acknowledgement/snapshot continuation. The
next V2 `memory_next` then builds a fresh snapshot while retaining the last
acknowledged revision for audit. Use a restore-tested backup and operator
review:

```sh
psql "$DATABASE_URL" -v host_id=HOST_UUID -v space_id=SPACE_UUID \
  -v scope=SCOPE -v namespace=NAMESPACE -v ON_ERROR_STOP=1 <<'SQL'
BEGIN;
UPDATE bpm_host_memory_deliveries SET status='expired'
WHERE host_id=:'host_id'::uuid AND memory_space_id=:'space_id'::uuid
  AND scope=:'scope' AND namespace=:'namespace' AND status='issued';
UPDATE bpm_host_memory_cursors
SET acknowledged_at=NULL, active_snapshot_id=NULL,
    snapshot_next_chunk_index=NULL
WHERE host_id=:'host_id'::uuid AND memory_space_id=:'space_id'::uuid
  AND scope=:'scope' AND namespace=:'namespace';
COMMIT;
SQL
```

There is no `edge repair` Mix task. Do not force a server snapshot while the
host is running or claim it is active before the final ACK.

## Dead-letter command and retention recovery

Inspect a command failure and correct its cause before requeue. The existing
source task requeues all dead-lettered command outbox rows by default or one
specific sequence; it does **not** requeue capture-spool dead letters:

```sh
devenv shell -- mix do --app backplane_host_agent cmd mix agent.memory.resync --seq SEQ
```

Use the deployment's configured environment for a real host. Do not delete
tombstones or change canonical events. The server retention
worker keeps a recoverable snapshot frontier before pruning old changes;
`first_available_revision` advances only with actual pruning. If a host falls
behind that frontier, allow a new snapshot. Inspect `bpm_memory_snapshots`
and `bpm_memory_snapshot_chunks` before deleting anything; active/issued
snapshots are not repair trash. Capture-spool dead letters require source
correction and approved replay, not this command.

## Protection incident and rollback

If diagnostics show `protection_unavailable`, leave edge sync disabled. Check
that the edge path was not created, and confirm command upload, capture, and
online recall still work. `plaintext_development` is allowed only in dev/test;
never copy such a database into production. Preserve files and access logs for
incident review, then remove exposed copies only under the incident plan.

Server migrations through `20260905000010` and host command V3 are additive.
Migration `20260905000011` replaces the action-edge partition guard with the
same rejection contract and has no down path; do not infer that an older binary
understands every new ACK or edge record.
For rollback, disable `memory.host_sync_v2.enabled`, keep V1 command upload,
and disable host edge config; stop/restart hosts under the compatible binary
after backing up all three stores. Preserve canonical accepted events and
issued delivery evidence. Follow the [release rollback procedure](../deploy/memory-v2-release.md)
for a schema boundary; migrations 00007 and 00011 have no down path. Do not run
a blind `ecto.rollback` or discard an unacknowledged spool.
