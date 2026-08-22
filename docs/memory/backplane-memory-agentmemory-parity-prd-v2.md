# Backplane Memory — Agentmemory-Parity Optimization PRD (v2)

Status: Proposed  
Owner: Backplane  
Repository: `gsmlg-opt/backplane`  
Scope: Backplane-only; automatic collection through `host_agent`  
Architecture: `backplane-memory-agentmemory-parity-design-v2.md`  
Date: 2026-07-30

## 1. Executive Summary

Backplane Memory already provides a central self-hosted memory foundation, PostgreSQL/pgvector storage, hybrid recall, observation/session capture, graph/profile/coordination modules, MCP/REST surfaces, and a host-agent integration path.

This PRD defines the next optimization program: bring Backplane Memory to functional parity with the visible and useful capabilities of agentmemory while retaining Backplane's architecture.

The required system boundary is fixed:

```text
Agent runtime
    → host_agent captures, filters, normalizes, spools, and transports
    → Backplane durably accepts the event
    → backplane_memory processes, stores, indexes, consolidates, recalls, and governs
```

The program does not introduce a second memory system in `host_agent`, and it does not move Backplane Memory features to another repository.

The target product includes:

- Overview Dashboard;
- Graph;
- Memories;
- Timeline;
- Sessions;
- Lessons;
- Actions;
- Crystals;
- Audit;
- Activity;
- Profile;
- Replay;
- Backplane-specific Config and Recall Inspector pages.

---

## 2. Baseline and Relationship to Existing Documents

This PRD builds on:

- `docs/memory-design.md`
- `docs/memory-prd.md`
- `docs/memory-agentmemory-prd.md`
- `docs/host-agent-design.md`
- `docs/host-agent-memory-design-final.md`

M1–M12 remain the baseline. This PRD defines M13–M18 and intentionally changes four earlier scope decisions:

| Capability | Previous status | v2 status |
|---|---|---|
| Lessons | Not first-class | Required |
| Activity | No independent read model/page | Required |
| Crystallization | Dropped | Required after lifecycle hardening |
| Replay | Deferred indefinitely | Required after event-store cutover |

All new implementation remains in the existing Backplane umbrella:

- `apps/backplane_memory` — domain logic and processing;
- `apps/backplane_host_agent` — host registration/channel support and edge integration contract;
- host-agent runtime/integration code — local capture, privacy, spool, transport;
- `apps/backplane_api` — host-agent, REST, and MCP transport;
- `apps/backplane_admin` — LiveView administration.

---

## 3. Product Vision

> Backplane Memory is the central, durable memory and coordination system for all connected agents. Agents should resume work with the right context, preserve evidence across sessions, learn reusable lessons, inspect completed work, coordinate actions, and explain every recalled item without depending on a vendor-specific agent runtime.

Backplane should match agentmemory's useful product coverage while improving on:

- durable centralized persistence;
- offline capture reliability;
- PostgreSQL-backed idempotency;
- evidence and provenance;
- contradiction safety;
- recall explainability;
- Phoenix/OTP supervision and background processing;
- integration with Backplane's LLM Proxy, MCP security, usage tracking, and administration UI.

---

## 4. Problem Statement

The current Memory implementation and parity plan leave several gaps:

1. Capture reliability is not yet specified end to end as a durable host spool plus durable server ACK protocol.
2. Transport idempotency, content deduplication, and semantic evidence are not sufficiently separated.
3. The current contradiction heuristic can treat equal scope/tags as conflict without proving semantic contradiction.
4. Recall components exist or are planned, but there is no unified recall trace that explains FTS, vector, graph, lifecycle, reranking, and token selection.
5. Lessons are not a first-class product object with candidate, active, reinforcement, and decay lifecycle.
6. Completed work lacks a crystal/digest object linked to sessions, actions, files, decisions, and lessons.
7. Activity is not a durable aggregate read model.
8. Replay is not scheduled as a deliverable and centralized Backplane requires a host-local import design.
9. Existing MCP prompts must become data-backed operations rather than generic prompt templates.
10. The administration experience does not yet cover all parity features or host capture health.

---

## 5. Goals

### G1 — Reliable Automatic Capture

Every supported hook event can be accepted locally while Backplane is offline, retried, durably acknowledged, and processed exactly once in effect.

### G2 — Centralized Memory Intelligence

All compression, embedding, consolidation, graph extraction, lessons, crystals, lifecycle, retention, and recall run in `backplane_memory`.

### G3 — Safe Durable Knowledge

Every durable memory has provenance and evidence. Evolution uses versioning and relations. Contradiction handling never silently destroys history.

### G4 — Explainable High-Quality Recall

Recall combines FTS, vector, and graph signals; applies diversity, lifecycle, optional reranking, and token packing; and stores a trace explaining every result.

### G5 — Agentmemory Product Coverage

Backplane provides product equivalents for Dashboard, Graph, Memories, Timeline, Sessions, Lessons, Actions, Crystals, Audit, Activity, Profile, and Replay.

### G6 — Graceful Degradation

Capture, FTS recall, sessions, activity, actions, audit, and replay remain usable when embedding or LLM providers are unavailable.

### G7 — Operational Visibility

Operators can identify whether missing memory originated in a hook, host privacy filter, spool, channel, ingest transaction, projection, embedding, consolidation, or recall stage.

---

## 6. Non-Goals

This program does not include:

- a second authoritative memory database in `host_agent`;
- agentmemory wire compatibility or iii-engine compatibility;
- agentmemory's SQLite/KV implementation;
- a new cross-project repository split;
- vision/image memory;
- mesh/P2P memory synchronization;
- filesystem crawling or watchers;
- Obsidian export;
- MEMORY.md synchronization;
- Git-backed memory snapshots;
- routines, checkpoints, sentinels, or sketches;
- multi-tenant security isolation beyond the existing single-owner model;
- enabling context injection by default;
- making tool count a success metric by itself.

