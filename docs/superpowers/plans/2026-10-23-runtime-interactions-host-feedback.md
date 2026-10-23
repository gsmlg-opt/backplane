# Child interactions and durable host feedback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix #81 and #82 on main and publish verified Backplane 1.10.33.

**Architecture:** Extend MultiAgent's existing observation boundary with correlated interactions and asynchronous resolution. Extend Conversation's existing Store checkpoints with token-bound host feedback, a canonical deduplication ledger, and projection at the next natural provider boundary. Preserve cancellation, CAS/incarnation fencing, resource ownership and inspection-only restoration.

**Tech Stack:** Elixir/OTP, ExUnit, existing Runtime Store adapters, Devenv/Nix, GitHub Actions, Hex and GHCR.

Approved specification: `docs/superpowers/specs/2026-10-23-runtime-interactions-host-feedback-design.md`.

Main is explicitly authorized. Preserve all unrelated edits recorded in
`/tmp/backplane-1.10.33-internal-requests-lp7loyui/context.json`.
Workers use disjoint file ownership; the coordinator runs all local Mix commands
serially and owns commits, pushes and publication.

## Task 1: MultiAgent public child interactions

**Modify:** `apps/backplane_agent_runtime/lib/backplane/agent_runtime/codex/multi_agent.ex`.
**Create:** `apps/backplane_agent_runtime/test/backplane/agent_runtime/codex/multi_agent_interaction_test.exs`.
**Modify if necessary:** `apps/backplane_agent_runtime/test/backplane/agent_runtime/codex/multi_agent_observer_test.exs` and manager-specific documentation.

- [ ] Run GitNexus impact on each changed existing symbol; report unsupported Elixir resolution without treating it as proof of no impact.
- [ ] Add a gated provider/preparation/backend fixture using the public manager API. Assert the existing stream contains the complete current identity and pending request:

```elixir
assert_receive {:codex_collaboration,
                %{type: :interaction_requested, manager_id: manager_id,
                  interaction_id: interaction_id, agent: agent}}
assert agent.pending_interaction.correlation == %{
         manager_id: manager_id, agent_id: agent.agent_id,
         run_id: agent.run_id, incarnation: agent.incarnation,
         interaction_id: interaction_id
       }
assert :ok = MultiAgent.resolve_interaction(manager,
  agent.pending_interaction.correlation, "approved")
```

- [ ] Ask the coordinator to run the new focused test before adding the API; expect undefined API or missing forwarded interaction.
- [ ] Add the public call below and a manager-owned reservation/delivery worker. Pin full correlation and child reference, reply only after child acknowledgement, and handle result/DOWN/timeout without retrying uncertain delivery.

```elixir
def resolve_interaction(manager, correlation, value),
  do: GenServer.call(manager, {:resolve_interaction, correlation, value}, :infinity)
```

- [ ] Extend complete public records and revisioned events with pending interaction/correlation. Preserve the resolved interaction ID after clearing pending state. Atomic subscribe snapshots recover current pending interactions.
- [ ] Clear actionable pending state and reservations on interrupt/close/session close, replacement, DOWN, terminal events and storage failure. Reject duplicate, unrelated, stale or closed resolution without clearing newer state. Keep waiting children running and manager responsive during held child commits.
- [ ] Carry `snapshot.conversation.host_feedback` to replacement options alongside messages and mailbox. Coordinate the exact history option with Task 2.
- [ ] Add assertions for preparation and backend paths, JSON-safe snapshot shape, resubscription, stale manager/run/incarnation, duplicate answers, cancellation and replacement, checkpoint failure, held checkpoint responsiveness, and event/ack ordering.
- [ ] Coordinator runs the interaction and observer suites; expect zero failures. Supply a requirement-to-test mapping for independent spec review, then code-quality review.

## Task 2: Conversation host feedback and shared interaction fences

**Modify:** `apps/backplane_agent_runtime/lib/backplane/agent_runtime/conversation.ex`, `conversation_adapter.ex`, `apps/backplane_agent_runtime/README.md`.
**Create:** a focused `host_feedback.ex` helper and `apps/backplane_agent_runtime/test/backplane/agent_runtime/conversation_feedback_test.exs`.
**Modify if necessary:** preparation/runtime-repair tests and `store_conformance_test.exs` for file-backed feedback proof.

- [ ] Run GitNexus impact before editing existing symbols. Add focused fixtures that invoke preparation/backend callbacks, capture actual next-provider requests, and hold/fail a feedback checkpoint.
- [ ] Write acceptance tests around the exact callback:

```elixir
assert {:ok, receipt} = context.append_feedback.(%{
         id: "hook-1", text: "extra context", source: "sigma-hooks",
         stage: "PreToolUse"
       })
assert receipt.store_mode in [:durable, :ephemeral]
assert receipt.correlation.invocation_id == invocation.invocation_id
```

