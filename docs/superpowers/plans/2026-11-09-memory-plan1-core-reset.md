# Memory Plan 1 — Core Reset Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the partitioned Backplane Memory with one global, provenance-tagged memory store exposing `memory::search/get/recent/remember/forget` on the gateway and the host agent, while event capture keeps working and all partition, edge-sync, peripheral and old-extraction code is deleted.

**Architecture:** A new `memory_records` table plus a `Backplane.Memory.Records` context and a five-tool managed service `Backplane.Memory.Service` replace `bpm_memories` and the 40-tool service. Capture (host spool → channel `memory_events` → `Ingest` → `bpm_events` → projections) is kept, with partition checks removed. The host agent forwards all `memory::*` calls to the gateway over the existing `mcp_tool_call` channel path. After the new path is green, the old code, tables, admin pages and CI steps are deleted.

**Tech Stack:** Elixir umbrella (OTP 28), Ecto/Postgres (FTS `tsvector`), Phoenix channels, Styx jobs, phoenix_duskmoon admin.

**Spec:** `docs/superpowers/specs/2026-11-09-memory-simplification-design.md`

**Plan series:** 1 core reset (this) → 2 host offline outbox/local recall → 3 memory agent distillation (+ vector search, embeddings, "session already distilled by agent" mark) → 4 host collectors → 5 plugins. Plan 1 search is full-text only; vector fusion is Plan 3.

## Global Constraints

- One user. host/agent/session/client are provenance only; no code may filter, authorize or partition by them unless the caller passes an explicit filter.
- Existing memory data may be destroyed; no backfill or compatibility code.
- New migrations go in `apps/backplane_system/priv/repo/migrations/` with timestamps after `20261108000000`.
- Schema/context live in `apps/backplane_memory`; admin UI uses `phoenix_duskmoon` components only.
- MCP namespace stays `memory::`; scopes are only `memory.read` (search/get/recent) and `memory.write` (remember/forget).
- `services.memory.enabled` defaults to `true`.
- Failures must not be silent: tool errors return a reason string; no `Logger.debug`-only skips.
- Do not commit, push or branch unless the user explicitly asks (AGENTS.md). "Checkpoint" steps below mean: run the listed verification and stop for review.
- Run focused tests per task (`mix test <path>`); run `mix compile --warnings-as-errors` at every checkpoint.
- Hermes/OpenClaw plugins and `integrations/memory/*` will stop working with the new tool contract; that is accepted and fixed in Plan 5. Do not patch them here.

## Review Focus

1. Fact supersede when subjects are given in a different order or case (`[{repo,X},{host,web-01}]` vs `[{host,WEB-01},{repo,X}]`) — must be treated as the same subject set. Test in Task 1.
2. `remember` retried with the same `request_key` (host retries after a timeout) — must return the same record, not a duplicate. Test in Task 1.
3. `search` with a query containing tsquery syntax characters (`foo & | ! :*`, quotes, Chinese text) — must not raise; must return matches. Test in Task 1.
4. A host whose `skill_hosts.memory_scope` is nil/blank (all hosts after this plan) still captures events end to end. Test in Task 3.
5. `forget` of an already-superseded or already-forgotten id — returns `{:ok, record}` idempotently with the original reason kept; unknown id returns `not_found`. Test in Task 1.

---

### Task 1: New `memory_records` schema and `Records` context

**Files:**
- Create: `apps/backplane_system/priv/repo/migrations/20261109000001_create_memory_records.exs`
- Create: `apps/backplane_memory/lib/backplane/memory/record.ex`
- Create: `apps/backplane_memory/lib/backplane/memory/records.ex`
- Create: `apps/backplane_memory/lib/backplane/memory/records/search.ex`
- Test: `apps/backplane_memory/test/backplane/memory/records_test.exs`

