# Memory V2 PR0 Audit and Architecture Decisions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a source-backed Memory V2 implementation audit and the two architecture decisions required before any production behavior changes.

**Architecture:** This milestone is documentation-only. It traces the current host-agent, Phoenix Channel, PostgreSQL/Oban, projection, and Recall V2 paths at baseline `55835fbd`, records defects without repairing them, and fixes the target ownership vocabulary before PR1 introduces a remote-first facade or partition changes.

**Tech Stack:** Elixir 1.18, OTP 28, Phoenix Channels, Ecto/PostgreSQL, Oban, Turso/ex_turso, Markdown, Mermaid

---

### Task 1: Establish and Record the Baseline

**Files:**
- Create: `docs/memory/memory-v2-implementation-audit.md`
- Reference: `docs/memory/backplane-memory-agentmemory-parity-design-v2.md`
- Reference: `docs/memory/backplane-memory-agentmemory-parity-prd-v2.md`
- Reference: `/home/gao/Workspace/gsmlg-opt/backplane/docs/memory/backplane-memory-v2-codex-handoff.md`

- [x] **Step 1: Create the isolated worktree**

  Worktree: `/home/gao/Workspace/gsmlg-opt/backplane/.trees/codex/memory-v2-audit`

  Branch: `codex/memory-v2-audit`

  Baseline: `55835fbd799c81238e455446f8fa43701a5adda6`

- [x] **Step 2: Fetch locked dependencies and initialize the worktree-local test database**

  Commands:

  ```bash
  HEX_HTTP_CONCURRENCY=1 HEX_HTTP_TIMEOUT=300 devenv shell -- mix deps.get
  devenv up -d postgres
  devenv shell -- env MIX_ENV=test mix ecto.create
  devenv shell -- env MIX_ENV=test mix ecto.migrate
  ```

- [x] **Step 3: Run the pre-change baseline**

  Commands:

  ```bash
  devenv shell -- mix format --check-formatted
  devenv shell -- mix compile --warnings-as-errors
  devenv shell -- mix test
  devenv shell -- mix credo --strict
  devenv shell -- mix dialyzer --format raw
  ```

  Record these observed results in the audit without fixing them:

  - format: pass;
  - compile: pass;
  - full tests: fail with 8 `backplane_memory` failures and 1 `backplane_mcp` failure; isolated `backplane_memory` rerun has 3 failures;
  - Credo strict: 10 warnings and 5 refactoring opportunities;
  - Dialyzer raw: 256 errors, 179 skipped warnings, and 10 unnecessary skips.

- [x] **Step 4: Add the baseline section to the audit**

  Include the exact commands, environment setup prerequisite, pass/fail result, failure files, and the rule that PR0 does not remediate baseline failures.

### Task 2: Trace the Actual Runtime and Ownership Model

**Files:**
- Create: `docs/memory/memory-v2-implementation-audit.md`
- Inspect: `apps/backplane_host_agent/lib/backplane/host_agent/memory/`
- Inspect: `apps/backplane_host_agent/lib/backplane/host_agent/memory_router.ex`
- Inspect: `apps/backplane_host_agent/lib/backplane/host_agent/memory_proxy.ex`
- Inspect: `apps/backplane_host_agent/lib/backplane/host_agent/agent_channel.ex`
- Inspect: `apps/backplane_api/lib/backplane/api/channels/host_agent_channel.ex`
- Inspect: `apps/backplane_api/lib/backplane/api/host_agent_memory_sync.ex`
- Inspect: `apps/backplane_memory/lib/backplane/memory/`

- [x] **Step 1: Document the seven actual runtime sequences**

  Add Mermaid sequence diagrams for automatic capture, explicit remember, online recall, offline recall, fact generation/delivery, canonical deletion/wipe, and reconnect/reconciliation. Each diagram must name the concrete modules/functions and visibly mark dropped pushes, no-op ACKs, local-first reads, and durable boundaries.

