# Codex Tool Profiles

`Backplane.AgentRuntime.Codex.profile/4` is the runtime-owned boundary for
explicit Codex profiles. It binds trusted host resources into descriptors,
requires exact run grants and descriptor revisions, and returns one
`ToolCatalog` registry/tools/authority bundle for `Conversation`.
`definitions/0` retains the local provider definitions for compatibility.

Every model-callable profile below dispatches through
`Conversation -> Execution.commit/dispatch`. `Codex.Backend` receives the
descriptor-owned `backend_context` only after the intent commit. Model arguments
cannot select adapters, credentials, workspaces, environments, or grants.

## Profiles

- `:pinned_local` exposes configured `exec_command`, `write_stdin`,
  `apply_patch`, `update_plan`, `view_image`, `clock::curr_time`, and
  `clock::sleep`. `apply_patch` is a custom/freeform tool using the pinned Lark
  grammar; raw input follows the same admission and commit path as JSON input.
- `:interactive` exposes configured synchronous/asynchronous user interaction,
  permission request, environment readiness, `new_context`, and
  `get_context_remaining` tools. Host callbacks authenticate replies, apply
  grants, and supply authoritative readiness/token state.
- `:collaboration_v1` and `:collaboration_v2` expose their distinct pinned names.
  `Codex.MultiAgent` owns wait/list state and starts child `Conversation`
  processes under a `DynamicSupervisor`; child options and authority come only
  from the host. Host snapshots/subscriptions retain closed identities separately
  from model-facing lists. V2 executing capacity and runtime residency are bounded
  independently of retained history; V2 interruption targets one task, while V1
  close and session shutdown retain recursive cleanup. V2 messages and terminal
  child results enter the recipient mailbox without starting an idle turn;
  `wait_agent` distinguishes mailbox activity, new steer and timeout.
  See `EMBEDDING.md` for the
  preparation, observer revision, admission and restart boundaries.
- `:extensions` exposes 27 concrete goal, memory, skill, history, note, and
  message-board tools. The bundled scoped reference state is ephemeral. A host
  adapter is required before claiming durability or restart recovery. Supplying
  `goal: goal_owner` to `Codex.ExtensionRuntime` routes only the three Goal tools
  to the persistent thread owner; other extension families retain their selected
  adapters.
- `:dynamic` conditionally exposes MCP resource operations, `tool_search`, and
  plugin request tools. Search publishes admitted tools for the next provider
  turn; another call in the discovery batch remains fenced to the old catalog.
- `:code_mode`, `:code_mode_only`, and `:mixed` expose the pinned freeform
  `exec` and function `wait` contracts only when the host can verify Deno
  process identity and bounded cleanup. Deno presence alone is insufficient;
  the current native adapter requires Linux `/proc` and `kill`, and unsupported
  hosts are rejected before a cell or nested tool can start. The opt-in Deno
  worker has no ambient filesystem or network access. Nested calls re-enter the
  admitted Conversation dispatcher with the existing run, authority, revision,
  budget, resource owner, catalog callbacks, and audit path.
- `:service_compat` exposes only configured service adapters. It includes the
  pinned `web::run` and `image_gen::imagegen` contracts plus explicit Backplane
  compatibility tools `web::fetch`, `web::search`, and `web::x_search`.
- `:configured` combines explicitly selected `:local`, `:interactive`,
  `:collaboration_v1` or `:collaboration_v2`, `:extensions`, `:dynamic`,
  `:code_mode`, and `:services` families. Missing families and duplicate
  canonical names fail before admission.

Provider-hosted capabilities are separate from local tools. A configured
provider adapter negotiates them and `:configured` returns them in
`profile.hosted_tools`; they are never inserted into `ToolRegistry`. The current
projection supports the pinned `web_search` declaration and normalizes observed
provider events. Local tests use an injected adapter and do not establish live
provider compatibility.

## Host Requirements

