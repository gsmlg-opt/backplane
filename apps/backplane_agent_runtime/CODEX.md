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
  Environment callbacks may report `status: :failed | :unavailable | :closed`
  (or the corresponding strings), with the exact `environment_id`. Failed
  startup uses `error: %{class: class, message: reason}`; Control returns an
  ordinary `%{is_error: true, error: json_safe_error}` value, including in Code
  Mode, so the model can continue with other tools. The UTF-8 reason is bounded
  to 256 bytes. Timeout and cancellation remain distinct errors. Explicit IDs
  must match the requested ID exactly; legacy maps without an ID remain valid.
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

### Plugin installation outcomes and Web answers

`request_install(arguments, operation)` remains a host installation boundary.
An ordinary `{:ok, map_or_list}` records a requested receipt. A host that has
installed and verified its artifact can return `{:ok, {:completed, fields}}`,
where atom-keyed `fields` contain exactly `completed: true`, the actual boolean
`user_confirmed`, and nonempty UTF-8 `tool_type`, `action_type`, `tool_id` matching
the request. `tool_name` is the only optional field. Runtime supplies the same
receipt as `operation.plugin_request_id`, completes it once, and exposes these
fields at the top level with `request_id` and `status: :completed`. Malformed
completion evidence is `:unknown_outcome`; it cannot assert that installation
did not happen. Completion grants no tools. Settled journal restoration retains
the receipt without calling the installer again; an unacknowledged crash does
not authorize installation replay.

The host owns filesystem installation. PluginProtocol provides download, archive
and manifest validation primitives, rather than an installation scheduler. The
acceptance fixture downloads a real archive, writes and verifies its files and
modes, then loads the installed manifest before attesting to completion.

`Web.search/3` and `Web.x_search/3` accept existing `results` maps and explicit
`kind: :answer` / `"kind" => "answer"` maps. Answers require nonempty UTF-8
`content`; optional `provider`/`query` are UTF-8 strings, and optional ordered
`citations` contain nonempty URL strings or maps with `url` and optional `title`.
Recognized fields accept either key style, without duplicate atom/string aliases.
Original content, citations, order and additional metadata are retained. Valid
legacy `results` lists take precedence over answer tags. Empty answer content is
accepted only with an explicit answer tag, nonempty valid ordered citations and
an unambiguous boolean `truncated: true`; the original map and whole-result bound
are retained. Both branches retain
the complete original-map `:erlang.external_size` limit (default 1,048,576),
including metadata and citations; no rows are synthesized for an answer.

### Native async event identity

`request_user_input_async` emits `:async_user_input_requested` and
`send_message_to_user_async` emits `:async_user_message`. Both include the
actual tool's `invocation_id` and `tool_call_id`, together with existing run,
incarnation, step, attempt and turn metadata. Identical calls have distinct
invocation IDs. Code Mode events identify the nested call rather than the outer
`exec` call. Conversation derives these fields from its live tool producer;
payload-supplied IDs cannot override them.

The IDs match the canonical tool invocation records and remain JSON-safe when
projected through `Conversation.public_interaction/1`. Notifications do not add
a durable replay journal. The host persists its own cards and admits replies as
new user messages. `accepted: true` remains immediate Runtime acceptance, even
without a subscriber or before subscriber processing; it does not acknowledge
durable user receipt.

### Observing, resolving and cancelling child interactions

`Codex.MultiAgent.subscribe(manager)` atomically returns the complete child roster
and its process-local `manager_id`/revision watermark. Later
`{:codex_collaboration, event}` messages carry complete child records. Reconcile
with another snapshot after an observation gap; a restarted manager is a new
stream rather than durable replay.

Each record includes `pending_interaction: nil | %{id: id, request: request,
correlation: correlation}`. Waiting children retain `status: :running`. Requests
are normalized to JSON-safe strings and values without exposing child PIDs or
worker handles. `:interaction_requested` and `:interaction_resolved` events both
include `interaction_id`, even after the resolved record's pending field clears.

Pass the exact observed correlation to
`Codex.MultiAgent.resolve_interaction(manager, correlation, value)`. It identifies
`manager_id`, stable `agent_id`, current `run_id`, `incarnation`, and
`interaction_id`. Malformed correlation or non-JSON-safe answers fail validation;
unknown children return `:not_found`; stale, closed or duplicate answers return
`:resource_conflict`. Resolution runs asynchronously so child persistence cannot
block manager observation or other children. `:ok` acknowledges the child's
resolution checkpoint, not tool completion. An exact `:interaction_resolved`
event also proves that checkpoint; later task settlement cannot turn an already
observed commit into a rejected answer. Delivery workers are temporary children
of the manager's supervisor and stop when their manager exits.

The manager waits at most five seconds for resolution acknowledgement,
independently of the child's configured `commit_timeout` (also five seconds by
default). A longer child commit can therefore outlast the manager's wait.
Lost acknowledgement returns
`:unknown_outcome`; never retry automatically. A submitted interaction stays
reserved until later observation or cancellation reconciles it.

