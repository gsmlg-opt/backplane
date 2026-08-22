# Backplane Memory — Host-Agent Capture and Agentmemory-Parity Architecture (v2)

Status: Proposed  
Owner: Backplane  
Repository: `gsmlg-opt/backplane`  
Primary implementation: `apps/backplane_memory`  
Edge capture and transport: `apps/backplane_host_agent` and host-agent integrations  
Public transport: `apps/backplane_api`  
Administration UI: `apps/backplane_admin`  
Date: 2026-07-30

## 1. Purpose

This document defines the target architecture for evolving Backplane Memory toward agentmemory feature parity while preserving Backplane's existing product boundary:

- Agent activity is captured near the runtime by `host_agent`.
- `host_agent` privacy-filters, normalizes, durably buffers, and transports captured events.
- Backplane receives those events over its authenticated host-agent channel.
- `backplane_memory` is the sole owner of durable memory, processing, indexing, consolidation, recall, governance, coordination, and memory-specific product features.
- PostgreSQL and pgvector remain the authoritative central store.
- Phoenix LiveView remains the administration surface.
- MCP tools continue to use Backplane's `memory::*` namespace.

The goal is functional parity with the useful parts of agentmemory, not implementation parity with iii-engine, SQLite/KV storage, or its single-file web viewer.

This document extends and refines:

- `docs/memory-design.md`
- `docs/memory-prd.md`
- `docs/memory-agentmemory-prd.md`
- `docs/host-agent-design.md`
- `docs/host-agent-memory-design-final.md`

The companion product requirements are defined in `backplane-memory-agentmemory-parity-prd-v2.md`.

---

## 2. Fixed Architecture Decisions

### 2.1 Ownership

Backplane is the sole owner of memory. No external agent runtime, plugin, or host-local database is authoritative for long-term memory.

`backplane_memory` owns:

- captured event persistence;
- sessions and observations;
- episodic summaries;
- semantic and procedural memory;
- lessons and crystals;
- embeddings and search indexes;
- knowledge graph and project profiles;
- confidence, evidence, lifecycle, decay, and supersession;
- actions, dependency edges, frontier, leases, and signals;
- audit, activity, replay, and memory health;
- REST, MCP, resources, prompts, and memory-specific internal APIs.

### 2.2 Host Agent Boundary

`host_agent` is a thin edge collector and reliable transport layer. It may perform only work that must occur close to the source runtime:

- install and invoke runtime-specific hooks;
- capture events;
- perform local privacy filtering and secret redaction;
- normalize source payloads into the canonical event envelope;
- assign stable event IDs and per-session sequence numbers;
- perform transport-level duplicate suppression;
- append to a durable local spool;
- batch, retry, reconnect, and process acknowledgements;
- maintain a small bounded recall cache for network outages;
- perform short-timeout SessionStart and PreCompact recall requests;
- expose capture and transport telemetry.

`host_agent` must not perform:

- LLM compression or summarization;
- embedding generation;
- semantic deduplication;
- consolidation;
- contradiction resolution;
- lesson or crystal extraction;
- graph extraction;
- project profile construction;
- decay or retention decisions;
- long-term memory storage;
- authoritative action or lease state.

The operational rule is:

> `host_agent` collects and delivers evidence; `backplane_memory` interprets and owns it.

### 2.3 Ingress Paths

There are two supported ingress classes:

1. **Automatic capture path** — all hook-driven capture flows through `host_agent`.
2. **Explicit operation path** — trusted callers may use the Backplane Memory MCP or REST APIs directly for operations such as `remember`, `recall`, `forget`, action management, and governance.

Both paths terminate in the same `Backplane.Memory` contexts and apply the same validation, privacy, scope, provenance, and audit rules.

### 2.4 Storage and Search

- PostgreSQL is the authoritative store.
- pgvector `halfvec(2560)` remains the vector representation for Qwen3-Embedding-4B.
- Native PostgreSQL FTS remains the keyword channel; no external BM25 extension is required for this scope.
- Recall uses FTS, vector, and graph channels fused through weighted Reciprocal Rank Fusion with `k = 60`.
- All asynchronous processing uses Oban.
- Live updates use Phoenix PubSub.

### 2.5 Product Scope Changes from the Existing Parity PRD

This architecture intentionally revises four prior scope decisions in order to align the product with agentmemory's visible capabilities:

- Lessons become a first-class Backplane Memory capability.
- Activity becomes a first-class read model and administration page.
- Crystallization is restored as a completed-work digest capability.
- Replay moves from indefinite deferral into a planned milestone after the canonical event stream is stable.

The following remain out of scope:

- image/vision memory;
- mesh or peer-to-peer memory synchronization;
- filesystem watchers;
- Obsidian export;
- MEMORY.md bridge;
- Git-backed memory snapshots;
- routines, checkpoints, sentinels, and sketches;
- temporal knowledge graph semantics beyond timestamps and ordinary lifecycle relations.

---

## 3. System Topology

