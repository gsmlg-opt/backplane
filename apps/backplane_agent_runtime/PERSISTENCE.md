# Agent runtime persistence adapter

`backplane_agent_runtime` includes an ephemeral ETS store and a durable store
contract. It does not include a database, journal format, or production durable
store. A host keeps ownership of its persistence technology and implements
`Backplane.AgentRuntime.Store` around it.

## Durable contract

A durable adapter declares all capabilities required by
`Store.validate_durable_capabilities/1`, including `incarnation_fencing`.
Its acknowledgement boundary has these properties:

1. `store/3` is the direct commit path used by `Execution` and
   `Conversation`; `acknowledge_commit/3` provides the equivalent operation for
   a host that stages first. Both compare the aggregate revision and atomically
   write the run, transition events, effect records, and outbox intents. They
   return only after the backend's documented durable boundary. Implementing
   only the staged callback is not sufficient. A failed or uncertain commit
   returns an error and no dependent effect may start.
2. `load/3` reconstructs `%{run:, revision:, transition:, effects:, outbox:,
   incarnation:}`. Runtime maps use atom keys even if the backend uses another
   encoding at rest.
3. `fence/5` atomically compares both the expected revision and current
   incarnation, then advances the revision and incarnation. Recovery must fence
   before dispatching or resolving work. Old callbacks remain stale after the
   fence.
4. A successful terminal snapshot retains the outcome, finite budget state,
   settled execution intents, and no outstanding provider/tool/wait ownership.
   An unknown-outcome terminal intentionally retains unresolved identities as
   evidence for host reconciliation.
5. Dispatched or unknown mutations remain uncertain across restart. Recovery
   does not infer success and does not execute them again. Only recorded
   read-only or idempotent work with `:not_dispatched` evidence is eligible for
   automatic resume.

`EphemeralStore` deliberately provides different guarantees: its context is an
ETS table, a restart loses records, and it does not declare durable capabilities
or implement incarnation fencing.

## Reusable conformance run

Run the package harness from the host adapter's integration tests against the
real persistence backend:

```elixir
assert {:ok, %{mode: :durable, checks: checks}} =
         Backplane.AgentRuntime.StoreConformance.run(MyRuntimeStore, context,
           run_id: "conformance-#{unique_id()}",
           restart: &MyRuntimeStoreTest.restart/1,
           fail_next_commit: &MyRuntimeStoreTest.fail_next_commit/1,
           dependent_effect_count: &MyRuntimeStoreTest.dependent_effect_count/2
         )

assert :terminal_reconstruction in checks
```

The three callbacks are test controls owned by the consumer, not production
`Store` callbacks. `restart` reconnects to the same durable namespace.
`fail_next_commit` injects a failure before acknowledgement.
`dependent_effect_count` lets the harness prove that the host did not launch an
effect for the rejected run.

The harness checks the direct execution commit and staged acknowledgement
paths, atomic snapshots/outbox records, failed direct commits, stale revisions,
atomic incarnation fences, restart reconstruction, terminal outcome and budget
reconstruction, and conservative handling of uncertain mutations.
Passing a fake only proves package handling. A durability claim requires the
same run against the real adapter plus a description of its flush, transaction,
and power-loss boundary.

## Sigma adapter boundary

Current Sigma source keeps session history in `Sigma.Session.Writer` and
`Sigma.Session.Log`. The writer serializes appends, advances its active leaf only
after `Sigma.Session.Storage.append/2` succeeds, rebuilds the leaf with
`Log.snapshot/3`, and checks the expected leaf when retrying. Fork publication
uses a temporary journal and a create-only hard link. These are useful adapter
inputs and remain Sigma-owned.

The current JSONL storage callback is append/read oriented. It does not expose
an atomic compare-and-set transaction that writes a runtime transition and
outbox together, an incarnation fence, or a documented flush/power-loss
acknowledgement. Therefore it must not declare `:durable` merely by wrapping
`Sigma.Session.Writer`. Sigma still needs a runtime-record adapter or reviewed
sidecar that supplies those operations and runs `StoreConformance` against the
actual storage. Existing JSONL replay, retry, fork, Protocol V1, sessions,
repositories, and UI stay owned by Sigma.

On restart, the adapter should load the runtime snapshot, atomically call the
equivalent of `Store.fence/6`, reconstruct the budget and outstanding effects,
and pass unresolved effect evidence to `Recovery.recover/2`. It should publish
runtime terminal/history projections into Sigma only after the runtime commit;
it must not regenerate a mutation from conversational JSONL alone.

## Codex resource reconciliation

