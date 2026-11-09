# Memory Plan 2 — Host Offline Save & Local Recall Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When the gateway is unreachable, the host agent still saves (`remember`/`forget`) memories durably and answers `search/get/recent` from memories stored on this host; queued writes upload idempotently on reconnect, and the host keeps a pulled copy of every memory whose provenance host is itself.

**Architecture:** The host's existing Turso/SQLite store (`Backplane.HostAgent.Memory.{Store,Migrator,Supervisor}`) gets a clean-slate V8 schema: `local_records`, `memory_outbox`, `memory_sync_state`. A new `Backplane.HostAgent.Memory.Local` context owns it. `memory_router.ex` falls back to `Local` on transport errors. A new `Backplane.HostAgent.Memory.OutboxSync` GenServer flushes the outbox in order and pulls this host's changed records through a new gateway channel event `memory_pull`. Health counters flow through the existing reporter to the admin host page.

**Tech Stack:** Elixir umbrella, ex_turso 3.1.16 (SQLite-compatible), Phoenix channels, Ecto/Postgres on the gateway, phoenix_duskmoon admin.

**Spec:** `docs/superpowers/specs/2026-11-09-memory-simplification-design.md` §6.11 (offline), §6.3 (provenance), §4 (no silent failures).

## Global Constraints

- One user; provenance is never an authorization boundary. The pull is limited to `host_id == channel host` only because §6.11 says "do not mirror other hosts' memories", not for access control.
- Local data may be destroyed: V8 drops every legacy host memory table; no data migration.
- Offline-saved results are explicitly marked: write results carry `"sync": "pending"`; offline reads carry `"offline": true, "source": "local"`.
- Uploads are idempotent: every host-originated `remember` carries a `request_key` (`"host-agent:" <> UUIDv7`) generated before the first attempt and reused on every retry.
- Non-transport gateway errors are never retried silently: the outbox entry becomes `failed` with `last_error`, is reported in health, and does not block later entries.
- macOS dev uses Postgres.app (`unset PGHOST`); never start devenv.
- Commit once per task on the feature branch with Conventional Commits; no Claude/Generated-with trailers. Run tests per app (`mix test apps/<app>/test/...`).
- ex_turso#9 (reopen wedge) is fixed upstream (closed 2026-07-07); no workaround needed.

## Review Focus

1. Gateway timed out but actually wrote the record → the outbox resend with the same `request_key` returns the same gateway record; the local row maps to that `remote_id`; no duplicate on the gateway. Test in Task 3/4.
2. `forget` of a record created offline before its `remember` has synced → the forget waits until the remember syncs, then uses the resolved `remote_id`. Test in Task 4.
3. Host restart with a non-empty outbox → entries survive (on disk) and flush after restart. Test in Task 4.
4. A host record superseded or forgotten on the gateway → the next pull updates the local status; offline `search` excludes it by default. Test in Task 4.
5. A gateway validation error during flush (e.g. invalid kind) → the entry becomes `failed` with `last_error`, is counted in health, and later entries still flush. Test in Task 4/5.

---

### Task 1: Gateway — changed-since query and `memory_pull` channel event

**Files:**
- Modify: `apps/backplane_memory/lib/backplane/memory/records.ex` (add `changed_since/3`, `to_map/1`)
- Modify: `apps/backplane_memory/lib/backplane/memory/tools.ex` (use `Records.to_map/1` instead of its private serializer)
- Create: `apps/backplane_system/priv/repo/migrations/20261110000001_index_memory_records_host_updated.exs` (btree index on `memory_records (host_id, updated_at, id)`; prefix-safe like the 2026110900000x migrations)
- Modify: `apps/backplane_api/lib/backplane/api/channels/host_agent_channel.ex` (new `handle_in("memory_pull", ...)`)
- Test: `apps/backplane_memory/test/backplane/memory/records_test.exs`, `apps/backplane_api/test/backplane/api/channels/host_agent_channel_test.exs`