---

## 7. Personas

| Persona | Need |
|---|---|
| Agent runtime | Capture work automatically and receive relevant memory without blocking normal operation |
| Host operator | Know local capture is private, durable, bounded, and recoverable across outages |
| Backplane operator | Inspect processing, search quality, memory lifecycle, actions, and failures |
| Agent developer | Integrate through stable hooks, REST, MCP, resources, and prompts |
| Reviewer | Trace a memory or lesson back to the exact session/events that produced it |

---

## 8. Primary User Journeys

### 8.1 Resume a Project

1. A runtime starts a session.
2. `host_agent` captures `SessionStart` and registers it with Backplane.
3. If injection is enabled, Backplane returns a token-budgeted project profile, memories, lessons, and recent episodic context.
4. The runtime begins even if recall times out.
5. Subsequent events are captured asynchronously through the local spool.

### 8.2 Work Offline and Synchronize Later

1. Backplane becomes unreachable.
2. Hooks continue appending privacy-filtered events to the host spool.
3. The runtime is not blocked.
4. When the channel reconnects, events upload in batches.
5. Backplane returns durable per-event ACKs.
6. Duplicate retries do not create duplicate events or projections.

### 8.3 Recall and Explain

1. An agent calls `memory::recall` or `memory::smart_search`.
2. Backplane executes FTS, vector, and graph retrieval where available.
3. Results are fused, diversified, reranked where enabled, and packed into the token budget.
4. Every result contains provenance.
5. An operator opens Recall Inspector to see why each candidate was selected or rejected.

### 8.4 Learn a Lesson

1. A user explicitly saves a rule or corrects the agent.
2. Backplane creates an active manual lesson or a candidate automatic lesson.
3. Evidence is linked to source events/session/crystal.
4. Repeated verified use reinforces it.
5. It appears in future relevant SessionStart context and recall.

### 8.5 Crystallize Completed Work

1. A session or connected action chain completes.
2. Backplane gathers its events, summary, actions, files, and decisions.
3. It creates a crystal containing durable outcomes and lesson candidates.
4. The crystal is searchable as episodic memory.
5. Raw events remain retained and traceable.

### 8.6 Replay a Historical Session

1. An operator selects a native session or starts a host-local Claude Code JSONL import.
2. `host_agent` safely reads, filters, normalizes, and uploads events.
3. Backplane projects a canonical timeline.
4. The operator scrubs prompts, tool calls/results, errors, commits, and boundaries.
5. Replay events link to derived memories, lessons, crystals, and actions.

---

## 9. Scope and Capability Matrix

| Product capability | Required v2 behavior |
|---|---|
| Dashboard | Product + operational health including hosts, spool, ingest, processing, recall, knowledge, and coordination |
| Graph | Knowledge, lifecycle, and provenance relations with query and visual inspection |
| Memories | Search, inspect, evidence, versions, relations, lifecycle, forget/governance |
| Timeline | Ordered event/observation stream by session with filters and raw/compressed views |
| Sessions | Lifecycle, summary, files, tools, processing state, actions, lessons, crystal links |
| Lessons | Candidate/active lifecycle, evidence, reinforcement, decay, recall, promotion/archive |
| Actions | Existing actions, edges, frontier, next, leases, signals, and source links |
| Crystals | Completed-work digest from session/action chain with outcomes, decisions, files, and lessons |
| Audit | All governance and lifecycle operations with actor, targets, details, and correlation |
| Activity | Durable daily aggregates, heatmap, breakdowns, trends, and live feed |
| Profile | Rebuildable project intelligence with source links |
| Replay | Canonical event playback and host-local Claude JSONL import |
| Config | All memory, host capture, recall, lifecycle, and feature settings |
| Recall Inspector | Per-query channel ranks, scores, reranking, token selection, and provenance |

---

## 10. Functional Requirements

### 10.1 Capture and Host-Agent Requirements

#### CAP-001 — Automatic Capture Path

All supported automatic runtime hooks must flow through `host_agent` before reaching Backplane.

**Acceptance:** No hook adapter writes directly to PostgreSQL or performs memory intelligence.

#### CAP-002 — Hook Coverage

The system must support the ten hook classes already defined by the Backplane parity plan:

- SessionStart;
- UserPromptSubmit;
- PostToolUse;
- PostToolUseFailure;
- PreCompact;
- SubagentStart;
- SubagentStop;
- Stop;
- SessionEnd;
- PostCommit.

**Acceptance:** Integration fixtures produce the expected canonical event type for each hook.

#### CAP-003 — Local Privacy Filter

Every captured payload must pass host-local privacy filtering before it is written to the spool.

**Acceptance:** API keys, recognized secret formats, and `<private>` blocks do not appear in spool fixtures or Backplane records.

#### CAP-004 — Canonical Event Envelope

`host_agent` must normalize source-specific hook payloads into the versioned envelope defined by the architecture document.

**Acceptance:** Every accepted event contains stable provenance, session sequence, event type, timestamps, idempotency key, hash, privacy metadata, and payload.

#### CAP-005 — Durable Local Spool

Capture must append to a disk-backed spool before reporting local success.

**Acceptance:** Pending events survive process and machine restart tests.

#### CAP-006 — Offline Operation

Backplane unavailability must not block non-synchronous hooks while the spool has capacity.

**Acceptance:** A 24-hour simulated outage followed by reconnection delivers all accepted local events within configured capacity.

#### CAP-007 — Batching and Partial ACK

Uploader batches must support per-event accepted, duplicate, permanent rejection, and retryable failure results.

