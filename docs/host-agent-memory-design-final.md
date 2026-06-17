# Host-Agent On-Device Memory + Backplane Sync — Design

**Status:** Accepted, implementation-ready after PR0 verification on 2026-06-17.
**Repo path:** `docs/host-agent-memory-design-final.md`
**Engine:** `gsmlg-dev/ex_turso` 0.1.1, a Rustler NIF over the `turso` crate with a `DBConnection` pool. No Ecto in `apps/backplane_host_agent`.
**PR0 baseline:** FTS5 is unavailable in the bundled Turso engine (`no such module: fts5`), so v1 local recall uses `LIKE` and tags local keyword results as degraded. Upstream request: `gsmlg-dev/ex_turso#2`.

---

## 1. Scope

Backplane Host Agent gains a local, on-device memory service. It stores memories in an embedded Turso database, exposes the same memory MCP surface whether online or offline, and uses the existing host-agent Phoenix channel only for synchronization with Backplane.

The host agent is not a memory intelligence engine. It persists local observations, performs keyword recall, manages sync state, and applies hub facts/wipes. Backplane remains the manager of shared memory: embedding, consolidation, semantic search, governance, entitlement, review, and cross-host policy.

```
local caller
  │
  ▼
HostAgent.MemoryRouter ──► HostAgent.Memory ──► ExTurso DB
                              │                    ├─ memories
                              │                    ├─ facts
                              │                    ├─ memory_outbox
                              │                    ├─ tombstones
                              │                    └─ slots
                              │
                              ▼
                       HostAgent.Memory.Syncer
                              │ existing host-agent channel, sync events only
                              ▼
                 BackplaneWeb.HostAgentChannel ──► BackplaneMemory
```

## 2. Non-Goals

- No local embeddings or vector index in v1.
- No LLM calls from the host agent.
- No host-side consolidation, summarization, procedural extraction, contradiction detection, or fact creation.
- No team/share tools at the host layer.
- No slot sync.
- No general hub-to-host memory replication; only curated facts and wipe directives flow down.
- No dependency from `apps/backplane_host_agent` to `:backplane`, `:backplane_web`, or `:backplane_memory`.
- No Ecto schemas, migrations, or repos in `apps/backplane_host_agent`.
- No encryption-at-rest in v1; this is explicitly out of scope and must be revisited before storing high-sensitivity data on shared machines.

## 3. Decision Ledger

| # | Decision |
|---|---|
| D1 | Store is host-level. `scope` is the partition key. `agent_id` is provenance only. Dedup is `(content_hash, scope)` while `deleted_at IS NULL`. |
| D2 | No team/share tools at host level. Sharing is sync-up plus Backplane memory management. |
| D3 | Sync up supports outbox ops `remember` and `forget` only. FIFO by `seq`, at-least-once. Hub idempotency uses local `id` and `(content_hash, scope)`. Ack returns `canonical_id`, stored locally as `remote_id`. Local UUIDv7 remains canonical on the originating host. |
| D4 | Sync down is narrow: hub-curated facts plus wipe directives. There is no general replication. |
| D5 | Host engine is `ex_turso`; SQL is raw; migrations use `PRAGMA user_version`; row mapping belongs in functional core modules. |
| D6 | Recall baseline is `LIKE` with `quality: :degraded`. FTS5 remains preferred when `ex_turso` exposes it. Vector recall is deferred until `ex_turso` exposes Turso native vector. |
| D7 | Local memories expire after `memory.local_ttl_days` (default 90), but only after they are synced. Facts never prune locally. |
| D8 | `forget` and `wipe` are different. `forget` soft-deletes locally and syncs an originating-host op. `wipe` hard-deletes locally, records a tombstone by `content_hash`, and blocks exact re-remember by default. |
| D9 | Downstream targeting is scope subscription. The host announces active scopes on join. The hub pushes facts for `entitled ∩ announced`. Join performs reconcile, then incremental updates. |
| D10 | Host MCP surface is local-only: `remember`, `recall`, `list`, `forget`, `stats`, `slot_read`, `slot_write`, `slot_list`, `facet_tag`, `facet_query`. Hub-only tools must return a stable local error. |
| D11 | Slots are device-only. Facets/tags live in memory payload JSON. Sessions are metadata only. |
| D12 | Hub facts live in a separate local `facts` table. `recall/2` unions `memories` and `facts`, then reducer rank-merges hits with `source: :local | :hub_fact`. |
| D13 | The host computes and stores no embeddings. Backplane embeds synced memories on ingest. |
| D14 | Write scope is resolved from the host agent's bound project scope, not caller input. Standalone agents use `proj_local`. A write with a caller-supplied scope that differs from the resolved scope is rejected. Read filters may only reference locally known scopes. |
| D15 | Fact entitlement is hub-side. Scope announcements narrow access; they never grant access. |
| D16 | Outbox carries no payload snapshot. It stores `(seq, op, memory_id)`. Syncer builds payloads from current rows at drain time. |
| D17 | `forget` is local plus originating-host-up only; it is not laterally propagated. Cross-host removal is the wipe channel. |
| D18 | Provenance is source/debug-grade. Under dedup, `agent_id` is first writer. A provenance set is deferred. |
| D19 | All local `memories` rows are raw episodic observations. The host assigns no semantic/procedural tier; pushed `facts` are the only on-device semantic knowledge. Pruning is age-only. |
| D20 | Join handshake includes `scope -> fact_set_hash`. Hub reconciles only scopes whose hash differs. |
| D21 | Wipe blocks byte-exact content only, keyed by `content_hash`. Semantic-equivalent re-learning is not blocked in v1. Tombstones persist until operator purge. |

