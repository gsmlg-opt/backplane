# Native clock cancellation across startup

Date: 2026-10-29. Request: #147. Baseline: main
`4e7a2a198cd9ee0f73fe019a0d457089dc95b229`, published 1.10.52.
Target: 1.10.53. Status: approved by the user on 2026-10-29; implemented and locally verified on 2026-10-30; publication awaits exact-commit
CI and official artifact verification.

## Reproduced problem

The issue's unchanged public-API probe was run against all five official Hex
packages pinned to 1.10.52. Cancellation immediately after `tool_started`, and
cancellation after actual waiter allocation but before the original cancellation
callback, both leave the clock intent uncertain and lack exact clock retirement
evidence. After the original callback ACK, cancellation produces the existing
`native_clock_wait_retirement` record. This reproduces the lifecycle gap without
Sigma code, manual proof construction, or dependency patches.

Conversation commits the tool intent and emits `tool_started` before launching
the Backend. ClockWait subsequently allocates its waiter and invokes the trusted
registration callback. Until that callback is accepted, Conversation cannot use
the cooperative clock cleanup path. Session closure and executor DOWN alone do
not identify or prove retirement of the original clock invocation.

## Choice and scope

Use coordinator-owned admission before releasing the real executor. Keep current
Runtime, Conversation, Store, Session, Registry and MultiAgent responsibilities.
Reuse the actual unarmed ClockWait, cancellation assertion and portable record.
Do not introduce another public receipt type or infer that dispatch never happened.

Alternatives considered:

1. Move `tool_started` after the current backend registration. This only hides one
   observable window: external cancellation can still arrive before registration,
   and wrappers can still pause before the ACK. It does not solve ownership.
2. Add a separate startup reservation ledger and a new no-dispatch proof protocol.
   This can cover pre-allocation, but duplicates clock state and expands the
   public proof/consumer compatibility surface unnecessarily.
3. Recommended: allocate and retain the original unarmed waiter while the real
   executor is parked, before publishing start or releasing backend dispatch.
   Cancellation before the Backend's former allocation point now retires an
   actual known waiter rather than reconstructing an absent one.

Write scope is the owning Runtime app, its focused tests and runtime documentation,
plus this design and the subsequent implementation plan. Release workflow changes
are not planned. No downstream changes, deployment, new branches or worktrees.

## Startup ownership and ordering

For a Store-ACKed native local `clock::sleep` invocation:

1. Construct the real owned executor using the existing parked-task machinery.
   It cannot execute backend or adapter code until Conversation releases it.
2. From the canonical acknowledged operation and current Session authority,
   Conversation obtains one Registry-owned unarmed ClockWait. Bind it to the
   exact executor PID, coordinator PID, original operation, Session owner and
   incarnation, registration ID and wait generation.
3. Validate and install that admission in Conversation's cancellation inventory
   before publishing `tool_started` or releasing the owned executor. Allocation
   and installation belong to the same serialized coordinator transition, so
   cancellation queued during allocation observes either the complete entry or
   an explicit failed startup; it never sees successful dispatch without one.
4. Deliver the exact admission through trusted execution context to that executor.
   Host configuration and adapter input cannot override the trusted capability.
5. ClockWait consumes the existing admission, validates its exact identity and
   Registry membership, and delegates to the original registration callback.
   The callback retains its current `{:ok, coordinator}` reply and live caller,
   token, operation and Session checks. Repeating the exact preinstalled entry is
   an idempotent acknowledgement; a different admission, caller, generation or
   operation conflicts. Successful startup never allocates a second waiter.
6. Only after that callback returns may the original waiter arm its timer. Recheck
   the original effect deadline and completion fence immediately before arming.

Apply the same ordering to direct root tools, managed-child Conversations, and
nested clock invocations inside real Deno Code Mode. Retain exact outer invocation
attribution and the existing registered native Code Mode worker boundary. A
transparent backend/post-hook wrapper may delay or delegate the existing callback;
it must not need to manufacture or collect startup proofs.

The admission is selected from the trusted local clock operation, its owning
Session and actual task; a tool name or family label alone is not retirement
authority. Do not grant unrelated host tools clock cancellation coverage. Preserve
existing support for transparent wrappers that delegate to the native Backend.
The implementation uses the native lifecycle marker in `Tools.contracts/1` for
this contract discrimination. Transparent wrappers retain it; a host descriptor
with only the clock name and local family does not opt into native retirement.
The marker describes a trusted native contract, not a cryptographic permission
boundary. Startup capabilities are still generated and checked by the coordinator.
Queued release messages are ignored while stopping, so even a wrapper preceding
the native Backend cannot start from a late release after cancellation.

