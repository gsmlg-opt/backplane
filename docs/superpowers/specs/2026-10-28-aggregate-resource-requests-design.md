# Sequential caller-owned MCP resource scopes

Date: 2026-10-28. Repository: `gsmlg-opt/backplane`, current `main` baseline
`f9c50b9c9b5f748d98ebee57b0a650a4e1e2f7e9`. Request: #139. Target release:
1.10.48. Status: approved by user; implemented and locally verified; publication and official-artifact verification pending.

## Problem and scope

An admitted native resource adapter may need pages from several explicitly
selected MCP sources. The current `DynamicRuntime.resource_request/2` registers
one request against one Conversation invocation; Conversation correctly rejects
a second independent cancellation registration for that invocation. Ordinary
completion also supplies no exact local request-retirement receipt. Calling the
single-request helper repeatedly cannot implement native aggregate tracking.

Support sequential resource list, template-list and read requests inside one
admitted invocation. Preserve ordinary single-request/legacy callbacks, existing
Runtime/Store/Conversation/Session/Registry authority, and raw MCP business results.
Do not implement parallel fan-out, automatic pagination, source selection,
consumer result merging, a second request manager, remote rollback, downstream
adoption or deployment. Synapsis remains responsible for its selected sources,
opaque continuations and output projection after adopting the official release.

Authorized implementation ownership is limited to `backplane_agent_runtime`,
`backplane_mcp_protocol`, their public documentation/tests/fixtures, this spec and
implementation plan, plus established unified release metadata. No new dependency,
database migration, unrelated cleanup or workflow change is planned. Work stays
on main without a new branch or worktree.

## Alternatives and decision

1. **Explicit sequential scope (recommended).** Register one invocation scope,
   make every request explicit and bind its real handle to that scope. This
   preserves a clear opening/closing boundary and existing coordinator ownership.
2. Implicitly merge repeated calls using an operation map. This hides the end of
   aggregation and permits accidental reuse after the intended adapter callback.
3. Add a parallel aggregate broker. This introduces unnecessary concurrency,
   scheduling and ownership contracts for a request that only requires sequence.

Choose the explicit scope. Add an opt-in MCP retirement contract because neither
an ordinary response nor `request_not_found` proves worker/transport retirement.
Keep the existing single-request cancellation validator strict; aggregate proof
has its own typed, validated schema.

## Public Runtime contract

```elixir
DynamicRuntime.resource_request_scope(operation, fn scope ->
  a = DynamicRuntime.resource_request(scope, fn request_opts ->
    Client.start_list_resources(client_a, Keyword.merge(source_a_opts, request_opts))
  end)

  b = DynamicRuntime.resource_request(scope, fn request_opts ->
    Client.start_list_resources(client_b, Keyword.merge(source_b_opts, request_opts))
  end)

  adapter_result(a, b)
end)
```

`resource_request_scope/2` returns the adapter callback's ordinary value when it
returns normally. The opaque scope belongs only to the actual native effect
caller, original admitted operation and scope generation. It is valid only while
the callback is running. The scoped `resource_request/2` accepts a one-argument
starter receiving reserved MCP options, including `track_retirement: true`.
These options must take precedence over static source options. The starter must
only start that resource request in this caller and return its real public handle
or ordinary start error. It must not start other effects or transfer the handle.
The scope reads Conversation's live effect-deadline accessor before each slot.
It supplies reserved `timeout`, `registration_timeout` and `retirement_deadline`
options clamped to that deadline (operation default 30,000 ms; registration default
5,000 ms). The starter must preserve these reserved options. Missing, stale or
expired enclosing deadline refuses admission before the starter, rather than
inventing an unbounded scope.

The existing operation-map plus zero-argument starter interface remains unchanged.
Scoped starters cannot run in another process; nested/reentrant scopes and a
second concurrent request are refused before their starter executes. Each scope
admits at most 128 request slots, checked before invoking a starter. Exceeding the
bound is an explicit resource-limit error, never silently truncated fan-out.

The host chooses whether to continue after an ordinary request error and how to
combine responses. The helper preserves each raw MCP success/error and does not
merge pages. Cleanup evidence is separate from the business result. If retirement
cannot be confirmed, retain that unresolved obligation and seal further starts;
return the actual result of the already-completed request unchanged. A later
scoped helper call returns the explicit sealed/retirement-unavailable error before
dispatch. Scope return does not manufacture a successful cleanup assertion.

An empty scope is valid and performs no MCP work. Its sealed empty inventory can
prove no resource request was admitted, but it never fabricates a per-request
`local: cancelled` report or a `tool_not_started` event.

## MCP tracked retirement contract

Add `track_retirement: true` to public resource start options and a public
`Client.retire_resource_request(handle, opts \\ [])` operation. Tracking is
enrolled atomically before activation/dispatch and bound to the original owner,
opaque handle, logical request and Client incarnation. Untracked starts retain
their existing behavior and retention characteristics.

