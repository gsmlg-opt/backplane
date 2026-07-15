# Backplane Memory V2 Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Establish `Backplane.Memory.*`, freeze the existing Memory MCP contract, add disabled rollout controls, and introduce an ordered, idempotent event stream that atomically dual-writes existing observations without changing their successful return shape.

**Architecture:** Deliver three stacked PRs into `feat/memory-v2-foundation`: PR 0A is namespace-only with old-module compatibility; PR 0B freezes the current 31-core/40-full tool surface, adds a master-gated flag facade, and locks in the existing generated-column FTS path; PR 1 adds plain Ecto event modules, row-locked sequence allocation, recursive privacy filtering, atomic observation/event composition, internal timeline queries, telemetry, and the HTTP/hook ingress required to exercise the milestone. No GenServer, LLM, embedding call, or Oban job belongs in event ingestion.

**Tech Stack:** Elixir 1.18 / OTP 28, Ecto 3.14, PostgreSQL, Oban 2.23, Plug/Phoenix, ExUnit SQL Sandbox, `:telemetry`

---

## Scope and approval boundary

This plan implements only the foundation described in the attached “Backplane Memory V2 — Start Plan” objective:

1. PR 0A — Namespace migration.
2. PR 0B — MCP contracts, feature flags, and FTS verification.
3. PR 1 — Event stream and observation dual-write.

Window summaries, Session Summary V2, fact/procedure extraction, Recall V2, payload object storage, and a public event-timeline MCP tool remain out of scope. Do not modify implementation code until this plan is approved.

## Delivery and branch model

The current root worktree is dirty with unrelated endpoint/reloader and `math_ex` changes. Preserve it. Create clean worktrees under the repository’s `.trees` directory:

```text
.trees/memory-v2-foundation  -> feat/memory-v2-foundation, from origin/main
.trees/memory-namespace      -> feat/memory-namespace, from feat/memory-v2-foundation
.trees/memory-v2-contracts   -> feat/memory-v2-contracts, from updated feat/memory-v2-foundation
.trees/memory-event-stream   -> feat/memory-event-stream, from updated feat/memory-v2-foundation
```

Each PR targets `feat/memory-v2-foundation`. Merge each PR into that branch before branching the next. When all three are accepted, the integration branch is the reviewable milestone proposed for `main`.

## Recorded baseline (2026-07-13)

| Check | Result |
|---|---|
| Worktree | `main` at `0e610018`, with unrelated user changes; no Memory source dirty |
| Dependencies | `devenv shell -- mix deps.get` succeeded; lock unchanged |
| Compile | Shared `_build/dev` failed on module-redefinition warnings while the `backplane` dev process was active; isolated `MIX_BUILD_PATH=/tmp/backplane-memory-v2-baseline-build` compile passed |
| Memory tests | `MIX_ENV=test devenv shell -- mix do --app backplane_memory test`: 196 tests, 0 failures; one pre-existing unused-default warning |
| Umbrella tests | Two pre-existing failures: `Backplane.Api.HostAgentChannelTest` missing a reconcile log line, and `Backplane.Admin.McpInspectorLiveTest` missing the stdio timeout message |
| Migrations | All up through `20260706000001_create_agent_trace_events` |
| Memory tools | 31 core; 40 when `memory.tools == "all"` |
| Legacy Oban rows | 224 old-name rows, none active: AccessWriteback 2 completed, Embed 2 discarded, FallbackSweep 188 completed, Procedural 32 completed |
| Release | `MIX_ENV=prod devenv shell -- mix release backplane --overwrite` succeeded |
| FTS | `bpm_memories.search_tsv` is generated/stored and GIN-indexed; embedding-error fallback test passes |

Use the isolated build-path compile in PR acceptance checks while the local dev process shares `_build/dev`:

```bash
MIX_BUILD_PATH=/tmp/backplane-memory-v2-build devenv shell -- mix compile --warnings-as-errors
```

Do not treat the two umbrella failures as Memory regressions. Re-run their exact files after each PR to detect drift, but do not fix them in this milestone unless they become causally related.

## Repository-grounded decisions

### Stable contracts

Keep all of these unchanged through PR 1:

- OTP app and release entry: `:backplane_memory`, permanent in the `backplane` release.
- MCP prefix and names: `memory::*`.
- Existing setting keys: `services.memory.enabled`, `memory.tools`, `memory.embed_model`, `memory.graph_min_observations`, `memory.hard_delete_enabled`, `memory.inject_context`, `memory.llm_model`, `memory.query_expansion_enabled`, `memory.reflect_enabled`, and `memory.reranker_enabled`.
- Existing tables: `bpm_memories`, `bpm_observations`, `memory_sessions`, `memory_summaries`, `memory_profiles`, `memory_slots`, `memory_graph_nodes`, `memory_graph_edges`, `memory_actions`, `memory_action_edges`, `memory_leases`, `memory_signals`, `memory_audit_log`, `memory_facets`, and `memory_facet_dimensions`.
- Successful `Observations.record/3`: `{:ok, %Observation{}}`.
- `register_session/2`: insert-only/idempotent; do not overwrite an existing project.
- `end_session/1`: raw `{count, rows}` result and exactly one legacy summary enqueue on the first transition.

