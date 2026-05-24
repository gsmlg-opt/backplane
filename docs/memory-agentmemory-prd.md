# Backplane Memory — agentmemory Feature Parity PRD

**Status:** Draft (interview-resolved)
**Owner:** Backplane
**Reference:** [`docs/memory-prd.md`](memory-prd.md) (v1 foundation — read that first)
**Target:** Feature parity with [agentmemory](https://github.com/rohitg00/agentmemory), scoped by design interview

---

## 1. Overview

`docs/memory-prd.md` defines the v1 memory foundation: schema, hybrid recall, 3-tier consolidation, privacy proxy, MCP surface, and OpenClaw/Hermes plugins. This document extends that baseline to full agentmemory parity. Every decision in this PRD was resolved through a design interview — rationale is included inline.

The work is organised into six milestone groups (M7–M12) that build on v1's M1–M6.

---

## 2. Decisions Log

The following decisions were made during the design interview and are fixed for this scope:

| Decision | Resolved |
|----------|---------|
| Search | Postgres FTS (`tsvector` + `ts_rank`) only — no BM25 extension |
| Code location | `apps/backplane_memory` (already exists) |
| Knowledge graph | Included; auto-enabled when `memory.llm_model` setting is configured |
| LLM config | `memory.llm_model` system setting — picks an auto-model alias (`fast`, `smart`, `expert`) or specific `provider/model` from the LLM proxy |
| Memory config UI | Dedicated left-side menu section in admin with 8 entries |
| Graph extraction threshold | N=3 minimum observations; configurable as `memory.graph_min_observations` |
| Context injection | Off by default; toggle in memory config |
| Hook suite | 10 hooks (see M8); `PreToolUse` and `Notification` dropped |
| Session replay | Deferred to future milestone |
| Vision | Dropped entirely |
| Mesh sync | Dropped — single Postgres server handles consistency |
| Filesystem watcher | Dropped |
| Obsidian export | Dropped |
| MEMORY.md bridge | Dropped |
| Git snapshots | Dropped from current scope; noted as future "review snapshot" milestone |
| Benchmarking | Lightweight `mix memory.eval` task only; no DB table or UI |
| Temporal graph | Dropped — plain `created_at` on edges is sufficient |
| Facets | Included with `memory_facets` table and strict dimension validation |
| M10 coordination scope | Leases + signals + actions/frontier/next + team memory only |
| Routines, checkpoints, sentinels, sketches, crystallize | All dropped |
| Slot reflection | Included; tightly grounded prompt, 5-item cap |
| Query expansion | Included; configurable on/off in memory config |
| Decay parameters | 30-day period, 0.1 eviction threshold, no row cap — all configurable |
| Consolidation triggers | SessionEnd (synthetic) → Oban async (LLM) → nightly (LLM) + 4-hour fallback sweep |
| Claude Code skills | All 4 (`/recall`, `/remember`, `/session-history`, `/forget`); published via Backplane skill hub |
| Admin UI navigation | Left-side menu (not tabs) |

---

## 3. Capability Areas

| Area | Milestone | What it adds |
|------|-----------|-------------|
| **Search & Intelligence** | M7 | Knowledge graph, project profile, query expansion, reranking |
| **Hook Suite & Capture** | M8 | 10-hook lifecycle, context injection, file history |
| **Advanced Memory** | M9 | Confidence scoring, access reinforcement, facets |
| **Multi-agent Coordination** | M10 | Team memory, leases, signals, actions/frontier/next |
| **Full MCP Surface** | M11 | ~37 tools, 6 resources, 3 prompts, 4 skills, memory slots |
| **Observability & Tooling** | M12 | Real-time LiveView viewer, governance/audit, health circuit breaker, eval task |

---

## 4. M7 — Search & Intelligence

### M7.1 Knowledge Graph

**Enabled automatically** when `memory.llm_model` is configured. No separate feature flag.

| ID | Requirement | Acceptance |
|----|-------------|------------|
| FR-M7-1 | Schema: `memory_graph_nodes(id uuid PK, type text, name text, properties jsonb, source_observation_ids uuid[], created_at)` and `memory_graph_edges(id uuid PK, source_id uuid, target_id uuid, relation text, weight float, created_at)` | Migration creates tables; GIN index on `properties` |
| FR-M7-2 | `Backplane.Memory.Workers.GraphExtractWorker` Oban job runs after session end; sends compressed observations to LLM proxy with extraction prompt; parses XML response into nodes + edges | Observation "JWT auth in src/middleware/auth.ts uses jose" creates `File` node + `Library` node + `uses` edge |
| FR-M7-3 | Job skipped when session has fewer than `memory.graph_min_observations` observations (default: 3) | No LLM call for sessions with < 3 observations |
| FR-M7-4 | `memory_graph_query(entity, depth, relation_filter?)` BFS traversal returns connected subgraph up to `depth` hops | Returns expected nodes and paths |
| FR-M7-5 | Graph results fused into hybrid recall as a third RRF stream when knowledge graph has data | Graph stream present alongside FTS + vector in recall |
| FR-M7-6 | Node dedup before insert: fuzzy-match by name+type (Levenshtein ≤ 2); merge rather than duplicate | No duplicate `File` nodes for same path |
| FR-M7-7 | `GET /api/memory/graph/stats` — node count by type, edge count by relation | Response matches schema |

**Entity types:** `File`, `Function`, `Module`, `Library`, `Concept`, `Decision`, `Bug`, `Pattern`, `Person`

**Relation types:** `uses`, `imports`, `calls`, `depends_on`, `tests`, `documents`, `caused_by`, `supersedes`, `relates_to`

---

### M7.2 Project Profile

| ID | Requirement | Acceptance |
|----|-------------|------------|
| FR-M7-8 | Schema: `memory_profiles(project text PK, top_concepts jsonb, top_files jsonb, patterns jsonb, session_count int, total_observations int, updated_at)` | Table exists |
| FR-M7-9 | `Backplane.Memory.Workers.ProfileBuildWorker` Oban job aggregates concept/file frequency from last 20 sessions; cache TTL 1 hour | Profile reflects recent session activity |
| FR-M7-10 | `GET /api/memory/profile?project=<path>` — returns cached profile or triggers rebuild | 200 with profile JSON |
| FR-M7-11 | Profile included in `session/start` response when context injection is enabled | Context block in SessionStart response |
| FR-M7-12 | `memory_profile` and `memory_profile_refresh` MCP tools | Tools work |

---

### M7.3 Query Expansion

**Configurable:** enabled/disabled via `memory.query_expansion_enabled` setting in memory config UI. Off by default.

| ID | Requirement | Acceptance |
|----|-------------|------------|
| FR-M7-13 | When enabled, `recall` sends the query to the LLM proxy before hybrid search; generates 3–5 alternative phrasings | Expanded queries visible in debug log |
| FR-M7-14 | Expanded queries run through FTS + vector separately; results union-deduplicated by memory ID before RRF | No duplicate memories in results |
| FR-M7-15 | Query expansion only fires when `memory.llm_model` is configured; silently skips if no LLM | No error when LLM absent |
| FR-M7-16 | `memory_expand_query` MCP tool: manual expansion for a given query string | Tool works |

---

### M7.4 Cross-encoder Reranker

| ID | Requirement | Acceptance |
|----|-------------|------------|
| FR-M7-17 | After hybrid retrieval, top-K candidates (default K=20) sent to LLM proxy for relevance scoring; top-N returned | Reranker reorders results |
| FR-M7-18 | Reranker gated by `memory.reranker_enabled` setting; off by default | Toggle in memory config |
| FR-M7-19 | Only fires when `memory.llm_model` is configured; silently skips otherwise | No error when LLM absent |

---

## 5. M8 — Hook Suite & Capture

### M8.1 Hook Set (10 hooks)

`PreToolUse` and `Notification` are excluded. Rationale: `PreToolUse` stdout is debug-only in Claude Code (not injected into conversation); `Notification` is too rare to justify the capture overhead.

| Hook | Fires when | Action |
|------|-----------|--------|
| `SessionStart` | Session opens | Register session; optionally write project context to stdout |
| `UserPromptSubmit` | User submits prompt | Privacy-filter and store as observation |
| `PostToolUse` | Tool call succeeds | Store tool name + filtered input + output as observation; dedup |
| `PostToolUseFailure` | Tool call fails | Store error context as observation with `is_error=true` |
| `PreCompact` | Before context compaction | Re-inject top memories into conversation |
| `SubagentStart` | Sub-agent spawned | Record sub-agent lifecycle event linked to parent session |
| `SubagentStop` | Sub-agent exits | Record sub-agent stop |
| `Stop` | Session ends cleanly | Trigger summarisation + slot reflection + graph extraction job |
| `SessionEnd` | Session complete | Mark session closed; enqueue consolidation |
| `PostCommit` | Git commit made | Record commit SHA + message; extract touched files as observation |

**Functional requirements:**

| ID | Requirement | Acceptance |
|----|-------------|------------|
| FR-M8-1 | All 10 hook scripts compiled and installed by host-agent plugin | Hooks fire and reach local broker in tests |
| FR-M8-2 | `SessionStart` respects `memory.inject_context` setting; when on, writes context block to stdout within 1500 ms timeout | Claude Code prepends context to first turn |
| FR-M8-3 | All hooks apply privacy filter before forwarding; observations containing only stripped content are silently dropped | No API keys in stored observations |
| FR-M8-4 | Hook timeouts: `SessionStart` inject path 1500 ms; register path 800 ms; all others 2000 ms; errors swallowed | Hooks never block Claude Code startup |
| FR-M8-5 | `AGENTMEMORY_SDK_CHILD=1` guard on every hook script prevents recursion when Claude Code spawns SDK sub-agents | No observation loop |
| FR-M8-6 | `mix memory.connect claude-code` merges hook entries into `~/.claude/settings.json` idempotently | Settings updated correctly; re-run after upgrade refreshes paths |

---

### M8.2 Context Injection

| ID | Requirement | Acceptance |
|----|-------------|------------|
| FR-M8-7 | `POST /api/memory/session/start` — registers session; returns `{context?: string, session_id: string}` | Response contains context when project has memory and injection is enabled |
| FR-M8-8 | Context block: project profile (top concepts/files/patterns) + top-5 hybrid recall results + top-2 procedural memories; total ≤ token budget (default 2000 tokens) | Context within budget |
| FR-M8-9 | `memory.inject_context` setting; off by default | Toggle in memory config UI |

---

### M8.3 File History

| ID | Requirement | Acceptance |
|----|-------------|------------|
| FR-M8-10 | Every observation stores `files jsonb` — array of file paths extracted from tool input/output during privacy-filter pass | Files extracted at capture time |
| FR-M8-11 | `GET /api/memory/file-history?files=<comma-list>&exclude_session=<id>` — returns observations referencing any listed file, newest first | Returns correct observations |
| FR-M8-12 | `memory_file_history` MCP tool | Tool works |

---

## 6. M9 — Advanced Memory Features

### M9.1 Confidence Scoring

Already present in schema (`confidence float DEFAULT 1.0` on `bpm_memories`). This milestone wires it into the pipeline.

| ID | Requirement | Acceptance |
|----|-------------|------------|
| FR-M9-1 | LLM consolidation sets confidence based on corroborating observation count and source diversity | Single-source memories get lower confidence than multi-session ones |
| FR-M9-2 | Recall response includes `confidence` field; `min_confidence` filter parameter supported | Filter works |
| FR-M9-3 | Contradiction detection lowers confidence on both conflicting memories before supersession | Audit log records confidence change |

---

### M9.2 Access Reinforcement

Already present in schema (`access_count`, `accessed_at` on `bpm_memories`). This milestone wires the reinforcement loop.

| ID | Requirement | Acceptance |
|----|-------------|------------|
| FR-M9-4 | Every recall hit increments `access_count` and updates `accessed_at` via batched Oban write-back (non-blocking) | Access log populated after recall |
| FR-M9-5 | Decay formula applied during nightly eviction sweep: `strength × 0.9^(floor(days_since_access / decay_period))`; configurable `memory.decay_period_days` (default 30) | Strength decreases for unaccessed memories |
| FR-M9-6 | Recall score = `rrf_score × strength × confidence × (1 + log(1 + access_count) × 0.1)` | Frequently accessed memories rank higher |
| FR-M9-7 | Eviction threshold: memories with `strength × confidence < memory.eviction_threshold` (default 0.1) are soft-deleted during nightly sweep | Weak memories evicted |
| FR-M9-8 | No hard row budget in v1; `memory.max_memories_per_scope` setting available but unset by default | Setting present; eviction only by threshold when unset |

---

### M9.3 Facets (Strict Dimension:Value Tags)

| ID | Requirement | Acceptance |
|----|-------------|------------|
| FR-M9-9 | Schema: `memory_facet_dimensions(name text PK, description text, allowed_values jsonb, created_at)` for dimension validation | Table exists; seeded with default dimensions |
| FR-M9-10 | Schema: `memory_facets(id uuid PK, memory_id uuid FK, dimension text FK, value text, created_at)`; GIN index on (dimension, value) | Table and index exist |
| FR-M9-11 | `remember` accepts `facets: [{dimension, value}]`; dimension validated against `memory_facet_dimensions`; unknown dimensions rejected with 422 | Invalid dimension returns error |
| FR-M9-12 | `recall` accepts `facets` filter: `[{dimension, value}]`; ANDs across dimensions (memory must match ALL specified facets) | Filtered results match all facets |
| FR-M9-13 | Default dimensions seeded: `language`, `framework`, `project`, `environment`, `team`, `type` | 6 dimensions seeded on first migration |
| FR-M9-14 | `memory_facet_tag` MCP tool: tag an existing memory with facets | Tool works |
| FR-M9-15 | `memory_facet_query` MCP tool: query memories by facet filter | Tool works |
| FR-M9-16 | Admin Config section lets operator add/remove facet dimensions | UI functional |

---

## 7. M10 — Multi-agent Coordination

Scope: **team memory + leases + signals + actions/frontier/next only.** Routines, checkpoints, sentinels, sketches, and crystallize are out of scope.

### M10.1 Team Memory

| ID | Requirement | Acceptance |
|----|-------------|------------|
| FR-M10-1 | `bpm_memories` adds `namespace text DEFAULT 'private'`; values: `private`, `shared`, `team:<team_id>` | Column added via migration |
| FR-M10-2 | `recall` default: own private + shared memories; `namespace=team:<id>` adds team-scoped | Namespace filtering correct |
| FR-M10-3 | `memory_team_share(memory_id, team_id)` sets namespace to `team:<id>` | Memory visible to team members |
| FR-M10-4 | `memory_team_feed(team_id, limit?)` returns recent shared memories in that team | Feed returns correct entries |
| FR-M10-5 | `memory.team_id` and `memory.user_id` settings drive default namespace behaviour | Settings respected |

---

### M10.2 Leases (Exclusive Action Locks)

| ID | Requirement | Acceptance |
|----|-------------|------------|
| FR-M10-6 | Schema: `memory_leases(id uuid PK, action_id uuid, holder_agent_id text, acquired_at, expires_at, renewed_at)` | Table exists |
| FR-M10-7 | `memory_lease(action_id, agent_id, ttl_seconds?)` — inserts row if action unclaimed; returns `{ok: true, lease_id}` or `{ok: false, held_by}` | Exclusive grant semantics; concurrent test passes |
| FR-M10-8 | Expired leases auto-released by Oban cron job every 30 seconds | Expired leases gone after TTL |
| FR-M10-9 | `memory_lease` MCP tool | Tool works |

---

### M10.3 Signals (Inter-agent Messaging)

| ID | Requirement | Acceptance |
|----|-------------|------------|
| FR-M10-10 | Schema: `memory_signals(id uuid PK, sender_agent_id text, recipient_agent_id text, topic text, payload jsonb, sent_at, read_at)` | Table exists |
| FR-M10-11 | `memory_signal_send(recipient_agent_id, topic, payload)` inserts row | Row inserted |
| FR-M10-12 | `memory_signal_read(agent_id, topic?, limit?)` returns unread signals; marks them read atomically in a single transaction | Read-receipt set atomically |
| FR-M10-13 | `memory_signal_send` and `memory_signal_read` MCP tools | Tools work |

---

### M10.4 Actions, Frontier & Next

| ID | Requirement | Acceptance |
|----|-------------|------------|
| FR-M10-14 | Schema: `memory_actions(id uuid PK, title text, description text, status text, priority int, created_by text, project text, tags text[], source_observation_ids uuid[], source_memory_ids uuid[], parent_id uuid, created_at, updated_at)` | Table exists |
| FR-M10-15 | Schema: `memory_action_edges(id uuid PK, source_id uuid FK, target_id uuid FK, edge_type text)`; edge types: `requires`, `unlocks`, `spawned_by`, `gated_by`, `conflicts_with` | Table exists |
| FR-M10-16 | `memory_action_create(title, description?, priority?, edges?, project?)` — creates action with dependency edges | Action created with correct edges |
| FR-M10-17 | `memory_action_update(action_id, status?, priority?)` — status values: `pending`, `in_progress`, `done`, `blocked`, `cancelled` | Status updated |
| FR-M10-18 | `memory_frontier(project?)` — returns actions with no pending `requires` prerequisites, sorted by priority desc | Correct unblocked set returned |
| FR-M10-19 | `memory_next(project?)` — returns single highest-priority unblocked action | Returns correct action |
| FR-M10-20 | `memory_action_create`, `memory_action_update`, `memory_frontier`, `memory_next` MCP tools | Tools work |

---

## 8. M11 — Full MCP Surface

### M11.1 Tool Listing

Given scope decisions, the tool surface is ~37 tools split into core (always available) and extended (`memory.tools=all`).

**Core tools (15 — always available):**

| Tool | REST endpoint |
|------|--------------|
| `memory_recall` | `GET /api/memory/recall` |
| `memory_save` | `POST /api/memory/remember` |
| `memory_smart_search` | `POST /api/memory/smart-search` |
| `memory_sessions` | `GET /api/memory/sessions` |
| `memory_file_history` | `GET /api/memory/file-history` |
| `memory_patterns` | `GET /api/memory/patterns` |
| `memory_timeline` | `GET /api/memory/timeline` |
| `memory_profile` | `GET /api/memory/profile` |
| `memory_export` | `GET /api/memory/export` |
| `memory_relations` | `GET /api/memory/graph/relations` |
| `memory_compress_file` | `POST /api/memory/compress-file` |
| `memory_audit` | `GET /api/memory/audit` |
| `memory_governance_delete` | `DELETE /api/memory/governance/delete` |
| `memory_diagnose` | `GET /api/memory/diagnose` |
| `memory_heal` | `POST /api/memory/heal` |

**Extended tools (22 — require `memory.tools=all`):**

| Tool | REST endpoint |
|------|--------------|
| `memory_graph_query` | `POST /api/memory/graph/query` |
| `memory_graph_stats` | `GET /api/memory/graph/stats` |
| `memory_consolidate` | `POST /api/memory/consolidate` |
| `memory_team_share` | `POST /api/memory/team/share` |
| `memory_team_feed` | `GET /api/memory/team/feed` |
| `memory_action_create` | `POST /api/memory/actions` |
| `memory_action_update` | `PATCH /api/memory/actions/:id` |
| `memory_frontier` | `GET /api/memory/actions/frontier` |
| `memory_next` | `GET /api/memory/actions/next` |
| `memory_lease` | `POST /api/memory/leases` |
| `memory_signal_send` | `POST /api/memory/signals` |
| `memory_signal_read` | `GET /api/memory/signals` |
| `memory_facet_tag` | `POST /api/memory/facets` |
| `memory_facet_query` | `GET /api/memory/facets/query` |
| `memory_verify` | `GET /api/memory/:id/verify` |
| `memory_slot_read` | `GET /api/memory/slots/:name` |
| `memory_slot_write` | `PUT /api/memory/slots/:name` |
| `memory_slot_list` | `GET /api/memory/slots` |
| `memory_enrich` | `POST /api/memory/enrich` |
| `memory_profile_refresh` | `POST /api/memory/profile/refresh` |
| `memory_expand_query` | `POST /api/memory/query/expand` |
| `memory_access_log` | `GET /api/memory/:id/access-log` |

---

### M11.2 MCP Resources (6)

| Resource URI | Description |
|-------------|-------------|
| `memory://status` | Health, session count, memory count |
| `memory://project/{name}/profile` | Per-project intelligence profile |
| `memory://memories/latest` | Latest 10 active memories |
| `memory://graph/stats` | Knowledge graph node/edge counts |
| `memory://sessions/active` | Currently active sessions |
| `memory://audit/recent` | Last 50 audit log entries |

---

### M11.3 MCP Prompts (3)

| Prompt | Behaviour |
|--------|-----------|
| `recall_context` | Runs smart search; returns formatted context messages |
| `session_handoff` | Builds handoff summary for current session |
| `detect_patterns` | Analyses recent observations for recurring patterns |

---

### M11.4 Claude Code Skills (4) — via Skill Hub

Skills are packaged as a Backplane skill bundle and published through the Backplane skill hub, not hardcoded into the plugin.

| Skill | Action |
|-------|--------|
| `/recall <query>` | Runs `memory_smart_search`; prints top-5 results |
| `/remember <content>` | Calls `memory_save` with `--type` flag and type inference |
| `/session-history` | Lists last 10 sessions with ID, start time, project, observation count, one-line summary |
| `/forget <query or id>` | Calls `memory_governance_delete`; shows confirmation prompt; writes audit entry |

---

### M11.5 Memory Slots

| ID | Requirement | Acceptance |
|----|-------------|------------|
| FR-M11-1 | Schema: `memory_slots(name text PK, content text, updated_at, updated_by, size_limit_chars int DEFAULT 2000)` | Table exists |
| FR-M11-2 | 8 default slots seeded: `persona`, `user_preferences`, `tool_guidelines`, `project_context`, `guidance`, `pending_items`, `session_patterns`, `self_notes` | 8 rows on first boot |
| FR-M11-3 | `memory.slots_enabled` setting; off by default | Toggle in memory config |
| FR-M11-4 | Slot content included in SessionStart context block when injection and slots are both enabled | Slot content in context |
| FR-M11-5 | `memory.reflect_enabled` enables Stop-hook slot reflection: scans recent observations; appends ≤ 5 evidenced TODOs to `pending_items`; updates `session_patterns` and `project_context`; prompt is strictly grounded — items without an explicit observation citation are dropped | Slots updated after session; no hallucinated TODOs |

---

## 9. M12 — Observability & Tooling

### M12.1 Admin UI — Left-Side Menu

The memory module uses a left-side menu (matching the existing admin navigation pattern), not tabs.

| Section | Route | Content |
|---------|-------|---------|
| **Overview** | `/admin/memory` | Stats: session count, memory count, embedding queue depth, consolidation lag, decay sweep status, circuit breaker state |
| **Memories** | `/admin/memory/browse` | Already implemented — filter/expand/forget with pagination |
| **Observations** | `/admin/memory/observations` | Live stream via `Backplane.PubSub`; tool name, session, truncated content, timestamp |
| **Sessions** | `/admin/memory/sessions` | Session list: summary, observation count, start/end time, consolidation status |
| **Graph** | `/admin/memory/graph` | Entity graph visualisation; entity search; click node to see connected edges |
| **Actions** | `/admin/memory/actions` | Action list with status badges; frontier view; active leases |
| **Audit** | `/admin/memory/audit` | Governance delete log; paginated; filterable by operation/actor/date |
| **Config** | `/admin/memory/config` | All `memory.*` settings: LLM model, injection toggle, decay params, graph threshold, query expansion, reranker, slots, reflect, tools visibility, team config |

---

### M12.2 Governance & Audit Trail

| ID | Requirement | Acceptance |
|----|-------------|------------|
| FR-M12-1 | Schema: `memory_audit_log(id uuid PK, operation text, actor text, target_ids jsonb, metadata jsonb, created_at)` | Table exists |
| FR-M12-2 | All delete operations write an audit entry; hard delete blocked unless `memory.hard_delete_enabled=true` | Audit entry present after every delete |
| FR-M12-3 | `memory_governance_delete` MCP tool: `memory_id` or `{scope, query}`; soft-deletes; writes audit entry | Audit entry written; memory soft-deleted |
| FR-M12-4 | `GET /api/memory/audit` — paginated; filterable by operation, actor, date range | Endpoint works |
| FR-M12-5 | `memory_audit` MCP tool | Tool works |

---

### M12.3 Health Monitoring & Circuit Breaker

| ID | Requirement | Acceptance |
|----|-------------|------------|
| FR-M12-6 | Circuit breaker (ETS-backed) wraps embedding provider calls: opens after 5 consecutive failures; half-opens after 30 s; closes after 2 successes | State machine transitions correctly |
| FR-M12-7 | Fallback chain: primary embedding provider → BM25-only (no vector); each step logged | Chain followed on provider failure; no error returned to caller |
| FR-M12-8 | `GET /api/memory/diagnose` — returns: circuit breaker state, embedding queue depth, consolidation backlog, recall p95, storage size, active sessions | All fields present |
| FR-M12-9 | `POST /api/memory/heal` — clears orphaned leases, resets half-open circuit breaker, flushes stale consolidation locks | Stuck state resolved |
| FR-M12-10 | `memory_diagnose` and `memory_heal` MCP tools | Tools work |

---

### M12.4 Consolidation Pipeline

| ID | Requirement | Acceptance |
|----|-------------|------------|
| FR-M12-11 | **working → episodic** (synthetic): fires on `SessionEnd` hook always, no LLM required; compresses raw observations into a session summary using extractive summarisation | Summary row created in `memory_summaries` for every closed session |
| FR-M12-12 | **episodic → semantic** (LLM): async Oban job enqueued after `SessionEnd`; only runs when `memory.llm_model` configured; extracts durable facts and patterns from session summary | Semantic memories created from session summaries when LLM available |
| FR-M12-13 | **semantic → procedural** (LLM): nightly Oban cron; only runs when LLM configured and ≥ 10 semantic memories exist for the scope; extracts reusable workflows | Procedural memories created from repeated semantic patterns |
| FR-M12-14 | **Fallback sweep**: Oban cron every 4 hours; picks up sessions that closed without triggering `SessionEnd` (crash, disconnect) | Orphaned sessions consolidated within 4 hours |
| FR-M12-15 | All LLM-dependent consolidation steps degrade gracefully when LLM absent: log a skip, do not error | No consolidation errors when LLM unconfigured |

---

### M12.5 Eval Task

| ID | Requirement | Acceptance |
|----|-------------|------------|
| FR-M12-16 | `mix memory.eval` task runs recall quality tests against a fixture corpus in `priv/memory_fixtures/` | Task exits 0; prints precision@5, recall@5, MRR to terminal |
| FR-M12-17 | Fixture: 15-session coding-agent corpus covering auth, database, and rate-limiting topics, loadable via `mix memory.seed_bench` | Fixture seeds without error |
| FR-M12-18 | No benchmark DB table or admin UI in this scope — terminal output only | No migration needed |

---

## 10. Architecture Notes

### Process model

- **No process per memory** — memories are data in Postgres. No GenServer per row.
- **Oban for all async work** — embed, consolidate, evict, graph extract, profile build, lease cleanup, access write-back. Queue isolation per concern.
- **PubSub for live viewer** — capture path broadcasts `{:memory_event, observation}` on `Backplane.PubSub`; LiveView subscribes. No polling.
- **ETS for hot state** — circuit breaker state. Not per-entity.
- **Behaviours for providers** — `BackplaneMemory.Embedding.Provider` behaviour; implementations: `VLLMProvider`, `NoopProvider`. Swap via config at boot.
- **Single Postgres** — no mesh, no federation. One DB, cluster-safe through Postgres advisory locks for consolidation.

### Module layout (existing + additions)

```
apps/backplane_memory/
├── lib/backplane_memory/
│   ├── application.ex
│   ├── memories/
│   │   ├── memory.ex              # existing schema
│   │   └── search.ex              # existing FTS search
│   ├── observations/
│   │   ├── observation.ex
│   │   └── session.ex
│   ├── graph/
│   │   ├── node.ex
│   │   ├── edge.ex
│   │   └── bfs.ex
│   ├── coordination/
│   │   ├── action.ex
│   │   ├── lease.ex
│   │   └── signal.ex
│   ├── facets/
│   │   ├── dimension.ex
│   │   └── facet.ex
│   ├── slots/
│   │   └── slot.ex
│   ├── embedding/
│   │   └── client.ex              # existing
│   ├── workers/
│   │   ├── embed_worker.ex        # existing
│   │   ├── consolidation_worker.ex
│   │   ├── eviction_worker.ex
│   │   ├── graph_extract_worker.ex
│   │   ├── profile_build_worker.ex
│   │   ├── lease_cleanup_worker.ex
│   │   └── access_writeback_worker.ex
│   ├── mcp/
│   │   ├── server.ex
│   │   └── tools/
│   ├── hooks/                     # compiled hook scripts (10)
│   ├── privacy/
│   │   └── filter.ex              # existing
│   ├── circuit_breaker.ex
│   ├── service.ex                 # existing
│   └── telemetry.ex
```

### Memory config settings (all in `memory.*` namespace)

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| `memory.llm_model` | string | nil | Auto-model alias or `provider/model`; enables all LLM features when set |
| `memory.inject_context` | bool | false | Write project context to stdout on SessionStart |
| `memory.query_expansion_enabled` | bool | false | LLM query expansion before hybrid search |
| `memory.reranker_enabled` | bool | false | Cross-encoder reranking of top-K candidates |
| `memory.graph_min_observations` | int | 3 | Minimum observations for graph extraction to run |
| `memory.decay_period_days` | int | 30 | Days of no access before strength decay begins |
| `memory.eviction_threshold` | float | 0.1 | `strength × confidence` below which memory is soft-deleted |
| `memory.max_memories_per_scope` | int | nil | Hard row budget per scope (unset = no cap) |
| `memory.slots_enabled` | bool | false | Enable named memory slots |
| `memory.reflect_enabled` | bool | false | Enable Stop-hook slot reflection (requires slots) |
| `memory.tools` | string | "core" | `"core"` (15 tools) or `"all"` (37 tools) |
| `memory.team_id` | string | nil | Default team ID for shared memories |
| `memory.user_id` | string | nil | User identity for attribution |
| `memory.hard_delete_enabled` | bool | false | Allow permanent (hard) deletes |

---

## 11. Milestone Summary

| Milestone | Content | Prerequisite |
|-----------|---------|-------------|
| **M1–M6** | v1 foundation (see `memory-prd.md`) | — |
| **M7** | Knowledge graph, project profile, query expansion, reranker | M1–M6 |
| **M8** | 10-hook suite, context injection, file history | M1–M6 |
| **M9** | Confidence wiring, access reinforcement loop, facets | M7, M8 |
| **M10** | Team memory, leases, signals, actions/frontier/next | M9 |
| **M11** | Full MCP tool surface (~37), resources, prompts, skills, slots | M8, M9 |
| **M12** | Left-side admin UI, governance/audit, circuit breaker, eval task, consolidation pipeline | M10, M11 |

---

## 12. Success Metrics

| Metric | Target |
|--------|--------|
| Retrieval recall@5 | ≥ 90% on `mix memory.eval` fixture |
| Hook latency | < 2 ms blocking per hook |
| MCP tool count | 37 tools (15 core + 22 extended) |
| Audit completeness | 100% of deletes produce an audit entry |
| Embedding fallback | Recall degrades to FTS-only — never errors — when embedder is down |
| Consolidation coverage | ≥ 95% of closed sessions have a summary within 4 hours |

---

## 13. Deferred / Future Milestones

| Feature | Reason deferred |
|---------|----------------|
| Session replay (JSONL import + scrubber) | Self-contained; add when observation pipeline is stable |
| Memory snapshots for review | Not rollback; a future read-only timeline milestone |
| Git snapshots | Database-level backup is sufficient for rollback |
| Benchmarking UI | Needs real corpus; `mix memory.eval` covers v1 quality needs |
| Routines, checkpoints, sentinels, sketches, crystallize | Speculative value; add when concrete use case emerges |
| Vision / image support | Text-dominant pipeline; model choice unresolved |
| Obsidian export | Generic JSON export covers the use case |
| MEMORY.md bridge | Backplane memory supersedes Claude Code's built-in file memory |
| Temporal graph | Non-breaking migration when time-aware queries become needed |
| Query expansion on by default | Latency cost; operator opts in when recall quality needs it |
