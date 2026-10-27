# MCP dependency composition, resource ownership and plugin cleanup

Date: 2026-10-27

Status: proposed; not approved or implemented. This document records source
investigation and proposed public contracts, not executed runtime acceptance.
Baseline: `main` at `fd31834b178e40a0ee335fc9c2872fa6dd8182ce`, published as
1.10.43. It covers [#120](https://github.com/gsmlg-opt/backplane/issues/120),
[#122](https://github.com/gsmlg-opt/backplane/issues/122) and
[#123](https://github.com/gsmlg-opt/backplane/issues/123) in the proposed 1.10.44
batch. The coordinating release design owns approval and delivery.

## Problem and ownership

`backplane_mcp_protocol` requires Finch and starts its pool unconditionally.
HTTP requests, both SSE implementations, modern subscription streams, JWKS and
introspection use Finch directly. A standalone server consumer therefore still
installs Finch/Mint even when it needs no Finch client.

Only `tools/call` has an acknowledged caller-owned asynchronous handle. The
resource list, template list and read APIs synchronously wait for an internally
assigned request ID. Their callers cannot cancel exactly their own pending call
through the supported handle lifecycle while retaining a shared connection.

`Plugins.Session` synchronously executes adapter calls in its mailbox and
discards adapter stop errors in `terminate/2` and failed catalog preparation.
The default `Plugins.MCP.stop/1` turns every supervisor-stop exit into `:ok`.
Consequently a ResourceRegistry callback can report confirmed retirement while
the adapter explicitly reports failure and retains its connection process.

Keep protocol requests, wire IDs and transport resources in
`backplane_mcp_protocol`. Keep one immutable installation's per-run activation,
catalog and cleanup coordination in `backplane_agent_runtime/Plugins`.
ResourceRegistry remains the caller's resource-retirement authority. Do not
create a global plugin service, a second host request tracker, a gateway resource
subsystem or a circular dependency from MCP Protocol to Agent Runtime.

## Chosen approach and alternatives

Migrate package HTTP implementations to the already resolved, published
`http_fetch` 0.21.17 API. Reuse its request-scoped completion barrier for truthful
local HTTP cleanup. Generalize the existing owned-tool request machinery
internally and expose dedicated additive resource APIs. Give Plugin Session an
explicit retained close report and responsive worker-based coordination.

Making Finch optional could satisfy a narrowly server-only composition, but
would require conditional implementations for every Finch-dependent module and
leave HTTP cleanup without the available Fetch completion contract. Splitting a
new client package would add a distribution boundary to an otherwise compatible
repair. Neither is selected. Removing Finch from this package does not promise
to remove independent Finch paths from the whole Backplane umbrella.

Resource calls must retain their actual protocol methods. Encoding them as tools,
using global cancellation or exposing private wire IDs would duplicate or evade
existing lifecycle ownership. Merely changing `terminate/2` cannot return cleanup
evidence to its caller, and a supervisor DOWN does not establish OS-child exit.

## #120: HTTP dependency and compatibility contract

Replace the mandatory `{:finch, "~> 0.19"}` dependency with
`{:http_fetch, "~> 0.21.17"}` and remove the package-owned Finch child.
`http_fetch` starts its own dependencies through its application contract; MCP
must not manually start, stop or claim ownership of shared HTTP pools. Preserve
the optional WebSocket dependency and the existing protocol, validator and
operation supervisors.

Use the existing private `Backplane.McpProtocol.HTTP` boundary for a small neutral
request representation and response maps containing `status`, ordered `headers`,
`body` and optional `trailers`. No Finch struct or type reference may remain in
the package's production source, application specification or required dependency
graph. Migrate its test/conformance HTTP callers as well; a successful umbrella
build with Finch available cannot prove standalone compatibility.

Buffered HTTP, legacy SSE, Streamable HTTP and modern subscription streaming use
the same Fetch request construction, option translation and cancellation resource
registration. JWT JWKS and introspection keep their existing status handling,
JSON validation, timeout and error contracts while using that boundary. Do not
change token, authentication, TLS or authorization policy.

Fetch uses manual redirects. Retain the current maximum of three 307 redirects,
relative Location resolution, method/body preservation and configured origin
check before every hop, before sending configured headers. Do not enable Fetch's
automatic redirects, implicit retries or a different protocol fallback policy.
Preserve current legacy/modern request metadata, mirrored routing headers,
session handling, fresh header providers, content-type checks and result/error
normalization. Stream chunks continue through the existing SSE parser in order;
retain its bounds, terminal behavior and reconnect policy.

Document the compatibility mapping:

| MCP HTTP option | Fetch mapping |
| --- | --- |
| `allowed_origin` | MCP's existing per-hop origin check; never passed as an ignored Fetch option |
| `request_timeout` | Total Fetch request timeout, bounded by the remaining operation deadline |
| `receive_timeout` | Stream inactivity timeout, including `:infinity` where already supported |
| `connect_timeout` | Finite connection-establishment limit, also bounded by an enclosing deadline |
| SSE reconnection/backoff options | Existing MCP SSE coordinator, outside Fetch options |

The default HTTP version and TLS backend follow Fetch's existing HTTP/1 and OTP
TLS defaults. Explicit supported Fetch options must be documented and validated;
do not silently accept Finch pool/connection options that no longer have a
meaning. Reject unsupported legacy Finch-only options with a structured
configuration diagnostic rather than silently changing their behavior. Any
additional compatibility mapping discovered during implementation must preserve
the stated transport semantics and be documented before integration.

For each hop, capture `HTTP.Promise.completion/1` from the original Promise,
before awaiting headers or consuming a streamed body. Retain completion handles
for all hops until their local cleanup is confirmed. Use the existing
`HTTP.RequestCompletion.abort_and_await/2` or `await/2` with the single remaining
close budget. The published barrier supports the chosen manual-redirect HTTP/1
and HTTP/2 TCP/OTP-TLS paths. An unsupported completion mode, missing handle,
lost worker evidence or `cleanup_unconfirmed` remains unconfirmed. Do not treat
Promise completion, an aborted controller or a stream PID's DOWN as equivalent.

A connection-owned task is registered before allocation; it publishes its
request completion handle to its transport coordinator before blocking on the
response. If allocation or this handoff is interrupted, its obligation remains
uncertain. All send/stream/body workers run outside the transport mailbox so
close/status can progress during blocked network work. A transport's close
aborts only its own request/stream handles; healthy shared pool connections and
other MCP clients remain available. Confirmation concerns local request-resource
release or pool return, never remote execution rollback.

## #123: caller-owned resource APIs

Add these dedicated public APIs alongside the unchanged synchronous APIs:

```elixir
Client.start_list_resources(client, opts \\ [])
Client.start_list_resource_templates(client, opts \\ [])
Client.start_read_resource(client, uri, opts \\ [])
# => {:ok, Client.ResourceRequest.t()} | {:error, MCP.Error.t()}

Client.await_resource_request(handle, timeout \\ :infinity)
# => {:ok, Client.Response.t()} | {:error, MCP.Error.t()}

Client.cancel_resource_request(handle, reason \\ "client_cancelled", opts \\ [])
# => {:ok, cancellation_report} | {:error, MCP.Error.t()}
```

List APIs accept the same cursor, metadata, progress and operation-timeout options
as their synchronous counterparts. Read accepts the same URI and other current
options. All three add `registration_timeout`, defaulting to the existing tool
handle's finite 5,000 ms. Cancellation accepts the same finite
`notification_timeout` and default as `cancel_tool_call/3`.

`ResourceRequest` is opaque and binds one client process incarnation, the caller
PID, a stable logical request ID and an unguessable reply reference. It is not a
wire ID or transferable ownership token. Do not change the existing public
`ToolCall` struct, API return values or mailbox behavior. Share an internal
owned-request implementation through type-specific facades rather than copying
independent request trackers or naming resource operations `tools/call`.

Registration is acknowledged before activation. The registration deadline bounds
that handshake; the existing finite operation deadline bounds dispatch,
response, any supported input resolution and continuation. Dispatch uses a
supervised worker outside the client mailbox. If registration observation times
out or the owner dies, abandon the exact logical operation and prevent later
activation. Preserve the existing two-phase handle lifecycle and its delivery
uncertainty when cancellation races a transport send.

Preserve the real methods `resources/list`, `resources/templates/list` and
`resources/read`, their `Response` envelopes and protocol-specific normalization.
Keep `nextCursor`, text/blob content order, URI, MIME and other supported metadata
unchanged. Existing MRTR support, reserved metadata rules, progress correlation
and absolute operation deadline apply equally. A continuation can replace its
wire ID while retaining the same owner and logical handle.

An await timeout is an observation failure, not terminal cancellation. It does
not remove the pending request; a subsequent await may observe the result. The
successful mailbox result remains a one-time receive, consistent with ToolCall;
this is not a new durable result cache or cross-BEAM handle.

Cancellation first settles that exact pending operation locally and stops its
owned dispatch/resolver workers, timers and progress callback. It then attempts
bounded protocol cancellation if the active protocol supports it. Reuse the
existing report fields and meanings:

```elixir
%{
  local: :cancelled,
  request_delivery: :not_sent | :accepted | :unknown,
  notification_delivery: :not_needed | :unsupported | :accepted | :failed | :timeout,
  remote: :unknown
}
```

`accepted` reports local transport acceptance only. Owner death invokes the same
local settlement and best-effort bounded notification without requiring a live
owner to receive it. Cancellation after a terminal result retains the existing
request-not-found outcome; it does not invent a replay-safe cancellation receipt.
One caller's settlement never closes a shared client, cancels another request or
tears down global HTTP resources. Late responses cannot settle the old handle
again or affect a newer request.

## #122: Plugin Session close and status

Add `Plugins.Session.close(session, opts \\ [])` and
`Plugins.Session.cleanup_status(session)`. The Session retains the same per-run
and immutable installation ownership. It owns a Task.Supervisor for adapter
activation, tool-call and cleanup workers; its mailbox never blocks inside an
adapter call or stop callback. Preserve `start_link/1`'s ready/partially-available
observable behavior using a bounded activation handshake, with the Session
coordinator alive and tracking obligations during activation.

Before an activation starts, record a unique `activation_id` and component
identity. After `adapter.start/2` succeeds, acknowledge the returned connection
into Session state before catalog preparation. A catalog failure removes that
component's callable tools and initiates one cleanup attempt, retaining both
the activation failure and cleanup result. Skills and other healthy components
remain available. A failed or lost activation that might have allocated resources
remains an explicit uncertain obligation; it is not omitted from aggregation.

The lifecycle is `active -> closing -> closed`. Closing immediately fences new
catalog/tool admission for this Session, retains already admitted operation
identities, cancels/settles its owned calls and begins bounded connection cleanup.
Read-only package data and cleanup inspection remain available. An in-flight call
that loses its execution receipt is uncertain, regardless of connection teardown.
Connection cleanup cannot rewrite a tool's prior unknown outcome into success.

The first close allocates a stable `close_id` and one finite
`cleanup_timeout` (default 5,000 ms, validated using the existing Runtime finite
cleanup range). All components share this absolute budget; do not grant a fresh
full timeout to each serial connection. Concurrent cleanup workers are bounded
by the package's finite connection inventory. The caller's optional `timeout`
bounds observation only and does not cancel the coordinator's close. Repeated
close joins or returns the stored result and never re-executes an uncertain stop
callback or extends its original deadline.

`close/2` returns `{:ok, report}` when a report is observed, including an
unconfirmed final report. `cleanup_status/1` returns `{:ok, report}` promptly
during active, closing and closed states. An observation timeout returns a
structured error identifying the Session and close ID when known, and explicitly
does not assert a terminal cleanup outcome.

The report contains:

```elixir
%{
  close_id: close_id_or_nil,
  run_id: run_id,
  plugin_id: plugin_id,
  release_id: release_id,
  artifact_digest: artifact_digest,
  phase: :active | :closing | :closed,
  outcome: :pending | :confirmed | :unconfirmed,
  components: %{
    server_name => %{
      activation_id: activation_id,
      outcome: :pending | :confirmed | :failed | :uncertain,
      activation_error: error_or_nil,
      cleanup: adapter_result_or_nil
    }
  }
}
```

Each connection's report identifies its actual activation/transport generation
and owned resource scope. Preserve original structured adapter failure facts and
partial confirmations through existing bounded Runtime error/public diagnostic
representations, without copying credentials, package environments or arbitrary
exception state into reports. Empty/no-allocation components are distinguished
from missing evidence. Aggregate confirmation requires confirmation of every
owned obligation; a worker timeout, DOWN, unexpected return, missing receipt or
failed callback is never silently successful. A later supervisor DOWN does not
erase the original failure.

Maintain legacy custom `adapter.stop/1` support. Exact `:ok`, `:done` and explicit
`{:ok, :confirmed | :released | :done}` are documented confirmations of that
adapter's declared owned scope. Errors remain failed; other results and lost
workers remain uncertain. A new default adapter's rich transport report is
validated explicitly, not accepted merely because it is `{:ok, map}`.

`stop/1` first executes or observes this same close. Only aggregate `:confirmed`
permits returning `:ok` and terminating the Session coordinator. Otherwise return
`{:error, %Error{class: :unknown_outcome, details: ...}}` with the retained close
identity/report and keep the fenced Session available for inspection. This keeps
the existing ResourceRegistry cleanup callback useful without weakening
`ResourceRegistry.safe_cleanup/1` to accept arbitrary success maps. Once close is
confirmed, stop does not call adapters again. Process termination without an
observed close does best-effort cleanup only and cannot manufacture a receipt.

Reports are retained by the live Session, not a new database or crash-recovery
service. Hosts must persist the returned evidence through their existing registry
or lifecycle adapter when required. Repeated status/close is observation, not an
effect-retry or reconciliation API. No automatic replay of failed or uncertain
cleanup, installation or tools is introduced.

### Default MCP connection closure

Extend the default connection record with its supervisor, client, transport and
activation identities. Plugin-owned client trees opt into `one_shot: true` at
construction: the client and transport children, and the outer Client child spec
when used under a supervisor, use `restart: :temporary`. A dead child cannot
silently launch a new executable under the same activation. Record/monitor child
loss even when the supervisor itself survives. Other ordinary MCP clients keep
their current restart behavior. Do not change restart policy only when close
begins; that leaves an earlier replacement race. Explicit close programmatically
terminates owned children after evidence collection without invoking replacement.

Add an optional transport `close(transport, opts)` callback returning a retained,
typed local cleanup report and a responsive `cleanup_status/1` callback. Keep
existing `shutdown/1` and `Client.close/1` as their current best-effort APIs;
neither acquires an implied confirmation guarantee. A bounded
`Client.close_connection(supervisor, opts \\ [])` orchestrates owned client tasks,
transport admission/cleanup and supervisor teardown, returning their separate
outcomes. Missing optional callbacks mean unconfirmed closure, not success.

For these APIs, `timeout` is one positive finite cleanup budget, defaulting to
5,000 ms, with the coordinator passing only its current remaining allowance.
Transport close returns `{:ok, transport_report}` for an observed report, even
when unconfirmed; invalid input or inability to observe a report returns a typed
MCP error. The retained transport report has this versioned shape:

```elixir
%{
  version: 1,
  close_id: close_id,
  activation_id: activation_id,
  transport: :stdio | :sse | :streamable_http,
  phase: :closing | :closed,
  outcome: :pending | :confirmed | :unconfirmed,
  resources: [%{id: resource_id, scope: declared_scope,
                 outcome: :pending | :confirmed | :failed | :uncertain,
                 evidence: bounded_facts, error: structured_error_or_nil}],
  remote: %{outcome: :unknown, session_delete: separate_delivery_result_or_nil}
}
```

Resource IDs are activation-qualified stable identifiers. Their scopes identify
request resources, direct-child/guardian/pipes or owned BEAM infrastructure;
resource evidence describes actual observed facts, not inferred remote success.
`cleanup_status/1` returns the same report without re-running cleanup. The
connection result adds client-worker and supervisor outcomes and is confirmed
only when they and the transport are all confirmed. A report still closing is
observation of pending work, never a confirmed return from `Plugins.MCP.stop/1`.

The default plugin adapter consumes that explicit result. It must not catch all
exits and return `:ok`. Transport, client-worker and supervisor confirmations are
separate obligations. Read the transport report before final process teardown;
retain it in the Plugin Session. Repeating a close against an already dead
connection without a retained report returns uncertainty, never inferred success.
HTTP/SSE closure uses the Fetch completion barriers above, including all retained
stream and redirect-hop resources. A remote legacy session DELETE has a separate
delivery result and cannot prove remote tool rollback or local socket cleanup.

The stdio implementation must add actual direct-child and helper exit evidence,
as specified in the following native ownership section. Port or transport DOWN
alone is insufficient. Existing best-effort shutdown remains callable on a
transport that cannot provide the stronger evidence.

### Native stdio ownership and build boundary

Add a small package-owned POSIX pipe guardian with an explicit
`mix backplane.mcp.stdio.build` task. It is separate from Runtime's Linux PTY
helper and does not add a dependency on Runtime. Verified stdio supports Linux
and macOS in this release; it is not a PTY and does not add terminal semantics.
The existing ordinary Client STDIO path remains the default outside Plugin
Session. Plugin-owned stdio uses the verified mode and one-shot tree. Missing or
unsupported helpers produce an explicit component-unavailable diagnostic before
launching its target; skills and other healthy components remain usable. There
is no silent fallback from verified cleanup to an unobservable direct launch.

The public verified ownership scope is exactly the target **direct child**, the
guardian and its local pipes. It does not certify arbitrary daemonized descendants,
remote work or external side effects. Report this scope in the transport receipt
and document it in Plugin Session's adapter contract. The host must separately
own any resources outside that declared connection scope; do not imply the
stronger job-control-tree guarantee of Runtime's independent PTY backend.

The guardian is the target's actual parent and owns both ends needed to forward
stdin/stdout. Use bounded typed packet4 framing for data, startup identity, close
and receipt messages; target output cannot impersonate control messages.
Preserve target JSON-RPC bytes, environment, working directory
and argument order; do not merge stderr into protocol stdout. Apply bounded
nonblocking queues so saturated output cannot prevent processing close. Require
an acknowledged guardian startup/identity handshake before admitting MCP traffic.

On close, seal data writes and close the target's stdin pipe, then allow a bounded
grace period. If still running, send TERM and then KILL within the same remaining
close budget. Signal only the exact child while it is still an unreaped child of
this guardian. Record the `waitpid` status as part of reaping before emitting the
receipt; never signal a PID after reaping or infer identity from a later `kill -0`
probe. Parentage and the unreaped child identity prevent PID reuse during these
signals without requiring Linux-only pidfds. Do not issue process-group signals
under this direct-child contract.

Do not wait indefinitely for stdout EOF after the direct child exits: descendants
can retain writers outside the declared ownership scope. Drain only within the
remaining budget, close every guardian-owned target pipe and emit a
token-correlated receipt with
the observed target status, actual reap fact and pipe-close outcomes. The guardian
then exits. The BEAM opens the helper with `:exit_status` and accepts confirmed
cleanup only after **both** a valid complete receipt and the actual successful
helper exit status are observed. This order proves target reap, local pipe release
and guardian termination. Transport/Port DOWN, a close command ACK, pipe EOF, a
child PID disappearing or helper exit alone is insufficient. A nonzero helper
status, missing/partial receipt, worker loss or deadline expiry is unconfirmed;
retain any separately observed target/pipe facts. Do not manufacture confirmation
when last-resort Port teardown loses the helper's exit evidence.

After confirmed or unconfirmed close the transport stays sealed for report
inspection until its owning coordinator stops it. Cleanup requests are correlated
to a single activation/close identity and do not launch another guardian or target.
Unexpected guardian/transport death cannot trigger replacement in a one-shot tree.
Best-effort termination may still release resources, but cannot improve missing
evidence into a confirmed close.

Package the C source, explicit build script/task and protocol version/probe with
the MCP Hex package. Do not compile from `on_load`, runtime startup or a generic
Mix application compiler. Require an explicit supported build and capability
probe before verified activation. Linux/macOS OTP release builds and Docker
builds that ship this capability invoke the same task and verify the packaged
executable. Ordinary standalone server consumers need no guardian or C compiler.
Windows/other direct STDIO consumers retain existing best-effort APIs; verified
plugin stdio on unsupported systems is explicitly unavailable in this version.

Acceptance includes real JSON-RPC stdio traffic and normal close with actual
target `waitpid` and helper exit evidence, TERM/KILL escalation, a nonzero target
exit with confirmed resource cleanup, inherited stdout held by a descendant,
blocked output with responsive close, close deadline exhaustion, lost guardian evidence,
and proof that no target replacement executes after failure or close. Verify
native protocol framing and allocation bounds, extracted Hex source build, and
Linux/macOS packaged capability probes. State which architectures actually ran;
a successful cross-build is not runtime execution proof.

## Allowed implementation and integration scope

- `apps/backplane_mcp_protocol/mix.exs`, its `lib/backplane/mcp_protocol/`
  application, HTTP/SSE boundaries, Client owned-request modules/supervisor,
  built-in plugin transports, JWT/introspection HTTP callsites and corresponding
  package documentation/tests/conformance fixtures.
- A package-owned stdio helper, explicit build task and bounded protocol fixtures
  required by the native ownership section; no dependency on Runtime's PTY helper.
- `apps/backplane_agent_runtime/lib/backplane/agent_runtime/plugins/` and focused
  Plugin Session/backend tests and public documentation. ResourceRegistry behavior
  is not broadened; its existing acceptance contract remains the integration gate.
- `mix.lock` only if adding the direct already-resolved Fetch constraint requires
  an actual scoped resolution change. Do not update unrelated dependencies.
- Required package verification/build/workflow contract changes for the new APIs
  and helper. No weakening existing release or CI checks.
- This design and its implementation plan after approval. The batch coordinator
  owns shared manifests, release assets, version stamping and Git mutations.

No downstream repository code, provider integration, deployment, global service
restart, shared test-database reset, unrelated Memory repair or new policy is
authorized by this design.

## Verification and acceptance gates

1. Reproduce #122's retained real Agent connection and explicit stop error through
   public Plugin Session and ResourceRegistry APIs. Add a second successful
   connection: only it is confirmed, the original failed result remains visible,
   registry retirement stays unconfirmed, and repeated close/status does not
   increase callback counts. Clean up only fixture-created processes afterward.
2. Exercise failed catalog preparation with failed cleanup, bounded calls and
   close/status during a blocked adapter call, worker timeout/exit, no new
   admission after close and partial activation with healthy skills/components.
3. Verify real stdio closure with actual child/helper reaping evidence and the
   native package gates below; missing/late evidence remains uncertain.
4. Use real local HTTP fixtures for legacy SSE, legacy Streamable HTTP and strict
   modern discovery, tools and resource list/template/read. Preserve pagination,
   text/blob/URI/MIME values, progress, metadata, input resolution and deadlines.
   Existing redirect/origin/auth fixture behavior must remain green after the
   migration; no new auth policy or real-provider test is required.
5. A shared client serves two independent resource owners. Cancel one, let the
   other complete, then perform another normal call on the same connection.
   Observe bounded registration while sends block, nonterminal await timeout,
   owner-death settlement and separate request/notification delivery reports.
6. Confirm HTTP/SSE close waits for actual Fetch request barriers, does not stop
   shared pools, and retains uncertain results on unsupported/lost evidence.
   Do not equate socket-worker DOWN with barrier success.
7. Build a fresh standalone server consumer using only the extracted/published
   MCP package and its required server dependencies. Resolve and inspect its
   actual dependency and started-application graphs: Finch and Mint must be
   absent. Start the MCP server and perform a local protocol request. The
   umbrella's independent Req/Finch graph is not the evidence for this gate.
8. Run owning package tests, strict compilation, formatting, Credo, Dialyzer and
   package/workflow contracts as required by the batch. Serialize shared build
   state. Then repeat the positive API/cleanup/server-composition checks against
   official Hex packages in a fresh consumer after publication.

Local fixtures establish Backplane's contracts. Synapsis resource projections and
Sigma root/managed-child plugin catalog adoption, persisted consumer replay,
production deployment and actual remote effects remain separate downstream
acceptance after the official packages are available.