```text
Claude Code / Codex / OpenCode / Hermes / OpenClaw / other runtimes
                              │
                              │ runtime hooks and plugin events
                              ▼
                    host_agent runtime
        ┌─────────────────────────────────────────────┐
        │ adapter · privacy filter · normalizer       │
        │ sequence allocator · durable local spool    │
        │ batch uploader · ACK tracker · recall cache │
        └──────────────────────┬──────────────────────┘
                               │ authenticated host-agent channel
                               │ at-least-once batches
                               ▼
                      backplane_api
        ┌─────────────────────────────────────────────┐
        │ host authentication · channel protocol      │
        │ payload limits · request correlation        │
        └──────────────────────┬──────────────────────┘
                               │
                               ▼
                    backplane_memory
        ┌─────────────────────────────────────────────┐
        │ ingest · event store · sessions             │
        │ observations · summaries · memories         │
        │ embeddings · recall · graph · profiles      │
        │ lessons · crystals · actions · replay       │
        │ audit · activity · governance · telemetry   │
        └───────────────┬─────────────────┬───────────┘
                        │                 │
                        ▼                 ▼
               PostgreSQL + pgvector   Backplane LLM Proxy
                                      ├─ embeddings
                                      ├─ compression
                                      ├─ summarization
                                      ├─ graph extraction
                                      ├─ contradiction classification
                                      └─ optional reranking

Direct MCP / REST callers ───────────────► backplane_memory

backplane_admin LiveView ────────────────► backplane_memory read models
```

---

## 4. Component Responsibilities

| Component | Owns | Must not own |
|---|---|---|
| Runtime integration | Hook installation, runtime payload extraction, local invocation contract | Persistent memory or semantic processing |
| `host_agent` | Privacy filtering, normalization, event ID/sequence, durable spool, batching, retry, ACK, recall cache, host telemetry | Embeddings, summaries, graph, consolidation, long-term memory |
| `backplane_api` | Host authentication, channel/session management, transport limits, REST routing, MCP transport | Memory business logic |
| `backplane_memory` | All memory domain state, processing, recall, coordination, lifecycle, governance, replay | Runtime-specific hook parsing beyond registered adapters |
| `backplane_admin` | LiveView read and management surfaces | Independent data models or processing logic |
| Backplane LLM Proxy | Provider selection, credentials, routing, usage, health, fallbacks | Memory lifecycle decisions |
| PostgreSQL/pgvector | Durable facts, projections, indexes, jobs, audit | Source runtime integration |

---

## 5. Capture Model

### 5.1 Supported Hook Lifecycle

The automatic capture path supports ten canonical hook classes.

| Runtime hook | Canonical event type | Backplane action |
|---|---|---|
| `SessionStart` | `agent.session.started` | Open/register session; optionally return context |
| `UserPromptSubmit` | `agent.prompt.submitted` | Store privacy-filtered user intent observation |
| `PostToolUse` | `agent.tool.completed` | Store tool input/output observation and touched files |
| `PostToolUseFailure` | `agent.tool.failed` | Store error observation |
| `PreCompact` | `agent.context.pre_compact` | Record compaction boundary; optionally return recall context |
| `SubagentStart` | `agent.subagent.started` | Link child session/run to parent |
| `SubagentStop` | `agent.subagent.stopped` | Close child lifecycle segment |
| `Stop` | `agent.session.stopped` | Trigger summary/reflection candidates |
| `SessionEnd` | `agent.session.ended` | Close session; enqueue final processing |
| `PostCommit` | `git.commit.created` | Store commit metadata and touched files |

Adapters may map additional source events to canonical types, but unknown event types must remain namespaced and versioned rather than silently coerced.

### 5.2 Canonical Event Envelope

Every automatically captured event sent by `host_agent` uses this logical envelope:

```json
{
  "event_id": "0191f28d-8f72-7db1-86cf-5be337f58d11",
  "schema_version": 1,
  "host_id": "host-mac-mini",
  "agent_id": "codex-main",
  "client_id": "codex-cli",
  "integration": "codex",
  "project": "/workspace/backplane",
  "scope": "project:backplane",
  "session_id": "session-uuid",
  "parent_session_id": null,
  "sequence": 42,
  "event_type": "agent.tool.completed",
  "occurred_at": "2026-07-30T13:00:00.000Z",
  "captured_at": "2026-07-30T13:00:00.012Z",
  "idempotency_key": "codex:session-uuid:tool-call-17:completed",
  "payload_hash": "sha256:...",
  "privacy": {
    "filtered": true,
    "filter_version": "2",
    "redaction_count": 2,
    "private_blocks_removed": 0
  },
  "trace": {
    "correlation_id": "...",
    "causation_id": "..."
  },
  "payload": {
    "tool_name": "shell",
    "input": {},
    "output": {},
    "files": []
  }
}
```

Required fields:

- `event_id`
- `schema_version`
- `host_id`
- `agent_id`
- `integration`
- `session_id` for session-bound events
- `sequence` for session-bound events
- `event_type`
- `occurred_at`
- `idempotency_key`
- `payload_hash`
- `privacy`
- `payload`

### 5.3 Schema Versioning

- Event schema versions are immutable.
- Backplane accepts the current version and a configurable compatibility window of older versions.
- Upcasting occurs at ingestion through explicit versioned modules.
- Raw accepted payloads remain available for provenance, but normal projections use the upcast canonical representation.
- An unsupported future version is rejected with a permanent error so the host does not retry indefinitely.

Suggested module boundary:

```text
Backplane.HostAgent.Memory.EventEnvelope
Backplane.HostAgent.Memory.EventNormalizer
Backplane.Memory.Ingest.EventValidator
Backplane.Memory.Ingest.Upcaster.V1
```

---

## 6. Host-Agent Capture Pipeline