- [x] **Step 2: Add the ownership and storage matrix**

  Cover capture spool events, canonical events, provisional commands, canonical memories, host facts, recall cache entries, tombstones/revocations, slots, projection state, and Oban jobs. For each row record current writer, current reader, current authority, intended authority, retention, encryption, and known defect.

- [x] **Step 3: Add the `memory::*` routing matrix**

  Cover `remember`, `recall`, `list`, `forget`, `stats`, and `lifecycle_context`, plus unknown Hub `memory::*` tools. Record the local handler, remote handler, online behavior, offline behavior, fallback class, authorization boundary, and result schema.

- [x] **Step 4: Add the identity and authorization inventory**

  Distinguish authenticated host ID, host token, global host-agent permission, `host:<host_id>` owner partition, registered `memory_scope`, source `client_id`, runtime integration, project provenance, namespace, and the proposed `memory_space_id`/`source_client_id` concepts.

- [x] **Step 5: Add the defect register**

  Classify every defect as P0, P1, or P2 and cite exact paths/functions. At minimum include local-first public memory routing, unsafe fallback absence, incomplete partition before ACK, revocation-only forget semantics, ignored fact/wipe pushes, no-op ACKs, hash-only reconciliation, missing edge revisions/cursors, Codex event vocabulary mismatch, outbox retry failure, tombstone identity, unbounded local retention, per-event full-session repair, incomplete processing states, and nullable worker partition writes.

- [x] **Step 6: Add audit queries and characterization-test specifications**

  Specify exact future checks for incomplete canonical events/memories, mixed session partitions, repair amplification, skipped generation visibility, stale/missing host cursors, unauthorized fallback, provisional identity reconciliation, and tool schema parity. Do not add tests in PR0.

### Task 3: Decide the Canonical Memory-Space Model

**Files:**
- Create: `docs/memory/adr-memory-space-partition.md`
- Reference: `apps/backplane_memory/lib/backplane/memory/partition.ex`
- Reference: `apps/backplane_memory/lib/backplane/memory/authorization.ex`
- Reference: `apps/backplane_memory/lib/backplane/memory/ingest.ex`
- Reference: `apps/backplane_memory/lib/backplane/memory/ingest/upcaster/v1.ex`

- [x] **Step 1: Describe the current conflicting identities**

  Explain how `client_id` currently means both authenticated caller provenance and durable memory owner, while captured source identity is overwritten and source scope can survive ingestion without canonical validation.

- [x] **Step 2: Compare the authority alternatives**

  Compare host-private ownership, project-shared ownership, user ownership, and an explicit stable memory-space model. Evaluate authorization, offline delivery, cross-host sharing, migration complexity, revocation, and rollback.

- [x] **Step 3: Record the accepted staged decision**

  Decide that `memory_space_id` is the stable authoritative owner; `host_id` is capture provenance and delivery target; `source_client_id` is runtime provenance; `scope` is a subpartition; and `namespace` is the visibility/lifecycle boundary. Preserve current host-private behavior initially by mapping each registered host to one private memory space. Defer cross-host sharing until an explicit entitlement model exists.

- [x] **Step 4: Define fail-closed invariants and compatibility**

  Require the server to derive a complete canonical partition before accepted ACK, reject conflicting source claims, retain source project/scope as provenance only, backfill without reinterpreting identifiers, version protocol changes, and preserve `host_memory.v1` during rollout.

- [x] **Step 5: Define ADR validation**

  Require tests for missing/lying scope, cross-partition claims, ownerless worker writes, canonical partition persistence, rebuild safety, and compatibility/backfill.

### Task 4: Decide Host-Edge Memory Protection

