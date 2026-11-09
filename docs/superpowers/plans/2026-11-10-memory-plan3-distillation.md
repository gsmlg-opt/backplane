# Memory Plan 3 — Memory Agent Distillation & Hybrid Recall Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After a captured session closes, a memory maintenance agent running on `backplane_agent_runtime` reads the session's observations and writes fact/procedure/worklog memories (with provenance back to the source events) through the shared merge rules. Sessions the working agent already distilled itself are only reviewed for merge/dedupe. Every failure is visible. Recall fuses full-text and vector ranks when an embedding model is configured.

**Architecture:**
- **Trigger and state.** A new `memory_distillations` table holds one row per session subject. It is populated when a session's projection transitions into `completed` or `abandoned`. A Styx cron scheduler claims due rows, bounded by a concurrency setting, and enqueues one `DistillWorker` per session.
- **Running the agent.** The worker splits the session's observations into byte-bounded chunks. For each chunk it runs one bounded `Backplane.AgentRuntime.Conversation` (ephemeral store) with a chat-completions provider adapter and five memory-domain tools.
- **LLM access.** The adapter calls Backplane's own LLM proxy (`/v1/chat/completions`, non-streaming) with `memory.llm_model`. The proxy URL comes from runtime config, not a hard-coded `localhost:4220`.
- **Embeddings.** A nullable `embedding vector(2560)` column is filled by a background worker. `Records.Search` fuses full-text ranks and vector ranks with Reciprocal Rank Fusion (RRF) and falls back to full text on any embedding failure.

**Tech Stack:** Elixir umbrella; `backplane_agent_runtime` (Conversation, ToolRegistry, EphemeralStore, ConversationAdapter); Req; Ecto/Postgres + pgvector 0.8; Styx (cron + queues); phoenix_duskmoon admin.

**Spec:** `docs/superpowers/specs/2026-11-09-memory-simplification-design.md` §6.4 (distillation, merge rules, failure visibility), §6.5 (memory agent), §6.7 (RRF recall), §6.10 (config/visibility, no hard-coded 4220), §4 (anti-goals), §8 items 2, 3, 6.

## Global Constraints

- Single user; provenance is descriptive only. Agent-written records carry `writer: "memory_agent"`, the session's `host_id` / `agent_id` / `integration` / `session_id`, and `source_event_ids` drawn only from event ids in the chunk being processed. Never invent ids.
- Distillation failure is never silent (§4). Every failed or blocked run stores a human-readable `last_error`, logs `Logger.warning`, and is shown in admin. A missing `memory.llm_model` marks due rows `blocked` with reason `"memory.llm_model not configured"`.
- Merge rules (§6.4) are applied by `Backplane.Memory.Records`:
  - `fact`: same `subject_keys` + `property` → the newer fact supersedes the older one. This already exists and is observed_at-aware.
  - `procedure`: the agent decides similarity through its tools. A merge is `Records.replace/2`, which writes the new record and marks the old one `superseded` pointing at it.
  - `worklog`: append only.
- The memory agent has no git, no shell and no workspace. Its tools act only on the memory domain.
- No new public MCP tools and no scope changes.
- LLM and embedding calls reach the proxy through `Application.get_env(:backplane_memory, :llm_proxy_url)`:
  - `config/runtime.exs` sets it to `"http://127.0.0.1:#{api_port}"` for prod.
  - `config/dev.exs` sets `"http://localhost:4220"`.
  - Requests send `x-backplane-memory-capture: skip`, plus `x-backplane-memory-origin: agent` (chat) or `embedding`, and authorize with `Backplane.Memory.ProxyAuth.authorize/1`.
- `observed_at` more than 5 minutes in the future is clamped to now in `Records.remember/1` (parked ruling from Plan 2).
- macOS dev uses Postgres.app (`unset PGHOST`); never start devenv. Run tests per app from the umbrella root (`mix test apps/<app>/test/...`).
- Commit once per task with Conventional Commits; no Claude/Generated-with trailers. Never `git add .superpowers/`.

