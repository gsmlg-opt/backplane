# Backplane Memory V2 — Implementation Audit and Remediation Handoff

**Audience:** OpenAI Codex\
**Repository:** `https://github.com/gsmlg-opt/backplane.git`\
**Primary branch:** `main`\
**Review baseline observed:** `55835fbd799c81238e455446f8fa43701a5adda6`\
**Date:** 2026-08-27\
**Status:** Implementation audit and staged remediation request

---

## 1. Objective

Review the current Backplane Memory V2 implementation and repair it so that the production behavior matches this contract:

```text
Agent runtime
  -> host-agent continuously captures, privacy-filters, durably spools, and uploads events
  -> Backplane durably stores and processes those events
  -> backplane_memory creates and governs authoritative memories
  -> host-agent uses Backplane Recall V2 while online
  -> host-agent provides a bounded, explicitly stale local fallback while Backplane is unavailable
  -> reconnect converges the local edge mirror to the canonical Backplane revision
```

The central architectural rule is:

> Backplane is the only authoritative long-term memory system.\
> host-agent is an edge collector, reliable transport, local command outbox, and bounded non-authoritative memory mirror.

Do not turn host-agent into a second semantic memory engine.

---

## 2. Source-of-Truth Order

Read these documents before modifying code:

1. `docs/memory/backplane-memory-agentmemory-parity-design-v2.md`
2. `docs/memory/backplane-memory-agentmemory-parity-prd-v2.md`
3. `docs/host-agent-memory-design-final.md`
4. `docs/memory-design.md`
5. `docs/memory-prd.md`
6. repository `AGENTS.md` files that apply to edited paths

The July Memory V2 design and PRD are the current product direction.

`docs/host-agent-memory-design-final.md` contains an older local-first design. It remains useful for Turso storage, outbox, local recall, fact application, wipe, and retention implementation details, but its rule that host-agent owns the `memory::*` surface locally is partially superseded.

Do not silently choose whichever document matches the current code. Record conflicts explicitly in the audit.

---

## 3. Required Working Method

This is not a single blind refactor.

Work in staged, reviewable changes:

1. Inspect and document the actual implementation.
2. Establish tests for the current behavior and desired behavior.
3. Fix P0 correctness and authority problems.
4. Introduce protocol/storage migrations behind explicit compatibility boundaries.
5. Remove obsolete behavior only after the new path is covered.
6. Run the repository's complete validation suite.
7. Report unresolved risks rather than hiding them.

Before implementation:

```bash
git status --short
git rev-parse HEAD
git log -5 --oneline
```

Re-check the current branch because it may have advanced beyond the review baseline.

Use the repository's existing Nix/devenv or documented development environment. Do not redesign the toolchain as part of this task.

---

## 4. Current Implementation to Inspect

### 4.1 Host capture and transport

Inspect:

```text
apps/backplane_host_agent/lib/backplane/host_agent/memory/event_envelope.ex
apps/backplane_host_agent/lib/backplane/host_agent/memory/privacy_filter.ex
apps/backplane_host_agent/lib/backplane/host_agent/memory/hooks.ex
apps/backplane_host_agent/lib/backplane/host_agent/memory/spool/
apps/backplane_host_agent/lib/backplane/host_agent/memory/capture_uploader.ex
apps/backplane_host_agent/lib/backplane/host_agent/memory/capture_supervisor.ex
apps/backplane_host_agent/lib/backplane/host_agent/memory/recall_cache.ex
apps/backplane_host_agent/lib/backplane/host_agent/memory_router.ex
```

This path is expected to remain fundamentally intact:

```text
runtime hook
  -> normalize and redact
  -> durable local capture spool
  -> host_events.v1 batch
  -> partial durable ACK
  -> retry or dead letter
```

Do not merge the capture spool with the memory mirror or memory command outbox.

### 4.2 Host-local memory implementation

Inspect:

