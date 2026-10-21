# Shared host Memory access implementation plan

> **For agentic workers:** Apply subagent-driven-development task by task, with coordinator-owned integration and final acceptance. Repository ownership, repair budgets, and authorized delivery gates take precedence over generic skill defaults.

**Goal:** Complete local L13 sharing with separately authorized read, delivery, remember and forget, then repeat L18 without losing existing state.

**Architecture:** Extend exact MemorySpace entitlements with capabilities and authority versions. Canonical transactions enforce current authority; host-owned persistent fences protect mirrors and durable commands. Default private capture and source provenance remain distinct from the requesting actor.

**Tech Stack:** Elixir/OTP, Ecto/PostgreSQL, Phoenix channels/LiveView, owner-connected Turso, existing DuskMoon components.

## Execution constraints

The user authorized option B and same-machine dev acceptance. No cross-machine checks.
Use the existing branch/workspace and preserve its inherited dirty implementation.
The frozen contract is [shared-host-access-design](../../memory/shared-host-access-design.md).
Task58 owns that architecture document until handoff; interface-dependent work starts
only after the corresponding interface is frozen. Parent owns this plan, task record,
all live lifecycle, dev migration, API/DB/browser and acceptance actions. At most two
child threads are active; all Mix validation is serialized by the parent.

Existing red Dialyzer gate is retained. Do not interpret socket/revocation subset
passes as full L13. Existing recovery budgets in local-dev-checklist.md remain intact.
New implementation tasks start Sol0/Astra0; inherited defects retain their counters.
No per-package commits or releases: delivery follows the complete goal's gates.

## Work packages and acceptance

### 1. Registry and durable authority audit

Ownership: `apps/backplane_system/lib/backplane/memory_spaces.ex`,
`apps/backplane_system/lib/backplane/memory_spaces/entitlement.ex`, new authority audit
schema, one new registry migration, and focused system registry/migration tests.
The exact S1 allocation in the frozen design additionally includes
`apps/backplane_skills/lib/backplane/skills/hosts.ex` and its existing test for
atomic lifecycle revocation; migration is
`20261020000004_add_memory_host_access.exs`.

Frozen schema: capabilities `read|deliver|remember|forget`, positive bigint
authority_version, offline_read_lease_seconds `0..300` default `0`. Delivery
requires read; remember and forget have no dependency on either. Frozen APIs are
the seven registry functions in the design, including `with_host_access/5` for
same-transaction authority checks. Grant/change/revoke use expected-version CAS,
reason and typed operator context; audits commit with the authority transition.

- [x] Add failing tests for independent capabilities, exact recipient/target, version
  conflicts, revoke/regrant, atomic audit and rejected registration/alias escalation.
- [x] Extend schema/migration and implement the frozen registry API. Preserve aliases,
  revoked state and default capture; never silently upgrade historical foreign rows.
- [x] Verify target/host lock order and transaction rollback, including audit failure.
- [x] Run `devenv shell -- mix test apps/backplane_system/test/backplane/memory_spaces_test.exs`
  plus the new focused audit/migration tests; expected zero failures.
- [x] Review specification compliance, then code quality, before dependent integration.

Task61 passed 27 system/registry/migration and 16 skills tests, scoped format/diff
and incremental owning-app warnings-as-errors compilation. Sol repair1 corrected
the initial Ecto dynamic-lock compile error. Actual dev migration remains pending.

### 2. Process-free shared operation contract

Ownership: `apps/backplane_memory_contract/lib/backplane/memory_tool_contract.ex`,
new process-free shared-access contract module if specified, and owning tests.

- [x] Add red tests for the explicit access selector on recall/list/stats/remember/forget
  and its absence from unsupported operations, preserving existing required fields.
- [x] Implement the five optional schema selectors without changing required fields,
  permissions or metadata (Task60). Descriptor/versioned protocol work stays in S3.
- [ ] Implement descriptors and versioned protocol shapes without
  processes, database access, or implicit private fallback.
- [x] Run `devenv shell -- mix test apps/backplane_memory_contract/test`; Task60 red
  11 tests / 5 expected failures, green 11 / 0, scoped format passed.
- [x] Review selector specification compliance, then code quality. This package may overlap
  registry implementation because their file ownership is disjoint.

### 3. Canonical authorization, commands and feed

Ownership: Memory `authorization.ex`, partition/service/read paths, canonical command
sync and edge delivery paths, relevant API channel integration, and owning tests.
Split concrete file ownership only after packages 1–2 pass; never assign concurrent
writes to shared channel/service files.

