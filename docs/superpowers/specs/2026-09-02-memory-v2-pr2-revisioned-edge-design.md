# Memory V2 PR2 Revisioned Edge Design

- **Status:** Proposed concrete implementation design constrained by the accepted Memory V2 handoff and ADRs
- **Date:** 2026-09-02
- **Branch:** `codex/memory-v2-pr2-revisioned-edge`
- **Authority:** Backplane is canonical; host-agent mirror state is transport-bounded, non-authoritative, and disposable

## Goal

Implement `host_memory.v2` as a monotonic, durable, transport-bounded convergence protocol. Backplane records every edge-visible canonical memory transition in the same PostgreSQL transaction as the memory mutation. An entitled host pulls bounded delta or snapshot deliveries, commits them to a separate Turso edge database, and ACKs only after that commit. Offline recall reads only the committed active edge generation and labels it `bounded_stale`. PR3 adds final persistent item/byte/type quotas and eviction policy; PR2 is development/test-only while that bound and production protection remain incomplete.

PR2 does not enable a plaintext production mirror. The accepted protection ADR permits schema and protocol work only behind an explicit development/test plaintext opt-in while `gsmlg-dev/concord#91` remains open. Production edge persistence must fail closed.

## Fixed requirements

1. `memory_space_id` is the canonical owner. `host_id` is provenance and delivery identity.
2. Source runtime, project, and source scope remain provenance and never grant authority.
3. Revisions belong to `{memory_space_id, scope, namespace}`.
4. Change rows and canonical mutations commit atomically.
5. Host applied revision advances in the same Turso transaction as the applied delta or activated snapshot.
6. Server cursor advances only after a valid ACK for a durably issued delivery.
7. A gap, compacted history, unknown cursor, or interrupted incompatible snapshot recovers through a snapshot.
8. Hashes validate materialized snapshot integrity; a v1 fact-set hash never becomes a v2 cursor.
9. Capture spool, command outbox, and edge mirror remain separate stores.
10. V1 command upload remains compatible. V2 owns only canonical server-to-host mirror convergence.

## Selected interface

Three alternatives were reviewed:

1. pull-based durable `next/ack`;
2. connection-scoped server push;
3. per-host durable mailboxes.

The selected design is pull-based because correctness remains entirely in durable state and reconnect behavior is identical to normal operation. A content-free `memory_available` notification may wake the pull loop, but losing it cannot lose data.

### Server seam

```elixir
defmodule Backplane.Memory.EdgeSync do
  @spec negotiate(Ecto.UUID.t(), map()) ::
          {:ok, map()} | {:error, %{code: atom(), retryable: boolean()}}

  @spec next(Ecto.UUID.t(), map()) ::
          {:ok, map()} | {:error, %{code: atom(), retryable: boolean()}}

  @spec ack(Ecto.UUID.t(), map()) ::
          {:ok,
           %{
             status: :progress | :advanced | :duplicate,
             applied_revision: non_neg_integer(),
             next_chunk_index: non_neg_integer() | nil
           }}
          | {:error, %{code: atom(), retryable: boolean()}}
end
```

`negotiate/2` selects one protocol and returns the canonical entitled partition inventory and server limits. `next/2` resolves the authenticated host entitlement, locks or creates its durable cursor, returns any outstanding delivery, and otherwise issues exactly one bounded delta or materialized snapshot chunk. `ack/2` verifies the issued delivery. An intermediate snapshot ACK records durable chunk progress only; only a delta commit or final activated-snapshot ACK advances the server cursor.

The Channel does not implement partition, revision, snapshot, or ACK policy.

### Host seam

```elixir
defmodule Backplane.HostAgent.Memory.Mirror do
  @spec offer(keyword()) :: {:ok, map()} | {:error, term()}
  @spec apply_delivery(map(), keyword()) :: {:ok, map()} | {:error, term()}
  @spec offline_read("recall" | "list" | "stats", map(), keyword()) ::
          {:ok, map()} | {:error, term()}
end
```