Run-owned OS commands and Deno cells are cleaned when the run ends, independently
of Conversation PID lifetime. Cleanup initiation and Task termination are not
confirmation of an external outcome. Registry callback failures, exceptions,
timeouts and uncertain backend acknowledgements retain process-local evidence;
uncertain run settlement uses the existing `unknown_outcome` boundary. Storage
failure still requires loading/reconciling the store, including when a commit
succeeded but its acknowledgement was lost.

Resource registries and collaboration managers remain ephemeral. Hosts needing
restart reconciliation must retain serializable resource/run identities and
backend-specific evidence in their own recovery system. Never serialize registry
values, PIDs, ports, cleanup functions, dispatch closures, credentials or grants.

`Codex.MultiAgent.cancel_interaction/3` uses the observed five-field interaction
correlation and shares an atomic manager reservation with resolution. Child
acceptance checks the run, incarnation, interaction and live producer. Its `:ok`
acknowledges terminal checkpoint persistence, pending interaction removal and
reconciled cleanup/effects, rather than merely delivery of a cancellation request.
An already dispatched backend can retain an `:unknown_outcome` execution intent
and continue to reserve capacity.

Worker loss, Store acknowledgement loss or timeout leaves cancellation uncertain,
even when a terminal checkpoint may already exist. Reconcile observer snapshots
with the host Store; a generic `run_cancelled` event is not an exact cancellation
receipt. Do not retry automatically or fall back to interruption by agent name,
which could target a replacement run. The supplied reason is diagnostic text in
the `:interrupted` observer event, with no guarantee of persisted reason history.
An `EphemeralStore` acknowledgement supplies only its local ETS guarantee;
durability still depends on the host adapter's documented boundary.

LocalCommand separates active/output records, unresolved session obligations,
and recent confirmed-release receipts. An obligation's confirmed evidence stays
pinned until the ResourceRegistry consumes it; only then may it enter the bounded
receipt cache. Receipt acknowledgement runs as a supervised, bounded effect after
registry settlement. A failed acknowledgement retains the backend obligation and
can cause admission backpressure; it does not undo already confirmed OS cleanup.
Missing or evicted receipts never prove successful release and must not cause
blind cleanup retries. Hosts must reconcile unresolved identities explicitly.
Owner-wide cancellation fences existing never-launched reservations in the
backend before acknowledgement; a consumed or evicted receipt cannot make an
old launch identity valid again. A verified LocalCommand reconciliation updates
current cleanup status in retained output for the exact session, owner, and
incarnation without shortening the output cache lifetime or changing the
command's execution outcome. The earlier `cleanup_error` remains historical
diagnostic evidence. A still-active ResourceRegistry session can release through
its existing callback after host backend reconciliation; an already failed or
uncertain registry entry has no public retry/reset and remains unresolved.

Conversation timer generations and catalog callback tokens are ephemeral fences,
not persistent execution contexts. A failed nested producer loses staging before
settlement acknowledgement, while a successful producer becomes eligible only
after that acknowledgement. A lost Store reply still requires loading and
reconciling the store; neither staging nor receipt eviction permits replay.
An already-dispatched mutating direct or nested tool with an untrustworthy
outcome retains its committed active invocation and execution intent under the
existing `unknown_outcome` boundary. Outer error handling, Task cleanup and
late results do not consume that evidence. This adds no persistence fields or
Store callbacks; the admitted catalog used for classification is process-local.
After acknowledgement loss, the host must inspect the stored run before any
continuation or replacement.
The current R22 implementation still fails command lifecycle regressions for
trusted confirmed non-start refusals; see the follow-up validation record. Do
not treat the new classification as a fully validated host upgrade boundary.

A replacement child run uses a fresh storage aggregate and committed history;
it never automatically replays a restored nonterminal run or a completed tool
mutation. The old run's revision history remains distinct from the replacement.


## Explicit disabled deadlines

The durable run deadline is `integer() | :infinity | nil`. Only `:infinity`
disables the root deadline. `nil` keeps the legacy unset meaning and receives a
finite default on admission. A finite admitted record remains finite even when
new options request infinity. An explicit saved infinity remains infinite when
options are omitted.

JSON adapters encode the sentinel as `"infinity"` and decode it with an explicit
case into `:infinity`. Do not create atoms from stored strings. Effect, commit,
cleanup, work and native command bounds remain independently finite. Restoring
an unfinished infinite run still requires reconciliation and fencing before
admission; it never authorizes replay of its external effects.

## Goal records and accounting recovery

Conversation revokes its Goal binding in a supervised task before emitting the
terminal run notification. The acknowledgement is bounded by commit and cleanup
limits. Goal death or missing acknowledgement leaves a controlled
`storage_failed` recovery boundary; hosts must reconcile it before new admission,
even if the journal already contains a terminal run.

`Goal.Store` is a separate host-owned thread record contract:

