# Memory V2 PR2-PR5 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete the handoff's PR2-PR5 remediation so Backplane remains the sole memory authority, hosts converge a protected bounded edge mirror by monotonic revision, projection work scales, and the final A-J qualification scenarios pass.

**Architecture:** PR2 introduces stable private memory spaces, transactional edge revisions, durable deliveries/cursors/snapshots, a separate protected Turso mirror, and explicit v1/v2 negotiation. PR3 adds local command reliability, cache quotas, deterministic eviction, retention, and operational telemetry. PR4 coalesces projection repairs and records precise fail-closed processing states. PR5 unifies tool contracts, publishes the protocol/runbook, runs the A-J qualification suite, and updates release gates without deleting rollback paths prematurely.

**Tech Stack:** Elixir 1.18, OTP 28, Phoenix Channels, Ecto/PostgreSQL, Oban, ex_turso 3.0.3/Turso, ExUnit, Telemetry, GitHub Actions.

---

## Program invariants

Every task must preserve all of these:

```text
canonical owner = memory_space_id
capture provenance/delivery target = host_id
runtime provenance = source_client_id
revision key = {memory_space_id, scope, namespace}
capture spool != command outbox != edge mirror
online recall = canonical
offline recall = committed edge generation + provisional overlay, visibly bounded_stale
server cursor advances only after a matching durable host ACK
production plaintext edge persistence = rejected before path creation
```

The existing `MemoryProxy` remains the remote-client seam. The existing `Memory.Syncer` remains command-outbox-only. A new `Memory.Edge.Syncer` owns edge polling. V1 hashes remain snapshot-compatibility hints and never become v2 cursors.

## Baseline evidence

Fresh worktree baseline at `825148ca`:

```text
apps/backplane_api/test: 222 tests, 0 failures
apps/backplane_memory/test: 1086 tests, 0 failures
apps/backplane_host_agent/test: 390 tests, 1 pre-existing failure
```

The host failure is `worker_test.exs:227`: the test imposes ordering between `FailingConnector.connect/1` and a separately scheduled Task child. `Supervisor.start_link/2` guarantees the child started, but not the order in which the child and caller deliver messages to the test process. The production behavior is healthy; the assertion is invalid.

## PR2 - Revisioned protocol and edge mirror

### Execution record

- Tasks 1–2: committed and reviewed through `65899099`.
- Task 3: committed as `ff2b1c31`; specification and quality reviews approved.
  Full scoped gates: Memory 1,109, API 224, System 412, Admin 270 tests, all passing.
  Final review regressions: migration 4/4 (NULL scope/namespace INSERT and UPDATE
  rejection across all 24 roots) and imports 4/4 (exact partition authorization).
  Changed-file formatting, warnings-as-errors compilation, and diff checks passed.
- Task 4: committed as `98636248` with notification-bound fix `1fbe5e9f`;
  specification and quality reviews approved. Real PostgreSQL storage/capture
  tests: 13/13; formatting, warnings-as-errors compilation, and diff checks passed.
- Task 5: committed as `0db5c1b9`; specification and quality reviews approved.
  EdgeSync/Config tests: 43/43 after the final failure/rebuild race fix; full
  Memory 1,141/1,141 before that isolated fix; affected System tests 19/19.
  Formatting, warnings-as-errors compilation, and diff checks passed.
- Task 6: committed as `2d9e8d5f`; specification and quality reviews approved.
  Full API tests: 234/234 with warnings-as-errors, repeated on the merged
  `bd5bc830` state using the worktree PostgreSQL instance. Scoped formatting and
  diff checks passed. Locally merged into main at the user's request; no push.
- Task 7: committed as `d266228c` with schema-before-configuration hardening
  `62738f48`; specification and quality reviews approved. Full host-agent suite:
  406/406 with warnings-as-errors; independently repeated edge/supervisor/config
  tests: 33/33. Formatting and diff checks passed. Production rejection,
  command/capture path aliases, foreign database preservation, restart durability,
  and normal supervised shutdown are covered.
- Task 8: committed as `908ed69e` with schema/replay hardening `ecd54030`,
  stale-snapshot idempotency `8691809c`, and atomic cleanup/bounded reads
  `8dfbb904`; the registered-schema startup expectation was corrected in
  `4aef7f0b`. Specification and quality reviews approved. Focused mirror/migrator
  tests: 22/22; final affected edge-store/migrator/mirror tests: 24/24 with
  warnings-as-errors. Scoped formatting and diff checks passed.
- Task 9: committed as `0ced47f7` with negotiation/lifecycle fixes through
  `42a00c1c`, `5fa8197e`, `3689c7b7`, and timer/partition guard regressions
  `8694680b`; specification and quality reviews approved. Fresh final gates:
  host-agent 452/452 and API channel/e2e 61/61 with warnings-as-errors. Scoped
  formatting and diff checks passed. Fresh-host bootstrap, negotiated-entitlement
  revocation, fair snapshot polling, durable apply-before-ACK, v1 protection/wipe
  behavior, reconnect deselection, normal OTP shutdown, and stale timer suppression
  are covered.
- Task 10: committed as `e02f545b` with sequence-preservation repair `7e4b7d89`
  and late rollback regression `e220299e`; specification and quality reviews
  approved. The user approved the narrow `mix.lock` scope expansion for
  `ex_turso` 3.0.4. Final focused tests: 38/38 with warnings-as-errors; the
  additional late-failure migration regression passed 6/6. Scoped formatting
  and diff checks passed. Composite tombstone identity, exact outbox states,
  empty-outbox AUTOINCREMENT high-water preservation, fail-closed rollback, and
  atomic wipe timestamps are covered.
- Task 11: committed as `2576bde1` with transition/specification hardening
  `b27c5e07`, storage-failure and transactional-retention repair `f49c33fa`, and
  batch-atomic settlement/live recovery `44f65bcc`; specification and quality
  reviews approved. Final focused reviewer gate: 33/33; final full host-agent
  gate: 475/475 with warnings-as-errors. Scoped formatting and diff checks passed.
  Due FIFO, bounded jittered retries, max-attempt dead letters, restart recovery,
  ordered duplicate-ID ACKs, wipe-safe state guards, selected/all requeue,
  terminal outbox retention, opt-in tombstone retention, malformed ACK handling,
  storage-error propagation, and rollback of partial settlement/pruning are
  covered. Tasks 12–20 remain outstanding; PR2–PR5 is not complete.

### Task 1: Repair the invalid baseline assertion and approve the design status

