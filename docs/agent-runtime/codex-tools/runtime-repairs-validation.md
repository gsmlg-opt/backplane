# Runtime repairs validation — 2026-10-01

The current generic host-rejection contract and its validation are recorded in
[the 2026-10-09 follow-up](#host-rejection-contract-follow-up--2026-10-09-issue-60).
Earlier failed command-lifecycle results below are historical; the Codex
command refusal repair shipped in v1.10.12. Deferred engine guarantees remain
separate from the generic host contract.

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

## R22–R24 follow-up on baseline `3197296da0a2e63884ea90eacd690d2786c49cd9`

This later follow-up is separate from the R18–R21 milestone and
its historical 495-test/package artifact. The Codex source remains pinned to
`46fdd5ef39735f4159cdcf0ec5e85c10521494e5`. No engine backend or Denox
dependency was changed. Source paths below are relative to
`apps/backplane_agent_runtime/lib/backplane/agent_runtime/`; tests are under its
`test/backplane/agent_runtime/` directory.

| Finding | Current status | Reproduction, repair, and remaining limit | Changed files and regression |
| --- | --- | --- | --- |
| R22 | Implemented, **unresolved full-suite regression** | The baseline let a crashed/timed-out nested mutation's error be caught and followed by outer success, consuming its execution intent. Current classification uses the normalized outcome and pinned admitted descriptor; an uncertain direct or nested mutation stops through existing `unknown_outcome` while retaining active invocation and intent. Confirmed read-only errors remain recoverable; explicit unknown results remain unknown. The current full Linux runtime run fails three command lifecycle tests: two trusted confirmed non-start refusals now stop as uncertain, while an older ambiguous-launch test expects continuation contrary to the new uncertainty boundary. R22 cannot be called verified until these contracts are reconciled and the full suite passes. | `conversation.ex`, `tool_effects.ex`; `conversation_uncertain_effects_test.exs`, `conversation_runtime_repairs_test.exs` |
| R23 | Implemented and focused native verified; overall milestone pending | Public owner-wide `Command.cancel/2` omitted `:reserved` obligations, so an old launch started while its owner PID lived. The backend now confirms and fences matching reserved identities in the same GenServer cancellation transaction. Mixed reserved/pending/active cancellation, unrelated older reservation survival, repeat cancellation, and late launch after receipt consumption/eviction pass on Linux. | `tools/local_command.ex`; `tools/local_command_owner_cancel_test.exs` |
| R24 | Implemented and focused native verified; overall milestone pending | A verified cleanup retry left an unexpired completed job's `cleanup_status: :uncertain` authoritative, and that record also masked in-progress retry evidence. Pending retry evidence now precedes stale completed metadata; verified settlement confirms the retained job only for the exact session, owner, and incarnation. Its output, TTL, original execution status/exit/termination and historical `cleanup_error` remain. A still-active ResourceRegistry session releases through its existing callback after host backend reconciliation. An already failed registry entry remains failed: there is no public retry/reset, and backend confirmation cannot erase it. | `tools/local_command.ex`; `tools/local_command_reconciliation_test.exs` |

### Follow-up reproduction and focused checks

R22's isolated baseline archive was
`/var/folders/sc/__3sj3tx5h9d4wxx953s0fgh0000gn/T/backplane-r22-astra-baseline-82jd8ri8`
at `3197296da0a2e63884ea90eacd690d2786c49cd9`, with only the new
regression test copied in. From its runtime package directory, with
`MIX_ENV=test`, `MIX_DEPS_PATH=/Users/gao/Workspace/gsmlg-opt/backplane/deps`,
and `MIX_BUILD_PATH=/tmp/backplane-runtime-r22-astra-baseline-build`:

```sh
mix test test/backplane/agent_runtime/conversation_uncertain_effects_test.exs:99 test/backplane/agent_runtime/conversation_uncertain_effects_test.exs:116 test/backplane/agent_runtime/conversation_uncertain_effects_test.exs:126 test/backplane/agent_runtime/conversation_uncertain_effects_test.exs:134
```

The baseline exited 2: **4 tests, 4 expected failures, 7 excluded**, seed
870741. An earlier Sol reproduction had 6 tests and 4 failures. On the current
macOS standalone runtime, from
`/Users/gao/Workspace/gsmlg-opt/backplane/apps/backplane_agent_runtime` with
`MIX_ENV=test`, `MIX_DEPS_PATH=/Users/gao/Workspace/gsmlg-opt/backplane/deps`,
and `MIX_BUILD_PATH=/tmp/backplane-runtime-r22-r24-build`, the following
focused selection exited 0: **132 tests, 0 failures**, seed 812590.

```sh
mix test test/backplane/agent_runtime/conversation_uncertain_effects_test.exs test/backplane/agent_runtime/conversation_runtime_repairs_test.exs test/backplane/agent_runtime/conversation_test.exs test/backplane/agent_runtime/conversation_catalog_test.exs test/backplane/agent_runtime/kernel_lifecycle_test.exs test/backplane/agent_runtime/execution_correctness_test.exs test/backplane/agent_runtime/recovery_test.exs test/backplane/agent_runtime/codex_multi_agent_profile_test.exs test/backplane/agent_runtime/codex_multi_agent_close_test.exs
```

An earlier two-file R22 check passed **35 tests, 0 failures**, seed 917864.
Scoped formatting, forced warnings-as-errors compilation of 69 files, and
`git diff --check` passed on macOS Elixir 1.19.5 / OTP 28. The regression uses
a real Conversation, production nested dispatcher, a barrier-capable Store,
and filesystem mutation. Its supervised outer helper records an attempted
success after the runtime stops the outer Task; this does not prove the outer
Task completed. For the timeout case, the harness cancels only the older outer
timer and leaves the actual nested timer to expire. Late-result checks use
captured Task references. No production durable adapter is exercised.

R23 and R24 native checks ran in the isolated Raven Linux copy
`/tmp/backplane-r22-r24.qsW1Lh/apps/backplane_agent_runtime`, with
`COREUTILS=/run/current-system/sw/bin/coreutils`,
`PATH=/tmp/backplane-r22-r24.qsW1Lh/tools:$PATH` (Deno 2.8.3),
`MIX_ENV=test`, and `MIX_BUILD_PATH=/tmp/backplane-r22-r24.qsW1Lh/build`.
The source/test files for each repair were overlaid into that copy; the real
Raven checkout was not modified.

```sh
mix test test/backplane/agent_runtime/tools/local_command_owner_cancel_test.exs --seed 386553
```

R23 before repair exited 2: **1 test, 1 expected failure**. After public
reserve/cancel, delayed start returned a running job. With the repair, this
test passed **2 tests, 0 failures**. The broader native selection below exited
0: **44 tests, 0 failures**, seed 386553.

```sh
mix test test/backplane/agent_runtime/tools/local_command_owner_cancel_test.exs test/backplane/agent_runtime/tools/local_command_test.exs test/backplane/agent_runtime/tools/local_command_cleanup_test.exs test/backplane/agent_runtime/codex_command_receipts_test.exs test/backplane/agent_runtime/codex_command_lifecycle_test.exs --seed 386553
```

```sh
mix test test/backplane/agent_runtime/tools/local_command_reconciliation_test.exs --seed 82733
```

R24 before repair exited 2: **2 tests, 2 expected failures**;
`Command.cancel_confirmed/3` reported stale `unknown_outcome` after explicit
retry. The first implementation still returned early while retry evidence was
pending, so the status query was corrected before final validation. The focused
new test then passed **2 tests, 0 failures**. The broader native selection
below exited 0: **55 tests, 0 failures**, seed 82733.

```sh
mix test test/backplane/agent_runtime/tools/local_command_reconciliation_test.exs test/backplane/agent_runtime/tools/local_command_cleanup_test.exs test/backplane/agent_runtime/tools/local_command_owner_cancel_test.exs test/backplane/agent_runtime/tools/local_command_test.exs test/backplane/agent_runtime/codex_command_receipts_test.exs test/backplane/agent_runtime/codex_command_lifecycle_test.exs test/backplane/agent_runtime/codex_resource_registry_test.exs --seed 82733
```

R24's fixture injects only the first failure and a worker barrier; its retry
calls the captured default Linux process-group reconciler and verifies actual
process absence. It does not set backend success state directly. Stale prior
tokens/references, repeated confirmation, retained output, an unresolved
sibling, and an already failed registry entry are covered. Both native focused
selections passed scoped `mix format --check-formatted`,
`mix compile --warnings-as-errors`, and `git diff --check` after their edits.
The parent independently reran each new native test: R23 **2 tests, 0 failures**,
seed 12373; R24 **2 tests, 0 failures**, seed 93432.

### Current full-runtime gate and delivery limits

From the isolated Linux runtime directory, with the native environment above:

```sh
env MIX_ENV=test MIX_BUILD_PATH=/tmp/backplane-r22-r24.qsW1Lh/build COREUTILS=/run/current-system/sw/bin/coreutils PATH=/tmp/backplane-r22-r24.qsW1Lh/tools:$PATH mix test
```

This current full-runtime run **failed**, exit 2: **510 tests, 3 failures**,
seed 194011, with Deno 2.8.3 available and no test skips. The complete log is
`/tmp/backplane-r22-r24-runtime-final.log` locally and `runtime-final.log` in
the isolated Linux copy. All failures are in
`codex_command_lifecycle_test.exs`: line 101 expects a confirmed workspace
non-start refusal to continue; line 182 expects the same for session-capacity
non-start refusal; line 164 is an older ambiguous-launch expectation of
provider continuation. The first two are current R22 regressions; the third
requires aligning the test's expected continuation with the required uncertain
effect behavior without weakening the recorded execution evidence. The
passing R22 focused run and the R23/R24 native runs do not close this gate.

Current whole-runtime `mix format --check-formatted` and
`mix compile --force --warnings-as-errors` passed on Linux Elixir 1.18.5 /
OTP 28; the latter compiled 69 files. The parent generated the local source
manifest with
`env CODEX_SOURCE_ROOT=/tmp/backplane-r22-r24-codex-source /opt/homebrew/bin/ruby scripts/codex_tools_inventory.rb --generate`
(exit 0). The pin/source lock and packaged upstream inventory remain
byte-identical. The final follow-up inventory check also passed, exit 0:
**16 families, 66 exact-source entries**.

```sh
env CODEX_SOURCE_ROOT=/tmp/backplane-r22-r24-codex-source /opt/homebrew/bin/ruby scripts/codex_tools_inventory.rb --check
```

The current R22–R24 package verifier has not run. Do not reuse the earlier
495-test total or package SHA as evidence for this follow-up.
No complete R22–R24 milestone, Codex parity, engine conformance, or production
host migration is claimed.

Before a host upgrade, settle/reconcile active runs and restart affected
Conversation, ResourceRegistry, MultiAgent, and LocalCommand supervision
trees; these process-local states have no hot migration. No new Store fields,
command adapter callbacks, or recovery framework were added. Existing optional
adapter callbacks remain optional. An already failed ResourceRegistry entry
cannot be reset through a public API, even after verified backend cleanup.


## Host rejection contract follow-up — 2026-10-09 (issue #60)

Issue [#60](https://github.com/gsmlg-opt/backplane/issues/60) reports Synapsis
host-tool approval refusals becoming uncertain after the Runtime upgrade. The
registered host backend returned plain `{:error, Error}` before its Gateway
call. For a potentially mutating descriptor, Runtime cannot infer non-execution
from an error class or metadata. The supported contract in v1.10.14 is now
`ToolEffects.reject(operation, error)` at that trusted pre-dispatch branch;
[EMBEDDING.md](../../../apps/backplane_agent_runtime/EMBEDDING.md) gives the
adapter pattern and limits.

Execution verifies the rejection's exact operation identity and arguments
before publishing a structured error and settling the invocation. Direct and
nested paths continue the provider; forged/malformed/replayed identities,
explicit unknown outcomes, and results arriving after cancellation remain
fail-closed. The helper asserts the trusted host's pre-dispatch decision; it does
not inspect external execution or reconcile a tool that already ran. Existing
host adapters must adopt it explicitly. Generic errors retain their current
classification.

Validation used Linux Elixir 1.18.5 / OTP 28, Deno 2.8.3 on PATH, and the native
Coreutils prerequisite:

- Standalone Runtime: 568 tests, zero failures; warnings-as-errors compilation
  and formatting passed. The new conversation regressions failed on the
  unmodified source before the implementation.
- `scripts/verify_agent_runtime_package.sh`: docs/compile/format and all 568
  source tests passed; 95 tests passed against the extracted artifact, including
  the new rejection cases. Empty-tool, bundled-basic, fake-backend, embedded and
  Codex consumer examples passed. The read-only Sigma source probe passed at
  `c6e916cabfb38ac20e4c3d4ccdd43652af607f38`.
- The exact Codex inventory check passed: 16 families, 66 entries, unchanged pin
  `46fdd5ef39735f4159cdcf0ec5e85c10521494e5`. Only hashes for the two changed
  generic Runtime source files were refreshed.

Consumer comparison used an isolated Synapsis checkout at
`5d4f0ac07a1606d0a3708eebf93a264ff5d23556`, seed 780259, and the three files
named in the issue. Its unchanged Runtime 1.10.4 pin ran 35 tests with one
pending-approval timeout failure. With Runtime 1.10.14 and pre-Gateway rejection
adoption, the unchanged tests ran with three failures: that same timeout, a
manual backend fixture lacking complete operation identity, and an old assertion
expecting provider completion after a dispatched tool's unknown timeout.

After supplying the manual fixture's exact operation identity and changing only
the dispatched-timeout expectation to uncertain cancellation with retained
intent, 34 checks passed. Only the unchanged baseline pending-approval timeout
assertion was excluded. All eight daemon tests and all three AbortableHTTP tests
passed in both comparisons. Approval/grant rejection, registration replacement
and disable, approved execution, task cancellation and no-retry checks passed.
The post-Gateway backend error handling was unchanged. These are supported
contract checks, not an unmodified consumer full-suite pass or a macOS
reproduction. No Synapsis main files or dependency pin were changed.