**Interfaces:**
- Produces:
  - Table `memory_records`: `id uuid pk`, `kind text not null` (check in `fact|procedure|worklog|note`), `title text`, `content text not null`, `subjects jsonb not null default '[]'` (list of `{"type","key"}`), `subject_keys text[] not null default '{}'` (normalized `"type:key"`, lowercased, sorted, deduped; GIN index), `property text`, `tags text[] default '{}'`, `confidence float`, `status text not null default 'active'` (check `active|superseded|forgotten`), `superseded_by uuid references memory_records`, `forgotten_reason text`, `forgotten_at utc_datetime_usec`, `writer text not null` (check `agent|memory_agent|user|host_collector`), `host_id text`, `agent_id text`, `integration text`, `session_id text`, `client_id text`, `source_event_ids uuid[] default '{}'`, `request_key text` (unique where not null), `observed_at utc_datetime_usec not null`, timestamps; generated stored column `search_tsv tsvector = to_tsvector('simple', coalesce(title,'') || ' ' || content || ' ' || array_to_string(subject_keys,' '))` with GIN index; btree indexes on `(status, observed_at desc)`, `(kind, status)`, `host_id`, `agent_id`.
  - `Backplane.Memory.Record` — Ecto schema for the table; `changeset(record, attrs)`.
  - `Backplane.Memory.Records.remember(attrs :: map()) :: {:ok, Record.t()} | {:error, Ecto.Changeset.t()}` — string-keyed attrs (`"kind"` default `"note"`, `"content"` required, `"title"`, `"subjects"`, `"property"`, `"tags"`, `"writer"` required, `"host_id"`, `"agent_id"`, `"integration"`, `"session_id"`, `"client_id"`, `"source_event_ids"`, `"observed_at"` default now, `"request_key"`).
  - `Records.forget(id :: Ecto.UUID.t(), reason :: String.t()) :: {:ok, Record.t()} | {:error, :not_found}`
  - `Records.get(id) :: {:ok, %{record: Record.t(), history: [Record.t()]}} | {:error, :not_found}` — `history` = records transitively superseded by this one, newest first.
  - `Records.search(query :: String.t(), filters :: map()) :: [Record.t()]` — filters (string keys, all optional): `"host_id"`, `"agent_id"`, `"kind"`, `"subject"` (`"type:key"`), `"since"`, `"until"` (ISO 8601), `"include_inactive"` (default false), `"limit"` (default 10, max 50), `"token_budget"` (default 4000; tokens estimated as `div(String.length(content), 3)`; stop adding results once exceeded, always return at least one).
  - `Records.recent(filters :: map()) :: [Record.t()]` — `kind = worklog`, active, `observed_at desc`; filters `"host_id"`, `"agent_id"`, `"since"`, `"limit"` (default 20, max 100).
  - `Records.normalize_subjects(list) :: {[map()], [String.t()]}` (public for tests).

- [ ] **Step 1: Write failing tests** in `records_test.exs` (`use Backplane.Memory.DataCase`, not async):
  - `remember/1 stores provenance` — insert with all provenance fields; assert they round-trip and `status == "active"`.
  - `remember/1 fact supersedes same subject set and property` — remember fact A `subjects: [%{"type"=>"repo","key"=>"X"},%{"type"=>"host","key"=>"web-01"}], property: "path", content: "/srv/x"`, then fact B with subjects `[%{"type"=>"host","key"=>"WEB-01"},%{"type"=>"repo","key"=>"x"}]`, same property, content `/opt/x`; assert A reloaded has `status == "superseded"`, `superseded_by == B.id`; `get(B.id)` history `== [A]`.
  - `remember/1 does not supersede other properties, kinds or forgotten facts`.
  - `remember/1 is idempotent on request_key` — same `request_key` twice returns same id; `Repo.aggregate(Record, :count) == 1`.
  - `forget/2` — sets `status "forgotten"`, reason, `forgotten_at`; second call with a different reason returns `{:ok, r}` with the first reason; unknown uuid → `{:error, :not_found}`.
  - `search/2 matches content, title and subject keys; excludes inactive by default; include_inactive returns them`.
  - `search/2 tolerates operator characters` — queries `"foo & | ! :* 'x'"` and `"部署 web-01"` do not raise; the Chinese query finds a record whose content contains `部署 web-01`.
  - `search/2 applies host/agent/kind/subject/since filters and token_budget`.
  - `recent/1 returns active worklogs newest first`.

- [ ] **Step 2: Run** `mix test apps/backplane_memory/test/backplane/memory/records_test.exs` — Expected: FAIL (module `Backplane.Memory.Records` undefined).

- [ ] **Step 3: Write the migration and implement `Record`, `Records`, `Records.Search`.**
  - Supersede runs in one `Repo.transaction` with the insert: for `kind == "fact"` and non-nil `property`, update active facts where `subject_keys = ^keys and property = ^property and id != ^new.id`.
  - `request_key` idempotency: on unique violation, return the existing row.
  - Search: build the tsquery with `websearch_to_tsquery('simple', ^q)`; if it yields an empty query (only operators), fall back to `ILIKE '%' || ^escaped || '%'` on content/title. For the `simple` config, CJK text without spaces is a single token, so also OR an `ILIKE` match on each whitespace-separated term of 2+ chars; rank with `ts_rank_cd` then `observed_at desc`.

- [ ] **Step 4: Run** `mix ecto.migrate` (test env via `MIX_ENV=test mix ecto.migrate` from umbrella root) then the test file — Expected: PASS.

- [ ] **Step 5: Checkpoint** — `mix compile --warnings-as-errors`; `mix format --check-formatted`.

---

### Task 2: Five-tool `memory::` service, default enablement, scopes