## Cancellation, failures and resource bounds

Before backend execution, before callback ACK, and after ACK all use the retained
original admission. Seal its completion fence, retire the actual waiter, join its
DOWN, validate the existing typed cancellation assertion, stop/join the original
executor, and separately confirm Session/Registry and any real Deno cleanup.
Only then produce the existing public clock and enclosing Code Mode records.

A late callback or release message cannot rearm the sealed waiter, start a second
waiter, escape into synchronous sleep, publish a late result or replace a retained
registration. Callback ACK loss does not release a coordinator-owned admission.
Owner/coordinator death still closes real resources through Registry supervision.

Use the existing per-owner limit of 128 registrations, counting unarmed and
ACK-retained entries. Check capacity before allocating the waiter. Active and
unacknowledged admissions continue to block Session transfer. Keep fixed original
effect and cleanup deadlines; admission must not renew either budget. Every
Registry interaction involved in startup must be bounded by the remaining
startup/effect deadline. A timed-out allocation or uncertain reply cannot be
treated as proof of absence: retain uncertainty and fence/close the owner through
the existing cleanup boundary. Do not publish a confirmed record without its
exact owned receipt. An executor that cannot be created or activated must not be
left running or silently retried.

Invalid arguments still allocate no waiter. Failed Session authority, capacity or
allocation prevents backend dispatch. Preserve the existing error and Store
settlement rules. Store rejection, malformed/lost ACK, missing original source,
expired cleanup, and incomplete resource cleanup must not become confirmed
retirement merely because startup was attempted. In particular, an ambiguous
tool-intent Store ACK remains a storage recovery concern; this design does not
infer which command committed from an unavailable ACK.

Normal completion still returns the existing elapsed-time shape, joins waiter
DOWN, and retains admission until authoritative result ACK. Result/terminal Store
failure cannot erase the original responsibility. Low-level compatibility calls
without a runtime operation keep their current synchronous behavior and make no
retirement claim. Runtime-bound execution must fail closed if its required
coordinator admission is missing or stale.

## Public evidence and reconciliation

Keep `ToolEffects.ClockCancellation`, `native_clock_cancellation` and
`native_clock_wait_retirement` shapes unchanged. Their waiter fields refer to an
actual allocated waiter even when the Backend was never released or its callback
never acknowledged. Preserve sealed report digests and exact original identities.

Retain records through the existing terminal Store ACK path. Cold reconciliation
continues to require byte-equal membership in the authoritative original Store,
matching invocation, Session, generation and nested source inventory. Do not clear
raw obligations by presence alone, accept recomputed replacement proofs, alter
recorded business history/results, replay tools/hooks, or turn unknown effects into
success. Evidence discharges only its exact original lifetime obligation; unrelated
provider, child, resource and tool obligations remain independently required.

## Acceptance and delivery

First preserve the 1.10.52 probe failure as baseline evidence. Add deterministic
regressions for cancellation on the actual start event, while the backend is
parked before using its admission, immediately before the unchanged original
callback ACK, and after that ACK. Gates schedule actual Runtime work and do not
forge callback results or proofs. Assert no timer can arm after stop and no second
allocation occurs. Cover late callback/release and timer/completion races.

For root and managed-child, direct and real Deno, exercise the complete host path:
cancel; confirm real executor/waiter and required Deno/Session termination; remove
the original Conversation; cold-load its original Store; reconcile exact public
proofs; bind replacement resources; observe the actual next Provider request;
verify original business results/history remain unchanged. Keep post-hook adapter
coverage and all previously passing registered-wait tests. This is local runtime
consumer proof, not a claim that Sigma Engine has adopted the new version.

Negative tests reject identity/generation/Session/caller substitution, omitted or
replaced source records, stale admissions, late work, and independent outstanding
obligations. Test capacity before allocation, owner/coordinator death, admission
failure, fixed deadlines and Store ACK rejection/malformed/loss. Do not weaken
existing strict validators or tests to make startup pass.

Run focused tests, full Runtime tests and package qualification serially, then
required strict compile, format, Credo, Dialyzer and workflow contracts. Preserve
unrelated services and use isolated build caches where a running dev process
would mutate shared compilation output. Record out-of-scope failures without
repairing them. Review the final combined diff and exact-commit CI before release.

After checks pass, commit/push the scoped fix to main with `fixes #147`, then use
the canonical unified release workflow for 1.10.53. Verify terminal success, all
five official Hex packages and versioned docs, an independent exact-version
consumer, all six platform archives/checksums and applicable embedded metadata,
qualification manifest, image digest/source labels, tag/main convergence and a
clean working directory. Apply `internal request fixed` after publication
verification. Stop without deployment or downstream edits.