```text
apps/backplane_host_agent/lib/backplane/host_agent/memory.ex
apps/backplane_host_agent/lib/backplane/host_agent/services/memory.ex
apps/backplane_host_agent/lib/backplane/host_agent/memory_proxy.ex
apps/backplane_host_agent/lib/backplane/host_agent/memory/store.ex
apps/backplane_host_agent/lib/backplane/host_agent/memory/supervisor.ex
apps/backplane_host_agent/lib/backplane/host_agent/memory/syncer.ex
apps/backplane_host_agent/lib/backplane/host_agent/memory/facts.ex
apps/backplane_host_agent/lib/backplane/host_agent/memory/pruner.ex
apps/backplane_host_agent/lib/backplane/host_agent/memory/migrations/v1.ex
apps/backplane_host_agent/lib/backplane/host_agent/config.ex
apps/backplane_host_agent/lib/backplane/host_agent/worker.ex
```

Identify exactly which operations are:

- local-only;
- remote-only;
- local-first;
- remote-first;
- synchronized;
- cached;
- authoritative;
- provisional.

### 4.3 Host transport boundary

Inspect:

```text
apps/backplane_api/lib/backplane/api/channels/host_agent_channel.ex
apps/backplane_api/lib/backplane/api/host_agent_memory_sync.ex
apps/backplane_api/lib/backplane/api/host_memory_revocation.ex
```

Trace these channel messages end to end:

```text
memory_call
memory_sync
memory_events
memory_facts
memory_facts_ack
memory_wipe
memory_wipe_ack
```

### 4.4 Backplane Memory V2

Inspect:

```text
apps/backplane_memory/lib/backplane/memory/application.ex
apps/backplane_memory/lib/backplane/memory/config.ex
apps/backplane_memory/lib/backplane/memory/service.ex
apps/backplane_memory/lib/backplane/memory/authorization.ex
apps/backplane_memory/lib/backplane/memory/partition.ex
apps/backplane_memory/lib/backplane/memory/ingest.ex
apps/backplane_memory/lib/backplane/memory/ingest/event_validator.ex
apps/backplane_memory/lib/backplane/memory/ingest/upcaster/v1.ex
apps/backplane_memory/lib/backplane/memory/events/
apps/backplane_memory/lib/backplane/memory/projections/
apps/backplane_memory/lib/backplane/memory/summaries/
apps/backplane_memory/lib/backplane/memory/memories.ex
apps/backplane_memory/lib/backplane/memory/memories/
apps/backplane_memory/lib/backplane/memory/recall/
apps/backplane_memory/lib/backplane/memory/workers/
```

Trace:

```text
captured event
  -> validation
  -> server privacy filtering
  -> event store
  -> projection repair
  -> session summary
  -> episodic/semantic extraction
  -> procedural extraction
  -> embedding/indexing
  -> Recall V2
```

---

## 5. First Deliverable: Implementation Audit

Before changing production behavior, create:

```text
docs/memory/memory-v2-implementation-audit.md
```

The audit must include:

### 5.1 Actual runtime sequence diagrams

Document the current sequences for:

1. automatic captured event;
2. explicit `memory::remember`;
3. online `memory::recall`;
4. offline `memory::recall`;
5. Backplane fact generation and host delivery;
6. Backplane memory deletion and host wipe;
7. host reconnect and reconciliation.

Do not copy the design document. Trace actual modules and functions.

### 5.2 Ownership matrix

For each state, document:

| State | Current writer | Current reader | Intended authority | Retention |
|---|---|---|---|---|
| capture spool event | | | host until ACK | |
| canonical event | | | Backplane | |
| local episodic memory | | | provisional or obsolete | |
| canonical memory | | | Backplane | |
| host `facts` row | | | edge mirror | |
| recall cache entry | | | non-authoritative cache | |
| tombstone | | | governance projection | |
| slot | | | device-local | |

### 5.3 Routing matrix

For every `memory::*` tool exposed through the host MCP router, record:

```text
tool name
local handler
remote handler
online behavior
offline behavior
fallback conditions
authorization boundary
result schema
```

### 5.4 Known and newly discovered defects

Classify each as:

```text
P0 correctness/security/data-loss risk
P1 scalability/operability/product mismatch
P2 cleanup/maintainability
```

Include file and function references.

### 5.5 Baseline validation