### Namespace compatibility

Move internal code and tests fully to `Backplane.Memory.*`. Keep compatibility modules only under explicit `backplane_memory_compat*` files. Preserve the complete public surfaces of:

- `BackplaneMemory` (`version/0`).
- `BackplaneMemory.Memory` (all 10 public functions and default arities).
- `BackplaneMemory.Observations` (all four public functions).
- `BackplaneMemory.Service` (managed-service callbacks, resources/prompts, and every public handler).
- All 10 old Oban worker names, not only the seven currently scheduled, because old persisted or externally enqueued jobs may reference any worker.

### Feature-flag hierarchy

`memory.pipeline.enabled` is the master kill switch. Every V2 accessor returns true only when the master and its own flag are true. `dual_write?/0` additionally requires events to be enabled.

```elixir
def events_enabled? do
  pipeline_enabled?() and enabled?("memory.events.enabled")
end

def dual_write? do
  events_enabled?() and enabled?("memory.events.dual_write")
end
```

All eight settings are real boolean defaults in `Backplane.Settings`; the facade exposes all eight accessors. PR 0B freezes current boot-only Memory service registration. It does not add dynamic registration or handler guards.

The first dual-write rollout therefore enables three flags, not two:

```text
memory.pipeline.enabled = true
memory.events.enabled = true
memory.events.dual_write = true
```

### FTS decision

Use the existing Option A. `search_tsv` already exists as a generated stored column with `bpm_memories_search_tsv_gin_idx`, and current alias-aware fragments successfully query it. Add regression coverage; do not add a migration or replace it with `to_tsvector(content)`, which would bypass the existing index.

### Dual-write failure policy

Three approaches were considered:

| Approach | Compatibility | Authority | Decision |
|---|---|---|---|
| Best-effort event after observation | Strong legacy availability | Can permanently miss events | Reject |
| Observation plus event in one DB transaction | Successful return unchanged; failures remain `{:error, reason}` | Event and observation cannot diverge | **Use** |
| Observation plus outbox/reconciler | Strong eventual delivery | Adds another table/worker and wider milestone | Defer |

`Events.Store.append_multi/3` is an internal composition seam used by both `append/1` and `Observations`. It allocates/inserts the event in the caller’s `Ecto.Multi`. The legacy observation insert is in the same transaction and remains the value returned on success. Summary enqueue remains after commit and outside event storage.

### Event identity and lifecycle

- An explicit `stream_id` wins. Otherwise require `session_id` and derive `"session:" <> session_id`.
- Project is metadata, never identity.
- `session.started:<session_id>` and `session.ended:<session_id>` are deterministic idempotency keys.
- A repeated key returns the existing event only when stream, type, and sanitized content/payload digest agree; otherwise return `{:error, :idempotency_conflict}`.
- When an idempotency key is present, store a canonical sanitized event fingerprint under `payload["_backplane"]["event_fingerprint"]`; compute it before truncation and exclude `_backplane` linkage/limit metadata so a retried observation can match the original event. This avoids a new database column and makes conflict checks deterministic even after truncation.
- A closed stream permits an idempotent replay of an existing event but rejects a new append with `{:error, :stream_closed}`.
- Stream metadata is write-once-per-field: later events may fill null fields but do not overwrite non-null identity metadata.
- `last_event_at` is the greatest observed `occurred_at`; sequence remains append order.
- `append_batch/1` is all-or-nothing. Normalize first, lock stream rows in lexical `stream_id` order to avoid deadlocks, allocate sequences in each stream’s input order, and return events in original input order.
- `range/2` is stream-local and sequence-ascending.
- `timeline/1` is cross-stream and ordered by `occurred_at DESC, id DESC`, with an opaque URL-safe Base64 JSON cursor containing those two values.
- `close_stream/1` is idempotent for an existing stream and returns `{:error, :not_found}` for an unknown stream.

Public result shapes are fixed as:

```elixir
append(attrs)              :: {:ok, Event.t()} | {:error, term()}
append_batch(events)       :: {:ok, [Event.t()]} | {:error, term()}
range(stream_id, range)    :: {:ok, [Event.t()]} | {:error, term()}
timeline(filters)          :: {:ok, %{events: [Event.t()], next_cursor: String.t() | nil}} | {:error, term()}
close_stream(stream_id)    :: {:ok, Stream.t()} | {:error, :not_found}
```

Include transitional `legacy.observation` in the initial taxonomy because the objective’s mapping requires it. It is the only addition to the listed taxonomy.

### Privacy and payload limits

