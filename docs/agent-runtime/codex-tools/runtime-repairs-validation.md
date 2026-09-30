# Runtime repairs validation — 2026-10-01

Work was performed on `main`, initially clean at
`d347040395bdab31bbb8a27dc3278a32b0acba4c`, which contains the reviewed
`60a9be615b874bc1d7f721bd38b3a07e68562c5e`. Validation was performed before commit.
The Codex pin remains `46fdd5ef39735f4159cdcf0ec5e85c10521494e5`.
Historical R1–R17 evidence remains separate in the ledger.

| Finding | Status | Reproduction and repair | Main files |
| --- | --- | --- | --- |
| R18 | Implemented and verified | Real Conversation busy launch returned `unknown_outcome` instead of `resource_conflict` before repair. Backend reservation now records validated non-start, preserves cancellation/owner/incarnation fences, and returns the original refusal. Capacity refusal withdraws only an unused reservation using explicit trusted evidence. Actual launch with lost acknowledgement stays uncertain. | `codex/tools.ex`, `command.ex`, `tools/local_command.ex`, `codex/resource_registry.ex`, `codex_command_lifecycle_test.exs` |
| R19-runtime | Implemented and verified | Old timeout cancelled direct and nested human waits. Root/effect/nested/commit timers now carry independent generations; waits retain remaining budgets. Admission/resolution acknowledgement races, cancellation, late replies, duplicate timeouts and current-generation deadlines are covered. | `conversation.ex`, `conversation_runtime_repairs_test.exs` |
| R20 | Implemented and verified | Failed/error-marked producers retained staging and callbacks; successful staging became eligible before acknowledgement. Execution end now revokes failed staging and callbacks immediately; only acknowledged success may publish. Tests retry A→B through admitted nested dispatch, execute B's discovered tool on the next provider turn, and verify exact registry, authority, definitions, revision and receipts. | `conversation.ex`, `conversation_runtime_repairs_test.exs` |
| R21 | Implemented and verified | Eight native commands succeeded on isolated baseline, leaving eight receipts despite capacity two. Pinned obligations and bounded recent receipts are separate; explicit consumption acknowledgement permits FIFO eviction. Actual uncertain cleanup survives output expiry and receipt churn; admission backpressure bounds obligations/output resources. | `tools/local_command.ex`, `codex/resource_registry.ex`, `codex_command_receipts_test.exs`, `codex_resource_registry_test.exs` |
| R19-engine and backend work | Deferred | No engine migration, worker-timer repair, NIF adapter or Denox dependency. Existing native tests remain, but passing them does not close the deferred interruption, limits, callback cancellation, shutdown, isolation, continuation and timer checklist. | [backend decision](backend-decision.md) |

Source paths in the table are relative to
`apps/backplane_agent_runtime/lib/backplane/agent_runtime/`; tests are under
`apps/backplane_agent_runtime/test/backplane/agent_runtime/`.

## Reproduction records

- R18: 10 tests, 1 expected failure before implementation; workspace conflict
  was replaced by uncertainty. Native processes were owned by supervised teardown.
- R19/R20: initial shared-runtime integration suite, 9 tests, 7 expected
  failures. Admission timeout/cancellation races already passed on baseline.
- R21: isolated `git archive` of the initial HEAD with the new native churn
  regression, `mix test test/backplane/agent_runtime/codex_command_receipts_test.exs:42`:
  6 tests, 1 expected failure, 5 excluded; eight successful commands produced
  receipt count 8 > capacity 2. Earlier retention-zero setup failures and an
  incorrect line filter are not counted as defect reproduction.
- An initial full-runtime attempt without Deno failed existing native tests
  (`codex_profile_test.exs`, `codex_ct08_test.exs`,
  `codex_framing_test.exs`, `codex_code_mode_os_cleanup_test.exs`) and hung in
  two CodeMode calls until test timeouts. That attempt was interrupted after
  identifying the missing prerequisite; it has no passing total. Tests and
  gates were not changed. The already cached Deno 2.8.3 was used for both
  complete final runtime runs below.
- A development compile using umbrella dependencies encountered an existing
  `ex_doc` lock mismatch. No dependencies were changed. The clean standalone
  package verifier independently passed development compilation and docs.

## Final commands and results

Linux `/proc`, coreutils, setsid and the supported launcher were available.
Elixir 1.18.5 / OTP 28 executed native command effects. No tests were skipped
in the final focused, runtime or package runs. Injected worker/cleanup crashes
appear in the logs as expected fault-test diagnostics.

From the repository root, set the standalone runtime environment and change
to the package directory:

```sh
export MIX_ENV=test
export MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/backplane/deps
export MIX_BUILD_PATH=/tmp/backplane-runtime-r18-r21-build
cd /home/gao/Workspace/gsmlg-opt/backplane/apps/backplane_agent_runtime
mix format --check-formatted
mix compile --warnings-as-errors
mix test \
  test/backplane/agent_runtime/conversation_runtime_repairs_test.exs \
  test/backplane/agent_runtime/conversation_test.exs \
  test/backplane/agent_runtime/conversation_catalog_test.exs \
  test/backplane/agent_runtime/codex_command_lifecycle_test.exs \
  test/backplane/agent_runtime/codex_command_receipts_test.exs \
  test/backplane/agent_runtime/codex_resource_registry_test.exs \
  test/backplane/agent_runtime/tools/local_command_test.exs \
  test/backplane/agent_runtime/tools/local_command_cleanup_test.exs \
  test/backplane/agent_runtime/codex_command_budget_test.exs \
  test/backplane/agent_runtime/codex_session_incarnation_test.exs
```

