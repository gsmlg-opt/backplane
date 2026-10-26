# Archived Child and Closure Reconciliation Implementation Plan

> **For agentic workers:** Use subagent-driven-development for independently owned components or executing-plans for the coordinating implementation. Follow the approved design task by task; serialize shared BEAM builds and Git mutations.

**Goal:** Restore safely retired child history and explicitly reconcile failed runtime ownership without repeating effects or rewriting historical outcomes.

**Architecture:** A trusted host adapter resolves immutable evidence, authoritative Stores and CAS-persisted closure receipts. Thin controller integrations seal inventories and consume exact receipts; an archive module validates history and prepares fresh normal admission.

**Tech Stack:** Elixir 1.18/OTP 28, existing Store/Kernel, GenServer and supervised Tasks, built-in JSON and crypto; no new dependency.

Approved spec: `docs/superpowers/specs/2026-10-27-archived-child-reconciliation-design.md` (user approval 2026-10-27). Execution uses current main, no branch/worktree. Root owns these files; PTY and AI workers own disjoint paths.

## Task 1: Evidence schema, adapter and receipt validation

Files: new `apps/backplane_agent_runtime/lib/backplane/agent_runtime/codex/reconciliation.ex`, `codex/reconciliation/adapter.ex`, `codex/reconciliation/evidence.ex`, and `test/backplane/agent_runtime/codex/reconciliation_test.exs`. New test support belongs to the same runtime app.

- [x] Write public API tests using a real runtime Store and an explicit host evidence adapter. Construct a terminal run, sealed inventory and exact observations; assert a new receipt is revision 1, latest exact retry is unchanged and original run remains identical.

```elixir
assert {:ok, first} = Reconciliation.reconcile(config, request)
assert first["revision"] == 1
assert {:ok, ^first} = Reconciliation.reconcile(config, request)
assert {:ok, ^original_record} = Store.load(store, context, run_id)
```

- [x] Run the new test explicitly with `flock /tmp/backplane-ir43-beam.lock devenv shell --no-tui -- python3 /tmp/backplane-1.10.43-internal-EYMX5h/run-runtime-check.py reconciliation-red test test/backplane/agent_runtime/codex/reconciliation_test.exs --seed 0 --max-cases 1`; record the missing public API failure before implementation.
- [x] Implement the approved fixed JSON shapes, canonical digests, closed enums, scope/identity/ownership validation, bounded adapter execution and absent-receipt CAS 0-to-1 semantics. Load current Store records through the adapter, verify original/current incarnation fences, terminal state and complete cleanup/effect requirements, then persist monotonic progress under host exclusivity. Lost ACK reloads the same receipt; no Provider/tool/cleanup calls exist in this module.
- [x] Add tests for exact latest retry, changed duplicate, stale revision, missing observations, run/fence disagreement, unknown mutation, partial progress, lost ACK and malformed evidence. Re-run this file and scoped format/compile checks until green.

## Task 2: Fenced Registry and permanently closed Session projections

Files: existing runtime `codex/resource_registry.ex`, `codex/session.ex`; new focused `codex/reconciliation_owner_test.exs`.

- [x] Write a real Registry cleanup failure fixture. Fence its owner, export its exact manifest and prove reconciliation changes only receipt-backed entries while never calling cleanup/acknowledgement again. Capture initial failed Session.close, establish Registry/run/owned-manager receipts and require explicit Session reconciliation.

```elixir
assert {:error, %Error{class: :unknown_outcome}} = Session.close(session)
assert {:ok, manifest} = Session.recovery_manifest(session)
assert {:ok, acknowledgement} = Session.reconcile_close(session, receipt_ref)
assert acknowledgement.status == :confirmed
assert %{phase: :closed, initial_cleanup: {:error, _}} = Session.status(session)
assert {:ok, ^acknowledgement} = Session.close(session)
```

