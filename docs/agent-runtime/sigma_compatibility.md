# Sigma compatibility contract

Scope: package changes in Backplane only; Sigma remains read-only. This is an
adoption boundary, not a drop-in replacement or completed Sigma migration.

Source recheck: Backplane `19b0a57a7a6ea2ac918bd68d2bf08539d927f37d`, package
`0.10.0`; Sigma `143c8db27f5f3d32efc5dafffb2755dba1daa23b`. The latter matches
the starting assessment; Backplane HEAD is newer. Both checkouts were clean at
entry. Historical PRD/design/plan/baseline milestone claims are not current proof.

## Capability matrix

| Capability | Already supported at entry | Package change in this scope | Sigma adapter required | Remains Sigma-owned |
| --- | --- | --- | --- | --- |
| Effect execution | Kernel identities, explicit commands, store-before-dispatch, registry/grants/approval, finite work/deadlines | `Conversation` owns a complete provider/tool loop using the same kernel/gateway | Replace Agent loop with one runtime owner; map status/events | Repository/session lifecycle |
| Provider streaming | Eager Provider.start/chunks ports | Add lazy normalized stream adapter; incremental events; first-terminal fencing | Build ProviderRequest, call existing Provider.stream, map messages/results/context | HTTP/SSE parsers, credentials, model configuration, context policy |
| Prompt control | Explicit run commands | Persisted prompt/steering/follow-up queues; safe-boundary consumption | Map Sigma admission metadata; after cancellation/idle settlement start new bounded root with retained messages/queued input | Session operations, model changes, attachment/retry metadata |
| Tools and permissions | Registry, schema/grant/revision checks, exact approvals | Current built-in schemas; correlated local interaction waits; provider tool-call IDs retained | Backend delegates to Sigma Dispatcher/permission hooks and maps results; keep argument changes authorized/validated | Tool implementations, grants, MCP clients and elicitation UI |
| Hook ordering | Host execution backends | Optional prompt/stop hooks; synthetic stop continuation; tools retain backend hooks | Connect Sigma prompt/stop hooks and its permission → pre-tool → tool → post-tool path | Session hooks, hook discovery/configuration, compaction and nudges |
| Cancellation | Controller fencing and finite cleanup | Responsive cancellation during stream/tool/interaction; unknown external outcomes retained | Map cancellation/unknown-outcome to Sigma events; reconcile external tool resources | Session remains alive; host resources and orphan cleanup |
| Storage and recovery | Store stage/ack, EphemeralStore, conservative Recovery classification | Durable incarnation fence; direct/staged conformance; conversation snapshots; inspect-only restart | Real transactional runtime-record adapter or reviewed sidecar; pass conformance against real backend | JSONL history, Writer/Log, replay, retry checkpoints, fork publication |
| Public runtime | Standalone package, no server/database dependency | Packaged contracts/example; artifact consumers and release matrix support | Sigma Agent facade maps Conversation to existing event/status contracts | Runtime/PublicRuntime, Protocol V1, ProtocolSubscription, UI |
| Collaboration | Unsupported operations fail explicitly | No collaboration expansion | None in this scope | Future separately scoped collaboration adoption |

## Current Sigma seams inspected

- `apps/sigma_agent/lib/sigma_agent.ex`: a GenServer admits prompts and owns one
  task turn loop. Busy `prompt` defaults to follow-up; explicit steering consumes
  one item after a completed provider/tool batch. Stop hooks run after no-tool
  completion and steering handling. Failed/cancelled turns can advance queued
  follow-ups. Package root cancellation ends that bounded root; its host adapter
  starts the next root after settlement using the suspended queue.
- `apps/sigma_ai/lib/sigma_ai/provider.ex`, `provider_event.ex`: lazy normalized
  streams already expose text, thinking, tool arguments/completion, usage and
  terminal events. The facade owns the producer/demand/cancellation bridge.
- `apps/sigma_coding/lib/sigma_coding/dispatcher.ex` and permission/hook modules:
  permission and pre-tool hook preparation precede execution; post-tool hooks
  can alter output. The dispatcher also handles bounded batch scheduling. The
  new package driver runs tools sequentially. Sigma's batch parallelism is not
  claimed; its adapters can preserve per-tool permission/hook semantics through
  the existing dispatcher. Any requirement for identical parallel scheduling
  needs a separate batch adapter decision and tests during consumer integration.
- `apps/sigma_agent/lib/sigma_agent/{runtime,public_runtime,protocol_subscription}.ex`:
  repository/session supervision, direct Protocol V1 command mapping, bounded
  subscriber relay/cursors remain product concerns.
- `apps/sigma_session/lib/sigma_session/writer.ex` and Log/SessionFiles/storage:
  serialized JSONL acknowledgement and leaf-conflict checks help history
  operations but do not provide the runtime's atomic transition/outbox and
  incarnation-fencing contract. See the [storage contract](persistence_adapter.md).

## Public contracts and evidence limits

See the shipped [embedded adapter guide](../../apps/backplane_agent_runtime/EMBEDDING.md),
[executable example](../../apps/backplane_agent_runtime/examples/embedded.exs),
[schema subset](../../apps/backplane_agent_runtime/SCHEMAS.md), and
[persistence contract](../../apps/backplane_agent_runtime/PERSISTENCE.md).