**Acceptance:** Mixed-result integration test leaves only retryable/unacknowledged entries in the spool.

#### CAP-008 — Bounded Recall Requests

SessionStart and PreCompact may synchronously request context, subject to strict timeout and fail-open behavior.

**Acceptance:** A timeout returns control to the runtime without context and still spools the lifecycle event.

#### CAP-009 — Recall Cache

`host_agent` may serve a bounded, stale-labelled cached context only when Backplane is unavailable.

**Acceptance:** Cached context includes source revision, age, and stale marker; no host-side semantic search is executed.

#### CAP-010 — Capture Telemetry

`host_agent` must expose connection state, spool depth/bytes, oldest event age, captured/redacted/rejected counts, retry count, dead letters, upload latency, and ACK latency.

**Acceptance:** Dashboard receives these metrics for each connected host.

---

### 10.2 Ingestion and Event Requirements

#### ING-001 — Authenticated Host Ingestion

Backplane must bind every batch to an authenticated host/client identity and authorized scope.

**Acceptance:** A host cannot claim another host ID or upload outside its allowed capture permissions.

#### ING-002 — Server Privacy Filter

Backplane must apply privacy filtering again before durable storage.

**Acceptance:** A deliberately unfiltered secret sent by a test client is rejected or redacted before persistence.

#### ING-003 — Durable ACK Boundary

Backplane may return `accepted` only after the event is committed to PostgreSQL.

**Acceptance:** Forced transaction rollback produces no accepted ACK.

#### ING-004 — Persistent Idempotency

Event ID and idempotency key constraints must prevent duplicate effects across retries, process restarts, and multiple Backplane nodes.

**Acceptance:** Delivering the same event 100 times creates one durable event and one observation effect.

#### ING-005 — Immutable Captured Events

Accepted captured events must not be overwritten by compressed or enriched data.

**Acceptance:** Raw canonical event remains queryable after all projections complete.

#### ING-006 — Schema Compatibility

Backplane must support explicit event schema upcasters and reject unsupported future versions as permanent errors.

**Acceptance:** Supported old-version fixture is upcast; unsupported future version is permanently rejected.

#### ING-007 — Out-of-Order Events

Backplane must accept out-of-order session events, record gaps, and repair affected projections when missing events arrive.

**Acceptance:** A shuffled event fixture produces the same final session/timeline as ordered input.

#### ING-008 — Projection State

Every asynchronous projection must expose pending/running/complete/skipped/failed/dead-letter status and processing version.

**Acceptance:** Session detail shows the processing state for summary, embeddings, graph, profile, lessons, and crystal.

#### ING-009 — Rebuildability

Observations, sessions, activity, replay timelines, profiles, and graph projections must be rebuildable from authoritative inputs.

**Acceptance:** Rebuild task reproduces fixture read models deterministically.

---

### 10.3 Sessions and Timeline

#### SES-001 — Session Lifecycle

Backplane must maintain active, stopped, completed, abandoned/stale, and processing states from canonical events.

**Acceptance:** Session state transitions are deterministic and audit-visible.

#### SES-002 — Session Detail

Session detail must include:

- project, host, agent, integration, model where known;
- start/end/duration;
- first prompt and summary;
- observation/event count;
- tool invocation and event-type breakdown;
- files and commits;
- source/child sessions;
- actions, lessons, memories, and crystal links;
- processing status and failures.

**Acceptance:** LiveView and REST return matching fixture information.

#### SES-003 — Timeline

Timeline must show ordered canonical events and observation projections, filterable by event type, tool, importance, error status, file, and time range.

**Acceptance:** Pagination is stable and does not load an unbounded session into the browser.

#### SES-004 — Raw and Enriched Views

Authorized operators may inspect privacy-filtered raw event data and enriched/compressed observation data separately.

**Acceptance:** Enrichment never replaces or masquerades as raw source data.

#### SES-005 — Fallback Session Closure

A periodic worker must identify stale sessions lacking SessionEnd and close/process them according to configuration.

**Acceptance:** At least 95% of closed or stale sessions receive a summary within four hours.

---

### 10.4 Durable Memories and Evidence

#### MEM-001 — Unified Remember Path

Explicit MCP, REST, and internal remember calls must use the same context, privacy, namespace, evidence, idempotency, embedding, and audit behavior.

**Acceptance:** Equivalent calls through all surfaces create equivalent records.

#### MEM-002 — Request Idempotency versus Semantic Dedup

The implementation must treat request idempotency and semantic deduplication as separate operations.

**Acceptance:** A network retry creates no duplicate; an independent second source for the same fact creates evidence and reinforcement.

#### MEM-003 — Evidence Records

Every auto-derived semantic/procedural memory and every active automatic lesson must link to one or more source events, observations, summaries, or crystals.

**Acceptance:** `memory::verify` returns a complete evidence chain for derived fixture memories.

#### MEM-004 — Versioned Evolution

Content evolution must create a new version or related memory rather than silently overwriting historical content.

**Acceptance:** Superseded memory remains inspectable and linked to its successor.

#### MEM-005 — Lifecycle States

Memories must support active, disputed, superseded, archived, and tombstoned states, plus candidate state where appropriate.

**Acceptance:** Recall excludes or annotates states according to caller filters and policy.

#### MEM-006 — Safe Contradiction Detection

Equal scope/tags alone must never be sufficient to declare contradiction.

**Acceptance:** Two compatible memories sharing scope/tags do not lose confidence or gain a contradiction relation.

#### MEM-007 — Contradiction Relations

Potential conflicts must create evidence-backed relation candidates and deterministic resolution outcomes.

**Acceptance:** Ambiguous conflict becomes disputed; temporal update can become supersession; all changes are audited.

#### MEM-008 — Access versus Truth Signals