To cancel that exact pending interaction, call
`Codex.MultiAgent.cancel_interaction(manager, correlation, reason)` with the same
five-field correlation. `reason` must be a nonblank UTF-8 string of at most 1024
bytes; it is diagnostic text in the `:interrupted` observer event, without a
guarantee that the Store persists it. Malformed input fails validation; unknown
children return `:not_found`; stale, replaced, closed or duplicate interactions
return `:resource_conflict`. Cancellation and resolution share one atomic manager
reservation. The child also validates its run, incarnation, interaction and live
producer before accepting cancellation.

Cancellation settles asynchronously. `:ok` requires exact child acceptance, an
acknowledged terminal checkpoint, a cleared pending interaction and reconciled
cleanup/effects. A dispatched backend can remain `:unknown_outcome` and retain
execution capacity. Lost workers, lost Store acknowledgements and timeouts return
`:unknown_outcome`; reconcile observer records and the host Store before further
action. Never retry automatically or fall back to interruption by agent name:
replacement may have started another run. A generic `run_cancelled` event is not
an exact interaction cancellation receipt. This API preserves existing stop and
deadline policies, affects only the correlated child run, and does not recurse
into descendants. Model-facing interruption retains its existing target rules.

Interrupt, close, session shutdown, replacement, child exit and storage failure
invalidate pending answers. Cancellation never emits `:interaction_resolved`.
Replacement retains the stable child identity and carries canonical messages,
mailbox and the `host_feedback` history seed with their original record identities.

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

One `DynamicRuntime` can serve independent callers, runs and incarnations with
overlapping candidate names. Each exact owner has its own candidate corpus and
publication state, retained until Runtime shutdown. `tool_search` uses the
generic metadata and English BM25 algorithm pinned to Codex revision
`46fdd5ef39735f4159cdcf0ec5e85c10521494e5`: names, descriptions, recursive input
properties, namespace descriptions and custom syntax are searchable. It runs in
pure Elixir with packaged data. Specialized Codex MCP indexing and namespace
grouping are outside this compatibility scope. Queries must be nonblank UTF-8
strings; stopword-only queries return no matches. The default limit is 8 and
must fit the configured per-owner bound. Publication still takes effect at the
next model turn. See `docs/agent-runtime/codex-tools/deferred-owner-search-validation.md`.

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

At the host-to-Deno boundary, settled native tool errors remain ordinary resolved
values (`ok: true`), including `is_error: true` results. Native runtime Error
values inside ordinary maps/lists expose only `class`, `message`, and recursively
projected `details`; private `cause` is omitted. JavaScript can inspect the result
and call another tool without replaying the settled invocation. Native
Conversation/Store results and invocation identities retain their original form.
Other structs retain their existing JSON encoder behavior. Unsupported values or
details terminate Code Mode as `malformed_result` after confirmed cleanup; an
encoded NDJSON record over 1,048,576 UTF-8 bytes, excluding its newline, terminates
as `budget_exceeded`. Returned context is retained before encoding validation.
Transport errors still reject the nested Promise; explicit `unknown_outcome`
and unconfirmed process cleanup remain terminal uncertainty.

`Codex.Session` optionally owns commands, cells, stored state, and collaboration
identities across separate bounded runs. Hosts bind a fresh run, build its profile,
and pass the returned `session_binding` to Conversation. Natural successful
completion prepares detachment, commits the run finish, then acknowledges
retention. Cancellation/failure/session close fence admission and perform bounded
cleanup; restart creates a fresh session identity and never replays effects.
See `docs/agent-runtime/codex-tools/session-resources.md` for the host API.

A managed child can retain its own Session while sharing its root's MultiAgent
manager and unchanged native collaboration contracts. Return the child's fresh
binding from `child_options/3`; the manager adopts it before starting the child.
Successful follow-ups use that same open Session with fresh run authority.
Child failure or target-only interruption closes local resources; root/recursive
close also reaches idle retained child Sessions. Unknown adoption or close
receipts preserve ownership obligations and prevent replacement. Host-owned
Session infrastructure remains inspectable after resource close.

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

## First-party Linux PTY

Build the optional native source on the target Linux host:

```sh
mix backplane.pty.build
```

```elixir
alias Backplane.AgentRuntime.{Command, Tools.LocalCommand}
{:ok, backend} = LocalCommand.start_link(pty: true)
{:ok, command} = Command.new(%{adapter: LocalCommand, server: backend})
```

Bind `command` into the existing local Codex profile. `tty: true` uses the native
controlling terminal; omitted/false tty keeps pipes. Trusted backend options
`terminal_rows`/`terminal_columns` accept 1..1000 (default 24/80). Startup probes
the first-party helper and actual PTY/pidfd syscalls; unavailable support returns
a structured error and never silently substitutes a pipe. Pipe-only consumers
need no C compiler. Optional `pty_helper_path` selects a trusted absolute helper.

Output preserves prompts, CR/LF and escape bytes without inserted separators.
Split UTF-8 suffixes wait for the next frame/poll; invalid/final incomplete bytes
use deterministic replacement. `write_stdin` passes input/control bytes through
normal terminal line discipline; Ctrl-C signals the foreground job. Explicit
cancellation/Session close cleans ordinary foreground/background groups in the
terminal session, including after its original leader exits. Deliberately creating
a different session is outside this scope.

