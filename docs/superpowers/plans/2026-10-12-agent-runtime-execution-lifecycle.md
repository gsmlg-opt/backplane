# Phase A and B: deadline and provider idle timeout implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement task-by-task. Execute checkboxes in order; parallelize disjoint edits and serialize Mix builds. This is the prepared execution plan. Do not commit, push, create branches, restart services, or modify a consumer without explicit authority.

**Goal:** Deliver issue #65's explicit disabled whole-run deadline, then an independent opt-in provider idle timeout matching Codex's stream observation behavior.

**Architecture:** Keep deadline enforcement, effect ownership, cancellation, and recovery in `backplane_agent_runtime`. Use `deadline: :infinity` as an explicit durable disabled mode; `nil` remains the legacy unset deadline. Provider idle observation is a separate finite timer policy, independent of tool deadlines and bounded store/cleanup work.

**Tech Stack:** Elixir 1.18+, OTP 28+, GenServer/Task supervision, the existing Store/Kernel contract, ExUnit, standalone Mix package through root devenv.

## Source baseline and delivery boundaries

- Official Codex baseline: `a9b0815167c27ab13719dd12d13b63e02b70d221`.
- Existing package tool-inventory pin: `46fdd5ef39735f4159cdcf0ec5e85c10521494e5`. Preserve that inventory pin, record `a9b0815167c27ab13719dd12d13b63e02b70d221` as the additional behavioral reference, and link each cited path to its audited commit.
- Cancellation-driven ordinary turns: `codex-rs/core/src/tasks/mod.rs:369` and `tasks/regular.rs:104` at that commit.
- Per-observation stream timeout: `codex-rs/codex-api/src/sse/responses.rs:535-540`, wrapping each `stream.next()` with `idle_timeout`.
- Child followup uses the existing thread without cumulative remaining time: `core/src/agent/control.rs:134-160`, `agent/control/api.rs:145-169`.
- Agent wait timeout expires observation only: `core/src/tools/handlers/multi_agents_v2/wait.rs:202-219`.
- Scope: package `apps/backplane_agent_runtime/**` only. No gateway-wide timeout configuration or Sigma migration in these phases.
- Phase A is independently shippable and implements all issue #65 acceptance checks. Phase B is separate Codex alignment, not a prerequisite to close #65.
- Preserve defaults: run 300,000ms; effect 30,000ms; commit/cleanup 5,000ms; finite maximum 3,600,000ms.
- Preserve output limits, work quotas, intent-before-dispatch, incarnation/revision fencing, and uncertain external-effect classification.
- `:infinity` is accepted only for `run_timeout`; it remains invalid for effect, commit, cleanup, and provider idle options.

## Task 0: prepare isolated package verification without changing running services

- [x] Capture `git status --short`, package version and current diff before edits; preserve unrelated files. These documents are prepared in the root checkout. Broad production implementation follows the master plan's isolated-worktree boundary; any authorized worktree belongs under `.trees/`.
- [x] Confirm Elixir 1.18.5 / OTP 28 in the root devenv shell. Existing `_build` is not proof dependencies are installed.
- [x] Fetch only standalone package dependencies, then execute each focused command serially:

```sh
devenv shell --no-tui -- sh -c 'cd apps/backplane_agent_runtime && env MIX_ENV=test mix deps.get'
```

- [x] `devenv` 2.2.2 has no `-d` flag; invoke it from the project root and change into the package inside the shell, as above.
- [x] Native Code Mode integration requires Deno 2.8.3; the readiness inspection found Deno absent in both host and devenv. Coreutils and the BEAM toolchain are available. Prepare the exact pinned Deno toolchain before running Code Mode integration; do not silently skip Deno tests or substitute another version.
- [x] Dependency fetch/configuration failure is an environment gate, not a product regression. Do not change package dependency constraints to bypass it. For an owned upstream dependency bug, follow repository issue-routing/blocker rules.

## File responsibilities

