# Agent Runtime Codex Lifecycle and Goal Design

Date: 2026-10-12
Status: implemented and verified in the detached `.trees/runtime65` workspace; uncommitted, without consumer rollout. Final evidence: `docs/superpowers/plans/2026-10-13-agent-runtime-validation.md`.

## Objective

Align Backplane's long-running interactive execution and optional Goal capability with the audited open-source Codex behavior. Deliver independently verifiable execution-deadline, provider-stream, and Goal changes without changing the gateway's product scope or silently redesigning upstream semantics.

## Authoritative inputs

- Backplane issue: https://github.com/gsmlg-opt/backplane/issues/65
- Inspected Backplane baseline: `1f4012542ac95c98d3b6c8c7711fa4743df7ca0c`, runtime version `1.10.19`.
- Existing tool inventory pin: Codex `46fdd5ef39735f4159cdcf0ec5e85c10521494e5`.
- Issue's execution reference: Codex `a9b0815167c27ab13719dd12d13b63e02b70d221`.
- Preserve `docs/agent-runtime/codex-tools/source-lock.json` and the existing tool inventory pin. Record new behavioral evidence separately; this work does not authorize a wholesale tool-inventory upgrade.
- Goal persistence, accounting, and idle continuation exist in both inspected Codex revisions. Their absence in Backplane is not attributable solely to the newer reference.

## Source-to-behavior contract

