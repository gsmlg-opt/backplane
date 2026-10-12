# Optional Codex Goal Runtime Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement task-by-task with disjoint ownership. This is the prepared Goal plan. Repository authority governs execution; no automatic branches, commits, dependency publication, or consumer changes.

**Goal:** Implement Codex-compatible, explicitly enabled thread goals in `backplane_agent_runtime`, using the existing Conversation, Usage, Store, and Codex.Session mechanisms.

**Architecture:** Goal is a specific shared domain extension, not a new generic plugin framework. A thread-scoped Goal process owns accounting and goal transitions; a host supplies durable goal persistence, explicit user mutation provenance, and ordinary turn admission. Conversation delivers acknowledged lifecycle events; the host retains session identity, provider selection, scheduling, UI, and run recovery.

**Tech Stack:** Elixir/OTP GenServer, existing AgentRuntime committed transitions, optional host adapters, ExUnit deterministic providers and in-memory transactional fixtures.

## Source contract and current gaps

Repository root: `/home/gao/Workspace/gsmlg-opt/backplane`.
Implementation scope is `apps/backplane_agent_runtime/`; no Sigma production edits or gateway database migrations.
Keep inventory pin `46fdd5ef39735f4159cdcf0ec5e85c10521494e5`; record the additional behavioral audit commit `a9b0815167c27ab13719dd12d13b63e02b70d221` separately.
Do not repin all tool inventories or rewrite unrelated extension contracts.

Source evidence at the existing pin:

- Goal tools and explicit authorization: [spec.rs:43](https://github.com/openai/codex/blob/46fdd5ef39735f4159cdcf0ec5e85c10521494e5/codex-rs/ext/goal/src/spec.rs#L43-L83).
- Persistent create, final accounting, restricted model status updates: [tool.rs](https://github.com/openai/codex/blob/46fdd5ef39735f4159cdcf0ec5e85c10521494e5/codex-rs/ext/goal/src/tool.rs#L204-L314).
- Remaining budget is `max(0, token_budget - tokens_used)`: [tool.rs:452](https://github.com/openai/codex/blob/46fdd5ef39735f4159cdcf0ec5e85c10521494e5/codex-rs/ext/goal/src/tool.rs#L452-L469).
- Create may replace only a completed goal: [goals.rs:225](https://github.com/openai/codex/blob/46fdd5ef39735f4159cdcf0ec5e85c10521494e5/codex-rs/state/src/runtime/goals.rs#L225-L245).
- Turn/token/tool lifecycle and idle continuation: [extension.rs](https://github.com/openai/codex/blob/46fdd5ef39735f4159cdcf0ec5e85c10521494e5/codex-rs/ext/goal/src/extension.rs#L180-L190), [accounting callbacks](https://github.com/openai/codex/blob/46fdd5ef39735f4159cdcf0ec5e85c10521494e5/codex-rs/ext/goal/src/extension.rs#L224-L525).
- Budget charge excludes cached input and does not add reasoning twice: [accounting.rs:508](https://github.com/openai/codex/blob/46fdd5ef39735f4159cdcf0ec5e85c10521494e5/codex-rs/ext/goal/src/accounting.rs#L508-L532).
- Automatic continuation uses the host's atomic start-if-idle: [runtime.rs:425](https://github.com/openai/codex/blob/46fdd5ef39735f4159cdcf0ec5e85c10521494e5/codex-rs/ext/goal/src/runtime.rs#L425-L521).

Additional audit evidence:

- Explicit host mutations persist user provenance before changing state: [api.rs:144](https://github.com/openai/codex/blob/a9b0815167c27ab13719dd12d13b63e02b70d221/codex-rs/ext/goal/src/api.rs#L144-L210).
- Fork copies the goal snapshot into the target thread: [thread_fork_goal.rs](https://github.com/openai/codex/blob/a9b0815167c27ab13719dd12d13b63e02b70d221/codex-rs/app-server/src/request_processors/thread_fork_goal.rs#L5-L26).

Current `codex/extension_runtime.ex:112-134` implements ephemeral goal CRUD only.
Its `goal_response/1` returns the original budget unchanged and no completion report.
Its replacement rule allows `blocked`, contrary to both audited Codex revisions.
`conversation.ex:630-647` stores raw provider usage, and `finish_turn/2` never reads goal state.
Current CT-06 coverage proves inventory and active replacement refusal, not the lifecycle above.

## Exact file ownership

Create under `apps/backplane_agent_runtime/lib/backplane/agent_runtime/`:

- `goal.ex`: public Goal GenServer, tool/host mutations, committed lifecycle consumption, continuation decisions.
- `goal/state.ex`: pure goal state, source-derived stop rules, accounting baselines and steering decisions.
- `goal/store.ex`: thread goal snapshot/CAS behavior and conformance entry points; no gateway Repo dependency.
- `goal/host.ex`: narrow provenance and turn-admission behavior; no scheduler implementation.

Modify:

- `codex/extension_runtime.ex`: delegate goal tools to a supplied Goal handle; preserve other families and label ephemeral reference mode accurately.
- `codex/backend.ex`: forward committed operation identity and trusted Goal handle; never derive ownership from model arguments.
- `conversation.ex`: optional `:goal`/`:thread_id` binding, acknowledged lifecycle and normalized usage delivery, steering before next effects.
- `conversation_adapter.ex`: define normalized usage envelope and optional Goal integration contract.
- `usage.ex`: only add the smallest reusable report inspection/charge helper if required; keep existing report identity/conflict semantics.
- `codex/multi_agent.ex`: propagate root goal attribution to child usage; retain child identity, scheduling, and finite work admission.
- `EMBEDDING.md`, `PERSISTENCE.md`, `CODEX.md`: host Goal contract, recovery limits, source ledger, explicit opt-in example.

Create tests: `goal_state_test.exs`, `goal_store_conformance_test.exs`, `goal_conversation_test.exs`, `goal_host_test.exs`, `goal_descendant_usage_test.exs` under `test/backplane/agent_runtime/`.
Modify `codex_ct06_test.exs` for delegation/replacement and `usage_test.exs` only for shared helper behavior.
Use test-local fake hosts and transactional stores; add no app-owned persistent database implementation. Create `test/fixtures/goal_file_store.exs` for restart proof, loaded explicitly with `Code.require_file/2` by Goal store/integration tests. This fixture persists a serializable record with write-to-temporary-file followed by atomic rename, and serializes CAS in its fixture owner process. It has no gateway or external database dependency. An in-memory fixture alone cannot prove restart durability.

## Proposed narrow APIs

These are planned Backplane APIs, not claims that these function names exist in Codex.

```elixir
Goal.start_link(thread_id: thread_id, owner_pid: host_pid,
  store: StoreAdapter, store_context: ctx, host: HostAdapter,
  host_context: host_ctx, max_goal_token_budget: nil)
Goal.get(goal)
Goal.set(goal, mutation, user_instruction)
Goal.clear(goal, user_instruction)
Goal.restore(goal) # load/accounting reconciliation only; no implicit dispatch
Goal.fork_snapshot(goal, target_thread_id) # copy committed snapshot only
Goal.bind(goal, attrs) # validate host/thread/current run authority; return ephemeral binding
Goal.unbind(goal, binding) # fence that run after acknowledged settlement
Goal.tool(goal, operation) # only get_goal/create_goal/update_goal
Goal.committed(goal, event) # idempotent acknowledged lifecycle/usage input
Goal.idle(goal, host_generation) # requests ordinary start_turn_if_idle admission
Goal.State.new(thread_id, opts) # {:ok, private_state}
Goal.State.create(state, attrs) # {:ok, next_state} | {:error, Error.t()}
Goal.State.update(state, :model, attrs) # same result; restricted status transition
Goal.State.account(state, receipt) # same result; existing Usage receipt deduplication
Goal.State.response(state) # current source-compatible goal response map
Goal.State.snapshot(state) # private persisted record, including internal goal identity
```

Store callbacks: `load(context, thread_id)`, `compare_and_swap(context, thread_id, expected_revision, expected_goal_id, next_record)`.
Load returns `{:ok, %{revision: non_neg_integer(), goal: map() | nil, receipts: map(), continuation_deferral: map() | nil}}`; empty thread is revision 0 with nil goal.
CAS returns the same record with revision advanced exactly once, or `{:error, %Error{class: :resource_conflict}}`; other persistence errors use existing Error classes.
Cleared state retains its monotonically advanced revision and receipt fences as a tombstone, so delete/recreate cannot create an ABA race.
CAS atomically writes the goal snapshot, accounting receipt identities, and continuation deferral; retries of the same receipt cannot charge twice.
`expected_goal_id` fences old-goal reports/status changes; CAS conflicts cause reload/re-evaluation, never blind status overwrite.
The host's storage adapter decides SQLite/PostgreSQL/journal transactions; the shared package does not own that technology.

Host callbacks:

```elixir
@callback record_user_instruction(term(), binary(), map()) :: :ok | {:error, Error.t()}
@callback start_turn_if_idle(term(), binary(), map()) ::
  {:ok, {:started, map()}} | {:ok, {:not_submitted, atom()}} | {:error, Error.t()}
```

Admission request includes `expected_goal_id`, `goal_revision`, host generation, trigger `:goal`, root/parent turn attribution and the source-derived contextual steering item.
The host atomically reserves ordinary turn admission and returns run/turn identities; it does not run providers in this callback.
The host routes selected resource lifetime through existing `Codex.Session.bind/attach/detach`, with a fresh run identity. `Goal.bind/2` attributes Goal work; it does not replace Session admission or confer tool grants. Its attrs contain thread_id, run_id, incarnation, current authority, and trusted execution mode. The opaque binding is never provider input or a persisted PID/token.
A host without persistent thread storage cannot enable durable Goal semantics; retain the explicitly named ephemeral reference mode for conformance fixtures only.
No new session manager, queue implementation, broad extension registry, provider client, or scheduling timer loop is introduced.

Committed lifecycle envelopes have one common identity and immutable binding:

```elixir
%{receipt_id: "run:incarnation:revision:event", revision: revision,
  thread_id: thread_id, run_id: run_id, incarnation: incarnation,
  turn_id: turn_id, expected_goal_id: goal_id, type: type, payload: payload}
```

Payloads: `:turn_started` has mode, trigger, root/parent turn IDs and normalized usage baseline; `:usage` has attempt_id, report identity and input/cached/output metrics; `:tool_finished` has tool/call ID, success, handler_executed and settlement certainty; `:item_completed` has classified assistant/reasoning/tool activity; `:turn_stopped` has outcome; `:turn_aborted` has explicit reason; `:turn_error` has normalized error classification.
`expected_goal_id` comes from the acknowledged Goal binding captured for that turn/attempt, never from a later read of whichever goal is current.
Thread/run/incarnation mismatches are refused; event revision/receipt identity must come from committed runtime transition identity, never model parameters.
Duplicate receipt plus identical digest is a no-op; duplicate receipt plus different payload is a conflict. No new effects run until required accounting acknowledgement succeeds.
Write required Goal delivery intents into the existing committed run outbox/checkpoint alongside the provider/tool lifecycle transition; acknowledge delivery only after Goal CAS succeeds.
If the run journal commit succeeds but Goal delivery fails or the process crashes, the host reconciles/redelivers the same committed receipt before new work; it never replays the provider or tool to recover accounting.
Goal tool mutations persist invocation identity, request digest and returned response atomically with the mutation. Crash after goal write but before Conversation tool-result checkpoint returns the cached response on redelivery instead of creating/updating the goal twice.

## State and identity invariants

Goal snapshot: thread_id, goal_id, objective, status, token_budget, tokens_used, time_used_seconds, created_at_ms, updated_at_ms, revision.
Private accounting state holds current run/incarnation/turn/attempt baselines, active_goal_id, receipt IDs, descendant attribution, counters and budget-steering marker.
Goal identity survives multiple Conversation runs; attach authority uses current host-owned run identity without making the goal belong to that run.
Statuses mirror Codex: `active`, `complete`, `paused`, `blocked`, `budget_limited`, `usage_limited`.
Model update accepts only complete/blocked/paused; user/host controls resume, objective/budget changes and clear.
`create_goal` rejects active, paused, blocked and budget/usage-limited replacement; it can replace complete only.
User-request creation/pause and three-turn blocking rules remain exact source tool instructions; do not invent a conversational intent parser.
Goal remains optional: ordinary Conversation completion and ordinary tasks do not implicitly create one.
Explicit host `set`/`clear` records canonical user provenance before the committed state change; failed provenance leaves goal state unchanged.
An unavailable host/store closes Goal admission and returns an error without claiming the goal was completed, paused or blocked.

## Task G1: State transitions and persistence contract

- [x] Add goal-only state/store modules and transactional fake-store fixture.
- [x] Add the file-backed test fixture and verify a committed snapshot, tombstone revision, receipt ledger, and continuation deferral survive termination of both Goal and fixture store owner, followed by fresh processes loading the same temporary directory. Decode only fixture-produced records with `:erlang.binary_to_term(binary, [:safe])`; no PIDs, functions, capabilities, or monotonic timestamps enter persisted records. Keep production storage technology host-owned.
- [x] Preserve completed-only replacement and model/user mutation separation.
- [x] Apply completed-only replacement to the existing ephemeral reference backend too, while preserving its run-scoped contract and other tool families.
- [x] Test expected_goal_id mismatch, stale revision, delete/recreate fencing, repeated receipts, and failed provenance.
- [x] Port source accounting status precedence: budget exhaustion beats model pause/block; explicit complete can finish achieved work with final accounting.
- [x] Test host resume of previously blocked goal resets consecutive blocking/failure audit.

```elixir
defmodule Backplane.AgentRuntime.GoalReplacementTest do
  use ExUnit.Case, async: true
  alias Backplane.AgentRuntime.Goal.State

  test "blocked goal cannot be replaced by create_goal" do
    assert {:ok, state} = State.new("thread-1", [])
    assert {:ok, state} = State.create(state, %{objective: "finish migration"})
    assert {:ok, state} = State.update(state, :model, %{status: :blocked})
    assert {:error, %{class: :resource_conflict}} =
      State.create(state, %{objective: "replace"})
    assert %{goal: %{objective: "finish migration"}} = State.response(state)
  end
end
```

## Task G2: Normalize and commit usage once

- [x] Extend ConversationAdapter's usage contract with stable report identity and authoritative per-attempt delta metrics.
- [x] Normalize cumulative provider snapshots into deltas using saved per-attempt baselines; terminal repeats and usage_updated replay resolve to one receipt.
- [x] Carry run/incarnation/turn/attempt/context identity through existing `Usage.report/2`; conflicting same-ID values remain errors.
- [x] Fix the current `usage.ex:22-30` duplicate branch: the following unconditional duplicate return discards its digest-conflict error. Add a focused regression asserting same identity/different metrics returns resource_conflict without changing totals.
- [x] Write and run this existing-module regression before the surgical duplicate-branch repair:

```elixir
test "same usage identity with changed metrics is a conflict" do
  alias Backplane.AgentRuntime.Usage
  assert {:ok, usage} = Usage.new()
  first = %{identity: "goal-accounting-1", input_tokens: 10,
    output_tokens: 2, cached_tokens: 0}
  assert {:ok, usage, %{status: :recorded}} = Usage.report(usage, first)
  totals = Usage.totals(usage)
  assert {:error, %{class: :resource_conflict}} =
    Usage.report(usage, %{first | input_tokens: 20})
  assert Usage.totals(usage) == totals
end
```

The preparation source probe returned `{:ok, _, %{status: :duplicate}}` for this conflicting input. Expected initial ExUnit failure: the `{:error, ...}` match fails. The minimal repair removes the unconditional duplicate return after the existing digest comparison; retain identical-report idempotency.
- [x] Commit normalized reports with the provider transition before forwarding acknowledged receipts to Goal.
- [x] Charge `max(0, input_tokens - cached_tokens) + output_tokens`; reasoning is included in output and never added again.
- [x] Distinguish missing cached/input/output from known zero. Partial totals do not prove a fully known charge.
- [x] Require authoritative normalized usage capability for budgeted Goal admission; if it becomes unknown, expose accounting uncertainty and suspend budgeted automatic admission pending host reconciliation. This is an adaptation of Backplane's existing unknown-metrics contract, not an additional Codex goal status or an upstream rule.
- [x] Do not turn missing usage into zero or invent a budget_limited status. A failed report commit emits no charged receipt or continuation.
- [x] Persist a receipt with expected_goal_id and debit it once across provider, stop, tool completion and recovery redelivery.
- [x] Starting a goal mid-turn establishes a fresh baseline; previously consumed tokens are not retroactively assigned to the new goal.
- [x] Record monotonic elapsed active-goal time with persisted accumulated seconds; reconstruct a fresh monotonic baseline after restore, not a serialized BEAM clock.
- [x] Treat elapsed usage as reporting, not an implicit goal deadline; human waits and Goal elapsed reporting are distinct from run/effect pause mechanics.

```elixir
defmodule Backplane.AgentRuntime.GoalChargeTest do
  use ExUnit.Case, async: true
  alias Backplane.AgentRuntime.Goal.State

  test "cached input and duplicate reports do not inflate goal use" do
    assert {:ok, state} = State.new("thread-1", [])
    assert {:ok, state} = State.create(state, %{objective: "ship", token_budget: 100})
    receipt = %{receipt_id: "run-1:1:2:usage", revision: 2,
      thread_id: "thread-1", run_id: "run-1", incarnation: 1, turn_id: "turn-1",
    expected_goal_id: State.snapshot(state).goal.goal_id, type: :usage,
      payload: %{attempt_id: "attempt-1", identity: "attempt-1:usage",
        input_tokens: 50, cached_tokens: 40, output_tokens: 7, reasoning_tokens: 5}}
    assert {:ok, state} = State.account(state, receipt)
    assert {:ok, state} = State.account(state, receipt)
    assert %{goal: %{tokens_used: 17}, remaining_tokens: 83} = State.response(state)
  end
end
```

## Task G3: Conversation lifecycle and budget wrap-up

- [x] Bind optional thread Goal capability when admitting a fresh Conversation run; validate thread/owner/run/incarnation before effects.
- [x] After acknowledged turn-start checkpoint, establish trusted host-provided mode and usage baseline before provider dispatch; Plan mode excludes goal token accounting as in Codex. Ordinary callers default to execution mode; do not infer a mode from model/user text. Add mode to the optional Goal binding, not to model-callable tool arguments.
- [x] Deliver acknowledged provider/tool/turn results as idempotent receipts, retaining existing tool settlement and uncertain-outcome handling.
- [x] Flush final progress before complete/paused/blocked model mutation and before turn/run cleanup acknowledgements.
- [x] At a tool-finish budget boundary, persist `budget_limited` and inject Codex's budget-limit steering once per goal into the active turn.
- [x] Allow that turn to produce the source-directed wrap-up; do not cancel the just-finished tool or falsely mark the objective complete.
- [x] Turn-stop accounting closes active attribution; stopped statuses do not schedule additional goal turns.
- [x] Return actual remaining budget and complete-only budget report through the existing three extension tools. Match the source response shape; internal goal identity, receipt ledgers, authority, and bindings remain in `State.snapshot/1` and are not exposed through `State.response/1`.
- [x] Keep `goal_id` as the persisted/source Goal field; map legacy ephemeral reference `id` only at that compatibility boundary, without modifying unrelated extension records.
- [x] Existing stop hooks, follow-up queues and terminal resource cleanup retain their ownership; Goal receives outcomes instead of replacing those flows.
- [x] An interrupted/uncertain run accounts only known committed usage, revokes continuation and keeps run recovery/fencing requirements before new admission.

## Task G4: Host admission, mutation and recovery races

- [x] Serialize Goal mutation/read/admission selection in the Goal owner; `start_turn_if_idle` is a fast reservation boundary and may not reenter Goal synchronously.
- [x] Mark the reserved automatic turn before processing its first lifecycle completion; very fast turns must not finish before automatic-turn attribution exists.
- [x] Busy thread, queued user input, pending interaction, closed Session or stale host generation returns not_submitted; no periodic polling or duplicate user prompt.
- [x] Explicit set/clear/pause and host interruption revoke pending continuation generation before later admission can start.
- [x] Host admission validates its current generation atomically with idle reservation; stale requests after cancellation are refused.
- [x] Keep goal mutation serialized across read/start reservation so a replaced/cleared goal cannot launch from an old snapshot.
- [x] Persist interruption continuation deferral separately from goal status; restoring active state alone must not erase user interruption or auto-start work.
- [x] Retain both audited source identities in the behavioral ledger: interruption counter handling uses a9's `interrupt_turn` distinction; do not silently claim all lifecycle details are unchanged from pin46.
- [x] `restore/1` reloads/reconciles pending accounting receipts; host explicitly signals ready/idle after ordinary run fences and Session readiness.
- [x] Fork copies objective/status/budget/counters/timestamps/goal identity to the new thread exactly as upstream snapshot semantics; live owner capabilities, receipts tied to source run and active tasks are not copied.
- [x] Tests cover delayed store acknowledgement, concurrent clear/resume, duplicate idle signals, prompt-vs-continuation, owner death, and stop-before-reservation acknowledgement.

## Task G5: Failure stopping and descendants

- [x] Port Codex source rules: provider usage-limit error yields usage_limited; exhausted/nonretryable turn error blocks automatic continuation.
- [x] Count three consecutive executed code-mode `exec` failure turns without a successful tool; successful tools reset that audit.
- [x] Count three truly empty automatic goal turns; tool/reasoning/assistant activity resets emptiness, commentary-only emptiness follows upstream classification.
- [x] Distinguish these runtime safety rules from the tool instruction requiring repeated external blocking across three goal turns.
- [x] Carry root_goal_id/root_thread_id at child admission using existing MultiAgent/RunTree identity, never model-supplied goal ownership.
- [x] Credit every descendant report once to the root goal, including late reports while the root is idle; preserve the expected root goal ID captured for that work.
- [x] Child-local accounting and root charges are separate views of one report; do not sum child totals again at child completion.
- [x] Replacing/completing/clearing a root goal prevents old child receipts from debiting a new goal; known final usage may settle the old snapshot under its allowed accounting mode.
- [x] Keep child cancellation, handoff and work quotas in existing owners; Goal accounting does not introduce a second child scheduler.

## Task G6: Scoped validation and host launch gate

- [x] Run each new test file first and confirm a meaningful failure before implementation; use deterministic latch messages rather than long sleeps.
- [x] Run Goal integration and existing scoped CT-06/Session/MultiAgent/Usage checks after dependencies are merged.
- [x] Document an embedding example with host-owned thread_id, supplied Store/Host adapters, explicit Goal enablement, and existing Session reuse.
- [x] Document missing durable adapter/usage capability refusal and interrupted-run recovery before automatic continuation.
- [x] Save the required agent note with `project: backplane` after implementation, without copying credentials or private provider data.

```sh
devenv shell --no-tui -- bash -c 'cd apps/backplane_agent_runtime && MIX_ENV=test mix test test/backplane/agent_runtime/goal_state_test.exs test/backplane/agent_runtime/goal_store_conformance_test.exs test/backplane/agent_runtime/goal_conversation_test.exs test/backplane/agent_runtime/goal_host_test.exs test/backplane/agent_runtime/goal_descendant_usage_test.exs'
devenv shell --no-tui -- bash -c 'cd apps/backplane_agent_runtime && MIX_ENV=test mix test test/backplane/agent_runtime/codex_ct06_test.exs test/backplane/agent_runtime/codex_session_lifetime_test.exs test/backplane/agent_runtime/codex_multi_agent_profile_test.exs test/backplane/agent_runtime/usage_test.exs'
```

Run builds serially. Expected: scoped tests pass, changed-file formatting passes, selected child app compiles with warnings as errors.
Do not claim full CI or downstream Sigma runtime proof from these checks.
Unrelated failures are reported and left untouched.
Goal state/store/usage work can proceed independently of optional run-deadline work; continuation launch requires both accounting completion and current run/Session recovery readiness.
Launch preparation ends with a reviewable implementation plan, source ledger, scoped tests and a host adapter contract; actual production rollout and consumer updates require separately authorized work.

## Execution evidence

See [the final validation record](2026-10-13-agent-runtime-validation.md). Checkboxes record verified behavior; illustrative helper snippets above are design sketches, and production helper names may differ. Native/cleanup fixtures use reversible prior-boundary regression probes where concurrent implementation preceded the first fixture run. The final full suite used four concurrent cases and the first complete run seed.
