# Backplane Memory — Design Spec (v1)

Central, self-hosted agent memory. Backplane is the sole owner; storage is Postgres + pgvector. Samgita is uninvolved.

## Topology

```
OpenClaw / Hermes plugin  ──►  host agent (local broker)  ──►  backplane (central brain + store)
        (localhost)              existing authed channel        backplane_memory app · shared DB

direct MCP / REST callers (Synapsis, etc.)  ──────────────────►  backplane memory MCP server / REST

embeddings:  backplane  ──►  local vLLM (OpenAI-compatible /v1/embeddings, Qwen3-Embedding-4B)
             routed through the existing LLM proxy
```

- **Host agent = thin local broker** for the plugin path: serves the plugin endpoint, privacy-filters + dedups *locally* (secrets never leave the machine), buffers writes offline, holds a small recall cache. No memory intelligence beyond that.
- **Backplane = the brain**: storage, embeddings, consolidation, decay/eviction, hybrid ranking.
- Broker is the plugin path, **not** the sole ingress — direct callers hit the memory MCP server / REST directly.
- Broker ↔ backplane rides the **existing channel**: `recall` request/reply, `observe`/`flush` async push + retry.

## Decision log

| # | Decision |
|---|----------|
| Ownership | Backplane owns memory; central Postgres + pgvector. |
| Tenancy | Single-owner. `client_id` = attribution/partition, **not** a security wall. `global` scope = instance-wide. |
| Provenance | `agent_id` + `host_id` on every row (audit / citation), immutable. |
| Scope | Abstract, user-defined opaque label; a partition key for retrieval filtering only. |
| Taxonomy | One structured field `memory_type ∈ {working, episodic, semantic, procedural}`. Everything else (`tags`, `metadata`) free-form. |
| Writes | Hybrid: explicit verbs + per-client opt-in auto-capture (observing `/api/llm/*`). Both land in **working**. Dedup + privacy-filter at write. |
| Embeddings | **Local vLLM serving `Qwen/Qwen3-Embedding-4B`** (OpenAI-compatible `/v1/embeddings`), called **through the LLM proxy**. Async (Oban). Native **2560-dim** output stored as **`halfvec(2560)`** (see constraint below). `embedding_model` per row; re-embed worker for model changes. |
| Retrieval | RRF (k=60) over pgvector **HNSW `halfvec_cosine_ops`** + native Postgres FTS. Prefilter scope/tier/confidence/not-expired. Rerank by query-time decay × access-strength. Diversify per source/scope. Caller token budget (~2000). Default recall = episodic + semantic + procedural (procedural ≥ semantic ≥ episodic); **working excluded** unless requested. |
| Consolidation | Trigger on memory-MCP **session close** + scheduled Oban fallback. `working→episodic` and `episodic→semantic` via the LLM proxy (async, circuit-breaker). **Procedural is explicit-only in v1.** Contradictions → **supersession + version chains** (`superseded_by`), never hard delete; detected during semantic consolidation. Per-tier TTL + score-threshold eviction (decay × strength × confidence) under a row/disk budget. |
| Surface | Dedicated memory **MCP server** (separate from the hub) + REST + internal Elixir context + host-agent channel verbs — all over one context module. |
| Packaging | `backplane_memory` umbrella app; persists via the shared `Backplane.Repo` connection; `bpm_*` tables; own MCP server, Oban queues, cache. |
| v1 verbs | `remember`, `recall`, `forget` (tombstone), `flush`/`end_session`, `get`, `stats`. Explicit `remember` defaults **semantic**; auto-capture writes **working**. Deferred: `handoff`, `recap`, `session-history`. |
| Plugins | We author the OpenClaw + Hermes plugins; flow is plugin → host agent → backplane. **No agentmemory wire-compat.** |

## Embedding stack

