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
The finite effect and root deadlines include waiting time. Cancellation closes
pending interaction ownership. MCP form rendering and answer validation remain
in the Sigma tool/interaction adapter.

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
production durable adapter, full Sigma migration, or collaboration implementation
is implied by local artifact tests. Incremental subscriber events are transient;
Sigma retains its ProtocolSubscription backpressure, cursor and replay policies.
