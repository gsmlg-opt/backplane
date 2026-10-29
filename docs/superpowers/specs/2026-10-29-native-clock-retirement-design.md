# Native clock wait ownership and exact retirement

Date: 2026-10-29. Baseline: main `389b0956a2cce9a51c1782327a806b299f94c5a5`.
Latest published version: 1.10.51. Target: 1.10.52. Request: #146.
Status: approved by the user on 2026-10-29; implemented and locally verified.
Publication is subject to exact-commit CI and the unified release workflow.

## Problem and choice

`Codex.Tools` currently implements clock::sleep with Process.sleep/1. The local
Backend does not register a cancellable wait, and Backend.cancel/1 cannot prove
its retirement. A stopped executor or closed Session therefore leaves the exact
tool obligation unresolved. The consumer must not infer cleanup from empty effects.

Recommended: introduce an invocation-owned ClockWait under the existing Registry
worker supervisor, and compose its typed cancellation with the existing
Conversation, ToolEffects and reconciliation machinery. Keep clock in the local
profile. Preserve Runtime/Store/Session/Registry/MultiAgent ownership boundaries.

Alternatives:

1. Extend DynamicRuntime's plugin observer tracker for clock. Avoid: local-only
   profiles would depend on an unrelated dynamic tool runtime and plugin state.
2. Treat clock as intrinsically effect-free after executor DOWN. Reject: bypasses
   exact owned-wait observation, provenance and authoritative source validation.
3. Add the owned ClockWait above. This adds one bounded lifetime and explicit
   proof type while reusing current cancellation and resource cleanup boundaries.

## Ownership and admission

Add internal Codex.ClockWait. Each runtime invocation starts one temporary,
initially unarmed waiter under ResourceRegistry.worker_supervisor/1. Register it
as kind :clock_wait with the exact existing resource owner/incarnation and cleanup
callback before arming. The callback seals the wait and joins its real DOWN under
the cleanup deadline. Bound clock registrations, including ACK-retained entries,
to 128 per owner; reject capacity before allocating another waiter. Registry's
current continuation-specific limit does not cover this new kind. No global
tracker, unbounded receipt cache, new supervisor tree or public synthetic handle.

The actual tool effect caller registers cancellation through the trusted
Conversation callback. Conversation validates its live token, caller PID, exact
operation and Session binding, then installs the registration. Only after that
acknowledgement may ClockWait arm its timer. The registration binds a unique
registration_id and wait_generation, the original ToolEffects cancellation
identity, owner handle, waiter and executor, and coordinator authority. PIDs,
references and cleanup capabilities stay process-local.

Backend's local path must propagate the trusted registration/deadline context to
Tools, alongside runtime_operation and resource_owner. It must not accept model
arguments as cancellation authority. Register clock explicitly in Conversation's
admission, retained task, release and stop paths; do not route it to ResourceScope.

If registration loses to cancellation or owner closure, do not arm; release/join
the actual allocated waiter. A missing entry or failed registration alone never
produces not_started or retirement evidence. If execution was admitted without an
owned wait receipt, keep the existing uncertainty rather than widening inference.

Keep the current duration range (1 ms through 12 hours), error contract and
wall_time_seconds result shape. Invalid arguments allocate no waiter. Standalone
Codex.call compatibility without a runtime operation may retain synchronous sleep
semantics; it produces no runtime retirement claim. A runtime-bound operation
missing required lifetime authority fails closed before arming.

## Normal completion and cancellation

ClockWait owns its timer and one completion gate. Timer messages include the exact
wait generation. Normal completion closes the gate, retires the timer/waiter and
joins actual waiter DOWN before returning elapsed time to the executor. The normal
result follows the existing Store result ACK path. Retain the registration and
terminal wait facts until that ACK; normal completion must not cancel or replay
the sleep to obtain evidence. Store rejection or a lost/malformed ACK cannot erase
the registration or permit a provider-facing result. Retain terminal facts in the
trusted registration after waiter exit; do not query a dead waiter to reconstruct
them. An active or unacknowledged clock registration blocks owner transfer/detach;
extend Registry readiness checks rather than treating the new kind as transferable.

Backend.cancel dispatches supported local clock waits to ClockWait.cancel.
Cancellation requires the exact registered operation, registration/wait generation,
Conversation coordinator and nonempty stop_generation. Seal completion before
stopping the timer/waiter. Observe the exact waiter's real DOWN within the original
cleanup budget, then return a typed ToolEffects.ClockCancellation assertion.
Repeated identical cancellation is idempotent while registration is retained;
changed identity/generation conflicts. All calls and joins use a finite remaining
deadline. Owner/coordinator death invokes the existing Registry cleanup boundary.

Timer/cancel races may yield a genuinely completed waiter, but cannot reopen the
gate, publish a late normal result after stopping, or overwrite the original
cancelled/unknown tool settlement. If completion preceded result ACK, cancellation
still requires retained exact terminal wait facts and executor cleanup. Absence or
eviction of those facts is uncertainty. A waiter exit signal without the original
registration and sealed terminal facts is not a valid report.