## Review Focus

1. **The model calls `write_memory` with a `fact` lacking subjects or property, or with an unknown kind.** The tool returns a structured error to the model and the conversation continues; nothing crashes and no invalid record is stored. Test in Task 4.
2. **A retried run on a session that already partly succeeded.** Identical candidates do not duplicate: `request_key = "distill:" <> subject_id <> ":" <> sha256(kind|subject_keys|property|content)`. Test in Task 4.
3. **A session that reopens** (new events after `completed`) and closes again. The distillation row returns to `pending` and the next run uses `review` mode for records it already wrote. Test in Task 2.
4. **The configured model routes to a provider that rejects `tools`** (HTTP 400/422) or returns no choices. The run becomes `failed` with a readable `last_error` naming the model; it is not `completed` with zero records. Test in Task 3/5.
5. **The embedding model is configured but the proxy returns errors, or vectors of the wrong dimension.** `memory::search` still returns full-text results; the embed worker leaves `embedding` null and logs a warning. Test in Task 6.

---

### Task 1: Records groundwork and proxy URL

**Files:**
- Modify: `apps/backplane_memory/lib/backplane/memory/records.ex`
- Modify: `config/runtime.exs`, `config/dev.exs`
- Test: `apps/backplane_memory/test/backplane/memory/records_test.exs`

**Interfaces — produces:**
- `Records.replace(old_id :: Ecto.UUID.t(), attrs :: map()) :: {:ok, Record.t()} | {:error, :not_found | :not_active | Ecto.Changeset.t()}`. In one transaction it inserts `attrs` through the same `prepare` / `request_key` path as `remember/1`, then sets the old row `status: "superseded", superseded_by: new.id` and bumps `updated_at`. It returns `:not_active` if the old row is not active.
- `Records.agent_written_for_session(host_id :: String.t() | nil, session_id :: String.t()) :: [Record.t()]` returns active records with `writer == "agent"` and that `session_id`; when `host_id` is non-nil, the `host_id` must match too.
- The clamp in `prepare/1`: an `observed_at` (DateTime or ISO8601 string) later than `now + 300s` becomes `now`.

- [ ] Step 1: Write failing tests:
  - `replace/2` supersedes an active procedure, links `superseded_by`, and the new row is active.
  - `replace/2` on a forgotten id returns `{:error, :not_active}`.
  - `agent_written_for_session/2` excludes `memory_agent` and `user` writers and other sessions.
  - `remember/1` with `observed_at = now + 1 day` stores an observed_at within 5 s of now; `now + 60 s` is stored unchanged.
- [ ] Step 2: Run `mix test apps/backplane_memory/test/backplane/memory/records_test.exs`; expect the new tests to fail.
- [ ] Step 3: Implement the functions above. Add `config :backplane_memory, llm_proxy_url: ...` to `config/dev.exs` (`"http://localhost:4220"`) and to the prod branch of `config/runtime.exs` (`"http://127.0.0.1:#{api_port}"`, reusing the existing `api_port`). Change the default in `Embedding.Client` from a literal to `Application.fetch_env!(:backplane_memory, :llm_proxy_url)`, and set `config :backplane_memory, llm_proxy_url: "http://localhost:4220"` in `config/test.exs` so tests keep working.
- [ ] Step 4: Run the memory test suite; it must pass.
- [ ] Step 5: Commit `feat(memory): add record replace, agent-written lookup and observed_at clamp`.

### Task 2: Distillation state and session-close trigger

**Files:**
- Create: `apps/backplane_system/priv/repo/migrations/20261110000002_create_memory_distillations.exs` (prefix-safe like `20261109000001`)
- Create: `apps/backplane_memory/lib/backplane/memory/distillation.ex` (schema), `apps/backplane_memory/lib/backplane/memory/distillations.ex` (context)
- Modify: `apps/backplane_memory/lib/backplane/memory/projections/rebuild.ex` (`replace_session_row/4` transition hook)
- Modify: `apps/backplane_memory/lib/backplane/memory/config.ex` (two settings)
- Test: `apps/backplane_memory/test/backplane/memory/distillations_test.exs`

