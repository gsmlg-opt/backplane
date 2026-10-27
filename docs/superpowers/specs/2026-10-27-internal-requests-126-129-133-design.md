# Runtime recovery, owned MCP operations and result fidelity

Date: 2026-10-27

Status: approved and implemented; release delivery is tracked separately in the implementation plan.
Baseline: main `69aa7842709db96c581ab4790bdf4be1d7da09ec`, released as 1.10.45.
Target: 1.10.46, subject to all source and unified release gates passing.

## Scope and architecture

This batch covers reopened #126 and new #129–#133 in gsmlg-opt/backplane.
The current checkout is clean main. Work stays in this checkout without creating
branches or worktrees. Only this batch's coherent commits may be published.
No deployment, downstream dependency upgrade or managed-service restart is included.

| Issue | Owning boundary | Required result |
| --- | --- | --- |
| #126 | Runtime reconciliation/archive codec | Preserve committed ordinary Runtime Error values through archive validation and authoritative restore |
| #129 | Runtime Codex.Web result union | Admit a citation-bearing answer whose body was exhausted by output budgeting |
| #130 | MCP Message encoding | Preserve namespaced request metadata in legacy and modern resource requests |
| #131 | Runtime effect and owned-request lifecycle | Cancel the exact MCP resource operation and retain truthful invocation settlement evidence |
| #132 | MCP caller-owned client API | Fetch one modern events/list page with an opaque owned handle |
| #133 | Runtime MultiAgent restore | Allow parent transfer with an idle, confirmed restored child |

The recommendation is to extend these existing owners. A generic arbitrary MCP
request API would create unnecessary method and capability policy; a host-side
workaround would duplicate Runtime ownership. Globally accepting arbitrary structs,
discarding Error causes, inventing answer text, or treating worker death as proof of
settlement would lose facts. Those alternatives are rejected.

## #126: full ordinary Runtime Error normalization

The assistant message metadata allowlist was already repaired in 1.10.44. The
reopened request supplies a separate reproduction: Evidence.public rejects the
Error struct inside a committed write_stdin/not_found tool result before the
archive reaches message validation. The earlier release therefore does not prove
acceptance of this residual case.

Add an explicit normalization branch for Backplane.AgentRuntime.Error only, before
the existing plain-map branch in codex/reconciliation/evidence.ex. Validate the
closed supported struct shape, known error class, message as nil or valid UTF-8
text and details as a map. Normalize all four fields: class, message, details and
cause. Nested values use the same depth/node/byte bounds, key ambiguity checks and
canonical JSON rules as all other evidence. Do not use Error.to_map/1: it omits
cause. Do not inspect, stringify or remove unsupported causes. Other structs and
runtime handles remain unsupported.

Portable archives contain the full canonical JSON error map; no executable struct
tag or dynamic atom creation is added. Restore still reloads the original Store
record and compares its normalized full history to the archive. It does not
reconstruct execution history from portable JSON. Thus typed Error values in the
authoritative restored run remain typed, including before a fresh followup.

Existing JSON-only archives normalize identically and retain their digests, so
schema_version remains 1. Outer schemas, exact receipt and Store revision checks,
history equality, closure eligibility and no-replay rules remain in force.

## #129: citation-only truncated answer success

Keep valid legacy results-list precedence and existing nonempty answer behavior.
Add one answer content alternative: content is exactly the empty string, citations
is a nonempty list passing the existing citation validator, and truncated is the
boolean true. No placeholder body, synthesized result rows, trimming, citation
reordering or host budgeting implementation is introduced.

For this empty-body alternative, include truncated in alias ambiguity checks and
require an unambiguous actual boolean. Existing nonempty answers retain their
current treatment of unrelated metadata. Both atom- and string-keyed answer
variants return the original complete map. Optional provider/query fields and the
whole-result external_size bound retain existing behavior. Web.search and
Web.x_search share the same contract; Services direct and Code Mode execution use
that existing public boundary.

The positive reference case is pinned OpenClaw
488631c18fae7cc541ba8fc8beff6cbb0438787b: 20 ordered valid HTTPS citations of
1000 UTF-16 units consume its 20000-unit budget and leave empty content with
truncated:true. Runtime admits that projection; it does not reproduce the host's
budget policy or implement a provider.

## #130: preserve nested MCP request metadata

Legacy Message.@progress_params currently declares a closed _meta object containing
only progressToken. Peri's encoder projects away all namespaced metadata, while
modern requests bypass that legacy projection.