`offer/1` reads durable local partition/cursor/snapshot state. `apply_delivery/2` validates and commits a delta or snapshot chunk. Delta commit and final snapshot activation return an ACK; an intermediate snapshot chunk returns a continuation/progress payload that cannot advance the server cursor. `offline_read/3` reads only the active generation and returns canonical stale metadata. Callers cannot advance cursors or activate partial snapshots through smaller public operations.

`Mirror` is stateless. A separate `Backplane.HostAgent.Memory.Edge.Syncer` process has the runtime responsibility for independent edge polling, wakeup hints, backoff, and protection/storage failures. The existing command `Memory.Syncer` remains solely responsible for the command outbox, allowing PR3 to change its retry/dead-letter behavior independently. The Turso transaction serializes edge writes.

## Canonical identity foundation

The durable registry belongs in `backplane_system`, which is below both `backplane_skills` and `backplane_memory` in the umbrella dependency graph.

### Tables

```text
bpm_memory_spaces
  id uuid primary key
  kind private | shared
  status active | disabled
  inserted_at / updated_at

bpm_memory_space_entitlements
  memory_space_id
  host_id
  scope
  namespace
  default_capture boolean
  status active | revoked
  inserted_at / updated_at
  unique(memory_space_id, host_id, scope, namespace)

bpm_memory_space_legacy_aliases
  alias_type
  alias_value
  memory_space_id
  unique(alias_type, alias_value)

bpm_memory_space_backfill_issues
  source_table
  source_id
  reason
  disposition
  details
  resolved_at
  unique(source_table, source_id)
```

Creating a host creates one stable private space, a legacy `host:<host_id>` alias, and the default `{memory_scope, private}` entitlement in the same transaction. Updating `memory_scope` clears the prior default marker and adds a new default entitlement without revoking the old subpartition. Deleting a host revokes delivery entitlements but does not delete the space or canonical memory.

### Dual identity

PR2 adds physically nullable `memory_space_id` columns for historical compatibility, but nullable new writes are forbidden. Migration order is fixed:

1. create the registry and mapping rows;
2. add canonical owner columns;
3. install compatibility derivation triggers that resolve exactly one legacy alias;
4. add `CHECK (memory_space_id IS NOT NULL) NOT VALID` constraints, which reject new null writes while permitting historical backfill;
5. backfill trustworthy rows and record unresolved rows;
6. validate constraints only when the defined table is clean;
7. install the edge revision/change trigger after memory backfill, so backfill does not manufacture feed history.

Application changesets also require canonical owner identity, but database enforcement is authoritative. `Memories.remember` resolves one canonical partition for every explicit/internal write, which makes current episodic/procedural fallbacks fail closed even before PR4 adds worker-specific processing states.

Direct roots receive the complete canonical tuple `{memory_space_id, scope, namespace}` plus host provenance where the domain requires it. The migration adds every currently missing field rather than adding only `memory_space_id`. The exact PR2 partition-root inventory is:

```text
Direct roots receiving memory_space_id:
  bpm_events
  bpm_streams
  bpm_memories
  bpm_observations
  memory_sessions
  bpm_projected_observations
  bpm_projected_sessions
  memory_summaries
  memory_crystals
  memory_profiles
  memory_graph_nodes
  memory_graph_edges
  memory_activity_daily
  memory_activity_subject_contributions
  memory_replay_events
  memory_recall_runs
  memory_actions
  memory_leases
  memory_signals
  memory_slots
  memory_import_batches
  bpm_projection_states
  bpm_projection_snapshots
  bpm_host_memory_revocations

Validated inheritance without a duplicate owner column:
  bpm_memory_remember_requests -> bpm_memories
  bpm_memory_evidence -> bpm_memories and typed source FKs
  bpm_memory_relations -> source/target bpm_memories
  bpm_memory_relation_evidence -> relation/evidence
  memory_lessons -> bpm_memories
  memory_crystal_* links -> memory_crystals plus validated sources
  memory_recall_candidates -> memory_recall_runs and candidate source
  memory_summary_source_events -> memory_summaries and bpm_events
  memory_action_edges -> memory_actions
  memory_facets -> memory_facet_dimensions and associated memory links
```