## 4. Relationship to Current Code

Current host-agent memory endpoints route through `Backplane.HostAgent.MemoryProxy`, which forwards `memory_call` events to `BackplaneWeb.HostAgentChannel`. That path is connectivity-dependent and only exposes `remember`, `recall`, `list`, `forget`, and `stats`.

This design replaces that for memory tools:

- `Backplane.HostAgent.MemoryRouter` calls `Backplane.HostAgent.Memory` directly.
- `Backplane.HostAgent.MemoryProxy` is removed from the memory tool path. It can be deleted after compatibility tests are migrated.
- `Backplane.HostAgent.Channel` remains the low-level socket wrapper.
- New `Backplane.HostAgent.Memory.Syncer` owns memory sync pushes over the channel.
- `BackplaneWeb.HostAgentChannel` keeps existing skill-sync events and adds `memory_sync`, `memory_facts`, and `memory_wipe`.
- Hub managed MCP tools remain in `BackplaneMemory.Service`; host sync should use a hub-side adapter module instead of round-tripping through the MCP service surface.

## 5. Runtime Configuration

The host agent continues to load YAML through `Backplane.HostAgent.Config`. Add an optional `memory` section:

```yaml
agent:
  host_id: host_01
  machine_name: workstation
  hub_url: http://localhost:4220
  token: REPLACE_WITH_AUTH_TOKEN
  work_dir: /home/me/.local/share/backplane/host_agent
  http_bind: 127.0.0.1
  http_port: 4221

memory:
  enabled: true
  db_path: /home/me/.local/share/backplane/host_agent/memory/host_agent_memory.db
  bound_scope: proj_local
  local_ttl_days: 90
  sync_interval_ms: 5000
  sync_batch_size: 50
  max_attempts: 5
  tombstone_relearn: block
```

Defaults:

- `enabled`: true when `http_port` is positive.
- `db_path`: `Path.join(config.work_dir, "memory/host_agent_memory.db")`.
- `bound_scope`: `proj_local` until host registration/project binding supplies a project id.
- `local_ttl_days`: 90.
- `sync_interval_ms`: 5000.
- `sync_batch_size`: 50.
- `max_attempts`: 5.
- `tombstone_relearn`: `block`; future value `allow_with_log` is reserved.

## 6. Local Supervision

When memory is enabled, host-agent supervision adds:

```text
Backplane.HostAgent.Application
├─ Backplane.HostAgent.McpManager
├─ Backplane.HostAgent.Worker
├─ Backplane.HostAgent.Memory.Store          # ExTurso DBConnection pool
├─ Backplane.HostAgent.Memory.Migrator       # runs before router accepts traffic
├─ Backplane.HostAgent.Memory.Syncer         # outbox up, facts/wipes down hooks
├─ Backplane.HostAgent.Memory.Pruner         # periodic retention
└─ Backplane.HostAgent.HttpServer            # existing Bandit server
```

Startup rules:

1. Start the ExTurso pool with WAL and `busy_timeout`.
2. Run migrations synchronously before HTTP starts.
3. Start Syncer even if disconnected; it remains idle until a channel exists.
4. HTTP routes must work without a channel.
5. If migrations fail, fail the memory children and surface the failure in agent diagnostics rather than silently forwarding to the hub.

## 7. Local Module Boundaries

