# Child interactions and durable host feedback

Status: approved by the user on 2026-10-23; implementation authorized on main.

Repository: `gsmlg-opt/backplane`, `main` at
`8e11bf07933e091e10924dfac6be040614682ca5`.

Requests: [#81](https://github.com/gsmlg-opt/backplane/issues/81) and
[#82](https://github.com/gsmlg-opt/backplane/issues/82).
Target release: `1.10.33`.

## Problem and scope

Managed child Conversations can suspend for an interaction, but MultiAgent drops
their interaction events and exposes no public resolution boundary. Preparation
and backend workers also lack a way to commit host feedback to Conversation
history before allowing an effect to continue.

Extend the existing manager observation stream and Conversation checkpoints.
Keep stable child identities, current resource ownership, Store compare-and-set
and incarnation checks, bounded workers, and inspection-only restoration. No
auxiliary child registry, context journal, Store interface, database migration,
automatic effect replay, or extra provider turn is needed.

## Alternatives

| Approach | Benefit | Limitation |
| --- | --- | --- |
| Token-bound feedback callback and existing checkpoints, plus the existing manager observer | Covers preparation and backend workers; acknowledges the canonical commit; preserves existing owners | Requires careful queued-checkpoint merging and producer fencing |
| Extend preparation return values | Small preparation API | Cannot acknowledge persistence inside the hook and does not cover backend feedback |
| Separate feedback service and child registry | Independent storage and lookup | Duplicates canonical history, lifecycle ownership, and recovery semantics |

The first approach is recommended.

## #81: public managed-child interactions

Add `pending_interaction` to the complete public child record. It is either `nil`
or a JSON-safe interaction record with the interaction ID, request, and exact
correlation. A waiting child's lifecycle status remains `:running`.

Publish `:interaction_requested` and `:interaction_resolved` through the existing
revisioned `{:codex_collaboration, event}` stream. Keep the normal `manager_id`,
revision and complete agent record. Include `interaction_id` on both event types,
including the resolved event after the child's pending field has been cleared.
Correlation contains:

```elixir
%{
  manager_id: manager_id,
  agent_id: stable_child_id,
  run_id: current_run_id,
  incarnation: current_incarnation,
  interaction_id: interaction_id
}
```

Add `MultiAgent.resolve_interaction(manager, correlation, value)`. The manager
validates the complete identity and current actionable interaction, reserves it
against duplicate submissions, and delegates asynchronously to the pinned child
through `Conversation.resolve/3`. Waiting for a child's Store must not block
manager snapshots, cancellation, or unrelated children. A success response means
the child acknowledged its resolution checkpoint.

Malformed input is a validation error. An unknown child is not found. Wrong
manager/run/incarnation, a closed session or child, no matching pending
interaction, and duplicate submissions are conflicts. Child persistence errors
are returned without claiming resolution. Lost child/worker acknowledgement is
an unknown outcome and must not trigger automatic retry. Recheck the full
identity at completion; neither a delayed acknowledgement nor an old observer
event may clear a newer pending interaction.

The current atomic `subscribe/2` snapshot is the recovery boundary. It returns
all current pending interactions with its revision watermark, followed by later
events. Hosts need no private child PID. Manager restart creates a new stream;
this does not introduce durable manager restoration.

Interrupt, close, session close, replacement, child exit and storage failure
clear actionable pending state and reject waiting resolution callers. Cancellation
does not emit `interaction_resolved`. Conversation must reject resolution in
terminal, cancelling, storage-failed and recovery-required phases, and recheck
the live interaction after a held resolution checkpoint before waking its worker.

Cancellation settlement uses temporary workers under the manager's existing child
supervisor. Interrupt, interrupting input, child close and session close fence
actionable interactions immediately; waiting for cancellation and terminal Store
snapshots happens outside the manager. Workers return cancellation and snapshot
evidence pinned to the manager, child, run, incarnation and PID. The manager alone
validates evidence, applies existing lifecycle reducers and publishes revisions.
Transient evidence is removed in the same callback, including after replacement.

Overlapping lifecycle requests queue by affected child identity; unrelated children
remain available. A queued close fences replacement immediately. Child-close
workers preserve the existing stop-on-first-failure traversal; session close still
attempts every child. Lost workers, timeouts, stale identities and missing evidence
retain uncertainty and capacity reservations. Physical termination remains in the
manager after accepted terminal evidence; this does not promise arbitrary process
shutdown is instantaneous.

Interaction requests exposed publicly must be JSON encodable. Preserve existing
atom-key/atom-enum requests by normalizing their public representation to JSON
strings; reject opaque handles, functions, references, tuples, invalid text and
ambiguous normalized map keys before accepting the interaction. Public events and
snapshots must contain no private process references.

## #82: feedback capability and canonical history

Preparation and tool backend contexts receive a Runtime-owned callback:

```elixir
context.append_feedback.(%{
  id: "host-stable-feedback-id",
  text: "Additional context",
  source: "sigma-hooks",
  stage: "PreToolUse"
})
# => {:ok, receipt} | {:error, %Backplane.AgentRuntime.Error{}}
```

All four fields are required nonempty UTF-8 strings. Bound `id`, `source` and
`stage` to 256 bytes each and `text` to 64 KiB. Accept documented atom or string
field names, reject ambiguous duplicates and unsupported fields, and do not
accept caller-supplied authority or invocation identities. The callback is
available to direct and nested preparation/backend workers, not provider or
unrelated lifecycle hooks. The direct backend's explicit context allowlist must
include it.

The callback is bound to the live producer token and immutable invocation
identity. Runtime stamps run, incarnation, turn, step, attempt, invocation,
tool-call, tool name, tool revision and catalog revision. Nested records also
identify the enclosing invocation. No token, closure, PID or private handle is
persisted.

Invocation identity is assigned before preparation. Preparation rewrites and
approval `update_input` can change argument bytes while preserving that identity.
Feedback therefore refers to the invocation attempt, with final arguments
available in its eventual committed `tool_invoked` record. The receipt does not
attest to argument bytes that may still be edited.

Keep an ordered, JSON-safe `conversation.host_feedback` collection, uniquely
keyed by the host feedback ID. Each record stores content, provenance,
Runtime-stamped correlation, accepted revision, Store mode, and projection state.
Expose it through existing Conversation status and Store snapshots. Missing
collections in older histories default to empty.

## Admission, persistence and cancellation

1. Validate payload and the live producer at receipt.
2. Enqueue actor-owned work; validate the producer and enclosing nested owner
   again when processing it.
3. Check the canonical feedback ID. An exact repeat from the same invocation
   returns its original receipt. Different content, provenance or invocation
   under that ID is a conflict. Stale producers fail before deduplication.
4. Commit through the existing `:conversation_updated` Store boundary.
5. Recheck liveness after Store acknowledgement, then acknowledge the callback.

The receipt includes feedback ID, stamped correlation, committed revision and
`store_mode: :durable | :ephemeral`. Only a durable adapter establishes durability;
an ephemeral receipt must remain explicit so a host can fail closed if it needs
durable acceptance. No successful receipt is returned before the Store confirms
the checkpoint.

Cancellation rejects queued and pending feedback callers and fences continuation.
If cancellation wins while Store work is blocked, no late acknowledgement may
release preparation or backend dispatch. A record that the Store nevertheless
committed remains evidence; cancellation cannot retract a committed write.
Failed or ambiguous commits use existing storage-failure/recovery handling and
produce no successful feedback receipt.

Acknowledged feedback is retained if preparation later denies, returns invalid
input, or approval refuses execution. It remains feedback about a non-dispatched
attempt. Backend feedback likewise does not prove successful tool completion.

## Provider continuation and replay

At the next existing provider boundary, project every accepted, unprojected
feedback record exactly once into canonical messages and checkpoint that
projection before constructing the provider request. Append after the complete
assistant-tool-call/tool-result batch, preserving provider protocol ordering.

Use the normal user-level transport role with an explicit host-feedback marker
in content and a `host_feedback` metadata field containing provenance and
correlation. Document this adapter encoding. The canonical source is the
host-feedback record, not a human prompt, steering call or collaboration message;
feedback grants no system authority. Later requests naturally include the
existing canonical message without inserting it again.

The append callback never starts a turn. If the current turn ends before another
provider request, projection waits for the next naturally admitted continuation.

Keep the deduplication ledger across context resets. Provide a documented
`host_feedback` history seed alongside `messages`, carry it during managed-child
replacement, and recognize already-projected feedback in supplied canonical
messages. Reusing a feedback ID in a later invocation must not add a second
message. Preserve the record's original identity when carrying history into a
new run. A restored `:run` remains inspection-only and never recreates workers or
replays feedback effects.

Queued checkpoints and provider/tool completions must merge feedback by ID with
monotonic projection state. Continuations must use the actual committed/rebased
Conversation, rather than overwrite it with a captured pre-commit snapshot.

## Implementation ownership

- The #81 worker owns `codex/multi_agent.ex`, dedicated child-interaction tests,
  and manager observation documentation. It carries the feedback history seed
  during replacement under the agreed Conversation contract.
- The #82 worker owns `conversation.ex`, `conversation_adapter.ex`, feedback
  validation/projection helpers if necessary, feedback tests and hook docs. It
  also owns the shared resolution phase/liveness guard and JSON-safe interaction
  admission required by #81.
- The coordinating agent owns this design, integration, release checks and any
  narrowly necessary pre-existing CI repair. Workers preserve others' changes;
  all local Mix/Devenv builds and tests are serialized.

## Acceptance and release evidence

- Exercise preparation and backend interactions through the public manager:
  correlated request/resolved events, atomic resubscription snapshots, exact
  identity checks, concurrent/completed duplicate answers, cancellation, close,
  replacement, storage failure, event/ack ordering, and responsiveness with held
  child checkpoints.
- Exercise feedback in direct/nested preparation and backends, custom inputs,
  preparation/approval rewrites, denied/invalid preparation, exact/conflicting
  IDs, subsequent turns, context reset, and replacement/history replay.
- Hold Store checkpoints to prove no early feedback acknowledgement or dependent
  dispatch. Cover cancellation while committing, commit failure, lost
  acknowledgement, stale callbacks, nested owner completion, and concurrent
  checkpoint/result merging.
- Inspect actual next-provider messages: each accepted record is inserted once,
  after all tool results, with explicit provenance and no extra provider call.
- Verify canonical snapshots contain no executable/private values. Use the
  existing Store conformance boundary for durable-adapter evidence and prove
  restored runs remain inspection-only; distinguish fake-Store tests from real
  durability verification.
- Run focused tests first, the owning runtime suite with real Deno, compilation,
  formatting, strict Credo, Dialyzer and workflow contracts. Existing main CI has
  Plugins GitTest and Dialyzer failures; diagnose them and make only necessary
  release-gate repairs, without weakening checks or adding broad ignores.
- Freeze one source SHA, publish `1.10.33` using the current release workflow,
  and independently verify terminal jobs, tags/refs, archives/checksums/packaged
  provenance, Hex/HexDocs, a fresh consumer and GHCR. Record any recovery path
  honestly. Preserve unrelated dirty work. Deployment and downstream dependency
  changes are outside this task.