**Files:**
- Modify: `apps/backplane_host_agent/test/backplane/host_agent/worker_test.exs`
- Modify: `docs/superpowers/specs/2026-09-02-memory-v2-pr2-revisioned-edge-design.md`

- [ ] Replace the ordered fourth/fifth-message assertions with two selective receives:

```elixir
assert_receive {:connect_failed, %{host_id: "host-authoritative"}}
assert_receive {:http_child_started, http_child}
```

- [ ] Run the exact test three times with fixed and random seeds:

```bash
devenv shell -- env MIX_ENV=test mix test apps/backplane_host_agent/test/backplane/host_agent/worker_test.exs:227 --seed 775465
devenv shell -- env MIX_ENV=test mix test apps/backplane_host_agent/test/backplane/host_agent/worker_test.exs:227 --seed 1
devenv shell -- env MIX_ENV=test mix test apps/backplane_host_agent/test/backplane/host_agent/worker_test.exs:227
```

Expected: all three runs pass.

- [ ] Run the complete host-agent suite.
- [ ] Commit the test repair:

```bash
git add apps/backplane_host_agent/test/backplane/host_agent/worker_test.exs
git commit -m "test(host-agent): remove invalid startup ordering assumption"
```

- [ ] Change the design status from `Proposed concrete implementation design` to `Approved implementation design`, set the approval date to `2026-09-05`, and retain the original proposal date/history.
- [ ] Commit the approval separately:

```bash
git add docs/superpowers/specs/2026-09-02-memory-v2-pr2-revisioned-edge-design.md
git commit -m "docs(memory): approve revisioned edge design"
```

### Task 2: Add stable memory-space registry and host lifecycle

**Files:**
- Create: `apps/backplane_system/lib/backplane/memory_spaces.ex`
- Create: `apps/backplane_system/lib/backplane/memory_spaces/memory_space.ex`
- Create: `apps/backplane_system/lib/backplane/memory_spaces/entitlement.ex`
- Create: `apps/backplane_system/lib/backplane/memory_spaces/legacy_alias.ex`
- Create: `apps/backplane_system/lib/backplane/memory_spaces/backfill_issue.ex`
- Create: `apps/backplane_system/priv/repo/migrations/20260905000001_create_memory_space_registry.exs`
- Create: `apps/backplane_system/test/backplane/memory_spaces_test.exs`
- Create: `apps/backplane_system/test/backplane/repo/migrations/create_memory_spaces_test.exs`
- Modify: `apps/backplane_skills/lib/backplane/skills/hosts.ex`
- Modify: `apps/backplane_skills/test/backplane/skills/hosts_test.exs`

- [ ] Write failing migration/context tests for one stable private space, `host:<id>` alias, exact active entitlement, scope-change preservation, revocation on host deletion, and ambiguous alias rejection.
- [ ] Run the focused tests and verify the failure is caused by missing schemas/tables.
- [ ] Create these PostgreSQL tables with UUID keys and explicit check/unique constraints:

```text
bpm_memory_spaces(id, kind private|shared, status active|disabled, timestamps)
bpm_memory_space_entitlements(memory_space_id, host_id, scope, namespace,
  default_capture, status active|revoked, timestamps,
  UNIQUE(memory_space_id, host_id, scope, namespace))
bpm_memory_space_legacy_aliases(alias_type, alias_value, memory_space_id,
  UNIQUE(alias_type, alias_value))
bpm_memory_space_backfill_issues(source_table, source_id, reason,
  disposition pending|resolved|approved_waiver,
  details, resolved_at, timestamps, UNIQUE(source_table, source_id))
```

- [ ] In the same idempotent migration, provision one stable private space, `host:<id>` alias, and current default entitlement for every existing `skill_hosts` row before any partition-root backfill runs.

- [ ] Implement the public context contract:

```elixir
@spec provision_private_host(Ecto.UUID.t(), String.t()) :: {:ok, map()} | {:error, term()}
@spec update_default_scope(Ecto.UUID.t(), String.t()) :: :ok | {:error, term()}
@spec revoke_host(Ecto.UUID.t()) :: :ok | {:error, term()}
@spec resolve_host_partition(Ecto.UUID.t(), String.t() | nil, String.t()) ::
        {:ok, %{memory_space_id: Ecto.UUID.t(), scope: String.t(), namespace: String.t()}}
        | {:error, :unauthorized | :ambiguous_partition | :partition_not_ready}
```

- [ ] Call the context inside the existing `Hosts` transactions for create, create-with-token, scope update, and delete; refresh runtime managers only after commit.
- [ ] Run system and skills focused suites.
- [ ] Commit `feat(memory): add stable memory space registry`.

### Task 3: Add canonical memory-space identity and fail-closed backfill

**Files:**
- Create: `apps/backplane_system/priv/repo/migrations/20260905000002_add_memory_space_identity.exs`
- Create: `apps/backplane_system/priv/repo/migrations/20260905000003_backfill_memory_space_identity.exs`
- Create: `apps/backplane_memory/lib/backplane/memory/partition_identity.ex`
- Create: `apps/backplane_memory/test/backplane/memory/memory_space_identity_migration_test.exs`
- Modify direct-root schemas: `events/event.ex`, `events/stream.ex`, `memories/memory.ex`, `observations/observation.ex`, `observations/session.ex`, `projections/projected_observation.ex`, `projections/projected_session.ex`, `projections/state.ex`, `projections/snapshot.ex`, `projections/activity_daily.ex`, `projections/activity_contribution.ex`, `summaries/summary.ex`, `crystals/crystal.ex`, `profiles/profile.ex`, `graph/node.ex`, `graph/edge.ex`, `replay/event.ex`, `recall/run.ex`, `coordination/action.ex`, `coordination/lease.ex`, `coordination/signal.ex`, `slots/slot.ex`, and `imports/import_batch.ex` under `apps/backplane_memory/lib/backplane/memory/`
- Modify: `apps/backplane_api/lib/backplane/api/host_memory_revocation.ex`
- Modify: `apps/backplane_memory/lib/backplane/memory/partition.ex`
- Modify: `apps/backplane_memory/lib/backplane/memory/ingest.ex`
- Modify: `apps/backplane_memory/lib/backplane/memory/ingest/upcaster/v1.ex`
- Modify: `apps/backplane_memory/lib/backplane/memory/memories.ex`
- Modify root writers/read boundaries: `events/preparation.ex`, `events/store.ex`, `events/query.ex`, `crystals.ex`, `observations.ex`, `profiles.ex`, `graph.ex`, `imports.ex`, `slots.ex`, `projections/observation_projector.ex`, `projections/session_projector.ex`, `projections/activity_projector.ex`, `projections/activity_store.ex`, `projections/rebuild.ex`, `replay/store.ex`, `recall/query_plan.ex`, `recall/store.ex`, `crystals/projection_store.ex`, and `eval/runner.ex` under `apps/backplane_memory/lib/backplane/memory/`
- Modify generator boundaries: `workers/summary_worker.ex`, `workers/episodic_worker.ex`, `workers/procedural_worker.ex`, `workers/profile_build_worker.ex`, `workers/graph_extract_worker.ex`, and `workers/crystal_worker.ex` under `apps/backplane_memory/lib/backplane/memory/`
- Modify: `apps/backplane_api/lib/backplane/api/channels/host_agent_channel.ex`
- Modify: `apps/backplane_memory/test/backplane/memory/workers/summary_worker_test.exs`
- Modify: `apps/backplane_memory/test/backplane/memory/workers/episodic_worker_test.exs`
- Modify: `apps/backplane_memory/test/backplane/memory/workers/procedural_worker_test.exs`
- Modify: `apps/backplane_memory/test/backplane/memory/memories/profile_build_worker_test.exs`
- Modify: `apps/backplane_memory/test/backplane/memory/graph/graph_extract_worker_test.exs`
- Modify: `apps/backplane_memory/test/backplane/memory/crystals_test.exs`
- Modify: `apps/backplane_api/test/backplane/api/channels/host_agent_channel_test.exs`