Run the available checks before changes and record existing failures separately from regressions:

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix test
mix credo --strict
mix dialyzer
```

Use repository-specific aliases when defined.

At the review baseline, compile and format passed in GitHub Actions, while Test, Credo, and Dialyzer failed. Do not assume those failures are Memory-specific; capture the exact current failures.

---

## 6. P0 Remediation A — Establish a Remote-First Memory Facade

### 6.1 Problem

The current host MCP service owns `memory::*` locally. `memory::recall` queries Turso with degraded keyword matching even while Backplane and Recall V2 are available. The host router also prevents Hub `memory::*` tools from replacing the local prefix.

That makes the degraded edge database the primary memory system.

### 6.2 Required design

Add an explicit facade, for example:

```text
Backplane.HostAgent.MemoryFacade
Backplane.HostAgent.Memory.RemoteClient
Backplane.HostAgent.Memory.OfflineRecall
```

The exact names may differ, but there must be a single module that owns online/offline routing policy.

### 6.3 Required semantics

#### Recall

```text
memory::recall
  if Backplane transport is healthy:
    call Backplane Recall V2
    merge local pending explicit writes if needed for read-your-writes
    return canonical result

  if transport is unavailable or bounded timeout expires:
    query the local edge mirror
    merge local pending explicit writes
    return explicitly stale result
```

Fallback is permitted only for transport failures such as:

```text
not connected
channel closed
connection refused/reset
network unreachable
DNS failure
hub down
bounded timeout
circuit open
```

Do not fall back on:

```text
unauthorized
partition mismatch
invalid arguments
unknown method
server validation failure
governance denial
```

Those errors must be returned to the caller.

#### Remember and forget

Retain local-first durability only as a command-outbox behavior:

```text
remember/forget
  -> write local provisional command state transactionally
  -> enqueue command outbox
  -> sync to Backplane
  -> receive canonical ID/revision
  -> reconcile local provisional row
```

The local row is not authoritative after Backplane ACK.

#### Other memory tools

Do not reject all Hub tools merely because they use the `memory::` prefix.

A practical boundary is:

```text
memory::*          canonical facade or Hub-owned memory tools
host_memory::*     host diagnostics and explicitly device-local operations
```

Device-only slots may remain local, but their namespace and documentation must make that clear.

### 6.4 Compatibility response

Preserve existing client compatibility where possible. Keep `hits` for recall while adding explicit consistency metadata:

```json
{
  "mode": "online",
  "consistency": "canonical",
  "stale": false,
  "as_of": "2026-08-27T12:00:00Z",
  "partition_revision": 1842,
  "recall_run_id": "uuid-or-null",
  "pending_operations": 0,
  "hits": [
    {
      "id": "uuid",
      "content": "...",
      "memory_type": "semantic",
      "origin": "backplane",
      "authority": "canonical",
      "confidence": 0.91,
      "source_ids": []
    }
  ]
}
```

Offline results must include:

```text
mode = offline
consistency = bounded_stale
stale = true
as_of
partition_revision
last_sync_age_seconds
```

### 6.5 Tests

Add tests proving:

1. healthy channel causes `memory::recall` to call Backplane, not local `LIKE`;
2. canonical Recall V2 metadata is returned;
3. disconnected channel uses local fallback;
4. timeout uses local fallback;
5. unauthorized does not use local fallback;
6. invalid arguments do not use local fallback;
7. local pending writes are visible before ACK;
8. an ACK replaces provisional identity with canonical identity without duplicate recall results;
9. Hub `memory::*` tools are no longer globally hidden by prefix filtering.

---

## 7. P0 Remediation B — Make Memory Partition Complete Before ACK

### 7.1 Problem

Captured event `scope` and `project` are optional, but canonical projections require a complete partition. An event can be durably accepted and ACKed, then fail projection because `scope` is missing or inconsistent.

### 7.2 Required behavior

The authenticated host identity must determine the authoritative memory partition.

At ingestion:

```text
authenticated host
  -> resolve registered memory partition
  -> derive canonical scope and namespace
  -> validate any caller-provided partition claim
  -> persist a complete canonical event
