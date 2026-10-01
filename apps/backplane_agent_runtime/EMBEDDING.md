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
- Optional `hooks` implementing `prompt/2` and `stop/2`.
- Optional `subscriber` PID receiving `{:agent_runtime, run_id, event}`.
- Finite `work` quota (default 100), `run_timeout` (300,000 ms), `effect_timeout`
  (30,000 ms), `commit_timeout` (5,000 ms), and `cleanup_timeout` (5,000 ms).
  Work counts provider attempts and tool invocations; it is not a token or billing
  quota. Provider usage is retained separately without inventing missing values.

`prompt/2` admits the initial user input. During execution, it queues a follow-up,
matching Sigma's default. `steer/2` queues steering. `follow_up/2` queues a new turn.
Calls acknowledge only after the corresponding checkpoint commits. Prompt hooks
may reject an initial prompt before its admission acknowledgement. Content can be
text or host content-block lists. Attachments and retry metadata can remain in
host content blocks/context; Sigma's command adapter owns their public shape.

One steering item is consumed after the provider response and complete sequential
tool batch, or after a response without tools, before the stop hook. Follow-ups
start after the current turn outcome is committed. One root run shares its finite
budget/deadline across these turns. A completed root rejects further prompts;
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
This R22 repair is not yet a validated host contract: the current full Linux
runtime suite fails three command lifecycle tests. Two trusted confirmed
non-start refusals are incorrectly treated as uncertain, and an older ambiguous
launch test still expects provider continuation. See the follow-up section in
[runtime-repairs-validation.md](../../docs/agent-runtime/codex-tools/runtime-repairs-validation.md)
before upgrading.

For descriptors with `requires_approval: true`, the runtime asks for an exact
operation approval before invocation; only `:approved` allows dispatch. It binds
the decision to run, tool revision and argument digest and still uses the existing
Execution approval gate. All other values deny. This generic approval is not a
replacement for Sigma's `PermissionInterceptor`: its tool backend may delegate to
`Sigma.Coding.Dispatcher.dispatch/3` to retain permission → pre-tool hook → tool →
post-tool hook ordering and patched arguments. The original schema remains intact;
a host that patches arguments must validate the final arguments at its own boundary.

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