```elixir
@callback load(term(), binary()) :: {:ok, map()} | {:error, Error.t()}
@callback compare_and_swap(term(), binary(), non_neg_integer(),
  binary() | nil, map()) :: {:ok, map()} | {:error, Error.t()}
```

For an absent thread, return the empty record from `Goal.State.new(thread_id,
[])`. CAS must compare both revision and current `goal_id` (nil for no Goal),
persist the entire next record atomically, advance revision exactly once and
return that committed record. A conflict returns `Error` class
`:resource_conflict`. Clearing retains a tombstone revision, so delete/recreate
cannot reuse an old receipt or mutation fence. Adapter acknowledgements must
represent their documented durable transaction/flush boundary.

Persist the full private snapshot, including receipt digests, event revisions,
cumulative usage baselines, mutation invocation responses, audit counters,
budget-steering delivery state and continuation deferral. The public
`Goal.get/1` response is insufficient for recovery. Never store PIDs, references,
functions, ports, authority capabilities or BEAM monotonic timestamps. Elapsed
whole seconds are persisted; a restored owner establishes a fresh local clock.
The file-backed test fixture proves package restart handling, not production
adapter durability.

Conversation checkpoints the Goal receipt outbox with the acknowledged
provider/tool/turn transition. Goal CAS records the receipt and response before
Conversation clears the outbox in another checkpoint. A lost reply may therefore
leave either an undelivered receipt or an already-applied receipt. Redeliver the
same receipt identity and payload; matching duplicates return the saved response,
while changed duplicates conflict. Recover accounting without replaying the
provider or external tool. Goal tool mutation and invocation response are also
stored together so a repeated committed invocation returns its original result.

After acknowledgement failure, load and fence/reconcile the ordinary run first.
`Goal.restore/1` reloads its record and invalidates live bindings/reservations;
it does not scan run journals or launch a continuation. The host reconstructs
fresh authorized bindings, then uses `GoalBridge.redeliver(goal, binding, run)`
for each retained committed outbox. Resolve changed Goal identity and uncertain
effects explicitly before fresh admission. Only after delivery and ordinary
Session readiness may the host signal `Goal.idle/2`. Restarting clears
process-local pending-receipt tracking, so persisted run outboxes remain the
host's recovery authority.

For a terminal run, persist receipt removal with the public Kernel command
through the existing direct Store commit or staged acknowledgement path:

```elixir
command =
  {:goal_outbox_acknowledged, System.system_time(:millisecond),
   %{
     run_id: run.run_id,
     incarnation: run.incarnation,
     receipts: exact_delivered_receipts
   }}

{:ok, staged} = Store.stage(MyRuntimeStore, context, run, %{command: command})
{:ok, _ack} = Store.acknowledge_commit(MyRuntimeStore, context, staged.stage, %{})
```

This command accepts only `:completed`, `:failed`, `:cancelled`, `:timed_out`
and `:unknown_outcome` runs. Supply a nonempty, duplicate-free list of complete
receipt maps with nonempty receipt IDs. Each must exactly match one uniquely
retained entry in `run.context.conversation.goal_outbox`, including its payload.
Partial maps, changed or unknown receipts, and ambiguous retained IDs are
rejected. The command uses the current run/incarnation fence; a matching retained
receipt may originate in an older incarnation. Keep its original contents.

The host establishes delivery before ACKing the exact successfully delivered
subset. The command removes only that subset and preserves remaining order,
context, terminal outcome, budgets, tool results and completed or unresolved
effect evidence. It advances the revision, emits
`run.goal_outbox_acknowledged` and produces no effects. It accepts no replacement
conversation or context and does not reopen the terminal Conversation. No Store
callback is added; the adapter's existing transaction and revision CAS remain
the persistence boundary.

A definitively rejected ACK write leaves the saved outbox authoritative. A lost
ACK reply or uncertain write may follow a successful commit: reload and reconcile
the outbox before deciding what remains. An already removed receipt is rejected
as a new ACK. If delivery must be repeated, redeliver the same original receipt
through Goal's existing duplicate accounting; never replay the provider or tool.

Descendant bindings capture root thread and Goal identity at admission. Their
capabilities authorize root usage accounting only; they cannot read or mutate
the root Goal through its tools. Child threads that need their own Goal tools
must receive their own host-owned Goal. Plan mode is inherited at delegation,
and its lifecycle does not change root Goal status or failure audits.
Their reports debit that root once, including while the root run is idle; completing
a child never adds its aggregate usage a second time. Replacing or clearing the
root fences old descendant receipts from the new Goal. `fork_snapshot/2` copies
the Goal snapshot into an empty target thread, retaining its Goal identity,
status, budget, totals and timestamps. Run receipts, live bindings, reservations
and continuation ownership are fresh in the target.
