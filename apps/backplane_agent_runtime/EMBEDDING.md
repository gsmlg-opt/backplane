# Embedded execution

## Ownership and API

Start `Backplane.AgentRuntime.Conversation` under a host supervisor with:

- `run_id`, optional `incarnation` (default 1), `store`, and `context` (the store handle).
- `provider`: a module implementing `ConversationAdapter.stream(request, context)`.
- `provider_context`: trusted ephemeral adapter dependencies; never persisted.
- `registry`: `ToolRegistry` descriptors with `schema`, `backend`, `backend_context`,
  revision and safety metadata. An empty registry is valid.
- `authority`: existing runtime grants/caller/run/revision. Model arguments never
  select backends or widen authority.
- Optional `hooks` implementing `prompt/2`, `stop/2`, and/or `prepare_tool/2`.
- Optional `subscriber` PID receiving `{:agent_runtime, run_id, event}`.
- Finite `work` quota (default 100), `run_timeout` (300,000 ms or explicit `:infinity`), `effect_timeout`
  (30,000 ms), `commit_timeout` (5,000 ms), and `cleanup_timeout` (5,000 ms).
  Work counts provider attempts and tool invocations; it is not a token or billing
  quota. Provider usage is retained separately without inventing missing values.
- `provider_output_limit`: a non-negative integer byte budget per provider response,
  or `:infinity` to permit unlimited generated content. When absent it inherits
  the finite `output_limit` option, whose default is 1,048,576 bytes.
- `output_limit`: a finite non-negative integer tool-result bound (default
  1,048,576 bytes). `:infinity`, other atoms, nil, negative and noninteger values
  are rejected; unlimited provider output never changes this tool bound.

`prompt/2` admits the initial user input. During execution, it queues a follow-up,
matching Sigma's default. `steer/2` queues steering. `follow_up/2` queues a new turn.
Calls acknowledge only after the corresponding checkpoint commits. Prompt hooks
may reject an initial prompt before its admission acknowledgement. Content can be
text or host content-block lists. Attachments and retry metadata can remain in
host content blocks/context; Sigma's command adapter owns their public shape.

One steering item is consumed after the provider response and complete sequential
tool batch, or after a response without tools, before the stop hook. Follow-ups
start after the current turn outcome is committed. One root run shares its work quota and configured
deadline policy across these turns. A completed root rejects further prompts;
the session adapter starts a new run with its committed canonical messages.

`cancel/1` acknowledges cancellation acceptance immediately, fences callbacks,
stops the current worker, and then persists cancellation/cleanup. A cancellation
racing an intent commit never dispatches that intent after acknowledgement.
An interrupted provider or tool is conservatively `unknown_outcome`: stopping an Elixir task
is not proof an external mutation did not happen. Queued follow-ups remain in the
snapshot after cancellation with `queue_status: :suspended`. Sigma's session adapter can admit them into a new
bounded run after settlement, as Sigma does after a cancelled turn. It must not
replay the cancelled tool.

`status/1` returns the last committed run, transcript, queues, usage and phase.
`:storage_failed` means acknowledgement failed or timed out; no dependent effect
starts, no durable terminal is asserted, and the host must load/reconcile storage.
A timeout can mean the store committed without replying. Do not retry blindly.

## Provider and tool adapters

The provider receives serializable request metadata, messages, turn_id, run_id,
incarnation, step_id and attempt_id. It returns an Enumerable. The runtime consumes
it in a supervised bounded worker, with one synchronous event acknowledgement at
a time. It preserves normalized text, thinking, tool-start/arguments/completion,
usage and response-terminal events. The first terminal ends enumeration; exhausted
streams without a terminal fail. Terminal assistant tool-call blocks are
validated and executed; incremental completed calls support providers whose final
message does not include tool blocks. Duplicate tool IDs fail explicitly.

Provider content accounting counts UTF-8 bytes of generated text and thinking,
plus tool arguments. Normalized `index` identifies a content block (default 0
when omitted); use distinct indexes for multiple blocks of the same kind. Tool
IDs join indexed argument deltas/snapshots to completed calls, including IDs that
arrive only at completion. Binary/custom arguments and `partial_json` snapshots
use their raw byte length; materialized argument maps use compact JSON encoding.
For each logical block the counter retains the larger of accumulated delta bytes
and the largest snapshot, so repeated snapshots, tool-call completion, usage and
the terminal message never add a second copy. Raw JSON whitespace/escaping can
make streamed arguments larger than their materialized map encoding; the larger
representation determines that block's budget. A final-only message counts its
content, and a terminal snapshot can contribute bytes not present in deltas.
The counter resets before every provider attempt, including tool continuations.

Usage, tool names/IDs, signatures, metadata and event envelopes do not consume
this content budget. Provider transport limits remain the host adapter's policy.
A finite limit breach returns `Backplane.AgentRuntime.Error` with class
`:resource_conflict`, message `"provider output limit exceeded"` and details
`%{scope: :provider_response, size: bytes, limit: limit}`. Invalid options return
`:validation` before provider/tool dispatch. The same provider option and
content accounting apply to direct non-stream `Execution.run/5` provider effects;
responses may carry an assistant `message`, normalized `content`, or `text`, with
optional `tool_calls`/`tools` collections. Deadlines, finite work budgets,
authorization, cancellation and uncertain-effect settlement still apply.