**Files:**
- Create: `apps/backplane_memory/lib/backplane/memory/tools.ex` (new service; the old `service.ex` is deleted in Task 5)
- Modify: `apps/backplane_memory/lib/backplane/memory/service_registration.ex:10,50-52` (register `Backplane.Memory.Tools`; settings list becomes `~w(services.memory.enabled)`; no prompts)
- Modify: `apps/backplane_memory_contract/lib/backplane/memory_tool_contract.ex` (rewrite to the 5 tools)
- Modify: `apps/backplane_system/lib/backplane/settings.ex:83-98` (add `"services.memory.enabled" => %{value: true, ...}` to the Managed Services block)
- Modify: `apps/backplane_system/lib/backplane/clients/client.ex:13` (`@memory_permissions ~w(memory.read memory.write)`)
- Modify: `apps/backplane_mcp/lib/backplane/transport/mcp_handler.ex:577` (replace `memory.admin` with `admin::*` in `logging_authorized?`)
- Modify: `apps/backplane_admin/lib/backplane/admin/live/managed_live.ex:10-33,104-121` (add Memory toggle for `services.memory.enabled`)
- Create: `apps/backplane_system/priv/repo/migrations/20261109000002_strip_retired_memory_scopes.exs` (remove `memory.coordinate`, `memory.replay`, `memory.admin` from client scope arrays)
- Test: `apps/backplane_memory/test/backplane/memory/tools_test.exs`, update `apps/backplane_system/test/backplane/clients_test.exs`

**Interfaces:**
- Consumes: `Records.*` from Task 1.
- Produces:
  - `Backplane.Memory.Tools.prefix/0 :: "memory"`, `tools/0` (list of `%{name, description, input_schema, handler}` with arity-2 handlers `(args, auth)`), `enabled?/0`.
  - Tool schemas:
    - `memory::search` — `query` (required), `host`, `agent`, `kind` (enum), `subject` (`"type:key"`), `since`, `until`, `include_inactive`, `limit`, `token_budget`.
    - `memory::get` — `id` (required).
    - `memory::recent` — `host`, `agent`, `since`, `limit`.
    - `memory::remember` — `content` (required), `kind` (enum, default `note`), `title`, `subjects` (array of `{type,key}`), `property`, `tags`, `writer` (enum `agent|user`, default `agent`), `session_id`, `host`, `agent`, `integration`, `request_key`.
    - `memory::forget` — `id` (required), `reason` (required).
  - Provenance stamping in `remember`: `client_id` from `auth[:client_id]`; `host_id` = `auth[:principal_metadata]["host_id"]` if present, else arg `host`; `agent_id`/`integration`/`session_id` from args; missing stay nil.
  - Result shape for every record: `%{"id","kind","title","content","subjects","property","tags","status","superseded_by","forgotten_reason","observed_at","provenance" => %{"writer","host","agent","integration","session","client","source_event_ids"}}`; `search`/`recent` return `%{"results" => [...]}`; `get` returns `%{"record" => ..., "history" => [...]}`.
  - `MemoryToolContract.tools/0 :: ["memory::search","memory::get","memory::recent","memory::remember","memory::forget"]`, `permissions/0 :: ["memory.read","memory.write"]`, `permission_for/1` (`search|get|recent → "memory.read"`, `remember|forget → "memory.write"`). Remove `route_class/1` and the other lists.

- [ ] **Step 1: Write failing tests** in `tools_test.exs`:
  - `tools/0 exposes exactly the five names`.
  - `remember stamps client and channel host` — call handler with `auth = %{kind: :client_token, client_id: "c1", principal_metadata: %{"host_id" => "h1"}}` and arg `host: "spoofed"`; assert `provenance.host == "h1"`, `client == "c1"`.
  - `remember without channel host uses arg host`.
  - `forget requires reason` — missing reason → `{:error, _}` with a message mentioning `reason`.
  - `search returns results with provenance`; `get unknown id → {:error, "not_found"}`.
  - `registration: with no settings row, memory tools are registered` — start `ServiceRegistration` with default Settings, assert `ToolRegistry.resolve("memory::search")` is `{:managed, _}`.
  - In `clients_test.exs`: a client with scope `memory.replay` is now invalid; `memory.read` grants `memory::search` and not `memory::remember`.

- [ ] **Step 2: Run** `mix test apps/backplane_memory/test/backplane/memory/tools_test.exs apps/backplane_system/test/backplane/clients_test.exs` — Expected: FAIL.

- [ ] **Step 3: Implement** the files above. Map `{:error, :not_found}` → `{:error, "not_found"}`; changeset errors → `{:error, "invalid: <field> <msg>; ..."}`.

- [ ] **Step 4: Run** the same tests — Expected: PASS.

- [ ] **Step 5: Checkpoint** — compile with warnings as errors.

---

### Task 3: Capture path without partitions