```

The event's working directory, repository path, project label, integration client, and source-provided scope remain provenance. They must not grant access or determine authority by themselves.

Do not return `accepted` when the persisted event cannot be projected into a complete authorized partition.

### 7.3 Identity cleanup

The current `client_id` concept appears to mix:

```text
source runtime identity, such as codex-cli
memory owner partition, such as host:<host_id>
```

Audit every use of `client_id`.

Prefer explicit concepts:

```text
source_client_id
memory_space_id or partition_id
host_id
```

Do not perform a broad rename without a migration and compatibility plan.

### 7.4 Memory-space decision gate

The current partition is host-specific. This prevents two entitled hosts in the same project from naturally sharing the same canonical memory space.

Create an ADR before implementing cross-host sharing:

```text
docs/memory/adr-memory-space-partition.md
```

The ADR must decide whether the authoritative partition is:

```text
host-private
project memory space
user memory space
or an explicit combination
```

Recommended direction:

```text
memory_space_id   stable owner
host_id           capture provenance and delivery target
source_client_id  runtime provenance
scope             subpartition
namespace         visibility/lifecycle namespace
```

A staged migration is acceptable. The immediate P0 requirement is fail-closed partition completeness.

### 7.5 Tests

Add tests proving:

1. missing source scope is replaced by the authenticated canonical scope, or rejected before ACK;
2. a host cannot claim another scope;
3. a host cannot claim another memory partition;
4. persisted events always contain complete partition fields;
5. projection rebuild cannot fail solely because canonical partition fields are absent;
6. semantic extraction cannot create memory with `client_id` or equivalent partition identity missing.

---

## 8. P0 Remediation C — Replace Hash-Only Full Reconcile with Revisioned Sync

### 8.1 Problem

The current `host_memory.v1` reconciliation uses a full fact-set hash during join. It has no durable host cursor, no delta protocol, no reliable ACK state, and no normal online propagation when new memories are generated.

### 8.2 Protocol target

Introduce `host_memory.v2` while keeping v1 compatibility during rollout.

The correctness mechanism must be a monotonic partition revision. Hashes may be used only for snapshot integrity.

### 8.3 Suggested server state

Introduce equivalent durable state:

```text
memory partition revision
ordered memory change log
per-host applied cursor
```

Possible tables:

```text
bpm_memory_partition_revisions
bpm_memory_changes
bpm_host_memory_cursors
```

Names may follow repository conventions.

Every canonical memory change that affects an edge mirror must append a change in the same database transaction:

```text
upsert
lifecycle change
supersede
delete/tombstone
lesson activation/archive when mirrored
profile replacement when mirrored
```

### 8.4 Host join

Example logical request:

```json
{
  "protocol": "host_memory.v2",
  "partitions": [
    {
      "memory_space_id": "uuid-or-stable-id",
      "scope": "project:backplane",
      "namespace": "private",
      "applied_revision": 1810
    }
  ]
}
```

### 8.5 Delta

Example logical server push:

```json
{
  "batch_id": "uuid",
  "from_revision": 1811,
  "to_revision": 1842,
  "changes": [
    {
      "revision": 1811,
      "op": "upsert",
      "memory": {}
    },
    {
      "revision": 1812,
      "op": "delete",
      "memory_id": "uuid"
    }
  ]
}
```

Host application rule:

```text
accept only when from_revision == applied_revision + 1
apply all changes in one Turso transaction
set applied_revision = to_revision in the same transaction
ACK only after commit
```

A revision gap must trigger snapshot recovery.

### 8.6 Snapshot

Snapshot requirements:

- paginated or chunked;
- bounded encoded bytes;
- explicit snapshot revision;
- deterministic ordering;
- integrity hash;
- resumable or safely restartable;
- no unbounded `Repo.all()` of the entire partition;
- no single oversized Phoenix push.

### 8.7 Durable ACK

`memory_facts_ack` and `memory_wipe_ack` must not remain no-op success handlers.

Persist:

```text
host ID
partition
applied revision
batch ID
acknowledged time
```

Real-time Phoenix push is a latency optimization. Revision catch-up is the correctness mechanism.

### 8.8 Tests

Add tests proving:

1. online generated memory reaches an already-connected host without reconnect;
2. reconnect resumes from the persisted cursor;
3. duplicate delta application is idempotent;
4. a revision gap requests a snapshot;
5. delete after upsert cannot be undone by an older replayed upsert;
6. ACK is persisted only after host transaction commit;
7. large partitions are chunked;
8. an interrupted snapshot can restart safely;
9. v1 and v2 compatibility behavior is explicit and feature-gated.

---

## 9. P0 Remediation D — Introduce a Bounded Canonical Edge Mirror

### 9.1 Separate three local stores

The host must distinguish:

```text
capture spool
  raw captured events waiting for durable server ACK
  never used for recall