For example, an embedding can select `provider_output_limit: :infinity` while
retaining `output_limit: 1_048_576` for tool results.

A Sigma provider adapter builds `Sigma.Ai.ProviderRequest` from that request and
its trusted configuration, then returns `Sigma.Ai.Provider.stream(provider,
request)`. It maps runtime tool-result messages into Sigma's provider context.
No provider HTTP or SSE code needs copying. Real Sigma provider normalization is
exercised by the optional `SIGMA_SOURCE` artifact fixture; this is not execution
of Sigma's entire Agent or its production providers.

Tool backends retain the existing `execute(operation)` contract. They receive
validated arguments and authoritative identity/grants, plus their configured
backend_context. The context also supplies:

```elixir
context.emit.(%{type: :tool_update, ...})
{:ok, answer} = context.interact.(%{kind: :permission, question: "Allow?"})
```

The host receives `interaction_requested` with a fresh `interaction_id`, then
calls `Conversation.resolve(pid, id, answer)` after authenticating the responder.
The answer is persisted before the worker continues. Stale/duplicate IDs fail.
An explicitly requested human interaction suspends the active effect, nested
invocation, Code Mode worker, and root deadlines. On resolution, each resumes
with its remaining pre-wait budget; queued timeout messages from before
suspension are fenced by the active timer. Provider and tool execution outside
an interaction remains bounded. Cancellation closes pending interaction
ownership. MCP form rendering and answer validation remain in the Sigma
tool/interaction adapter. Nested interaction is supported through the same
trusted context; a nested invocation has its own token and settlement identity.

Root, effect and nested execution timers carry a fresh generation each time
they are armed. Suspension invalidates the previous generation; resumption
uses only the remaining budget. Store admission acknowledgement alone cannot
revive an interaction after a valid timeout or cancellation wins. Commit and
cleanup deadlines continue to run during human waiting. Engine timer fencing
is separately deferred; these shared-runtime guarantees do not verify Deno or
Denox engine behavior.
If a nested worker dies during an acknowledged human wait, the runtime stops
with uncertain settlement and clears the interaction rather than continuing
with suspended deadlines.
An already-dispatched, potentially mutating direct or nested tool also remains
unresolved when its worker dies, times out, or returns an uncertain result. The
runtime classifies the normalized outcome against the pinned admitted tool
descriptor, then stops through the existing `unknown_outcome` settlement path
without completing that invocation. Its active-tool and execution-intent
evidence remain inspectable. An outer tool catching the error or attempting to
return success, OS cleanup, cancellation, or a late Task result cannot consume
or replay it. Explicit `unknown_outcome` stays uncertain even for a read-only
descriptor; an ordinary confirmed read-only error can be handled. Error text,
model arguments, and `retry_safe` do not prove that a mutation did not run.
A registered host backend that rejects an invocation **before dispatching any
external effect** can return `ToolEffects.reject(operation, error)` instead of a
plain error:

```elixir
alias Backplane.AgentRuntime.{Error, ToolEffects}

def execute(operation) do
  with :ok <- authorize_without_dispatch(operation) do
    dispatch_tool(operation)
  else
    {:error, %Error{} = error} -> ToolEffects.reject(operation, error)
  end
end
```

This is an assertion by the trusted backend, not independent runtime observation
of the host. Use it only for checks completed before dispatch: rejected scoped
approval, expired or mismatched grants, or a changed/disabled host registration.
The rejection binds the current operation's run/incarnation, provider attempt,
invocation, descriptor/catalog identity and exact arguments. Execution validates
it before returning a structured `is_error: true` result to the provider and
settling that invocation. The host must use the exact runtime operation; changed,
incomplete or replayed identities fail closed. `:unknown_outcome` cannot be
converted to a rejection.