**Table `memory_distillations`:**
- `subject_id` string PK (= `bpm_projected_sessions.subject_id`), `host_id`, `session_id`, `agent_id`, `integration`.
- `status` string: `pending | running | completed | failed | blocked`.
- `mode` string: `distill | review`.
- `attempts` integer default 0, `due_at`, `started_at`, `finished_at` (utc_datetime_usec).
- `last_error` text, `records_written` integer default 0, timestamps.
- Index on `(status, due_at)`.

**Settings** (add to `@editable_settings`):
- `memory.distill_delay_seconds`, label "Distillation delay seconds", integer 0..86_400, default 600.
- `memory.distill_max_concurrency`, label "Distillation concurrency", integer 1..8, default 2.
- Accessors: `Config.distill_delay_seconds/0`, `Config.distill_max_concurrency/0`.

**Interfaces — produces (`Backplane.Memory.Distillations`):**
- `schedule(session :: map()) :: {:ok, Distillation.t()}`. The map needs `subject_id`, `host_id`, `session_id`, `agent_id`, `integration`. Upsert on `subject_id` with `status: "pending"`, `due_at: now + delay`, `last_error: nil`; `mode` is `"review"` when `Records.agent_written_for_session/2` is non-empty, else `"distill"`. A `running` row is left untouched (the scheduler re-checks after the run).
- `claim_due(now :: DateTime.t(), limit :: pos_integer()) :: [Distillation.t()]`. Atomically moves up to `limit` rows from `pending` with `due_at <= now` to `running` (`FOR UPDATE SKIP LOCKED`), sets `started_at`, increments `attempts`, and recomputes `mode`.
- `complete(subject_id, records_written :: non_neg_integer()) :: :ok`
- `fail(subject_id, reason :: String.t()) :: :ok` (also `Logger.warning`)
- `block_due(now, reason :: String.t()) :: non_neg_integer()`. Pending rows that are due become `blocked`; it logs one warning per call when the count is > 0.
- `unblock_all() :: non_neg_integer()`: `blocked` → `pending`.
- `reset_stale_running(older_than :: DateTime.t()) :: non_neg_integer()`: `running` → `pending`.
- `retry(subject_id) :: {:ok, Distillation.t()} | {:error, :not_found}`: `failed` / `blocked` / `completed` → `pending`, due now.
- `running_count() :: non_neg_integer()`
- `for_subjects([String.t()]) :: %{String.t() => Distillation.t()}`
- `counts() :: %{String.t() => non_neg_integer()}`

**Trigger:** in `replace_session_row/4`, when `previous_status != read_model["status"]` and the new status is `"completed"` or `"abandoned"`, call `Distillations.schedule/1` after the upsert. `"stopped"` does not trigger, because per-turn Stop hooks emit it.

- [ ] Step 1: Write failing tests:
  - A rebuild that ends a session (an `agent.session.ended` event) creates a `pending` row due at `now + 600 s`.
  - A `stopped` transition creates no row.
  - Reopening and closing a completed session sets the row back to `pending`.
  - `mode` is `"review"` when an `agent`-written record exists for that host/session.
  - `claim_due/2` respects the limit, skips future rows and increments attempts.
  - `block_due/2` then `unblock_all/0` round-trips.
  - `reset_stale_running/1` and `retry/1` work.
- [ ] Step 2: Run them; expect failure.
- [ ] Step 3: Implement the migration, schema, context, settings and trigger.
- [ ] Step 4: `MIX_ENV=test mix ecto.migrate`, then run the memory suite; it must pass.
- [ ] Step 5: Commit `feat(memory): track per-session distillation state on session close`.

