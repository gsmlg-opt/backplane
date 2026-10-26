# Cold recovery verification

Date: 2026-10-27. Source checkout: `main`, baseline
`d153846a8d2a9ce9d5aabbb818f53e553edbb20d`, with the uncommitted #117/#119
implementation. This verifies the local fixture, not a released package or a
production host adapter. The approved contract is
[archived child reconciliation](../specs/2026-10-27-archived-child-reconciliation-design.md).

## Persistence and custody boundary

`ReconciliationFileHostFixture` implements the public Store and reconciliation
adapter callbacks. One GenServer serializes run transitions, incarnation fences,
immutable evidence and receipt CAS. Accepted mutations write a complete temporary
snapshot, sync its file contents, close it and atomically rename it over the
previous snapshot before returning. A refusal leaves the previous snapshot intact;
a simulated lost acknowledgement occurs after the rename. Transition journal and
outbox data share that snapshot.

This is a trusted-local file backend. Its Erlang terms must only come from the
fixture's own directory. The runner creates a unique directory and owns exclusive
custody: it waits for the producer to exit and verifies the OS process is gone
before starting the consumer. It also compares each BEAM's reported `System.pid()`
with the subprocess PID. The outer shared build lock serializes BEAM commands.
There is no multiwriter lease protocol or interprocess CAS guarantee beyond this
runner-enforced custody. File sync plus rename is not a power-loss durability
proof: directory sync, machine failure, filesystem crash and distributed failover
are outside this fixture.

## Exercised behavior

The producer starts a real MultiAgent child and managed Session, runs the fixture
Provider through Conversation, completes the child, and closes it through the
public child tool. It monitors the actual Provider worker and named Conversation
executor and requires their exit. A real registered component process is stopped
and monitored by its cleanup callback. Public Session status confirms permanent
closure and successful cleanup. Closure is distinct from Session PID termination.

The source inventory retains the original active Provider identity even after
completion clears active cleanup fields. It merges that inventory with terminal
run requirements and the Registry's sealed resource inventory. The child manifest
must contain Provider, executor, Session and registry-resource obligations. These
facts and the original terminal record are retained in the file store. The host
creates a retirement receipt and archive, then commits a manager receipt without
projecting it before producer shutdown. The consumer reloads that exact committed
receipt, demonstrating persistence across the unprojected boundary.

The fresh consumer manager imports the archive twice with an identical restore
receipt and no admissions, preparation, binding, Provider call or cleanup. Marker
counts remain byte-for-byte equivalent as maps. Explicit followup then preserves
the logical child ID and committed history, but creates a new attempt, a higher
incarnation, a new managed binding and a destination-manager-qualified run ID.
Both source and destination use sequence 1. Final markers contain exactly one
new preparation, Provider call and cleanup; original markers remain unchanged.
The original completed Store record remains identical after reconciliation,
import and followup.

Separate low-level Kernel/Store cases exercise usage and finish writes with both
definite refusal and committed-but-lost acknowledgements. The consumer reloads
exact producer records, advances their fence, and rejects stale-revision and
old-incarnation CAS attempts. Nonterminal cases additionally reject stale
transition writes. Completed runs use a valid fence probe: cancelling a completed
run would fail Kernel validation before reaching Store CAS. Remaining nonterminal
runs settle through existing public Kernel commands before receipt confirmation.

The unknown-root fixture is also a low-level Kernel/Store setup, **not a complete
Conversation aggregate**. It records an exact simulated Provider attempt, observes
its actual process exit, and uses the producer BEAM's verified exit for its local
executor. Lifetime reconciliation, including receipt lost-ACK recovery, leaves
the deterministic serialization of the whole original Store record unchanged.
That record includes terminal `unknown_outcome`, journal, context and the fixture
Goal usage/outbox envelope. Adding unobserved tool, child, dependency,
host-component or acknowledgement obligations remains unconfirmed. This does not
prove real GoalBridge notifications or end-to-end root Conversation closure;
those require the separate aggregate tests.

The focused durable ExUnit file also verifies immutable evidence, atomic
journal/outbox persistence across adapter restart, run fencing, receipt refusal,
lost receipt ACK, latest exact retry, progress CAS and stale/changed requests.

## Commands and evidence

All commands ran from `/home/gao/Workspace/gsmlg-opt/backplane` with
`flock /tmp/backplane-ir43-beam.lock devenv shell --no-tui --` as the prefix.
The two Python runners set `MIX_ENV=test`, `ERL_FLAGS='+S 4:4'`, and the available
Deno directory `/tmp/backplane-deno-2.8.3-shvogz4s` on PATH. The runtime-check runner
executes Mix from `apps/backplane_agent_runtime`.

Evidence base: `/tmp/backplane-1.10.43-internal-EYMX5h`.

| Check | Command after the prefix | Result / evidence |
| --- | --- | --- |
| Focused durable Store tests | `python3 /tmp/backplane-1.10.43-internal-EYMX5h/run-runtime-check.py cold-astra-round1-durable test test/backplane/agent_runtime/codex/reconciliation_durable_test.exs --seed 0 --max-cases 1` | Passed: 3 tests, 0 failures; `cold-astra-round1-durable.log` and `cold-astra-round1-durable-result.json` |
| Independent BEAM producer and consumer | `python3 apps/backplane_agent_runtime/test/fixtures/run_reconciliation_cold.py /tmp/backplane-1.10.43-internal-EYMX5h/cold-astra-round1` | Passed: producer PID 129454 and consumer PID 129597, both exit 0, no timeout, OS exit and BEAM PID checks true; `cold-astra-round1/result.json`, `producer.log`, `consumer.log` |
| Scoped formatting application | `python3 /tmp/backplane-1.10.43-internal-EYMX5h/run-runtime-check.py cold-astra-format format test/fixtures/reconciliation_file_host.exs test/fixtures/reconciliation_cold_beam.exs test/backplane/agent_runtime/codex/reconciliation_durable_test.exs` | Passed; `cold-astra-format.log` and result JSON |
| Formatting verification | `python3 /tmp/backplane-1.10.43-internal-EYMX5h/run-runtime-check.py cold-astra-format-check format --check-formatted test/fixtures/reconciliation_file_host.exs test/fixtures/reconciliation_cold_beam.exs test/backplane/agent_runtime/codex/reconciliation_durable_test.exs` | Passed; `cold-astra-format-check.log` and result JSON |
| Strict Credo with owned file filters | `python3 /tmp/backplane-1.10.43-internal-EYMX5h/run-runtime-check.py cold-astra-quality credo --strict --files-included test/fixtures/reconciliation_file_host.exs,test/fixtures/reconciliation_cold_beam.exs,test/backplane/agent_runtime/codex/reconciliation_durable_test.exs` | Passed, no reported issues; `cold-astra-quality.log` and result JSON |

Python runner syntax parsing with `ast.parse` and `git diff --check` also passed.

The cold Store snapshot is retained at
`cold-astra-round1/host-1793048137886443686/host.term`; its adjacent `markers` file
and the runner JSON identify the observed execution counts. These absolute paths
are ephemeral local evidence, not repository artifacts.

Full runtime/regression suites, warnings-as-errors compilation, package builds,
release publication and downstream production-store acceptance are owned by the
coordinator and are not established by these scoped checks. The cold runner's
failure-time shutdown branch was inspected but not fault-injected in this run.