```text
runtime hook
    │
    ▼
adapter parses source payload
    │
    ▼
privacy filter and private-block removal
    │
    ▼
canonical event normalization
    │
    ├─ stable event_id
    ├─ idempotency_key
    ├─ per-session sequence
    └─ payload_hash
    │
    ▼
append to durable local spool
    │
    ▼
return success to runtime
    │
    ▼
background uploader batches pending events
    │
    ▼
Backplane durable ACK
    │
    ▼
mark/remove acknowledged spool entries
```

### 6.1 Local Spool Requirements

The spool is an edge delivery queue, not a memory database.

It must:

- survive host-agent process and machine restarts;
- preserve enqueue order per session;
- support batch reads and acknowledgement by event ID;
- retry transient failures with bounded exponential backoff and jitter;
- retain permanent failures in a dead-letter state with operator visibility;
- enforce configurable maximum bytes and maximum event age;
- never delete unacknowledged events merely because Backplane is unavailable;
- expose queue depth, oldest event age, bytes used, retries, and dead-letter count;
- encrypt at rest when a host-level encryption facility is configured;
- compact acknowledged records without blocking capture.

The storage implementation is behind a behavior so the current host-agent queue can be retained or replaced without changing the wire contract.

```elixir
@callback append(EventEnvelope.t()) :: :ok | {:error, term()}
@callback next_batch(pos_integer(), pos_integer()) :: [EventEnvelope.t()]
@callback acknowledge([event_id()]) :: :ok | {:error, term()}
@callback reject(event_id(), reason(), permanent?()) :: :ok
@callback stats() :: map()
```

### 6.2 Transport-Level Deduplication

The host may suppress exact duplicate hook invocations before enqueueing, but only when all of the following match:

- integration;
- session ID;
- source call/event ID;
- canonical event type;
- payload hash.

This optimization is not authoritative. Backplane still enforces persistent idempotency.

### 6.3 Runtime Blocking Rules

- Async hooks return after successful local enqueue; they do not wait for Backplane processing.
- A Backplane outage must not block the runtime while the spool has capacity.
- `SessionStart` and `PreCompact` may make a bounded synchronous recall request.
- Recall timeout or channel failure is fail-open: the runtime continues without injected memory.
- Capture of the corresponding lifecycle event still occurs through the spool.

### 6.4 Recall Cache

The host recall cache is deliberately small and non-authoritative.

It may store:

- the most recent project profile;
- the last successful SessionStart context block;
- a bounded set of high-priority active lessons;
- expiration metadata and the Backplane revision used to produce the entry.

It must not independently rank or consolidate memory. It is used only when Backplane is unreachable and must label injected data as cached/stale.

---

## 7. Delivery Semantics and Acknowledgements

### 7.1 Delivery Guarantee

The channel provides **at-least-once delivery with persistent server-side idempotency**.

Exactly-once network delivery is not attempted. Exactly-once effects are achieved through unique constraints and idempotent projections.

### 7.2 Batch Contract

Suggested defaults:

- maximum 100 events per batch;
- maximum uncompressed batch payload 512 KiB;
- configurable compression for larger batches;
- one batch may contain multiple sessions;
- ordering is guaranteed only per session sequence, not globally.

Logical request:

```json
{
  "batch_id": "uuid",
  "host_id": "host-mac-mini",
  "events": []
}
```

Logical acknowledgement:

```json
{
  "batch_id": "uuid",
  "results": [
    {"event_id": "...", "status": "accepted", "server_event_id": "..."},
    {"event_id": "...", "status": "duplicate", "server_event_id": "..."},
    {"event_id": "...", "status": "rejected", "retryable": false, "reason": "unsupported_schema"},
    {"event_id": "...", "status": "failed", "retryable": true, "reason": "database_unavailable"}
  ]
}
```

### 7.3 ACK Boundary

`accepted` means:

- host identity and permissions were validated;
- event schema passed validation;
- server privacy filtering completed;
- the event was durably committed to PostgreSQL;
- the durable event is discoverable by its idempotency key.

It does not mean that compression, embedding, graph extraction, summaries, lessons, crystals, or profiles are finished.

### 7.4 Ordering and Late Events

- Each session-bound event carries an increasing sequence.
- Backplane accepts out-of-order events and marks sequence gaps.
- Projections process contiguous ranges where ordering is semantically required.
- A gap does not block unrelated sessions.
- Missing events can arrive later and trigger targeted projection repair.
- Session closure is not treated as proof that all earlier events have arrived; a configurable grace period precedes final crystal generation.

---

## 8. Backplane Ingestion Pipeline

```text
authenticated batch
    │
    ▼
host and client scope authorization
    │
    ▼
schema validation and upcasting
    │
    ▼
server-side privacy defense-in-depth
    │
    ▼
persistent idempotency check
    │
    ▼
PostgreSQL transaction
    ├─ append immutable event
    ├─ register/update stream metadata
    ├─ enqueue or record projection work
    └─ write ingestion telemetry/audit where required
    │
    ▼
durable ACK
    │
    ▼
Oban projection and processing workers
```

### 8.1 Persistent Idempotency

Recommended uniqueness rules:

```text
UNIQUE (host_id, event_id)
UNIQUE (host_id, idempotency_key) WHERE idempotency_key IS NOT NULL
UNIQUE (session_id, sequence, event_type) WHERE session_id IS NOT NULL
```

The third constraint may be relaxed for event types that legitimately share a sequence. The canonical rule is the source event/idempotency key, not content similarity.

### 8.2 Privacy Defense in Depth

The server repeats privacy filtering because:

- host versions may lag;
- direct MCP/REST callers bypass host capture;
- source adapters can be misconfigured;
- policy may change after a host is deployed.

