# Native Events lifecycle and post-effect Goal admission settlement

Date: 2026-10-29. Baseline: main `1997ae62d046cd685841d34db15e6e6a7f9de6ad`.
Latest published release: 1.10.50 (`a81325c3`). Target: 1.10.51.
Status: proposed for user review; implementation has not begun.
Scope: internal requests #144 and #145. The baseline includes the already committed
HTTP/2 SSE repair; preserve it and qualify the complete release commit.

## Problems and choices

Events already expose a real caller-owned EventRequest, but lack public immutable
identity, controlled wait and tracked terminal retirement. Resource-specific
helpers cannot truthfully accept that handle. A normal raw page does not prove
worker or transport retirement, and current-wire cancellation does not discharge
historical MRTR wire obligations.

A released Goal executor can perform an actual host hook and stop before Runtime
admission. Existing withdrawal covers never-released reservations; existing
settle_unstarted_admission requires effects:none_dispatched. Neither can settle
this occurrence without misrepresenting executed work. The old reservation then
blocks fresh automatic admission even after an ordinary user turn succeeds.

Recommended: typed Events APIs with shared private owned-request machinery, plus
a separate host-effect Goal settlement entry point using the existing Goal ledger.
This preserves MCP Client, DynamicRuntime, Conversation, Session/Registry and
Goal/State/Store ownership. No alternate request tracker or execution engine.

Alternatives considered:

1. Copy the resource cancellation/retirement implementation for Events. Avoided:
   duplicates delicate deadlines, MRTR inventory and transport barrier machinery.
2. Publish a generic mixed-request scope or widen no-effect settlement. Avoided:
   expands public semantics unnecessarily and obscures distinct request/effect facts.
3. Require fake ResourceRequest handles or move hooks behind an invented Runtime
   run. Rejected: changes ownership/history and the consumer's real hook ordering.

## Typed MCP Events lifecycle (#144)

Keep EventRequest opaque and distinct from ResourceRequest. Add its immutable
registered identity, unique cancellation key and optional fixed retirement deadline.
Identity contains the same original logical/client incarnation/method attribution
needed by tracked requests, with method exactly events/list. Original mailbox tags,
reply reference and caller ownership remain unchanged through MRTR continuations.

Add Client.event_request_identity/1, event_cancellation_control/0,
cancel_event_wait/3, await_event_request/3 and retire_event_request/2. Existing
start_list_events/2, await_event_request/2 and cancel_event_request/3 remain valid;
cancel_event_request additionally supports the existing verified:true semantics.
Tracked starts use track_retirement:true and retirement_deadline. Controls remain
typed, owner-bound and single-request-bound; resource and Events controls are not
interchangeable. Observation timeout alone does not cancel or retire the request.

Extract only the shared private tracked-request and controlled-receive mechanisms.
They explicitly recognize the two supported handle families; do not accept an
arbitrary callback module or add a public generic handle. Retain ResourceRequest
API, resource receipt schemas and existing resource validation unchanged.

Events use receipt schema event_retirement, version 1, containing the exact
registered identity, ordered complete wire request_ids, actual terminal kind,
workers_down/worker_count and transport barrier, local_cleanup and remote:unknown.
Receipt local:retired means local lifetime discharge, never business rollback.
Enrollment occurs before dispatch; capture every worker and wire before MRTR
replacement. Use the existing combined bound of 256 tracked logical requests per
Client and 256 wire obligations per request. Reject overflow before admitting the
extra obligation. Pinned history must not depend on the opportunistic 128 cache.

Retirement queries require an actually terminal request and the original owner.
Collection and Client acceptance both obey the original fixed enrollment deadline
and shorter finite query deadline. Collector death, owner death, expired budget or
uncertain transport leaves unresolved obligations retained. Preserve shutdown and
connection sealing behavior. Do not claim cleanup from a missing ledger entry.

## Native one-page Events composition

Add DynamicRuntime.event_request(operation, starter/1). The starter performs only
one Client.start_list_events in the actual effect caller, preserving reserved
tracking/deadline options. This is not an Events pagination/aggregate scope.
Register the exact native operation and cancellation responsibility before calling
the starter; attach its original EventRequest identity before waiting. Wait under
the live invocation budget and the typed cancellation control. After any observed
terminal result, including verified cancellation, call full retire_event_request.
The current-wire cancel report alone cannot prove all MRTR obligations retired.