- [x] Run only `test/backplane/agent_runtime/codex/reconciliation_owner_test.exs` through the shared runtime runner and record the expected missing operation failure.
- [x] Add opt-in trusted recovery configuration and serializable sealed inventories. Retain exact local subject pins and failed diagnostics. Perform adapter work in bounded supervised workers outside mailboxes; compare pins/manifest before projection. A closing/in-progress owner cannot be projected. Explicit reconciliation never reopens admission, repeats callbacks or erases unacknowledged obligations.
- [x] Run owner regressions plus existing `codex_resource_registry_test.exs`, `codex_session_lifetime_test.exs` and `codex_multi_agent_close_test.exs`; preserve existing non-recovery behavior and unknown cleanup evidence.

## Task 3: Managed child reconciliation and archive followup

Files: existing runtime `codex/multi_agent.ex`; new `codex/multi_agent/archive.ex` and focused `codex/multi_agent_recovery_test.exs`.

- [x] Add public-only fixtures that actually complete a child, close old ownership, persist its history/evidence, stop the old manager and create a new one. Import must call no preparation or Provider. Followup must call them exactly once with the same logical ID/history and fresh manager-qualified run, attempt, incarnation and managed binding.

```elixir
assert {:ok, archive} = MultiAgent.export_child(old, identity, receipt_ref)
assert {:ok, restored} = MultiAgent.restore_child(fresh, archive)
assert {:ok, ^restored} = MultiAgent.restore_child(fresh, archive)
refute_receive {:prepared, :fresh, _}
assert {:ok, _} = call(fresh, "followup_task", %{"target" => identity.name, "message" => "continue"})
assert_receive {:prepared, :fresh, next}
assert next.parent.child.agent_id == identity.agent_id
refute next.run_id == identity.run_id
```

- [x] Record RED with that explicit test file, then implement immutable archive schema/export/validation, trusted history/configuration references and nonresident roster import. Preserve old admission provenance and emit one restored event. Reject import after fresh admission; archived parents require fresh admission before descendant followup.
- [x] Add stable opt-in root/scope configuration, manager-qualified run IDs and capacity/replacement integration. Import carries no capabilities/queued work. Reconciliation consumes exact original identity plus recovered Store fence, preserves historical failure/unknown and invalidates old pending correlations. Child/manager retirement cannot infer whole Session closure.
- [x] Run managed-child, observer, birth, interaction and V2 lifecycle regression files, then inspect integrated diff for policy/budget/history changes outside the approved boundary.

## Task 4: Durable recovery, documentation and delivery proof

Files: runtime `PERSISTENCE.md`, `EMBEDDING.md`, `docs/agent-runtime/codex-tools/session-resources.md`; durable runtime test fixtures and a public fresh-BEAM consumer. Root integrates the PTY worker's EMBEDDING snippet only after shared ownership is handed back.

- [x] Add a genuine persisted fixture with atomic receipt CAS and runtime Store fencing; inject usage/finish commit failure and lost acknowledgements. First BEAM captures real admission/component facts and exits completely. Second BEAM loads durable records without old processes/capabilities, reconciles and restores, then admits explicit fresh work. Execution markers distinguish the new work from replay.
- [x] Verify terminal unknown provider-only retirement leaves run journal/outcome/Goal state unchanged; missing tool/child/dependency/native/hook observations remain blocked. Record same-BEAM and independent-BEAM evidence separately.
- [x] Document public construction, exact identity/receipt schemas, adapter exclusivity/durability guarantees, live/cold flows, archive limits and permanent Session closure. State actual verification and downstream limitations.
- [x] Run focused recovery plus the owning runtime suite, compile/format/Credo and required package/workflow contracts. The complete package verifier passes with 1107 runtime tests, 216 Conversation tests and the current Sigma source probe enabled. Full compile/format/Credo/Dialyzer pass under the existing exact CI compiler pair; strict production compilation also passes.
- [ ] Coordinator stages only intended files, reviews each commit and actual remote main, completes authorized CI/release publication and official-package verification. Include only the user-approved minimum release-validation repairs; do not deploy services.

Self-review: Tasks 1-4 cover every approved evidence/CAS/controller/archive/cold-recovery acceptance group. PTY and PDF are separate plans. Original/current incarnation, receipt revision and Session identity remain distinct. No new execution/recovery policy or permission gate is added.