Access count, evidence count, source diversity, lesson application count, and contradiction count must be tracked separately.

**Acceptance:** Recall access alone does not increase factual confidence.

#### MEM-009 — Retention

Decay and retention may lower retrieval priority or archive memory but must not automatically erase captured evidence.

**Acceptance:** Archived memory and provenance remain inspectable; hard delete remains disabled by default.

---

### 10.5 Recall V2

#### RCL-001 — Query Planning

Recall must normalize query, resolve scope/namespace/project/facets, and optionally extract temporal/entity hints before retrieval.

**Acceptance:** Debug/trace representation shows the resolved query plan.

#### RCL-002 — Parallel Retrieval Channels

Recall must execute available FTS, vector, and graph retrieval channels concurrently.

**Acceptance:** Channel failure is isolated and remaining channels still return results.

#### RCL-003 — Weighted RRF

Candidates must be fused using weighted RRF with default `k = 60`.

**Acceptance:** Deterministic fixture produces expected fused order.

#### RCL-004 — Candidate Types

Recall must normalize memories, summaries, crystals, lessons, and optionally working observations into a common candidate form.

**Acceptance:** One query can return multiple kinds with explicit kind/type fields.

#### RCL-005 — Lifecycle Scoring

Post-fusion scoring must incorporate bounded lifecycle, confidence, evidence, utility, and recency signals.

**Acceptance:** New relevant memory is not eliminated by age/access multipliers; disputed items are annotated or penalized.

#### RCL-006 — Diversity

Recall must prevent one source session, crystal, or candidate kind from monopolizing results when comparable alternatives exist.

**Acceptance:** Fixture with many near-duplicates from one session returns diversified top results.

#### RCL-007 — Optional Reranking

When enabled and configured, top-K candidates may be reranked through the Backplane LLM Proxy. Failure must preserve pre-rerank results.

**Acceptance:** Provider failure does not fail recall.

#### RCL-008 — Token-Budget Packing

Recall must pack selected candidates within the caller's token budget and return token estimates.

**Acceptance:** Returned context never exceeds configured budget within tokenizer tolerance.

#### RCL-009 — Provenance

Every selected result must include source identifiers sufficient for verification.

**Acceptance:** Provenance coverage is 100% for returned derived records.

#### RCL-010 — Recall Runs

Backplane must persist recall runs and per-candidate score/rank/selection data, subject to retention and privacy policy.

**Acceptance:** Recall Inspector can explain selected and rejected candidates.

#### RCL-011 — Fallback

When embedder and LLM are unavailable, FTS-only recall must continue without error.

**Acceptance:** Provider outage integration test returns FTS results.

#### RCL-012 — Context Injection

When enabled, SessionStart context must combine profile, semantic memory, active lessons/procedures, and relevant episodic context within budget.

**Acceptance:** Injection is off by default, bounded, provenance-labelled, and fail-open.

---

### 10.6 Graph and Profile

#### GRP-001 — Graph Domains

Graph records and APIs must distinguish knowledge, lifecycle, and provenance relation domains.

**Acceptance:** UI filters each domain and does not conflate relation semantics.

#### GRP-002 — Knowledge Extraction

Configured session processing may extract entities and edges with source observation IDs and processing version.

**Acceptance:** Reprocessing the same session/version is idempotent.

#### GRP-003 — Graph Recall

Relevant graph matches must participate as a distinct Recall V2 channel.

**Acceptance:** Recall trace records graph rank/score where used.

#### GRP-004 — Project Profile

Profiles must include concepts, files, patterns/errors, active lessons, recent crystals/summaries, counts, and summary.

**Acceptance:** Profile links statements to source records and is rebuildable.

#### GRP-005 — Profile Injection

Project profile may be included in SessionStart context when injection is enabled.

**Acceptance:** Stale profile is labelled with revision/time and does not prevent session start.

---

### 10.7 Lessons

#### LES-001 — First-Class Lesson Model

A lesson must be represented as a procedural `bpm_memories` record plus lesson-specific lifecycle state.

**Acceptance:** Lesson is searchable through general recall and manageable through lesson APIs.

#### LES-002 — Lesson States

Lessons must support candidate, active, disputed, superseded, and archived states.

**Acceptance:** State transitions are validated and audited.

#### LES-003 — Explicit Save

`memory::lesson_save` must create an active lesson with actor and source context.

**Acceptance:** Manual lesson is immediately available to relevant recall unless filters exclude it.

#### LES-004 — Automatic Candidates

Backplane may generate candidates from corrections, repeated error/remediation patterns, consolidation, and crystals.

**Acceptance:** Automatic candidates do not become active by default.

#### LES-005 — Promotion

Operators/agents with permission may promote a candidate; optional auto-promotion is separately configurable and threshold-gated.

**Acceptance:** Promotion requires evidence and records promoter/reason.

#### LES-006 — Reinforcement

`memory::lesson_strengthen` and observed verified application may increment reinforcement and update last-applied time.

**Acceptance:** Merely returning a lesson in recall does not reinforce it.

#### LES-007 — Decay and Archive

Inactive lessons may decay in retrieval priority and eventually archive according to configuration.

**Acceptance:** Archived lesson retains evidence and can be reactivated.

#### LES-008 — Lesson UI

The Lessons page must show rule, state, confidence, reinforcement, contradictions, scope/project, source, last use, and evidence.

**Acceptance:** Operators can inspect, promote, dispute, archive, and reactivate with audit records.

---

### 10.8 Actions and Coordination

#### COORD-001 — Existing Scope Retained

Team memory, actions, action edges, frontier, next, leases, and signals remain part of `backplane_memory`.

**Acceptance:** No feature is moved to another repository or service.

#### COORD-002 — Source Provenance

Actions created from memory processing must retain source observation, memory, session, lesson, or crystal IDs.