| Contract | Official Codex evidence |
| --- | --- |
| Normal turn has cancellation-driven lifetime without a cumulative wall-clock wrapper | [task registration](https://github.com/openai/codex/blob/a9b0815167c27ab13719dd12d13b63e02b70d221/codex-rs/core/src/tasks/mod.rs#L312-L424), [regular task loop](https://github.com/openai/codex/blob/a9b0815167c27ab13719dd12d13b63e02b70d221/codex-rs/core/src/tasks/regular.rs#L104-L124) |
| Stream timeout measures waiting for the next SSE event | [SSE poll](https://github.com/openai/codex/blob/a9b0815167c27ab13719dd12d13b63e02b70d221/codex-rs/codex-api/src/sse/responses.rs#L535-L540) |
| Ordinary human approval is a pending decision callback, without root-deadline expiry | [approval wait](https://github.com/openai/codex/blob/a9b0815167c27ab13719dd12d13b63e02b70d221/codex-rs/core/src/session/mod.rs#L2930-L3001) |
| Process observation yield and completion-only command timeout are distinct | [unified exec](https://github.com/openai/codex/blob/a9b0815167c27ab13719dd12d13b63e02b70d221/codex-rs/core/src/unified_exec/process_manager.rs#L632-L657) |
| Child wait timeout does not interrupt the child | [V2 wait](https://github.com/openai/codex/blob/a9b0815167c27ab13719dd12d13b63e02b70d221/codex-rs/core/src/tools/handlers/multi_agents_v2/wait.rs#L202-L219) |
| Goal is an optional extension integrating lifecycle, usage, and tools | [extension installation](https://github.com/openai/codex/blob/a9b0815167c27ab13719dd12d13b63e02b70d221/codex-rs/ext/goal/src/extension.rs#L613-L638), [host installation](https://github.com/openai/codex/blob/a9b0815167c27ab13719dd12d13b63e02b70d221/codex-rs/app-server/src/extensions.rs#L76-L89) |
| Goal continuation uses ordinary idle-turn admission | [continuation](https://github.com/openai/codex/blob/a9b0815167c27ab13719dd12d13b63e02b70d221/codex-rs/ext/goal/src/runtime.rs#L436-L503) |
| Goal budget triggers wrap-up, not immediate worker termination | [budget steering](https://github.com/openai/codex/blob/a9b0815167c27ab13719dd12d13b63e02b70d221/codex-rs/ext/goal/src/extension.rs#L521-L550) |
| Goal accounting includes uncached input, output, and descendants | [formula](https://github.com/openai/codex/blob/a9b0815167c27ab13719dd12d13b63e02b70d221/codex-rs/ext/goal/src/accounting.rs#L551-L575), [descendant attribution](https://github.com/openai/codex/blob/a9b0815167c27ab13719dd12d13b63e02b70d221/codex-rs/ext/goal/src/extension.rs#L458-L474) |

These references establish the audited open-source paths, not hosted Codex service limits.

## Scope and delivery boundaries

Implementation scope is `apps/backplane_agent_runtime/**` and directly related documentation under `docs/agent-runtime/**` and `docs/superpowers/**`. Package-verifier fixture changes may be made only for the new public runtime contracts and must be listed in the execution task before editing.

Do not change Sigma, Synapsis, gateway routes, database migrations, production configuration, dependencies, or release versions in this delivery. Consumer integration is demonstrated with package-local host/store fixtures and documented adapters. Real consumer rollouts are separate work.

Do not commit, create branches, push, publish, or deploy without explicit authorization. Implementation was authorized after plan preparation and was isolated in a detached worktree. For broad implementation, use an authorized worktree under this project's `.trees/`; do not place a worktree elsewhere.

## A. Disabled whole-run deadlines

1. Accept `run_timeout: :infinity` as an explicit opt-in. Preserve the existing finite default, finite bounds, and rejection of invalid values.
2. Persist disabled mode explicitly rather than as a distant timestamp. Legacy `deadline: nil` continues to mean unset; it must not accidentally become a disabled run. An explicit sentinel and its wire representation are defined in the execution plan.
3. Apply the same meaning to direct `Execution`, `ExecutionController`, `Conversation`, nested dispatch, human-wait pause/resume, and child follow-up replacement.
4. No root timer or root-budget subtraction exists in disabled mode. Finite effect, commit, cleanup, native command, and work limits remain independent.
5. Ordinary approval waiting in disabled mode has no newly invented finite expiry. Preserve decision identity, resolver identity, argument digest, descriptor revision, and authority checks.
6. Old timer generations, callback incarnations, cancellation, owner death, and uncertain external effects retain their existing fencing and reconciliation behavior.
7. Restoring a nonterminal record remains inspection/reconciliation-only. Disabled deadlines do not authorize replaying external mutations.

## B. Provider stream idle timeout

Introduce an opt-in finite `provider_idle_timeout` for normalized Conversation streams. Its default is unset so existing total provider-effect behavior remains compatible. In enabled mode, the provider's stream-wait timer measures the interval before the next valid provider event, independently of the optional root deadline. The new mode replaces the provider-only total effect timer; it does not disable tool, hook, store, or cleanup timeouts.

The runtime owns event-wait semantics over its existing enumerable/event boundary, not an HTTP/SSE parser. Host provider adapters retain transport-specific timeout and retry ownership. Malformed events do not reset the timer. Every reset/pause/resume is generation-fenced. Supported blocking human interaction suspends the idle timer and resumes its remaining active-wait budget.

Normal unified exec polling, completion-only timeout, and child wait semantics are regression checks in this delivery. Do not redesign those tool protocols unless a source-backed discrepancy is reproduced by the scoped checks.

## C. Optional thread-scoped Goal execution

### Placement

The reusable runtime package owns Goal state transitions, tool execution, usage accounting, continuation policy, budget steering, and failure guards. Hosts supply stable thread identity, durable storage, trusted user operations, ordinary turn admission, and UI/events.

Use the existing `Codex.Session` when the host selects retained resources. Do not add a second resource owner, a competing provider loop, or a general plugin framework. A small Goal-specific lifecycle bridge is sufficient.

### Lifecycle

- A goal belongs to a stable thread and survives individual run completion. Run bindings continue to require exact authority and incarnation; a thread identifier alone is not an authorization capability.
- Statuses are `active`, `paused`, `blocked`, `usage_limited`, `budget_limited`, and `complete`.
- Model tools remain `create_goal`, `get_goal`, `update_goal`; model update accepts only complete, blocked, and paused.
- Trusted host set/get/clear/resume operations are separate from model tool input. Goal authorization and user mutation history are recorded before live state changes.
- `create_goal` cannot replace active, paused, blocked, usage-limited, or budget-limited work. Only no goal or a completed goal admits creation, matching Codex's insert path.
- Normal `turn_completed` is not objective completion. Only the explicit Goal state transition claims completion.
- An active goal can initiate the next turn only after acknowledged settlement, idle admission, and authoritative goal re-read. Admission shares normal user-turn policy and current catalog/grants.
- Pause, clear, completion, budget exhaustion, host close, and goal replacement serialize against continuation. Duplicate stop/idle delivery cannot start duplicate turns.
- Recovery restores metadata and accounting without automatically resuming uncertain effects. Fork accounting is flushed before copying a snapshot; inherited goal continuation can be deferred for the first explicit fork turn.

### Accounting and stop behavior

Reuse existing `Usage.report/2` attribution and deduplication where compatible; supply explicit report identities and goal/run/attempt provenance. Goal accounting is persistent, idempotent, and guarded by expected goal identity and store revision. Count known uncached input plus output; include descendant usage once at the root. Elapsed usage is measured and reported, not converted to a new whole-goal wall-clock cutoff.

Missing provider metrics remain unknown. A budgeted host integration must supply authoritative normalized metrics; it must not advertise fabricated remaining tokens or proof of budget enforcement when required values are unavailable.

Budget exhaustion persists `budget_limited`, injects one wrap-up instruction into the current turn, and prevents further automatic continuation. It does not turn uncertain effects into ordinary errors or terminate work solely to satisfy token accounting.

Carry Codex's actual failure guards: provider usage limits, terminal nonretryable/exhausted errors, consecutive qualifying execution failures, and consecutive automatic empty responses. The broader three-turn same-blocker audit and explicit-pause instruction remain model policy text; do not invent a natural-language authorization classifier.

## Verification requirements

Use red/green tests for production changes, starting with focused files. Runtime tests run as the standalone `apps/backplane_agent_runtime` Mix project under devenv; do not start unrelated umbrella apps or PostgreSQL. Serialize Mix builds/tests across agents.

Required evidence includes:

- Successful individually bounded effects after a disabled run has exceeded a finite comparison budget.
- Unchanged finite-run expiry, bounded effects/commit/cleanup, approval resolution, explicit cancellation, and unknown-outcome cleanup behavior.
- Durable sentinel round-trip and old-record compatibility; restored nonterminal work remains fenced.
- Active provider progress survives the previous total-effect duration; silent/malformed streams expire under the idle limit; old generations cannot expire a resumed/reset stream.
- Multi-turn Goal progression, user pause/resume/clear, budget wrap-up, completed-only replacement, duplicate accounting/events, goal mutation races, descendant attribution, and restart/fork behavior.
- A package-local host integration using the real Conversation/Execution path, existing Session resource boundary, durable test storage, and exact run authority. Direct Goal GenServer tests alone are insufficient.

Final scoped checks cover the owning app's tests, warnings-as-errors compilation, scoped formatting, and `git diff --check`. Native Code Mode tests require Deno at the workflow's pinned version and verified Linux cleanup prerequisites. Do not claim a test or package-consumer proof that was not run.

## Preparation snapshot

The current devenv shell provides Elixir 1.18.5, OTP 28, and Coreutils. Deno is absent in the inspected shell. The standalone app has an existing `_build` directory but no standalone `deps` directory; cached build presence is not a usable test baseline. Execution must install standalone dependencies and the pinned native test prerequisites before claiming readiness of the full scoped suite.

No Mix/ExUnit runtime suite was run while writing this design. A standalone source probe loading only `Error` and `Usage` reproduced an in-scope prerequisite: `Usage.report/2` accepts the same identity with different token values as `:duplicate` because its digest-conflict error is discarded. The Goal plan requires a failing `usage_test.exs` regression and a surgical repair before trusting report deduplication.