- [ ] Write failing migration tests that seed trustworthy, ambiguous, missing, shared, and `team:*` legacy rows across every direct root; every validated child relationship; partition-sensitive audit rows; and pending Oban jobs.
- [ ] Write failing changeset/ingest tests proving new rows cannot omit `memory_space_id`, `scope`, or `namespace`, and source-provided authority cannot override the authenticated entitlement.
- [ ] Write failing readiness tests for unresolved current memories/roots, missing host mappings, a pre-seeded unresolved initial-snapshot issue, exact entitlement revocation, and deterministic repeated `partition_not_ready` results.
- [ ] At each generator/channel test boundary, prove both exact owner propagation and fail-closed incomplete input so PR2 remains independently valid before Task 15 adds richer state labels.
- [ ] Add nullable physical owner columns for rollback compatibility, derive only through exact aliases/parents, record one stable backfill issue per unresolved root, and add `NOT VALID` non-null/nonblank checks so new invalid writes fail immediately.
- [ ] Preserve `client_id` as a legacy alias and add `source_client_id` where runtime provenance is currently overwritten.
- [ ] Propagate the authenticated channel partition and exact canonical owner through every active generator. PR2 must fail closed rather than creating an ownerless summary, episodic/procedural memory, profile, graph record, or crystal; Task 15 adds the detailed terminal processing states later.
- [ ] Implement one exact validator:

```elixir
@spec validate(map()) :: {:ok, map()} | {:error, :incomplete_partition | :partition_mismatch}
```

It must reject nil, blank, mismatched, or cross-space values.
- [ ] Run the migration twice against fixtures and prove idempotent issue keys and unchanged exact namespaces.
- [ ] Run all partition, ingest, memories, projection-schema, and migration tests.
- [ ] Commit `feat(memory): add canonical memory space identity`.

### Task 4: Create durable revision, delivery, snapshot, and v1 receipt storage

**Files:**
- Create: `apps/backplane_system/priv/repo/migrations/20260905000004_create_host_memory_edge_sync.exs`
- Create: `apps/backplane_system/priv/repo/migrations/20260905000005_install_memory_edge_change_capture.exs`
- Create: `apps/backplane_memory/lib/backplane/memory/edge_sync/partition_revision.ex`
- Create: `apps/backplane_memory/lib/backplane/memory/edge_sync/change.ex`
- Create: `apps/backplane_memory/lib/backplane/memory/edge_sync/cursor.ex`
- Create: `apps/backplane_memory/lib/backplane/memory/edge_sync/delivery.ex`
- Create: `apps/backplane_memory/lib/backplane/memory/edge_sync/snapshot.ex`
- Create: `apps/backplane_memory/lib/backplane/memory/edge_sync/snapshot_chunk.ex`
- Create: `apps/backplane_memory/lib/backplane/memory/edge_sync/compat_receipt.ex`
- Create: `apps/backplane_memory/test/backplane/memory/edge_sync/migration_test.exs`
- Create: `apps/backplane_memory/test/backplane/memory/edge_sync/change_capture_test.exs`

- [ ] Write failing real-PostgreSQL tests for contiguous concurrent revisions, rollback-without-gap, edge-visible upsert/delete, partition move ordering, ignored embedding/access-only updates, and the exact eligibility boundary.
- [ ] Create the seven durable tables exactly as approved, including one issued delivery per host partition and immutable ordered change rows.
- [ ] Install a `bpm_memories` trigger function that:

```text
compares old/new edge-visible shapes
locks affected partition revision rows in lexical order
allocates one revision per emitted transition
inserts immutable payload snapshots
rolls back with the canonical mutation on failure
uses pg_notify only after commit as a content-free wakeup
```

The eligible shape is semantic/procedural, active/disputed, nondeleted, in an exact entitled namespace, and below the configured single-item byte limit. A transition to oversized/ineligible emits a delete when an older mirrored version exists and records only content-free telemetry.

- [ ] Initialize backfilled partitions with `first_available_revision = current_revision + 1` so the first v2 delivery must be a canonical-view snapshot.
- [ ] Run focused concurrency and transaction tests.
- [ ] Commit `feat(memory): add revisioned host memory feed storage`.

### Task 5: Implement the PostgreSQL EdgeSync store and public protocol

**Files:**
- Create: `apps/backplane_memory/lib/backplane/memory/edge_sync.ex`
- Create: `apps/backplane_memory/lib/backplane/memory/edge_sync/store.ex`
- Create: `apps/backplane_memory/lib/backplane/memory/edge_sync/postgres_store.ex`
- Create: `apps/backplane_memory/lib/backplane/memory/edge_sync/snapshot_builder.ex`
- Create: `apps/backplane_memory/lib/backplane/memory/edge_sync/notifier.ex`
- Create: `apps/backplane_memory/test/backplane/memory/edge_sync_test.exs`
- Create: `apps/backplane_memory/test/backplane/memory/edge_sync/snapshot_builder_test.exs`
- Create: `apps/backplane_memory/test/backplane/memory/edge_sync/notifier_test.exs`
- Modify: `apps/backplane_memory/lib/backplane/memory/application.ex`
- Modify: `apps/backplane_memory/lib/backplane/memory/config.ex`
- Modify: `apps/backplane_memory/test/backplane/memory/config_test.exs`
- Modify: `apps/backplane_system/lib/backplane/settings.ex`
- Modify: `apps/backplane_system/test/backplane/settings_test.exs`