- `lib/backplane/agent_runtime/execution.ex`: option validation, authoritative durable deadline resolution, canonical command metadata, finite commit/effect budgets.
- `lib/backplane/agent_runtime/kernel.ex`: preserve finite/infinite execution deadline through admission, intents, checkpoints and replay.
- `lib/backplane/agent_runtime/types.ex`: document `deadline: integer() | :infinity | nil`.
- `lib/backplane/agent_runtime/conversation.ex`: root timer absence, bounded effects/nested tools, approval interactions, streaming idle timers.
- `lib/backplane/agent_runtime/execution_controller.ex`: root timer absence plus finite effect and cleanup timers for direct controller callers.
- `lib/backplane/agent_runtime/approval.ex`: explicit unbounded approval expiry without fabricating a new TTL; preserve exact approval identity and operation checks.
- `lib/backplane/agent_runtime/codex/multi_agent.ex`: carry infinite child mode and existing remaining-work limits through followup/resume.
- `README.md`, `EMBEDDING.md`, `PERSISTENCE.md`, `CODEX.md`, `SCHEMAS.md`, `CHANGELOG.md`: public API, durable sentinel, source references and compatibility.
- Existing `test/backplane/agent_runtime/*` suites remain the primary regression locations. New standalone idle-timer tests may use `conversation_provider_idle_test.exs`.

## Task A1: define finite versus disabled mode at every execution boundary

**Files:** execution.ex, kernel.ex, types.ex; execution_test.exs, execution_correctness_test.exs.

- [x] Add failing limit tests directly inside `ExecutionTest`:

```elixir
test "run timeout alone accepts infinity" do
  assert {:ok, %{run: :infinity, effect: 30_000}} =
           Execution.validate_limits(run_timeout: :infinity)
  for key <- [:effect_timeout, :commit_timeout, :cleanup_timeout] do
    assert {:error, %Error{class: :validation}} =
             Execution.validate_limits([{key, :infinity}])
  end
end
```

- [x] Run the scoped file below; expect the infinite run assertion to fail before implementation.
- [x] Keep `finite_timeout/3` for the three bounded options; add an explicit run-only validator:

```elixir
defp run_timeout(opts) do
  case Keyword.get(opts, :run_timeout, @default_run_timeout) do
    :infinity -> {:ok, :infinity}
    _ -> finite_timeout(opts, :run_timeout, @default_run_timeout)
  end
end
defp absolute_deadline(%{deadline: :infinity}, _run_timeout, _opts), do: :infinity
defp absolute_deadline(%{deadline: deadline}, _run_timeout, _opts)
     when is_integer(deadline), do: deadline
defp absolute_deadline(_record, :infinity, _opts), do: :infinity
defp absolute_deadline(_record, run_timeout, opts), do: wall_now(opts) + run_timeout
```

- [x] Make `effective_timeout/4` branch on the resolved deadline: `:infinity -> {:ok, configured}`; integer -> current positive-remaining calculation. Add a `validate_record_deadline(%{deadline: :infinity}, _opts)` clause.
- [x] Canonical admission and provider/tool intent commands persist the sentinel. Kernel `maybe_put_execution_deadline/2` accepts it only when the current deadline is unset; checkpoint resume preserves an already infinite deadline. Finite admission/checkpoint rules stay unchanged; options cannot disable an already finite admitted record.
- [x] Add `base_record()` admission regressions with `wall_now: fn -> 1_000 end`: infinity produces the sentinel; omitted timeout produces `301_000`; an admitted infinity record with default options stays infinite at `wall_now: fn -> 1_000_000 end`.
- [x] Add invalid sentinel tests (`"infinity"`, `:disabled`, negative integers) at the atom-key runtime API. Durable adapters may encode the sentinel as the JSON string `"infinity"`, but must normalize it explicitly when reading; never create atoms dynamically.

Run from project root:

```sh
devenv shell --no-tui -- sh -c 'cd apps/backplane_agent_runtime && env MIX_ENV=test mix test test/backplane/agent_runtime/execution_test.exs test/backplane/agent_runtime/execution_correctness_test.exs'
```

## Task A2: disable root timers while retaining bounded owned work