Profiles are capability-driven and fail closed. Command tools need the selected
workspace, command adapter, caller identity, and `Codex.ResourceRegistry`; plan
needs a host-started `Plan`; collaboration needs `Codex.MultiAgent`; extensions
need `Codex.ExtensionRuntime`; dynamic tools need `Codex.DynamicRuntime` plus the
  relevant MCP/plugin adapters; Code Mode needs `Codex.ResourceRegistry`, Deno,
  and a verified process-lifecycle capability; service and hosted tools need
  host-owned adapters and credentials. Selecting no
profile starts none of these resources.

Existing consumers can upgrade without selecting a Codex profile; their current
`Execution`, `ExecutionController`, provider, and tool APIs remain available.
To opt in, start only the required host runtimes, call `Codex.profile/4` with the
run's exact grants/revisions, and pass the returned `registry`, `tools`, and
`authority` together to `Conversation`. Do not merge profile fields with an old
catalog or persist `backend_context`, PIDs, callbacks, credentials, or grants.

The standalone local example is `examples/codex_local.exs`:

```sh
mix run --no-start --no-deps-check apps/backplane_agent_runtime/examples/codex_local.exs
```

On Linux it uses the existing `LocalCommand` process-group backend. On other
platforms it uses an explicitly labelled one-shot `System.cmd` example adapter
because production `LocalCommand` currently requires Linux `/proc`, `setsid`,
and process-group probing. Verified host adapters can opt into PTY; see
`docs/agent-runtime/codex-tools/command-host-adapters.md` for the capability and
cleanup contract. The default LocalCommand adapter still uses pipes.

## Compatibility Boundary

The exact 66-entry inventory for Codex revision
`46fdd5ef39735f4159cdcf0ec5e85c10521494e5` is packaged as
`priv/codex/source-inventory.json`. Per-family contract, execution,
availability, and parity evidence is maintained under
`docs/agent-runtime/codex-tools/`. Source presence does not establish behavior.

The old direct-call `clock` and time-waiting `wait` names remain Backplane
compatibility aliases and are not in `:pinned_local`. The pinned `wait` name is
the Code Mode continuation. Hosted search is `web_search`, standalone service
search is `web::run`, and image generation is `image_gen::imagegen`.

Compatibility remains adapted rather than unqualified full parity:

- Code Mode uses the packaged Deno process adapter with running-cell time slices,
  incremental output, and current-catalog dispatch on `wait`. The legacy
  `codex.tool`/generator interface remains available. The source contract and
  native-engine differential validation limits are documented in
  `docs/agent-runtime/codex-tools/code-mode-conformance.md`.
- The default native lifecycle adapters require Linux. Other platforms require
  independently verified host adapters.
- Extension reference state is ephemeral unless a durable host adapter supplies
  and verifies recovery.
- Full pinned output schemas, all schema property descriptions, and native Codex
  event/wire differential coverage remain incomplete.
- Production MCP, web/image services, and provider-hosted tools were not tested
  against live backends.

The selected Code Mode backend for internal request #54 is the existing Deno
process adapter, with no Denox migration. Host limits remain independent from
response budgets: source 128 KiB, lifetime output 1 MiB, 32 nested calls,
30 seconds of engine execution, and a 64 MiB V8 old-space ceiling by default.
V8's old-space limit is not a total OS-process RSS limit. ResourceRegistry bounds
live cells (16 by default), stored keys (256 per owner/incarnation), and total
stored state (16 MiB). A host can set shorter execution limits.

`tools` and `ALL_TOOLS` derive from the admitted registry and exact grants.
Running cells buffer detached output and hold nested requests until a new `wait`
supplies the current dispatcher, authority, and catalog. Attached notifications
emit a `custom_tool_call_output` event immediately; detached notifications are
retained for the next wait. No callback from an expired invocation can grant
access. Unsettled or crashed nested callbacks remain `unknown_outcome`.

`Codex.Session` optionally owns commands, cells, stored state, and collaboration
identities across separate bounded runs. Hosts bind a fresh run, build its profile,
and pass the returned `session_binding` to Conversation. Natural successful
completion prepares detachment, commits the run finish, then acknowledges
retention. Cancellation/failure/session close fence admission and perform bounded
cleanup; restart creates a fresh session identity and never replays effects.
See `docs/agent-runtime/codex-tools/session-resources.md` for the host API.