- [ ] Write failing tests for negotiation, exact entitlement inventory, one outstanding delivery, count/byte-bounded deltas, exact retry, invalid/stale/future/foreign ACK rejection, gap/cursor-ahead snapshot recovery, and initial-snapshot build failure/recovery.
- [ ] Implement the public API:

```elixir
@spec negotiate(Ecto.UUID.t(), map()) :: {:ok, map()} | {:error, map()}
@spec next(Ecto.UUID.t(), map()) :: {:ok, map()} | {:error, map()}
@spec ack(Ecto.UUID.t(), map()) :: {:ok, map()} | {:error, map()}
```

- [ ] Add runtime settings `memory.host_sync_v1.enabled` and `memory.host_sync_v2.enabled`; test v1-only, v2-disabled, v2-enabled, malformed negotiation, and fail-closed no-downgrade behavior after v2 selection.
- [ ] Supervise only the PostgreSQL notification listener; protocol/store modules remain stateless, and notifications are correctness-independent content-free hints.

- [ ] Materialize snapshots in a transaction that shares the partition revision lock with the change trigger, streams eligible memories in canonical-ID order, chunks by both count and encoded bytes, stores chunk hashes, and publishes the ready manifest only after all chunks exist.
- [ ] Record a stable readiness issue when an initial snapshot build fails, keep the partition at `partition_not_ready`, and clear/complete that issue only after a successful deterministic rebuild; prove both transitions with real PostgreSQL tests.
- [ ] Make intermediate snapshot ACKs update only progress; only the final activation ACK advances `applied_revision`.
- [ ] Return bounded error maps with `code` and `retryable`, never content.
- [ ] Run all EdgeSync tests and commit `feat(memory): implement host memory v2 delivery protocol`.

### Task 6: Expose v2 transport and durable v1 compatibility receipts

**Files:**
- Modify: `apps/backplane_api/lib/backplane/api/channels/host_agent_channel.ex`
- Modify: `apps/backplane_api/lib/backplane/api/host_agent_memory_sync.ex`
- Modify: `apps/backplane_api/test/backplane/api/channels/host_agent_channel_test.exs`
- Modify: `apps/backplane_api/test/backplane/api/host_agent_memory_sync_test.exs`
- Modify: `apps/backplane_api/test/backplane/api/host_agent_sync_e2e_test.exs`

- [ ] Replace the current no-op ACK tests with failing tests for issued receipt binding, ACK-after-application, exact duplicate ACK, conflict rejection, and no v2 cursor movement.
- [ ] Add channel events `memory_next` and `memory_ack`; negotiate `memory_v2` at join and return an explicit selected protocol/inventory.
- [ ] Keep `memory_available` content-free and correctness-independent.
- [ ] Bound v1 fact/wipe queries by count and encoded bytes. Persist an issued receipt before push and include `receipt_key` plus `payload_hash`.
- [ ] Make malformed, unauthorized, and partition-mismatched requests fail without invoking local fallback semantics.
- [ ] Run API focused and e2e suites; commit `feat(api): expose revisioned host memory sync`.

### Task 7: Add the host protection gate and separate edge database

Scope amendment approved by the user on 2026-09-07: update the two existing
exact-map expectations in `apps/backplane_host_agent/test/backplane/host_agent/config_test.exs`
to include the newly introduced host-sync configuration defaults.

**Files:**
- Create: `apps/backplane_host_agent/lib/backplane/host_agent/memory/edge/protection.ex`
- Create: `apps/backplane_host_agent/lib/backplane/host_agent/memory/edge/store.ex`
- Create: `apps/backplane_host_agent/lib/backplane/host_agent/memory/edge/migrator.ex`
- Create: `apps/backplane_host_agent/lib/backplane/host_agent/memory/edge/migrations/v1.ex`
- Create: `apps/backplane_host_agent/lib/backplane/host_agent/memory/edge/supervisor.ex`
- Create: `apps/backplane_host_agent/test/backplane/host_agent/memory/edge/protection_test.exs`
- Create: `apps/backplane_host_agent/test/backplane/host_agent/memory/edge/store_test.exs`
- Create: `apps/backplane_host_agent/test/backplane/host_agent/memory/edge/migrator_test.exs`
- Create: `apps/backplane_host_agent/test/backplane/host_agent/memory/edge/supervisor_test.exs`
- Modify: `apps/backplane_host_agent/lib/backplane/host_agent/config.ex`
- Modify: `apps/backplane_host_agent/lib/backplane/host_agent/memory/supervisor.ex`
- Modify: `apps/backplane_host_agent/test/backplane/host_agent/memory/supervisor_test.exs`

- [ ] Write failing tests proving disabled/production plaintext modes create no directory, dev/test plaintext requires explicit opt-in, and protection failure leaves capture/commands/online recall healthy.
- [ ] Add config keys for `host_sync_v1`, `host_sync_v2`, edge DB path, explicit plaintext development opt-in, frame/item limits, and sync interval.
- [ ] Resolve protection before any `File.mkdir_p` or `Turso.start_link` call. At the open callsite add:

```elixir
# TODO(upstream): gsmlg-dev/concord#91
```

- [ ] Create separate `edge_partitions`, `edge_memories`, and `edge_snapshot_chunks` tables. `edge_memories` key includes generation and canonical ID; deletes retain canonical ID/server revision without content.
- [ ] Return `:ignore` from the isolated supervisor when disabled/unavailable and expose `disabled | plaintext_development | protection_unavailable` diagnostics.
- [ ] Run real Turso restart/migration tests; commit `feat(host-agent): add protected edge memory store`.

### Task 8: Implement atomic mirror application and offline reads

Scope amendment approved by the user on 2026-09-20: add and register an edge V2
migration for persistent `sync_status` and `last_delivery_hash`, and add focused
schema-validation plus V1-to-V2 upgrade/data-preservation tests.

**Files:**
- Create: `apps/backplane_host_agent/lib/backplane/host_agent/memory/mirror.ex`
- Create: `apps/backplane_host_agent/lib/backplane/host_agent/memory/mirror/store.ex`
- Create: `apps/backplane_host_agent/test/backplane/host_agent/memory/mirror_test.exs`
- Create: `apps/backplane_host_agent/lib/backplane/host_agent/memory/edge/migrations/v2.ex`
- Modify: `apps/backplane_host_agent/lib/backplane/host_agent/memory/edge/migrator.ex`
- Modify: `apps/backplane_host_agent/test/backplane/host_agent/memory/edge/migrator_test.exs`

