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