**Interfaces:**
- Produces:
  - `Records.to_map(Record.t()) :: map()` — exactly the record shape Tools already returns (`"id","kind","title","content","subjects","property","tags","status","superseded_by","forgotten_reason","observed_at","provenance"`), plus `"updated_at"` (ISO 8601 usec).
  - `Records.changed_since(host_id :: String.t(), cursor :: nil | %{updated_at: DateTime.t(), id: Ecto.UUID.t()}, limit :: pos_integer()) :: [Record.t()]` — all statuses, `host_id = ^host_id`, ordered `updated_at asc, id asc`, strictly after the `(updated_at, id)` cursor; `limit` clamped to 1..500.
  - Channel event `"memory_pull"`: payload `%{"cursor" => nil | %{"updated_at" => iso, "id" => uuid}, "limit" => int}`; requires the socket token scope that maps to `memory.read` (`host_agent.recall`); replies `{:ok, %{"records" => [map], "cursor" => nil | %{"updated_at","id"}}}` where `cursor` is the last returned record's pair (or the request cursor when empty). Host id always comes from the socket, never the payload. Invalid cursor → `{:error, %{"code" => "invalid_cursor"}}`; missing scope → `{:error, %{"code" => "unauthorized"}}`.

- [ ] **Step 1: Write failing tests:** `changed_since returns only the host's records after the cursor in order` (three records for host A with distinct timestamps, one for host B; cursor after the first → second and third only); `changed_since includes superseded and forgotten records`; `changed_since respects limit and clamps 0/1000`; channel test `memory_pull returns socket host records and a cursor` (payload with a spoofed `"host_id"` is ignored); `memory_pull without recall scope is unauthorized`; `memory_pull with malformed cursor returns invalid_cursor`.
- [ ] **Step 2: Run** `mix test apps/backplane_memory/test/backplane/memory/records_test.exs` and `mix test apps/backplane_api/test/backplane/api/channels/host_agent_channel_test.exs` — Expected: FAIL.
- [ ] **Step 3: Implement** the interfaces above and the migration.
- [ ] **Step 4: Run** the same tests plus `mix test apps/backplane_memory/test/backplane/memory/tools_test.exs` — Expected: PASS.
- [ ] **Step 5: Commit** `feat(memory): add host changed-since pull over the host channel`.

---

### Task 2: Host local schema V8 and `Memory.Local` context

**Files:**
- Create: `apps/backplane_host_agent/lib/backplane/host_agent/memory/migrations/v8.ex`
- Modify: `apps/backplane_host_agent/lib/backplane/host_agent/memory/migrator.ex` (register V8)
- Create: `apps/backplane_host_agent/lib/backplane/host_agent/memory/local.ex`
- Test: `apps/backplane_host_agent/test/backplane/host_agent/memory/local_test.exs`, update `migrator` test if present

**Interfaces:**
- V8 `up/0`: `DROP TABLE IF EXISTS` every pre-V8 memory table (`memories`, `facts`, `memory_outbox`, `slots`, `tombstones`, `canonical_memory_receipts`, `memory_access_global`, `memory_access_state`, `memory_request_keys`, and any other table created by V1–V7 — list them from the migration files), then create:
  - `local_records(local_id TEXT PRIMARY KEY, remote_id TEXT UNIQUE, request_key TEXT UNIQUE, kind TEXT NOT NULL, title TEXT, content TEXT NOT NULL, subjects TEXT NOT NULL DEFAULT '[]', property TEXT, tags TEXT NOT NULL DEFAULT '[]', status TEXT NOT NULL DEFAULT 'active', superseded_by TEXT, forgotten_reason TEXT, writer TEXT NOT NULL, agent_id TEXT, integration TEXT, session_id TEXT, observed_at TEXT NOT NULL, updated_at TEXT NOT NULL, sync_state TEXT NOT NULL CHECK (sync_state IN ('pending','synced','failed')))` with indexes on `(status, observed_at)`, `(kind, status)`.
  - `memory_outbox(seq INTEGER PRIMARY KEY AUTOINCREMENT, op TEXT NOT NULL CHECK (op IN ('remember','forget')), local_id TEXT NOT NULL, payload TEXT NOT NULL, state TEXT NOT NULL DEFAULT 'pending' CHECK (state IN ('pending','failed')), attempts INTEGER NOT NULL DEFAULT 0, last_error TEXT, inserted_at TEXT NOT NULL, updated_at TEXT NOT NULL)`.
  - `memory_sync_state(key TEXT PRIMARY KEY, value TEXT NOT NULL)`.
  - JSON columns are stored as encoded strings (Jason).