- [ ] Write failing real-store tests for contiguous delta, duplicate delta, forward gap, snapshot staging invisibility, chunk restart, final manifest activation, restart persistence, and old-upsert non-resurrection.
- [ ] Implement:

```elixir
@spec offer(keyword()) :: {:ok, map()} | {:error, term()}
@spec apply_delivery(map(), keyword()) :: {:ok, map()} | {:error, term()}
@spec offline_read("recall" | "list" | "stats", map(), keyword()) ::
        {:ok, map()} | {:error, term()}
```

- [ ] Apply a delta and advance the local cursor in one Turso transaction. Return the ACK only after commit.
- [ ] Stage snapshot chunks in a non-active generation, verify every chunk and final manifest, then flip generation/cursor/last-sync atomically.
- [ ] Query only the active generation with bounded lexical matching and return `as_of`, `partition_revision`, and stale age.
- [ ] Run mirror tests; commit `feat(host-agent): apply revisioned edge memory mirror`.

### Task 9: Wire negotiation, polling, wakeups, v1 application, and facade fallback

**Files:**
- Create: `apps/backplane_host_agent/lib/backplane/host_agent/memory/edge/syncer.ex`
- Create: `apps/backplane_host_agent/test/backplane/host_agent/memory/edge/syncer_test.exs`
- Create: `apps/backplane_host_agent/test/backplane/host_agent/connector_test.exs`
- Modify: `apps/backplane_host_agent/lib/backplane/host_agent/channel.ex`
- Modify: `apps/backplane_host_agent/lib/backplane/host_agent/connector.ex`
- Modify: `apps/backplane_host_agent/lib/backplane/host_agent/worker.ex`
- Modify: `apps/backplane_host_agent/lib/backplane/host_agent/agent_channel.ex`
- Modify: `apps/backplane_host_agent/lib/backplane/host_agent/memory/facts.ex`
- Modify: `apps/backplane_host_agent/lib/backplane/host_agent/memory_facade.ex`
- Modify: `apps/backplane_host_agent/lib/backplane/host_agent/memory/diagnostics.ex`
- Modify: `apps/backplane_host_agent/test/backplane/host_agent/channel_test.exs`
- Modify: `apps/backplane_host_agent/test/backplane/host_agent/agent_channel_test.exs`
- Modify: `apps/backplane_host_agent/test/backplane/host_agent/worker_test.exs`
- Modify: `apps/backplane_host_agent/test/backplane/host_agent/memory_facade_test.exs`
- Modify: `apps/backplane_host_agent/test/backplane/host_agent/memory/facts_test.exs`
- Modify: `apps/backplane_host_agent/test/backplane/host_agent/memory/diagnostics_test.exs`

- [ ] Write failing tests for v2 offer preservation, explicit selection, `memory_next -> commit -> memory_ack`, wakeup without reconnect, independent backoff, and v1 facts/wipes applied before ACK.
- [ ] Add protection tests proving production/unavailable mode persists no content-bearing v1 facts and emits no success ACK, while a governance wipe remains permitted and ACKs only after its transaction commits.
- [ ] Compose the v2 offer at Channel join while retaining the existing v1 block; pass the join reply through Connector and Worker to the edge syncer.
- [ ] Handle `memory_available` by scheduling an immediate poll. Handle v1 `memory_facts`/`memory_wipe` transactionally and ACK only after commit. Content-bearing v1 fact persistence must consult `Memory.Edge.Protection` and remain disabled in production while protection is unavailable; governance wipes may still remove state.
- [ ] Change offline facade behavior to read `Mirror.offline_read/3`, merge the provisional overlay, and return:

```text
authority = canonical | canonical_with_provisional
source = edge_mirror
consistency = bounded_stale
history_available = true
```

Preserve provisional-only behavior when no committed mirror exists. Preserve canonical online revision metadata instead of overwriting it with nil.
- [ ] Run host-agent and API transport suites; commit `feat(host-agent): converge edge memory without reconnect`.

## PR3 - Bounds, governance, and local reliability

### Task 10: Repair tombstone identity and command outbox state

**Files:**
- Create: `apps/backplane_host_agent/lib/backplane/host_agent/memory/migrations/v2.ex`
- Modify: `apps/backplane_host_agent/lib/backplane/host_agent/memory/migrator.ex`
- Modify: `apps/backplane_host_agent/lib/backplane/host_agent/memory.ex`
- Modify: `apps/backplane_host_agent/lib/backplane/host_agent/memory/facts.ex`
- Modify: `apps/backplane_host_agent/test/backplane/host_agent/memory/migrator_test.exs`
- Modify: `apps/backplane_host_agent/test/backplane/host_agent/memory/facts_test.exs`
- Modify: `apps/backplane_host_agent/test/backplane/host_agent/memory_test.exs`

- [ ] Write a failing migration test with identical content in two scopes and historical pending/inflight/done/failed outbox rows.
- [ ] Rebuild tombstones with `PRIMARY KEY(scope, content_hash)` and preserve every exact row.
- [ ] Migrate outbox states to `pending | inflight | retry_wait | done | dead_letter` with `attempts`, `next_attempt_at`, `last_error`, `completed_at`, and `dead_lettered_at`; conservatively map historical failed rows to dead letter.
- [ ] Add due-FIFO and retention indexes. Run migration twice and prove data preservation.
- [ ] Commit `fix(host-agent): repair memory tombstone and outbox schema`.

### Task 11: Add bounded retry, manual requeue, and retention

**Files:**
- Modify: `apps/backplane_host_agent/lib/backplane/host_agent/memory/syncer.ex`
- Modify: `apps/backplane_host_agent/lib/backplane/host_agent/memory/pruner.ex`
- Modify: `apps/backplane_host_agent/lib/backplane/host_agent/memory/diagnostics.ex`
- Modify: `apps/backplane_host_agent/lib/mix/tasks/agent.memory.resync.ex`
- Modify: `apps/backplane_host_agent/test/backplane/host_agent/memory/syncer_test.exs`
- Modify: `apps/backplane_host_agent/test/backplane/host_agent/memory/pruner_test.exs`
- Modify: `apps/backplane_host_agent/test/backplane/host_agent/memory/diagnostics_test.exs`
- Modify: `apps/backplane_host_agent/test/mix/tasks/agent_memory_tasks_test.exs`