**Files:** conversation.ex, execution_controller.ex; conversation_test.exs, execution_controller_test.exs.

- [x] Add the timer regression below using the existing ConversationTest `start/1` fixture:
- [x] State references were checked against Conversation's current map: root timer is `state.timer` / `state.timer_generation`; owned effect timer is `state.effect.timer` / `state.effect.timer_generation` (`conversation.ex:180-185,1177-1184`). Preserve those names in the implementation and tests.

```elixir
test "infinite run has no root timer but finite effect timer" do
  {pid, _store} = start(run_timeout: :infinity, effect_timeout: 500)
  assert {:ok, _} = Conversation.prompt(pid, "work")
  assert_receive {:provider, _request, provider}
  state = :sys.get_state(pid)
  assert state.run.deadline == :infinity
  assert state.timer == nil
  assert state.timer_generation == nil
  assert is_reference(state.effect.timer)
  send(provider, {:events, [done("finished")]})
  assert_receive {:agent_runtime, "test", %{type: :run_completed}}
end
```

- [x] Replace unconditional `now() + limits.run` and root `send_after` with finite/infinite branches. Construct fresh state lazily so restored `:run` does not evaluate deadline arithmetic first.
- [x] Outer/nested timeouts resolve `:infinity` to `limits.effect`, and finite deadlines to `max(1, min(limits.effect, deadline - now()))`.
- [x] Interaction pause stores `paused_run_remaining: :infinity`; resume preserves durable infinity and does not arm a root timer. Effect/nested remaining milliseconds still pause/resume and receive fresh timer generations.
- [x] Controller `arm_run_timer/1` explicitly clears any prior root timer for infinity; `effective_effect_timeout/1` continues using finite effect timeout. Never make its cleanup timer optional.
- [x] Add multi-effect success beyond a comparable finite root limit using gated provider/tools and short controlled delays; pair with the existing finite cancellation test. Inject stale generation messages directly after pause/resume to prove they cannot stop the current effect.
- [x] Add finite effect timeout, explicit cancellation during provider/tool/interaction waits, gated commit timeout, and stalled cleanup regressions with `run_timeout: :infinity`; preserve `unknown_outcome` for tools lacking settlement proof.

Run: `devenv shell --no-tui -- sh -c 'cd apps/backplane_agent_runtime && env MIX_ENV=test mix test test/backplane/agent_runtime/conversation_test.exs test/backplane/agent_runtime/execution_controller_test.exs test/backplane/agent_runtime/conversation_uncertain_effects_test.exs'`.

## Task A3: preserve approval, child continuation and durable recovery

**Files:** approval.ex, conversation.ex, codex/multi_agent.ex, PERSISTENCE.md; approval_test.exs, codex_multi_agent_profile_test.exs, recovery_harness_test.exs, store_conformance_test.exs.

- [x] Add approval tests proving approved and denied tools work with infinite runs and cancellation while awaiting approval cannot invoke the backend.
- [x] Keep Conversation-generated approval `expires_at: s.run.deadline`; recognize explicit `:infinity` only with integer `current_time`, retaining exact approval ID, tool revision, digest and resolver checks:

```elixir
case {now, expires_at} do
  {now, :infinity} when is_integer(now) -> {:ok, :infinity}
  {now, expiry} when is_integer(now) and is_integer(expiry) and now <= expiry ->
    {:ok, expiry}
  _ -> {:error, Backplane.AgentRuntime.Error.new(:validation, "approval is expired")}
end
```

- [x] Do not invent a finite approval lifetime. This sentinel removes the existing root-derived expiry only; the operation binding and authority checks remain mandatory. Document this as the compatibility adaptation to Codex's bound approval responses.
- [x] Change `carry_limits/2`: calculate work first; for infinite prior deadline keep finite requested replacement timeout if explicitly requested, otherwise preserve infinity; for finite prior deadline retain remaining-time clamp. Never reset consumed work or turn uncertain snapshots into safe replacements.
- [x] Add this helper and have `carry_limits/2` use its successful timeout when constructing replacement opts; do not rely on Erlang term ordering between integers and `:infinity`:

```elixir
defp carry_timeout(:infinity, opts),
  do: {:ok, Keyword.get(opts, :run_timeout, :infinity)}
defp carry_timeout(deadline, opts) when is_integer(deadline) do
  remaining = deadline - System.system_time(:millisecond)
  requested = Keyword.get(opts, :run_timeout, :infinity)
  cond do
    remaining <= 0 ->
      {:error, Error.new(:timeout, "agent deadline has expired")}
    requested == :infinity -> {:ok, remaining}
    is_integer(requested) and requested > 0 -> {:ok, min(requested, remaining)}
    true -> {:error, Error.new(:validation, "invalid replacement run timeout")}
  end
end
```

- [x] Regression matrix covers finite prior + requested infinity => remaining finite; infinite prior + omitted => infinity; infinite prior + finite => finite; exhausted prior finite => timeout. Invalid requested values must fail normal `Execution.validate_limits/1` before child launch, including the infinite-prior branch.
- [x] Add completed child followup, interrupted-safe child replacement, and V1 closed-child resume tests for infinite mode; assert no arithmetic failure and existing work quota remains reduced.
- [x] Extend existing durable harness fixtures to round-trip admitted infinity through store/load/replay/fence and then resume options omitted. Terminal restored Conversation stays terminal; active restored Conversation stays `recovery_required` and dispatches nothing.
- [x] Test legacy nil record with finite defaults still acquires a finite deadline; finite saved deadlines are not regenerated; explicit infinity is never replaced by a distant timestamp. Document adapter atom/string normalization requirements without adding a package-owned journal.

Run: `devenv shell --no-tui -- sh -c 'cd apps/backplane_agent_runtime && env MIX_ENV=test mix test test/backplane/agent_runtime/approval_test.exs test/backplane/agent_runtime/codex_multi_agent_profile_test.exs test/backplane/agent_runtime/recovery_harness_test.exs test/backplane/agent_runtime/store_conformance_test.exs'`.

## Phase A exit gate

- [x] All five #65 checks pass: cumulative healthy effects, finite deadline expiry, bounded effect/commit/cleanup, explicit cancellation, durable/interaction preservation.
- [x] Document `run_timeout: :infinity` with finite effect/commit/cleanup values and host reconciliation after uncertain cancellation. Add the release note without bumping/releasing the package automatically.
- [x] Scoped format and strict compilation succeed; save implementation/validation note labeled `project: backplane` when implementation is complete. Do not write a note claiming implementation during planning.

## Task B1: opt-in provider idle policy independent of total tool timeout

**Files:** execution.ex, conversation.ex, EMBEDDING.md, CODEX.md; provider_output_test.exs, conversation_provider_idle_test.exs.

- [x] Add `provider_idle_timeout` option with `nil` default, positive finite integer maximum 3,600,000ms. Omission retains current provider total `effect_timeout`; configuration opts into provider-only idle observation and replaces that provider's total effect timer. Hooks, approvals and tools still use bounded `effect_timeout`.
- [x] Add failing validation cases: nil/30/300_000 accepted; zero/negative/string/`:infinity` rejected. Add a controlled provider that emits every 20ms for 120ms with idle 50ms and effect 70ms; expect completion. Pair with omission using the same provider; expect the existing total-effect timeout.
- [x] Validate the optional option alongside the bounded effect limit using this private helper, and include `provider_idle` in the validated limits map:

```elixir
defp provider_idle_timeout(opts) do
  case Keyword.get(opts, :provider_idle_timeout) do
    nil -> {:ok, nil}
    _ -> finite_timeout(opts, :provider_idle_timeout, @default_effect_timeout)
  end
end
```
- [x] Use the same owned effect entry/timer field and fresh generation for each accepted progress event; no second independent timer is needed:

```elixir
defp provider_timeout(%{opts: opts, limits: limits}) do
  Keyword.get(opts, :provider_idle_timeout) || limits.effect
end
# For provider roles only, arm provider_timeout(s), capped by finite root remaining time.
# On validated provider progress: cancel old effect.timer, mint generation,
# send {:timeout, effect.task.ref, generation}, and update effect_live_deadline.
```