Use the installed Peri nested schema's additional_keys:any option on this shared
_meta object. Preserve the existing optional progressToken string/integer type.
Do not make the entire request permissive or replace _meta with an unvalidated map.
Applying the fix to the shared schema avoids duplicating the same metadata defect
in tools/prompts and other methods that already share progress metadata.

Client.Metadata.attach, modern reserved field precedence, progress option override,
key normalization and JSON encoding remain the existing authorities. Add no new
namespace/size restrictions, transport, ownership tracker or fallback behavior.

## #131: caller ownership and verified cancellation settlement

Source inspection confirms two independent defects. DynamicRuntime runs resource
callbacks synchronously in its retained GenServer, so that GenServer owns the MCP
handle instead of the Conversation effect caller. Conversation.stop also treats
every remaining active tool as uncertain after killing its worker. Fixing only the
first defect cannot satisfy actual managed-child interrupt/parent-continuation
acceptance. Current MCP local:cancelled additionally does not prove worker DOWN.

Three approaches were considered: caller execution alone fixes owner-down delivery
but cannot confirm aggregate cleanup; a generic cancellation broker for arbitrary
adapters would widen authority and scope; caller execution plus an explicit native
resource helper provides the narrow verified path. Select the third.

### Compatible ownership and opt-in helper

For only list_mcp_resources, list_mcp_resource_templates and read_mcp_resource,
DynamicRuntime.call performs a short immutable adapter-configuration lookup, then
executes the existing adapter callback in the actual calling process. Tool-search
publication and plugin-install state remain in their serialized manager path.
Existing callbacks consequently own their Client.start_* handles correctly, and
abrupt owner death cancels only the exact request. Legacy callbacks retain ordinary
success/error behavior; they do not gain confirmed aggregate interruption without
an observed cleanup report.

Add this explicit public helper for adapters opting into verified interruption:

```elixir
DynamicRuntime.resource_request(operation, fn ->
  Client.start_read_resource(client, uri, opts)
end)
```

It returns the existing ordinary MCP success/error for host conversion. Opt-in
asserts that this callback's cancellable work consists of this one owned resource
request, without additional untracked effects. The helper registers the exact
invocation with DynamicRuntime before invoking the starter, receives a fresh
registration/cancellation identity, runs the finite starter in the same caller,
attaches the original owner-bound handle and waits for completion or cancellation.
No consumer constructs private handles or sends private manager messages.

DynamicRuntime retains operation identity, caller monitor and pending cancellation;
it never executes the adapter. Cancellation during MCP registration stays pending
and is applied as soon as the handle is returned. A stuck starter consumes the same
remaining cleanup budget; at expiry its caller is terminated and outcome remains
uncertain. Registration absence or request_not_found never proves non-dispatch.

### MCP cancellation observation and actual local retirement

Add a cancel-aware Client.await_resource_request/3, leaving /2 unchanged. Its
explicit cancellation-control option is used by the native helper: a fresh opaque
control identity binds one owner and request, and the library's control operation
signals that wait with reason and the existing remaining cleanup budget. Keep
control construction/signalling behind supported MCP functions used by the helper,
not exposed raw process messages. The owner receives the signal and invokes
cancel_resource_request itself, retaining the current ownership check. A distinct
cancellation return carries the report rather than pretending it is a normal result.
Observation timeout continues not to cancel.

Preserve existing local:cancelled as logical request cancellation. Add separate
local_cleanup:confirmed|uncertain evidence for exact dispatch/resolver workers and
request-scoped transport cleanup barriers. Monitor before signalling and observe
real DOWN or already-established termination evidence. For HTTP, await the original
request-specific lifecycle completion; a killed dispatch Task alone is insufficient.
Do not close a shared client/connection to obtain proof.

One finite remaining cleanup budget covers local retirement and notification
observation. Report original request identity and distinguish request delivery
(not_sent/accepted/unknown), notification delivery
(accepted/not_needed/unsupported/failed/timeout) and remote:unknown. A transport's
notification acceptance is not remote rollback. Verified local retirement can
succeed despite a failed cancellation notification; it cannot succeed while local
workers/barriers are unconfirmed. request_not_found requires exact previously
observed terminal evidence to reconcile, rather than interpreting absence as success.

### Conversation, Store and nested Code Mode

Extend the existing ToolEffects.cancel boundary with a verified cancellation
assertion, and add a narrow Codex.Backend cancellation route to the helper's exact
registration. Existing :ok is an acknowledgement, never verification. Conversation
retains the original admitted operation/backend context rather than rebuilding an
operation from a newer catalog.