memory command outbox
  provisional explicit remember/forget commands
  used only for read-your-writes and synchronization

edge memory mirror
  canonical Backplane-selected memories
  used for offline recall
```

Do not merge these concerns into one table.

### 9.2 Replace or migrate `facts`

Migrate the current minimal `facts` representation to an explicit edge mirror, for example `edge_memories`.

It should retain enough canonical semantics for offline recall:

```text
canonical_id
memory_space_id or partition_id
scope
namespace
memory_type
content
content_hash
confidence
lifecycle_state
tags
metadata
source_refs or bounded provenance
server_revision
edge_priority
edge_expires_at
updated_at
last_accessed_at
byte_size
```

Do not replicate raw embeddings unless there is a separately approved local embedding/search design.

### 9.3 Edge selection

Backplane decides what is eligible for mirroring. A sensible order is:

1. active procedural memories and lessons;
2. current project profile;
3. high-confidence semantic memories;
4. recent episodic memories or crystals;
5. bounded working context.

host-agent does not independently consolidate, classify, or semantically promote memory.

### 9.4 Resource limits

The edge mirror must be bounded by configuration:

```text
max bytes
max items
max items per partition/scope
type quotas
maximum age
priority
LRU or equivalent access policy
```

Eviction is local cache management. It must not produce a Backplane `forget`.

Add telemetry:

```text
edge items
edge bytes
partition revision
last successful sync
stale age
eviction count
snapshot count
delta count
sync failures
```

### 9.5 Encryption gate

The capture spool has optional encryption support, while the current local memory DB does not clearly provide equivalent protection.

Inspect the actual Turso/ex_turso capabilities and repository credential facilities.

Do not invent custom cryptography.

Before persisting a long-lived edge mirror containing user memory, provide one of:

1. an approved storage encryption mechanism;
2. approved field-level envelope encryption using existing project facilities;
3. an explicit documented deployment restriction plus a tracked blocking issue.

Record the decision in an ADR.

### 9.6 Tests

Add tests proving:

1. edge mirror survives host-agent restart;
2. offline recall works after restart;
3. configured byte/item bounds are enforced;
4. high-priority procedural memory survives lower-priority eviction;
5. eviction never creates an upstream delete;
6. stale metadata is correct;
7. tombstoned/superseded items disappear according to canonical revision;
8. mirror content is protected according to the approved encryption decision.

---

## 10. P1 Remediation — Fix Local Schema and Retention Defects

### 10.1 Tombstone key

The current tombstone schema uses `content_hash` as the sole primary key while code treats tombstones as scope-specific.

Migrate to a correct identity, at minimum:

```text
UNIQUE(scope, content_hash)
```

For protocol v2, prefer canonical memory identity and delete revision where possible.

Add migration tests for two scopes containing identical content.

### 10.2 Outbox semantics

Audit the difference between:

```text
pending
inflight
failed
done
retryable
permanent rejection
```

Do not move an operation permanently to `failed` on the first retryable application error.

Align retry/partial-ACK behavior with the mature capture uploader pattern where practical.

Add:

- bounded exponential backoff;
- attempt count;
- next retry time;
- permanent dead-letter state;
- operator-visible reason;
- manual retry/requeue;
- cleanup of old done rows.

### 10.3 Retention

Current pruning focuses on synced local memories. Add explicit retention for:

```text
completed command outbox rows
dead letters
edge mirror rows under quota
expired recall cache
obsolete tombstones according to governance policy
device-only slots only when explicitly configured
```

Do not silently prune:

```text
unacknowledged captured events
pending memory commands
canonical deletion state needed to prevent resurrection
```

---

## 11. P1 Remediation — Repair Projection Correctness and Complexity

### 11.1 Coalesce projection repair

The current event append path may enqueue a projection repair for every event. A repair rebuilds the entire session from canonical events.

For long sessions this can approach quadratic work.

Change scheduling so that jobs are coalesced by:

```text
host_id
session_id
latest input revision
```

Required behavior:

- multiple incoming events produce one pending/recent repair per session;
- a stale repair exits without overwriting a newer revision;
- a new late event schedules the next repair;
- final output remains deterministic.

### 11.2 Processing states

Do not report success when required generation was skipped.

Represent:

```text
pending
running
complete
skipped_no_model
skipped_disabled
failed
dead_letter
```

This is especially important for:

```text
summary
semantic extraction
procedural extraction
embedding
graph/profile generation
crystallization
```

### 11.3 Fail closed on incomplete partition

Workers must not create memories with incomplete authoritative partition fields.

Remove or reject fallback behavior that can create a semantic memory with a missing owner identity.

### 11.4 Tests and benchmark

Add:

1. shuffled/out-of-order session fixture;
2. late-event repair fixture;
3. 10,000-event scheduling test that proves repairs are coalesced;
4. stale job revision test;
5. worker `skipped_no_model` state test;
6. incomplete partition rejection test;
7. deterministic rebuild test.

The scheduling test need not execute an expensive real LLM.

---

## 12. P1 Remediation — Unify Schemas and Tool Discovery

The host-local memory service currently exposes shallow tool definitions, while Backplane managed tools have canonical input schemas and permissions.

Required direction:

- one canonical schema for each public `memory::*` tool;
- host facade reuses or mirrors the canonical schema;
- local-only `host_memory::*` tools have their own explicit schema;
- tool discovery remains usable while Hub is offline;
- tool names do not silently change semantics between online and offline modes;
- every response indicates consistency/authority where behavior degrades.

Add contract tests comparing the schemas available through:

```text
direct Backplane MCP
host-agent MCP while connected
host-agent MCP while disconnected
```

---

## 13. Documentation Cutover

Update documentation after behavior is implemented.

Required changes:

1. mark the local-first portions of `docs/host-agent-memory-design-final.md` as superseded;
2. add a concise authority and consistency model;
3. document online/offline recall behavior;
4. document capture spool vs command outbox vs edge mirror;
5. document `host_memory.v2`;
6. document partition/memory-space semantics;
7. document edge retention and encryption;
8. add an operations runbook for stuck cursors, snapshots, dead letters, stale mirrors, and manual resync.

Suggested new files:

```text
docs/memory/memory-v2-implementation-audit.md
docs/memory/adr-memory-space-partition.md
docs/memory/adr-host-edge-encryption.md
docs/memory/host-memory-v2-protocol.md
docs/operations/host-memory-edge-runbook.md
```

---

## 14. Migration and Compatibility Rules

Do not perform a big-bang destructive cutover.

Required rules:

- migrations must be forward-only and idempotent according to repository convention;
- preserve existing local DBs;
- backfill revision/cursor state explicitly;
- keep v1 protocol compatibility behind a documented feature flag or version negotiation;
- do not reuse v1 hash fields as if they were revision cursors;
- do not reinterpret existing IDs without a mapping;
- do not delete old tables until rollback/cutover requirements are satisfied;
- do not broaden host authentication scopes;
- do not accept source-provided scope as authorization;
- do not expose raw secrets in logs, telemetry, audit, or error details.

---

## 15. Mandatory Acceptance Scenarios

The remediation is not complete until these end-to-end scenarios pass.

### Scenario A — Continuous capture during outage

```text
Backplane unavailable for 24 hours
hooks continue to succeed while spool has capacity
host-agent restarts
Backplane reconnects
all accepted events upload with durable partial ACK
duplicates create one canonical effect
```

### Scenario B — Online canonical recall

```text
host-agent connected
agent calls memory::recall
Backplane Recall V2 executes
result contains recall_run_id and provenance
local degraded LIKE is not the primary result source
```

### Scenario C — Offline bounded recall

```text
host has previously synchronized edge revision N
Backplane becomes unavailable
host-agent restarts
agent calls memory::recall
persistent edge mirror answers
response is labelled bounded_stale
response includes as_of, revision N, and stale age
```

### Scenario D — No unsafe fallback

```text
Backplane returns unauthorized or partition mismatch
host-agent does not return local memory as if authorized
caller receives the canonical error
```

### Scenario E — Read-your-writes

```text
offline explicit remember is accepted locally as provisional
immediate recall includes it
reconnect syncs the command
Backplane returns canonical ID/revision
later recall contains one canonical item, not duplicates
```

### Scenario F — Live edge convergence

```text
host remains connected
Backplane generates a new semantic/procedural memory
host receives a revisioned delta without reconnect
host commits and ACKs the new revision
offline recall can use it
```

### Scenario G — Delete convergence

```text
canonical memory exists on host
Backplane tombstones/deletes it
host applies delete revision
old delta retry cannot resurrect it
offline recall no longer returns it
```

### Scenario H — Bounded storage

```text
mirror receives more data than configured capacity
eviction follows priority/quota policy
database stays within configured bounds
eviction does not produce upstream forget
```

### Scenario I — Complete partition

```text
source event omits or lies about scope
server derives or rejects before accepted ACK
persisted canonical event has complete authorized partition
projection and semantic extraction do not create ownerless records
```

### Scenario J — Projection scalability

```text
large session receives many events
repair work is coalesced
final projection is deterministic
job count does not scale as one full rebuild per event
```

---

## 16. Validation Commands

Run targeted tests while developing, then the full suite.

At minimum:

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix test apps/backplane_host_agent/test
mix test apps/backplane_api/test
mix test apps/backplane_memory/test
mix test
mix credo --strict
mix dialyzer
```