The server records only privacy metadata required for operations and auditing; it does not retain the original unfiltered secret value.

### 8.3 Event Store and Projection Boundary

The target model distinguishes three classes of state:

1. **Captured experience source of truth** — immutable memory events.
2. **Durable knowledge source of truth** — versioned `bpm_memories` plus evidence, relations, and lifecycle state.
3. **Derived read models** — observations, sessions, summaries, graph, profiles, activity aggregates, replay timelines, and recall traces.

Captured events are never overwritten by compressed observations. Compression creates or updates a projection linked to the source event.

`bpm_memories` may update operational fields such as access counters, but content evolution is represented by a new version and relation rather than rewriting history.

---

## 9. Processing Pipeline

### 9.1 Per-Event Processing

After durable ingestion:

```text
memory event
   ├─ ObservationProjector
   ├─ SessionProjector
   ├─ ActivityProjector
   ├─ optional CompressionWorker
   ├─ EmbeddingWorker
   └─ PubSub notification
```

Raw observation projection is deterministic and does not require an LLM. LLM compression is optional enrichment.

### 9.2 Session Completion Processing

After `agent.session.ended`, subject to sequence-gap grace time:

```text
closed session
   ├─ SummaryWorker
   ├─ SemanticConsolidationWorker
   ├─ GraphExtractWorker
   ├─ ProfileBuildWorker
   ├─ LessonCandidateWorker
   ├─ CrystalWorker
   └─ File/commit relationship projector
```

All workers are idempotent and keyed by session ID plus processing/prompt version.

### 9.3 LLM-Unavailable Behavior

- Event capture, observation projection, FTS, sessions, activity, audit, actions, and replay continue without an LLM.
- Embedding failure degrades recall to FTS and graph channels that remain available.
- Session summary produces a deterministic fallback containing selected important observations, tool/file counts, errors, commits, and timestamps.
- LLM-dependent graph, semantic, lesson, and crystal enrichment enters `pending` or `skipped` state and may be retried after a provider becomes available.
- No user-facing operation fails solely because an optional intelligence feature is disabled.

### 9.4 Projection State

A common projection state model tracks:

```text
projector
subject_type
subject_id
input_revision
output_revision
status            # pending | running | complete | skipped | failed | dead_letter
attempt_count
last_error
started_at
completed_at
updated_at
```

This drives administration status, repair, and replayability of derived data.

---

## 10. Memory Taxonomy and Searchable Artifacts

Backplane retains the established memory tiers:

| Tier | Meaning | Typical source |
|---|---|---|
| Working | Recent captured observations and temporary context | Hook events |
| Episodic | What happened in a session or completed body of work | Summaries and crystals |
| Semantic | Durable facts, decisions, architecture, preferences, and patterns | Explicit writes and consolidation |
| Procedural | How work should be performed | Explicit procedures and active lessons |

The immutable event stream sits below these tiers as evidence; it is not itself another recall tier.

### 10.1 Unified Recall Candidate

Every recall channel returns a normalized candidate:

```elixir
%RecallCandidate{
  id: uuid,
  kind: :memory | :lesson | :crystal | :summary | :observation,
  memory_type: :working | :episodic | :semantic | :procedural,
  content: binary,
  scope: binary,
  namespace: binary,
  project: binary | nil,
  session_id: binary | nil,
  confidence: float,
  strength: float,
  evidence_count: non_neg_integer,
  source_ids: [uuid],
  channel_scores: map,
  lifecycle_state: atom,
  token_estimate: non_neg_integer
}
```

This allows lessons and crystals to participate in recall without flattening their specialized lifecycle fields.

---

## 11. Data Model Extensions

The exact migrations must preserve existing table names and constraints. The following logical additions are required.

### 11.1 Memory Evidence

```text
memory_evidence
  id
  memory_id
  source_event_id
  source_observation_id
  source_summary_id
  source_crystal_id
  source_session_id
  agent_id
  host_id
  evidence_kind       # supports | contradicts | derives | confirms | applies
  support_score
  excerpt
  created_at
```

Repeated evidence must strengthen a memory rather than being discarded as a duplicate.

### 11.2 Memory Relations

```text
memory_relations
  id
  source_memory_id
  target_memory_id
  domain              # lifecycle | provenance | knowledge
  relation_type       # supersedes | contradicts | extends | derives | related
  confidence
  status              # candidate | confirmed | rejected
  evidence_ids
  classifier_model
  classifier_version
  created_at
  resolved_at
```

### 11.3 Lessons

`bpm_memories` remains the searchable procedural record. Lesson-specific state is attached one-to-one:

```text
memory_lessons
  memory_id PK/FK -> bpm_memories.id
  status                 # candidate | active | disputed | superseded | archived
  context
  source_kind            # manual | correction | crystal | consolidation
  reinforcement_count
  contradiction_count
  decay_rate
  last_reinforced_at
  last_decayed_at
  promoted_at
  promoted_by
  created_at
  updated_at
```

### 11.4 Crystals

```text
memory_crystals
  id
  memory_id UNIQUE/FK -> bpm_memories.id
  title
  project
  source_session_id
  source_action_ids
  narrative
  key_outcomes
  decisions
  files_affected
  unresolved_items
  processing_version
  created_at

memory_crystal_lessons
  crystal_id
  lesson_memory_id
  relation_type          # extracted | reinforced
  created_at
```

A crystal is searchable as episodic memory but retains structured completed-work data.

### 11.5 Activity Aggregates