### Task 3: Chat-completions client and runtime provider adapter

**Files:**
- Modify: `apps/backplane_memory/mix.exs` (add `{:backplane_agent_runtime, in_umbrella: true}`)
- Create: `apps/backplane_memory/lib/backplane/memory/llm/chat_client.ex`, `apps/backplane_memory/lib/backplane/memory/distill/provider.ex`
- Test: `apps/backplane_memory/test/backplane/memory/llm/chat_client_test.exs`, `.../distill/provider_test.exs`

**Interfaces — produces:**
- `Backplane.Memory.LLM.ChatClient.complete(messages :: [map()], tools :: [map()], opts :: keyword()) :: {:ok, %{content: String.t() | nil, tool_calls: [%{id: String.t(), name: String.t(), arguments: map()}], usage: map() | nil}} | {:error, String.t()}`.
  - Opts: `:model` (default `Config.llm_model()`), `:req_options` (tests pass `plug:`), `:receive_timeout` (default 120_000).
  - It POSTs to `llm_proxy_url <> "/v1/chat/completions"` with `%{model, messages, tools, tool_choice: "auto", stream: false}`. `tools` are OpenAI `{"type":"function","function":{name, description, parameters}}`; the input is `%{name:, description:, parameters:}` from the runtime request.
  - Tool-call `arguments` JSON strings are decoded; invalid JSON yields `arguments: %{"_invalid_json" => raw}`, so the tool returns a validation error to the model.
  - Every error is a readable string that includes the model:
    - `"memory.llm_model not configured"`
    - `"LLM proxy returned HTTP <status> for model <m>: <first 300 chars of body>"`
    - `"LLM proxy unreachable: <reason>"`
    - `"LLM response for model <m> had no choices"`
    - `"proxy credential unavailable"`
- `Backplane.Memory.Distill.Provider` implements `Backplane.AgentRuntime.ConversationAdapter`. `stream(request, context)` converts runtime messages (system/user/assistant with tool_calls/tool results) to chat format, calls `ChatClient.complete/3` (`context[:chat_client]` overrides the module for tests), and returns a list of normalized events:
  - `response_started`;
  - one `tool_call_completed` per call;
  - `usage_updated` when present;
  - then `response_completed` with `message: %{role: :assistant, content: ...}`, or on error `response_failed` with the error string.
  - Use the exact event shapes from `apps/backplane_agent_runtime/lib/backplane/agent_runtime/conversation_adapter.ex` and `EMBEDDING.md`.

- [ ] Step 1: Write failing tests:
  - ChatClient against a `Req` plug stub: a tool-call response is decoded; HTTP 400 maps to an error string containing the model and the status; no model returns the not-configured error; requests carry the `x-backplane-memory-capture: skip` header and `stream: false`.
  - Provider: given a stub chat client returning one tool call, the stream is `[response_started, tool_call_completed, response_completed]`; given an error, it ends in `response_failed`.
  - A runtime round-trip with `Conversation.start_link` (EphemeralStore, one no-op test tool) reaches `run_completed`.
- [ ] Step 2: Run; expect failure.
- [ ] Step 3: Implement.
- [ ] Step 4: Run the memory suite and `mix compile --warnings-as-errors`.
- [ ] Step 5: Commit `feat(memory): add proxy chat client and agent runtime provider adapter`.

### Task 4: Memory agent tools, chunker, prompts and run-one-chunk

**Files:**
- Create: `apps/backplane_memory/lib/backplane/memory/distill/chunker.ex`, `.../distill/tool_backend.ex`, `.../distill/prompts.ex`, `.../distill/agent.ex`
- Test: `apps/backplane_memory/test/backplane/memory/distill/{chunker,tool_backend,agent}_test.exs`