Cancellation first fences new direct/nested dispatch and continuation, invalidates
execution timers, and fixes one stop generation and cleanup deadline. Preserve all
active identities, owned Tasks and in-flight Store commits. Asynchronously request
eligible cancellation while callers remain alive; the mailbox must still process
registration, cleanup reports, DOWN and Store ACK. Accept only matching reports,
observe actual effect Task termination, complete existing Session/Registry cleanup,
then compare against post-ACK Kernel.cleanup_requirements(run). The existing exact
settled requirements boundary remains authoritative.

At the deadline, kill remaining owned Tasks and retain unconfirmed obligations.
Do not renew budgets, restart requests or infer acknowledgement from resulting DOWN.
Completion/cancellation races decide once per registration. A real completion that
won may cover its exact obligation, but cannot resume Provider/tool execution after
the stop fence. Old registrations, stop generations and late results cannot mutate
a replacement operation. Missing cancellation or Store ACK remains recovery-required.

Verified assertions use strict identity equality across run/incarnation, logical
turn, step/attempt/invocation, enclosing invocation, tool/catalog revisions, exact
arguments and collaboration/Session binding when present. They additionally bind
the fresh helper registration, original MCP logical request/live client incarnation
and stop generation. PIDs/refs/live tokens stay in process state. Persist bounded
JSON identity/report evidence as an optional validated part of existing cleanup
input/outcome/journal. Do not create a second settlement ledger or a fabricated
successful tool_completed result for cancelled work.

Direct calls need their exact request evidence, effect Task DOWN and existing
resource cleanup. Nested Code Mode also needs the enclosing admission fence, exact
evidence for every outstanding nested invocation and real Deno worker cleanup via
the existing Registry/CodeMode worker path. Compose these into an assertion for
the enclosing exec/continuation obligation. Inner resource cancellation alone does
not settle outer exec; Deno termination alone does not settle an inner request.
Unsupported/uncertain nested work keeps the composite uncertain. General plugin,
command and Provider cancellation remain conservative. Do not relax MultiAgent
safe_replacement; it succeeds only when authoritative child cleanup actually settles.

Expected code scope is DynamicRuntime and a focused helper if useful; ToolEffects,
Codex.Backend, Conversation stop state, Kernel's optional retained cleanup evidence,
narrow Code Mode cancellation composition, and MCP owned-request/transport cleanup.
Store and ResourceRegistry ownership remain unchanged.

The published Runtime dependency on backplane_mcp_protocol must become
`~> 1.10.46`: the current 1.10.44 floor does not provide the new cancel-aware
wait/control functions. Include apps/backplane_agent_runtime/mix.exs in scope and
qualify the standalone package against that declared floor. The release workflow
must publish MCP before Runtime consumers as it already does.

## #132: finite caller-owned event descriptor listing

Add Client.EventRequest as a dedicated opaque handle using the existing internal
OwnedRequest machinery, alongside ToolCall and ResourceRequest. Public APIs:

```elixir
Client.start_list_events(client, opts \\ [])
Client.await_event_request(handle, timeout \\ :infinity)
Client.cancel_event_request(handle, reason \\ "client_cancelled", opts \\ [])
```

Support the existing options `:cursor`, `:meta`, `:progress`, `:timeout` and
`:registration_timeout`, with the same finite timeout defaults and validation.
Register exactly one events/list request; preserve opaque cursor. Await returns
the existing `{:ok, Response.t()}` shape with the whole Response.result unchanged,
without filtering or reshaping
events, descriptions, delivery values, boolean/object schemas, nextCursor or extra
public fields. Do not auto-page.

Registration must atomically check the current Client is ready, is negotiated as
modern 2026-07-28 and advertises the events capability by key presence. Missing
capability returns existing MCP `Error.protocol(:method_not_found, %{method:
"events/list"})`. Not-ready or legacy mode returns MCP
`Error.transport(:unsupported_operation, ...)` with a stable reason for this new
API. Preserve existing connection_closed precedence for a sealed connection.
Check these conditions before creating an operation timer or retaining request
registration; never switch versions or fall back. Use existing get_protocol_info for host source
inspection; add no parallel discovery snapshot API. Add events/list to the modern
method profile only, with no new legacy method branch or MRTR allowlist expansion.