Specific legacy gaps are closed in PR2: streams gain scope/namespace; observations and legacy sessions gain host/scope/namespace; summaries, projection states/snapshots, imports, and revocations gain their missing canonical scope/namespace fields. Where a child already redundantly stores host/client/scope/namespace, all retained legacy fields must match the canonical parent relationship. A mismatch is a durable backfill issue, never silently overwritten.

Partition-sensitive audit rows and pending Oban jobs are inventoried by stable table/job identity. When their owner cannot be derived through a validated target or exact legacy partition fields, the migration records a backfill issue rather than rewriting opaque JSON. PR5 cutover requires every such issue to be resolved or its disposition completed.

The backfill is repeatable and keyed by `{source_table, source_id}`. It never guesses. Exact existing `scope` and `namespace`, including `shared` and `team:*`, are preserved. `partition_not_ready` is returned when an entitled partition has an unresolved edge-visible current memory, unresolved canonical partition root, failed initial snapshot, or missing validated host mapping. PR5 global cutover remains blocked until the full inventory reports zero unresolved rows or completed approved dispositions.

Historical `host:<host_id>` owner IDs are aliases, not `source_client_id` values.

## Edge eligibility

PR2 mirrors the minimum existing canonical fact contract:

- `memory_type` is `semantic` or `procedural`;
- namespace is an entitled exact namespace;
- lifecycle is `active` or `disputed`;
- `deleted_at` is nil;
- the encoded edge payload is within the configured single-item byte limit.

Transitions out of eligibility emit a delete. Transitions into eligibility emit an upsert. A scope, namespace, or memory-space move emits a delete in the old partition followed by an upsert in the new partition. Embedding, access-count, application-count, and access-time-only updates do not allocate revisions.

Oversized canonical memories remain valid canonical records but are ineligible for the edge mirror. If an older mirrored version exists, the transition emits a delete. Telemetry records the omission without content.

PR3 may expand eligibility to selected episodic/crystal/profile records and owns quota/priority policy.

## Revision and change capture

### Tables

```text
bpm_memory_partition_revisions
  memory_space_id / scope / namespace composite primary key
  current_revision bigint
  first_available_revision bigint
  updated_at

bpm_memory_changes
  memory_space_id / scope / namespace / revision composite primary key
  op upsert | delete
  memory_id
  payload jsonb
  payload_bytes
  created_at

bpm_host_memory_cursors
  host_id / memory_space_id / scope / namespace composite primary key
  applied_revision bigint
  active_snapshot_id uuid nullable
  snapshot_next_chunk_index integer nullable
  last_acknowledged_batch_id uuid nullable
  acknowledged_at

bpm_host_memory_deliveries
  id uuid primary key
  host_id / memory_space_id / scope / namespace
  kind delta | snapshot_chunk
  snapshot_id uuid nullable
  chunk_index integer nullable
  from_revision bigint nullable
  to_revision bigint
  payload jsonb
  encoded_bytes
  chunk_hash / integrity_hash
  status issued | progress | acknowledged | expired
  issued_at / acknowledged_at
  unique(host_id, memory_space_id, scope, namespace) where status = issued

bpm_memory_snapshots
  id uuid primary key
  memory_space_id / scope / namespace
  revision bigint
  item_count / chunk_count
  integrity_hash
  status building | ready | expired
  expires_at / inserted_at

bpm_memory_snapshot_chunks
  snapshot_id / chunk_index composite primary key
  item_count / encoded_bytes
  chunk_hash
  payload jsonb

bpm_host_memory_compat_receipts
  id uuid primary key
  host_id
  kind facts | wipe
  receipt_key
  scope
  payload_hash
  issued_at / acknowledged_at
  unique(host_id, kind, receipt_key)
```