Return the original successful/error MCP response for ordinary adapter conversion
only after confirmed local retirement; do not alter cursor, order, schemas or
metadata. If retirement is unconfirmed, return unknown_outcome through the existing
uncertain-tool path and retain the unresolved registration. Do not publish the page
as an acknowledged normal tool result or invent cleanup to get past the failure.
No completed page is replayed or cancelled again to obtain a receipt.

Retain exact request identity and terminal receipt in DynamicRuntime/Conversation
until the authoritative result Store ACK. Release the registration only from the
existing post-ACK continuation. Failed/missing ACK cannot release it or permit a
provider-facing reply. Keep transport retirement separate from result persistence.

Expose native mcp_events through DynamicRuntime when the host MCP adapter exports
list_events(arguments, operation). Its schema requires one explicit server string
and permits one opaque cursor. The host selects configured source visibility and
converts the ordinary raw result; Backplane adds no source policy. Other existing
MCP resource capabilities remain unchanged. Missing Events support does not
advertise mcp_events. No subscription, scheduler, webhook or ingress effects.

Conversation admits mcp_events registration with the same live effect caller,
invocation token and Session checks. Backend dispatches Events cleanup explicitly;
release and retained-effect selection recognize the new typed registration. Share
private registration plumbing only where its identity/fencing semantics match;
do not rename Events as a resource or weaken the old resource predicates.

Add a distinct ToolEffects.EventsCancellation assertion validating the complete
event_retirement receipt, exact registration/stop generation and sealed original
request identity. After validated request retirement, Conversation may terminate
the registered effect caller and must observe its actual DOWN within the cleanup
deadline. Confirmed Session/Registry cleanup remains separately required.

On whole-run/child interruption, materialize portable event_request_retirement
only after those real cleanup obligations are confirmed. It retains the original
complete typed report, invocation/Session identity, registration/stop generation,
executor_down, resources, local_cleanup, outcome:unknown and sealed retirement
digest. Retain it in status and terminal Store evidence. Reconciliation requires
the original authoritative intent and byte-equal retained source record, including
exact nested Code Mode references. Recomputed or substituted proof is insufficient.
Keep existing resource/plugin/Code Mode contracts and historical outcomes intact.

## Post-effect, pre-Runtime Goal settlement (#145)

Add owner-only Goal.settle_host_admission(goal, admission, reason, attestation).
Keep settle_unstarted_admission and withdrawal strict and unchanged. Reuse the
existing token-keyed admission_settlements ledger, pending attempt fence, complete
Store CAS ACK validation, historical lookup and binding/delegation fences.

Admission is the exact existing five-field identity: run_id, incarnation, logical
turn_id, host_generation and reservation_token. Closed attestation:

```elixir
%{
  admission: exact_identity,
  executor: :confirmed_down,
  runtime_admission: :never_started,
  future_start: :fenced,
  effects: %{
    kind: :host_pre_runtime,
    records: [
      %{effect_id: "stable-command-id", kind: "UserPromptSubmit", result: actual_result}
    ],
    result: actual_host_turn_result,
    cleanup: :confirmed
  }
}
```

The outer, effects and individual record maps have exactly the shown keys. Effect
IDs/kinds are nonempty UTF-8 strings; IDs are unique. Preserve ordered records,
actual hook results, stop reason and host terminal result exactly. Nested result
values are JSON-compatible (string-keyed objects, arrays, finite numbers, strings,
booleans and nil), without live capabilities; reject rather than truncate invalid
evidence. Require 1–128 effect records and bound total encoded effects data to 1 MiB.
No implicit command output/credential capture. Hosts supply the actual relevant
structured facts and must not put secrets in persisted evidence.

This is a trusted host attestation, not independent Goal observation of commands.
The host must observe actual executor DOWN, finish all local command/helper/pipe
obligations, and atomically fence the exact token/generation at the same gate used
for admission, queued continuations and future starts. Actual effects may remain
externally visible; confirmed cleanup does not undo them. Store absence, zero
provider calls, UI agent_end or an unrelated host close alone is not proof.
Missing/uncertain cleanup, ambiguous Runtime/outbox admission or actual Runtime
activity cannot use this API. Reconcile such activity through its existing owner.

