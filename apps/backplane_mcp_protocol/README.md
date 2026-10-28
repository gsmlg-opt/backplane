# Backplane.McpProtocol MCP

[![hex.pm](https://img.shields.io/hexpm/v/backplane_mcp_protocol.svg)](https://hex.pm/packages/backplane_mcp_protocol)
[![docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/backplane_mcp_protocol)
[![Hex Downloads](https://img.shields.io/hexpm/dt/backplane_mcp_protocol)](https://hex.pm/packages/backplane_mcp_protocol)

Model Context Protocol (MCP) implementation in Elixir.

## Overview

Backplane.McpProtocol is the MCP protocol app used by Backplane and is also
published on Hex. It provides client and server implementations for the
[Model Context Protocol](https://spec.modelcontextprotocol.io/) under the
Backplane.McpProtocol namespace. The package supports the modern
`2026-07-28` protocol over Streamable HTTP and stdio while preserving the
legacy initialization and session behavior required by older protocol versions.

## Owned resource and event requests

Resource operations can retain ownership in the actual caller with
`Client.start_list_resources/2`, `start_list_resource_templates/2` and
`start_read_resource/3`. Await the returned opaque handle with
`Client.await_resource_request/2`; an observation timeout leaves the request
active. Only the original owner can await or cancel it. Owner exit cancels that
request while preserving unrelated work on the shared client.

Adapters requiring interruption evidence can create a
`Client.resource_cancellation_control/0` in that same owner before registration,
then pass it as `cancellation: control` to `await_resource_request/3`.
`Client.cancel_resource_wait(control, reason, timeout: remaining_ms)` signals the
wait and acknowledges only delivery of that signal. The owner performs the exact
request cancellation and receives `{:cancelled, report}`. A control binds to one
request and cannot be reused for another. `resource_request_identity/1` exposes
the original registered identity to that owner, including after completion; MRTR
can change the current wire request ID without changing the logical identity.

Cancellation retains the existing `local: :cancelled` logical meaning. The
separate `local_cleanup` field is `:confirmed` only after actual request worker
termination and request-scoped transport cleanup are observed. HTTP/SSE use the
original request completion barriers and keep the shared connection open.
STDIO rejects expired sends and sends from terminated callers at the actual write,
then confirms a mailbox barrier after the exact dispatch workers terminate; it
keeps the shared target open and does not claim remote rollback.
Custom transports may implement the optional `cancel_request/3` callback to
provide this evidence; without it, verified cleanup remains uncertain. Notification
acceptance never proves remote rollback: `remote` remains `:unknown`.
An ordinary result that wins the race remains an ordinary result and supplies no
verified cleanup assertion.

Resource adapters that require evidence after terminal delivery must enroll before
start with `track_retirement: true`, then call
`Client.retire_resource_request(handle, timeout: 5_000)` in the original owner.
List, template-list and read still return the exact ordinary result through await;
retirement neither replays the operation nor sends cancellation for a completed
request. A live request returns `:request_not_terminal` and must first follow its
existing owner cancellation path. Even a verified cancellation report must be
followed by the distinct tracked receipt to account for all historical MRTR wires.

```elixir
{:ok, request} = Client.start_list_resources(client, track_retirement: true)
result = Client.await_resource_request(request)
{:ok, receipt} = Client.retire_resource_request(request)
# result is unchanged; only receipt.local_cleanup == :confirmed proves retirement.
```

The receipt has `schema: :resource_retirement`, `version: 1`, the original
`logical_id`, `request_id`, `client_incarnation` and `method`, ordered actual
`request_ids`, and the actual terminal kind (`:completed`, `:cancelled`, `:failed`
or `:timed_out`). `local: :retired` describes the retirement observation;
`local_cleanup` and `cleanup_evidence` independently record whether every original
dispatch/resolver worker and transport completion barrier was confirmed. Exact
HTTP/SSE pins survive unrelated traffic and MRTR continuation IDs until resolution;
STDIO uses its request barrier. `remote` is always `:unknown`.

Tracking reserves one of at most 256 entries per Client before dispatch. Overflow
returns `:resource_retirement_capacity`; entries are never evicted to admit new
work. Each tracked logical request also admits at most 256 wire obligations;
another MRTR continuation fails with `:resource_retirement_obligation_capacity`
before its dispatch or pin, while preserving the admitted inventory for retirement.
Untracked continuation behavior is unchanged. The optional tracked-start `retirement_deadline` is an absolute local
monotonic millisecond value, fixed at the earlier of that value and start plus
operation `timeout` (default 30,000ms). Registration and operation respect that
same bound. Retirement uses the earliest of this enrollment bound, its positive
finite `timeout` (default 5,000ms) and optional absolute `deadline`. No retry or
cancellation renews enrollment.

Wrong owners cannot obtain proof; foreign/stale handles, untracked requests,
consumed capabilities and expired entries return
`:resource_retirement_unavailable`. Uncertain or timed-out proof collection keeps
the obligation, pins and capacity while closing public proof availability. Expiry
triggers bounded cleanup, never a successful proof. Resolved retirement frees the
entry; owner/client lifecycle cleanup or connection teardown handles remaining
obligations. Untracked starts retain their existing retention behavior.

`Client.start_list_events/2`, `await_event_request/2` and
`cancel_event_request/3` retain a distinct opaque `EventRequest` for one raw
`events/list` page. They require a ready `2026-07-28` client advertising the
`events` capability. Cursor and descriptor order, schema booleans/objects,
`nextCursor` and extra result fields remain unchanged; no auto-pagination or
webhook execution is performed.

`event_request_identity/1` exposes the original registered Events identity to
its owner. For a controlled wait create `event_cancellation_control/0` before
starting, then use `await_event_request(handle, timeout, cancellation: control)`;
`cancel_event_wait(control, reason, timeout: remaining_ms)` signals that owner.
Events and resource controls cannot be interchanged. Controls stay bound to the
first awaited request across observation timeouts. `cancel_event_request/3`
also supports `verified: true` for current-wire cleanup evidence.

Enroll Events with `track_retirement: true` and call `retire_event_request/2`
after either ordinary terminal delivery or cancellation. Even a verified cancel
report covers only the current wire; full retirement accounts for every original
MRTR wire ID and worker. Events receipts use `schema: :event_retirement`,
`version: 1`, and the same identity, terminal, ordered inventory, cleanup evidence
and `remote: :unknown` fields described above. The original fixed enrollment
and shorter query deadlines apply. Events expiry cannot renew the cleanup budget:
expired or late-collected obligations retain their ledger entries and HTTP pins
until connection teardown, and continue consuming tracked capacity. Owner-death
collection before expiry still uses the original enrollment deadline. Resources
and Events share the combined 256-entry bound; each logical request retains at most 256 wire obligations.
Events report `:event_retirement_capacity`,
`:event_retirement_obligation_capacity` and `:event_retirement_unavailable` at
the corresponding typed boundary. Resource schemas and errors are unchanged.

```elixir
control = Client.event_cancellation_control()
{:ok, request} = Client.start_list_events(client, cursor: "opaque", track_retirement: true)
result = Client.await_event_request(request, 5_000, cancellation: control)
{:ok, receipt} = Client.retire_event_request(request)
# Publish the original terminal result only after confirmed local retirement.
```

## Installation

```elixir
def deps do
  [
    {:backplane_mcp_protocol, "~> 1.10.38"}
  ]
end
```

Inside the Backplane umbrella, use `{:backplane_mcp_protocol, in_umbrella: true}`
instead.

Version `1.6.3` is retired and predates modern MCP support. Consumers requiring
`2026-07-28` should update their dependency constraint and run
`mix deps.update backplane_mcp_protocol`. Version `1.10.12` is published on Hex
with the modern HTTP implementation.

## Quick Start

### Server

```elixir
# Define a tool as a Component (compile-time registration)
defmodule MyApp.Echo do
  @moduledoc "Echoes everything the user says to the LLM"

  use Backplane.McpProtocol.Server.Component, type: :tool

  alias Backplane.McpProtocol.Server.Response

  schema do
    field :text, :string, required: true, max_length: 150, description: "the text to be echoed"
  end

  @impl true
  def execute(%{text: text}, frame) do
    {:reply, Response.text(Response.tool(), text), frame}
  end
end

defmodule MyApp.MCPServer do
  use Backplane.McpProtocol.Server,
    name: "My Server",
    version: "1.0.0",
    capabilities: [:tools]

  # Static component registration — dispatches to MyApp.Echo.execute/2
  component MyApp.Echo

  @impl true
  def init(_client_info, frame) do
    # Legacy sessions can also register tools dynamically via the Frame:
    # frame = register_tool(frame, "dynamic_tool", description: "...", input_schema: %{...})
    {:ok, frame}
  end

  # Use init_request/2 instead for request-local modern setup.
end

# Add to your application supervisor
children = [
  {MyApp.MCPServer, transport: :streamable_http}
]

# Add to your Phoenix router (if using HTTP)
forward "/mcp", Backplane.McpProtocol.Server.Transport.StreamableHTTP.Plug, server: MyApp.MCPServer

# Or if using only Plug router
forward "/mcp", to: Backplane.McpProtocol.Server.Transport.StreamableHTTP.Plug, init_opts: [server: MyApp.MCPServer]
```

Now you can achieve your MCP server on `http://localhost:<port>/mcp`

### Client

```elixir
# Add to your application supervisor
children = [
  {Backplane.McpProtocol.Client,
   name: MyApp.MCPClient,
   transport: {:streamable_http, base_url: "http://localhost:4000"},
   client_info: %{"name" => "MyApp", "version" => "1.0.0"},
   protocol_version: :auto}
]

# Use the client
{:ok, result} = Backplane.McpProtocol.Client.call_tool(MyApp.MCPClient, "echo", %{text: "this will be echoed!"})
```

`:auto` is the default. It probes with modern `server/discover`, negotiates
`2026-07-28` when available, and falls back to legacy initialization only when
the transport provides protocol-defined evidence of a legacy peer. For
Streamable HTTP, a valid JSON-RPC `-32601 Method not found` response to the
current `server/discover` request is legacy evidence whether it arrives with
HTTP 200 or HTTP 400. Explicit version pins never downgrade. Pin a version
string when cross-era fallback is not wanted:

```elixir
protocol_version: "2025-06-18"
```

Modern HTTP requests are stateless, POST-only, and do not create an MCP
session. Legacy versions continue to use their existing initialization,
session, GET notification stream, and DELETE cleanup behavior.

### Modern HTTP wire requests

An HTTP client can discover the server directly without `initialize`:

```bash
curl --fail-with-body http://localhost:4000/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H 'MCP-Protocol-Version: 2026-07-28' \
  -H 'Mcp-Method: server/discover' \
  --data '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "server/discover",
    "params": {
      "_meta": {
        "io.modelcontextprotocol/protocolVersion": "2026-07-28",
        "io.modelcontextprotocol/clientInfo": {"name": "example", "version": "1.0.0"},
        "io.modelcontextprotocol/clientCapabilities": {}
      }
    }
  }'
```

Every modern request needs that `_meta` object. Mirror the body method in
`Mcp-Method` and the metadata version in `MCP-Protocol-Version`. For `tools/call`,
also mirror `params.name` in `Mcp-Name`; declared `x-mcp-header` tool arguments
need their matching `Mcp-Param-*` headers. A mismatch returns HTTP 400 with
JSON-RPC code `-32020`; missing required metadata returns `-32602`.

Completed responses include `resultType: "complete"` and authoritative server
information in `result._meta["io.modelcontextprotocol/serverInfo"]`. Cacheable
results, including `server/discover` and `tools/list`, include `ttlMs` and
`cacheScope` (defaulting to `0` and `"private"`). The modern executor adds these
fields after the callback returns. `Response.to_protocol/1` alone builds the
component payload and does not select a protocol version. Likewise, calling the
internal `Server.Handlers.handle/3` directly bypasses discovery: mount the
`StreamableHTTP.Plug` shown above so `Server.Modern.Executor` handles
`server/discover` and decorates responses.

Register static tools with `component/2`, or register dynamic tools in
`init_request/2`. The legacy `init/2` callback does not run for modern requests,
and a modern frame is fresh for each request. Keep durable application state
in the application's own context.

When local input-schema validation is enabled for a tool, invalid arguments
produce a JSON-RPC `error` with code `-32602` and no `result`. An application
failure can instead return a completed tool result
with `isError: true` and application-owned structured details:

```elixir
response =
  Response.tool()
  |> Response.error("Revision conflict")
  |> Response.structured(%{
    "code" => "revision_conflict",
    "message" => "Revision conflict",
    "details" => %{"expected_revision" => 3},
    "retryable" => false
  })

{:reply, response, frame}
```

The package's Agent Note HTTP parity regression is pinned to
[`gsmlg-opt/agent-note` at `1a16690d`](https://github.com/gsmlg-opt/agent-note/blob/1a16690d3f0bcdb08e00752e46d76f234313416b/crates/note-mcp/tests/org_transports_test.rs),
covering discovery, cache metadata, routing, schema rejection, and structured
mutation results through a real HTTP client. Note revisions and business tool
behavior remain the consuming application's responsibility.

### Streamable HTTP endpoint and dynamic headers

Use `url:` when the client already has the exact MCP endpoint, including any
non-default path:

```elixir
transport:
  {:streamable_http,
   url: "https://mcp.example.com/custom/mcp",
   headers: %{"x-static" => "configured"},
   headers_provider: fn ->
     {:ok, %{"authorization" => "Bearer #{resolve_current_token()}"}}
   end}
```

`url:` is mutually exclusive with `base_url:` plus `mcp_path:`. Supplying both
forms raises `ArgumentError`, as does supplying neither. With the composed form,
`mcp_path:` defaults to `/mcp`:

```elixir
transport:
  {:streamable_http,
   base_url: "https://mcp.example.com",
   mcp_path: "/mcp"}
```

`headers_provider:` must be a zero-arity function returning either
`{:ok, headers_map}` or `{:error, reason}`. The map must contain binary header
names and binary values. Lists and keyword lists are not valid provider return
values. Header names are normalized case-insensitively before dynamic values
override static values, duplicate normalized names are rejected, and names or
values containing invalid header syntax or CR/LF are rejected.

The provider is invoked for every outbound HTTP operation: POST requests,
legacy GET streams, legacy session DELETE, and modern request-scoped streams.
Malformed provider results return `:invalid_headers_provider_result`; provider
exceptions, throws, and exits become `:headers_provider_failed`; an explicit
`{:error, reason}` is returned as a transport error. Static headers are
validated before the provider is called.

The provider executes in the transport request path, not in the original
caller's process. Automatic propagation of caller-local Logger metadata such as
a request ID is therefore not available through this zero-arity seam.

## Documentation

For detailed guides and examples, see the files in `pages/`, including the
client, server, API reference, and authorization guides.

## Verification

From `apps/backplane_mcp_protocol`, run the package and release checks with the
umbrella dependency directory:

```bash
MIX_ENV=test MIX_DEPS_PATH=../../deps mix test
MIX_ENV=dev MIX_DEPS_PATH=../../deps mix docs
MIX_ENV=dev MIX_DEPS_PATH=../../deps mix hex.build --unpack
```

Run the frozen official conformance package in a second terminal after starting
the server harness:

```bash
MIX_ENV=test MIX_DEPS_PATH=../../deps mix run --no-halt test/conformance/server_runner.exs -- 4105
npx -y @modelcontextprotocol/conformance@0.2.0-alpha.11 server --url http://127.0.0.1:4105/mcp --requirements 2026-07-28

MIX_ENV=test MIX_DEPS_PATH=../../deps mix compile
npx -y @modelcontextprotocol/conformance@0.2.0-alpha.11 client --command "ERL_LIBS=../../_build/test/lib elixir test/conformance/client_runner.exs --" --requirements 2026-07-28
```

The package revision and scored requirement counts are recorded in the
[conformance pin](https://github.com/gsmlg-opt/backplane/blob/main/apps/backplane_mcp_protocol/test/conformance/PIN.md).

## Examples

The app includes Elixir implementation examples using `plug` and `phoenix` apps:

1. [upcase-server](/priv/dev/upcase/README.md): `plug` based MCP server using streamable_http
2. [echo-elixir](/priv/dev/echo-elixir/README.md): `phoenix` based MCP server using sse
3. [ascii-server](/priv/dev/ascii/README.md): `phoenix_live_view` based MCP server using streamable_http and UI

## License

LGPL-v3 License. See [LICENSE](./LICENSE) for details.