```text
memory_activity_daily
  date
  project
  agent_id
  host_id
  event_type
  event_count
  session_count
  memory_count
  lesson_count
  crystal_count
  recall_count
  action_count
  error_count
  PRIMARY KEY (date, project, agent_id, host_id, event_type)
```

### 11.6 Recall Traces

```text
memory_recall_runs
  id
  query
  normalized_query
  scope
  namespace
  filters
  channel_weights
  token_budget
  tokens_used
  result_count
  latency_ms
  query_embedding_model
  reranker_model
  created_at

memory_recall_candidates
  recall_run_id
  candidate_id
  candidate_kind
  fts_rank
  vector_rank
  graph_rank
  fts_score
  vector_score
  graph_score
  rrf_score
  lifecycle_score
  reranker_score
  final_score
  selected
  rejection_reason
  token_estimate
```

### 11.7 Replay Imports

```text
memory_import_batches
  id
  host_id
  integration
  source_format
  source_path_fingerprint
  status
  discovered_count
  imported_count
  rejected_count
  started_at
  completed_at
  error
```

Backplane stores only a non-sensitive source path fingerprint or display-safe label, not arbitrary local secrets.

---

## 12. Idempotency, Deduplication, and Evidence

These are distinct mechanisms and must not be conflated.

### 12.1 Request Idempotency

Prevents network retry or hook retry from creating duplicate effects.

Keys:

- host event ID;
- host idempotency key;
- direct caller idempotency key;
- processing input revision and worker version.

### 12.2 Exact Content Candidate Detection

`content_hash` remains a fast candidate lookup but must include the relevant partition fields:

```text
normalized content
scope
namespace
memory_type
project/client attribution where applicable
```

An exact match does not discard the new source. It adds evidence and may reinforce the existing memory.

### 12.3 Semantic Deduplication

Semantic dedup is a memory intelligence operation performed centrally. It may classify a candidate as:

- exact duplicate;
- paraphrase of the same fact;
- extension;
- temporal update;
- contradiction;
- unrelated.

The classification and evidence are retained. A low-confidence model output cannot automatically delete or supersede a memory.

### 12.4 Evidence versus Access

Backplane tracks independent signals:

- `evidence_count` — independent sources supporting truth;
- `source_diversity` — distinct sessions/agents/hosts;
- `access_count` — how often retrieval returned the item;
- `application_count` — how often a lesson/procedure was explicitly applied;
- `contradiction_count` — opposing evidence.

Access frequency affects retrieval utility, not factual confidence by itself.

---

## 13. Memory Lifecycle and Contradiction Handling

### 13.1 Lifecycle States

```text
candidate
    │ validation / explicit confirmation
    ▼
active
    ├─ new compatible evidence ──► reinforced active
    ├─ newer replacement ────────► superseded
    ├─ unresolved conflict ──────► disputed
    ├─ low utility / retention ──► archived
    └─ governance request ───────► tombstoned
```

Hard deletion remains disabled by default and is a separately authorized governance operation.

### 13.2 Contradiction Pipeline

The current implementation must not infer contradiction solely from equal scope/tags. The target pipeline is:

1. Generate candidates using canonical subject/predicate metadata, entity overlap, and semantic similarity.
2. Check whether validity intervals or project/scope boundaries actually overlap.
3. Classify the pair as duplicate, extension, temporal replacement, contradiction, or unrelated.
4. Persist a candidate relation with model/prompt version and evidence.
5. Apply deterministic policy:
   - temporal replacement with strong evidence may supersede;
   - ambiguous contradiction marks both as disputed;
   - non-overlapping contexts coexist;
   - low-confidence classification requires review.
6. Audit every confidence, lifecycle, and relation change.

No contradiction candidate immediately reduces both memories' confidence without a supporting relation record.

---

## 14. Recall V2

### 14.1 Pipeline

```text
query
  │
  ├─ normalize language and whitespace
  ├─ resolve scope / namespace / project / facets
  ├─ parse temporal and entity hints
  └─ optional LLM query expansion
          │
          ▼
parallel retrieval
  ├─ PostgreSQL FTS
  ├─ pgvector HNSW cosine
  └─ graph entity/traversal channel
          │
          ▼
union and candidate normalization
          │
          ▼
weighted RRF, k=60
          │
          ▼
lifecycle and evidence scoring
          │
          ▼
source/session/kind diversity
          │
          ▼
optional top-K reranker
          │
          ▼
token-budget packing
          │
          ▼
provenance attachment and recall trace
```

### 14.2 Channel Rules

- FTS is always available.
- Vector search is omitted when no query embedding can be produced.
- Graph search is omitted when no relevant entities or graph data exist.
- Missing channels do not produce an error; fusion renormalizes available weights.
- Working memory is excluded by default unless explicitly requested.
- Default tier preference remains procedural, semantic, episodic.

### 14.3 Fusion

Use weighted RRF:

```text
rrf(candidate) = Σ channel_weight / (60 + rank_in_channel)
```

The lifecycle multiplier must be bounded so it cannot erase a highly relevant candidate merely because it is new:

```text
lifecycle_score = bounded(
  state_weight
  × confidence_weight
  × strength_weight
  × evidence_weight
  × recency_weight
  × utility_weight
)
```

### 14.4 Diversity

Default diversity policy:

- maximum three candidates from one source session before filling unused capacity;
- maximum configurable candidates from one crystal or summary;
- preserve at least one high-ranked lesson when an active lesson matches;
- prevent one memory kind from consuming the entire token budget unless no alternatives exist.