Formatting and warnings-as-errors compilation passed. Focused selection:
**130 tests, 0 failures**, seed 993880. The shared-runtime selection separately
passed **75 tests, 0 failures**, including **24 new integration regressions**.
They exercise R15 input/result overlap in both commit orderings, strict Store
CAS, acknowledgement barriers, cancellation settlement and no late dispatch.

From the same package directory and environment:

```sh
PATH=/nix/store/18db0p8hqcp37myq75hl2mkjgff7x3by-deno-2.8.3/bin:$PATH mix test
```

Complete runtime: **495 tests, 0 failures**, seed 188298. Existing native
Deno tests executed. This is the runtime package suite, not the whole umbrella.

From a fresh shell at the repository root (without the standalone Mix exports):

```sh
devenv shell --no-tui -- bash -c 'export PATH=/nix/store/18db0p8hqcp37myq75hl2mkjgff7x3by-deno-2.8.3/bin:"$PATH"
REQUIRE_SIGMA_SOURCE=1 SIGMA_SOURCE=/home/gao/Workspace/gsmlg-opt/sigma bash scripts/verify_agent_runtime_package.sh'
```

Package verifier passed: clean development formatting/compilation/docs,
**495 runtime tests**, Hex archive, empty/bundled/fake backend consumers,
examples, **83 isolated Conversation consumer tests**, and a read-only Sigma
source probe at `7b30ca0a9f25146c5469b62fd87005fe1d7568c5`. It did not modify
Sigma or prove consumer migration. Artifact SHA256:
`663d8e72c324b6536ad143bd3b33377ecdc91827d34d9d889cb6e5ca9ff4e8b8`.
The verifier removes its temporary artifact on exit. This host's full log is
`/tmp/backplane-runtime-r18-r21-package-20261001.log`.

The exact pinned Codex checkout was verified before these commands:

```sh
CODEX_SOURCE_ROOT=/tmp/backplane-codex-pinned-source nix shell nixpkgs#ruby -c ruby scripts/codex_tools_inventory.rb --generate
CODEX_SOURCE_ROOT=/tmp/backplane-codex-pinned-source nix shell nixpkgs#ruby -c ruby scripts/codex_tools_inventory.rb --check
git diff --check
```

Inventory check passed: **16 families, 66 exact-source entries**. The initial
local manifest was already stale against ten source files; refreshing it
preserved the source lock and byte-identical packaged upstream inventory.
Ledger schema remains v2, with this milestone and its validation runs added
separately from historical review evidence.

## Post-push compiler correction

Commit `bec580a4dd48e2ca61b2206522c6b4c96e438eb3` was rebased unchanged over
four unrelated remote commits through `6d4b2a81` and pushed. Its CI checks and
Elixir 1.18 runtime job passed. The Elixir 1.20.1 / OTP 29.0.2 strict compilation
job detected an unreachable `lifecycle(nil, _handle)` clause introduced here;
the only caller already requires an arity-one function. The follow-up removes
that unused clause without changing the lifecycle contract and refreshes the
local source manifest. The earlier package artifact and runs remain historical
evidence for the main repair patch.

The correction passed these commands from the runtime package directory:

```sh
MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/backplane/deps MIX_BUILD_PATH=/tmp/backplane-runtime-r18-r21-build mix do format --check-formatted, compile --warnings-as-errors, test test/backplane/agent_runtime/codex_resource_registry_test.exs test/backplane/agent_runtime/codex_command_receipts_test.exs test/backplane/agent_runtime/codex_command_lifecycle_test.exs
PATH=/nix/store/6z2rn7bppkdx6p3qqkawp9yw1jw9hb42-elixir-1.20.4/bin:$PATH MIX_ENV=prod MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/backplane/deps MIX_BUILD_PATH=/tmp/backplane-runtime-r18-r21-latest-build mix compile --force --warnings-as-errors
```

Formatting and strict compilation passed; lifecycle regressions passed
**28 tests, 0 failures**, seed 469556. The separate strict production compile
passed on **Elixir 1.20.4 / OTP 29**. Existing JSONSchex dependency warnings
were emitted; the runtime package emitted no warnings. Inventory generation
and checking use the same pinned-source commands above.

## Host migration and remaining limits

Settle/reconcile active runs, then restart affected Conversation,
ResourceRegistry and LocalCommand supervision trees; no hot-state migration
is supplied. Optional command `reserve/2` and `acknowledge_release/2` callbacks
preserve existing adapters' start result contract. Generic errors, missing
backend records and cancellation requests are not proof of non-start or cleanup.
Explicit `never_started/not_created` rejection evidence requires a backend
fence against every later launch of the identity.

Native `receipt_capacity` and `session_capacity` default to 256. Direct hosts
using numeric sessions must generate fresh VM-monotonic IDs and acknowledge
consumed release proof. Existing pins survive newer receipt eviction. Evicted
evidence is unavailable-or-expired, never confirmed; acknowledgement failure
retains backend obligations/backpressure without reversing OS cleanup proof.
Registry `session_cleanup_status/4` exposes recent acknowledgement results.

Resources and callback/generation identities remain process-local. No durable
restart reconciliation, uncertain-effect replay, live-provider/service parity,
PTY parity, escaped-session cleanup, full Codex compatibility or Denox
conformance is claimed. Nested worker death during acknowledged human waiting
stops conservatively with uncertain settlement. The deferred engine checklist
remains open even though the preserved native test suite passed.