`retire_resource_request` is an observation/retirement operation for an already
terminal tracked request. It does not repeat the request, alter its result or send
a cancellation notification for ordinary completion. A still-live request must
first use the existing exact owner cancellation path; retiring it directly returns
an explicit not-terminal error. The normal await API remains unchanged.

The tracked entry retains the original local cleanup obligation through terminal
delivery: actual dispatch/resolver workers, transport and exact wire identities,
including any MRTR continuation obligations. The handle's logical identity stays
stable; do not require an initial wire ID to equal a later continuation wire ID.
Preserve explicit request-specific transport pins/evidence until retirement or
owner cleanup. Opportunistic HTTP/SSE worker maps and 128-entry completed-job
caches are not sufficient authority for a later tracked proof.

Reuse `RequestCleanup.release` and its worker-DOWN and transport-barrier semantics.
The report records a distinct resource-retirement schema with full logical/Client
identity, exact relevant wire IDs, actual terminal kind and cleanup evidence.
`local_cleanup: confirmed` requires every original worker and transport obligation
to be confirmed. Remote outcome remains unknown. Normal completion is described
as completed/retired, never relabeled cancelled. Existing cancellation reports
keep their existing meaning and validation.

`retirement_deadline` is an optional integer absolute local monotonic millisecond
deadline on tracked start. At enrollment fix the earlier of this value and the
start time plus the selected operation `timeout` (30,000 ms by default). For tracked
requests, registration and operation also respect that fixed bound. An expired
bound refuses dispatch. The new retire API accepts a positive finite `timeout`
(default 5,000 ms) and optional absolute `deadline`; effective due is the earliest
of call time plus timeout, enrollment retirement deadline and supplied deadline.
There is no infinite default. Runtime supplies the live original effect deadline;
once interrupted it additionally supplies the already fixed cleanup deadline.
Do not rebase an enrollment deadline at next request, proof retry or cancellation.

Proof collection returns confirmed or honest uncertain evidence. Consuming the
public receipt capability never drops an unresolved cleanup obligation or frees
its tracked capacity. Preserve unresolved worker/transport bookkeeping and pins
under the existing owner/Client lifecycle until actual release or connection
teardown. Expiry invalidates proof availability and triggers bounded owner/Client
cleanup; it is not evidence of cleanup and cannot silently evict live obligations.
Only resolved retirement releases its bookkeeping/capacity. An expired or missing
entry is unavailable, not confirmed. Wrong owner,
foreign/stale handle or Client incarnation cannot fetch or release another
request's obligation. Owner/client death and shutdown perform bounded cleanup and
release bookkeeping, without synthesizing successful proof.

Allow at most 256 outstanding tracked entries per Client, reserving capacity
before dispatch and refusing overflow explicitly. Never evict an unretired tracked
obligation to admit another request. Sequential Runtime scopes collect retirement
before the next starter, so normal aggregation holds one MCP tracked obligation
at a time. Ordinary untracked traffic does not evict tracked evidence or change
its results.

## Runtime and Conversation ownership

Conversation retains exactly one cancellation entry per admitted invocation.
DynamicRuntime extends that entry with a bounded ordered request inventory, one
scope token, actual effect owner monitor and a serialized admission gate. Each
request slot has a fresh cancellation control (controls remain single-request),
real handle identity, phase and exact retirement/cancellation evidence.

Register the scope with Conversation before invoking its callback. Before every
starter, DynamicRuntime atomically admits a slot only while the gate is open and
identity/owner/generation match. Cancellation seals the gate in the same serialized
state transition. A slot admitted before sealing may still be registering its
real handle; it remains an obligation until registration and cleanup resolve.
No slot admitted after sealing may invoke its starter. Do not claim cancellation
can retroactively prevent dispatch already admitted before the stop fence.

After each request returns, collect its exact retirement proof before permitting
another slot. Keep the compact validated proof in the scope rather than retaining
arbitrary response bodies or host closures. Keep bookkeeping when callback return
or owner DOWN races with result publication; actual owner DOWN alone is not proof
that every MCP worker/transport retired.

Close the callback's capability on return/raise/exit. Retain the invocation's
inventory through authoritative result/cleanup Store ACK or coordinator teardown,
using existing Conversation release hooks. Do not release at callback return:
cancellation can race with an unacknowledged result. Ordinary and nested result
settlement, storage failure and coordinator death all release task-owned monitors,
controls and retained records without implying a committed result.

## Cancellation and proof

1. Conversation seals dispatch and fixes its existing stop generation and absolute
   cleanup deadline; DynamicRuntime seals the scope's future admissions.
2. If a real current request exists, signal its own cancellation control. If a
   pre-fence admitted starter is in flight, retain the pending stop and bind the
   returned real handle before cancellation. A start error without a handle does
   not automatically prove no dispatch; absent exact registration cleanup evidence
   remains uncertain.