The isolated conversation consumer uses deterministic provider/tool doubles and
runs against one extracted Hex artifact. The Sigma-source consumer loads the real
Sigma Provider facade/normalizers and all nine built-in schema functions, then
uses a thin adapter to drive a complete two-provider-step turn with a fake tool
backend. `Tool`, `PathUtils` and `Req` scaffolding only permits loading those
modules; it does not prove Sigma dispatcher, real tools, sessions or UI execution.
No paid/live provider is called. The disk-backed store fixture tests file reopen,
commit rejection and fencing; it does not certify production durability.

The existing empty-tool, bundled-basic and fake-backend consumers remain required.
The acceptance command uses `REQUIRE_SIGMA_SOURCE=1`; ordinary CI may omit the
optional external checkout and reports that omission.

## Remaining consumer work

Sigma must build the provider/message/event adapter, tool/permission/elicitation
adapter, prompt/stop hooks, session-owned run replacement and cancellation queue
handoff, and durable runtime-record storage. It must then test real Writer replay,
retry/fork, Protocol V1 ordering, UI subscriptions, tool cancellation/resource
cleanup, and context/compaction behavior before removing its duplicated loop.
Only that integration can establish migration parity.

No upstream dependency defect requiring an issue was found in this scope.
The public Hex package API and `backplane_agent_runtime-0.10.0.tar` returned HTTP
404 during this work. Local metadata still declares `0.10.0`, with changes under
Unreleased. The gated release workflow now includes this package; its credentials,
remote execution and actual publication have not been exercised. Nothing has been
committed, pushed, merged, published or deployed by this task.

## Final local verification — 2026-09-20

All checks below ran against the uncommitted package scope. Toolchain: Elixir
1.18.5 / OTP 28, ERTS 16.4.0.5. Sigma stayed clean at the SHA above.

From the Backplane repository root:

```sh
MIX_ENV=test REQUIRE_SIGMA_SOURCE=1 \
  SIGMA_SOURCE=/home/gao/Workspace/gsmlg-opt/sigma \
  bash scripts/verify_agent_runtime_package.sh
```

Exit 0. The script stages the package in a temporary directory, resolves its
**development-only** ExDoc dependency, and explicitly selects dev/test/prod
contexts so an inherited `MIX_ENV=test` cannot hide the documentation task.
It leaves package dependencies, locks, generated docs and artifacts out of the
checkout. It ran:

| Gate | Result |
| --- | --- |
| `mix format --check-formatted` | Passed |
| `mix compile --warnings-as-errors` | Passed |
| `mix docs --warnings-as-errors` | Passed; README, embedding, persistence, schemas and changelog included |
| Package `mix test` | **232 tests, 0 failures** |
| `mix hex.build`, artifact metadata/content and production-dependency checks | Passed; **zero production dependencies** |
| Existing empty_tool, bundled_basic and fake_backend consumers | All passed against the same artifact |
| Packaged `examples/embedded.exs` executed from an artifact consumer | Passed |
| Installed-artifact Conversation, schema and store conformance tests | **33 tests, 0 failures** |
| Required real Sigma provider/schema source consumer | Passed; complete two-provider-step turn with fake tool backend |

Artifact SHA-256:
`4fec632b0521de5b2f60d7853f143a5ed9fd8f291717a33d307f2e6923d7a667`.
Two full builds of the final package contents produced this same hash. The
verifier removes its temporary artifact on exit. Final log:
`/tmp/backplane-agent-runtime-final-acceptance.log`.

The resumed work also reproduced and fixed two terminal-event races: cancelling
while a successful final commit was pending, and cancelling again during cleanup.
Both now publish exactly one event for the committed terminal outcome. The latest
focused Conversation suite passed **23 tests, 0 failures** before the complete
artifact verification above.

Runtime-specific release tests were run without executing Memory V2 tests:

```sh
devenv shell -- mix run --no-start --no-compile -e '
ExUnit.start()
ExUnit.configure(
  exclude: [:test],
  include: [
    test: :"test umbrella releases version and publish the Hex package",
    test: :"test published agent runtime provides a documentation task without production dependencies"
  ]
)
Code.require_file("test/release_config_test.exs")'
```

Exit 0: **2 executed tests passed; 10 excluded**. Final log:
`/tmp/backplane-agent-runtime-release-check.log`. `bash -n
scripts/verify_agent_runtime_package.sh` and `git diff --check` also passed.

The earlier standalone `elixir` release-check failure came from not loading
`Backplane.Repo`, not a demonstrated Memory V2 defect. The corrected loaded Mix
invocation passed before release documentation changes; final validation used
only the two runtime release tests above. Memory V2 fixes remain in the other
worktree and were not changed here.

The runtime previously had no `mix docs` task even though default Hex publishing
builds documentation. The package now has ExDoc only in the development environment,
and the release workflow resolves package publishing dependencies and verifies
docs before publishing. These are local workflow/contract checks, not evidence of
a remote CI run or publication. This completes the bounded package acceptance
scope; the consumer migration and production-storage work listed above remains.