| Module | Responsibility |
|---|---|
| `Backplane.HostAgent.Memory` | Public local API used by router and tests. Owns transactions, calls pure reducer functions, and returns stable result maps. |
| `Backplane.HostAgent.Memory.Store` | Thin wrapper over `ExTurso.execute/3`, `ExTurso.query/3`, and `DBConnection.transaction/3`. No domain logic. |
| `Backplane.HostAgent.Memory.Migrator` | `PRAGMA user_version` migrations, idempotent boot apply, and schema version checks. |
| `Backplane.HostAgent.Memory.Migrations.V*` | Numbered SQL strings only. |
| `Backplane.HostAgent.Memory.Reducer` | Pure functions: validation, scope resolution, hash, LIKE query construction, tag/facet normalization, rank merge. No Store calls. |
| `Backplane.HostAgent.Memory.UUID7` | Local UUIDv7 generation. |
| `Backplane.HostAgent.Memory.Facts` | Apply hub fact reconcile and wipe directives. |
| `Backplane.HostAgent.Memory.Syncer` | Outbox drain, channel push, ack handling, scope announcements, fact-set hashes. |
| `Backplane.HostAgent.Memory.Pruner` | Age-only retention for synced local memories. Never touches facts. |
| `Backplane.HostAgent.Memory.Diagnostics` | Read-only sync/store status used by HTTP diagnostics and mix tasks. |

## 8. Local SQL Schema

Use raw SQL migrations. Store timestamps as UTC ISO-8601 text for portable JSON and deterministic hashing.

```sql
CREATE TABLE memories (
  id TEXT PRIMARY KEY,
  content TEXT NOT NULL,
  content_hash TEXT NOT NULL,
  memory_type TEXT NOT NULL DEFAULT 'episodic'
    CHECK (memory_type = 'episodic'),
  scope TEXT NOT NULL,
  agent_id TEXT NOT NULL,
  session_id TEXT,
  tags TEXT NOT NULL DEFAULT '[]',
  metadata TEXT NOT NULL DEFAULT '{}',
  confidence REAL NOT NULL DEFAULT 1.0,
  sync_state TEXT NOT NULL DEFAULT 'pending'
    CHECK (sync_state IN ('pending', 'synced', 'failed')),
  remote_id TEXT,
  synced_at TEXT,
  deleted_at TEXT,
  inserted_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE UNIQUE INDEX memories_content_scope_live_uniq
  ON memories(content_hash, scope)
  WHERE deleted_at IS NULL;

CREATE INDEX memories_scope_inserted_idx ON memories(scope, inserted_at);
CREATE INDEX memories_sync_state_idx ON memories(sync_state);
CREATE INDEX memories_deleted_idx ON memories(deleted_at);

CREATE TABLE facts (
  id TEXT PRIMARY KEY,
  content TEXT NOT NULL,
  content_hash TEXT NOT NULL,
  scope TEXT NOT NULL,
  tags TEXT NOT NULL DEFAULT '[]',
  metadata TEXT NOT NULL DEFAULT '{}',
  updated_at TEXT NOT NULL
);

CREATE INDEX facts_scope_updated_idx ON facts(scope, updated_at);

CREATE TABLE memory_outbox (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  op TEXT NOT NULL CHECK (op IN ('remember', 'forget')),
  memory_id TEXT NOT NULL,
  state TEXT NOT NULL DEFAULT 'pending'
    CHECK (state IN ('pending', 'inflight', 'done', 'failed')),
  attempts INTEGER NOT NULL DEFAULT 0,
  last_error TEXT,
  inserted_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE INDEX memory_outbox_state_seq_idx ON memory_outbox(state, seq);
CREATE INDEX memory_outbox_memory_id_idx ON memory_outbox(memory_id);

CREATE TABLE tombstones (
  content_hash TEXT PRIMARY KEY,
  scope TEXT NOT NULL,
  wiped_at TEXT NOT NULL,
  directive_id TEXT NOT NULL
);

CREATE TABLE slots (
  scope TEXT NOT NULL,
  key TEXT NOT NULL,
  value TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (scope, key)
);
```

JSON columns are stored as text and validated/encoded by `Reducer`. `content_hash` is lowercase SHA-256 hex of `content`. Hub-side `BackplaneMemory` may store binary hashes; channel payloads use hex strings and adapters convert as needed.

## 9. Search Baseline

PR0 proved this `ex_turso` build does not expose FTS5:

```sql
CREATE VIRTUAL TABLE memories_fts USING fts5(content);
-- Parse error: no such module: fts5
```