- [x] Refactor stream reduction so `collect/2` validation succeeds before progress is acknowledged. Malformed/duplicate tool events, output-limit errors, unknown events, stale tokens and tool-origin metadata must never rearm the provider timer.
- [x] Route provider progress through a dedicated `{:provider_chunk, token, event}` owner call; keep tool `{:chunk, token, event}` metadata path separate. The owner validates provider role/token and output limits before emitting and refreshing idle observation.
- [x] First event is bounded: arm idle observation when provider starts, not after first output. Every successful normalized provider event accepted from enumeration refreshes observation; completion is acknowledged then clears the timer through normal settlement.
- [x] State explicitly that normalized enumeration cannot observe raw SSE comments/unforwarded transport events. Host transport adapters still own raw `stream.next()` idle policy; adapters must not claim exact raw-SSE parity from normalized heartbeats alone.

## Task B2: idle pause, timeout settlement and message races

**Files:** conversation.ex; conversation_provider_idle_test.exs, conversation_test.exs, conversation_uncertain_effects_test.exs.

- [x] Gate provider interaction with `context.interact`, wait beyond the idle timeout, resolve, then produce output within the saved remaining time. Assert the wait is paused and finite/infinite root semantics remain correct.
- [x] Test an active provider stall expires after idle timeout despite infinite root; a finite root still expires even when valid progress keeps refreshing idle observation.
- [x] After each refresh inject the prior `{:timeout, task_ref, prior_generation}`; assert the active provider survives. Inject an event from an old token and a tool progress event; neither changes provider idle generation.
- [x] Verify malformed event and output-limit failures terminate through existing provider failure paths; no automatic provider retry is added. Verify mutating tool timeout still yields uncertain reconciliation and is never converted to a routine tool error.
- [x] Cancellation during streaming/interaction kills the owned task, fences its token, rejects late chunks and leaves bounded cleanup intact.

Run: `devenv shell --no-tui -- sh -c 'cd apps/backplane_agent_runtime && env MIX_ENV=test mix test test/backplane/agent_runtime/conversation_provider_idle_test.exs test/backplane/agent_runtime/provider_output_test.exs test/backplane/agent_runtime/conversation_test.exs test/backplane/agent_runtime/conversation_uncertain_effects_test.exs'`.

## Phase B exit and launch preparation

- [x] Examples show explicit `run_timeout: :infinity, provider_idle_timeout: 300_000` and explain independently bounded tool work. Callers omitting both options retain existing timeout behavior.
- [x] Run package tests once after focused files pass and the exact Deno prerequisite is ready: `devenv shell --no-tui -- sh -c 'cd apps/backplane_agent_runtime && env MIX_ENV=test mix test'`. Do not run umbrella tests or repair unrelated apps. If an out-of-phase suite fails, report it and stop without extending scope.
- [x] Standalone `.formatter.exs` exists and covers lib/test/examples/config. Use explicit runtime targets to avoid incidental example/config scope: `devenv shell --no-tui -- sh -c 'cd apps/backplane_agent_runtime && env MIX_ENV=test mix format --check-formatted lib/backplane/agent_runtime/*.ex lib/backplane/agent_runtime/codex/*.ex test/backplane/agent_runtime/*.exs && env MIX_ENV=test mix compile --warnings-as-errors'`.
- [x] Launch packet includes changed API/schema docs, validation outputs with exit codes, source permalinks, compatibility notes, and consumer migration instructions. Commit/publish/release/Sigma update remain separate explicitly authorized actions.

## Execution evidence

See [the final validation record](2026-10-13-agent-runtime-validation.md). Checkboxes record verified behavior; illustrative helper snippets above are design sketches, and production helper names may differ. Native/cleanup fixtures use reversible prior-boundary regression probes where concurrent implementation preceded the first fixture run. The final full suite used four concurrent cases and the first complete run seed.