After typed wait cancellation validates, Conversation stops/joins the registered
tool executor using its existing bounded stop machinery. Session/Registry and
owned-manager cleanup remain separately required. Failure to confirm any component
retains its obligation; do not manufacture a confirmed proof to unblock admission.

## Typed evidence and durable reconciliation

The private typed cancellation report has exactly these fields:

```elixir
%{
  schema_version: 1,
  record_type: :native_clock_cancellation,
  registration_id: registration_id,
  wait_generation: wait_generation,
  stop_generation: stop_generation,
  completion_gate: :closed,
  timer_retired: true,
  waiter_down: true,
  local_cleanup: :confirmed
}
```

Validate the report against the retained sealed registration, including a sealed
report digest, exact operation identity and stop generation. A caller-supplied map
or recomputed digest alone grants no authority. Clock cancellation does not claim
external rollback, permission decisions or cleanup of independent work.

After actual executor DOWN and confirmed resource cleanup, Conversation materializes
a portable record with exactly: schema_version:1,
record_type:native_clock_wait_retirement, identity, stop_generation,
provenance:{session_binding_identity}, cancellation (the complete public report),
executor_down:true, resources:confirmed, local_cleanup:confirmed, outcome:unknown,
and retirement_digest sealing the remaining record. Use the existing Evidence
public conversion and digest rules. Identity contains all current cancellation
identity fields, including original run/incarnation/invocation, tool attribution,
Session binding and enclosing invocation where applicable. Clock wait retirement
is valid only for the actual clock::sleep operation, plus an explicitly supported
legacy local wait alias if admitted as that actual operation; Code Mode's outer
wait is never classified as a local clock wait by name alone.

Retain the portable record in Conversation status and terminal Store cleanup
evidence through the existing authoritative terminal ACK. Extend strict
ToolEffects validation and Reconciliation's explicit type allowlists. Require
byte-equal record membership in the authoritative original run cleanup evidence,
matching original intent and exact Session identity; lack of a retained source
record is not permission to accept a fabricated substitute.

For Code Mode, the outer retirement retains the exact nested clock record type,
identity and evidence digest. Validate its enclosing invocation, common stop
generation, complete nested inventory and source records through the existing
recursive reconciliation path. A valid clock receipt discharges only its original
obligation; unrelated tools, children, provider or resource obligations remain.
Session/Registry/MultiAgent consume this through existing public reconciliation,
without rewriting original history, retrying execution or adding implicit recovery.
Existing plugin, Events, resource and Code Mode proof schemas remain compatible.

## Scope and acceptance

Allowed changes: apps/backplane_agent_runtime source/tests and corresponding
runtime documentation, existing package qualification fixtures/scripts only as
needed, this design/implementation plan and standard release metadata. No consumer
repository changes, dependency workaround, deployment, new branch/worktree,
permission/sandbox change, unrelated cleanup or automatic addition of later issues.

Reproduce the baseline gap, then cover these public functional paths:

1. Direct real Conversation native clock invocation: normal completion preserves
   elapsed result and result ACK ordering. Cancellation while waiting produces the
   exact typed/portable proof only after waiter/executor DOWN and resource closure.
2. Real managed-child clock cancellation through MultiAgent: original child
   invocation and Session provenance survive whole-child retirement. Unrelated
   retained child/work obligations cannot be discharged by that record.
3. Real Deno Code Mode invoking clock::sleep: cancel the actual nested wait,
   confirm worker/executor retirement and exact nested digest composition.
4. Writer-backed Store cold read after the source Conversation exits. Public
   reconciliation accepts genuine retained records and rejects changed invocation,
   Session, registration, generations, digest, enclosing identity, absent source
   records, incomplete nested inventory and unrelated evidence substitution.
5. Admission/cancel and timer/cancel races, owner/coordinator death, cleanup timeout,
   stale timer/completion, duplicate cancel, completed-before-ACK wait, result and
   terminal Store rejection/lost/malformed ACK. Unconfirmed cases retain obligations.
6. Public host recovery sequence: retain the prior journal/results, reconcile exact
   old lifetime, retire the old Session, bind fresh resources and reach an actual
   next Provider request. Do not weaken the original consumer continuation claim;
   local upstream fixtures do not establish live Sigma adoption.

Run focused regressions, full affected runtime suite and existing package/cold
consumer qualification, followed by required compile warnings-as-errors, format,
strict Credo, configured Dialyzer and workflow/release contracts. Verify the final
integrated diff and exact commit CI. Inspect live release.yml and set-version.sh,
confirm the target is still the next available patch, and use the canonical
main-only unified release. Await every release job and verify five official Hex
packages and their source/docs, archive checksums/provenance and published image.
Do not report released until those gates complete; downstream adoption and
deployment remain separate, unverified outcomes.