- [x] Add red coverage for credential/grant intersection, foreign source reads,
  actor/source separation, remember-only and forget-only grants, and forged authority.
- [x] Implement exact-target canonical reads and version-fenced transactional commands.
- [x] Bind delivery/snapshot/ACK authority to access ID/version and preserve legacy
  private negotiation. Add concurrent revoke/mutation/delivery regression coverage.
- [x] Verify rejected stale commands cannot execute after regrant and committed
  duplicate receipts expose no protected content.
- [x] Run owning focused Memory/API suites named in each dispatch; expected zero failures.

Canonical Task63 passed97 scoped tests, incremental owning warnings-as-errors
compile and format/diff after Sol2/Astra1. Final recovery preserves a bounded
error through actual nested transaction rollback; shared facets can only be added
to newly inserted rows. API/feed Task66 remains under implementation. These are
source/fault checks, with no dev migrations or shared-host live qualification yet.

### 4. Host persistent authority and shared outbox

Ownership: new host access owner plus existing facade/proxy, durable command store,
syncer/mirror admission, startup ownership and focused host tests.

- [x] Add red tests for owner serialization, persisted fences, selector admission,
  lease expiry, cold start, stale replies/snapshots, and denied overlays/receipts.
- [x] Implement frozen owner/store API, shared command target/version persistence,
  and routing integration without altering settled socket retry behavior.
- [x] Verify permanent denial prevents fallback, transport-only failure preserves
  approved behavior, and fresh regrant requires fresh synchronization.
- [x] Run focused host tests from each dispatch, including existing private-routing
  regressions; expected zero failures.

Task64 source accepted after repair2:26 focused integration cases and310 affected
regressions passed, owning warnings-as-errors compile and format/diff passed.
Credential scope transitions require fresh connection generation, retain true
target revoke fences, and cannot reuse an old mirror. These source/fault checks do
not replace the live mirror/revoke/lease/two-host matrix below.

### 5. Existing Admin partition access controls

Ownership only: `apps/backplane_admin/lib/backplane/admin/live/memory_memories_live.ex`
and `apps/backplane_admin/test/backplane/admin/live/memory_memories_live_test.exs`.

- [x] Add tests for separate recipient host/target triple, independent permissions,
  reason/version validation, stale revoke, rejected submissions and audit actor.
- [x] Implement Access section using registered hosts and DuskMoon controls. Preserve
  unsaved form/version during refresh; reset draft only when target changes.
- [x] Run `devenv shell -- mix test apps/backplane_admin/test/backplane/admin/live/memory_memories_live_test.exs apps/backplane_admin/test/backplane/admin/live/memory_operator_refresh_test.exs apps/backplane_admin/test/backplane/admin/live/memory_operator_pages_live_test.exs`.
  Task62 initial 36 / 2 failed, repair1 36 / 0 passed. Scoped format/diff passed;
  no hook/router/layout changes. Browser/dev migration remains pending integration.

### 6. Actual same-machine grant/revoke and repeatability

Parent exclusively owns execution; workers may author a separately scoped private
driver after protocol handoff. Preserve both isolated fixtures and existing records.

- [ ] Apply dev migration and restart through supported lifecycle commands after all
  child commands stop. Confirm all endpoints and ownership before mutation.
- [ ] Grant through supported Admin controls; prove two same-machine hosts share only
  the exact authorized partition, with preserved source and separate actor identity.
- [ ] Prove read/delivery, remember-only, forget-only and missing-credential-permission
  boundaries through both HTTP and MCP; reject raw foreign authority.
- [ ] With a positively populated mirror, prove online revoke, offline lease bound,
  cold restart, stale delivery/snapshot rejection, queued-command revoke/regrant and
  durable audit. Existing private capture must retain its target.
- [ ] Repeat required workflow with retained state and supported service restarts;
  compare complete bounded inventories, tombstones and pending queues.
- [ ] Restore healthy fixtures/configuration and retain sanitized reports and UI evidence.
- [ ] Run required scoped compile/format/Credo/assets and resolve or accurately report
  remaining mandatory quality gates. Update runbook, acceptance and implementation
  explanation from actual results; mark L13/L18 only with passing evidence.
- [ ] Commit/push/selective release only after every required delivery gate passes.

## Current boundary

Task58 frozen architecture and Task59 read-only UI inventory are complete.
Task60 five schema selectors passed source verification; descriptor and transport
work remains in S3. Task61 implements registry/audit; Task62 implements the disjoint
Admin view against frozen interfaces, waiting for the serialized Mix slot.
No live shared-access acceptance has run. Live stack health was
rechecked at continuation: public/admin/host ready; no deliberate fault active.
