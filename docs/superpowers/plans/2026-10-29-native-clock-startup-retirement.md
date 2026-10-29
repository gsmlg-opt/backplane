# Native clock startup retirement implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Close #147 and publish 1.10.53 with exact clock retirement before backend startup and before cancellation callback ACK.

**Architecture:** Conversation creates the real parked executor, allocates an unarmed Registry-owned ClockWait and installs its cancellation entry before publishing start/releasing work. Native Backend consumes this trusted admission and acknowledges it idempotently; existing ToolEffects proofs and cold reconciliation remain unchanged.

**Tech Stack:** Elixir/OTP, ExUnit, existing Session/ResourceRegistry and real Deno Code Mode.

Approved spec: `docs/superpowers/specs/2026-10-29-native-clock-startup-retirement-design.md`.
Work on existing main only. Preserve unrelated edits. Serialize builds and Git mutations.

### Task 1: Characterize startup and write durable regressions

Files: `apps/backplane_agent_runtime/test/backplane/agent_runtime/clock_wait_retirement_test.exs` and a focused startup test module in the same directory if needed.

- [x] Preserve the unchanged public issue probe failure against official 1.10.52: `/tmp/backplane-ir147-startup-probe.exs`, log `/tmp/backplane-ir147-startup-probe.log` (already reproduced).
- [x] Add scheduling gates in the real delegating Backend: before `Backend.execute(operation)`, immediately before the original `register_cancellation`, and after its real ACK. The before-backend gate sends `{:clock_startup_pending, operation, self()}` and awaits an explicit test release. Never manufacture an ACK or proof.
- [x] For direct startup, cancel on the actual `{:agent_runtime, run, %{type: :tool_started}}` event using the unchanged Backend. Assert an exact retained clock proof, real waiter/executor DOWN, no late timer or provider result.
- [x] Expand root/managed-child × direct/real-Deno cold recovery paths to the startup gates. Reuse exact-source/tamper rejection, actual next Provider and replacement Session assertions; keep existing registered-wait cases.
- [x] Run focused tests before implementation where possible; record missing retirement as the expected baseline failure.

### Task 2: Own admission before dispatch

Files: `conversation.ex`, `codex/clock_wait.ex`, `codex/backend.ex`, `codex/resource_registry.ex` under `apps/backplane_agent_runtime/lib/backplane/agent_runtime/`; existing low-level clock tests if needed.

- [x] Split internal ClockWait admission preparation from wait execution. Preparation accepts canonical operation, validated resource owner, coordinator and the real parked executor. It produces the same Registry handle/value and registration digest used by existing typed cancellation.
- [x] Install the admission in Conversation's cancellation inventory in the same serialized callback that starts the parked task. Include exact Session identity. Release work only after preparation succeeds; prevent direct and nested dispatch on failure.
- [x] Deliver trusted admission to the parked executor without accepting host-supplied replacement capabilities. Backend forwards the operation's admission to ClockWait. No second allocation occurs on consumption.
- [x] Preserve the public callback reply `{:ok, coordinator}`. Exact preinstalled entry + current token/caller/operation/Session may ACK again; different registration, caller, generation or operation rejects. Missing preadmission in runtime-bound execution fails closed.
- [x] Keep waiter arming after the callback and original deadline check. Stop seals the same real waiter even if the callback has not returned. Keep existing normal/result-ACK and terminal-ACK retention and owner capacity/transfer rules.
- [x] Bound startup Registry calls by remaining effect time. On ambiguous allocation failure, never infer absence; fence/close resources and retain uncertainty. No retrying dispatch or releasing failed parked executors.
- [x] Check races, stale capabilities, owner/coordinator death, fixed deadlines, capacity and Store failure coverage. Run focused clock tests with real Deno on PATH.

### Task 3: Integrated verification and documentation

Files: `docs/agent-runtime/codex-tools/session-resources.md`, approved spec and this plan.

- [x] Explain pre-dispatch ownership, unchanged proof format, late-callback fencing and actual compatibility limits.
- [x] Review integrated diff and resolve in-scope findings. Preserve original business history and unrelated obligations.
- [x] Run full Runtime suite/package qualification using `scripts/verify_agent_runtime_package.sh` with real Deno and `REQUIRE_SIGMA_SOURCE=1`. Treat the Sigma probe as read-only source compatibility, not Engine acceptance.
- [x] Run strict compile, format, Credo, Dialyzer and release/CI workflow contracts. Use an isolated build when the user dev service is writing shared `_build`; never stop their service.

### Task 4: Exact-commit release

- [ ] Commit intended files only, `fix(runtime): own clock cancellation before dispatch (fixes #147)`, and push main. Inspect all exact-source CI jobs until terminal success.
- [ ] Dispatch `gh workflow run release.yml --ref main -f version=1.10.53 -f release_apps=all`; await all jobs including Memory, migration smoke, six archives, five Hex packages and Docker.
- [ ] Verify official Hex checksums/source bytes/docs and exact-version independent consumer startup/cold-recovery tests. Verify six archives/checksums, embedded versions and applicable metadata/helpers/host-agent plugin manifests, qualification manifest and image source/version/digest.
- [ ] Confirm tag/main/local convergence, clean workspace and `internal request fixed` on #147. Report publication separately from deployment/downstream adoption, then stop.