**Interfaces — produces:**
- `Chunker.chunks(observations :: [ProjectedObservation.t()], max_bytes :: pos_integer()) :: [[map()]]`.
  - Each observation is rendered as `%{"event_id", "at", "type", "tool", "content"}`, ordered by `source_sequence`, with `content` truncated to 4_000 bytes.
  - Chunks are greedy-packed by encoded JSON size and never empty.
  - The default `max_bytes` is 24_000.
- `ToolBackend.execute(operation)` dispatches on the tool name. `backend_context` holds `%{session: map, chunk_event_ids: MapSet.t(), mode: "distill" | "review", subject_id: String.t(), written: pid_or_counter}`. The five tools, all with JSON Schema 2020-12 and `safety` set:
  - `read_chunk`, read_only true. Returns the current chunk's observations, plus in `review` mode the session's agent-written records via `Records.to_map/1`.
  - `search_memory {query, kind?, subject?}`, read_only true. Calls `Records.search/2` with limit 10 and returns `Records.to_map/1` maps.
  - `write_memory {kind, content, title?, subjects?, property?, tags?, source_event_ids}`, read_only false.
    - Validation errors are returned as `{:ok, %{content: "error: ..."}}`, never raised, so the model can correct itself:
      - `kind` must be in `fact|procedure|worklog`;
      - a `fact` needs non-empty `subjects` and `property`;
      - `source_event_ids` must be a non-empty subset of `chunk_event_ids`.
    - It sets `writer: "memory_agent"` and the session provenance, uses `request_key` as in Review Focus 2, and `observed_at` = the latest cited event's `at`.
  - `replace_memory {id, ...write_memory fields}`, read_only false. Uses `Records.replace/2`; the old record must be an active `procedure` or `fact`.
  - `forget_memory {id, reason}`, read_only false. Only for an exact duplicate of another active record; reason is required.
- `Prompts.system(mode)` returns the system instruction string.
  - `distill`: extract only durable environment facts (where repos, services and paths live per host), reusable procedures (how something was done on which host, with caveats) and one worklog line per meaningful unit of work. Always `search_memory` before writing; merge procedures through `replace_memory`; write nothing when nothing is worth remembering; cite event ids.
  - `review`: the working agent already wrote memories for this session; only merge or dedupe them against existing memory; do not re-extract.
- `Agent.run_chunk(session :: map(), chunk :: [map()], mode :: String.t(), opts :: keyword()) :: {:ok, %{records_written: non_neg_integer()}} | {:error, String.t()}`.
  - It starts a `Conversation` under `Backplane.Memory.Distill.TaskSupervisor`, added to `Backplane.Memory.Application` children as `{Task.Supervisor, name: Backplane.Memory.Distill.TaskSupervisor}`.
  - Conversation options:
    - `run_id`: `"distill-" <> subject_id <> "-" <> chunk_index <> "-" <> unique`;
    - `EphemeralStore`;
    - `provider: Distill.Provider` (`opts[:provider]` overrides for tests);
    - `messages`: the system prompt;
    - `authority`: caller `"backplane_memory"`, grants = the five tool names;
    - `work: 40`, `run_timeout: 240_000`.
  - It prompts `"Process this session chunk."`, waits for `run_completed` / `run_failed` with a 250_000 ms receive timeout, stops the conversation, and returns the counted writes.
  - A `run_failed` returns the failure reason as a string.

- [ ] Step 1: Write failing tests:
  - Chunker packing and ordering, and truncation of one oversized observation.
  - ToolBackend: an invalid fact (no property) returns an error text and stores nothing; a valid fact gets `writer` `memory_agent`, provenance and source ids; source ids outside the chunk are rejected; repeated identical writes produce one record; `replace_memory` supersedes; `search_memory` returns other hosts' records (global recall).
  - Agent: with a scripted fake provider (first response calls `search_memory`, second calls `write_memory`, third completes), `run_chunk` returns `records_written: 1`; a fake provider that fails returns `{:error, reason}`.