**Acceptance:** Action detail traces back to its origin.

#### COORD-003 — Frontier Correctness

Frontier returns only actions without unresolved required dependencies and respects project/scope filters.

**Acceptance:** Concurrent dependency update tests produce correct frontier.

#### COORD-004 — Lease Safety

Lease acquisition is atomic, expiry is cluster-safe, and lease state is visible in Action detail and Dashboard.

**Acceptance:** Concurrent acquisition grants exactly one active lease.

#### COORD-005 — Crystal Integration

Completed connected action chains may be crystallized.

**Acceptance:** Crystal links all source actions and does not alter action history.

---

### 10.9 Crystals

#### CRY-001 — Crystal Model

Backplane must store a structured completed-work digest linked to a searchable episodic memory.

**Acceptance:** Crystal is returned by crystal search and general episodic recall.

#### CRY-002 — Session Crystallization

A closed session may produce one idempotent crystal per processing version after the event grace period.

**Acceptance:** Re-running the worker does not duplicate the crystal.

#### CRY-003 — Action-Chain Crystallization

An explicitly selected or completed connected action chain may produce a crystal.

**Acceptance:** Only completed/cancelled terminal actions are included unless operator explicitly overrides.

#### CRY-004 — Structured Output

Crystal contains narrative, outcomes, decisions, files, unresolved items, source IDs, and processing metadata.

**Acceptance:** Missing/invalid LLM fields degrade to deterministic data rather than corrupting the record.

#### CRY-005 — Lesson Candidates

Crystallization may create or reinforce lesson candidates through a join relation.

**Acceptance:** Crystal never stores ambiguous strings that sometimes mean lesson IDs and sometimes lesson text.

#### CRY-006 — Raw Retention

Crystallization must not prune raw events in this version.

**Acceptance:** Full source replay remains available after crystal creation.

#### CRY-007 — Crystal UI

The Crystals page must expose source session/actions, outcomes, decisions, files, lessons, model/version, and evidence.

**Acceptance:** Links navigate to source and derived objects.

---

### 10.10 Audit and Governance

#### AUD-001 — Audit Coverage

Audit must cover:

- remember/forget/delete;
- hard-delete attempts;
- lifecycle and confidence changes;
- relation confirmation/rejection;
- lesson promotion/reinforcement/archive;
- crystallization;
- replay imports;
- action/lease/signal governance;
- projection rebuild/heal;
- export;
- configuration changes affecting memory behavior.

**Acceptance:** All fixture operations create the expected audit entry.

#### AUD-002 — Correlation

Audit entries must include actor, targets, request/correlation ID, host/client where relevant, operation, result, and structured details.

**Acceptance:** An event can be followed from host batch to memory transition via correlation IDs.

#### AUD-003 — Governance Delete

Soft delete remains default. Hard delete requires explicit setting and privileged scope.

**Acceptance:** Hard delete is blocked and audited when disabled.

#### AUD-004 — Verify

`memory::verify` must return provenance, evidence, lifecycle relations, processing metadata, and relevant audit transitions.

**Acceptance:** Reviewer can reproduce why a memory is active.

---

### 10.11 Activity and Dashboard

#### ACT-001 — Durable Daily Aggregates

Activity metrics must be incrementally projected by date, project, agent, host, and event type.

**Acceptance:** Aggregate fixture equals direct event-count calculation.

#### ACT-002 — Historical Heatmap

Activity page must show a complete configured historical window rather than sampling only recent sessions.

**Acceptance:** Events older than the most recent sessions appear correctly.

#### ACT-003 — Breakdown and Trends

Page must show event types, errors, sessions, recalls, memories, lessons, crystals, actions, projects, agents, and hosts.

**Acceptance:** Filters update through server-side queries.

#### ACT-004 — Live Feed

Recent activity must update via PubSub with reconnect-safe historical fetch.

**Acceptance:** New event appears live; reload restores it from PostgreSQL.

#### ACT-005 — Host Capture Dashboard

Overview must show connected hosts, last heartbeat, integration version, spool depth/age, redaction counts, retry/ACK latency, and dead letters.

**Acceptance:** Simulated offline host becomes visibly degraded.

#### ACT-006 — Processing Dashboard

Overview must show projection lag, queue depth, failures, embedding/consolidation status, graph/profile/lesson/crystal backlog, and circuit breaker state.

**Acceptance:** Failed worker is visible with actionable error/detail link.

#### ACT-007 — Recall Dashboard

Overview must show recall count, latency, channel availability, empty rate, budget utilization, reranker use, and fallback rate.

**Acceptance:** Metrics distinguish estimated token reduction from actual LLM Proxy usage.

---

### 10.12 Replay

#### RPL-001 — Canonical Timeline

Replay must be generated from canonical events and remain independent of source transcript format.

**Acceptance:** Native and imported equivalent sessions produce the same replay kinds/order.

#### RPL-002 — Playback Controls

UI supports play/pause, previous/next, scrubber, event selection, keyboard controls, and speeds 0.5×/1×/2×/4×.

**Acceptance:** Browser tests cover controls and cursor progression.

#### RPL-003 — Event Detail

Authorized operators may inspect prompts, privacy-filtered tool input/output, errors, commits, and timestamps.

**Acceptance:** Sensitive fields remain redacted and permissions are enforced.

#### RPL-004 — Host-Local Import

Claude Code JSONL import must execute through `host_agent`, not by assuming the centralized Backplane server can read the host path.

**Acceptance:** Import succeeds from an approved host directory when Backplane is remote.

#### RPL-005 — Import Safety

Import must enforce approved roots, symlink policy, path-secret rejection, file/byte/entry limits, malformed-line tolerance, privacy filtering, and batch audit.