Therefore v1 local recall uses escaped `LIKE` over `memories.content` and `facts.content`:

```sql
SELECT id, content, scope, tags, metadata, confidence, inserted_at, 'local' AS source
FROM memories
WHERE deleted_at IS NULL
  AND scope = ?
  AND lower(content) LIKE ?

UNION ALL

SELECT id, content, scope, tags, metadata, 1.0 AS confidence, updated_at AS inserted_at,
       'hub_fact' AS source
FROM facts
WHERE scope = ?
  AND lower(content) LIKE ?
```

Every local `LIKE` hit includes `quality: :degraded`. Rank merge is deterministic:

1. Exact phrase matches before token matches.
2. Facts before local memories for equal text score.
3. Higher confidence before lower confidence.
4. Newer `inserted_at`/`updated_at` before older rows.
5. Stable tie-break by id.

When `ex_turso` supports FTS5, a new migration may add FTS tables/triggers and D6 can be revised without changing the MCP surface.

## 10. Local API Semantics

All APIs return tagged tuples internally and JSON-compatible maps at the router boundary.

### `remember`

Input:

```json
{
  "content": "string, required",
  "session_id": "optional string",
  "tags": ["optional", "strings"],
  "metadata": {"optional": "object"},
  "scope": "optional, must equal resolved scope if present"
}
```

Behavior:

1. Resolve scope from `memory.bound_scope`.
2. Reject empty content.
3. Reject caller-supplied scope if it differs from the resolved scope.
4. Compute content hash.
5. If tombstone exists for `(content_hash, scope)` and policy is `block`, return `{:error, :wiped}`.
6. In one transaction, insert memory with `ON CONFLICT DO NOTHING`; on dedup hit, select existing live row and enqueue no outbox row.
7. On new row, insert outbox `(op='remember', memory_id=id)`.

Output:

```json
{"id": "uuid7", "scope": "proj_local", "dedup": false, "sync_state": "pending"}
```

### `forget`

Input: `{"id": "uuid7"}`

Behavior:

1. Find a live local memory.
2. Soft-delete it.
3. Insert outbox `(op='forget', memory_id=id)` in the same transaction.
4. Do not touch facts.

`forget` on a fact id returns `{:error, :read_only_fact}`. Hub-originated global removal must use `memory_wipe`.

### `recall`

Input:

```json
{"query": "required string", "limit": 10, "scope": "optional known scope"}
```

Output hits:

```json
{
  "id": "string",
  "content": "string",
  "scope": "proj_local",
  "source": "local | hub_fact",
  "quality": "degraded",
  "tags": [],
  "metadata": {},
  "score": 0.0
}
```

### `list`

Filters: `scope`, `agent_id`, `tag`, `q`, `limit`, `offset`. It lists local memories only unless `include_facts: true` is passed. Deleted rows are excluded.

### `stats`

Returns memory counts by sync state, outbox state, fact count, tombstone count, and known scopes.

### Slots

`slot_write`, `slot_read`, and `slot_list` use the `slots` table. Slots are device-only and never sync.

### Facets

`facet_tag` updates local memory `tags`/`metadata` JSON. Because outbox payloads are built at drain time, pre-sync tagging is reflected in the synced `remember`. Post-sync tagging remains local until an `update` op exists. `facet_query` filters local memories by tag/facet JSON.

## 11. MCP and HTTP Router Contract

Routes remain:

- `POST /memory/:agent_id/call/:method`
- `POST /:agent_id/call/:method`
- `POST /memory/:agent_id/mcp`
- `POST /:agent_id/mcp`

Changes:

- Direct calls dispatch to `Backplane.HostAgent.Memory`.
- `tools/list` returns the static local memory tool set plus existing non-memory `McpManager` tools.
- `tools/call` for `memory::*` dispatches locally.
- Hub-only memory tools, such as `memory::team_share`, return `hub_only_tool` with a message directing clients to Backplane MCP.
- No memory route returns `503` due to channel disconnect.

Stable internal errors:

| Error | HTTP | MCP |
|---|---:|---:|
| `unknown_method` | 404 | `-32601` |
| `invalid_args` | 400 | `-32602` |
| `invalid_scope` | 400 | `-32602` |
| `wiped` | 409 | `-32000` |
| `not_found` | 404 | `-32004` |
| `read_only_fact` | 409 | `-32000` |
| `hub_only_tool` | 400 | `-32000` |
| `storage_error` | 500 | `-32000` |