### 14.5 Token Packing

Candidates are selected by marginal relevance and token cost, not rank alone. The response includes:

- selected content;
- candidate kind and memory type;
- final score and optional score breakdown;
- provenance IDs;
- confidence and lifecycle state;
- estimated tokens;
- stale/cache marker where applicable.

### 14.6 Recall Inspector

The administration UI can inspect a `memory_recall_runs` record and answer:

- which channels returned the candidate;
- its rank and score in each channel;
- how RRF and lifecycle scoring changed it;
- whether reranking moved it;
- why it was selected or rejected;
- what consumed the token budget;
- which source events support it.

---

## 15. First-Class Lessons

A lesson is a short imperative rule or operational heuristic, such as:

- “Always run token expiry tests after changing authentication.”
- “Do not edit generated migrations after they have shipped.”
- “Prefer `memory::*` tool names; do not publish underscore aliases.”

Lessons are procedural memories with a specialized lifecycle.

### 15.1 Sources

- explicit `memory::lesson_save`;
- explicit user correction;
- repeated successful procedural patterns;
- repeated failure/remediation pairs;
- crystal extraction;
- consolidation candidates.

### 15.2 Promotion Policy

- Manual lessons may become active immediately.
- Automatically extracted lessons start as candidates.
- Auto-promotion is off by default.
- Optional auto-promotion requires configurable confidence, independent evidence, and source-diversity thresholds.
- Every active lesson has at least one evidence link.

### 15.3 Reinforcement and Decay

A lesson is reinforced only by explicit confirmation, observed successful application, or independent repeated evidence. Being returned by recall is not sufficient.

Decay lowers retrieval priority; it does not erase the lesson or its evidence. Archived lessons remain inspectable and can be reactivated.

---

## 16. Crystals

A crystal is a compact, structured digest of completed work. It is distinct from a raw session summary:

- a summary records what happened in a session;
- a crystal records the stable outcomes of a completed work unit and its reusable lessons.

### 16.1 Sources

- a completed session;
- a completed connected action chain;
- an explicitly selected group of actions and sessions.

### 16.2 Contents

- narrative;
- key outcomes;
- decisions and rationale;
- files affected;
- completed and unresolved items;
- source actions and session;
- extracted or reinforced lessons;
- processing model and prompt version.

### 16.3 Retention Rule

Crystallization does not delete or prune the underlying event stream in this version. It creates a high-density episodic recall unit with complete provenance.

---

## 17. Actions and Coordination

Actions, frontier, next, leases, signals, and team memory remain inside `backplane_memory`.

The memory relationship is explicit:

- observations and memories may create action candidates;
- actions retain source observation and memory IDs;
- completed action chains may generate crystals;
- crystals may reinforce memories and lessons;
- leases provide exclusive action execution claims;
- signals provide inter-agent coordination messages.

Action state is not inferred from memory text. It is managed by the coordination contexts and audited independently.

---

## 18. Knowledge Graph and Project Profile

### 18.1 Graph Domains

The graph UI and API must distinguish:

1. **Knowledge relations** — code and concept entities such as `uses`, `imports`, `depends_on`, and `caused_by`.
2. **Lifecycle relations** — `supersedes`, `contradicts`, and `extends` between memories.
3. **Provenance relations** — `derived_from`, `summarizes`, and `supported_by`.

They may share storage abstractions but must expose the domain so callers do not confuse a code relationship with a memory lifecycle relationship.

### 18.2 Project Profile

A profile is a rebuildable project read model containing:

- top concepts;
- top files/modules;
- recurring patterns and common errors;
- active lessons;
- recent crystals and summaries;
- session and observation counts;
- a concise project summary;
- source revision and provenance.

Profiles are never the sole evidence for a durable memory. Each profile statement must link to underlying memories, summaries, or events.

---

## 19. Activity and Dashboard

### 19.1 Activity

Activity is generated by incremental projection, not by scanning only a few recent sessions at page load.

The Activity page includes:

- annual event heatmap;
- event-type distribution;
- activity by project, agent, and host;
- sessions and error trends;
- memory, lesson, crystal, action, and recall trends;
- recent live event feed;
- host capture and delivery health.

### 19.2 Overview Dashboard

The Overview page exposes operational and product health:

```text
Capture
  connected hosts
  events captured / filtered / rejected
  local spool depth and oldest age
  privacy redaction count
  upload and ACK latency

Ingestion
  accepted / duplicate / rejected events
  sequence gaps
  ingestion failures

Processing
  projection lag
  embedding queue depth
  summary and consolidation backlog
  graph/profile/lesson/crystal backlog
  dead-letter jobs

Recall
  request count
  FTS/vector/graph channel availability
  p50/p95 latency
  empty-recall rate
  token-budget utilization
  reranker usage/failures

Knowledge
  memories by type and lifecycle
  lessons by state
  crystals
  graph nodes/edges
  pending contradictions

Coordination
  actions by status
  frontier size
  active/expired leases
  unread signals
```

Estimated token reduction must be clearly labelled as an estimate. Actual LLM usage should use Backplane LLM Proxy usage records when available.

---

## 20. Replay

### 20.1 Canonical Replay Source

Replay is generated from canonical Backplane events, not from vendor-specific transcript records.

The projection produces ordered replay events:

```text
prompt
assistant response
subagent lifecycle
agent tool call
agent tool result
error
commit
session boundary
```

### 20.2 Import Architecture