**Acceptance:** Security fixtures are rejected without reading unauthorized files.

#### RPL-006 — Import Idempotency

Re-importing the same transcript must not duplicate sessions/events/lessons/crystals.

**Acceptance:** Second import reports duplicate/unchanged entries.

#### RPL-007 — Derived Links

Replay events must link to derived summary, memories, graph entities, lessons, crystals, and actions where relationships exist.

**Acceptance:** Fixture link graph is navigable in LiveView.

---

### 10.13 MCP, REST, Resources, Prompts, and Skills

#### API-001 — Namespace

All MCP tools use `memory::*`. No parallel underscore namespace is added.

**Acceptance:** Tool listing and docs expose canonical names consistently.

#### API-002 — Functional Parity

Tool count is not a release KPI. Every product capability must have the minimal complete MCP/REST surface required for automation and UI.

**Acceptance:** Capability matrix maps each operation to Context, REST, MCP where appropriate, UI, and tests.

#### API-003 — Core versus Extended Visibility

Existing `memory.tools=core|all` behavior remains. Read-heavy common tools stay core; governance, import, and advanced coordination stay extended.

**Acceptance:** Client tool listing respects setting and scopes.

#### API-004 — New Lesson Tools

Required:

```text
memory::lesson_save
memory::lesson_recall
memory::lesson_strengthen
memory::lesson_promote
memory::lesson_archive
```

#### API-005 — New Crystal Tools

Required:

```text
memory::crystallize
memory::crystal_get
memory::crystal_list
memory::crystal_search
```

#### API-006 — New Replay/Activity/Explain Tools

Required:

```text
memory::replay_sessions
memory::replay_load
memory::replay_import
memory::activity_summary
memory::recall_explain
```

#### API-007 — New Resources

Required:

```text
memory://lessons/top
memory://crystals/latest
memory://activity/summary
memory://session/{id}/handoff
memory://recall/{id}/trace
```

#### API-008 — Data-Backed Prompts

`recall_context`, `session_handoff`, and `detect_patterns` must query actual Backplane data and return source-linked results.

**Acceptance:** Prompt tests fail if only a generic instruction is returned.

#### API-009 — Skill Hub

Existing `/recall`, `/remember`, `/session-history`, and `/forget` remain; add `/lessons`, `/recap`, `/handoff`, and `/activity` through the Backplane Skill Hub.

**Acceptance:** Generated/reference skill metadata matches live tools.

---

### 10.14 Administration UI

#### UI-001 — Left Navigation

Memory navigation must use Backplane's existing left-side pattern:

```text
Overview
Observe: Activity, Sessions, Timeline, Replay
Knowledge: Memories, Lessons, Crystals, Graph, Profile
Coordinate: Actions
Operate: Recall Inspector, Audit, Config
```

#### UI-002 — LiveView Architecture

Pages use Phoenix LiveView, server-side pagination and filtering, and PubSub live updates where useful.

**Acceptance:** No unbounded all-record fetch or single-file viewer implementation.

#### UI-003 — Cross-Linking

Memory entities must link across evidence and derived artifacts.

**Acceptance:** From a memory an operator can navigate to evidence/session/replay; from a session to summary/actions/lessons/crystal; from recall trace to selected candidates.

#### UI-004 — Processing and Error States

Pages must distinguish empty, loading, disabled feature, skipped due to missing provider, pending, failed, and complete states.

**Acceptance:** A provider-disabled graph does not appear as unexplained zero data.

#### UI-005 — Repair Actions

Authorized operators may retry/rebuild failed projections, re-embed, rebuild profile/graph/activity, rerun summary/crystal, and resolve relation/lesson candidates.

**Acceptance:** Every repair is idempotent and audited.

---

### 10.15 Security and Privacy

#### SEC-001 — Client Scopes

Introduce or map permissions for:

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

**Acceptance:** Replay/import/governance are unavailable to read-only clients.

#### SEC-002 — Namespace Enforcement

Private/shared/team namespaces must be enforced consistently in Context, REST, MCP, recall, resources, prompts, UI, and direct SQL query helpers.

**Acceptance:** Cross-namespace leakage tests pass.

#### SEC-003 — Sensitive Telemetry

No memory content, prompt, tool output, secret, or raw payload may be placed in metric labels or ordinary logs.

**Acceptance:** log-capture tests show IDs and classifications only.

#### SEC-004 — Admin Exposure

This PRD does not add a separate Memory-only auth stack. Memory UI uses the platform administration security model; deployment docs must warn that the current admin endpoint belongs on a trusted network until application-level authentication exists.

**Acceptance:** release docs include deployment requirement and reverse-proxy guidance.

---

## 11. Non-Functional Requirements

### NFR-001 — Capture Availability

Non-synchronous hooks must remain usable during Backplane outage while local spool capacity remains.

### NFR-002 — Local Enqueue Latency

Privacy-filtered local enqueue p95 must be below 50 ms on target hosts. Hook wrappers must perform no remote wait for asynchronous hooks.

### NFR-003 — Context Injection Latency

SessionStart injection must obey a 1,500 ms total timeout. Registration-only path should target 800 ms or less. Timeout is fail-open.

### NFR-004 — Server Ingest Throughput

A single Backplane deployment must sustain at least 500 events/second in batched ingestion on the reference development environment without dropping accepted events.

### NFR-005 — Recall Latency

- Retrieval/fusion p95 below 300 ms for top-10, excluding query embedding and optional LLM expansion/reranking.
- End-to-end no-reranker p95 below 800 ms on the reference environment.
- Optional LLM stages have separate timeout and metrics.

### NFR-006 — Recall Availability

FTS-only recall must remain available when embedding and LLM services are down.

### NFR-007 — Projection Lag