## Command response budgets

`exec_command.max_output_tokens` and `write_stdin.max_output_tokens` bound the
output returned by each call, independently of `Command.output_limit`, which is
a host-owned backend hard limit. The response uses a four-bytes-per-token
estimate (default 10,000); it is not tokenizer accounting. Results expose
`output_budget_unit: :estimated_token_bytes`, `output_truncated`, and
`omitted_output_bytes`. A poll advances past the entire observed backend batch,
including intentionally omitted bytes; the next poll does not repeat that batch.
UTF-8 prefixes are not cut inside a character.

Results retain backend `status`, exit status when available, termination and
cleanup evidence, and `output_limit_exceeded?`. A hard-limit termination is not
a successful command merely because an exit code is missing. LocalCommand keeps
its bounded output buffer and Linux process-group cleanup; descendants that
create a separate session remain outside that backend's cleanup guarantee.

Command output retention is bounded independently from cleanup evidence. A failed
cleanup keeps the invocation/session, owner incarnation, process-group and
workspace association until an explicit reconciler confirms release. Expiring a
completed output record therefore cannot make `session_cleanup_status/1` or
owner cleanup report `:confirmed`; unknown identities remain distinct from known
never-launched reservations and confirmed-release receipts.

Collaboration close is idempotent. Closed or interrupted records retain closure
state and any uncertain settlement evidence, recursive close skips confirmed
descendants, and stale monitor notifications are fenced by run identity. The
manager does not terminate unrelated peers when a descendant cannot establish
settlement.

## Worker framing

The packaged Deno worker runs with explicit denied ambient permissions using
`deno run` and a data URL. Its stdin protocol is bounded NDJSON: UTF-8 decoding
is streaming, only newline-terminated records are parsed, and a record is limited
to 1 MiB before buffering. Malformed JSON, invalid UTF-8, oversized records, and
incomplete records at EOF produce an explicit protocol error and exit the worker.
The Elixir port also assembles bounded records independently of pipe read sizes.
`codex_framing_test.exs` deterministically splits raw records and UTF-8 bytes in
the actual packaged JavaScript source; separate tests exercise the real
`CodeMode.execute` worker with large source and nested results. Those framing
tests alone are not evidence of cross-provider-turn continuation behavior.

## Patch results

`apply_patch` parses operations and ordered line hunks before modifying files.
Anchors, EOF constraints, whitespace/punctuation matching, additions and
rename-with-edit follow the pinned parser/application semantics while preserving
workspace and symlink checks. Move destinations may create parent directories.
The legacy direct-call move form remains a Backplane compatibility extension.

Patches are not whole-patch atomic. Successful operations appear in `files`;
on a later failure they remain in `Error.details.files`. A failed write can
leave uncertain content and reports `:unknown_outcome` with `uncertain_files`.
Callers must inspect this evidence rather than treating an error as proof that
nothing changed. Malformed bodies are rejected before executing any operation.


## Execution lifecycle behavioral references

The tool inventory remains pinned to `46fdd5ef39735f4159cdcf0ec5e85c10521494e5`.
Issue #65 additionally audits Codex `a9b0815167c27ab13719dd12d13b63e02b70d221`:

- [Ordinary task registration](https://github.com/openai/codex/blob/a9b0815167c27ab13719dd12d13b63e02b70d221/codex-rs/core/src/tasks/mod.rs#L312-L424)
  and [regular turns](https://github.com/openai/codex/blob/a9b0815167c27ab13719dd12d13b63e02b70d221/codex-rs/core/src/tasks/regular.rs#L104-L124)
  use cancellation-driven lifetime. Backplane exposes this through explicit
  `run_timeout: :infinity`, preserving finite defaults for existing consumers.
- [Stream observation](https://github.com/openai/codex/blob/a9b0815167c27ab13719dd12d13b63e02b70d221/codex-rs/codex-api/src/sse/responses.rs#L535-L540)
  bounds each `stream.next()` wait. Backplane's optional `provider_idle_timeout`
  observes validated normalized events; raw transport SSE remains host-owned.
- [Approval callbacks](https://github.com/openai/codex/blob/a9b0815167c27ab13719dd12d13b63e02b70d221/codex-rs/core/src/session/mod.rs#L2930-L3001)
  await bound decisions. Infinite Backplane runs use explicit infinite approval
  expiry with the existing identity checks.
- [Unified exec](https://github.com/openai/codex/blob/a9b0815167c27ab13719dd12d13b63e02b70d221/codex-rs/core/src/unified_exec/process_manager.rs#L632-L657)
  distinguishes observation yield from completion-only command timeout;
  [child waits](https://github.com/openai/codex/blob/a9b0815167c27ab13719dd12d13b63e02b70d221/codex-rs/core/src/tools/handlers/multi_agents_v2/wait.rs#L202-L219)
  expire observation without interrupting the child.

## Goal behavioral references and adaptations

The existing tool inventory at `46fdd5ef39735f4159cdcf0ec5e85c10521494e5`
already includes Goal extension contracts. The persistent owner ports their
source behavior, with the additional `a9b0815167c27ab13719dd12d13b63e02b70d221`
lifecycle audit retained explicitly:

- [Tool instructions](https://github.com/openai/codex/blob/46fdd5ef39735f4159cdcf0ec5e85c10521494e5/codex-rs/ext/goal/src/spec.rs)
  require explicit creation and constrain model updates to complete, pause or
  block. Host resume, budget changes and clear remain separate operations.
- [Goal accounting](https://github.com/openai/codex/blob/46fdd5ef39735f4159cdcf0ec5e85c10521494e5/codex-rs/ext/goal/src/accounting.rs)
  excludes cached input and avoids adding reasoning output twice, establishes
  current-usage baselines for newly created goals, excludes Plan token charges,
  tracks descendants and stops after three qualifying failed or empty turns.
- [Interruption accounting](https://github.com/openai/codex/blob/a9b0815167c27ab13719dd12d13b63e02b70d221/codex-rs/ext/goal/src/accounting.rs#L478)
  distinguishes `interrupt_turn` from other aborts. Backplane persists the
  deferral and evaluates interrupted emptiness when the host next signals idle;
  it does not claim the two source revisions have identical abort behavior.
- [Continuation runtime](https://github.com/openai/codex/blob/46fdd5ef39735f4159cdcf0ec5e85c10521494e5/codex-rs/ext/goal/src/runtime.rs)
  and [budget steering](https://github.com/openai/codex/blob/46fdd5ef39735f4159cdcf0ec5e85c10521494e5/codex-rs/ext/goal/templates/goals/budget_limit.md)
  supply the continuation/wrap-up policy. Backplane reserves the host's existing
  Session admission; it adds no independent provider loop or child scheduler.
- [Fork inheritance](https://github.com/openai/codex/blob/46fdd5ef39735f4159cdcf0ec5e85c10521494e5/codex-rs/app-server/src/request_processors/thread_fork_goal.rs)
  copies the Goal snapshot into a new thread. Live bindings, run receipts and
  accounting ownership are not copied.

Backplane's explicit adaptations are the host-owned `Goal.Store` CAS contract,
committed Conversation receipt outbox, capability-bound attribution and
snake_case response fields. Public timestamps are seconds; private persistence
retains millisecond timestamps and `goal_id`. Completion steering refers to the
emitted snake_case fields. Missing normalized usage suspends budgeted automatic
admission through the existing unknown-metrics contract; this is a Backplane
accounting guard, not another Codex Goal status or an upstream requirement.
Uncertain responses expose `accounting_uncertain: true`, unavailable remaining
tokens and no completion budget report. Known charged usage remains available
as a partial measurement. Decreasing cumulative provider metrics are refused
before another charge or provider idle refresh.
Elapsed time reports usage rather than enforcing a Goal deadline.

Persistent Goal support is opt-in and needs a validated real host adapter before
production launch. The existing ephemeral extension reference mode remains
explicitly ephemeral. Scoped fixtures establish package behavior, including
receipt recovery and native nested-tool acknowledgement; they do not establish
consumer integration, provider wire compatibility or complete Codex parity.