## 12. Sync Up

Syncer drains `memory_outbox` while connected.

State transitions:

```text
pending ──select batch──► inflight
inflight ──ok/duplicate──► done
inflight ──validation error, attempts < max──► failed
inflight ──validation error, attempts >= max──► failed
inflight ──transient/channel error──► pending
```

Transient errors do not increment attempts. Validation errors increment attempts and retain `last_error`.

Event:

```json
{
  "protocol": "host_memory.v1",
  "items": [
    {
      "seq": 1,
      "op": "remember",
      "id": "local_uuid7",
      "content": "current content",
      "content_hash": "sha256_hex",
      "scope": "proj_local",
      "agent_id": "agent id from local route",
      "session_id": null,
      "tags": [],
      "metadata": {},
      "confidence": 1.0,
      "inserted_at": "utc iso8601",
      "updated_at": "utc iso8601"
    }
  ]
}
```

`forget` items include `id`, `remote_id`, `content_hash`, `scope`, and timestamps. The Syncer builds every payload from the current row at drain time (D16).

Ack:

```json
{
  "items": [
    {
      "id": "local_uuid7",
      "status": "ok | duplicate | error",
      "canonical_id": "hub_uuid",
      "error": null
    }
  ]
}
```

`ok` and `duplicate` mark outbox `done`; `remember` rows become `synced` with `remote_id` and `synced_at`; acknowledged `forget` rows keep `deleted_at` and also become `synced` so retention can purge them. Failed `forget` rows remain soft-deleted locally and visible in diagnostics.

## 13. Join, Facts, and Wipes

Join payload extends the existing host-agent channel join params:

```json
{
  "memory": {
    "protocol": "host_memory.v1",
    "scopes": [
      {"scope": "proj_local", "fact_set_hash": "sha256_hex"}
    ]
  }
}
```

`fact_set_hash` is SHA-256 over canonical JSON rows ordered by `{id, updated_at}` for one scope. Empty scope hash is SHA-256 of `[]`.

Down events:

```json
{
  "scope": "proj_local",
  "full": true,
  "facts": [
    {
      "id": "hub_fact_id",
      "content": "fact content",
      "content_hash": "sha256_hex",
      "tags": [],
      "metadata": {},
      "updated_at": "utc iso8601"
    }
  ]
}
```

For `full: true`, host transactionally replaces all facts in that scope. For incremental push, it upserts by `id`. Facts are read-only outside reconcile and wipe handling.

Wipe event:

```json
{
  "directive_id": "wipe_id",
  "items": [
    {"remote_id": "hub_uuid", "content_hash": "sha256_hex", "scope": "proj_local"}
  ]
}
```

Host wipe behavior:

1. Hard-delete matching local memory by `remote_id`, else `(content_hash, scope)`.
2. Insert tombstone.
3. Cancel matching `pending` or `inflight` outbox rows.
4. Delete matching fact rows.
5. Ack per item.

Wipes are idempotent and replay-safe.

## 14. Hub-Side Contract

`BackplaneWeb.HostAgentChannel` adds three sync events and must not route them through local MCP code:

- `memory_sync`
- `memory_facts_ack`
- `memory_wipe_ack`

PR6 introduces a hub adapter responsible for host sync. The exact module name is implementation detail, but it must provide these operations:

```elixir
apply_sync_item(host, item) ::
  {:ok, %{status: :ok | :duplicate, canonical_id: binary()}}
  | {:error, :validation, term()}
  | {:error, :transient, term()}

facts_for_scope(scope, host_fact_set_hash) ::
  :unchanged | {:full, [fact()]}

active_wipes(scope) :: [wipe_item()]

entitled_scopes(host) :: MapSet.t(String.t())
```

The adapter may delegate to current `BackplaneMemory.Memory` and `BackplaneMemory.Service` internals, but host sync is not a public managed MCP tool call. This keeps MCP authorization, tool schemas, and sync idempotency separate.

Hub requirements:

- Resolve allowed scopes from host registration/project membership.
- Use only `entitled ∩ announced` for facts and wipes.
- Ignore or log announced scopes outside entitlement.
- For host `remember`, store `host_id`, `agent_id`, `scope`, tags, metadata, and content. Duplicate responses must return the existing canonical id.
- For host `forget`, apply originating-host semantics only. It must not laterally delete other hosts' local copies.
- Governance delete/review wipe emits `memory_wipe` and includes active wipe directives in the next join reconcile.

## 15. Retention and Diagnostics