A PostgreSQL trigger on `bpm_memories` calls a narrowly scoped SQL function. It compares edge-visible old/new shapes, locks affected partition rows in deterministic lexical order, increments each revision, inserts immutable payload snapshots, and issues `pg_notify` only as a post-commit hint. Failure rolls back both memory mutation and revision/change rows.

Backfilled partitions begin with `first_available_revision = current_revision + 1` and require an initial snapshot. No incomplete historical deltas are invented. `bpm_host_memory_deliveries` is the exact retry/ACK identity. Snapshot chunk deliveries reference one durable `bpm_memory_snapshots` row; intermediate chunk ACKs advance only `snapshot_next_chunk_index`, while final activation ACK advances `applied_revision` and clears snapshot state.

## Negotiation and wire contract

The host join keeps the existing v1 block and adds a separate v2 offer so older servers can ignore it:

```json
{
  "memory": {
    "protocol": "host_memory.v1",
    "scopes": [{"scope": "proj_local", "fact_set_hash": "sha256:..."}]
  },
  "memory_v2": {
    "offers": ["host_memory.v2"],
    "max_frame_bytes": 524288,
    "partitions": [
      {
        "memory_space_id": null,
        "scope": "proj_local",
        "namespace": "private",
        "applied_revision": 0,
        "snapshot": null
      }
    ]
  }
}
```

`EdgeSync.negotiate/2` returns one explicit selection and canonical inventory:

```json
{
  "selected": "host_memory.v2",
  "limits": {"max_changes": 100, "max_frame_bytes": 524288},
  "partitions": [
    {
      "memory_space_id": "uuid",
      "scope": "proj_local",
      "namespace": "private",
      "current_revision": 18,
      "applied_revision": 0,
      "status": "snapshot_required"
    }
  ]
}
```

A new host may offer an empty partition list. The server returns every active exact entitlement. Omitted `memory_space_id` is accepted only when the remaining claim resolves exactly one active entitlement. Unknown, ambiguous, revoked, or conflicting entries receive bounded per-partition reasons. Once v2 is selected, there is no silent v1 downgrade for that connection.

The v2 request/reply events are:

```text
memory_next       host asks for current/outstanding/next delivery
memory_ack        host reports committed delta, committed snapshot progress, or final activation
memory_available  optional content-free server hint; host still calls memory_next
```

`memory_next` returns one of `current`, `delta`, or `snapshot_chunk`. Snapshot continuation includes `snapshot_id` and `next_chunk_index`. `memory_ack` includes `batch_id`, status `applied | progress`, applied revision, and snapshot progress fields where relevant.

Host state rules are exact:

- `to_revision <= applied_revision`: stale/duplicate delivery, mutate nothing, return duplicate ACK;
- `from_revision == applied_revision + 1` with contiguous changes: commit rows and cursor, then ACK;
- forward gap or overlapping non-duplicate range: commit `snapshot_required`, mutate no mirror rows, request recovery;
- delta while a snapshot is staging: reject as snapshot restart/recovery, never merge states;
- partition mismatch or malformed payload: permanent protocol error, no write;
- transaction/decode/integrity failure: no cursor change and no ACK.

## Delta delivery

Request:

```json
{
  "protocol": "host_memory.v2",
  "partition": {
    "memory_space_id": "uuid-or-null-for-first-resolution",
    "scope": "proj_local",
    "namespace": "private"
  },
  "applied_revision": 12
}
```

Response:

```json
{
  "protocol": "host_memory.v2",
  "status": "batch",
  "kind": "delta",
  "batch_id": "uuid",
  "partition": {
    "memory_space_id": "uuid",
    "scope": "proj_local",
    "namespace": "private"
  },
  "from_revision": 13,
  "to_revision": 18,
  "changes": []
}
```