Apply current string redaction recursively to maps and lists. Redact values under case-insensitive sensitive keys (`authorization`, `cookie`, `set-cookie`, `password`, `secret`, `token`, `api_key`, `access_key`, and environment variants), strip PostgreSQL-invalid null bytes, then enforce:

```text
content: 64 KiB encoded UTF-8
payload JSON: 256 KiB
preview: 512 Unicode graphemes
digest: lowercase SHA-256 hex over the sanitized full value before truncation
```

Keep content truncation metadata under `payload["_backplane"]["content"]`. When the payload itself is oversized, replace it with:

```json
{
  "_backplane": {
    "payload": {
      "truncated": true,
      "original_bytes": 123456,
      "sha256": "...",
      "preview": "..."
    }
  }
}
```

Never hash raw secret-bearing input into persisted metadata; digest only the sanitized full value.

### Hook ingress is part of PR 1

The usable milestone cannot work on current `main`: `BackplaneMemory.Router` is not mounted, and `memory.connect` writes an outdated hook shape that maps session start/end to per-tool events. PR 1 includes the ingress repair required by its acceptance flow. Mounting the existing router activates all of its currently defined REST endpoints, including diagnose/heal, rather than only the three write endpoints; approval of this plan explicitly approves that public-surface activation.

- Mount the Memory router at `/api/memory` and make its internal routes prefix-relative.
- Preserve existing HTTP response bodies/statuses.
- Write the current Claude Code hook map keyed by event name.
- Use actual `SessionStart`, `SessionEnd`, and `PostToolUseFailure` events.
- Make hooks send explicit event types; use `tool_use_id` as the idempotency-key component where available.
- Keep shell-hook failures non-blocking.