The pinned OpenClaw sources are src/agents/mcp-event-request.ts and
src/gateway/server-methods/mcp-events.ts at 488631c18fae7cc541ba8fc8beff6cbb0438787b.
They require modern metadata/Mcp-Method and capability key presence. Host webhook
filtering and catalog projection are separate policy. This feature implements no
webhook subscription, inbound delivery, scheduler, server catalog or automatic
server capability advertising. Because the modern method profile is shared with
Server.Modern.Executor, also require the events capability for server dispatch of
events/list. A server without it returns method_not_found without invoking its
callback. A server that explicitly advertises it can use the existing generic
callback; this batch supplies no catalog implementation.

Reuse exact owner/client incarnation validation, two-phase registration, finite
deadlines, unrelated-request isolation and cancel reporting. An await observation
timeout remains nonterminal and distinct from cancellation.

## #133: retain the validated restored-child snapshot

Archive.restore already loads the authoritative terminal record, verifies the exact
archive, admission and retirement receipt, and returns material.snapshot. The
MultiAgent imported row discards it, leaving pid:nil and snapshot:nil; the normal
transfer gate then cannot inspect that row.

Store material.snapshot and its existing snapshot_identity in the imported row.
Use the existing transfer_snapshot and transfer_ready checks. Do not fabricate a
new cleanup receipt or snapshot, create a child Session, prepare child IO, invoke
a Provider, or force an unwanted followup to make parent transfer succeed.
Repeated/stale restore and archive identity validation retain their existing rules.
A deliberate later followup still requires fresh admission/run/binding and uses
the existing restored request and history path.

## Verification and release acceptance

Run focused regression checks first, then integrated source gates on the exact
committed SHA. Keep Mix/devenv builds serialized; preserve initial failure evidence.
The verification scope contains functional lifecycle/codec/protocol/result checks,
not new security, permission, authentication or sandbox features/tests.

- #126: real ordinary native Error followed by successful direct/real-Deno
  continuation; receipt-bound export, JSON roundtrip, restore and explicit fresh
  followup. Preserve full normalized error fields, assistant metadata, exact history
  digest and original Store history. Verify independent producer/consumer BEAM
  restoration without Provider/tool execution during import. Retain unsupported
  value rejection rather than stripping fields.
- #129: complete 20-citation reference success case through public search/x_search,
  direct and real-Deno model-visible result, persistence and replay. Check original
  body, ordering, truncation marker and whole-result budget behavior remain intact.
- #130: encoder and real owned-resource HTTP/legacy SSE fixtures retain nested
  Unicode metadata, cursor/URI, progress token and ordered results across
  list/template/read. Preserve existing progress-token validation.
- #131: original public actual-caller death probe for all three resource methods;
  unrelated pending request and subsequent request succeed on the same client with
  one initialization. Actual managed-child interrupt_agent succeeds and parent
  continues with retained Session/client, through direct and real-Deno nested paths.
  Cover cancellation during registration/wait, completion races, stale generations,
  repeated cancellation, cleanup timeout, lost cancellation/Store ACK and real worker
  DOWN. Legacy adapters gain correct ownership but retain uncertain cleanup without
  verified reports. Eligible official-package consumers adopt the helper before
  claiming confirmed interruption. No global client cancellation or remote rollback
  claim; verify exact inner and enclosing obligation coverage.
- #132: real modern HTTP discovery and exactly one events/list page, raw schemas,
  metadata/header, operation/registration deadlines, nonterminal await timeout,
  owner exit, exact cancellation and unrelated request survival. Capability and
  protocol negotiation remain explicit; a modern server without events does not
  invoke a callback for the new method.
- #133: restored settled child is immediately transfer-ready; a real parent-only
  turn completes/detaches with no child work. Include an independent cold-BEAM
  parent-only case and retain explicit fresh followup coverage.

Required source gates include warnings-as-errors compilation, formatting, strict
Credo, configured Dialyzer, workflow contract tests, owning app suites, standalone
package qualification and applicable native CI matrices. Record out-of-scope
failures and stop only affected work without unrelated repairs.

Publish through the existing unified release workflow only after all required
exact-SHA source CI passes and main/remote are clean and converged. Recheck that
1.10.46 is unoccupied. Preserve the workflow's artifact stamping and MCP-before-
Runtime publication dependency. Do not create a tag as a substitute for the release.
Verify all five exact official Hex versions in a fresh consumer, checksum/source
equality, versioned HexDocs, six release archives/checksums, qualification manifest,
compiled production source/version, packaged native helper probes and GHCR labels
and version/latest digest. Close issues only after official consumable verification;
downstream upgrades and production acceptance remain separate.