Rules:

- one outstanding delivery per host partition;
- exact retries return the same durable delivery;
- deltas start at server cursor `applied_revision + 1`;
- all change revisions are contiguous;
- both item count and encoded bytes are bounded;
- a single oversized change is not issued as an invalid frame;
- missing retained history, cursor ahead, or inconsistent claims trigger a snapshot;
- invented, stale, future, foreign-space, or mismatched ACKs cannot advance a cursor.

## Snapshot delivery

Snapshots are materialized from a revision-pinned canonical view, not from independent live pages. The builder starts a transaction, locks the partition revision row, records `R = current_revision`, and streams the current eligible `bpm_memories` rows in deterministic memory-ID order into durable chunks. The edge-change trigger must acquire the same partition lock, so no edge-visible mutation can commit between revision capture and snapshot materialization. The builder never uses unbounded `Repo.all/1`.

This canonical-table path is required for the initial backfilled snapshot and remains the compaction-safe snapshot source after early change rows are pruned in PR3. Change-log reconstruction may be used only when a complete retained baseline is provable; it is not the default.

The builder chunks by both count and encoded bytes, stores per-chunk hashes, and computes a manifest hash over ordered chunk hashes while streaming. The snapshot transaction commits the complete ready manifest before any chunk can be issued.

`next/2` returns one durably issued materialized chunk at a time. A continuation request names the snapshot and expected next chunk index; the server returns the existing issued delivery byte-for-byte until it is acknowledged. If a snapshot expires or the host state is incompatible, a new snapshot safely restarts.

The host writes chunks into a staging generation. Exact duplicate chunks are idempotent; same index with different hash fails closed. An intermediate committed chunk returns `status=progress` and the next chunk index; it never returns a revision-advancing ACK. Final activation verifies the complete manifest, flips `active_generation`, advances the host `applied_revision`, records `last_sync_at`, and returns `status=applied` atomically. Only that final ACK may advance the server cursor. Partial staging is never visible to recall.

## Host edge database

The edge mirror uses a separate Turso database and pool.

```text
edge_partitions
  memory_space_id / scope / namespace primary key
  applied_revision
  active_generation
  last_batch_id
  last_sync_at
  snapshot_id / snapshot_revision / next_chunk_index / chunk_count / integrity_hash

edge_memories
  memory_space_id / scope / namespace / generation / canonical_id primary key
  memory_type / content / content_hash / confidence / lifecycle_state
  tags / metadata / source_refs
  server_revision / edge_priority / edge_expires_at
  updated_at / last_accessed_at / byte_size

edge_snapshot_chunks
  snapshot_id / chunk_index primary key
  chunk_hash / applied_at
```

Deletes retain canonical ID and server revision as tombstone state so an older replayed upsert cannot resurrect content. Old generations are deleted only after activation commits.

The existing `facts`, command outbox, and capture spool are not migrated into this mirror.

## Host polling and wakeup

The existing command Syncer keeps `memory_sync`/`host_memory.v1` for provisional remember/forget upload and is otherwise unchanged. A separate `Backplane.HostAgent.Memory.Edge.Syncer` owns edge polling, protection/storage backoff, and wakeup hints. When v2 is enabled and the edge store is available, its scheduled cycle calls:

```text
memory_next -> apply_delivery -> memory_ack
```

A content-free `memory_available` server notification may request an immediate cycle. It contains only partition identity and current revision. The host still calls `memory_next`; notification state is never authoritative.

## Offline facade behavior

After an allowlisted transport failure:

1. read the committed active edge generation;
2. query using degraded local lexical matching only;
3. merge the bounded provisional command overlay;
4. suppress canonical IDs with pending forgets;
5. return the compatibility aliases and consistency envelope.

With a committed mirror:

```text
mode = offline
authority = canonical | canonical_with_provisional
source = edge_mirror
consistency = bounded_stale
stale = true
history_available = true
as_of = last_sync_at
partition_revision = applied_revision
last_sync_age_seconds = computed age
```

