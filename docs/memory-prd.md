# Backplane Memory — PRD (v1)

**Status:** Draft · **Owner:** Backplane · **Scope:** v1 (single-owner, self-hosted)

## 1. Summary

A central, self-hosted memory service inside Backplane that lets agents persist and recall knowledge across sessions, projects, and runtimes. Backplane owns the store (Postgres + pgvector); agents reach it via a dedicated memory MCP server, REST, or — for external runtimes — a local host-agent broker. Embeddings are produced by a local vLLM model. This removes the "re-explain everything every session" tax and gives agents durable, searchable, decaying memory.

## 2. Problem & motivation

- Agents are stateless across sessions; context is re-established manually every run.
- Knowledge produced in one repo/project/agent is invisible to others.
- External runtimes (OpenClaw, Hermes) have a memory slot but no self-hosted provider behind it.
- Existing context lives in opaque transcripts, not a queryable, governed store with provenance.

## 3. Goals / Non-goals

**Goals**
- One central, self-hosted memory store all agents can write and query.
- Automatic capture (zero-effort) plus deliberate writes.
- Relevant recall under a token budget, fused from semantic + keyword signals.
- Memory that consolidates, decays, and resolves contradictions on its own.
- Drop-in memory provider for OpenClaw and Hermes via first-party plugins.
- Full provenance (which agent, which host) on every memory.