**Files:**
- Create: `apps/backplane_system/priv/repo/migrations/20261109000003_drop_memory_partition_columns.exs` — drop FK + column `memory_space_id` (and ownership `scope`/`namespace` where present) from `bpm_events`, `bpm_streams`, `bpm_projection_states`, `bpm_projection_snapshots`, `bpm_projection_repair_frontiers`, `bpm_projected_sessions`, `bpm_projected_observations`; drop and recreate any unique index that included those columns without them; truncate these tables first (data is disposable). Drop column `skill_hosts.memory_scope`.
- Modify: `apps/backplane_memory/lib/backplane/memory/ingest.ex` (remove `:36-38`, `:42`, `:67-75`, `:98-109`, `:205-213`, `:235-260`, `:298-307`; batch check becomes: token scope `host_agent.capture` and event `host_id == channel host_id`)
- Modify: `apps/backplane_memory/lib/backplane/memory/ingest/upcaster/v1.ex:12-54` (stop reading/deriving partition fields)
- Modify: `apps/backplane_memory/lib/backplane/memory/events/{store,event,stream,preparation,types}.ex` (drop partition fields, `@subject_owner_fields`, `PartitionIdentity.validate`, namespace normalization)
- Modify: `apps/backplane_memory/lib/backplane/memory/projections/{session_projector,observation_projector,state,projected_session,projected_observation,snapshot,rebuild}.ex` (drop partition fields; in `rebuild.ex` remove Activity/Replay `:7-8,13,30-31,167-168,297-298,420-450` and PartitionIdentity `:22,105-120`)
- Modify: `apps/backplane_memory/lib/backplane/memory/workers/projection_repair_worker.ex` (remove summary/window/lesson enqueues `:14,24-25,39,155-170,224-225,265-303,355-391`, partition fields `:241-246,312-317`)
- Modify: `apps/backplane_memory/lib/backplane/memory/workers/fallback_sweep_worker.ex` (remove `SummaryWorker` `:23,205`; partition fields `:137-139,182-188,217-222`)
- Modify: `apps/backplane_memory/lib/backplane/memory/audit.ex:118` (`list/…` no longer takes a partition)
- Modify: `apps/backplane_api/lib/backplane/api/channels/host_agent_channel.ex` — keep `memory_events` (`:435-456`), `validate_memory_events_payload`, `safe_host_event_ingest`, `mcp_tools_list`/`mcp_tool_call`; replace `ingest_bound_memory_events`/`ingest_memory_events` (`:892-991`) with a direct `Ingest` call carrying `host_id`; simplify `safe_memory_event_host` (`:869-885`, no `memory_scope`); delete `:9-11`, `:20-21`, join partition/negotiation (`:27-28,39-40,45-66,79-145`), `:270`, `:282-366`, `:414-433`, `:458-485`, `:500-513`, `:553-640`, `:673-770`, `:786-796`. `host_memory_auth` (`:651-670`) keeps scope mapping and sets `principal_metadata: %{"host_id" => host.id}` only.
- Modify: `apps/backplane_skills/lib/backplane/skills/{hosts,host}.ex` (remove `memory_scope` field, `provision_memory_space`, scope update/revoke `hosts.ex:9,240,326,336,344`)
- Modify: `apps/backplane_mcp/lib/backplane/transport/task_manager.ex:285-298` (drop `memory_partition_id`/`memory_scope` metadata)
- Modify: `apps/backplane_admin/lib/backplane/admin/live/host_agents_live.ex:456,500,914` (remove memory scope input)
- Test: update `apps/backplane_memory/test/backplane/memory/ingest_test.exs`, `events/*`, `projections/*`, `workers/fallback_sweep_worker_test.exs`, `apps/backplane_api/test/backplane/api/channels/host_agent_channel_test.exs`, `apps/backplane_skills/test/backplane/skills/hosts_test.exs`

**Interfaces:**
- Produces: `Backplane.Memory.Ingest.ingest_batch(events :: [map()], ctx :: %{host_id: String.t(), scopes: [String.t()]}) :: {:ok, [result]} | {:error, term()}` (existing name kept if already this; the plan only removes partition params). Channel `memory_call`, `memory_sync`, `memory_next/ack`, `memory_import_batch`, `memory_access_refresh` events no longer exist.

- [ ] **Step 1: Write failing tests:**
  - `host_agent_channel_test`: `"memory_events from a host with no memory_scope are ingested"` — join as a host with `memory_scope: nil`, push a valid `memory_events` batch, assert reply `ok` and one `bpm_events` row with that `host_id`; `"join reply has no memory partition keys"`; `"mcp_tool_call memory::remember stamps channel host"` — push `mcp_tool_call` for `memory::remember`, assert the stored record's `host_id` is the socket host.
  - `ingest_test`: `"event whose host_id differs from channel host is rejected as host_mismatch"`.
  - `projections` tests: a captured session closes on `SessionEnd` and via fallback sweep without enqueueing any summary job (`refute_enqueued` / Styx job table empty for summary workers).

- [ ] **Step 2: Run** `mix test apps/backplane_api/test/backplane/api/channels/host_agent_channel_test.exs apps/backplane_memory/test/backplane/memory/ingest_test.exs` — Expected: FAIL.

- [ ] **Step 3: Implement** the modifications listed above.

- [ ] **Step 4: Run** the updated tests plus `mix test apps/backplane_memory/test/backplane/memory/{events,projections,ingest} apps/backplane_memory/test/backplane/memory/workers/fallback_sweep_worker_test.exs apps/backplane_skills/test/backplane/skills/hosts_test.exs` — Expected: PASS. Old tests that exercise deleted behaviour are removed in Task 5, not fixed here.