Also run any repository aliases, migration checks, JavaScript tests, or release validation required by CI.

Do not declare completion with only mock-module unit tests. Include transport and persistence integration tests.

---

## 17. Expected PR Sequence

A recommended sequence is:

### PR 0 — Audit and architecture decisions

- implementation audit;
- source-of-truth conflict notes;
- memory-space ADR;
- edge encryption ADR;
- no major behavior change.

### PR 1 — Remote-first facade and partition fail-closed

- `MemoryFacade`;
- online canonical Recall V2;
- strict fallback classification;
- local provisional read-your-writes;
- complete partition before ACK;
- update obsolete router tests.

### PR 2 — Revisioned protocol and edge mirror

- `host_memory.v2`;
- server revisions/change log/cursors;
- host edge schema;
- delta/snapshot/ACK;
- v1 compatibility.

### PR 3 — Bounds, governance, and local schema repair

- quotas/eviction;
- tombstone identity fix;
- outbox retry/dead-letter cleanup;
- encryption decision implementation;
- operations telemetry.

### PR 4 — Projection scalability and processing health

- coalesced session repair;
- complete processing states;
- fail-closed workers;
- large-session tests.

### PR 5 — Cutover and cleanup

- documentation;
- operations runbook;
- remove dead compatibility paths only when safe;
- final CI cleanup.