Under normal load, deterministic observation/session/activity projections should reach p95 lag below 10 seconds. LLM-dependent jobs have separately reported SLAs.

### NFR-008 — Consolidation Coverage

At least 95% of eligible closed sessions must have a summary within four hours.

### NFR-009 — Provenance

100% of returned auto-derived memories, lessons, and crystals must include evidence/provenance.

### NFR-010 — Idempotency

Retrying any host event, worker job, crystallization request, or transcript import must not duplicate durable effects.

### NFR-011 — Storage Safety

No automatic decay, consolidation, or crystallization operation may hard-delete captured source events.

### NFR-012 — Horizontal Safety

Ingestion, leases, projection workers, and consolidation must remain correct with multiple Backplane nodes sharing PostgreSQL.

### NFR-013 — Bounded Queries

Every list/search/replay/admin endpoint must use explicit limits and stable pagination.

### NFR-014 — Observability

Every pipeline stage exposes counts, latency, status, and error class through telemetry without exposing content.

---

## 12. Configuration

Existing `memory.*` settings remain. Add:

| Setting | Type | Default | Purpose |
|---|---|---:|---|
| `memory.host_batch_max_events` | integer | 100 | Maximum event count per upload batch |
| `memory.host_batch_max_bytes` | integer | 524288 | Maximum uncompressed batch bytes |
| `memory.host_spool_max_bytes` | integer | implementation default | Local spool capacity |
| `memory.host_spool_max_age_days` | integer | 30 | Retention warning/policy for unacked events |
| `memory.event_gap_grace_seconds` | integer | 60 | Grace before final session processing |
| `memory.recall_trace_enabled` | boolean | true | Persist recall trace records |
| `memory.recall_trace_retention_days` | integer | 30 | Recall trace retention |
| `memory.recall_max_per_session` | integer | 3 | Diversity limit |
| `memory.lesson_auto_extract` | boolean | true when LLM configured | Produce lesson candidates |
| `memory.lesson_auto_promote` | boolean | false | Promote candidates automatically |
| `memory.lesson_promote_confidence` | float | 0.85 | Optional promotion threshold |
| `memory.lesson_promote_sources` | integer | 2 | Minimum independent sources |
| `memory.lesson_decay_enabled` | boolean | true | Apply lesson utility decay |
| `memory.crystals_enabled` | boolean | true when LLM configured | Generate crystals |
| `memory.crystal_session_enabled` | boolean | true | Session crystallization |
| `memory.crystal_action_enabled` | boolean | true | Action-chain crystallization |
| `memory.activity_retention_days` | integer | 730 | Daily aggregate retention |
| `memory.replay_enabled` | boolean | true | Replay read surface |
| `memory.replay_import_enabled` | boolean | false | Host-local transcript import |
| `memory.replay_import_max_files` | integer | 200 | Import safety cap |
| `memory.replay_import_max_bytes` | integer | 1073741824 | Import safety cap |

All configuration changes are audited and visible in Config UI.

---

## 13. Milestones

### M13 — Host-Agent Capture Reliability and Contract

Deliverables:

- canonical event envelope v1;
- adapter mapping for supported hooks;
- local privacy filtering contract;
- durable spool behavior;
- batching, partial ACK, retry, reconnect, dead letters;
- persistent server idempotency;
- host capture telemetry and Dashboard section;
- contract/integration test harness.

Exit criteria:

- 24-hour simulated outage loses no locally accepted events within capacity;
- 100 duplicate deliveries create one event effect;
- no asynchronous hook waits for Backplane;
- privacy fixtures pass on host and server.

### M14 — Event Store Cutover and Correctness Hardening

Deliverables:

- immutable captured-event source of truth;
- common projection state/rebuild framework;
- observations/sessions/activity validation projections;
- out-of-order repair;
- evidence records;
- request idempotency separated from semantic dedup;
- contradiction pipeline replacing scope/tag heuristic;
- lifecycle and relation audit expansion;
- data-backed MCP prompts.

Exit criteria:

- event replay reproduces session/timeline fixtures;
- same-content independent source adds evidence;
- compatible same-tag memories are not marked contradictory;
- every automatic durable memory is verifiable.

### M15 — Recall V2 and Recall Inspector

Deliverables:

- query plan;
- parallel FTS/vector/graph retrieval;
- weighted RRF `k=60`;
- normalized candidate types;
- bounded lifecycle scoring;
- diversity;
- optional reranker;
- token packing;
- provenance;
- recall runs/candidates;
- Recall Inspector LiveView;
- expanded eval fixtures.

Exit criteria:

- Backplane coding corpus top-5 hit rate at least 95%;
- separate LongMemEval-compatible report produced without claiming direct comparability until reproduced;
- FTS-only outage path passes;
- 100% returned derived results contain provenance;
- Inspector explains selected and rejected candidates.

### M16 — Lessons and Crystals

Deliverables:

- lesson schema/lifecycle/evidence;
- save/recall/strengthen/promote/archive tools and APIs;
- automatic lesson candidates;
- SessionStart lesson injection;
- lesson UI;
- crystal schema and workers;
- session and action-chain crystallization;
- crystal-to-lesson joins;
- crystal tools/APIs/UI.

Exit criteria:

- automatic lessons remain candidates by default;
- active lessons have evidence;
- crystal generation is idempotent;
- no raw event is pruned;
- session/action/lesson links are navigable.

### M17 — Activity, Dashboard, and Replay

Deliverables:

- durable daily aggregates;
- complete heatmap and trend queries;
- live activity feed;
- expanded Overview metrics;
- canonical replay projection;
- playback UI;
- host-local Claude Code JSONL import;
- import safety and idempotency;
- derived artifact links.

Exit criteria:

- historical aggregates match event fixtures;
- failed host/worker/channel states are visible;
- native and imported replay fixtures are equivalent;
- replay import reads only approved local roots and is audited.