Without a committed mirror, retain PR1's `provisional_only` and `history_available=false` response. Authorization, partition, validation, governance, and protocol errors never read the mirror.

## Protection gate

`ex_turso 3.0.3` still exposes no supported database-encryption option. `gsmlg-dev/concord#91` is open and marked `unable to resolve`.

PR2 therefore implements:

- a separate `Memory.Edge.Protection` decision before edge path creation/open;
- default-disabled edge persistence;
- explicit plaintext opt-in accepted only in `dev` and `test`;
- unconditional rejection of plaintext edge persistence in production;
- persistent startup warning and diagnostics status `plaintext_development`;
- failure status that allows capture delivery and online recall but disables sync writes and offline mirror reads;
- `# TODO(upstream): gsmlg-dev/concord#91` at the edge Turso open callsite.

There is no silent plaintext fallback, spool-cipher reuse, or private NIF access.

Protection is resolved before directory creation or `Turso.start_link`. Disabled or rejected protection returns `:ignore` from the isolated edge supervisor and leaves the edge path absent. The command memory store, command Syncer, capture spool/uploader, host connection, and online facade remain supervised independently and continue operating. Diagnostics compute/report `disabled`, `plaintext_development`, or `protection_unavailable` even when no edge process exists.

## Compatibility

- V1 host command upload remains enabled.
- V1 hash reconcile remains available behind `memory.host_sync_v1.enabled` during rollout, but content-bearing fact persistence uses the same protection decision as v2 and stays disabled in production while protection is unavailable. Governance wipe application may remain enabled because it removes state rather than creating plaintext canonical content.
- V2 delivery is behind `memory.host_sync_v2.enabled` and the host edge protection gate.
- The host advertises v2 separately from the existing v1 join block, so an older server can ignore v2 and continue v1.
- A new server selects one delivery protocol explicitly. It never silently downgrades after selecting v2.
- V1 fact/wipe application is wired to the existing transactional `Facts` module and ACKs only after commit. The server persists an issued `bpm_host_memory_compat_receipts` row before push. Facts use `receipt_key = facts:<memory_space_id>:<scope>:<fact_set_hash>`; wipes use the stable directive ID. Payload hashes bind the ACK to the issued content, duplicate exact ACKs are idempotent, conflicting receipts are rejected, and these rows never advance v2 cursors.
- V1 fact and wipe queries are count/byte bounded. Because v1 has no chunk continuation, an oversized compatibility result returns an explicit bounded error/status and records telemetry rather than using unbounded `Repo.all/1` or one oversized push.
- Legacy identifiers remain available for rollback; `memory_space_id` is never inferred from a v1 hash.

## Internal seams

The public interfaces remain `EdgeSync.negotiate/2`, `next/2`, `ack/2`, and host `Mirror.offer/1`, `apply_delivery/2`, `offline_read/3`. Internally, two real adapter seams isolate storage from protocol orchestration:

```elixir
defmodule Backplane.Memory.EdgeSync.Store do
  @callback negotiate(host_id :: String.t(), offer :: map()) :: {:ok, map()} | {:error, term()}
  @callback next(host_id :: String.t(), request :: map(), limits :: map()) ::
              {:ok, map()} | {:error, term()}
  @callback ack(host_id :: String.t(), ack :: map()) :: {:ok, map()} | {:error, term()}
end

defmodule Backplane.HostAgent.Memory.Mirror.Store do
  @callback offer(GenServer.server()) :: {:ok, map()} | {:error, term()}
  @callback apply_delivery(GenServer.server(), map()) :: {:ok, map()} | {:error, term()}
  @callback read(GenServer.server(), String.t(), map()) :: {:ok, map()} | {:error, term()}
end
```

Production adapters use PostgreSQL and Turso. Protocol unit tests may use in-memory adapters, but acceptance tests use real stores and prove transaction/ACK ordering.

