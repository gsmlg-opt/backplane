# Request ownership and cleanup

Resource requests have additive caller-owned handles:

```elixir
{:ok, listing} = Client.start_list_resources(client, cursor: "next-page")
{:ok, templates} = Client.start_list_resource_templates(client)
{:ok, reading} = Client.start_read_resource(client, "file:///example.txt")

{:ok, response} = Client.await_resource_request(listing, 1_000)
{:ok, report} = Client.cancel_resource_request(reading, "host_cancelled")
```

The owner PID and client process incarnation are fixed. Registration is
acknowledged before dispatch, with `registration_timeout: 5_000` by default;
`:timeout` remains the finite end-to-end operation budget. List cursor, request
metadata and progress options retain their existing protocol-era behavior.
Actual `resources/list`, `resources/templates/list` and `resources/read` methods
retain their `Client.Response` envelopes, pagination and ordered text/blob data.
The logical handle follows MRTR continuations across fresh wire IDs. Existing
synchronous resource APIs and the public `Client.ToolCall` contract are unchanged.

An await timeout observes no result and leaves the operation active. A later
await can receive its result once. Cancellation settles only this owner's
operation and its dispatch/resolver workers and timers. It reports local
settlement separately from transport acceptance and cancellation-notification
delivery; `remote: :unknown` never promises remote execution rollback. Owner
death follows the same local settlement path without closing the shared client.

## Owned connections

Hosts that own a finite activation can opt into `one_shot: true` when starting
the Client tree. Both child specifications and the outer Client specification
are temporary in this mode, so a failure cannot launch a replacement executable
under the same activation. Other clients retain their existing restart policy.

`Client.close_connection(supervisor, timeout: 5_000)` collects a transport report,
settles owned client workers, then observes supervisor termination using one
remaining budget. Its result keeps these obligations separate and is confirmed
only when all are confirmed. `transport.close(pid, timeout: milliseconds)` and
`transport.cleanup_status(pid)` provide retained version-1 reports. Reports move
from `phase: :active` through `:closing` to `:closed`; pending work and missing
evidence cannot confirm cleanup. Transport reports remain inspectable until the
owning host tears down the connection. Repeated transport close observes the
stored outcome and does not repeat cleanup. A later close against an already
dead tree without a retained report is unconfirmed.

`Client.close/1` and `transport.shutdown/1` remain best-effort APIs. Process DOWN
alone is insufficient evidence of external resource cleanup. A Session host
must retain the explicit result before final process teardown when it needs to
report that result later.

## Verified stdio

Build this optional capability explicitly on native Linux or macOS:

```sh
mix backplane.mcp.stdio.build
```

Use `{:stdio, command: executable, args: args, cleanup: :verified}` for an owned
connection, together with `one_shot: true` and a host `activation_id`. Normal
compilation and ordinary direct stdio need no C compiler. Verified activation
fails explicitly before target launch if its helper is missing or unsupported;
it never falls back to an unobservable direct launch. Hex ships the C11 source
and explicit build task; a target-native executable is assembled into gateway
OTP releases and Docker images.

The guardian is the target's actual parent. It relays typed bounded packet4 data
frames, closes target stdin, allows finite EOF grace, then sends TERM and KILL
only while that exact direct child is still unreaped. Confirmation requires the
correlated receipt with actual `waitpid`/pipe-close facts and the guardian's
successful Port `:exit_status`. A nonzero target exit can still confirm released
resources. Lost receipts, helper loss, premature Port closure and deadline expiry
retain partial facts and remain unconfirmed.

The declared scope is the direct child, guardian and guardian-owned local pipes.
Detached descendants, inherited endpoints held by descendants, remote work and
other side effects are outside that scope. Cleanup does not wait indefinitely
for a descendant to close stdout. It provides no process-tree guarantee.

## HTTP resources

HTTP uses `http_fetch ~> 0.21.17` through the neutral private `HTTP` boundary.
There is no required Finch/Mint dependency or package-owned Finch pool. Buffered
requests, legacy SSE, Streamable HTTP, modern streams, JWKS and introspection use
the same Fetch construction and preserve the existing protocol/authentication
policy. Manual redirects retain the maximum three 307 hops, relative Location,
method/body and origin checks before configured headers are sent.

`request_timeout` maps to the total Fetch request deadline; `receive_timeout` to
stream inactivity, including existing `:infinity` support; `connect_timeout` to
connection establishment. Enclosing operation deadlines bound applicable finite
timeouts. SSE reconnection options remain in the MCP coordinator. Supported
Fetch options and rejected legacy pool options are documented by `HTTP`.

Each allocation is registered before Fetch begins. The original Promise's
request-completion handle is handed off before headers/body await, and every
redirect hop remains tracked. Close waits on actual `HTTP.RequestCompletion`
barriers and owned workers. Missing or unsupported evidence remains unconfirmed.
During a live connection, a completed request handle is compacted only after
its original request-completion barrier returns `:ok` and its owning worker's
actual DOWN is observed. Active workers retain all redirect hops. Missing,
pending, unsupported or lost evidence remains individually tracked. The most
recent 64 confirmed resource receipts remain inspectable; older confirmed
receipts become activation-scoped aggregate resources with IDs
`{activation_id, "confirmed_history:<scope>"}` and
`evidence.aggregate: true` and an exact `evidence.confirmed_count` per scope.
These aggregates preserve confirmed history without retaining old request
handles or worker processes. Resource counts include aggregate counts rather
than simply counting report entries.

A single supervised worker processes completion checks or close barriers at a
time. Owner loss uses the same sequential abort queue under one finite deadline,
not one process per historical request. Monitor and per-worker request indexes
avoid rescanning completed history. Close freezes both recent and aggregate
evidence, and late completion cannot improve the retained result. Cleanup-worker
resource IDs use `{activation_id, task_reference}`, preserving the same accepted
identifier shape as ordinary worker resources.

Only owned request resources are aborted; shared pools and other MCP clients
remain available. A remote session DELETE is a separate best-effort delivery
fact and cannot prove local resource release or remote rollback.