The built-in collaboration backend uses this contract for explicit refusals
before effects, including capacity before child reservation, duplicate task
names and missing targets (#72). With a total V2 limit of four, a root with three
executing children receives a structured `:resource_conflict` tool error on its
fourth spawn and can continue; the admitted children remain running. That
refusal creates no child preparation or admission receipt. Fully identified
runtime operations receive rejection proof; legacy direct calls with incomplete
identity retain plain errors. Errors after admission reservation or host
preparation, attempted delivery/interruption, or unconfirmed cleanup are not
reclassified, even when they use the same error class as a capacity refusal.

Do not call this helper for an error returned by an already-dispatched tool,
for a timeout/crash, or based on missing backend records. Plain errors and error
metadata claiming non-execution retain their existing uncertainty classification.
Late rejection results cannot revive cancelled or timed-out work. Host adapters
that currently return plain pre-dispatch errors, including the Synapsis adapter
reported in [#60](https://github.com/gsmlg-opt/backplane/issues/60), must explicitly
adopt this contract; upgrading the package alone does not reclassify those errors.

Hosts can implement `hooks.prepare_tool(invocation, context)` to prepare a tool
before final schema validation, authorization, approval and the `:tool_invoked`
commit. The invocation pins its run, attempt, call, tool revision and catalog;
`invocation.arguments` contains the original function arguments or raw custom
input. `context.input_kind` is `:function` or `:custom`. The context supports the
existing correlated interaction API, but provides no nested-dispatch or catalog
publication callbacks.

The optional callback returns `:allow`, `{:allow, final_input}`, `{:deny, reason}`,
or `{:error, %Backplane.AgentRuntime.Error{}}`. Omission allows unchanged input.
Only the input can change: return a map for a function tool or a binary for a
custom tool, never an altered invocation/descriptor. The runtime validates the
final input against the pinned descriptor and authority. Approval, the committed
intent and backend dispatch all use that exact final input. The hook must not
perform the tool effect. A backend must not rewrite already approved or committed
arguments; move such transformations into preparation.

For descriptors with `requires_approval: true`, only `:approved` permits the exact
requested operation. The runtime binds approval to run, tool revision and argument
digest and retains the Execution approval gate. A host can resolve the interaction
with `{:update_input, final_input}` to edit input; this revalidates/reauthorizes and
requests a fresh approval with a fresh interaction ID. Approval for earlier input
cannot approve the replacement. Other answers deny. Preparation runs once and is
not repeated for approval edits. Preparation and approval edits share one finite
active admission budget; human interaction pauses it rather than replenishing it.

Preparation workers have per-invocation callback tokens and timer generations.
Denial, malformed results, exceptions, cancellation, timeouts and stale results
produce no invocation commit or dispatch. Preparation rejection permits provider
continuation; interruption of an already dispatched enclosing tool retains the
existing uncertain-outcome rules. Supported nested calls prepare and validate
through the same boundary while preserving the outer worker. Nested tools that
require runtime interactive approval remain unsupported (`:approval_required`).
A `nested_dispatch` caller must remain attached to its enclosing invocation. If
the enclosing worker ends while nested preparation is pending, the runtime cancels
that preparation and its waiter through conservative existing uncertainty
settlement; the nested tool cannot dispatch after its owner ends.
Host permission/pre-tool transformations should use preparation; post-tool hooks
remain in the backend. These hooks apply to `Conversation`; direct explicit-command
Execution users must prepare their own exact input before committing it.

Tools run sequentially. Sigma's batching/parallel performance is not reproduced;
calling its dispatcher for one tool retains its local execution policies without
running a second conversational loop. Session start/end hooks, context assembly,
compaction, tool failure nudges, and stop-hook recursion policy remain host code.
The optional prompt hook runs before every admitted/steering user message. The
stop hook runs after no-tool responses and steering handling, returning `:stop`
or `{:continue, synthetic_user_message}`. Synthetic stop continuations do not run
the user prompt hook again, matching Sigma's ordering.

## Tool catalog publication

Hosts that discover a batch can opt into schema quarantine at the runtime
boundary. For example:

```elixir
{:ok, bundle} = Backplane.AgentRuntime.ToolCatalog.admit_batch(
  %{registry: registry, authority: authority, tools: provider_tools},
  mode: :quarantine,
  run_id: run_id
)
```

Strict mode is the default. The returned `bundle.registry`, `bundle.tools`, and
`bundle.authority` must be passed together; do not retain the original registry
or independently append `:tools`. `bundle.rejected` is a trusted-host
diagnostic only. A repaired descriptor can be admitted again at a new
descriptor revision; quarantine is not a name denylist. The same option is
available as `schema_admission: :quarantine` for initial Conversation options
and dynamic catalog updates. Sigma adapters may map deterministic admission
errors to their own non-retryable migration guidance; this package does not
change Sigma error classes.

For catalogs whose descriptors have different revisions, authority may carry
`tool_revisions: %{tool_name => revision}`. Admission and execution use the
per-tool value when present and retain the legacy single `tool_revision`
fallback. Rejected entries are removed from both `grants` and `tool_revisions`.

Each provider request includes `catalog_revision` and canonical provider tool
definitions shaped as `%{name: binary, description: binary, parameters: map}`.
The provider attempt and its complete sequential tool batch use that snapshot.
Existing fixed-catalog callers may continue to pass `registry` and `authority`;
the initial catalog revision defaults to 1 and definitions are projected from
the registry unless `tools` is supplied.

An executing trusted tool can stage one complete replacement with
`Conversation.stage_catalog/2` or `backend_context.stage_catalog/1`:

```elixir
%{
  publication_id: "catalog-2",
  run_id: run_id,
  incarnation: incarnation,
  expected_revision: 1,
  catalog: %{
    revision: 2,
    registry: registry,
    authority: authority,
    tools: provider_tools
  }
}
```

Catalog revision is independent of descriptor `tool_revision`. Publication
validates the run/incarnation fence, expected next catalog revision, schemas,
available backends, exact provider definition/registry membership, and existing
per-descriptor `Policy` authority. The bundle remains process-local: registry,
authority, backend contexts, provider context, grants, and credentials are not
added to the persisted run or provider request.

Staging acknowledges immediately and never waits for its own tool effect. A
successful discovery effect publishes the complete bundle after the current
batch checkpoint and before steering, hooks, or another provider attempt. Other
calls in the discovery response remain pinned to the old catalog. Failed,
error-marked, cancelled, or storage-failed discovery discards its staging.
Approval and interaction waits reject new staging.

Nested discovery records both the producing invocation and the enclosing tool
publication boundary. A staged catalog becomes eligible only after the producing
invocation has an acknowledged successful result; outer failure, timeout,
cancellation, or storage uncertainty discards dependent staging. A callback from
a completed nested invocation is rejected by its expired token even while the
outer tool remains active. Publication still occurs once at the existing
post-batch boundary, so calls in the discovery batch remain pinned to the old
catalog.

A nested producer stops accepting callbacks when its execution ends, before
its settlement acknowledgement arrives. Failed, error-marked, timed-out,
cancelled or uncertain producers relinquish their own staged catalog then;
they cannot retain the pending slot or mutate a later producer's update. A
successful producer becomes eligible only after its settlement is acknowledged.

Conversation persistent transitions, including nested admission, result, timeout,
interaction, and publication checkpoints, use one FIFO commit coordinator. A
queued transition is rebased against the last acknowledged conversation before
dispatch; cancellation clears queued transitions before any effect can start.

`status/1` exposes the active revision plus staged/published receipts without
catalog contents. Reusing a `publication_id` with the structurally identical
bundle returns its existing receipt, including after publication; different
content conflicts. The Conversation retains the 16 most recent receipts for
acknowledgement-loss reconciliation. Older evicted IDs require host-level
reconciliation and must not be retried blindly. Run/incarnation fencing is
checked before every receipt lookup. Catalog state is intentionally ephemeral;
restored Conversations remain inspection-only under the existing recovery contract.

## Persistence and restart

Every effect uses the existing `Execution.commit/5` gate. Provider completions
atomically store their transcript and settle the reservation. Tool completions
store their result before appending its transcript projection; a crash between
these commits leaves the result in `run.tool_results` for host reconciliation and
never automatically repeats the tool. Queues, interactions, turns and usage are
stored in `run.context.conversation`.

To inspect a recovered run, supply the stored `:run` to start_link. Terminal runs
remain terminal; all other restored runs enter `:recovery_required` and execute
nothing. `Store.fence/6`/`RecoveryHarness` let a durable host fence old incarnations
and classify uncertain work. The host owns recovery decisions and a replacement
run after reconciliation. `EphemeralStore` cannot establish restart durability.
See [PERSISTENCE.md](PERSISTENCE.md) and the shipped `StoreConformance` helper.

## Compatibility changes and limits

Existing Provider.start/chunks, Execution, ExecutionController and tool APIs remain.
The new lazy-stream adapter is additive. Durable adapters now need atomic
incarnation fencing to claim durable conformance; missing support fails explicitly.
Schemas are checked recursively, including unused branches, so previously ignored
unsupported nested constraints now fail before invocation. No published protocol,
production durable adapter, full Sigma migration, production provider/service
conformance, or native Codex wire parity is implied by local artifact tests.
The opt-in Codex collaboration profiles supervise child `Conversation` processes;
they do not imply integration with Sigma's persistent peers or scheduler.
Incremental subscriber events are transient; Sigma retains its
ProtocolSubscription backpressure, cursor and replay policies.

### Collaboration host observation and V2 capacity

`Codex.MultiAgent.snapshot/1` returns `{:ok, snapshot}` with all created child
identities, including closed records. `subscribe/2` (subscriber defaults to the
calling process) installs a monitored observer and returns that snapshot in one
serialized call. Events use `{:codex_collaboration, event}` with a process-local
`manager_id`, monotonically increasing `revision`, transition `type`, and the
complete public `agent` record (or `admission` receipt for admission events).
Apply events newer than the snapshot watermark,
deduplicate by manager ID and revision, and fetch another snapshot on a gap or
manager replacement. `unsubscribe/2` stops subsequent delivery. The model-facing
`list_agents` retains its separate live-agent projection.

Public records contain stable agent and parent identities, task name, profile,
current run ID/incarnation, lifecycle status/reason, cleanup certainty, residency,
and explicitly supplied JSON-safe `host_metadata`. They exclude process handles,
grants, adapter contexts and raw failures. Creation and start are published before
provider execution; cancellation acceptance is not confirmed interruption.
Unexpected process exit or lost cleanup acknowledgement retains uncertainty.

The trusted `child_options(request, run_id, parent_context)` callback prepares
each spawn or replacement activation before execution. The manager consumes a
unique reservation before invoking it. `parent_context.child` supplies the
`attempt_id`, prospective `run_id`, stable `agent_id`, name, incarnation and
activation kind. Rejected attempts consume their reservation; retrying the same
task receives a fresh attempt and run ID. A replacement retains its stable agent
identity while receiving a fresh attempt and run ID.

Returning `{:ok, options}` acknowledges that the host has persisted the
birth/activation intent and associated the supplied identity with its store.
Durable hosts must complete that transaction before returning success. They can
return non-sensitive JSON-safe `host_metadata` for observation; it is removed
before starting the Conversation. Preparation rejection, malformed options and
callback exceptions prevent input dispatch and retain a correlated rejection.

Hosts can also supply `admission_receipt: fn receipt -> :ok | {:error, error} end`
to persist admission outcomes synchronously. A `:created` receipt confirms that
the child process was started; its acknowledgement gates initial input dispatch
and provider/tool effects. It does not promise that input admission or provider
execution will succeed. Subsequent input failure produces a correlated `:failed`
receipt. Rejected preparation produces `:rejected`; startup failure produces
`:failed`. Receipt callback failure prevents input dispatch. Receipts expose safe
identity and outcome fields, excluding host options, authority and raw failures.
`process_started` remains true after any later failure, distinguishing failed
startup from failure after confirmed process creation in a fresh snapshot.
`receipt_acknowledged` is true or false when a callback is configured, and nil
otherwise; `receipt_error_class` records a failed acknowledgement separately
from the admission's `error_class`.
Use the admission receipt for confirmed process birth; the existing `:created`
lifecycle event still announces the identity before process startup. Both trusted
callbacks run inside the manager's serialized operation and must not synchronously
call back into that manager.

The snapshot's `admissions` list and revisioned `:admission_reserved`,
`:admission_created`, `:admission_rejected` and `:admission_failed` observer events
support reconciliation within the manager lifetime. An asynchronous observer is
not a durability acknowledgement. The host must reconcile prepared intents after
manager loss; manager state, receipts and observer revisions do not survive
restart or automatically restore children. Durable reservation/receipt storage
is a Backplane host integration contract, not a claim of native Codex durability.

V2 `max_concurrent_threads_per_session` includes the root and defaults to four.
An explicit legacy `max_agents: n`, when the new option is absent, retains an
`n`-child-slot configuration. Spawn, nested spawn and idle follow-up share the
same serialized admission budget; saturation returns `:resource_conflict`.
Running, cancelling and uncertain children reserve slots. Confirmed safe
settlement releases execution capacity, independently of retained identity.
Idle child processes are unloaded as needed to keep residency within the child
slot bound, retaining committed history and remaining authority/work/deadlines.
Follow-up activates the same identity with a fresh run, without replaying its
original prompt or uncertain effects.

V2 `interrupt_agent` interrupts only the target's current task and rejects root
or self targets. Settled/unloaded targets remain inspectable and are not reloaded
by interruption. Independently running descendants and siblings continue.
V1 `max_agents` continues to count open identities, and V1 `close_agent` closes
the target and descendants. Explicit owner-session shutdown cleans up the tree.

### V2 mailbox delivery and waits

V2 `send_message` queues attributed input for a registered running or idle
identity, including a child's parent/root. It does not steer the recipient or
start an idle turn. `followup_task` explicitly activates work. Queued mail is
consumed at the recipient's next natural provider continuation or explicit
activation; mail arriving while a final response completes does not cause an
extra provider request.

Terminal child results use the same mailbox boundary with source agent, run,
incarnation and result identities. Host lifecycle notifications remain separate
from model input. Duplicate notifications for the same terminal activation do
not create another accepted result; stale run/incarnation notifications cannot
deliver a result for a replacement activation. Delivery is best effort, with
acceptance recorded after the recipient acknowledges it. Failure to reach an
unavailable, closed or recovery-required recipient is not successful delivery.

V2 `wait_agent` watches the invoking agent's pending mailbox and new steer.
It returns `Wait completed.`, `Wait interrupted by new input.`, or
`Wait timed out.` with `timed_out` true only for timeout. Pending steer takes
priority when both kinds are already queued. Timeout leaves children running.
V1 wait retains its explicit target/status behavior.

Mailbox acceptance is not an exactly-once durable-delivery guarantee. Active
Conversation input is checkpointed before acknowledgement. Fresh, unadmitted
Conversations and idle/unloaded identity queues retain mail in process-local
state until the next run admits and checkpoints it. Manager replacement does
not restore those queues. Durable hosts must reconcile their own accepted
messages and activation intents; observers do not provide mailbox persistence.

### Host-named collaboration contracts

`Codex.MultiAgent.bind_contract(manager, action, attrs)` binds a host's tool
contract to an explicit V2 action before catalog admission. It returns
`{:ok, contract}` in the usual `Codex.Contract` shape. The existing Codex V1/V2
profiles retain their names and schemas. A host can instead publish names such
as `sessions_spawn` or `agents_wait` with its own argument and result formats.

| Action | Canonical arguments supplied by the host adapter |
|---|---|
| `:spawn` | `task_name`, `message`, and supported V2 child options |
| `:message` | `target`, `message` for queue-only mail |
| `:followup` | `target`, `message` for explicit activation |
| `:list` | Optional V2 list filters |
| `:wait` | `timeout_ms` within the manager's configured bounds |
| `:interrupt` | `target` for the current task |

The trusted host supplies `attrs.name`, `tool_revision`, JSON `schema`,
`backend`, and `safety`, as for other contracts. Binding adds
`contract.collaboration_binding`, containing the manager identity, action and
SHA-256 fingerprint. The fingerprint covers the canonical name, revision,
schema, input/output format, backend module, safety and action. Change the
declared revision when the host adapter changes its conversion semantics.

Grant the returned contracts explicitly:

```elixir
authority = %{
  caller: "my-host",
  run_id: run_id,
  grants: Enum.map(contracts, & &1.tool_name),
  tool_revisions: Map.new(contracts, &{&1.tool_name, &1.tool_revision}),
  tool_bindings: Map.new(contracts, &{&1.tool_name, &1.collaboration_binding.fingerprint})
}

{:ok, binding} = Codex.Session.bind(session, authority)
contracts = Enum.map(contracts, &put_in(&1, [:backend_context, :session_binding], binding))
{:ok, bundle} = Codex.Catalog.admit(contracts, authority)
```

Pass `bundle.registry`, `bundle.tools`, `bundle.authority` and that
`session_binding` together to `Conversation.start_link/1`. Attaching the
Conversation binds the manager to the current session/run authority. Bindings
alone grant nothing: policy recomputes the actual descriptor fingerprint and
requires the exact per-tool grant. A changed name, revision, schema, backend or
action cannot use the old authorization. Quarantine narrows `tool_bindings`
alongside grants and tool revisions. Session capabilities remain ephemeral and
are excluded from the descriptor fingerprint.

Native and host-named contracts can share a manager. Once bound policy is in use,
native calls also require their own current name and revision grants; removing a
binding or renaming an invocation cannot switch to an ungranted native action.

The host backend translates arguments separately, then calls
`Codex.MultiAgent.call_bound(original_operation, canonical_arguments)`. For
example, a `sessions_spawn` adapter can map its `task` field to canonical
`message`. It must preserve the original operation's name, revision, arguments
and invocation identity. The registered binding selects the action; model
arguments do not. The host may translate a successful result, while returning
refusals and uncertain errors unchanged.

The original binding is journaled before dispatch and participates in approval
and refusal matching. Manager checks also require the current parent or child
authority, session owner and run incarnation. Capacity checks, child reservation,
host preparation/receipt acknowledgements, inherited policy, mailbox delivery,
waits and interruption use the same existing MultiAgent implementation.
Admission evidence retains the triggering invocation identity and original
argument digest. A failure after reservation remains subject to the existing
uncertain-outcome rules; it does not become proof that nothing happened.

Bindings belong to one manager lifetime. Replacing that manager requires new
bindings and explicit grants; no binding restores children or replays effects.
See the packaged `examples/host_collaboration.exs` for a complete, deterministic
Session/Conversation integration with custom schemas and successful-result
conversion. It uses ephemeral stores; durable hosts still own the persistence
and reconciliation contracts above.

## Codex run resources and cleanup

Codex command sessions and Code Mode cells belong to the executing Conversation,
not its short-lived effect Task. The runtime supplies that owner through trusted
backend context; model arguments cannot change it. Cells are supervised by the
resource registry's worker supervisor and use a `:temporary` child specification,
so normal completion, cancellation, protocol failure, or a crash never replays
the original start arguments. A resumed cell retains its identity and nested-call
counter, but receives the current wait invocation's dispatcher, authority,
incarnation and catalog snapshot. The previous effect token is never made valid
again.

Run completion, cancellation, deadlines, provider failure and storage failure
initiate bounded cleanup even if the Conversation remains alive. Command ownership
is registered before launch/polling. A host selecting a Codex profile must not
assume returned sessions survive completion of their run. This repair introduces
no implicit session-lifetime extension.

Numeric command sessions are bound to the trusted invocation incarnation as well
as the run owner. Reservation cleanup carries a stable session identity from
before launch through the backend acknowledgement, so a rejected or ambiguous
launch can only reconcile that invocation. An adapter without per-invocation
confirmation reports uncertainty and never falls back to owner-wide cancellation.
A replacement incarnation cannot poll or release an old session by reusing its
numeric ID; host reconciliation remains responsible for old work.

`Conversation.status/1` includes process-local `resource_cleanup` evidence.
Failed cleanup prevents a confirmed terminal outcome; failed or lost storage
acknowledgement remains `:storage_failed` even if the OS processes were stopped.
Registry `owner_status/2` and `cleanup_status/3` expose reconciliation evidence;
they are not a durable resource store. Cleanup tasks execute outside the registry
server and are bounded independently of other resource operations. Conversation
requests all owned registries concurrently under its cleanup deadline and
acknowledges cancellation before waiting for those outcomes.

Command adapters can implement the optional `cancel_confirmed/3` callback
(command, invocation, timeout). The invocation includes the trusted session
identity for individual cleanup; owner-wide cancellation remains a separate run
termination path. Return `:ok` only after verifying owned resources
are stopped. Existing `cancel/2` keeps its request-acknowledgement contract; it
alone cannot prove cleanup. Adapters without confirmation leave Codex cleanup
uncertain. Linux `LocalCommand` implements confirmation for its supported process
groups; descendants that establish a new session are outside that guarantee.

Command adapters may implement `reserve/2` and `acknowledge_release/2`. Codex
registers the owner-bound session first, then reserves it with the backend before
launch. Native reservation binds the owner and incarnation, fences cancellation
before handle binding, and pins evidence until registry release is acknowledged.
Owner-wide `Command.cancel/2` also confirms and fences that owner's existing
never-launched reservations in the LocalCommand backend before replying. A
delayed launch with an old session identity is rejected while the owner PID is
still alive. This is distinct from per-invocation `cancel_confirmed/3`; another
owner's reservation remains usable, including when a newer cancelled receipt
has been evicted.

Legacy adapters keep their existing `start/3` result contract; a generic error
or missing record remains uncertain unless trusted backend evidence proves
non-start. Only an explicit validated rejection carrying
`Error.details.launch_status: :never_started` and `reservation: :not_created`
allows withdrawal without cleanup. An adapter emitting that evidence must have
fenced every later launch of that identity before replying; an error class alone
is insufficient. LocalCommand emits it when finite admission capacity is full.

LocalCommand accepts positive `receipt_capacity` and `session_capacity` options
(both default to 256). Unacknowledged confirmations and unresolved obligations
are pinned, and retained command/output resources also apply admission
backpressure. Registry receipt acknowledgement runs in a supervised task with
the registry cleanup timeout. Hosts that fail to acknowledge consumed evidence
must reconcile backend obligations before admitting more work.

Recent release receipts preserve exact owner/incarnation checks. Repeated
release is confirmed while the receipt or a pinned obligation exists; an evicted
receipt returns `:unknown_outcome` with `receipt: :expired`. This means
unavailable-or-expired evidence, not proof that the ID once ran. A scalar floor
fences old identities without an expired-ID collection. New native session IDs
must increase monotonically; an existing reserved identity remains valid even
when newer receipts are retired. The ResourceRegistry already generates such
IDs. Direct hosts using numeric sessions must use fresh monotonic IDs and
acknowledge confirmed releases; calls without numeric sessions keep their
existing ownership contract and are subject to retained-resource backpressure.

After explicit `Command.cancel_confirmed/3` reconciliation verifies process
group release, LocalCommand's current `cleanup_status` is confirmed in both
session and owner queries and in any retained output record for the exact
session, owner, and incarnation. An in-progress retry reports pending before
older uncertain output metadata. The output cache retains its normal lifetime;
the command's original status, exit and termination information do not become
successful execution. A retained `cleanup_error` records the earlier failure,
not the current cleanup state. A host can then release a still-active
ResourceRegistry session through its existing cleanup callback and receipt
acknowledgement. A registry entry already marked failed or uncertain has no
public retry/reset operation: backend confirmation does not erase that registry
evidence, and the host must reconcile it separately before replacement.

## Continuing a Codex child agent

Collaboration preserves a stable agent identity while completed or interrupted
work uses a fresh run ID. A replacement receives canonical committed messages,
including tool results, through the additive trusted `Conversation` `:messages`
option. It does not resubmit the original prompt. Remaining work and deadline
bounds carry forward, and replacement authority cannot exceed either the current
parent or the prior child authority. Exhausted agents cannot gain another quota
by closing, resuming, or following up.

Closed-run snapshots are tagged with their originating run and incarnation. A
successful replacement clears the cached snapshot; a failed replacement retains
it as recovery evidence. A later child therefore cannot reuse history or quota
from an older incarnation when the current execution has an uncertain outcome.

Close/resume and interrupt/send require settled execution. Restored nonterminal
runs remain inspection-only; uncertain mutations and unacknowledged storage need
host reconciliation. An interrupted provider-only response may be explicitly
discarded after confirmed cleanup; this admits new input without replaying that
response or its original prompt. The collaboration manager's identity/history coordination
is process-local and is not a new durable session implementation.

Resource cleanup callbacks confirm release only with `:ok`, legacy `:done`, or
`{:ok, :confirmed | :released | :done}`. Explicit errors and exceptions retain
failed records. Uncertain, unexpected, pending/requested replies and callback
timeouts retain uncertain records. Hosts using arbitrary callback return values
must migrate to an explicit confirmation after checking the resource. Repeated
release requests join existing cleanup or return retained evidence; they do not
blindly retry callbacks. Confirmed-release receipts have bounded retention.

Upgrade hosts by settling/reconciling existing runs and restarting the affected
Conversation, ResourceRegistry, MultiAgent and LocalCommand supervision trees;
these changed in-memory states do not provide a hot-upgrade migration. Existing
non-Codex consumers need no new profile or command callback. Real Deno process
termination is verified on Linux using the captured process identity; other
platforms do not acquire a confirmed-cleanup guarantee from these tests.


## Long-running interactive turns

Opt in with `run_timeout: :infinity`. This persists `deadline: :infinity`,
omits the root timer and preserves disabled mode through human waits and safe
child continuations. Omitted options retain the finite defaults. The finite
maximum is 3,600,000 ms; effect, commit and cleanup limits remain finite.
Explicit cancellation still fences the run and reconciles uncertain effects.
An approval bound to an infinite run has explicit infinite expiry; its operation
identity, argument digest, tool revision and trusted resolver checks still apply.

`provider_idle_timeout: 300_000` optionally replaces the provider's total effect
limit with a finite wait for its next accepted normalized event. Accepted progress
refreshes the generation-fenced timer. Tools, hooks, store commits and cleanup
retain their own total limits, and a finite root deadline still wins. Human
interaction pauses the provider wait and resumes its remaining time.

```elixir
Conversation.start_link(
  # Other host-owned provider/store/catalog options are required.
  run_id: "interactive-run",
  run_timeout: :infinity,
  provider_idle_timeout: 300_000,
  effect_timeout: 30_000,
  commit_timeout: 5_000,
  cleanup_timeout: 5_000
)
```

The host transport owns raw SSE observation. A normalized enumerable cannot see
SSE comments or events its adapter discards; enabling this option establishes
idle semantics at the normalized runtime boundary.

Finite child continuations preserve the prior absolute deadline. The internal
`inherited_deadline` option carries that value between trusted runtime owners;
it is not a model argument or a consumer option for extending a deadline.

## Persistent thread Goals

The host opts into `Backplane.AgentRuntime.Goal` independently of any Codex
profile. One host thread owner starts it with durable `Goal.Store` and
`Goal.Host` adapters. A missing adapter or an invalid initial record refuses
startup. The package supplies no production database or thread scheduler.

```elixir
alias Backplane.AgentRuntime.{Conversation, Goal}
alias Backplane.AgentRuntime.Codex.Session

# Execute in the host's existing thread owner; adapter modules/contexts and
# runtime_options are supplied by the embedding.
{:ok, goal} = Goal.start_link(
  thread_id: thread_id,
  owner_pid: self(),
  store: MyGoalStore,
  store_context: goal_store_context,
  host: MyGoalHost,
  host_context: thread_context
)

# Record an explicit user instruction, then durably create the Goal.
{:ok, _} = Goal.set(goal, %{objective: "Finish the requested migration"},
  %{text: "Keep working until the migration is finished"})

# Reuse the host's ordinary Session, grants and fresh run identity.
{:ok, session_binding} = Session.bind(session, authority)
{:ok, goal_binding} = Goal.bind(goal, %{
  thread_id: thread_id,
  run_id: authority.run_id,
  incarnation: 1,
  authority: authority,
  usage_authoritative: true,
  mode: :execution
})

{:ok, conversation} = Conversation.start_link(Keyword.merge(runtime_options,
  run_id: authority.run_id,
  authority: authority,
  thread_id: thread_id,
  session_binding: session_binding,
  goal: goal,
  goal_binding: goal_binding
))
{:ok, _} = Conversation.prompt(conversation, user_message)
```

`runtime_options` still supplies the ordinary provider, run Store, catalog and
resource options. Use a supervisor in the real host. Omit `token_budget` unless
the user requested one. A budgeted Goal requires authoritative normalized
input/cached/output usage at binding and automatic admission; missing values
remain unknown and suspend budgeted automatic continuation. Trusted binding
`mode: :plan` excludes Goal token/time charges and lifecycle failure audits.
Delegated bindings inherit that mode and authorize root usage only; child Goal
tools require a separate owner for the child thread. Bindings and authority are ephemeral
host capabilities and never model input.

To expose the existing `create_goal`, `get_goal` and `update_goal` tools, start
`Codex.ExtensionRuntime` with `goal: goal` and its required host/caller/run/project
scope, then select `:extensions` (or the configured extension family) through
`Codex.profile/4`. Preserve the returned registry/tools/authority bundle. A
Conversation with Goal tools also needs the same `goal` and `goal_binding` so
provider usage and tool settlement are acknowledged before subsequent work.
Without a supplied Goal owner, the extension reference backend remains ephemeral.

`Goal.Host.record_user_instruction/3` records canonical provenance before a
host `set/3` or `clear/2` mutation. Failure leaves the Goal unchanged.
`start_turn_if_idle/3` atomically reserves ordinary host admission and returns
`{:ok, {:started, %{run_id: run_id, incarnation: incarnation, turn_id: turn_id}}}`
or `{:ok, {:not_submitted, reason}}`. It validates `request.host_generation`,
Session readiness, queued user input and pending interactions. This callback
must return promptly, must not dispatch providers, and must not synchronously
reenter Goal. Schedule the accepted turn through the existing owner after the
callback returns; bind fresh Session/Goal capabilities and pass
`goal_trigger: :goal`. Host generation must change when user input or
cancellation invalidates a reservation.

After ordinary run settlement, receipt reconciliation and Session readiness,
the owner calls `Goal.idle(goal, current_host_generation)`. There is no polling
loop. Busy, deferred, already-reserved or uncertain-accounting states return
`not_submitted`. Interruption persists a continuation deferral; restoring an
active status does not itself launch work. Explicit host resume uses
`Goal.set(goal, %{status: :active}, user_instruction)` after reconciliation.
Model tools can complete, pause or block; they cannot resume, change budgets,
clear, or replace an unfinished Goal.

Charge is `max(0, input_tokens - cached_tokens) + output_tokens`; reasoning is
already included in output. Cumulative reports debit acknowledged deltas once,
including terminal repeats and descendant reports. A fresh Goal starts from
current usage rather than charging earlier work. Budget exhaustion persists
`budget_limited`, emits one wrap-up steering item and lets the current turn
settle. It does not assert the objective was achieved. Elapsed seconds report
active Goal time, including active idle intervals, and do not create a deadline.
Plan entry/exit resets the local clock; restore starts a fresh clock without
charging process downtime.
