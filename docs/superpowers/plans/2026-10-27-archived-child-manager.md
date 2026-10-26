# Archived Child Manager Implementation Plan

> **For agentic workers:** Execute inline task by task with writing-plans and test-driven-development. Root owns Reconciliation/Session/Registry and delivery; this worker owns only MultiAgent, Archive and direct tests/fixtures. Do not create worktrees or commit.

**Goal:** Apply trusted child/manager retirement receipts and restore retired child history into a fresh nonexecuting roster, admitting continuation only through a new ordinary child birth.

**Architecture:** Public host wrappers pin exact controller identity, call bounded trusted adapter validation outside the mailbox, then project only the same pin. A pure archive module resolves immutable admission/inventory/configuration references and the authoritative terminal Store; archive JSON contains no executable options or authority. Archived followup resolves policy outside the controller before using existing admission, limits, ancestry and Session-birth checks.

**Tech Stack:** Existing Elixir GenServer, Task supervisors, Store/Kernel, JSON/crypto and host Reconciliation adapter; no new dependency.

Approved spec: `docs/superpowers/specs/2026-10-27-archived-child-reconciliation-design.md`. Current checkout baseline `d153846a8d2a9ce9d5aabbb818f53e553edbb20d`. PDF, PTY and the recovery foundation are separate parts of the approved batch with coordinated file ownership.

## File boundaries

- Modify `apps/backplane_agent_runtime/lib/backplane/agent_runtime/codex/multi_agent.ex`: recovery configuration, stable root identity, manager-qualified runs, fenced manifests, receipt projections, archive roster/fresh continuation and event pinning.
- Create `apps/backplane_agent_runtime/lib/backplane/agent_runtime/codex/multi_agent/archive.ex`: fixed archive/admission/inventory schemas, safe runtime-message projection, authoritative comparison, historical limits/configuration/ceiling validation.
- Create `apps/backplane_agent_runtime/test/backplane/agent_runtime/codex/multi_agent_recovery_test.exs` and direct fixture `apps/backplane_agent_runtime/test/fixtures/multi_agent_recovery_host.exs`: real Conversation completion/export/import/followup, conflicts, retry/events, partial closure and failure tests.
- Existing Session, Registry, Reconciliation/Evidence/Adapter, their recovery tests/fixture, package/release docs and Git are outside this worker's writes.

## Task 1: Author failing public integration tests

- [x] Build a host adapter fixture with authoritative EphemeralStore records, immutable admission/inventory records and explicit fixture receipt creation. Use real children and public host APIs; fixture callbacks count preparation/provider/cleanup activity.
- [x] Complete a child and fence it through `MultiAgent.recovery_manifest(manager, identity)`. Persist exact trusted evidence/receipt, export and reconcile/retire its source manager, then stop the old manager.
- [x] Restore into a fresh manager with a different root run but matching stable root/scope. Assert no preparation/provider/cleanup work, preserved child/parent/history, zero imported admissions, closed nonresident entry, one restored event and exact retry receipt.
- [x] Explicit followup must preserve child ID/history/feedback/remaining work/deadline and use a new manager-qualified sequence-1 run, attempt and higher incarnation through existing preparation/birth checks. Old event identities cannot affect it.
- [x] Add name/ID/scope/parent/duplicate/import-phase/config/history/artifact/version/unknown-history cases and capacity/refusal checks before preparation.
- [x] Run RED using `flock /tmp/backplane-ir43-beam.lock` and `ERL_FLAGS='+S 4:4'` through `/tmp/backplane-1.10.43-internal-EYMX5h/run-runtime-check.py` with only the new test path; retain failures before implementation.

## Task 2: Implement safe archive value operations

- [x] Validate fixed version-1 archive/admission/inventory fields and canonical digests using Evidence helpers. Compare exact original identity, committed terminal revision/history/limits, source profile and immutable configuration/ceiling references. Reject runtime handles, ambiguous/unknown keys, missing artifacts, pending accepted work, unknown outcomes and configuration mismatch.
- [x] Retain canonical messages/host feedback via an explicit known runtime message schema; preserve nested JSON without arbitrary atom creation. Reuse authoritative Store values on continuation rather than deriving executable options from archive JSON.
- [x] Require an independently confirmed retirement receipt tied to source subject/manifest and current Store fence. Export does no provider/tool/cleanup work; import does not prepare options or grants.

## Task 3: Integrate exact manager lifecycle operations

- [x] Validate optional recovery adapter/root/scope configuration. Preserve old non-recovery behavior; recovery run IDs are `name <> ":" <> manager_id <> ":" <> sequence`.
- [x] Add `recovery_manifest/2`, `reconcile_child/2`, `reconcile_close/2`, `export_child/3`, `restore_child/2` host-only wrappers. Pin/fence in GenServer, validate using bounded workers, apply only unchanged identity/manifest. A timeout/death preserves uncertainty and reservation.
- [x] Compile complete ownership obligations from host inventory, exact original run identities, Kernel requirements, manager-owned Sessions and descendants. Manager closure stays fenced; per-child progress survives sibling failures. Preserve historical errors and accepted latest receipt revision, release capacity only after confirmation, invalidate old interaction/mail/delivery correlations without replay.
- [x] Import only during the fresh roster phase with stable root/scope/name/parent and exact duplicate idempotency. New admissions close import; historical run lookup cannot replace a live mapping. Restore emits one event and imports no updates/results/outboxes/Goal bindings.
- [x] Resolve archive continuation references outside controller callbacks, reject archived immediate parents before reading execution options, then reuse normal capacity/admission/authority/budget/deadline/Session-birth path. Consume failed admission identities normally and retain history. Refuse obsolete archives after replacement.
- [x] Run green public integration tests; diagnose before repair and track at most two failed Sol repair rounds.

## Task 4: Verify existing manager contracts and hand off

- [x] Run scoped format/compile checks and the direct manager admission, observer, interaction, mailbox, lifecycle, managed Session and close regression files explicitly under the shared lock.
- [x] Inspect complete owned diff against every manager/archive acceptance clause. Preserve all concurrent unrelated changes and ensure worker subprocesses finish.
- [x] Record exact argv/cwd/exit/results and same-BEAM evidence under `/tmp/backplane-1.10.43-internal-EYMX5h`; root owns foundation integration, independent durable-BEAM fixture, package/release proof and shared Agent Note writes.

## Self-review

All schema and lifecycle behavior maps to tasks 1–3; compatibility and acceptance review maps to task 4. No new Store/Kernel/Goal semantics are introduced. Original admission incarnation, recovered fence, destination incarnation and receipt revisions remain separate. Adapter callbacks never execute inside the manager mailbox. Root confirmed bounded/load APIs and explicit admission records; complete host inventory reference is coordinated before implementation. No release or downstream production durability claim follows from same-BEAM tests.

## Integrated result

Manager/archive implementation and the independent spec/quality review are complete.
The extracted runtime suite passes 1107 tests and the packaged Conversation consumer
passes 216 tests. The capacity checks run both before asynchronous archive validation
and immediately before fresh admission; imported closed entries reserve no capacity.
The coordinator also completed the independent-BEAM fixture described in
[cold recovery verification](2026-10-27-cold-recovery-verification.md).

Release publication remains pending exact-source remote CI and official-package
verification described in the
[batch release design](../specs/2026-10-27-internal-requests-release-design.md).
These implementation checks do not establish production host-adapter durability
or downstream application acceptance.
