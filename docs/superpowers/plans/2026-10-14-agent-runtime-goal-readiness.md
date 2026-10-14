# Agent Runtime Goal Package and Host Readiness Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans when execution is authorized. Track execution with `- [ ]`. Repository instructions override automatic commits, branches, pushes, publication and deployment.

**Goal:** Establish extracted-package evidence for the completed lifecycle/Goal contracts, then define the selected production host's integration scope from its actual source.

**Architecture:** Reuse the existing Hex archive verifier and independent Conversation consumer. Keep Goal optional and reuse ordinary Conversation/Session admission. Production persistence, provider normalization and recovery belong to the selected host; package fixtures prove library contracts only.

**Tech Stack:** Elixir 1.18 / OTP 28, ExUnit, Mix/Hex, Bash, existing GitHub Actions, Deno 2.8.3 and Linux command prerequisites.

---

## Status and scope decision

This is a **reviewable draft**, prepared on 2026-10-14, not an instruction to begin implementation. The previous A/B/C implementation is complete. No new runtime behavior, Goal scheduler, approval expiry or state policy is proposed here.

Local inspection baseline: `c67e57c1522a00b2b813fdef49777c7f955fddd1`, clean main. Implementation `ca19921b` is included through merge `5098c6e8`.

Verified remotely during planning:

- [Agent Runtime CI](https://github.com/gsmlg-opt/backplane/actions/runs/38368420298), at the same baseline: 689 tests, zero failures on Elixir 1.18 / OTP 28; strict production compilation on Elixir 1.20 / OTP 29. The latest lane is compilation only.
- [v1.10.20 release](https://github.com/gsmlg-opt/backplane/releases/tag/v1.10.20) and its [successful workflow](https://github.com/gsmlg-opt/backplane/actions/runs/38371373191), including Agent Runtime Hex publication. These do not prove Goal adoption by a consumer.
- The existing verifier already copies current `conversation_test.exs`, including infinity regressions. Its missing copied cases are provider idle and the Goal suites. There is no evidence here that the current extracted artifact has run those new contracts.

Two independently scoped continuations are available:

| Continuation | Concrete result | Required scope decision |
| --- | --- | --- |
| Package acceptance, Tasks 1–3 below | New contracts exercised through the extracted archive, with continuous CI coverage | Approve verifier and directly related CI/test scope |
| Production host integration | Real persistent Goal across ordinary runs, recovery and user-input races | Name the host/repository before specifying its files or implementation |

The host question is pending. Sigma and Synapsis are candidates, not selected targets. Tasks 1–3 form a concrete package acceptance proposal that does not depend on choosing one. The host launch matrix below remains an acceptance contract, not a fabricated host implementation plan.

## Codex evidence and compatibility boundary

Retain inventory pin `46fdd5ef39735f4159cdcf0ec5e85c10521494e5` and the audited lifecycle revision `a9b0815167c27ab13719dd12d13b63e02b70d221`. Temporary local source directories are inspection conveniences, not plan dependencies.

| Contract | Exact official Codex evidence at a9 |
| --- | --- |
| Optional Goal installed by the host | [app-server extensions](https://github.com/openai/codex/blob/a9b0815167c27ab13719dd12d13b63e02b70d221/codex-rs/app-server/src/extensions.rs#L76-L89) |
| Restore accounting state without automatically starting work | [Goal runtime](https://github.com/openai/codex/blob/a9b0815167c27ab13719dd12d13b63e02b70d221/codex-rs/ext/goal/src/runtime.rs#L412) |
| Ordinary idle admission, serialized with Goal selection and respecting deferral | [continuation](https://github.com/openai/codex/blob/a9b0815167c27ab13719dd12d13b63e02b70d221/codex-rs/ext/goal/src/runtime.rs#L436-L503) |
| Busy admission does not enqueue or steer an existing turn | [thread API](https://github.com/openai/codex/blob/a9b0815167c27ab13719dd12d13b63e02b70d221/codex-rs/core/src/codex_thread.rs#L417) |
| Admission atomically checks Plan, pending input and turn ownership | [turn input](https://github.com/openai/codex/blob/a9b0815167c27ab13719dd12d13b63e02b70d221/codex-rs/core/src/session/turn_input.rs#L460) |
| User provenance and persisted thread ownership | [user context](https://github.com/openai/codex/blob/a9b0815167c27ab13719dd12d13b63e02b70d221/codex-rs/app-server/src/request_processors/thread_goal_user_context.rs#L10), [Goal processor](https://github.com/openai/codex/blob/a9b0815167c27ab13719dd12d13b63e02b70d221/codex-rs/app-server/src/request_processors/thread_goal_processor.rs#L133) |

Backplane-specific adaptations remain explicit: CAS revision plus Goal identity, receipt outboxes, ephemeral capability binding and conservative unknown-usage admission. `Goal.restore/1` does not scan run journals; the host fences ordinary runs, rebuilds bindings, calls `GoalBridge.redeliver/3`, durably checkpoints acknowledgement, then signals idle after Session readiness.

## File ownership and stopping rules

Proposed implementation scope:

- `scripts/verify_agent_runtime_package.sh`: artifact assertions and copied independent-consumer contracts.
- `.github/workflows/agent-runtime.yml`: verifier execution and relevant path filters, retaining existing jobs and prerequisites.
- `test/ci_workflow_test.exs`: only Agent Runtime workflow assertions.
- `docs/superpowers/plans/2026-10-14-agent-runtime-goal-readiness.md`: execution evidence.

Read/reuse existing tests under `apps/backplane_agent_runtime/test/`; do not rewrite their semantics. No production `.ex` changes or sibling repository edits are planned. If package verification exposes a runtime defect, record its exact reproduction and scope a repair before changing production behavior. Route dependency blockers upstream under AGENTS.md.

Tasks 1 and 2 have disjoint edit ownership and may be prepared in parallel after scope authorization. Task 3 depends on both; serialize all Mix/build invocations. Preserve unrelated edits. Stop on an out-of-scope failure and report it without repair.

## Task 1: Exercise the new contracts from the extracted package

**Modify:** `scripts/verify_agent_runtime_package.sh`.
**Reuse:** the existing `test/agent_runtime_packages/conversation/` Mix project and owning-app tests/fixtures.

- [ ] Add the following artifact assertions beside the existing module/document assertions, after extraction:

```bash
for goal_file in \
  lib/backplane/agent_runtime/goal.ex \
  lib/backplane/agent_runtime/goal/state.ex \
  lib/backplane/agent_runtime/goal/store.ex \
  lib/backplane/agent_runtime/goal/host.ex \
  lib/backplane/agent_runtime/goal_bridge.ex; do
  test -f "$unpacked/$goal_file"
done
```

- [ ] After copying the existing Conversation tests/fixtures and before running that consumer, add the following complete copy block. Preserve relative fixture layout; every required file must exist, with no optional skip:

```bash
for contract_test in \
  conversation_provider_idle_test.exs \
  goal_state_test.exs \
  goal_store_conformance_test.exs \
  goal_host_test.exs \
  goal_bridge_test.exs \
  goal_conversation_test.exs \
  goal_stream_accounting_test.exs \
  goal_descendant_usage_test.exs \
  goal_cleanup_test.exs \
  goal_nested_accounting_test.exs; do
  cp "$source_dir/test/backplane/agent_runtime/$contract_test" \
    "$conversation_fixture/test/backplane/agent_runtime/$contract_test"
done
cp "$source_dir/test/fixtures/goal_file_store.exs" \
  "$conversation_fixture/test/fixtures/goal_file_store.exs"
```

This uses `AGENT_RUNTIME_PATH="$unpacked"`, already set by the consumer invocation. It validates packaged modules/resources without copying implementation into the consumer. The file store is a test fixture, not a production durability claim.

- [ ] Check shell syntax:

```sh
bash -n scripts/verify_agent_runtime_package.sh
```

Expected: exit 0. Runtime execution is deferred to Task 3 to avoid concurrent Mix activity.

## Task 2: Keep the package gate in the owning workflow

**Modify:** `.github/workflows/agent-runtime.yml` and the Agent Runtime case in `test/ci_workflow_test.exs`.

- [ ] Extend both push and pull-request `paths` to the following exact list; do not change other workflows:

```yaml
paths:
  - "apps/backplane_agent_runtime/**"
  - "scripts/verify_agent_runtime_package.sh"
  - "test/agent_runtime_packages/**"
  - "test/ci_workflow_test.exs"
  - ".github/workflows/agent-runtime.yml"
```

- [ ] Append this step to the existing `test` job after `Run tests`. Reuse its installed Deno/coreutils and set root working directory explicitly:

```yaml
- name: Verify standalone package and consumers
  working-directory: .
  run: bash scripts/verify_agent_runtime_package.sh
```

Do not add a job or imply the latest compatibility lane runs tests. The verifier also runs package documentation checks and the copied source suite; keep those existing gates visible even though some tests repeat at a different artifact boundary. The optional Sigma probe retains its existing read-only/absent-checkout behavior and is not a Goal integration gate.

- [ ] Add the three extra paths to `assert_package_triggers` in the existing Agent Runtime test, retaining the exact workflow order. Append `"Verify standalone package and consumers"` to that case's `assert_package_steps` list.

- [ ] Add this exact assertion before `assert_agent_runtime_latest_job(workflow)`:

```elixir
assert_step(job, %{
  "name" => "Verify standalone package and consumers",
  "working-directory" => ".",
  "run" => "bash scripts/verify_agent_runtime_package.sh"
})
```

- [ ] Run the directly related workflow test, serially with Task 3's builds:

```sh
devenv shell --no-tui -- mix run --no-start test/ci_workflow_test.exs
```

Expected: zero failures, existing job identities and latest compile assertions retained. If an unrelated workflow assertion fails, record and stop; do not expand this plan to fix it.

## Task 3: Record artifact acceptance at the execution revision

**Modify:** this plan's execution record only.

- [ ] Record the actual execution revision and scoped diff; the planning baseline may have advanced:

```sh
git rev-parse HEAD
git status --short --branch
git diff -- scripts/verify_agent_runtime_package.sh .github/workflows/agent-runtime.yml test/ci_workflow_test.exs
```

- [ ] Verify prerequisites from the same shell used for package validation:

```sh
devenv shell --no-tui -- bash -c 'elixir --version; deno --version; command -v coreutils; command -v setsid; command -v kill; test -r /proc/self/stat'
```

Required: Deno 2.8.3, Elixir >= 1.18 / OTP >= 28, executable single-binary coreutils, setsid and kill, readable Linux process metadata. Inspect each command's output, not only the shell's final status. If unavailable, provision the pinned prerequisites before validation using the existing workflow recipe; do not count skipped native tests as full acceptance.

- [ ] Run the package verifier with no other Mix process building this checkout:

```sh
devenv shell --no-tui -- bash scripts/verify_agent_runtime_package.sh
```

Expected: exit 0; strict compile/docs, source tests, Hex archive isolation, existing consumers, copied Goal/idle cases and examples pass. Record the artifact hash and consumer test count emitted by this run; do not reuse historical counts or claim CI ran uncommitted changes. The verifier cleans its temporary archive on exit, so retain command output as evidence.

- [ ] Check only changed formatting and patch whitespace:

```sh
devenv shell --no-tui -- mix format --check-formatted test/ci_workflow_test.exs
git diff --check
```

Expected: exit 0. No full umbrella suite, release or process restart is required by this plan.

- [ ] Record command versions, exit codes, source revision, artifact hash, actual covered cases and skips. Stop once package acceptance passes. If implementation fixes were needed, save an Agent Note labeled `project: backplane` after their verification.

## Production host launch matrix — requires a named target

Selecting a host produces a separate source-grounded implementation plan with exact host files. Before that selection, no adapter, migration or UI implementation is authorized by this draft.

| Gate | Evidence required from the selected host |
| --- | --- |
| Durable store | Full private Goal record, revision + goal_id CAS, clear tombstone, durable acknowledgement, two owner restarts and conflicting-writer rejection |
| User provenance | Canonical explicit user instruction durably recorded before set/clear; recording failure leaves Goal unchanged; budget omitted unless requested |
| Ordinary admission | Real thread owner checks generation, pending input/interaction, Plan and Session readiness atomically; cancellation/new input invalidate reservations; callback does not call provider or reenter Goal |
| Recovery ordering | Ordinary run fenced/reconciled, Goal restored, fresh bindings rebuilt, committed outbox redelivered/checkpointed, Session ready before idle; lost CAS reply cannot replay provider/tool side effects |
| Provider usage/idle | Actual provider streaming/terminal fixtures normalize authoritative input/cached/output usage once; decreasing/unknown usage closes budgeted auto admission; only validated progress refreshes idle observation |
| Lifecycle races | Two ordinary runs share Goal; queued user input wins against stale continuation; pause/clear/cancel and explicit resume retain deferral fences; budget exhaustion steers wrap-up |
| Descendants/Plan | Late descendant usage retains captured Goal identity, cannot mutate root; trusted Plan runs remain excluded; replacement rejects stale receipts |
| Disabled compatibility | Existing consumer path without Goal still works through its real dispatcher, permissions and provider backend |

The existing Sigma source probe and package-local fixtures cannot satisfy this matrix for a deployed host. Naming the target is necessary because its thread owner, storage transaction and provider adapters determine the implementation files and tests.

## Self-review and execution record

- [x] Previous stage is complete; refreshed merge/CI/publication facts are distinguished from original verification.
- [x] Codex-backed behavior and Backplane host adaptations are separate; pins are unchanged.
- [x] Package task snippets use existing script variables, verified paths and current fixture layout.
- [x] Workflow changes include the exact-path/step assertions they affect; existing job identities remain intact.
- [x] No production host is silently selected, and no release or runtime policy is proposed.
- [ ] Execution scope selected by the user.
- [ ] Tasks 1–3 authorized and completed, or superseded by a named-host plan.
- [ ] Actual execution results recorded.