- `Backplane.HostAgent.Memory.Local` (all functions take `store` first, defaulting to `Backplane.HostAgent.Memory.Store`):
  - `queue_remember(store, args :: map, request_key :: String.t()) :: {:ok, map}` — inserts `local_records` (`sync_state: "pending"`, `local_id` UUIDv7 via `Memory.Uuid7`, `writer` from args default `"agent"`, `observed_at` now) and an outbox `remember` row whose payload is `args` + `"request_key"`, in one transaction; returns the record map (same keys as `Records.to_map/1`, with `"id" => local_id`, `"sync" => "pending"`).
  - `queue_forget(store, id :: String.t(), reason :: String.t()) :: {:ok, map} | {:error, :not_found}` — `id` may be a `remote_id` or `local_id`; marks the row `forgotten` locally and enqueues `forget` with payload `%{"reason" => reason}`; already-inactive rows return `{:ok, row}` without a new outbox entry.
  - `upsert_remote(store, record :: map) :: {:ok, map}` — upsert by `remote_id` (= record `"id"`); if the row has a matching `request_key`, fill `remote_id` on that row instead of inserting; sets `sync_state: "synced"`.
  - `search(store, query :: String.t(), filters :: map) :: [map]` — `LIKE` on title/content/subjects for each whitespace term of ≥2 chars (AND across terms); filters `"kind"`, `"agent"`, `"subject"` (`"type:key"`), `"since"`, `"include_inactive"` (default false), `"limit"` (default 10, max 50); ordered `observed_at desc`.
  - `get(store, id) :: {:ok, map} | {:error, :not_found}`; `recent(store, filters) :: [map]` (kind `worklog`, active, `observed_at desc`, default 20, max 100).
  - `pending_outbox(store, limit) :: [map]` (state `pending`, ordered by `seq`); `complete(store, seq, remote :: map)` (delete outbox row; `upsert_remote`); `fail(store, seq, reason :: String.t())` (state `failed`, `last_error`, `attempts + 1`, and the record's `sync_state` → `failed`); `bump_attempt(store, seq, reason)` (stays pending, `attempts + 1`, `last_error`).
  - `get_state(store, key) :: String.t() | nil`, `put_state(store, key, value)`.
  - `stats(store) :: %{"outbox_pending" => int, "outbox_failed" => int, "local_records" => int, "last_sync_at" => iso | nil, "last_error" => String.t() | nil}` (`last_sync_at`/`last_error` read from `memory_sync_state`).

- [ ] **Step 1: Write failing tests** in `local_test.exs` (temp-file Turso store via the existing test helpers used by host memory tests): migrating a V7 database to V8 leaves only the three new tables plus sqlite internals; `queue_remember` creates a pending record and one outbox row with the request_key in its payload; `upsert_remote` with matching request_key fills `remote_id` on the same row (no second row); `queue_forget` by remote_id and by local_id; already-forgotten → no new outbox row; `search` matches CJK term `部署` and excludes forgotten unless `include_inactive`; `fail` makes `stats()["outbox_failed"] == 1`.
- [ ] **Step 2: Run** `mix test apps/backplane_host_agent/test/backplane/host_agent/memory/local_test.exs` — Expected: FAIL.
- [ ] **Step 3: Implement** V8, register it, implement `Local`.
- [ ] **Step 4: Run** the test file and `mix test apps/backplane_host_agent/test` — Expected: PASS.
- [ ] **Step 5: Commit** `feat(host-agent): add local memory records and outbox schema`.

---

### Task 3: Router — offline writes and local reads

**Files:**
- Modify: `apps/backplane_host_agent/lib/backplane/host_agent/memory_router.ex`
- Test: `apps/backplane_host_agent/test/backplane/host_agent/memory_router_test.exs`

**Interfaces:**
- Consumes: `Local.*` (Task 2), `HubProxy.call_tool/2`.
- Behavior (both `/memory/:agent_id/mcp` `tools/call` and `/memory/:agent_id/call/:method`):
  - `remember`: set `args["request_key"]` to `"host-agent:" <> Uuid7.generate()` if absent; forward. On `{:ok, record}` → `Local.upsert_remote(record)`, return record. On `"gateway_unavailable"` or `"gateway_timeout"` → `Local.queue_remember(args_with_agent, request_key)`, return `{:ok, pending_map}` (HTTP 200 on `/call`). Other errors → returned unchanged, nothing queued.
  - `forget`: forward; on success `upsert_remote`. On transport error → `Local.queue_forget`; `{:error, :not_found}` locally → error `"gateway_unavailable"` (cannot forget an unknown record offline).
  - `search` / `get` / `recent`: forward; on transport error answer from `Local` and wrap: `search`/`recent` → `%{"results" => [...], "offline" => true, "source" => "local"}`; `get` → `%{"record" => map, "history" => [], "offline" => true, "source" => "local"}` or `"not_found"`.
  - When the local memory store is disabled (`memory.enabled: false` / no store process), behave exactly as Plan 1 (errors pass through).

- [ ] **Step 1: Write failing tests** with the existing `ScriptedHubProxy` seam: offline remember returns 200 with `"sync" => "pending"` and an outbox row exists; timeout remember also queues and keeps the generated request_key; online remember passes a `request_key` to the hub and caches the result (`Local.get(remote_id)` finds it); validation error (`%{"code" => "invalid"}`) is returned and nothing is queued; offline search returns `"offline" => true` and only local active records; offline forget of an unknown id → `gateway_unavailable`; store disabled → Plan 1 behavior.
- [ ] **Step 2: Run** `mix test apps/backplane_host_agent/test/backplane/host_agent/memory_router_test.exs` — Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the router test and `mix test apps/backplane_host_agent/test` — Expected: PASS.
- [ ] **Step 5: Commit** `feat(host-agent): save and recall memories while the gateway is offline`.

---

### Task 4: `OutboxSync` — ordered flush and host pull

**Files:**
- Create: `apps/backplane_host_agent/lib/backplane/host_agent/memory/outbox_sync.ex`
- Modify: `apps/backplane_host_agent/lib/backplane/host_agent/memory/supervisor.ex` (add `OutboxSync` after `Migrator`)
- Modify: `apps/backplane_host_agent/lib/backplane/host_agent/hub_proxy.ex` (add `pull_memory(cursor, limit)` pushing `"memory_pull"`)
- Test: `apps/backplane_host_agent/test/backplane/host_agent/memory/outbox_sync_test.exs`

**Interfaces:**
- `OutboxSync.start_link(opts)` — opts `store`, `hub_proxy` (default `HubProxy`), `interval_ms` (from memory config `sync_interval_ms`, default 5000), `batch_size` (`sync_batch_size`, default 50).
- `OutboxSync.sync_now(server \\ __MODULE__) :: :ok` (synchronous; used by tests and on channel reconnect).
- One cycle: if `MemoryProxy.channel()` is not alive → skip. Flush `Local.pending_outbox(batch_size)` in `seq` order:
  - `remember` → `call_tool("memory::remember", payload)`; `{:ok, rec}` → `Local.complete(seq, rec)`.
  - `forget` → resolve the row's `remote_id`; if nil (its remember not yet synced) stop this cycle's flush; else `call_tool("memory::forget", %{"id" => remote_id, "reason" => ...})`; ok → `complete`.
  - Transport error (`:not_connected`, `:closed`, `:disconnected`, `:noproc`, `{:channel_exit, _}`, `:timeout`) → `bump_attempt`, stop flushing this cycle.
  - Any other error → `Local.fail(seq, reason_string)`, `Logger.warning`, continue with the next entry.
- Then pull: loop `HubProxy.pull_memory(cursor, 200)` from `Local.get_state("pull_cursor")` (JSON), `Local.upsert_remote/2` each record, save cursor, stop when fewer than 200 returned. On success `put_state("last_sync_at", now)`; on error `put_state("last_error", reason)` and `Logger.warning`.
- `HubProxy.pull_memory(cursor :: map | nil, limit) :: {:ok, %{"records" => list, "cursor" => map | nil}} | {:error, term}`.

- [ ] **Step 1: Write failing tests** (scripted hub proxy + real temp store): ordered flush of two queued remembers; resend with same request_key mapping to the same remote id (Review Focus 1); offline-created record + queued forget → forget only sent after remember synced, with remote id (Review Focus 2); restart: stop and restart the supervisor on the same DB file, pending entries flush (Review Focus 3); pull applies a forgotten status and offline `Local.search` excludes it (Review Focus 4); validation error → failed + later entry still flushed + `stats()["outbox_failed"] == 1` (Review Focus 5); channel down → no calls made.
- [ ] **Step 2: Run** `mix test apps/backplane_host_agent/test/backplane/host_agent/memory/outbox_sync_test.exs` — Expected: FAIL.
- [ ] **Step 3: Implement**; call `OutboxSync.sync_now/1` (cast variant) when the worker (re)establishes the channel (`worker.ex` where `MemoryProxy.set_channel/1` is called).
- [ ] **Step 4: Run** the test and `mix test apps/backplane_host_agent/test` — Expected: PASS.
- [ ] **Step 5: Commit** `feat(host-agent): flush memory outbox and pull host records on reconnect`.

---

### Task 5: Health reporting, admin visibility, config cleanup

**Files:**
- Modify: `apps/backplane_host_agent/lib/backplane/host_agent/reporter.ex` (memory section = `Local.stats/1` when the store is running; drop mirror/partition/edge fields)
- Modify: `apps/backplane_host_agent/lib/backplane/host_agent/config.ex` (`parse_memory`: keep `enabled`, `db_path`, `sync_interval_ms`, `sync_batch_size`; remove `bound_scope`, `local_ttl_days`, `tombstone_relearn`, `host_sync`/`parse_edge`, `import_profiles`; unknown keys still ignored)
- Modify: `apps/backplane_skills/lib/backplane/skills/agent_manage.ex` (memory allowlist/sanitizer matches the new reported keys)
- Modify: `apps/backplane_admin/lib/backplane/admin/live/host_agents_live.ex` (replace "Reported mirror partitions" with: pending uploads, failed uploads (warning badge when > 0, showing `last_error`), local records, last sync)
- Modify: `apps/backplane_host_agent/lib/backplane/host_agent/memory/spool/turso.ex` (remove leftover `claude_code_import` reference if unused); `apps/backplane_memory/lib/backplane/memory/audit.ex` (remove `contract_operations/0` if it has no callers)
- Modify: `docs/memory/examples/host-agent.local.yaml.example` (memory block = the four kept keys)
- Test: `reporter_test`, `config_test` (host), `agent_manage_test`, `host_agents_live_test`

- [ ] **Step 1: Write failing tests:** reporter includes `outbox_pending/outbox_failed/local_records/last_sync_at/last_error`; config parse of a YAML containing `bound_scope`/`host_sync` loads and drops them; admin page shows "Failed uploads: 1" and the last error for a host whose report has `outbox_failed: 1`; agent_manage passes the new keys through and drops unknown ones.
- [ ] **Step 2: Run** those test files — Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `mix test apps/backplane_host_agent/test`, `mix test apps/backplane_skills/test`, `mix test apps/backplane_admin/test` — Expected: PASS.
- [ ] **Step 5: Commit** `feat(host-agent): report local memory sync health`.

---

### Task 6: Docs, full gate, live end-to-end

**Files:**
- Modify: `docs/architecture/memory.md` (offline section: local store, outbox, pull cursor, what is/isn't mirrored)
- Modify: `docs/superpowers/specs/2026-11-09-memory-simplification-design.md` (status line: Plan 2 implemented)

- [ ] **Step 1: Full gate** with `unset PGHOST` (Postgres.app): `MIX_ENV=test mix ecto.migrate`, `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix credo --strict`, `mix dialyzer`, per-app `mix test` for backplane_memory, backplane_api, backplane_host_agent, backplane_skills, backplane_admin, backplane_system, backplane_mcp, plus `mix run --no-start test/ci_workflow_test.exs` and `mix run --no-start test/release_config_test.exs`. Expected: all pass.
- [ ] **Step 2: Live e2e** (Postgres.app, `unset PGHOST`): `mix ecto.migrate`; start `mix backplane.run` and `mix agent.run` in the background; `POST localhost:4222/memory/e2e/call/remember` (online) → appears in gateway; stop the gateway; `remember` again → `"sync":"pending"`; `call/search` → `"offline":true` and both records found; restart the gateway; within ~10s the pending record exists in `memory_records` exactly once with `provenance.host` = this host; `forget` it via gateway `/mcp`; after the next sync, offline `search` (gateway stopped again) no longer returns it. Stop all services at the end.
- [ ] **Step 3: Commit** `docs(memory): document host offline memory`.
