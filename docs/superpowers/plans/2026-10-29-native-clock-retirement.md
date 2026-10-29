# Native Clock Retirement Implementation Plan

> **For agentic workers:** Execute task-by-task with scoped-prd-execution and bounded parallel ownership. User authorized main and release; no branches or worktrees.

**Goal:** Resolve #146 with exact durable clock cancellation evidence and publish 1.10.52.

**Architecture:** ClockWait owns an initially unarmed timer under ResourceRegistry. Conversation registers its exact invocation before arming, joins retirement, and persists strict typed evidence. Existing reconciliation composes this evidence with Session, Registry, MultiAgent and Code Mode.

**Tech Stack:** Elixir/OTP, ExUnit, existing Deno Code Mode, writer-backed Store and GitHub release workflow.

## Task 1: Owned wait and bounded Registry registration

Files: new `apps/backplane_agent_runtime/lib/backplane/agent_runtime/codex/clock_wait.ex`; modify sibling `resource_registry.ex`; focused ClockWait tests.

- [x] Characterize unsupported native clock cancellation against the committed baseline Backend; retain the original consumer reproduction in #146.
- [x] Add `ClockWait.run(context, duration)`, `register_admission(operation, registration, coordinator)`, `seal_admission(entry)`, `sealed_report_digest(operation)`, `cancel(operation)`, `release(entry)` and `retired?(entry)`.
- [x] Reserve Registry capacity before waiter allocation, bound clock registrations to 128 per owner, reject transfer while retained, and clean up partial starts.
- [x] Require trusted live registration before arming; keep terminal facts after waiter DOWN until ACK. Cancel closes the gate, joins actual waiter DOWN, freezes the exact report and calls `ToolEffects.confirm_clock_cancellation(operation, report)`.

## Task 2: Runtime integration and evidence

Files: runtime `codex/backend.ex`, `codex/tools.ex`, `conversation.ex`, `tool_effects.ex`, `codex/reconciliation.ex`.

- [x] Propagate trusted callbacks into local tool context. Runtime-bound sleep uses `ClockWait.run(context, duration)`; standalone compatibility remains synchronous.
- [x] Admit exact local clock cancellation in Conversation, seal before cleanup, attach clock registration/stop generation, retain uncertain registrations, and release only after ACK.
- [x] Add ClockCancellation assertion and strict exact-field validation against sealed registration digest.
- [x] Materialize native_clock_wait_retirement only after confirmed waiter, executor and resource retirement. Require authoritative source-record membership and extend nested Code Mode inventory validation.

## Task 3: Functional acceptance

Files: new runtime clock retirement test module, existing shared fixtures only if required.

- [x] Exercise direct normal completion and cancellation with real Provider/Conversation/Session.
- [x] Exercise real managed-child and real-Deno nested clock cancellation, exact enclosing digest and unchanged previous results.
- [x] Cold-read genuine Store evidence after Conversation exits, reconcile old lifetime, bind fresh resources and reach the next actual Provider request.
- [x] Reject substituted identities/generations/digests, absent source records, incomplete nested inventories and unrelated obligation discharge.
- [x] Cover completion/cancel race, unACKed completion, deadlines, owner death, capacity, transfer, stale signals and failed Store ACK.

Run focused tests using `devenv shell --no-tui -- mix test <test-path>`; missing contract fails on baseline, all new regressions pass after integration. Serialize all Mix/build commands.

## Task 4: Integrated verification and release

- [x] Review final integrated diff and update runtime documentation with actual behavior and limits.
- [x] Run complete affected runtime suite, warnings-as-errors compile, formatting, strict Credo, configured Dialyzer, root release/CI contracts and current package/cold-consumer qualification.
- [ ] Commit intended paths with `fix(runtime): ... (fixes #146)`, push main and verify exact remote SHA and exact-commit CI.
- [ ] Inspect live `.github/workflows/release.yml` and `scripts/set-version.sh`; confirm 1.10.52 remains free and dispatch canonical main release with its declared inputs.
- [ ] Wait for every release job. Verify official five Hex packages/source/docs, archive checksums/build provenance and published image. Report downstream adoption separately.

Out-of-scope failures are recorded without repair. No deployment, downstream edits, dependency workaround or unrelated request is authorized.