- [ ] Coordinator runs the focused test before implementation; expect missing capability. Add the callback only to direct/nested preparation/backend contexts, including the explicit direct backend allowlist.
- [ ] Validate exact four fields, nonempty UTF-8, 256-byte identity/provenance bounds and 64-KiB text. Reject unsupported/ambiguous keys. Stamp immutable correlation from the live worker, never caller payload.
- [ ] Enqueue feedback work, recheck live token/nested owner before processing and after checkpoint. Track pending callers through cancellation/storage failure. Commit via existing conversation_updated and return a receipt only after Store acknowledgement.
- [ ] Maintain ordered canonical host_feedback records; exact repeat returns original receipt, changed payload/provenance/invocation conflicts, and stale producers fail before lookup. Retain committed feedback after denied/invalid preparation without implying dispatch.
- [ ] Merge queued checkpoints by feedback ID with monotonic projection state and retain actual committed/rebased Conversation in continuations. Keep the ledger across context resets and accept the documented history seed alongside messages; recognize existing projected messages.
- [ ] At the natural provider boundary, append explicitly marked host-feedback messages after the complete tool-response batch, checkpoint projection, then construct the provider request. Never call prompt/steer/follow_up to inject feedback or start an extra turn.

```elixir
assert Enum.count(request.messages,
  &(get_in(&1, [:host_feedback, :id]) == "hook-1")) == 1
assert Enum.find_index(request.messages, &Map.has_key?(&1, :host_feedback)) >
       Enum.find_index(request.messages, &(Map.get(&1, :role) == :tool))
```

- [ ] Add Conversation resolution phase and post-checkpoint token/interaction guards for Task 1. Publicly exposed interaction requests normalize atom keys/enums to strings while rejecting opaque/ambiguous/non-JSON values; preserve existing root request compatibility where possible.
- [ ] Cover direct/nested prepare/backend, custom input and approval rewrites, failed/held commits, cancellation during commit, exact/conflicting dedup, later turns, history replay/context reset, invalid/denied preparation, concurrent result/checkpoint merging, durable file snapshots and inspection-only restoration.
- [ ] Coordinator runs feedback, preparation and affected runtime tests. Document receipts, durability distinction, immutable identity/final arguments, retained denied feedback, provider encoding, and replacement history. Supply spec coverage, then pass independent quality review.

## Task 3: Existing CI release blockers

**Modify only as needed:** runtime `outbox.ex`, `inbox.ex`, `store.ex`, `codex/contract.ex`, `context.ex`, `tools/local_resource.ex`; shared Credentials return spec; Plugins Git test helper. Diagnose residual warnings after primary repairs.

- [ ] Correct closed success-map specs to include actual receipt IDs/digests and Store `mode`; preserve adapter callback types. Declare optional collaboration_binding in Contract and the selection-list argument in Context.fork.

```elixir
@type receipt :: %{status: :submitted, submission_id: String.t(), digest: String.t()}
# Store wrapper successes include mode: :ephemeral | :durable.
# Contract.t includes optional(:collaboration_binding) => map().
```

- [ ] Remove unsupported ineffective Path.wildcard `unescape` options; keep behavior and verify glob/grep tests. Correct Credentials auth_type spec to permit actual nil metadata.
- [ ] Isolate Git config test queries in an independent temporary repository, keeping GIT_CONFIG_COUNT, URL-scoping and redirect assertions. Prove an enclosing fixture checkout's non-secret header does not contaminate that query.
- [ ] Run focused suites and Dialyzer. Fix only evidenced residual failures; do not delete reachable conformance helpers or use broad warning ignores. Coordinate MultiAgent residual warnings with Task 1 owner.

## Task 4: Integration and release

- [ ] Independently review spec compliance, resolve findings, then review code quality. Review integrated #81/#82 races and preservation of concurrent changes.
- [ ] Run serialized `devenv shell --no-tui -- mix` focused tests, the complete owning runtime suite with real Deno, warnings-as-errors compile, format, strict Credo, Dialyzer, and both root workflow contracts. Record exact commands/results, including limitations.
- [ ] Run GitNexus detect_changes on staged paths, inspect the exact staged diff, and commit only this task's files with Conventional Commits including `Fixes #81` and `Fixes #82`. Push main and verify local/tracking/live remote convergence.
- [ ] Use `scripts/set-version.sh 1.10.33` according to the current release workflow; freeze one qualified SHA and wait for its CI gates. Do not publish unrelated dirty files.
- [ ] Dispatch `.github/workflows/release.yml` on main with version 1.10.33. Follow all terminal qualification, build, installed smoke, GitHub, Hex and Docker jobs. Preserve the frozen source if main advances.
- [ ] Independently verify all published asset sizes/SHA256, sidecars and packaged BuildInfo, Hex tarballs/HexDocs and a fresh consumer, GHCR version/latest digest and provenance, release notes, issue closure and remote refs.
- [ ] Capture a coherent Agent Note implementation review only if the project's durable-knowledge quality gate passes. Do not modify filesystem memories.
- [ ] Report implemented, tested and released evidence with links and any remaining limitation; do not imply production deployment or downstream integration.