If repository constraints require a different split, keep each PR independently testable and state the reason.

---

## 18. Non-Goals

Do not add:

- local embeddings;
- local vector search;
- local LLM summarization;
- host-side semantic consolidation;
- host-side contradiction resolution;
- peer-to-peer or multi-primary memory synchronization;
- a new authentication system;
- broad cross-host sharing before the memory-space ADR is resolved;
- unrelated UI redesign;
- unrelated Backplane service refactors.

---

## 19. Final Codex Report

At the end of each PR, report:

```text
Summary
Actual defect fixed
Authority/consistency impact
Files changed
Database migrations
Protocol changes
Compatibility behavior
Tests added
Validation commands and results
Known limitations
Follow-up work
```

For the final remediation report, include:

1. before/after architecture diagrams;
2. finalized ownership matrix;
3. finalized routing matrix;
4. protocol version compatibility;
5. migration and rollback notes;
6. observed edge resource usage;
7. projection scheduling measurements;
8. all remaining P1/P2 issues;
9. exact CI status.

Do not claim a path is fixed unless an automated test exercises it.

---

## 20. Completion Definition

The task is complete when the implementation enforces:

```text
Backplane
  authoritative event and memory store
  memory generation and lifecycle
  Recall V2
  partition authorization
  revisioned edge feed

host-agent
  durable capture
  reliable upload
  provisional command outbox
  remote-first memory facade
  bounded persistent offline mirror
  explicitly stale fallback
```

The intended final invariant is:

> Online recall is canonical.\
> Offline recall is bounded and visibly stale.\
> Reconnection converges by revision.\
> host-agent never becomes an independent long-term semantic memory authority.