**Files:**
- Create: `docs/memory/adr-host-edge-encryption.md`
- Reference: `apps/backplane_host_agent/lib/backplane/host_agent/memory/spool/cipher.ex`
- Reference: `apps/backplane_host_agent/lib/backplane/host_agent/memory/spool/turso.ex`
- Reference: `apps/backplane_host_agent/lib/backplane/host_agent/memory/store.ex`
- Reference: `apps/backplane_host_agent/lib/backplane/host_agent/memory/migrations/v1.ex`
- Reference: `apps/backplane_system/lib/backplane/settings/credentials/`
- Reference: `deps/ex_turso/`

- [x] **Step 1: Inventory current protection**

  Document capture-spool field encryption, the unencrypted host memory store, local key/config sources, protected fields, failure behavior, and the absence of equivalent long-lived mirror protection.

- [x] **Step 2: Verify dependency capabilities**

  Inspect the locked `ex_turso 3.0.3` APIs and underlying Turso options for supported database encryption or key facilities. Record direct source evidence; do not infer support from product marketing.

- [x] **Step 3: Compare approved alternatives**

  Compare supported database encryption, field-level envelope encryption using existing project facilities, and a documented deployment restriction that blocks the long-lived edge mirror. Reject custom cryptographic formats and silent plaintext persistence.

- [x] **Step 4: Record the staged decision**

  Allow the existing short-lived capture spool cipher to remain. Block the new long-lived canonical edge mirror from production enablement until supported storage encryption or reviewed field-level envelope encryption is implemented. Permit development-only plaintext only under an explicit configuration guard and visible warning.

- [x] **Step 5: Define validation and escalation**

  Require restart, wrong-key, missing-key, rotation, plaintext-leak, backup, and eviction tests. The missing internal dependency capability is tracked by `gsmlg-dev/concord#91` as an open `Feature` with label `internal request` and severity `needed`; add `# TODO(upstream): gsmlg-dev/concord#91` at the eventual implementation callsite.

### Task 5: Self-Review and Verify PR0

**Files:**
- Review: `docs/memory/memory-v2-implementation-audit.md`
- Review: `docs/memory/adr-memory-space-partition.md`
- Review: `docs/memory/adr-host-edge-encryption.md`
- Review: `docs/superpowers/plans/2026-08-29-memory-v2-pr0-audit.md`

- [x] **Step 1: Check handoff coverage**

  Verify the audit contains all seven sequences, both matrices, baseline results, severity register, source conflicts, and future audit/test specifications. Verify both ADRs include context, decision, alternatives, consequences, compatibility, validation, and explicit non-goals.

- [x] **Step 2: Scan for placeholders and ambiguous authority language**

  Command:

  ```bash
  rg -n 'TBD|implement later|host-agent is authoritative|source scope grants' docs/memory/memory-v2-implementation-audit.md docs/memory/adr-memory-space-partition.md docs/memory/adr-host-edge-encryption.md
  rg -n 'TODO' docs/memory/memory-v2-implementation-audit.md docs/memory/adr-memory-space-partition.md docs/memory/adr-host-edge-encryption.md
  ```

  Expected: no placeholders and no statement granting host-agent or source claims canonical authority. The only `TODO` is the prescribed future callsite marker `TODO(upstream): gsmlg-dev/concord#91` quoted by the encryption ADR.

- [x] **Step 3: Verify documentation references**

  Check every cited repository path exists and every referenced function is present with `rg`. Correct stale references before review.

- [x] **Step 4: Verify the scoped diff**

  Commands:

  ```bash
  git status --short
  git diff --check
  git diff --stat
  git diff -- docs/memory docs/superpowers/plans
  ```

  Expected: only the four PR0 documentation files are changed; no production code, migrations, tests, lockfiles, Admin files, or user-owned main-checkout changes are included.

- [x] **Step 5: Run documentation-safe validation**

  Commands:

  ```bash
  devenv shell -- mix format --check-formatted
  devenv shell -- mix compile --warnings-as-errors
  ```

  Expected: both pass exactly as they did at baseline. Record the full-suite/Credo/Dialyzer failures as unchanged pre-existing evidence rather than rerunning unrelated failing checks for a documentation-only diff.