- [ ] Step 2: Run; expect failure.
- [ ] Step 3: Implement.
- [ ] Step 4: Run the memory suite.
- [ ] Step 5: Commit `feat(memory): add memory agent tools, chunking and per-chunk runs`.

### Task 5: Scheduler and distill workers

**Files:**
- Create: `apps/backplane_memory/lib/backplane/memory/distill.ex`, `.../workers/distill_scheduler_worker.ex`, `.../workers/distill_worker.ex`
- Modify: `config/config.exs` (crontab `{"* * * * *", Backplane.Memory.Workers.DistillSchedulerWorker}`; queue `memory` concurrency stays 3)
- Test: `apps/backplane_memory/test/backplane/memory/distill_test.exs`, `.../workers/distill_scheduler_worker_test.exs`

**Interfaces — produces:**
- `Distill.run(subject_id :: String.t(), opts :: keyword()) :: :ok`.
  - It loads the session and its `ProjectedObservation`s ordered by `source_sequence`.
  - Zero observations → `Distillations.complete(subject_id, 0)` without any LLM call.
  - Otherwise it runs `Agent.run_chunk/4` per chunk, sequentially. The first error stops the run with `Distillations.fail(subject_id, "chunk <i>/<n>: <reason>")`, keeping the counts already written; on success it calls `Distillations.complete(subject_id, total)`.
- `DistillSchedulerWorker.perform/1` (Styx, queue `:memory`, max_attempts 1). In order:
  1. `reset_stale_running(now - 900 s)`;
  2. if `Config.llm_model()` is nil, `block_due(now, "memory.llm_model not configured")` and stop;
  3. otherwise `unblock_all()`, then `claim_due(now, max(Config.distill_max_concurrency() - running_count(), 0))`, and enqueue `DistillWorker.new(%{"subject_id" => id}, unique: [period: 900, keys: [:subject_id]])` for each.
- `DistillWorker.perform/1` (queue `:llm`, max_attempts 1) calls `Distill.run/2` and rescues any exception into `Distillations.fail/2` with `Exception.message/1`.

- [ ] Step 1: Write failing tests (Styx `testing: :inline`; a fake provider through app env `config :backplane_memory, :distill_provider` read by `Agent`):
  - The scheduler with no model blocks due rows and leaves future rows pending.
  - With a model set it claims at most the concurrency limit and runs them; the end state is `completed` with `records_written`.
  - A failing provider ends `failed` with a `last_error` containing the reason.
  - An empty session completes with 0 records and no provider call.
  - A raised exception inside `run_chunk` becomes `failed`.
- [ ] Step 2: Run; expect failure.
- [ ] Step 3: Implement.
- [ ] Step 4: Run the memory suite.
- [ ] Step 5: Commit `feat(memory): schedule and run session distillation in the background`.

### Task 6: Record embeddings and RRF hybrid search

**Files:**
- Create: `apps/backplane_system/priv/repo/migrations/20261110000003_add_memory_records_embedding.exs` (`ALTER TABLE ... ADD COLUMN embedding vector(2560)`, prefix-safe; no ANN index, because pgvector HNSW/IVFFlat cap `vector` at 2000 dims and single-user volume makes an exact scan acceptable)
- Modify: `record.ex` (`field :embedding, Pgvector.Ecto.Vector`, not castable), `records/search.ex`
- Create: `apps/backplane_memory/lib/backplane/memory/workers/embed_records_worker.ex`
- Modify: `config/config.exs` (crontab `{"*/5 * * * *", Backplane.Memory.Workers.EmbedRecordsWorker}`), `records.ex` (after a successful insert, enqueue `EmbedRecordsWorker.new(%{})` best-effort when `Embedding.Client.configured?()`)
- Test: `apps/backplane_memory/test/backplane/memory/records/search_test.exs`, `.../workers/embed_records_worker_test.exs`