Confirmation requires exact guardian cleanup evidence, broker reaping and broker
Port exit. Missing helper proof stays `unknown_outcome`; a successful command
exit alone does not release the session. No OS sandbox or post-crash observer is
added. See [protocol, process ownership and build prerequisites](c_src/README.md).

### Caller-owned MCP resources and interruption

Dynamic MCP list, template-list and read callbacks run in their actual effect
caller. Existing adapters keep their ordinary success/error behavior and now own
MCP handles in that caller; legacy adapters retain uncertain interruption cleanup.
An adapter whose only cancellable work is one MCP resource request can opt in:

```elixir
DynamicRuntime.resource_request(operation, fn ->
  Client.start_read_resource(client, uri, opts)
end)
```

The helper preserves the public MCP success/error for the adapter to convert. It
requires `backplane_mcp_protocol ~> 1.10.46`. It registers the admitted operation
before starting and binds cancellation to that registration, the original MCP
logical request and live client incarnation. A confirmed cleanup records exact
local request retirement, actual effect Task termination, and Session/Registry
cleanup. Remote cancellation remains unknown. Nested Code Mode also requires the
matching enclosing invocation and real Deno cleanup; either proof alone is
insufficient. Missing acknowledgements or an expired cleanup deadline retain
uncertain obligations, and cancellation never synthesizes a successful tool result.
If ordinary completion wins the cancellation race, its result alone does not prove
local cleanup; interruption remains uncertain without that separate evidence.

### Headless native Code Mode

`Codex.Headless` is a facade over one `Conversation` owner. Supply the ordinary
Store, admitted native catalog and resources, with no provider options:

```elixir
{:ok, occurrence} = Headless.start_link(opts)
{:ok, identity} = Headless.execute(occurrence, source, input: %{"job" => "daily"})
{:ok, result} = Headless.await(occurrence, timeout: 30_000)
```

One instance admits one occurrence. The actual `execute` caller is monitored for
its entire execution; supervisors and later observers do not replace it.
`status/1` and `cancel/1` use the same owner. Await timeout leaves execution alone.
Prompt, steer, follow-up and provider options are rejected. Source/input and the
complete worker command frame are bounded before admission; JSON input is the
worker's `input` global and is never interpolated into source or host callbacks.

The Store journals `host_step_started`, then the actual native outer `exec`
intent/result. It records a portable catalog projection and digest, without
executable registry handles. Every nested intent precedes its effect and every
nested result ACK precedes its JavaScript reply. Generator and time-slice yields
are resumed internally with nil under one original deadline and configured timeout.
Ordered output shares one total hard/presentation bound across slices; truncation
is retained. The result preserves the raw supported JSON `value`, `output`,
`output_truncated`, `nested_invocations` and separate `outer_reservations`.
Successful await requires committed terminal completion; cancellation cannot turn
an intermediate persisted raw result into success. Zero nested calls are valid.
Terminal reload is inspection-only; unfinished reload enters `recovery_required`
without provider calls, script replay or ownership reattachment.

### Plugin request observation retirement

Plugin installation adapters run on the actual native effect caller, with
serialized request admission and result publication. An adapter may durably
acknowledge its host request, then opt into narrowly cancellable observation:

```elixir
DynamicRuntime.plugin_install_wait(operation, immutable_host_request_ref, fn ->
  observe_existing_request()
end)
```

The callback only observes that acknowledged request. It must not install,
start an MCP client or dispatch other work. The runtime seals the exact request's
completion gate before stopping its registered caller/waiter. It records actual
DOWN under the original cleanup deadline. Old adapters remain compatible and
retain unknown interruption outcomes. The host request survives independently;
late completion or a later explicit installation cannot rewrite the old run.

`DynamicRuntime.plugin_install_retirement(runtime, exact_identity)` returns a
bounded typed proof for the exact original invocation, request, registration,
Session and stop generation. `Conversation.status/1.retirement_evidence` retains
up to 256 proofs. Hosts must persist needed evidence before losing the runtime;
missing or evicted records remain unavailable. A separate outer Code Mode proof
requires actual executor exit, Session/Registry cleanup and every original nested
settlement or exact retirement proof. These records certify local retirement,
with business outcome unknown, and do not report remote rollback or tool success.

### Image invocation context

`image_gen::imagegen` revision 2 is mutating, not retry-safe or parallel-safe.
The existing `generate(request, opts)` adapter receives reserved
`opts[:runtime_context]`: portable exact invocation/Session identity, resource
ownership, the original effect caller PID and a live `effect_deadline` accessor.
Configured image options cannot replace it. Image timeout is clamped to that
live remaining budget, and stale accessor errors propagate. Process-local
ownership/accessors must not be stored as artifact metadata. Standalone image
calls and adapters ignoring the additive option remain supported. Paid requests
are never automatically replayed; local Task termination does not prove remote
cancellation. Web contracts retain their existing metadata.