A centralized Backplane server cannot safely assume that `~/.claude/projects` exists on the server. Transcript import therefore occurs through `host_agent`:

```text
operator invokes host-agent import
    │
    ▼
host-local adapter reads approved path
    │
    ▼
privacy filter and source parser
    │
    ▼
canonical event envelopes
    │
    ▼
durable spool and normal upload
    │
    ▼
Backplane event store and replay projection
```

The first import adapter targets Claude Code JSONL. Additional adapters can be added for Codex or OpenCode without changing Backplane's canonical replay model.

### 20.3 Import Safety

- reject symlinks unless explicitly enabled;
- restrict reads to operator-approved roots;
- reject paths matching secret/credential patterns;
- cap files, entries, bytes, and traversal depth;
- skip malformed entries without aborting the entire batch;
- preserve a stable source record fingerprint for idempotency;
- record imports in audit;
- apply the same privacy filtering as live capture.

### 20.4 Replay UI

- session selector;
- play/pause;
- previous/next;
- 0.5×, 1×, 2×, and 4× speed;
- time scrubber;
- event kind filters;
- tool input/output detail subject to permissions;
- links from events to derived summaries, memories, lessons, crystals, and actions.

---

## 21. MCP, REST, Resources, and Prompts

### 21.1 Naming

All tools use `memory::*`. Agentmemory-style underscore names are not introduced as a second public namespace.

Examples:

```text
memory::recall
memory::remember
memory::smart_search
memory::timeline
memory::lesson_recall
memory::crystallize
memory::replay_load
```

### 21.2 Existing Surface

Existing M1–M12 tools, resources, actions, slots, graph, facets, coordination, governance, and diagnostic surfaces remain supported.

### 21.3 New Surface

Lessons:

```text
memory::lesson_save
memory::lesson_recall
memory::lesson_strengthen
memory::lesson_promote
memory::lesson_archive
```

Crystals:

```text
memory::crystallize
memory::crystal_get
memory::crystal_list
memory::crystal_search
```

Replay and activity:

```text
memory::replay_sessions
memory::replay_load
memory::replay_import
memory::activity_summary
memory::recall_explain
```

New resources:

```text
memory://lessons/top
memory://crystals/latest
memory://activity/summary
memory://session/{id}/handoff
memory://recall/{id}/trace
```

### 21.4 Data-Backed Prompts

The three existing prompts must be implemented as real Backplane queries:

- `recall_context` performs recall, token packing, and provenance formatting.
- `session_handoff` reads session summary, decisions, files, active lessons, and open actions.
- `detect_patterns` analyses a specified project/session range and returns pattern candidates with observation citations.

A prompt must not merely tell the calling model to perform work that Backplane already has the data and functions to perform.

---

## 22. Administration Information Architecture

Backplane retains left-side navigation rather than copying agentmemory's horizontal tabs.

```text
Memory
├── Overview
├── Observe
│   ├── Activity
│   ├── Sessions
│   ├── Timeline
│   └── Replay
├── Knowledge
│   ├── Memories
│   ├── Lessons
│   ├── Crystals
│   ├── Graph
│   └── Profile
├── Coordinate
│   └── Actions
└── Operate
    ├── Recall Inspector
    ├── Audit
    └── Config
```

All pages use LiveView, server-side pagination/filtering, and PubSub updates where appropriate. No single-file viewer is introduced.

---

## 23. Oban Queues and Workers

Recommended queue isolation:

```text
memory_ingest_repair
memory_projection
memory_embedding
memory_summary
memory_consolidation
memory_graph
memory_profile
memory_lessons
memory_crystals
memory_activity
memory_retention
memory_coordination
memory_import
memory_maintenance
```

Key worker requirements:

- idempotent by subject and processing version;
- bounded input size;
- explicit timeout;
- structured retry policy;
- dead-letter visibility;
- telemetry spans and job metadata;
- no recursive hook capture from LLM calls made by Backplane itself.

---

## 24. Context Injection

Context injection remains disabled by default.

### 24.1 SessionStart

When enabled, Backplane returns a token-budgeted block containing:

1. project profile summary;
2. highest-ranked semantic memories;
3. active lessons/procedures;
4. recent relevant episodic summaries/crystals;
5. optional open actions/handoff data.

The host injects it only if returned within the configured timeout.

### 24.2 PreCompact

PreCompact recall emphasizes:

- current-session decisions;
- active files and errors;
- unresolved actions;
- relevant lessons;
- facts likely to be lost during compaction.

It must not blindly repeat the SessionStart block.

### 24.3 Budget and Provenance

- default budget: 2,000 tokens;
- each block carries compact source identifiers;
- cached fallback is labelled stale;
- no context is injected on timeout or authorization failure;
- capture continues regardless of injection outcome.

---

## 25. Security and Privacy

### 25.1 Defense Layers

1. Source adapter minimizes payloads.
2. Host privacy filter removes secrets and `<private>` blocks.
3. Local spool protects data at rest where configured.
4. Authenticated channel binds events to a registered host/client.
5. Server privacy filter repeats policy.
6. Namespace and scope are enforced on reads and writes.
7. Replay and export apply stricter permissions.
8. Governance changes are audited.

### 25.2 Suggested Client Scopes

```text
memory.read
memory.write
memory.coordinate
memory.replay
memory.admin
host_agent.capture
host_agent.recall
host_agent.import
```

The system remains single-owner rather than multi-tenant, but attribution and namespace filtering are still enforced consistently.

### 25.3 Administration Endpoint