Pruner rule:

```sql
DELETE FROM memories
WHERE sync_state = 'synced'
  AND (
    (deleted_at IS NULL AND inserted_at < cutoff)
    OR (
      deleted_at IS NOT NULL
      AND NOT EXISTS (
        SELECT 1
        FROM memory_outbox
        WHERE memory_outbox.memory_id = memories.id
          AND memory_outbox.state IN ('pending', 'inflight', 'failed')
      )
    )
  );
```

It never touches:

- `facts`
- unsynced memories
- soft-deleted rows with pending, inflight, or failed forget outbox entries
- tombstones
- slots

Diagnostics expose:

- memory counts by `sync_state`
- outbox counts by state
- oldest pending `seq`
- failed/dead-letter rows with last error
- fact count and per-scope `fact_set_hash`
- tombstone count
- last successful sync
- last reconcile time

Add operator tasks:

- `mix agent.memory.resync` — requeue failed outbox rows to `pending`.
- `mix agent.memory.tombstones --purge` — purge tombstones explicitly.

## 16. Telemetry

Events:

| Event | Measurements | Metadata |
|---|---|---|
| `[:backplane, :host_agent, :memory, :call]` | `duration` | method, agent_id, status |
| `[:backplane, :host_agent, :memory, :store, :query]` | `duration` | operation, status |
| `[:backplane, :host_agent, :memory_sync, :batch]` | `count`, `duration` | status, connected, oldest_seq |
| `[:backplane, :host_agent, :memory_facts, :apply]` | `count`, `duration` | scope, full |
| `[:backplane, :host_agent, :memory_wipe, :apply]` | `count`, `duration` | directive_id |
| `[:backplane, :host_agent, :memory_pruner, :run]` | `deleted`, `duration` | cutoff |

## 17. Implementation Sequence and Gates

| PR | Gate |
|---|---|
| PR0 | `ex_turso` dependency/build support, retained Turso contract test, D6 baseline recorded. Done: fallback is `LIKE`. |
| PR1 | Store and migrations boot a clean host DB and re-run idempotently. WAL/busy settings applied. |
| PR2 | `Backplane.HostAgent.Memory` implements local remember/forget/recall/list/stats/slots/facets; reducer has no Store calls; atomicity and dedup tests pass. |
| PR3 | `MemoryRouter` memory path is local-only; offline tools work; `MemoryProxy` no longer participates in memory calls. |
| PR4 | Syncer drains remember/forget outbox at-least-once, builds payload at drain time, and announces scopes with fact hashes. |
| PR5 | Host applies facts and wipes idempotently; recall reflects facts immediately; wipe blocks exact resurrection. |
| PR6 | Hub channel handles sync, entitlement, fact push, and governance wipe. Non-entitled scope announcements produce no data. |
| PR7 | Pruner and diagnostics prove bounded local storage and operator recovery without DB surgery. |

Each PR must preserve:

- local memory calls succeed without a channel,
- no Ecto dependency in `apps/backplane_host_agent`,
- row plus outbox transactionality,
- facts untouched by outbox/pruner,
- replay-safe sync,
- scoped tests for the changed app(s).

## 18. Acceptance Tests

Required retained tests:

- Turso contract: WAL, busy behavior, transaction rollback, JSON round-trip, dedup upsert, and current D6 fallback.
- Fresh boot migrates DB; second boot no-ops.
- Concurrent identical `remember` inserts one row and one outbox item.
- Forced transaction failure leaves no orphan outbox row.
- Tombstone blocks exact re-remember.
- `forget` excludes from recall and enqueues one forget.
- `recall` merges local memories and facts with correct `source`/`quality`.
- Memory router returns local results while channel is disconnected.
- Hub-only tools produce stable errors.
- Syncer drains in FIFO order and handles transient vs validation errors differently.
- Pre-sync facet/tag updates appear in synced payload.
- Fact reconcile full replace is idempotent.
- Wipe cancels queued outbox, hard-deletes local rows, deletes facts, and inserts tombstone.
- Pruner deletes only old synced memories.
- Entitlement test: a host announcing a non-entitled scope receives no facts or wipes for that scope.

## 19. Out of Scope, Tracked

- `update` op for post-sync edit/tag propagation.
- FTS5 until `ex_turso` exposes it.
- Turso native vector recall.
- Local embeddings.
- Slot sync.
- General hub-to-host replication.
- Provenance sets.
- Encryption-at-rest.
- Semantic/non-exact wipe matching.
- Team/share tools on the host.