**Interfaces — produces:**
- `EmbedRecordsWorker.perform/1` (queue `:embeddings`, unique period 60). It embeds up to 50 active records with a null `embedding`, using `Embedding.Client.embed(texts, :document)` where text = `title <> "\n" <> content`, and writes the vectors. When unconfigured it does nothing; on `{:error, reason}` it logs a warning and leaves the column null. It goes through `Embedding.CircuitBreaker` (`allow_request?` / `record_success` / `record_failure`).
- `Search.search/2`:
  - Unconfigured: unchanged behaviour.
  - Configured: it also embeds the query (`:query` mode), takes the top 50 by `embedding <=> query_vector` among rows matching the same filters with a non-null embedding, takes the top 50 full-text ids, and fuses with RRF `score = Σ 1/(60 + rank)`. Then it applies `limit` and `within_budget`.
  - Any embedding error, or an open breaker, silently uses the full-text path for that query, logging at debug with the reason; the worker's warning carries visibility.

- [ ] Step 1: Write failing tests:
  - A Req plug stub serving 2560-dim vectors: a record with no keyword overlap but a near-identical vector is returned for the query when configured, and is not returned when unconfigured.
  - The proxy returning 500 → search still returns full-text matches.
  - The worker fills embeddings, and skips rows when the proxy returns wrong-dimension vectors.
- [ ] Step 2: Run; expect failure.
- [ ] Step 3: Implement.
- [ ] Step 4: `MIX_ENV=test mix ecto.migrate`; run the memory suite.
- [ ] Step 5: Commit `feat(memory): embed records and fuse vector and full-text recall`.

### Task 7: Admin visibility and docs

**Files:**
- Modify: `apps/backplane_admin/lib/backplane/admin/live/memory_sessions_live.ex` (columns "Distillation" (status/mode), "Error" (last_error, truncated to 200 chars) and "Records"; a "Retry" `dm_btn` for `failed` / `blocked` / `completed` calling `Distillations.retry/1`)
- Modify: `apps/backplane_admin/lib/backplane/admin/live/memory_overview_live.ex`:
  - keep the existing "提炼未启用" alert;
  - add a `dm_alert` `variant="error"` id `memory-distill-failed` when `counts()["failed"] > 0`, text `"<n> 个会话提炼失败，见 Sessions 页"`;
  - add an alert id `memory-distill-blocked` when blocked > 0.
- Modify: `apps/backplane_memory/lib/backplane/memory/admin_queries.ex` (`recent_sessions/1` attaches `distillation` via `Distillations.for_subjects/1`)
- Modify: `docs/architecture/memory.md` (Distillation and Recall sections; remove "Automatic distillation … not yet built")
- Test: `apps/backplane_admin/test/backplane/admin/live/memory_sessions_live_test.exs`, `memory_overview_live_test.exs`

- [ ] Step 1: Write failing LiveView tests:
  - A failed row shows its status and error, and Retry sets it to pending.
  - The overview shows `#memory-distill-failed` when a failed row exists.
  - The config page lists the two new settings.
- [ ] Step 2: Run; expect failure.
- [ ] Step 3: Implement with phoenix_duskmoon components only.
- [ ] Step 4: Run the admin and memory suites.
- [ ] Step 5: Commit `feat(admin): show session distillation status, failures and retry`.

### Task 8: Live verification (controller)

- [ ] Set `memory.llm_model` (an existing OpenAI-compatible route that supports tool calling) and optionally `memory.embed_model` on the Postgres.app dev DB.
- [ ] Set `memory.distill_delay_seconds` to 0.
- [ ] Capture a real session through the host agent (hooks POST, then SessionEnd).
- [ ] Confirm the row runs to `completed`, and that the fact/procedure/worklog records cite source event ids from that session (spec §8.2).
- [ ] Repeat with a changed repo path; the default recall returns only the new fact (§8.3).
- [ ] Unset the model; the admin shows blocked and the log shows a warning (§8.6).
- [ ] Record the results in the ledger.