- [ ] **Step 5: Checkpoint.**

---

### Task 4: Host agent forwards the five tools online

**Files:**
- Modify: `apps/backplane_host_agent/lib/backplane/host_agent/memory_router.ex` — `/memory/:agent_id/mcp` `tools/list` returns the five tools (schemas from the hub's `mcp_tools_list` filtered to `memory::*`; if the channel is down, return the five names from `MemoryToolContract.tools/0` with the static schemas exported by `Backplane.MemoryToolContract.schemas/0`); `tools/call` for any `memory::*` goes through the `route_remote_memory_tool` path (`:651-663`) via `HubProxy.call_tool`, injecting `"agent" => agent_id` when absent; `/memory/:agent_id/call/:method` (`:502-546`) maps `method` → `memory::<method>` the same way. Remove `memory_access_id` guard `:231`, OpenClaw binding `:235-246`, access errors `:139-149`, `forbidden_authority?` `:608,665-680`, route_class uses `:612-622,686-701,705,808`. Remove lifecycle-context injection `:275-500` (spec: no automatic injection) — capture responses become plain `202`.
- Modify: `apps/backplane_memory_contract/lib/backplane/memory_tool_contract.ex` — add `schemas/0 :: %{String.t() => map()}` (same input schemas as Task 2; `Backplane.Memory.Tools` must use these to avoid drift).
- Modify: `apps/backplane_host_agent/lib/backplane/host_agent/memory/capture_uploader.ex` (`:8,28,52,491` drop `Access`; `:136-170` drop `bind_events`)
- Modify: `apps/backplane_host_agent/lib/backplane/host_agent/memory_proxy.ex` (keep only channel tracking: `set_channel/1`, `channel/0`, `set_connection/1`, `set_connection_owner/1`; delete the rest)
- Modify: `apps/backplane_host_agent/lib/backplane/host_agent/channel.ex:82-127` (join payload without `memory_v2` access/edge extensions; keep `hermes_capture.v1`/`openclaw_capture.v1`)
- Modify: `apps/backplane_host_agent/lib/backplane/host_agent/worker.ex` (remove `EdgeSyncer` `:24,218,591-645`, `worker_negotiation` `:390-404`, `memory_host_sync` `:738-747`)
- Modify: `apps/backplane_host_agent/lib/backplane/host_agent/{agent_channel,telemetry,reporter}.ex` (remove edge/diagnostics refs)
- Modify: `apps/backplane_host_agent/lib/backplane/host_agent/memory/supervisor.ex:26-55` (start only `Store` and `Migrator`; the local store is used by Plan 2)
- Modify: `apps/backplane_host_agent/lib/backplane/host_agent/application.ex:17` (remove `ImportSupervisor`)
- Modify: `apps/backplane_host_agent/lib/backplane/host_agent/memory_router.ex:177`, `memory/hooks/hermes.ex:81` (inline `uuid?/1`)
- Test: update `apps/backplane_host_agent/test/backplane/host_agent/{memory_router_test,memory_proxy_test,channel_test,worker_test,agent_channel_test}.exs`

**Interfaces:**
- Consumes: `MemoryToolContract.tools/0`, `schemas/0`; `HubProxy.call_tool(name, args)` (existing).
- Produces: host HTTP contract — `POST /memory/:agent_id/mcp` (`tools/list`, `tools/call`), `POST /memory/:agent_id/call/{search|get|recent|remember|forget}`; offline calls return error `"gateway_unavailable"` (Plan 2 replaces this).

- [ ] **Step 1: Write failing tests** in `memory_router_test.exs`:
  - `"tools/list returns exactly the five memory tools"`.
  - `"tools/call memory::remember forwards to hub with agent injected"` — stub `HubProxy` (existing test seam) and assert it received `"memory::remember"` with `"agent" => "a1"` for path `/memory/a1/mcp`.
  - `"call/search maps to memory::search"`.
  - `"when channel is down, tools/call returns gateway_unavailable"`.
  - `"capture hook returns 202 without context injection"`.

- [ ] **Step 2: Run** `mix test apps/backplane_host_agent/test/backplane/host_agent/memory_router_test.exs` — Expected: FAIL.

- [ ] **Step 3: Implement** the modifications.

- [ ] **Step 4: Run** `mix test apps/backplane_host_agent/test/backplane/host_agent/{memory_router_test,memory_proxy_test,channel_test,worker_test,agent_channel_test}.exs apps/backplane_host_agent/test/backplane/host_agent/memory/{capture,hooks,event_envelope,spool}*` — Expected: PASS (deleted-feature tests are removed in Task 6).

- [ ] **Step 5: Checkpoint.**

---

### Task 5: Delete old gateway memory code and tables

**Files:**
- Delete (lib, `apps/backplane_memory/lib/backplane/memory/`): `service.ex`, `router.ex`, `recall/`, `memories.ex`, `memories/`, `observations.ex`, `provenance.ex`, `partition.ex`, `partition_identity.ex`, `authorization.ex`, `current_context.ex`, `edge_sync.ex`, `edge_sync/`, `readiness.ex`, `lessons.ex`, `lessons/`, `crystals.ex`, `crystals/`, `crystal_sources.ex`, `graph.ex`, `graph/`, `slots.ex`, `slots/`, `coordination/`, `shared_commands.ex`, `shared_commands/`, `replay.ex`, `replay/`, `replay_notifier.ex`, `imports.ex`, `imports/`, `generated_skills.ex`, `facets.ex`, `facets/`, `profiles.ex`, `profiles/`, `activity.ex`, `activity_notifier.ex`, `eval.ex`, `eval/`, `qualification.ex`, `qualification/`, `sources.ex`, `sources/`, `source_support.ex`, `context.ex`, `operations.ex`, `operations/`, `fact_extraction.ex`, `prompts.ex`, `summaries/`, `llm.ex`, `projections/{activity_contribution,activity_daily,activity_projector,activity_store,activity_verifier,replay_projector,read_models,session_detail}.ex`; workers `summary, window_summary, episodic, procedural, relation_classifier, lesson_candidate, lesson_decay, lesson_decay_sweep, crystal, graph_extract, lease_cleanup, activity_retention, recall_trace_purge, access_writeback, eviction, stage_resume, embed, edge_sync_retention`; `numeric.ex` if unreferenced after deletion.
- Keep: `embedding/` (Plan 3), `proxy_auth.ex`, `privacy/`, `events/`, `ingest*`, `projections/` (remaining), `audit.ex`, `config.ex`, `canonical_json.ex`, `event_notifier.ex`, `pipeline_telemetry.ex`, `query_log_filter.ex`, `application.ex`, `service_registration.ex`, `record.ex`, `records*`, `tools.ex`.
- Delete mix tasks: `apps/backplane_memory/lib/mix/tasks/memory.{eval,qualify,seed_bench,activity.verify,replay.browser_qualify}.ex`, `backplane.memory.edge_cutover_check.ex`. Keep `memory.connect.ex` and `priv/hooks/` until Plan 5; keep `memory.projections.rebuild.ex` if it compiles against the kept projections, otherwise delete.
- Delete priv: `priv/browser/replay_qualification.mjs`, `priv/memory_fixtures/`, `priv/skills/*.json`.
- Delete: `apps/backplane_system/lib/backplane/memory_spaces.ex`, `memory_spaces/`; `apps/backplane_memory_contract/lib/backplane/{memory_read_request,memory_source_contract}.ex`; `apps/backplane_api/lib/backplane/api/host_agent_memory_sync.ex`; REST forward to `Backplane.Memory.Router` in `apps/backplane_api/lib/backplane/api/router.ex:65,123-124`.
- Modify: `apps/backplane_memory/lib/backplane/memory/application.ex:25-35` (remove Recall/Crystal TaskSupervisors, `EdgeSync.Notifier`, `ActivityNotifier`, `ReplayNotifier`, `GeneratedSkills`, `reconcile_generated_skills`).
- Modify: `apps/backplane_memory/lib/backplane/memory/config.ex` (only kept keys: `services.memory.enabled`, `memory.llm_model`, `memory.embed_model`, `memory.proxy_credential`, `memory.event_gap_grace_seconds`, `memory.session_stale_after_seconds`, `memory.fallback_sweep_batch_size`, host batch/spool keys still read by code).
- Modify: `apps/backplane_system/lib/backplane/settings.ex` (delete dead `memory.*` defaults listed in the spec inventory: `host_sync.*`, `pipeline/window_summaries/session_summary/fact_extraction/procedure_extraction/relation_classifier/recall.*` flags, all `recall_*`, `activity_retention_days`, `replay_*`, `lesson_*`, `crystal*`; `:527-537` stop writing `recall_relevance_vector_min`).
- Modify: `config/config.exs:33-37,42-56` (drop queues `memory_relation_classifier`, `memory_lessons`, `memory_crystals` and all memory crons except FallbackSweep); `config/test.exs:29` if it references removed config.
- Create: `apps/backplane_system/priv/repo/migrations/20261109000004_drop_retired_memory_tables.exs` — `DROP TRIGGER IF EXISTS bpm_memory_edge_change_capture ON bpm_memories`; drop functions `bpm_capture_memory_edge_change, bpm_memory_edge_payload, bpm_memory_edge_max_item_bytes, bpm_memory_edge_eligible, bpm_reject_memory_change_update, memory_access_sorted_capabilities, memory_access_audit_immutable, bpm_reject_memory_provenance_mutation, bpm_memory_mutation_evidence_partition, bpm_memory_backfill_source_id` (`CASCADE`); drop tables (`CASCADE`): every table in the spec inventory "Drop" list (`bpm_memories`, evidence/relations/requests, sources, spaces/entitlements/aliases/backfill/access audits+commands/revocations, partition revisions/changes/snapshots/chunks, host cursors/deliveries/receipts, `bpm_observations`, `memory_sessions`, summaries, graph, profiles, facets, leases, signals, actions, slots, activity, recall runs/candidates, lessons, crystals, replay, import batches); delete `system_settings` rows whose keys were removed from defaults. `down` raises `Ecto.MigrationError` (irreversible).
- Delete tests: everything under `apps/backplane_memory/test/**` except `records_test`, `tools_test`, `events/*`, `ingest_test`, `ingest/*`, `projections/{projectors,source,state,revision,rebuild,projection_repair_worker,source_lock_concurrency}_test`, `workers/fallback_sweep_worker_test`, `privacy/filter_test`, `embedding/*`, `proxy_auth_test`, `config_test`, `support/{data_case,ingest_fixtures}.ex`; `apps/backplane_system/test/backplane/{memory_spaces,memory_host_access,memory_permissions}_test.exs`, `.../repo/migrations/create_memory_spaces_test.exs` and partition migration tests (`memory_space_identity_migration_test`, `security_partition_migrations_test`, `complete_partition_migration_test`, `partition_identity_migration_test`, `m18_migration_*`, `memory_v2_upgrade_test`); `apps/backplane_api/test/backplane/api/{memory_crystals_router,memory_lessons_router,memory_router,memory_get_router,memory_m18_outage_qualification,memory_v2_edge_qualification,memory_tool_schema_parity,host_agent_memory_sync,host_agent_sync_e2e}_test.exs`; `apps/backplane/test/integration/memory_mcp_contract_test.exs` (replace with a 5-tool contract test in Step 1).
- Modify: `apps/backplane_system/lib/backplane/memory_permissions.ex` to delegate to the new contract (or delete if `clients.ex:88-93` can call the contract directly).

- [ ] **Step 1: Write the replacement contract test** `apps/backplane/test/integration/memory_mcp_contract_test.exs`: over `POST /mcp` with a `bp2_` client holding `memory.read memory.write`, `tools/list` contains exactly the five `memory::` tools; `remember` then `search` round-trips; a `memory.read`-only client gets a scope error on `remember`.
- [ ] **Step 2: Delete files and apply edits; run** `MIX_ENV=test mix ecto.reset` — Expected: migrations succeed.
- [ ] **Step 3: Run** `mix compile --warnings-as-errors` — Expected: no warnings, no undefined modules. Fix every remaining reference (grep `MemorySpaces|PartitionIdentity|EdgeSync|Lessons|Crystals|Recall\.|Service\.call|memory_partition_id|memory_scope` across `apps/` must return nothing outside deleted files).
- [ ] **Step 4: Run** `mix do --app backplane_memory cmd mix test`, `mix test apps/backplane/test/integration/memory_mcp_contract_test.exs`, `mix test apps/backplane_system/test apps/backplane_api/test apps/backplane_mcp/test` — Expected: PASS.
- [ ] **Step 5: Checkpoint.**

---

### Task 6: Delete old host-agent memory code

**Files:**
- Delete (`apps/backplane_host_agent/lib/backplane/host_agent/`): `memory/access.ex`, `memory/openclaw_binding.ex`, `memory/syncer.ex`, `memory/source_commands.ex`, `memory_source_facade.ex`, `memory_record_read.ex`, `memory_facade.ex`, `memory/{import,import_runner,import_supervisor}.ex`, `memory/import/`, `memory/{context_packer,reducer,pruner,diagnostics}.ex`, `memory/edge/`, `memory/mirror.ex`, `memory/mirror/`, `memory.ex`, `services/memory.ex`, capture `RecallCache` (child at `memory/capture_supervisor.ex:58`) ; mix tasks `apps/backplane_host_agent/lib/mix/tasks/agent.memory.{import,resync,tombstones}.ex`.
- Keep: `memory/{store,migrator,supervisor}.ex`, `memory/migrations/` (Plan 2 reworks), capture, hooks, spool, envelope, git_context, privacy_filter, uuid7.
- Delete tests: `apps/backplane_host_agent/test/backplane/host_agent/memory/{access,mirror,import,replay_import_service,syncer,pruner,reducer,read_filters,context_packer,diagnostics,v1_to_v2_upgrade,host_server_contract}_test.exs`, `memory/edge/`, `memory_{facade,record_read,get_router,routing_consistency,diagnostics_endpoint}_test.exs`, `memory_test.exs`.
- Modify: `apps/backplane_host_agent/lib/backplane/host_agent/services.ex` (unregister the local memory service; host MCP memory goes only through `memory_router`).

- [ ] **Step 1: Delete and edit; run** `mix compile --warnings-as-errors` — Expected: clean; grep `Memory.Access|MemoryFacade|Mirror|Edge\.|ImportRunner|memory_access_id` in `apps/backplane_host_agent/lib` returns nothing.
- [ ] **Step 2: Run** `mix do --app backplane_host_agent cmd mix test` — Expected: PASS.
- [ ] **Step 3: Checkpoint.**

---

### Task 7: Admin Memory pages reduced to records, events/sessions, config

**Files:**
- Delete: `apps/backplane_admin/lib/backplane/admin/live/memory_{memories,lessons,crystals,graph,profile,actions,replay,activity,recall_inspector,timeline,pipeline,audit,search}_live.ex`, `plugs/memory_detail_plug.ex`, and their tests in `apps/backplane_admin/test/backplane/admin/live/`.
- Create: `apps/backplane_admin/lib/backplane/admin/live/memory_records_live.ex` — `/memory/records`: search box (calls `Records.search/2` with `include_inactive` toggle and host/agent/kind filters), table with kind, title/content excerpt, subjects, status, writer, host, agent, observed_at; row detail shows provenance, history (`Records.get/1`), and a "Forget" action requiring a reason (`Records.forget/2`).
- Modify: `memory_{overview,events,streams,sessions,config}_live.ex`, `memory_operator_components.ex`, `components/memory_components.ex`, `memory_operator_hook.ex` — remove references to deleted modules; overview shows counts of records by kind/status, captured events (24h), open sessions, and a warning banner when `memory.llm_model` is unset ("提炼未启用：未配置 memory.llm_model").
- Modify: `apps/backplane_admin/lib/backplane/admin/router.ex:14-16,106-164`, `components/layouts.ex:63-106` (nav: Overview, Records, Events, Sessions, Config).
- Modify tests: `apps/backplane_admin/test/support/memory_fixtures.ex`, `route_boundary_test.exs`, `logs_live_test.exs`.
- Test: `apps/backplane_admin/test/backplane/admin/live/memory_records_live_test.exs`

- [ ] **Step 1: Write failing tests:** records page lists a remembered record with its host; search filters; forget with reason moves it out of default list; overview shows the llm_model warning when unset and hides it when set.
- [ ] **Step 2: Run** `mix test apps/backplane_admin/test/backplane/admin/live/memory_records_live_test.exs` — Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `mix do --app backplane_admin cmd mix test` — Expected: PASS.
- [ ] **Step 5: Checkpoint** — screenshot `/memory/records` and `/memory/overview` for the PR (AGENTS.md).

---

### Task 8: CI, docs and final verification

**Files:**
- Modify: `.github/workflows/memory-test.yml` — delete steps at `:130-182` (slot/backfill SQL), `:184-185` (edge cutover), `:187-238` (m18/qualification/readiness/v2-upgrade/outage/edge/source/evidence/recall/replay/seed_bench/eval/qualify) and the qualification artifact upload; keep a single step running `mix do --app backplane_memory cmd mix test`.
- Modify: `.github/workflows/memory-plugins.yml` — delete slot SQL `:155-205`, edge check `:210`, `v1_to_v2_upgrade_test` and the "Verify memory plugin source lifecycle" step `:222-233`; keep capture/envelope/hook tests; mark OpenClaw live acceptance `:248` as removed until Plan 5.
- Modify: `.github/workflows/test.yml:42-43,153-154` (drop `--exclude memory_qualification_runtime`).
- Modify: `.github/workflows/release.yml:447-450` (stop copying `docs/qualification/memory.md`; keep `docs/memory/host-memory-protocol.md` only if updated in this task).
- Modify: `test/ci_workflow_test.exs:147-148,675`, `test/release_config_test.exs:1062-1290` to match.
- Delete: `test/hermes_memory_live_{oracle_test,acceptance}.exs`, `test/openclaw_memory_live_acceptance.exs` (Plan 5 adds new live tests).
- Modify: `docs/architecture/memory.md` — replace with a short current-state description pointing to the spec; mark `docs/memory/adr-memory-space-partition.md` as superseded (one-line header).
- Modify: `AGENTS.md` Data Storage bullet for memory tables (`memory_records` instead of `bpm_memory_spaces`, `bpm_observations`, `bpm_memories`).

- [ ] **Step 1: Run** `mix run --no-start test/ci_workflow_test.exs` and `mix test test/release_config_test.exs` — Expected: FAIL before edits.
- [ ] **Step 2: Apply edits.**
- [ ] **Step 3: Run the full gate:** `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix credo --strict`, `mix dialyzer`, `mix test`, `mix run --no-start test/ci_workflow_test.exs` — Expected: all pass. Report any failure outside the touched scope and stop.
- [ ] **Step 4: Manual end-to-end in dev:** restart `devenv up`; `curl` capture hook `POST localhost:4222/capture/v1/hooks/claude_code/SessionStart` with a test session → row in `bpm_events`; `POST localhost:4222/memory/test/call/remember` `{"content":"repo X is at /srv/x on web-01","kind":"fact","subjects":[{"type":"repo","key":"X"},{"type":"host","key":"web-01"}],"property":"path"}` then `call/search {"query":"repo X"}` returns it with `provenance.host` = the devenv host id; same via gateway `POST localhost:4220/mcp`.
- [ ] **Step 5: Checkpoint** — summarize diff stats and verification output for the user.