- [ ] Write failing tests for retryable ACK errors, permanent errors, bounded exponential backoff with injected clock/jitter, max-attempt dead letter, restart recovery, selected/all manual requeue, done-row retention, and preservation of pending/deletion guards.
- [ ] Claim only due pending/retry rows. Classify validation/governance errors as permanent and transport/storage/transient server errors as retryable.
- [ ] Use deterministic injected clock/random functions in tests; production backoff is bounded and jittered.
- [ ] Prune only configured old done rows, configured old dead letters, expired cache, safe superseded edge generations, and governance-approved tombstones.
- [ ] Commit `fix(host-agent): make memory commands retryable and observable`.

### Task 12: Enforce edge quotas, deterministic eviction, retention, and telemetry

**Files:**
- Create: `apps/backplane_host_agent/lib/backplane/host_agent/memory/edge/eviction.ex`
- Create: `apps/backplane_host_agent/lib/backplane/host_agent/memory/edge/telemetry.ex`
- Create: `apps/backplane_host_agent/test/backplane/host_agent/memory/edge/eviction_test.exs`
- Create: `apps/backplane_host_agent/test/backplane/host_agent/memory/edge/telemetry_test.exs`
- Create: `apps/backplane_memory/lib/backplane/memory/edge_sync/retention.ex`
- Create: `apps/backplane_memory/test/backplane/memory/edge_sync/retention_test.exs`
- Modify: `apps/backplane_host_agent/lib/backplane/host_agent/memory/edge/store.ex`
- Modify: `apps/backplane_host_agent/lib/backplane/host_agent/memory/mirror.ex`
- Modify: `apps/backplane_host_agent/lib/backplane/host_agent/memory/edge/syncer.ex`
- Modify: `apps/backplane_host_agent/lib/backplane/host_agent/config.ex`
- Modify: `apps/backplane_host_agent/lib/backplane/host_agent/memory/diagnostics.ex`
- Modify: `apps/backplane_host_agent/lib/backplane/host_agent/reporter.ex`
- Modify: `apps/backplane_host_agent/lib/backplane/host_agent/telemetry.ex`
- Modify: `apps/backplane_host_agent/test/backplane/host_agent/memory/edge/store_test.exs`
- Modify: `apps/backplane_host_agent/test/backplane/host_agent/memory/mirror_test.exs`
- Modify: `apps/backplane_host_agent/test/backplane/host_agent/memory/edge/syncer_test.exs`
- Modify: `apps/backplane_host_agent/test/backplane/host_agent/config_test.exs`
- Modify: `apps/backplane_host_agent/test/backplane/host_agent/memory/diagnostics_test.exs`
- Modify: `apps/backplane_host_agent/test/backplane/host_agent/reporter_test.exs`

- [ ] Write failing tests for max bytes/items, per-partition/type quotas, expiry, priority-before-LRU ordering, canonical-ID tie-break, snapshot integrity under bounded selection, and no generated upstream forget.
- [ ] Apply deterministic bounded selection while staging, keep ordered chunk-hash progress, verify the complete manifest, then expose only the bounded generation.
- [ ] Evict in this order: expired, type quota excess, partition quota excess, global excess; within a class sort lowest server priority, oldest access, oldest update, canonical ID.
- [ ] Emit content-free telemetry for protection mode, items/bytes, revision/lag, stale age, delta/snapshot/gap/failure/eviction counts, and command retry/dead-letter counts.
- [ ] Add bounded server change/snapshot retention that never prunes beyond a recoverable snapshot frontier.
- [ ] Run Scenarios C, F, G, and H focused tests; commit `feat(memory): bound and observe host edge storage`.

## PR4 - Projection scalability and processing health

### Task 13: Enforce complete partitions in every generator

**Files:**
- Create: `apps/backplane_system/priv/repo/migrations/20260905000006_enforce_complete_memory_partition.exs`
- Modify: `apps/backplane_memory/lib/backplane/memory/partition_identity.ex`
- Modify: `apps/backplane_memory/lib/backplane/memory/memories.ex`
- Modify: `apps/backplane_memory/lib/backplane/memory/memories/memory.ex`
- Modify: `apps/backplane_memory/lib/backplane/memory/workers/episodic_worker.ex`
- Modify: `apps/backplane_memory/lib/backplane/memory/workers/procedural_worker.ex`
- Modify: `apps/backplane_memory/lib/backplane/memory/workers/graph_extract_worker.ex`
- Modify: `apps/backplane_memory/lib/backplane/memory/workers/profile_build_worker.ex`
- Create: `apps/backplane_memory/test/backplane/memory/memories/memory_test.exs`
- Create: `apps/backplane_memory/test/backplane/memory/complete_partition_migration_test.exs`
- Modify: `apps/backplane_memory/test/backplane/memory/workers/episodic_worker_test.exs`
- Modify: `apps/backplane_memory/test/backplane/memory/workers/procedural_worker_test.exs`
- Modify: `apps/backplane_memory/test/backplane/memory/graph/graph_extract_worker_test.exs`
- Modify: `apps/backplane_memory/test/backplane/memory/memories/profile_build_worker_test.exs`
- Modify: `apps/backplane_memory/test/backplane/memory/direct_boundary_security_test.exs`

- [ ] Write failing tests for nil/blank/mismatched space, host, legacy client, scope, and namespace at each worker boundary.
- [ ] Remove episodic/procedural owner fallbacks and reject incomplete inputs with a durable failed processing state.
- [ ] Backfill or quarantine every historical incomplete row before validating nonblank constraints.
- [ ] Run Scenario I tests and commit `fix(memory): fail closed on incomplete projection partitions`.

### Task 14: Coalesce session repairs and reject stale work

**Files:**
- Create: `apps/backplane_system/priv/repo/migrations/20260905000007_coalesce_projection_repairs.exs`
- Create: `apps/backplane_memory/lib/backplane/memory/projections/repair_frontier.ex`
- Modify: `apps/backplane_memory/lib/backplane/memory/events/store.ex`
- Modify: `apps/backplane_memory/lib/backplane/memory/workers/projection_repair_worker.ex`
- Modify: `apps/backplane_memory/lib/backplane/memory/projections/rebuild.ex`
- Create: `apps/backplane_memory/test/backplane/memory/projections/coalesce_projection_repairs_migration_test.exs`
- Modify: `apps/backplane_memory/test/backplane/memory/projections/projection_repair_worker_test.exs`
- Modify: `apps/backplane_memory/test/backplane/memory/projections/replay_parity_test.exs`
- Modify: `apps/backplane_memory/test/backplane/memory/qualification_test.exs`