## Error taxonomy

Permanent protocol errors:

```text
invalid_request
unsupported_protocol
protocol_disabled
unauthorized
partition_mismatch
ambiguous_partition
partition_not_ready
invalid_ack
batch_not_found
batch_conflict
payload_too_large
```

Retryable server errors:

```text
storage_unavailable
transaction_conflict
snapshot_build_unavailable
```

Host recovery results:

```text
duplicate
snapshot_required
snapshot_restart_required
edge_protection_unavailable
edge_storage_unavailable
integrity_mismatch
```

Errors expose codes and bounded identifiers only, never memory content or secret material.

## Telemetry and diagnostics

Server:

```text
partition current/first-available revision
change count and retained bytes
snapshot build/chunk counts
issued/acked batches
host revision lag
invalid/stale ACK count
delivery latency and error class
```

Host:

```text
edge protection mode
edge items/bytes
applied revision and last sync
stale age
delta/snapshot counts
gap/integrity/protection failures
```

Content, tags, metadata, and raw payloads never appear in telemetry labels.

## PR2 scope and deferred work

PR2 includes:

- stable private memory-space mapping and dual-write/backfill foundation;
- exhaustive partition-root/inheritance/job inventory, new-write database enforcement, and partition-readiness audit;
- revision/change/cursor/snapshot storage;
- server `negotiate/next/ack` protocol and API transport;
- separate host edge DB, transactional apply, snapshot activation, and offline facade;
- explicit v1 compatibility and production protection gate.

PR2 does not include:

- cross-host sharing;
- production mirror enablement while protection is unavailable;
- edge quotas, priority/LRU eviction, or change-log retention policy (PR3);
- tombstone/outbox schema repair (PR3);
- projection coalescing or detailed worker processing states (PR4); PR2 still enforces canonical owner identity for every new write;
- removal of v1 paths or final schema/tool/docs cutover (PR5);
- local embeddings, vector search, LLM processing, or semantic consolidation.

## Validation

Automated tests must prove:

1. stable host mapping, old-scope preservation, entitlement revocation, and ambiguous-row disposition;
2. every new partition-root write has non-null memory-space identity, and derived/child rows inherit through validated exact-partition relationships;
3. incomplete episodic, procedural, summary, lesson, crystal, graph, profile, activity, replay, recall-trace, coordination, projection, import, and slot writes fail closed;
4. backfill covers every inventory row once, preserves exact scope/namespace, records stable unresolved issues, and makes `partition_not_ready` deterministic;
5. concurrent edge-visible changes allocate contiguous revisions;
6. rollback produces no change and no revision gap;
7. partition moves produce old delete/new upsert in deterministic order;
8. embedding/access-only updates produce no revision;
9. delta count/byte bounds and exact replay;
10. wrong/stale/future/foreign ACKs cannot advance cursors;
11. gap or compacted history produces a canonical-view snapshot;
12. initial and post-compaction snapshots include unchanged legacy canonical memories;
13. materialized snapshot chunks are bounded, deterministic, resumable, and integrity-checked;
14. partial snapshot progress cannot advance the server applied revision;
15. host delta applies atomically with its cursor and ACK follows commit;
16. interrupted snapshots resume/restart safely and partial generations are invisible;
17. delete revision cannot be undone by an older upsert;
18. connected polling or wakeup converges without reconnect;
19. restart preserves mirror and offline recall metadata;
20. pending remember/forget merges without duplicates or resurrection;
21. v1-only, v2-disabled, v2-enabled, and malformed negotiation are explicit;
22. v1 issued receipts and duplicate/conflicting ACKs are durable and never advance v2 cursors;
23. production protection rejection occurs before edge DB creation and leaves capture/commands/online recall healthy;
24. development/test plaintext requires explicit opt-in and reports degraded status;
25. current capture spool and command upload behavior remain unchanged.