Reasons are host_stopped, cancelled and superseded. host_stopped retires only the
old reservation while preserving Goal status, budgets, usage, failure audit and
continuation policy. cancelled uses the existing durable cancellation deferral;
superseded retires only the old reservation. The actual hook stopReason remains
in effects data. Do not use cancelled for an ordinary hook veto merely to obtain
settlement: its policy intentionally blocks subsequent automatic continuation.

Settlement does not call idle, release new work, replay a hook, create Runtime
history/receipts or select automatic retry policy. A later real ordinary prompt
may finish normally; a subsequent normal host idle decision can then admit fresh
automatic work for the same active Goal using a new identity/token. The host owns
when that idle decision is made; settlement acknowledgement is not a scheduling
signal. Do not silently defer or resume Goal by introducing another policy flag.

Require the exact current reservation and no matching live binding or fresh
Runtime receipt, including Runtime-minted turn identities and accounting ACK
failure. Install the pending fence before persistence, not after. Exact old retries
return the saved acknowledgement before considering a newer reservation. Changed
effects, reason or identity for a saved/pending token conflict. Only a full Store
ACK clears the matching local reservation; rejection, malformed ACK and lost ACK
retain it and its future-start fence. CAS reload must recover the original stored
acknowledgement without touching a newer Goal/admission or replaying effects.

Extend persisted receipt validation to recognize the two strict settlement forms
without changing the envelope or requiring a new Store callback. Old records still
load; malformed new data fails closed. Keep unrelated binding/receipt accounting,
elapsed time and restore/fork behavior. A cold host must retain/re-establish its
external start fence and reconcile unknown Runtime/outbox work before resubmission;
Goal persistence alone cannot recreate a host execution seal.

## Ownership, acceptance and release

Allowed implementation: apps/backplane_mcp_protocol and apps/backplane_agent_runtime
source, matching tests/docs and existing package qualification scripts/fixtures;
this spec/implementation plan and standard release metadata. No downstream edits,
dependency patches, deployments, unrelated Memory fixes, new branches/worktrees or
permission/sandbox features. Newly opened requests are not automatically appended.

First reproduce the missing supported boundaries on the official/current baseline.
Use public APIs and real supervised effects for functional acceptance, not private
state seeding or fabricated retirement records:

1. Real local modern MCP HTTP Events page: exact cursor/ordered payload preserved;
   intent ACK precedes request, result ACK precedes provider-facing reply, actual
   normal retirement retained through ACK, shared Client remains usable. No
   subscription, cancellation notification or replay in ordinary completion.
2. Typed owner/control identity, MRTR completion/cancellation full wire inventory,
   bounded waiting/deadline/collector failure, pins surviving unrelated traffic.
   Existing resource schema and regression suites remain unchanged and passing.
3. Direct and real-Deno Events cancellation/whole-child retirement using exact
   original request identity; actual effect DOWN, Session cleanup, retained proof
   readback and reconciliation after source Conversation exits. Uncertain cleanup
   or substituted evidence cannot confirm retirement.
4. Actual released supervised executor executes a real observable command hook,
   stops before Runtime with no original provider/Runtime record, then exits.
   Owner seals the exact admission and settles its real result/effects. Settlement
   produces no new command/provider work. A later ordinary Conversation and normal
   idle decision yield a fresh automatic identity without original hook replay or
   unrelated Goal mutation; finally confirm complete owned-resource retirement.
5. Host settlement Store rejection/lost/malformed ACK, exact retries and changed
   evidence, newer Goal/admission preservation, late bind/delegate, actual Runtime
   start including lost accounting ACK, portable bounds and unrelated accounting.
   Independent producer/consumer BEAM verifies durable saved-ACK recovery.
6. Preserve #127 no-effect, #91 withdrawal, #109 terminal ACK, resource scopes,
   native adapter cancellation and provider-free host_context regressions.

Verification proceeds from focused tests to affected app suites, strict compile,
format, Credo, configured Dialyzer, workflow/release contracts and the existing
extracted package/independent consumer qualification on supported Elixir versions.
Run the complete exact-commit CI before the canonical main-only unified release.
After release require every job, five exact official Hex packages and versioned
docs/checksums/source bytes, independent functional and cold consumers, six archive
checksums/manifest, packaged compiled version/SHA/helpers and GHCR source/digest
verification. Report local fixtures separately from real Sigma/Synapsis adoption;
this task does not claim downstream acceptance or deployment.