- [ ] Replace tests that expect one job per event with failing tests for one durable frontier and at most one pending repair job per `{host_id, session_id}`. Because `input_revision` is a SHA-256 digest, the frontier stores monotonic `requested_generation`, `inflight_generation`, and `completed_generation` watermarks plus the revision hash for each generation; hashes are never ordered lexically.
- [ ] Group batch inserts by host/session, atomically increment `requested_generation` once per accepted batch/session while replacing `requested_revision` with the new canonical digest, and enqueue with Oban uniqueness keyed only by host/session across pending/retryable states. Preserve the legacy `event_id` perform clause for outstanding jobs.
- [ ] A worker locks the frontier and session, snapshots the latest requested generation/hash into the inflight fields, and recomputes the authoritative revision hash. Hash inequality makes the work stale without comparing hashes; if `requested_generation > completed_generation`, the same transaction ensures exactly one host/session successor is pending. Events arriving during a running job only advance the monotonic generation and latest digest, so 10,000 events cannot create 10,000 pending jobs.
- [ ] Migrate/deduplicate eligible pending legacy jobs without deleting completed history.
- [ ] Prove 10,000 events create a bounded job count, generation watermarks increase monotonically while revision digests remain opaque, and shuffled/late job order converges identically.
- [ ] Run Scenario J and commit `fix(memory): coalesce projection repair by revision`.

### Task 15: Record precise processing states across every family

**Files:**
- Create: `apps/backplane_system/priv/repo/migrations/20260905000008_expand_memory_processing_states.exs`
- Create: `apps/backplane_memory/lib/backplane/memory/projections/processing_state.ex`
- Modify: `apps/backplane_memory/lib/backplane/memory/projections/state.ex`
- Modify: `apps/backplane_memory/lib/backplane/memory/workers/summary_worker.ex`
- Modify: `apps/backplane_memory/lib/backplane/memory/workers/episodic_worker.ex`
- Modify: `apps/backplane_memory/lib/backplane/memory/workers/procedural_worker.ex`
- Modify: `apps/backplane_memory/lib/backplane/memory/workers/embed_worker.ex`
- Modify: `apps/backplane_memory/lib/backplane/memory/workers/graph_extract_worker.ex`
- Modify: `apps/backplane_memory/lib/backplane/memory/workers/profile_build_worker.ex`
- Modify: `apps/backplane_memory/lib/backplane/memory/workers/crystal_worker.ex`
- Modify: `apps/backplane_memory/test/backplane/memory/workers/summary_worker_test.exs`
- Modify: `apps/backplane_memory/test/backplane/memory/workers/summary_worker_concurrency_test.exs`
- Modify: `apps/backplane_memory/test/backplane/memory/workers/episodic_worker_test.exs`
- Modify: `apps/backplane_memory/test/backplane/memory/workers/procedural_worker_test.exs`
- Modify: `apps/backplane_memory/test/backplane/memory/workers/embed_worker_test.exs`
- Modify: `apps/backplane_memory/test/backplane/memory/graph/graph_extract_worker_test.exs`
- Modify: `apps/backplane_memory/test/backplane/memory/memories/profile_build_worker_test.exs`
- Create: `apps/backplane_memory/test/backplane/memory/workers/crystal_worker_test.exs`
- Modify: `apps/backplane_memory/test/backplane/memory/projections/state_test.exs`

- [ ] Write failing state-transition tests for pending, enqueued compatibility, running, complete, skipped_no_model, skipped_disabled, failed, and dead_letter.
- [ ] Use stable processing identity for all seven families:

```text
summary, semantic, graph, crystallization:
  subject_type=captured_session, subject_id=stable host/session subject ID,
  input_revision=canonical session input revision
procedural:
  subject_type=memory_partition, subject_id=stable canonical partition key,
  input_revision=hash of sorted qualifying canonical inputs
embedding:
  subject_type=memory, subject_id=canonical memory UUID,
  input_revision=canonical content revision/hash
profile:
  subject_type=memory_profile, subject_id=stable canonical partition/project key,
  input_revision=hash of sorted canonical source revisions
```

- [ ] Migrate every historical generic `skipped` row before replacing the database constraint: explicit no-model reasons become `skipped_no_model`, explicit disabled reasons become `skipped_disabled`, and unclassifiable rows become `failed` with their original reason retained. The new write/read contract and DB constraint then exclude generic `skipped` entirely.
- [ ] Record one durable terminal reason for every scheduled processing family; no-model and disabled branches must not return invisible `:ok`.
- [ ] Preserve stale-write guards and Oban retry semantics.
- [ ] Commit `feat(memory): expose complete projection processing states`.

## PR5 - Contract cutover, qualification, and release gates

### Task 16: Unify canonical and host memory tool contracts

**Files:**
- Create: `apps/backplane_memory_contract/mix.exs`
- Create: `apps/backplane_memory_contract/lib/backplane/memory_tool_contract.ex`
- Create: `apps/backplane_memory_contract/test/backplane/memory_tool_contract_test.exs`
- Create: `apps/backplane_memory_contract/test/test_helper.exs`
- Modify: `apps/backplane_memory/lib/backplane/memory/service.ex`
- Modify: `apps/backplane_memory/mix.exs`
- Modify: `apps/backplane_host_agent/lib/backplane/host_agent/services/memory.ex`
- Modify: `apps/backplane_host_agent/lib/backplane/host_agent/memory_router.ex`
- Modify: `apps/backplane_host_agent/mix.exs`
- Modify: `apps/backplane_system/lib/backplane/memory_permissions.ex`
- Modify: `apps/backplane_system/mix.exs`
- Create: `apps/backplane_system/test/backplane/memory_permissions_test.exs`
- Create: `apps/backplane_api/test/backplane/api/memory_tool_schema_parity_test.exs`
- Modify: `apps/backplane_memory/test/backplane/memory/service_tools_test.exs`
- Modify: `apps/backplane_memory/test/backplane/memory/namespace_contract_test.exs`
- Modify: `apps/backplane_host_agent/test/backplane/host_agent/memory_router_test.exs`
- Modify: `.github/workflows/test.yml`
- Modify: `test/ci_workflow_test.exs`

- [ ] Classify tools into three explicit sets: canonical-overlap tools have exact shared names/schemas on direct, connected, and disconnected discovery; server-only tools appear direct/connected and are absent offline; device-local tools remain locally executable and are absent from the direct server contract unless intentionally shared.
- [ ] Write failing transport parity tests for exact names, schemas, required fields, and `_meta["backplane"] = %{permission, authority, consistency, availability}` within each applicable set. Disconnected discovery may expose fewer server-only tools, but must not drift on canonical-overlap definitions.
- [ ] Make `backplane_memory_contract` a process-free dependency-neutral app with no server-runtime dependencies. Move schemas and the canonical tool-to-permission map into `MemoryToolContract`; make `Backplane.MemoryPermissions` delegate to it so permissions have one owner.
- [ ] Make connected host discovery prefer canonical definitions and route every canonical-overlap/server tool remotely even when a same-named slot/facet/replay local handler exists. Route only the explicit device-local set locally; retain usable local discovery and execution offline.
- [ ] Add `backplane_memory_contract` to the per-app CI matrix and update its contract test.
- [ ] Commit `feat(memory): unify host and canonical tool schemas`.