Reference: [Claude Code Hooks Reference](https://code.claude.com/docs/en/hooks).

---

## PR 0A — `feat/memory-namespace`

### File structure

**Move the source tree:**

```text
apps/backplane_memory/lib/backplane_memory.ex
  -> apps/backplane_memory/lib/backplane/memory.ex
apps/backplane_memory/lib/backplane_memory/
  -> apps/backplane_memory/lib/backplane/memory/
apps/backplane_memory/test/backplane_memory/
  -> apps/backplane_memory/test/backplane/memory/
```

**Non-mechanical moves:**

```text
lib/backplane/memory/memory.ex
  -> lib/backplane/memory/memories.ex
lib/backplane/memory/memories/profiles.ex
  -> lib/backplane/memory/profiles.ex
lib/backplane/memory/memories/profile.ex
  -> lib/backplane/memory/profiles/profile.ex
lib/backplane/memory/consolidation/summary.ex
  -> lib/backplane/memory/summaries/summary.ex
```

**Create compatibility files:**

```text
apps/backplane_memory/lib/backplane_memory_compat.ex
apps/backplane_memory/lib/backplane_memory_compat/workers.ex
apps/backplane_memory/test/backplane/memory/compatibility_test.exs
```

### Task 0A.1: Freeze namespace-sensitive behavior first

**Files:**

- Create: `apps/backplane_memory/test/backplane_memory/namespace_contract_test.exs` before the move; move it with the test tree in Task 0A.2.
- Modify: `apps/backplane_memory/test/backplane_memory/service_test.exs`.
- Modify: `apps/backplane_memory/test/backplane_memory/observations_test.exs`.

- [ ] Add a test that records the exact 10-function `Memories` public API, four-function Observations API, `version/0`, 31/40 tool counts, prefix, and `enabled?/0` behavior.
- [ ] Add an application-start regression that inserts `services.memory.enabled=true` into the settings ETS before restarting `:backplane_memory`, then asserts all expected `memory::*` tools are registered.
- [ ] Record each worker’s current queue/max-attempt options so compatibility definitions can preserve them exactly.
- [ ] Run the namespace contract before the move and save the green result; the same moved test must stay green after internal renaming.

Expected public context list:

```elixir
[
  count: 0,
  count: 1,
  forget: 1,
  get: 1,
  list: 0,
  list: 1,
  maybe_detect_contradiction: 2,
  remember: 1,
  remember: 2,
  scope_stats: 0,
  stats: 0,
  team_feed: 1,
  team_feed: 2,
  team_share: 2
]
```

Run:

```bash
MIX_ENV=test devenv shell -- mix test apps/backplane_memory/test/backplane_memory/service_test.exs apps/backplane_memory/test/backplane_memory/observations_test.exs
```

### Task 0A.2: Move the namespace mechanically

**Files:** all production/test files under `apps/backplane_memory`, plus `apps/backplane_memory/mix.exs`.

- [ ] Use `git mv` for the source and test roots listed above.
- [ ] Rename `BackplaneMemory.MixProject` to `Backplane.Memory.MixProject` while retaining `app: :backplane_memory` and every current dependency.
- [ ] Change the application callback to `{Backplane.Memory.Application, []}` and supervisor name to `Backplane.Memory.Supervisor`.
- [ ] Replace internal `BackplaneMemory.*` modules with `Backplane.Memory.*` and move test modules to `Backplane.Memory.*`.
- [ ] Rename `BackplaneMemory.DataCase` to `Backplane.Memory.DataCase` and update its imports.
- [ ] Apply the non-mechanical context/schema mappings from the objective, including `Memories`, `Profiles`, and `Summaries.Summary`.
- [ ] Keep the root entry module as `Backplane.Memory` with unchanged `version/0` behavior.
- [ ] Run formatting only on moved/modified Elixir files.

Representative callback after the move:

```elixir
def application do
  [
    extra_applications: [:logger, :crypto, :tzdata],
    mod: {Backplane.Memory.Application, []}
  ]
end
```

### Task 0A.3: Update all in-repo callers and configuration

**Files:**

- Modify: `config/config.exs`.
- Modify: eight Memory LiveViews under `apps/backplane_admin/lib/backplane/admin/live/`.
- Modify: `apps/backplane_api/lib/backplane/api/channels/host_agent_channel.ex`.
- Modify: `apps/backplane_api/lib/backplane/api/host_agent_memory_sync.ex`.
- Modify: their tests.
- Modify: Memory docs and Mix tasks that contain Elixir module names.

- [ ] Update Oban cron worker modules and all seven `:llm_module` defaults.
- [ ] Update admin/API aliases and direct handler/schema calls.
- [ ] Update all three `Mix.Tasks.Memory.*` references.
- [ ] Update documentation examples that mean the Elixir namespace.
- [ ] Do not replace `BackplaneMemoryProvider` in the Hermes Python integration; it is a Python class name.
- [ ] Assert the stable app atom, prefix, setting keys, and existing table names are byte-for-byte unchanged.

Audit command:

```bash
rg -n 'BackplaneMemory\.' apps config integrations docs CLAUDE.md
```

At this stage, matches must be restricted to the two compatibility source files, compatibility tests, and historical documentation explicitly marked as legacy.

### Task 0A.4: Add complete compatibility modules

**Files:**

- Create: `apps/backplane_memory/lib/backplane_memory_compat.ex`.
- Create: `apps/backplane_memory/lib/backplane_memory_compat/workers.ex`.
- Test: `apps/backplane_memory/test/backplane/memory/compatibility_test.exs`.

- [ ] Define `BackplaneMemory`, `BackplaneMemory.Memory`, `BackplaneMemory.Observations`, and `BackplaneMemory.Service` as logic-free delegates.
- [ ] Write `compatibility_test.exs` after the namespace move and run it before adding wrappers; verify it fails because the old modules are absent.
- [ ] Explicitly delegate every public function/arity captured by the compatibility test; do not use runtime reflection or dynamic dispatch.
- [ ] Define old-name workers for AccessWriteback, Embed, Episodic, Eviction, FallbackSweep, GraphExtract, LeaseCleanup, Procedural, ProfileBuild, and Summary.
- [ ] Give each old worker the same `use Oban.Worker` queue/max-attempt options as before, delegate `perform/1` for persisted jobs, and also delegate existing public helpers such as `enqueue/*` and `perform_with_client/2` for external compatibility.
- [ ] Ensure new code/config never references a compatibility module.

Worker pattern:

```elixir
defmodule BackplaneMemory.Workers.SummaryWorker do
  @moduledoc false
  use Oban.Worker, queue: :memory, max_attempts: 3

  @impl Oban.Worker
  def perform(job), do: Backplane.Memory.Workers.SummaryWorker.perform(job)
end
```

### Task 0A.5: Verify and commit PR 0A

- [ ] Run Memory tests:

```bash
MIX_ENV=test devenv shell -- mix do --app backplane_memory test
```

- [ ] Run caller-focused tests:

```bash
MIX_ENV=test devenv shell -- mix test apps/backplane_api/test/backplane/api/host_agent_memory_sync_test.exs apps/backplane_admin/test/backplane/admin/live/memory_live_test.exs
```

- [ ] Compile on an isolated build path:

```bash
MIX_BUILD_PATH=/tmp/backplane-memory-v2-pr0a devenv shell -- mix compile --warnings-as-errors
```

- [ ] Run the umbrella suite and record only the two known baseline failures or any new regression.
- [ ] Build the production release:

```bash
MIX_ENV=prod devenv shell -- mix release backplane --overwrite
```

- [ ] Boot with Memory enabled and assert the 31 default tools retain their exact names and schemas.
- [ ] Commit in reviewable units:

```bash
git commit -m "test(memory): freeze namespace compatibility"
git commit -m "refactor(memory): move modules under Backplane.Memory"
git commit -m "fix(memory): preserve legacy module and worker names"
```

PR 0A adds no migration and changes no public MCP/REST response.

---

## PR 0B — `feat/memory-v2-contracts`

### File structure

**Create:**

```text
apps/backplane_memory/lib/backplane/memory/config.ex
apps/backplane_memory/test/backplane/memory/config_test.exs
apps/backplane/test/integration/memory_mcp_contract_test.exs
docs/architecture/memory-v2.md
```

**Modify:**

```text
apps/backplane_system/lib/backplane/settings.ex
apps/backplane_memory/test/backplane/memory/service_test.exs
apps/backplane_memory/test/backplane/memory/service_tools_test.exs
apps/backplane_memory/test/backplane/memory/memories/search_test.exs
```

### Task 0B.1: Freeze the complete tool catalog and ten priority contracts

- [ ] Replace weak “at least 15/37” assertions with exact 31-core and 40-full name/schema assertions.
- [ ] Restore `memory.tools` after every mutating test and keep those tests `async: false`.
- [ ] Add handler-level success, empty, not-found, default, and filter tests for `remember`, `recall`, `list`, `forget`, `stats`, `profile`, `file_history`, `sessions`, `timeline`, and extended-only `consolidate`.
- [ ] Capture current quirks rather than fixing them: `profile` returns `building`, timeline group order is unspecified, and `consolidate` treats `session_id` as the worker argument without existence validation.
- [ ] Add transport-level tests in the `backplane` app using `Backplane.ConnCase`: manually register the managed service, call `tools/list` and `tools/call`, and assert JSON text content, validation `-32602`, `result.isError`, unknown-tool behavior when disabled, and no `structuredContent`/`output_schema`.
- [ ] Verify disabled behavior through registration state, not new handler guards.

Transport assertion shape:

```elixir
assert %{
         "result" => %{
           "content" => [%{"type" => "text", "text" => encoded}],
           "isError" => false
         }
       } = mcp_request("tools/call", params)

assert {:ok, decoded} = Jason.decode(encoded)
```

### Task 0B.2: Add typed disabled settings and the facade

**Files:** `Backplane.Settings`, new `Backplane.Memory.Config`, and config tests.

- [ ] Add all eight boolean defaults with descriptions to `Backplane.Settings.@defaults`.
- [ ] Add `pipeline_enabled?/0`, `events_enabled?/0`, `dual_write?/0`, `window_summaries_enabled?/0`, `session_summary_v2_enabled?/0`, `fact_extraction_v2_enabled?/0`, `procedure_extraction_v2_enabled?/0`, and `recall_v2_enabled?/0`.
- [ ] Use strict booleans. Do not accept legacy string `"true"` for new keys.
- [ ] Test every flag false by default, master-gate behavior, events dependency for dual-write, and independent child settings.
- [ ] Keep service registration boot-only and document the existing asynchronous settings-load caveat; do not expand this PR into a settings-readiness redesign.

Facade pattern:

```elixir
defmodule Backplane.Memory.Config do
  @moduledoc false

  @pipeline "memory.pipeline.enabled"

  def pipeline_enabled?, do: enabled?(@pipeline)
  def events_enabled?, do: pipeline_enabled?() and enabled?("memory.events.enabled")

  def dual_write? do
    events_enabled?() and enabled?("memory.events.dual_write")
  end

  defp enabled?(key), do: Backplane.Settings.get(key) == true
end
```

### Task 0B.3: Lock in generated-column FTS

- [ ] Add an explicit regression that inserts lexical-only rows, injects an embedding failure, calls the public recall path, and asserts ranked lexical matches.
- [ ] Assert the test migration exposes a generated `search_tsv` column and named GIN index.
- [ ] Do not add or alter a migration.
- [ ] Do not hardcode `bpm_memories.search_tsv` in a fragment because an Ecto alias hides the base table name.

Run:

```bash
MIX_ENV=test devenv shell -- mix test apps/backplane_memory/test/backplane/memory/memories/search_test.exs apps/backplane_memory/test/backplane/memory/service_test.exs
```

### Task 0B.4: Add the architecture record

**File:** `docs/architecture/memory-v2.md`.

- [ ] State `:backplane_memory` versus `Backplane.Memory` explicitly.
- [ ] Record 31/40 current MCP tools and compatibility policy.
- [ ] Record events as authoritative, with summaries/memories as derived projections.
- [ ] Define the master-gated flag hierarchy and three-flag dual-write rollout.
- [ ] Record generated-column FTS, boot-only service registration, and no-inline-LLM/embedding/Oban ingestion.
- [ ] Explain that PR 0B documents the target event architecture but creates no event table.
- [ ] Relate this record to `docs/memory-design.md` as the V2 evolution rather than silently contradicting it.

### Task 0B.5: Verify and commit PR 0B

- [ ] Run config, service, FTS, and transport contract files.
- [ ] Run the complete Memory app tests.
- [ ] Run the isolated warnings-as-errors compile and production release.
- [ ] Run the umbrella suite and compare against the two known failures.
- [ ] Prove no `bpm_events` or `bpm_streams` migration/file exists.
- [ ] Commit:

```bash
git commit -m "test(memory): freeze managed service contracts"
git commit -m "feat(memory): add v2 rollout controls"
git commit -m "docs(memory): record v2 foundation architecture"
```

---

## PR 1 — `feat/memory-event-stream`

### File structure

**Create:**

```text
apps/backplane_system/priv/repo/migrations/20260713000001_create_memory_event_stream.exs
apps/backplane_memory/lib/backplane/memory/events.ex
apps/backplane_memory/lib/backplane/memory/events/event.ex
apps/backplane_memory/lib/backplane/memory/events/stream.ex
apps/backplane_memory/lib/backplane/memory/events/types.ex
apps/backplane_memory/lib/backplane/memory/events/store.ex
apps/backplane_memory/lib/backplane/memory/events/query.ex
apps/backplane_memory/test/backplane/memory/events/event_test.exs
apps/backplane_memory/test/backplane/memory/events/store_test.exs
apps/backplane_memory/test/backplane/memory/events/query_test.exs
apps/backplane_memory/test/backplane/memory/events/concurrency_test.exs
apps/backplane_api/test/backplane/api/memory_router_test.exs
apps/backplane_memory/test/mix/tasks/memory_connect_test.exs
```

**Modify:**

```text
apps/backplane_memory/lib/backplane/memory/privacy/filter.ex
apps/backplane_memory/lib/backplane/memory/observations.ex
apps/backplane_memory/lib/backplane/memory/router.ex
apps/backplane_api/lib/backplane/api/router.ex
apps/backplane_memory/lib/mix/tasks/memory.connect.ex
apps/backplane_memory/priv/hooks/*.sh
apps/backplane_telemetry/lib/backplane_telemetry/telemetry_logger.ex
apps/backplane_system/lib/backplane/metrics.ex
```

### Task 1.1: Add reversible stream/event storage

- [ ] Write a migration with `bpm_streams` first and `bpm_events` second.
- [ ] Use text `stream_id` as the streams primary key and a restrictive foreign key from events.
- [ ] Use `:bigint` for sequence/cursors, `:binary_id` for event IDs/causation, `:utc_datetime_usec` for timestamps, and `:map` for JSON payload.
- [ ] Add unique `(stream_id, sequence)` and partial unique `idempotency_key` indexes with explicit names.
- [ ] Add only session/run/project/type time indexes from the objective. Do not duplicate the unique stream-sequence index and do not add payload GIN.
- [ ] Implement `down/0` that drops events before streams.
- [ ] Add `Stream` and `Event` schemas with focused changesets and database constraint names.

Migration constraint excerpt:

```elixir
create unique_index(:bpm_events, [:stream_id, :sequence],
         name: :bpm_events_stream_sequence_uniq
       )

create unique_index(:bpm_events, [:idempotency_key],
         where: "idempotency_key IS NOT NULL",
         name: :bpm_events_idempotency_key_uniq
       )
```

- [ ] In the test database, migrate, roll back this migration, assert both tables disappear, and migrate again.

### Task 1.2: Normalize events and enforce the taxonomy

**Files:** `events.ex`, `events/types.ex`, `events/event.ex`, and unit tests.

- [ ] Implement explicit/string-key normalization without atomizing external input.
- [ ] Require event type plus explicit stream or session-derived stream.
- [ ] Default namespace, payload, importance, occurred time, and event ID.
- [ ] Validate the objective taxonomy plus transitional `legacy.observation`.
- [ ] Reject invalid importance, payload shape, malformed UUIDs, and missing identity before a transaction starts.
- [ ] Return `{:ok, %Event{}} | {:error, reason}` from append; duplicates return the same shape.

### Task 1.3: Expand privacy filtering and payload bounds

**Files:** `privacy/filter.ex`, `privacy/filter_test.exs`, and `events/event_test.exs`.

- [ ] Preserve `Filter.apply/1` and its exact string-return contract for legacy callers.
- [ ] Add `apply_event/1` for recursive maps/lists/strings.
- [ ] Redact secret-looking values and sensitive map/header/environment keys at any depth.
- [ ] Strip null bytes.
- [ ] Apply the 64 KiB/256 KiB/512-grapheme limits and sanitized-value SHA-256 policy above.
- [ ] Add nested headers, environment maps, tool input/output, error, UTF-8 truncation, and oversized JSON tests.
- [ ] Assert raw secrets never appear in persisted content, payload, previews, digests, telemetry, or error strings.

### Task 1.4: Implement atomic, idempotent append

**File:** `events/store.ex`; tests in `store_test.exs` and `concurrency_test.exs`.

- [ ] Add `append_multi(multi, name, attrs)` as `@doc false` for transaction composition.
- [ ] In the transaction: resolve an existing idempotency key, insert stream on conflict, lock it `FOR UPDATE`, reject closed streams, fill only null metadata, allocate `next_sequence`, insert event, and update the cursor/last-event time.
- [ ] Let any later Multi failure roll back both the event and cursor.
- [ ] Handle a unique-idempotency race by rolling back, loading the winner outside the failed transaction, validating its identity/digest, and returning it as duplicate.
- [ ] Have the internal Multi value distinguish `{:inserted, event}` from `{:duplicate, event}` while the public API unwraps both to `{:ok, event}`.
- [ ] Emit telemetry only after transaction resolution; do not include attrs/content/payload in metadata.
- [ ] Implement all-or-nothing batch append with deterministic multi-stream lock order.

Composition shape:

```elixir
Ecto.Multi.new()
|> Backplane.Memory.Events.Store.append_multi(:event, event_attrs)
|> Ecto.Multi.insert(:observation, observation_changeset)
|> repo().transaction()
```

- [ ] Test sequence 1, sequential increments, exact duplicate, conflicting key, closed stream, batch rollback, and outer-Multi rollback leaving the next sequence at 1.
- [ ] For the 100-writer test, use `async: false` and separate `Sandbox.checkout(repo, sandbox: false)` connections per task, with unique stream IDs and explicit committed-row cleanup. A shared DataCase owner does not prove locking.
- [ ] Test “different streams do not block” with a barrier: hold stream A’s outer transaction open after append, prove stream B completes, then release A.

### Task 1.5: Implement range, timeline, and stream closure

**Files:** `events/query.ex`, `events.ex`, and query tests.

- [ ] Implement `range(stream_id, first..last)` ascending by sequence.
- [ ] Implement filters for stream/project/agent/session/run/type/tool/from/to/limit/cursor.
- [ ] Cap limit at 500 and default to 100.
- [ ] Encode/decode the `occurred_at + id` cursor as opaque URL-safe Base64 JSON.
- [ ] Return `%{events: events, next_cursor: cursor_or_nil}` from timeline.
- [ ] Implement idempotent `close_stream/1` and reject unknown streams.
- [ ] Add pagination stability tests where equal timestamps are disambiguated by ID.

### Task 1.6: Atomically dual-write observations and session events

**Files:** `observations.ex`, `observations_test.exs`, and compatibility tests.

- [ ] When `Config.dual_write?()` is false, execute the unchanged legacy path.
- [ ] When true, sanitize once, derive the event, compose event plus observation in one transaction, and return the inserted Observation.
- [ ] Generate the Observation UUID before composition and store it under `payload["_backplane"]["legacy_observation_id"]`. When `append_multi` reports a duplicate, load and return that Observation instead of inserting another row.
- [ ] Accept additive opts for explicit `event_type`, payload, identity, occurred time, and idempotency key.
- [ ] Transitional fallback: tool present/error false -> completed; tool present/error true -> failed; otherwise `legacy.observation`.
- [ ] On first session registration, append idempotent `session.started` in the same transaction while preserving insert-only project behavior.
- [ ] On first end transition, append `session.ended` and close the stream in the transaction; enqueue the legacy summary only after commit.
- [ ] Repeated/unknown end calls remain `{0, nil}` and do not enqueue or append.
- [ ] Keep Summary/Episodic workers and all LLM calls outside the event transaction.
- [ ] Test all flags false, events-only, dual-write, transaction failure rollback, unchanged successful return structs, and unchanged summary enqueue behavior.

### Task 1.7: Mount and freeze the HTTP ingestion path

**Files:** Memory router, API router, and `memory_router_test.exs`.

- [ ] Change Memory router paths from `/api/memory/...` to prefix-relative paths.
- [ ] Add `forward("/api/memory", Backplane.Memory.Router)` before the public catch-all.
- [ ] Preserve successful status/body contracts for session start/end, observations, file history, profile, graph, audit, diagnose, and heal; return non-2xx on a newly visible transactional persistence failure so hooks can retry rather than accepting lost data.
- [ ] Pass additive event attributes through the observation endpoint without exposing an event object in the response.
- [ ] Preserve the existing observation error response in this milestone; record any unsafe `inspect(changeset)` behavior as separate follow-up rather than mixing a response change into PR 1.
- [ ] Prove `/api/memory/session/start`, `/observations`, and `/session/end` execute through `Backplane.Api.Endpoint` rather than only direct-plug tests.

### Task 1.8: Repair hook installation and explicit event mapping

**Files:** `memory.connect.ex`, all hook scripts, and Mix task tests.

- [ ] Change the generated `hooks` value from a list to a map keyed by current Claude Code event names.
- [ ] Register `SessionStart`, `SessionEnd`, `UserPromptSubmit`, `PostToolUse`, `PostToolUseFailure`, `PreCompact`, `SubagentStart`, `SubagentStop`, and `Stop` correctly.
- [ ] Keep the post-commit hook under `PostToolUse` with a Bash matcher and an in-script `git commit` command check so it does not classify every tool as a commit.
- [ ] Emit explicit mappings:

```text
SessionStart       -> session.started
SessionEnd         -> session.ended
UserPromptSubmit   -> conversation.user_message
PostToolUse        -> tool.call.completed
PostToolUseFailure -> tool.call.failed
Stop               -> agent.run.completed
PreCompact         -> legacy.observation
SubagentStart      -> session.started
SubagentStop       -> session.ended
post git commit    -> tool.call.completed, tool_name=git_commit
```

- [ ] Include tool input/output in payload, keep legacy content as the displayable output, and use `tool_use_id` in the idempotency key where present.
- [ ] Preserve two-second non-blocking curl behavior and set the generated SessionEnd command hook timeout to 3 seconds so Claude Code's session-end budget can accommodate the request.
- [ ] Test idempotent merge into an existing settings file, preservation of unrelated hooks, event keys, matchers, and generated commands using a temp home directory.

### Task 1.9: Expose ingestion telemetry safely

**Files:** `events/store.ex`, `TelemetryLogger`, `Backplane.Metrics`, and their tests.

- [ ] Emit exact events `[:backplane, :memory, :event, :append]`, `:duplicate`, and `:error` with monotonic duration plus content/payload byte measurements.
- [ ] Restrict metadata to stream/type/project/agent/session/run/status.
- [ ] Subscribe the telemetry logger to all three events.
- [ ] Subscribe `Backplane.Metrics` and expose counters for appended, duplicate, error, plus append duration.
- [ ] Add tests that attach a temporary handler, assert measurements/metadata, and refute content/secrets/headers in emitted terms.

Metrics handler pattern:

```elixir
def handle_event([:backplane, :memory, :event, :append], measurements, _metadata, _config) do
  inc("memory_events_appended")
  record_timing("memory_event_append_duration", native_to_microseconds(measurements.duration))
end
```

### Task 1.10: Demonstrate the milestone and commit PR 1

- [ ] Run all Memory event, observation, privacy, router, hook, telemetry, and MCP contract tests.
- [ ] Run the full Memory app tests.
- [ ] Run the isolated warnings-as-errors compile.
- [ ] Exercise migration down/up in test.
- [ ] Build the production release.
- [ ] Start the dev app with pipeline/events/dual-write enabled and demonstrate:

```text
register session -> memory_sessions + sequence 1 session.started
record tool result -> bpm_observations + sequence 2 tool.call.completed
retry same tool_use_id -> existing event and linked observation returned; no duplicate rows
end session -> sequence 3 session.ended + closed stream + legacy summary enqueue
memory::recall -> unchanged lexical/vector response contract
```

- [ ] Query the stream ordered by sequence and prove one session maps to one stream.
- [ ] Verify all flags false removes the event path completely.
- [ ] Run the umbrella suite and compare against the two recorded baseline failures.
- [ ] Commit in reviewable units:

```bash
git commit -m "feat(memory): add ordered event stream storage"
git commit -m "feat(memory): add atomic observation event dual-write"
git commit -m "fix(memory): connect lifecycle hooks to event ingestion"
git commit -m "feat(memory): expose event ingestion telemetry"
```

---

## Final acceptance checklist

### PR 0A

- [ ] No migration, table, setting, MCP name/schema, or response change.
- [ ] No internal `BackplaneMemory.*` reference outside the compatibility allowlist.
- [ ] All old public context/service and worker modules remain callable.
- [ ] `:backplane_memory` remains permanent in the release and boot registration works.

### PR 0B

- [ ] Exact 31/40 catalog and ten priority MCP behaviors are frozen at handler and wire levels.
- [ ] All eight flags exist as typed false defaults behind a master gate.
- [ ] Embedding-disabled recall uses the generated/indexed FTS column.
- [ ] No event table exists and all-false behavior is unchanged.
- [ ] Architecture record is complete.

### PR 1

- [ ] Reversible stream/event migration with no redundant or payload-wide index.
- [ ] Per-stream monotonic ordering under real concurrent connections.
- [ ] Strict idempotency, conflict detection, cursor rollback, and closed-stream rules.
- [ ] Recursive secret filtering and bounded content/payload persistence.
- [ ] Atomic observation/event dual-write with unchanged successful observation/session returns.
- [ ] Existing summary behavior stays outside event storage and remains exactly once.
- [ ] HTTP/hooks execute the milestone flow using explicit lifecycle event types.
- [ ] Telemetry exposes health without content or secrets.
- [ ] No window/session summary V2, facts, procedures, Recall V2, or public timeline tool is introduced.

## Plan self-review

- Spec coverage: all objective sections 1–6 map to branch setup, PR 0A, PR 0B, PR 1, verification, or explicit non-goals.
- Repository corrections included: 31/40 tools, 15 stable tables, 10 workers, unmounted Memory router, outdated hook wiring, generated-column FTS, migration location, and true multi-connection concurrency tests.
- Placeholder scan: clear; every implementation decision is explicit.
- Type consistency: `stream_id` is text, event IDs are UUIDs, sequence/cursors are bigint, times are microsecond UTC, payload is a map, and all public result shapes are defined once above.