- **Model:** `Qwen/Qwen3-Embedding-4B` — native dim **2560**, MRL-capable (32–2560), instruction-aware, 32K context, 100+ languages.
- **Serving:** local **vLLM** exposing the OpenAI-compatible `/v1/embeddings`. Backplane reaches it **through the existing LLM proxy**, so memory introduces no second provider client — it inherits routing, health, and fallback.
- **Dimension / storage — the hard constraint:** pgvector's standard `vector` type can only be **HNSW-indexed up to 2000 dims**. 2560 exceeds that, so the column **must be `halfvec`** (16-bit, HNSW-indexable up to 4000 dims, ~half the storage, negligible recall loss). Requires **pgvector ≥ 0.7** (0.8.x current). Use Qwen's **full native 2560** as `halfvec(2560)` rather than MRL-truncating — the 4B model's quality is the reason to run it; truncation throws that away.
- **Query/document asymmetry:** Qwen3 embeddings are instruction-aware. Embed *recall queries* with the retrieval instruction prefix; embed *stored memories* as plain documents (no instruction). The embedding client carries a `mode` (`query` | `document`).

## Schema — `bpm_memories`

| Column | Type | Notes |
|--------|------|-------|
| `id` | uuid pk | |
| `content` | text | |
| `memory_type` | enum | working / episodic / semantic / procedural |
| `scope` | text | opaque, indexed |
| `agent_id` / `host_id` | text | provenance, indexed |
| `client_id` | text | attribution, indexed |
| `session_id` | text null | consolidation boundary, indexed |
| `tags` | text[] | GIN |
| `metadata` | jsonb | free-form |
| `embedding` | **halfvec(2560)** null | HNSW `halfvec_cosine_ops`; null until embedded |
| `embedding_model` | text | default `Qwen/Qwen3-Embedding-4B`; for re-embed migrations |
| `content_hash` | bytea | dedup window |
| `search_tsv` | tsvector | generated from `content`; GIN |
| `confidence` | float | corroboration up, contradiction/age down |
| `access_count` | int | strength signal |
| `accessed_at` | timestamptz | bumped async post-recall |
| `superseded_by` | uuid null | version chain |
| `expires_at` | timestamptz null | per-tier TTL |
| `deleted_at` | timestamptz null | tombstone |
| `inserted_at` / `updated_at` | timestamptz | |

Indexes: `HNSW(embedding halfvec_cosine_ops)`, `GIN(search_tsv)`, `GIN(tags)`, `btree(scope, memory_type)`, `btree(session_id)`, partial on `deleted_at IS NULL`.

## Module layout — `apps/backplane_memory/lib/backplane_memory/`

```
memory.ex                  context API: remember/recall/forget/flush/get/stats
memories/memory.ex         schema (Backplane.Repo)
retrieval/{vector,keyword,fusion,ranker}.ex   RRF · decay×strength
embedding/client.ex        calls vLLM via the LLM proxy; query|document mode
consolidation/{promoter,contradiction}.ex     LLM via proxy
privacy/filter.ex          shared rules (mirrored in broker)
workers/{embed,consolidate,evict,reembed}_worker.ex   Oban
mcp/server.ex              own MCP server + tool defs
rest/router.ex             /api/memory/* for direct callers
cache.ex                   ETS
```

Host-agent side adds a local broker: plugin listener · privacy-filter · dedup · offline buffer · channel relay · recall cache.

## Core flows

- **Write** (explicit or auto): caller → broker (privacy-filter + dedup) → context → insert `working` row (+`content_hash`) → enqueue embed worker → async embed via vLLM (document mode).
- **Recall**: embed query (query mode) → prefilter (scope/tier/confidence/not-expired) → vector (`halfvec` HNSW) + FTS streams → RRF → decay × strength rerank → diversify → fill token budget → return; enqueue async access bump.
- **Consolidation**: session-close or cron → gather `working` for session/scope → LLM summarize → `episodic` → evict consolidated working; periodic `episodic→semantic` fact extraction + contradiction check → supersede.

## Open implementation leaves (recommended defaults)

- **pgvector version**: ensure **≥ 0.7** in the deploy (Nix/devenv) — `halfvec` is unavailable below it.
- **Privacy filter rules**: secret/key regex + entropy heuristics + honor `<private>` tags; on by default at the broker.
- **Eviction budget / decay τ per tier**: configurable constants; generous defaults.
- **vLLM dims**: leave vLLM at native 2560 (no MRL `--hf-overrides` needed); the column matches.
- **Admin UI**: memory browser page (list / search / inspect / forget). Recommended, minor.