### M18 — Surface Completion, Integrations, Evaluation, and Release

Deliverables:

- final REST/MCP/resources/prompts/skills inventory;
- core/all tool visibility and permission tests;
- Claude Code, Codex, OpenCode, Hermes, and OpenClaw adapter validation as available in the repository;
- LiveView navigation and cross-link completion;
- migration/backfill/rebuild tooling;
- operational runbooks;
- load, failure, privacy, recall, and upgrade testing;
- release and rollback plan.

Exit criteria:

- every capability has Context, transport, UI, observability, and tests where applicable;
- migration can be run without capture downtime;
- rollback preserves accepted events;
- Definition of Done is satisfied.

---

## 14. Success Metrics

| Metric | Target |
|---|---:|
| Host-local accepted events lost during supported outage test | 0 |
| Duplicate event effects after retry | 0 |
| Privacy fixture leakage into spool/database | 0 |
| Backplane coding-corpus top-5 hit rate | ≥ 95% |
| Returned auto-derived records with provenance | 100% |
| Recall retrieval/fusion p95, excluding query embedding/LLM | < 300 ms |
| FTS-only recall availability during provider outage | 100% |
| Eligible sessions summarized within 4 hours | ≥ 95% |
| Governance deletes with audit entry | 100% |
| Lifecycle/relation changes with audit entry | 100% |
| Local enqueue p95 | < 50 ms |
| Deterministic projection p95 lag under normal load | < 10 s |
| Replay import duplicate effects on re-import | 0 |
| Activity aggregate discrepancy versus canonical events | 0 in test fixtures |

Agentmemory's published benchmark numbers are reference targets, not evidence that Backplane has achieved parity. Backplane must run and publish its own reproducible reports.

---

## 15. Release Definition of Done

The optimization program is complete when all of the following are true.

### Capture

- Automatic capture uses `host_agent` for every supported runtime.
- Host privacy filtering, canonical normalization, durable spool, retry, and ACK are operational.
- A Backplane outage does not block asynchronous hooks within spool capacity.
- Accepted events are not lost or duplicated in effect.

### Processing

- Captured events are immutable.
- Observations, sessions, activity, and replay are event-derived and rebuildable.
- Optional processing is idempotent, observable, and fail-open.
- Raw events are never replaced by compressed projections.

### Knowledge

- Memories have evidence, lifecycle, versions, and relations.
- Contradiction classification is evidence-backed and reviewable.
- Lessons are first-class and conservatively promoted.
- Crystals preserve completed-work outcomes and source links.
- Actions and coordination remain in Backplane Memory.

### Recall

- FTS, vector, and graph channels participate where available.
- Weighted RRF, diversity, lifecycle scoring, optional reranking, and token packing are implemented.
- Every selected derived candidate has provenance.
- Recall Inspector explains rankings and selection.
- FTS-only recall works during provider outages.

### Product

- Overview, Graph, Memories, Timeline, Sessions, Lessons, Actions, Crystals, Audit, Activity, Profile, Replay, Config, and Recall Inspector are usable.
- UI uses LiveView with bounded server-side queries.
- Pages cross-link evidence and derived records.
- Disabled/pending/skipped/failed states are clear.

### Surfaces

- MCP uses only `memory::*` canonical names.
- Existing tools remain compatible unless explicitly migrated.
- New lesson, crystal, replay, activity, and explain surfaces are complete.
- Resources and prompts return real Backplane data.
- Skills are published through the Backplane Skill Hub.

### Governance and Operations

- All destructive and lifecycle operations are audited.
- Hard delete remains disabled by default.
- Host, ingest, processing, recall, knowledge, and coordination health are visible.
- Rebuild, retry, heal, and migration paths are documented and tested.

---

## 16. Risks and Mitigations

| Risk | Mitigation |
|---|---|
| Feature breadth delays reliability work | Enforce milestone order; parity UI begins only after capture/event correctness |
| Host spool becomes a second memory database | Keep envelope-only queue, bounded retention, no semantic indexes or intelligence |
| LLM extraction creates false knowledge | Candidate states, evidence requirements, prompt/model version, conservative promotion |
| Contradiction resolution damages valid memory | Relation candidates, deterministic policy, disputed state, no tag-only mutation |
| Recall tracing grows quickly | Configurable retention, compact candidate rows, sampled traces where needed |
| Replay exposes sensitive tool data | Double privacy filtering, replay permission, field-level redaction, trusted admin endpoint |
| Central server cannot access transcript files | Host-local import adapter through normal event transport |
| Activity aggregates drift | Rebuildable projector and consistency task comparing aggregates to events |
| Multi-node workers duplicate effects | Unique processing keys, advisory locks where needed, idempotent transactions |
| Optional provider outages stall queues | Separate queues, skip/retry states, deterministic fallback, circuit breakers |
| Existing API naming drifts from Backplane convention | Canonical `memory::*` inventory generated/tested from live registry |

---

## 17. Open Implementation Decisions

These choices are intentionally left for implementation planning, without changing the product contract:

1. The concrete disk-backed spool implementation behind the host-agent spool behavior.
2. Compression codec and exact transport framing for large batches.
3. Whether recall traces are stored for every request or sampled after the initial evaluation period.
4. Exact tokenizer implementation used for server-side budget estimation.
5. The first reranker model/strategy available through Backplane's LLM Proxy.
6. Whether lesson auto-promotion remains permanently off or is enabled for trusted scopes after evaluation.
7. The default event-gap grace period for final session crystallization.
8. The exact retention window for raw replay detail versus aggregate activity.

None of these decisions may move memory intelligence into `host_agent` or weaken durable idempotency, privacy, provenance, or audit requirements.