3. Validate completed-request receipts and current-request cancellation/retirement
   against the entire original inventory. Account for zero, completed and still
   starting/current slots explicitly; never omit a slot, substitute a request or
   reuse another Client's proof. Late ordinary completion may supply a distinct
   retirement receipt, without rewriting its business outcome.
   Every terminal tracked slot, including one cancelled through the existing
   cancellation API, must obtain the tracked retirement receipt over its complete
   accumulated worker/wire obligation ledger. The existing current-request
   cancellation report cannot by itself discharge earlier MRTR continuations.
4. Produce typed aggregate cancellation evidence only when the gate is sealed,
   inventory is exact and every admitted slot is locally retired. It binds full
   invocation/Session identity, scope registration, stop generation, inventory
   digest/count and ordered per-slot proof. Unknown, absent or expired proof
   prevents confirmation. The aggregate does not invent a representative logical
   request ID or weaken existing `ToolEffects.Cancellation` validation.
5. Once the sealed scope proves all admitted MCP obligations locally retired,
   Conversation stops the original actual effect Task if it is still alive and
   observes its DOWN under the same deadline, fencing late results. This covers
   callback computation/waiting between requests, where no controlled MCP await
   exists to consume a cancellation signal. Do not terminate that caller before
   an admitted starter/current request has supplied its required cleanup proof;
   missing proof follows the existing uncertain-stop path. This targeted stop
   applies only to the new validated aggregate assertion, without changing legacy
   or single-request cleanup semantics. Conversation still requires its own
   Session and Registry cleanup. Nested Code Mode also requires the exact enclosing
   invocation, real Deno exit and all original nested cleanup obligations. Reuse
   existing Kernel/Store cleanup acceptance and ordinary JSON evidence bounds.

All stages share the original deadline. No retry, receipt lookup, next request or
state transition renews it. Failure, owner/coordinator exit, missing registration,
uncertain barriers or Store ACK loss preserve honest unknown/recovery-required
state. Cancellation never creates `tool_completed`, successful aggregate output,
remote rollback, or permission for automatic replay/fresh-run admission without
the existing complete cleanup contract.

## Verification and release acceptance

Use functional regressions before implementation. Serialize local BEAM/build
commands and coordinate disjoint source ownership; no additional checkout.

MCP coverage:

- Ordinary untracked success/error contracts remain unchanged; tracked list,
  templates and read preserve raw results and return exact retirement receipts.
- Completed requests retire without replay or cancellation notification; actual
  workers and HTTP/SSE/stdio barriers are covered, including MRTR wire changes.
- Retention survives more than 128 unrelated completed HTTP jobs; capacity,
  wrong owner/Client, expired proof, owner death and completion/cancel races stay
  bounded and cannot confirm unavailable obligations.

Runtime coverage:

- Two real resource-only sources: list/templates first pages and read, source-
  specific options/cursors preserved, one native invocation and unchanged adapter
  aggregation semantics. Include direct native and real Deno nested consumption.
- First completed request plus second current request, cancellation between slots,
  registration/attach races, normal completion before cancellation, empty scope,
  cap overflow, refused parallel/reentrant calls and reuse after callback return.
- Exact owner/Session/Client/scope/generation identity, caller/coordinator death,
  finite original deadline, missing proof and result/cleanup Store ACK loss.
- Existing single-request, legacy callbacks, Session cleanup, nested outer cleanup,
  plugin retirement, headless execution and recovery regressions stay green.

Run owning app suites, strict compilation, format, Credo, Dialyzer and workflow
contract as required by applicable CI. Qualify the extracted candidate package and
standalone consumer before publication; no local source override counts as final
consumption. Change Runtime's MCP package minimum to `~> 1.10.48` because the new
scope requires the new public tracked-retirement API. The original helper remains
supported, but the released Runtime package must not silently resolve an older
MCP package lacking the new API.

After exact-SHA applicable CI succeeds, use the established unified 1.10.48
release workflow. Verify all five official Hex packages/checksums and versioned
docs, a fresh exact-Hex consumer with the aggregate regressions, all six archive
checksums, packaged production version/source/helpers, and published container
version/source labels. Close only #139 after verified publication. Record new
requests separately; do not silently expand this release. No deployment or
downstream upgrade is part of completion.

## Source evidence

- Runtime `codex/resource_request.ex`: one registration/handle/control per call.
- `codex/dynamic_runtime.ex`: resource entries and register/attach/finish/cancel,
  owner/coordinator monitors and release hooks.
- `conversation.ex`: per-invocation cancellation registration, Store-ACK release,
  cooperative task/Session cleanup and nested outer acceptance.
- `tool_effects.ex`: strict single-request cancellation identity and evidence.
- MCP `client.ex`, `client/state.ex`, `client/resource_cancellation.ex`,
  `client/request_cleanup.ex`, `http_lifecycle.ex` and HTTP/SSE/stdio transports:
  original owner/handle, completion removal, finite cleanup and transport retention.
- Historical Agent Note `30677b9a-8b63-45c1-bf39-a7104a8fc592` records 1.10.46
  single-request boundaries; it does not claim aggregate support.