This architecture does not create a second Memory-only authentication system. Memory administration pages must use the platform administration security model. Until application-level admin authentication is introduced, exposed deployments must bind or proxy the admin endpoint only on trusted networks.

---

## 26. Failure Modes

| Failure | Required behavior |
|---|---|
| Backplane unavailable | Host enqueues locally and retries; runtime remains usable |
| Host spool full | Apply configured policy, surface critical alert, never silently claim capture succeeded |
| Duplicate batch/event | Return `duplicate`; no duplicate event or projection effect |
| Out-of-order event | Accept, mark gap, repair projection when missing event arrives |
| Embedder down | FTS/graph recall continues |
| LLM down | Deterministic projections continue; intelligence jobs skip/retry |
| Projection worker crash | Oban retry; idempotent replay; visible failure state |
| Contradiction classifier uncertain | Create candidate/disputed relation; no automatic destructive change |
| SessionEnd missing | Fallback sweep closes stale session after policy threshold |
| Replay import malformed | Reject/skip bad entries, retain batch report, continue safe files |
| Privacy filter removes all content | Drop content observation while preserving minimal non-sensitive operational event if needed |

---

## 27. Migration Strategy

### Phase A — Contract and Telemetry

- Freeze canonical event envelope v1.
- Add host spool/ACK telemetry.
- Add persistent server idempotency constraints.
- Keep current writes and event dual-write.

### Phase B — Projection Framework

- Introduce common projection state.
- Rebuild observations and sessions from events in validation mode.
- Compare old and event-derived results.
- Add targeted repair and replay commands.

### Phase C — Read Cutover

- Move Timeline, Sessions, Activity, Replay, and session processing to canonical event-derived reads.
- Retain old columns/tables during a compatibility period.
- Remove legacy capture writes only after consistency acceptance passes.

### Phase D — Knowledge Lifecycle

- Add evidence and relation tables.
- replace unsafe contradiction heuristics;
- separate request idempotency from semantic dedup;
- migrate duplicate sources into evidence where recoverable.

### Phase E — Parity Features

- Recall V2 and Inspector;
- Lessons;
- Crystals;
- Activity Dashboard;
- Replay and host-local transcript import;
- MCP/resources/prompts/UI parity.

---

## 28. Test Strategy

### 28.1 Host-Agent Tests

- hook adapter fixtures for every supported runtime;
- privacy redaction and private-block removal;
- stable event ID/idempotency generation;
- per-session sequence allocation under concurrency;
- spool recovery after crash/restart;
- retry and partial ACK handling;
- offline capture and later upload;
- cache fallback and stale labelling;
- import path and file safety.

### 28.2 Ingestion Tests

- 100 repeated deliveries produce one durable event;
- mixed accepted/duplicate/rejected batch response;
- authorization and namespace enforcement;
- unsupported schema permanent rejection;
- server-side privacy filter catches unfiltered secrets;
- transaction failure produces no ACK and no partial event.

### 28.3 Projection Tests

- deterministic event-to-observation/session projection;
- out-of-order event repair;
- event replay produces identical read model;
- worker retry is idempotent;
- sequence gaps are visible and recoverable.

### 28.4 Memory Lifecycle Tests

- exact duplicate adds evidence rather than losing provenance;
- same tags/scope without conflicting content does not create contradiction;
- temporal replacement creates supersession;
- ambiguous conflict becomes disputed;
- all transitions produce audit entries;
- decay archives but does not erase evidence.

### 28.5 Recall Tests

- FTS-only, vector-only, and graph-only fallback paths;
- weighted RRF ordering;
- source/session diversity;
- lesson inclusion;
- token packing;
- provenance on every result;
- recall trace explains selected and rejected candidates;
- optional LLM functions fail open.

### 28.6 Product Tests

- all LiveView pages paginate and filter server-side;
- live activity updates through PubSub;
- crystal links to session/actions/lessons;
- replay ordering and controls;
- data-backed prompts return real session/memory data;
- MCP core/all visibility and client scopes.

---

## 29. Observability

Telemetry event prefix:

```text
[:backplane, :memory, ...]
[:backplane, :host_agent, :memory, ...]
```

Required dimensions:

- host/client/integration;
- project/scope/namespace;
- event type;
- worker/projector;
- recall channel;
- model/provider;
- result status;
- error class.

Never attach full prompts, tool output, memory content, or secrets to metrics labels.

---

## 30. Decision Summary

| Decision | Resolution |
|---|---|
| Automatic collection path | Runtime → `host_agent` → Backplane |
| Memory intelligence | `backplane_memory` only |
| Durable store | PostgreSQL + pgvector |
| Capture delivery | At-least-once + persistent idempotency |
| Host offline behavior | Durable bounded spool + retry |
| Captured source of truth | Immutable event stream |
| Durable knowledge source | Versioned `bpm_memories` + evidence/relations |
| Search | PostgreSQL FTS + pgvector + graph, weighted RRF `k=60` |
| LLM behavior | Optional enrichment through Backplane LLM Proxy; fail-open |
| Contradictions | Evidence-backed relation and lifecycle resolution; never tag-only heuristic |
| Lessons | First-class procedural subtype |
| Crystals | First-class completed-work episodic digest |
| Actions | Remain in Backplane Memory coordination |
| Replay import | Host-local adapter → canonical events → Backplane |
| UI | Phoenix LiveView left navigation |
| Tool namespace | `memory::*` only |
| Context injection | Off by default, token-budgeted, fail-open |