### Task 17: Add the A-J real-store qualification suite

**Files:**
- Create: `apps/backplane_api/test/backplane/api/memory_v2_edge_qualification_test.exs`
- Modify: `apps/backplane_api/test/backplane/api/memory_m18_outage_qualification_test.exs`
- Modify: `apps/backplane_host_agent/test/backplane/host_agent/memory/capture_outage_contract_test.exs`
- Modify: `apps/backplane_host_agent/test/backplane/host_agent/memory_facade_test.exs`
- Modify: `apps/backplane_host_agent/test/backplane/host_agent/memory/mirror_test.exs`
- Modify: `apps/backplane_host_agent/test/backplane/host_agent/memory/edge/syncer_test.exs`
- Modify: `apps/backplane_memory/test/backplane/memory/ingest_test.exs`
- Modify: `apps/backplane_memory/test/backplane/memory/direct_boundary_security_test.exs`
- Modify: `apps/backplane_memory/test/backplane/memory/projections/projection_repair_worker_test.exs`

- [ ] Implement one named test/fixture per handoff Scenario A-J. Use real PostgreSQL/Turso stores and transport integration for C, E, F, G, and H; mock only external LLM/network edges.
- [ ] Assert automated evidence for canonical Recall V2 metadata, unsafe-fallback rejection, restart persistence, live convergence, delete non-resurrection, quotas, complete partition, and bounded projection jobs.
- [ ] Run the entire qualification file with three seeds and record edge bytes/items and 10,000-event job counts.
- [ ] Commit `test(memory): qualify memory v2 authority and convergence`.

### Task 18: Publish protocol, authority model, runbook, and cutover notes

**Files:**
- Create: `docs/memory/host-memory-v2-protocol.md`
- Create: `docs/operations/host-memory-edge-runbook.md`
- Modify: `docs/host-agent-memory-design-final.md`
- Modify: `docs/architecture/memory-v2.md`
- Modify: `docs/operations/memory-v2.md`
- Modify: `docs/deploy/memory-v2-release.md`
- Modify: `docs/qualification/memory-v2.md`
- Modify: `docs/qualification/memory-v2-capability-matrix.md`
- Modify: `docs/memory/memory-v2-implementation-audit.md`

- [ ] Document the exact negotiated wire contract, cursor/snapshot algorithms, error taxonomy, v1 compatibility flags, migration/rollback sequence, and production protection restriction from implemented code.
- [ ] Mark the old local-first authority text superseded and publish final ownership/routing matrices.
- [ ] Add exact operator commands/queries for stuck cursors, forced snapshot, dead-letter requeue, stale mirrors, retention/protection incidents, and rollback.
- [ ] Include measured edge usage and projection scheduling counts from Task 17.
- [ ] Commit `docs(memory): publish host memory v2 operations model`.

### Task 19: Update release qualification and migration ceiling

**Files:**
- Modify: `.github/workflows/release.yml`
- Modify: `test/release_config_test.exs`
- Create: `apps/backplane_memory/lib/backplane/memory/readiness.ex`
- Create: `apps/backplane_memory/lib/mix/tasks/backplane.memory.edge_cutover_check.ex`
- Create: `apps/backplane_memory/test/backplane/memory/readiness_test.exs`
- Create: `apps/backplane_memory/test/backplane/memory/memory_v2_upgrade_test.exs`
- Create: `apps/backplane_host_agent/test/backplane/host_agent/memory/v1_to_v2_upgrade_test.exs`

- [ ] Write failing release-contract assertions for latest migration `20260905000008`, packaged protocol/runbook, PR4 qualifications, and A-J edge qualification.
- [ ] Define issue dispositions as `pending | resolved | approved_waiver`. `resolved` and `approved_waiver` count as complete only with `resolved_at`; every other row blocks cutover.
- [ ] Implement one fail-closed `Backplane.Memory.Readiness.edge_cutover/0` entrypoint and `mix backplane.memory.edge_cutover_check` wrapper. It returns success only when mappings, root/child/audit/job inventories, initial snapshots, and issue dispositions are ready; `.github/workflows/release.yml` must run that exact command.
- [ ] Add real upgrade tests from the previous server migration head through `20260905000008` and from an existing populated host Turso v1 command database through local v2/edge migrations. Assert preserved commands, tombstones, canonical data, and rollback-compatible feature flags, not only fresh-schema idempotency.
- [ ] Add focused workflow commands without weakening existing format/compile/Credo/Dialyzer/per-app gates.
- [ ] Run release-config and workflow tests; commit `ci(memory): qualify revisioned edge cutover`.

### Task 20: Final completion audit and branch integration gate

- [ ] Run formatting and warnings-as-errors compilation:

```bash
devenv shell -- mix format --check-formatted
devenv shell -- mix compile --warnings-as-errors
```

- [ ] Run scoped suites, then the full umbrella suite:

```bash
devenv shell -- env MIX_ENV=test mix test apps/backplane_host_agent/test
devenv shell -- env MIX_ENV=test mix test apps/backplane_api/test
devenv shell -- env MIX_ENV=test mix test apps/backplane_memory/test
devenv shell -- env MIX_ENV=test mix test
```

- [ ] Run static analysis:

```bash
devenv shell -- mix credo --strict
devenv shell -- mix dialyzer
```

- [ ] Run release and installed-migration qualification required by `.github/workflows/release.yml`.
- [ ] Audit every handoff requirement, PR2 design validation item, migration, feature flag, error class, and A-J scenario against fresh command output.
- [ ] Confirm production plaintext edge persistence remains disabled while `gsmlg-dev/concord#91` is unresolved; report this as a deployment restriction, not a silent fallback.
- [ ] Dispatch final spec and code-quality reviews, fix every finding, re-run affected and full gates, then use the finishing-a-development-branch workflow.
- [ ] Publish the final remediation report with before/after architecture diagrams, ownership and routing matrices, protocol compatibility, migrations/rollback, measured edge usage, projection job counts, remaining issues, and exact CI status. Do not mark any path fixed without an automated integration test.