**Non-goals (v1)**
- Knowledge-graph extraction / entity traversal (stays out of Backplane; Samgita's domain if ever).
- Decision/PRD/notes modeling — memory is the episodic/semantic/procedural substrate only.
- Multi-tenant security isolation (single-owner deployment; `client_id` is attribution, not a wall).
- Auto-derived procedural memory (explicit-only in v1).
- True BM25 (native Postgres FTS in v1; BM25 extension is a later upgrade).

## 4. Users & personas

| Persona | Need |
|---|---|
| **Agent (in-runtime)** | Remember/recall facts and procedures across sessions without re-priming. |
| **Host operator** | Run the memory broker locally; trust that secrets never leave the machine. |
| **External runtime** (OpenClaw/Hermes) | Plug Backplane into its memory slot with one config. |
| **Backplane operator** | Inspect, search, and prune memory; control capture and retention. |

## 5. Key use cases

- **Cross-session recall:** an agent resumes work and is pre-loaded with the most relevant prior knowledge within a token budget.
- **Deliberate knowledge:** an agent asserts a durable fact or learned procedure that survives indefinitely.
- **Passive capture:** completed turns are observed and stored automatically, then consolidated.
- **Project-scoped memory:** memories partitioned by an opaque, user-defined scope so recall stays relevant.
- **Forget:** an operator or agent tombstones a memory or a scope.
- **Provenance audit:** trace any recalled memory back to the agent and host that produced it.

## 6. Functional requirements

| ID | Requirement | Acceptance criteria |
|----|-------------|---------------------|
| FR-1 | **Write — explicit** | `remember(content, type?, scope?, tags?, metadata?, session_id?)` persists a memory; default `type=semantic`; returns id. |
| FR-2 | **Write — auto-capture** | Per-client opt-in capture of `/api/llm/*` completions stores `working`-tier rows; off by default. |
| FR-3 | **Dedup** | Identical content within a short window (content hash) is not duplicated. |
| FR-4 | **Provenance** | Every row records `agent_id` + `host_id`; immutable; returned with recall results. |
| FR-5 | **Scope** | Opaque user-defined `scope` partitions memories; recall filters by it; `global` = instance-wide. |
| FR-6 | **Embedding** | Each row is embedded async via local vLLM (`Qwen3-Embedding-4B`) through the LLM proxy; recall degrades to keyword-only until embedded. |
| FR-7 | **Recall — hybrid** | `recall(query, scope?, type?, limit?, token_budget?)` returns ranked memories fusing vector + FTS via RRF, filtered and reranked by decay × strength. |
| FR-8 | **Recall — defaults** | Default search covers episodic+semantic+procedural (procedural ≥ semantic ≥ episodic); `working` excluded unless requested. |
| FR-9 | **Token budget** | Results greedily fill a caller-supplied budget (default ~2000 tokens); diversified per source/scope. |
| FR-10 | **Consolidation** | On session close (memory-MCP lifecycle) or scheduled fallback, `working→episodic` and `episodic→semantic` promotion runs via the LLM proxy. |
| FR-11 | **Contradiction** | Conflicting facts are superseded with a version chain (`superseded_by`), never hard-deleted; detected during semantic consolidation. |
| FR-12 | **Decay & eviction** | Per-tier TTL + score-threshold eviction (decay × strength × confidence) under a row/disk budget; access strengthens. |
| FR-13 | **Forget** | `forget(id | scope/query)` tombstones (soft-delete) by default. |
| FR-14 | **Surfaces** | Memory exposed via its own MCP server (separate from the hub), REST `/api/memory/*`, internal context module, and host-agent channel verbs. |
| FR-15 | **Plugin integration** | First-party OpenClaw + Hermes plugins route plugin → local host-agent broker → backplane; recall-before-turn and capture-after-turn. |
| FR-16 | **Broker — local privacy** | Host-agent broker privacy-filters and dedups locally before relay; buffers writes when backplane is unreachable. |
| FR-17 | **Read conveniences** | `get(id)` and `stats()` (counts per tier/scope) available. |
| FR-18 | **Admin** | Operator UI to list, search, inspect, and tombstone memories; toggle capture per client. |

## 7. Non-functional requirements

| ID | Requirement |
|----|-------------|
| NFR-1 | **Recall latency** — p95 recall (excluding query embedding) under a few hundred ms at expected corpus size; embedding async, never on the write path. |
| NFR-2 | **Capture is non-blocking** — auto-capture and writes never add measurable latency to proxy traffic. |
| NFR-3 | **Offline tolerance** — broker buffers and retries; no memory loss when backplane is briefly unreachable. |
| NFR-4 | **Privacy** — secrets/keys and `<private>` content are stripped at the broker before leaving the host. |
| NFR-5 | **Resilience** — embedding/LLM calls use circuit-breaker + fallback; memory degrades gracefully (keyword-only, skip consolidation) rather than failing writes. |
| NFR-6 | **Storage** — `halfvec(2560)` HNSW index; pgvector ≥ 0.7 required; shares the Backplane DB connection. |
| NFR-7 | **Isolation of concerns** — `backplane_memory` is a self-contained umbrella app with its own MCP server, Oban queues, and cache. |
| NFR-8 | **Observability** — capture/embed/consolidate/evict counts and recall quality are inspectable. |

## 8. Scope

**v1:** FR-1…FR-18 above; tri-tier auto-pipeline (working→episodic→semantic); explicit procedural; OpenClaw + Hermes plugins; native FTS; admin UI.

**Deferred (v2+):** `handoff` / `recap` / `session-history` verbs; auto-derived procedural; knowledge graph; true BM25 extension; multi-model embedding; cross-instance federation.

## 9. Success metrics

- **Retrieval quality** — recall@5 measured on a held-out memory benchmark (reference target: agentmemory reports 95.2% R@5 on LongMemEval-S).
- **Token savings** — measurable reduction in tokens spent re-establishing context per session.
- **Adoption** — OpenClaw and Hermes runtimes connect and capture/recall with zero manual server code.
- **Autonomy** — consolidation/eviction keep working-tier volume bounded without operator intervention.
- **Zero secret leakage** — no secrets present in stored memories (audited).

## 10. Dependencies & constraints

- Postgres + **pgvector ≥ 0.7** (`halfvec`).
- Local **vLLM** serving `Qwen/Qwen3-Embedding-4B` (native 2560-dim, instruction-aware), OpenAI-compatible.
- Backplane **LLM proxy** (embedding + consolidation routing) and **host-agent channel** (broker transport).
- Oban for async embed/consolidate/evict/reembed.

## 11. Milestones

1. **M1 — Store & writes:** schema, `halfvec(2560)`, explicit `remember`/`get`, dedup, provenance, async embed via vLLM.
2. **M2 — Recall:** hybrid RRF (vector + FTS), scope/tier filters, decay×strength rerank, token budget.
3. **M3 — Lifecycle:** consolidation pipeline, decay/eviction, supersession.
4. **M4 — Surfaces:** memory MCP server + REST; auto-capture from the proxy (opt-in).
5. **M5 — Broker & plugins:** host-agent broker (privacy/dedup/buffer) + OpenClaw and Hermes plugins.
6. **M6 — Admin & metrics:** operator UI, observability, recall benchmark.

## 12. Risks & open questions

- **Embedding instruction tuning** — query/document asymmetry must be applied correctly or recall quality drops.
- **Eviction tuning** — decay τ and budgets need calibration to avoid over- or under-forgetting.
- **Consolidation cost** — LLM promotion volume must be bounded (batch per session/scope).
- **Privacy completeness** — regex/entropy filters are heuristic; define the accepted residual risk.
- **vLLM availability** — embedding backfill stalls if vLLM is down; recall must stay keyword-capable meanwhile.