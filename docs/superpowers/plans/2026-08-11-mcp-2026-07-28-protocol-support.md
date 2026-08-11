# MCP 2026-07-28 Protocol Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add complete dual-era MCP `2026-07-28` client and server support to `apps/backplane_mcp_protocol` over Streamable HTTP and stdio while preserving all legacy versions.

**Architecture:** Model `2026-07-28` as an independent modern profile. Keep legacy traffic in `Server.Session`; route modern requests through a request-scoped functional executor. Retain the client GenServer for transport and correlation state while using pure modules for negotiation, metadata, headers, results, and MRTR.

**Tech Stack:** Elixir 1.18, OTP 28, Plug/Finch, ExUnit, Peri-compatible schema validation, telemetry, official `@modelcontextprotocol/conformance` runner.

**Worktree:** `/home/gao/Workspace/gsmlg-opt/backplane/.trees/codex/mcp-2026-07-28`

**Scoped test convention:** Run commands from the worktree root with `MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/backplane/deps`. Bare `mix` is intentional because `unbuffer` is unavailable and the Nix shell is already installed.

---

### Task 1: Model modern and legacy protocol profiles

**Files:**

- Create: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/protocol/profile.ex`
- Create: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/protocol/v2026_07_28.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/protocol/behaviour.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/protocol/registry.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/protocol.ex`
- Create: `apps/backplane_mcp_protocol/test/backplane/mcp_protocol/protocol/profile_test.exs`
- Create: `apps/backplane_mcp_protocol/test/backplane/mcp_protocol/protocol/v2026_07_28_test.exs`
- Modify: `apps/backplane_mcp_protocol/test/backplane/mcp_protocol/protocol/version_modules_test.exs`

- [ ] **Step 1: Run GitNexus impact for each existing protocol symbol**

Analyze `Protocol.Behaviour`, `Protocol.Registry`, and `Backplane.McpProtocol.Protocol` upstream. Record any HIGH or CRITICAL warning before editing.

- [ ] **Step 2: Write failing independent-profile tests**

```elixir
test "2026-07-28 is a stateless modern profile" do
  assert {:ok, profile} = Registry.profile("2026-07-28")
  assert profile.era == :modern
  assert profile.lifecycle == :per_request
  assert "server/discover" in profile.request_methods
  refute "initialize" in profile.request_methods
  refute "ping" in profile.request_methods
  refute "tasks/list" in profile.request_methods
end

test "legacy profiles preserve initialization" do
  assert {:ok, profile} = Registry.profile("2025-11-25")
  assert profile.era == :legacy
  assert profile.lifecycle == :initialize
  assert "initialize" in profile.request_methods
end
```

- [ ] **Step 3: Verify the tests fail**

Run:

```sh
cd apps/backplane_mcp_protocol && MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/backplane/deps mix test test/backplane/mcp_protocol/protocol/profile_test.exs test/backplane/mcp_protocol/protocol/v2026_07_28_test.exs
```

Expected: compilation failure because `Profile` and `V2026_07_28` do not exist.

- [ ] **Step 4: Implement the profile contract and modern profile**

```elixir
defmodule Backplane.McpProtocol.Protocol.Profile do
  @enforce_keys [:version, :era, :lifecycle, :request_methods, :notification_methods]
  defstruct [
    :version,
    :era,
    :lifecycle,
    request_methods: [],
    notification_methods: [],
    features: [],
    cacheable_methods: [],
    named_methods: [],
    extensions: %{}
  ]

  @type era :: :legacy | :modern
  @type lifecycle :: :initialize | :per_request
  @type t :: %__MODULE__{}
end
```

Add `profile/0` to the version behaviour. Adapt legacy modules through a default profile derived from their existing callbacks. Implement `V2026_07_28` independently with the exact modern method and feature sets. Register it as known, but keep the default legacy until Task 12.

- [ ] **Step 5: Run protocol tests and commit**

```sh
cd apps/backplane_mcp_protocol && MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/backplane/deps mix test test/backplane/mcp_protocol/protocol
git add apps/backplane_mcp_protocol
git commit -m "feat(mcp): model the 2026 protocol profile"
```

### Task 2: Add modern wire metadata, results, errors, cache hints, and schema preservation

**Files:**

- Create: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/protocol/cache_hint.ex`
- Create: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/schema_validator.ex`
- Create: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/schema_validator/peri.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/mcp/error.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/mcp/message.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/mcp/response.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/server/response.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/server/component/schema.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/server/component/tool.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/client/json_schema_converter.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/client/cache.ex`
- Create: `apps/backplane_mcp_protocol/test/backplane/mcp_protocol/mcp/modern_error_test.exs`
- Create: `apps/backplane_mcp_protocol/test/backplane/mcp_protocol/protocol/cache_hint_test.exs`
- Create: `apps/backplane_mcp_protocol/test/backplane/mcp_protocol/schema_validator_test.exs`
- Modify: `apps/backplane_mcp_protocol/test/backplane/mcp_protocol/server/response_test.exs`
- Modify: `apps/backplane_mcp_protocol/test/backplane/mcp_protocol/client/cache_test.exs`

- [ ] **Step 1: Run impact analysis for every existing wire/schema symbol being changed**

Analyze `MCP.Error`, `MCP.Message`, `MCP.Response`, `Server.Response`, `Server.Component.Schema`, `Server.Component.Tool`, `Client.JSONSchemaConverter`, and `Client.Cache` upstream.

- [ ] **Step 2: Write failing tests for modern errors and cache hints**

```elixir
assert %Error{code: -32_020} = Error.for_version("2026-07-28", :header_mismatch)
assert %Error{code: -32_021} = Error.for_version("2026-07-28", :missing_client_capability)
assert %Error{code: -32_022, data: %{"requested" => "x", "supported" => [_]}} =
         Error.for_version("2026-07-28", :unsupported_protocol_version, %{
           requested: "x",
           supported: ["2026-07-28"]
         })

assert {:ok, %CacheHint{ttl_ms: 0, scope: :private}} = CacheHint.new(%{})
assert %{"ttlMs" => 0, "cacheScope" => "private"} = CacheHint.put(%{}, CacheHint.default())
```

Add structured-content cases for map, list, string, number, boolean, and `nil`, plus raw `$defs`, local/external `$ref`, `allOf`, conditionals, and unknown schema keywords.

- [ ] **Step 3: Verify the focused tests fail**

```sh
cd apps/backplane_mcp_protocol && MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/backplane/deps mix test test/backplane/mcp_protocol/mcp/modern_error_test.exs test/backplane/mcp_protocol/protocol/cache_hint_test.exs test/backplane/mcp_protocol/schema_validator_test.exs test/backplane/mcp_protocol/server/response_test.exs
```

- [ ] **Step 4: Implement version-specific wire helpers**

```elixir
@spec Error.for_version(String.t(), atom(), map()) :: Error.t()
def for_version(version, reason, data \\ %{})

defmodule Backplane.McpProtocol.Protocol.CacheHint do
  defstruct ttl_ms: 0, scope: :private
  def default, do: %__MODULE__{}
  def new(attrs)
  def put(result, %__MODULE__{} = hint)
  def parse(result)
  def cacheable_method?(method)
end

defmodule Backplane.McpProtocol.SchemaValidator do
  @callback compile(map(), keyword()) :: {:ok, term()} | {:unsupported, term()} | {:error, term()}
  @callback validate(term(), term(), keyword()) :: :ok | {:error, term()}
end
```

Preserve raw JSON Schema maps. Let the Peri adapter compile only its proven subset; unsupported schemas keep tools usable and emit diagnostics. Widen structured content to every JSON value and retain an explicit presence flag so JSON `null` differs from absence.

- [ ] **Step 5: Run wire/schema regressions and commit**

```sh
cd apps/backplane_mcp_protocol && MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/backplane/deps mix test test/backplane/mcp_protocol/mcp test/backplane/mcp_protocol/protocol test/backplane/mcp_protocol/schema_validator_test.exs test/backplane/mcp_protocol/server/response_test.exs test/backplane/mcp_protocol/client/cache_test.exs
git add apps/backplane_mcp_protocol
git commit -m "feat(mcp): add modern wire contracts"
```

### Task 3: Implement the stateless modern server core

**Files:**

- Create: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/server/profile_router.ex`
- Create: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/server/modern/request_context.ex`
- Create: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/server/modern/headers.ex`
- Create: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/server/modern/result.ex`
- Create: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/server/modern/discovery.ex`
- Create: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/server/modern/executor.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/server/context.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/server.ex`
- Create: `apps/backplane_mcp_protocol/test/support/modern_stub_server.ex`
- Create: `apps/backplane_mcp_protocol/test/backplane/mcp_protocol/server/profile_router_test.exs`
- Create: `apps/backplane_mcp_protocol/test/backplane/mcp_protocol/server/modern/request_context_test.exs`
- Create: `apps/backplane_mcp_protocol/test/backplane/mcp_protocol/server/modern/headers_test.exs`
- Create: `apps/backplane_mcp_protocol/test/backplane/mcp_protocol/server/modern/result_test.exs`
- Create: `apps/backplane_mcp_protocol/test/backplane/mcp_protocol/server/modern/discovery_test.exs`
- Create: `apps/backplane_mcp_protocol/test/backplane/mcp_protocol/server/modern/executor_test.exs`

- [ ] **Step 1: Run impact analysis for `Server.Context` and `Server` callbacks**

- [ ] **Step 2: Write routing, context, discovery, and isolation tests**

```elixir
assert {:ok, {:modern, profile}} =
         ProfileRouter.route(discover_request(), %{transport: :http, protocol_version: "2026-07-28"})

assert {:ok, :legacy} =
         ProfileRouter.route(initialize_request(), %{transport: :stdio, connection_era: :unknown})

assert {:response, %{"result" => %{"resultType" => "complete", "supportedVersions" => versions}}} =
         Executor.execute(ModernStubServer, discover_request(), transport_context())

assert "2026-07-28" in versions
assert Process.whereis(legacy_session_name()) == nil
```

Test required request metadata, missing capability `-32021`, result server info, cache hints, deterministic lists, MRTR method restrictions, fresh frames, callback failure sanitization, and no session process creation.

- [ ] **Step 3: Verify tests fail**

```sh
cd apps/backplane_mcp_protocol && MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/backplane/deps mix test test/backplane/mcp_protocol/server/profile_router_test.exs test/backplane/mcp_protocol/server/modern
```

- [ ] **Step 4: Implement plain-function server components**

```elixir
ProfileRouter.route(message, transport_context)
RequestContext.build(profile, request, transport_context)
Headers.validate(profile, request, normalized_headers)
Result.normalize(method, callback_return, request_context, server_module)
Discovery.execute(server_module, request_context)
Executor.execute(server_module, request, transport_context, opts \\ [])
```

Add optional `init_request/2`; never invoke legacy `init/2` for modern requests. Intercept `server/discover` before application dispatch.

- [ ] **Step 5: Run server-core tests and commit**

```sh
cd apps/backplane_mcp_protocol && MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/backplane/deps mix test test/backplane/mcp_protocol/server/profile_router_test.exs test/backplane/mcp_protocol/server/modern
git add apps/backplane_mcp_protocol
git commit -m "feat(mcp): add stateless modern server core"
```

### Task 4: Add dual-era Streamable HTTP server routing

**Files:**

- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/server/transport/streamable_http/plug.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/server/modern/executor.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/server/modern/headers.ex`
- Modify: `apps/backplane_mcp_protocol/test/backplane/mcp_protocol/server/modern/headers_test.exs`
- Create: `apps/backplane_mcp_protocol/test/backplane/mcp_protocol/server/transport/streamable_http/modern_plug_test.exs`

- [ ] **Step 1: Run impact analysis for the Plug, executor, and header-validation symbols**

- [ ] **Step 2: Write failing modern HTTP tests**

Cover session-free POST, matching `MCP-Protocol-Version`, `Mcp-Method`, `Mcp-Name`, parameter mirrors, HTTP 400/`-32020`, HTTP 404/`-32601`, JSON and request-scoped SSE responses, rejection of modern GET/DELETE, and unchanged legacy session behavior.

```elixir
conn = post_modern(discover_request())
assert conn.status == 200
refute get_resp_header(conn, "mcp-session-id") != []
assert %{"result" => %{"resultType" => "complete"}} = json_response(conn)
```

- [ ] **Step 3: Verify failure, then split POST dispatch**

```elixir
defp dispatch_post(conn, message, context, opts)
defp dispatch_modern(conn, message, context, profile, opts)
defp dispatch_legacy(conn, message, session_id, context, opts)
```

Authorize before routing. Modern dispatch calls `Server.Modern.Executor` without registry/session lookup. Legacy dispatch remains byte-for-byte compatible.

- [ ] **Step 4: Run modern and legacy HTTP tests and commit**

```sh
cd apps/backplane_mcp_protocol && MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/backplane/deps mix test test/backplane/mcp_protocol/server/transport/streamable_http/modern_plug_test.exs test/backplane/mcp_protocol/server/transport/streamable_http/plug_test.exs
git add apps/backplane_mcp_protocol
git commit -m "feat(mcp): route modern HTTP requests statelessly"
```

### Task 5: Add dual-era stdio server routing and modern subscriptions

**Files:**

- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/server/transport/stdio.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/server/modern/executor.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/server/transport/streamable_http/plug.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/server/supervisor.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/server/registry.ex`
- Create: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/server/modern/subscriptions.ex`
- Create: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/server/modern/subscription.ex`
- Create: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/server/transport/streamable_http/modern_subscription.ex`
- Modify: `apps/backplane_mcp_protocol/test/support/test_io_device.ex`
- Create: `apps/backplane_mcp_protocol/test/backplane/mcp_protocol/server/transport/modern_stdio_test.exs`
- Create: `apps/backplane_mcp_protocol/test/backplane/mcp_protocol/server/modern/subscriptions_test.exs`
- Create: `apps/backplane_mcp_protocol/test/backplane/mcp_protocol/server/transport/streamable_http/modern_subscription_test.exs`

- [ ] **Step 1: Run impact analysis for stdio, Plug, supervisor, and registry symbols**

- [ ] **Step 2: Write failing lazy-session and subscription tests**

```elixir
assert :unknown == state.detected_era
push_line(device, encode(discover_request()))
assert_receive {:io_write, response}
assert response =~ ~s("resultType":"complete")
assert state_after().legacy_session == nil

assert {:ok, ref} = Subscriptions.subscribe(hub, self(), context)
assert :ok = Subscriptions.publish(hub, notification)
assert_receive {:mcp_subscription, ^ref, ^notification}
```

Cover lazy legacy session creation on `initialize`, connection-era locking, conflict errors, subscriber monitoring, idempotent cancellation, no replay/event IDs, HTTP request ownership, stdio multiplexing, and concurrent ordinary requests.

- [ ] **Step 3: Implement routing state and subscription ownership**

```elixir
def ensure_legacy_session(state)
def dispatch_line(line, %{detected_era: era} = state)

Subscriptions.subscribe(hub, subscriber, request_context)
Subscriptions.unsubscribe(hub, subscription_ref)
Subscriptions.publish(hub, notification)
```

- [ ] **Step 4: Run focused server transport tests and commit**

```sh
cd apps/backplane_mcp_protocol && MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/backplane/deps mix test test/backplane/mcp_protocol/server/transport/modern_stdio_test.exs test/backplane/mcp_protocol/server/modern/subscriptions_test.exs test/backplane/mcp_protocol/server/transport/streamable_http/modern_subscription_test.exs test/backplane/mcp_protocol/server/transport/stdio_test.exs
git add apps/backplane_mcp_protocol
git commit -m "feat(mcp): add modern stdio and subscriptions"
```

### Task 6: Implement client auto-negotiation and explicit protocol state

**Files:**

- Create: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/client/negotiation.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/client.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/client/state.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/client/supervisor.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/transport/stdio.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/transport/streamable_http.ex`
- Modify: `apps/backplane_mcp_protocol/test/support/stub_client.ex`
- Create: `apps/backplane_mcp_protocol/test/backplane/mcp_protocol/client/negotiation_test.exs`
- Modify: `apps/backplane_mcp_protocol/test/backplane/mcp_protocol/client/state_test.exs`
- Modify: `apps/backplane_mcp_protocol/test/backplane/mcp_protocol/client_test.exs`
- Modify: `apps/backplane_mcp_protocol/test/backplane/mcp_protocol/transport/stdio_test.exs`
- Modify: `apps/backplane_mcp_protocol/test/backplane/mcp_protocol/transport/streamable_http_test.exs`

- [ ] **Step 1: Run impact analysis for client, state, supervisor, and transport startup symbols**

- [ ] **Step 2: Write failing negotiation tests**

Test `:auto` discovery, pinned legacy initialization, pinned modern refusal to downgrade, exact HTTP/stdio fallback classification, `-32022` retry, negotiated legacy version state, readiness, and protocol introspection.

```elixir
assert {:send, %Operation{method: "server/discover"}, state} = Negotiation.begin(auto_state())
assert {:ready, %{era: :modern, negotiated_version: "2026-07-28"}} =
         Negotiation.handle_result(state, discover_request(), discover_result())
```

- [ ] **Step 3: Implement negotiation as pure transitions**

```elixir
@type protocol_preference :: :auto | Protocol.version()
@type negotiation_status :: :connecting | :discovering | :initializing | :ready

Negotiation.begin(State.t())
Negotiation.handle_result(State.t(), Request.t(), map())
Negotiation.handle_error(State.t(), Request.t(), Error.t())
State.protocol_context(State.t())
Client.get_protocol_info(client, opts \\ [])
```

The stdio and Streamable HTTP transports signal `:negotiate`, not `:initialize`.
Retain the client's legacy `:initialize` cast while the out-of-scope SSE and
WebSocket transports still use it. Route negotiation responses by pending
request method.

- [ ] **Step 4: Run client state/negotiation tests and commit**

```sh
cd apps/backplane_mcp_protocol && MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/backplane/deps mix test test/backplane/mcp_protocol/client/negotiation_test.exs test/backplane/mcp_protocol/client/state_test.exs test/backplane/mcp_protocol/client_test.exs test/backplane/mcp_protocol/transport/stdio_test.exs test/backplane/mcp_protocol/transport/streamable_http_test.exs
git add apps/backplane_mcp_protocol
git commit -m "feat(mcp): negotiate modern and legacy peers"
```

### Task 7: Add client metadata and dual-era transport headers

**Files:**

- Create: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/client/metadata.ex`
- Create: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/transport/request_context.ex`
- Create: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/transport/streamable_http/headers.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/client.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/client/operation.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/transport/behaviour.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/transport/streamable_http.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/transport/stdio.ex`
- Create: `apps/backplane_mcp_protocol/test/backplane/mcp_protocol/client/metadata_test.exs`
- Create: `apps/backplane_mcp_protocol/test/backplane/mcp_protocol/transport/request_context_test.exs`
- Create: `apps/backplane_mcp_protocol/test/backplane/mcp_protocol/transport/streamable_http/headers_test.exs`

- [ ] **Step 1: Run impact analysis for every existing client/transport symbol**

- [ ] **Step 2: Write failing metadata and header tests**

```elixir
params = Metadata.attach(%{"_meta" => %{"progressToken" => 7}}, modern_state(), %{})
assert get_in(params, ["_meta", "io.modelcontextprotocol/protocolVersion"]) == "2026-07-28"
assert get_in(params, ["_meta", "progressToken"]) == 7

assert {:ok, headers} = Headers.build(%{}, encoded, request_context)
assert headers["mcp-protocol-version"] == "2026-07-28"
assert headers["mcp-method"] == "tools/call"
assert headers["mcp-name"] == "weather"
```

Cover `Mcp-Param-*` encoding, CR/LF rejection, session-free modern HTTP, legacy session retention, modern shutdown without DELETE, no modern GET SSE, and stdio ignoring HTTP-only context.

- [ ] **Step 3: Implement request context through the existing send options**

```elixir
Metadata.attach(params, state, extra_meta)
RequestContext.new(method, params, state, opts \\ [])
Headers.build(base_headers, encoded_message, request_context)

transport.send_message(name, encoded,
  timeout: timeout,
  request_context: request_context
)
```

- [ ] **Step 4: Run transport regressions and commit**

```sh
cd apps/backplane_mcp_protocol && MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/backplane/deps mix test test/backplane/mcp_protocol/client/metadata_test.exs test/backplane/mcp_protocol/transport/request_context_test.exs test/backplane/mcp_protocol/transport/streamable_http/headers_test.exs test/backplane/mcp_protocol/transport/streamable_http_test.exs test/backplane/mcp_protocol/transport/stdio_test.exs
git add apps/backplane_mcp_protocol
git commit -m "feat(mcp): send modern metadata and headers"
```

### Task 8: Implement modern result routing and MRTR

**Files:**

- Create: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/client/result_router.ex`
- Create: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/client/mrtr.ex`
- Create: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/client/input_handler.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/client.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/client/request.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/client/sampling.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/client/elicitation.ex`
- Create: `apps/backplane_mcp_protocol/test/backplane/mcp_protocol/client/result_router_test.exs`
- Create: `apps/backplane_mcp_protocol/test/backplane/mcp_protocol/client/mrtr_test.exs`

- [ ] **Step 1: Run impact analysis for response routing and callback symbols**

- [ ] **Step 2: Write failing complete/input-required tests**

```elixir
assert {:complete, response, state} = ResultRouter.route(request, complete_result(), state)
assert response.result_type == :complete

assert {:input_required, continuation, state} =
         ResultRouter.route(request, input_required_result(), state)
refute_received {GenServer, :reply, _}
```

Cover method-based routing, missing `resultType` only for legacy, supervised roots/sampling/elicitation resolution, new wire ID, exact request state, original deadline across rounds, cancellation, callback errors, and one final caller reply.

- [ ] **Step 3: Implement result and MRTR reducers**

```elixir
ResultRouter.route(Request.t(), map(), State.t())
MRTR.prepare(Request.t(), map())
InputHandler.resolve(input_requests, State.t())
MRTR.retry_params(MRTR.t(), input_responses)
```

Store original params, caller, absolute deadline, active wire ID, and continuation state in `Client.Request`.

- [ ] **Step 4: Run MRTR and legacy callback tests and commit**

```sh
cd apps/backplane_mcp_protocol && MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/backplane/deps mix test test/backplane/mcp_protocol/client/result_router_test.exs test/backplane/mcp_protocol/client/mrtr_test.exs test/backplane/mcp_protocol/client_test.exs
git add apps/backplane_mcp_protocol
git commit -m "feat(mcp): handle modern results and MRTR"
```

### Task 9: Add client catalog header projection and subscription streams

**Files:**

- Create: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/client/catalog.ex`
- Create: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/client/subscription.ex`
- Create: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/transport/streamable_http/stream.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/client.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/client/handlers.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/transport/behaviour.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/transport/streamable_http.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/transport/stdio.ex`
- Create: `apps/backplane_mcp_protocol/test/backplane/mcp_protocol/client/catalog_test.exs`
- Create: `apps/backplane_mcp_protocol/test/backplane/mcp_protocol/client/subscription_test.exs`
- Create: `apps/backplane_mcp_protocol/test/backplane/mcp_protocol/transport/streamable_http/stream_test.exs`

- [ ] **Step 1: Run impact analysis for catalog handlers and transport streaming symbols**

- [ ] **Step 2: Write failing catalog/subscription tests**

```elixir
assert {:ok, %{"Mcp-Param-City" => "Paris"}} =
         Catalog.parameter_headers(catalog, "weather", %{"city" => "Paris"})

assert {:ok, subscription} = Client.listen_subscriptions(client, ["notifications/tools/list_changed"])
assert subscription.acknowledged?
assert :ok = Client.close_subscription(client, subscription)
```

Cover invalid `x-mcp-header` filtering, atomic catalog replacement, acknowledgement before delivery, subscription ID correlation, request-owned HTTP streaming, concurrent normal calls, stdio multiplexing, cancellation, and explicit modern rejection of legacy resource-subscription APIs.

- [ ] **Step 3: Implement catalog and request-owned stream APIs**

```elixir
Catalog.compile(tools)
Catalog.parameter_headers(catalog, tool_name, arguments)
Client.listen_subscriptions(client, filters, opts \\ [])
Client.close_subscription(client, subscription, opts \\ [])
Transport.open_stream(name, encoded_request, opts)
```

- [ ] **Step 4: Run focused tests and commit**

```sh
cd apps/backplane_mcp_protocol && MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/backplane/deps mix test test/backplane/mcp_protocol/client/catalog_test.exs test/backplane/mcp_protocol/client/subscription_test.exs test/backplane/mcp_protocol/transport/streamable_http/stream_test.exs
git add apps/backplane_mcp_protocol
git commit -m "feat(mcp): add modern catalog headers and subscriptions"
```

### Task 10: Add 2026 authorization hardening and redaction

**Files:**

- Create: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/client/authorization.ex`
- Create: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/client/authorization/credential_store.ex`
- Create: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/logging/redaction.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/logging.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/telemetry.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/server/authorization.ex`
- Create: `apps/backplane_mcp_protocol/test/backplane/mcp_protocol/client/authorization/authorization_test.exs`
- Create: `apps/backplane_mcp_protocol/test/backplane/mcp_protocol/logging/redaction_test.exs`
- Create: `apps/backplane_mcp_protocol/test/backplane/mcp_protocol/logging_test.exs`
- Create: `apps/backplane_mcp_protocol/test/backplane/mcp_protocol/telemetry_test.exs`
- Modify: `apps/backplane_mcp_protocol/test/backplane/mcp_protocol/server/authorization/authorization_test.exs`

- [ ] **Step 1: Run impact analysis for server authorization**

- [ ] **Step 2: Write failing issuer, registration, storage, and redaction tests**

```elixir
assert :ok = Authorization.validate_issuer("https://auth.example", "https://auth.example")
assert {:error, :issuer_mismatch} = Authorization.validate_issuer("https://auth.example", "https://AUTH.example")
assert %{"application_type" => "native"} = Authorization.registration_metadata(%{}, :native)
refute inspect(Redaction.redact(%{"access_token" => "secret"})) =~ "secret"
```

- [ ] **Step 3: Implement opt-in client authorization helpers**

```elixir
Authorization.validate_issuer(expected, returned)
Authorization.registration_metadata(metadata, application_type)
Authorization.credential_key(issuer, client_id)
Authorization.select_registration(metadata, opts)
CredentialStore.fetch(issuer, client_id)
CredentialStore.put(issuer, client_id, credentials)
Redaction.redact(term)
```

Prefer pre-registration, then CIMD, then deprecated DCR. Do not add OAuth to stdio.
Apply redaction in the package's central logging and telemetry emitters, with integration tests proving emitted metadata cannot contain secrets.

- [ ] **Step 4: Run authorization tests and commit**

```sh
cd apps/backplane_mcp_protocol && MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/backplane/deps mix test test/backplane/mcp_protocol/client/authorization test/backplane/mcp_protocol/logging/redaction_test.exs test/backplane/mcp_protocol/server/authorization
git add apps/backplane_mcp_protocol
git commit -m "feat(mcp): harden modern authorization"
```

### Task 11: Add dual-era integration and frozen conformance adapters

**Files:**

- Create: `apps/backplane_mcp_protocol/test/backplane/mcp_protocol/client/dual_era_integration_test.exs`
- Create: `apps/backplane_mcp_protocol/test/support/modern_mock_server.ex`
- Create: `apps/backplane_mcp_protocol/test/support/legacy_mock_server.ex`
- Create: `apps/backplane_mcp_protocol/test/conformance/conformance_server.ex`
- Create: `apps/backplane_mcp_protocol/test/conformance/conformance_client.ex`
- Create: `apps/backplane_mcp_protocol/test/conformance/server_runner.exs`
- Create: `apps/backplane_mcp_protocol/test/conformance/client_runner.exs`
- Create: `apps/backplane_mcp_protocol/test/conformance/PIN.md`
- Modify: `apps/backplane_mcp_protocol/mix.exs` only if the harness proves an additional test-only dependency is required.
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/server/profile_router.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/server/modern/request_context.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/server/modern/executor.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/server/transport/streamable_http/plug.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/server/transport/stdio.ex`
- Modify: `apps/backplane_mcp_protocol/test/backplane/mcp_protocol/server/profile_router_test.exs`
- Modify: `apps/backplane_mcp_protocol/test/backplane/mcp_protocol/server/modern/executor_test.exs`
- Modify: `apps/backplane_mcp_protocol/test/backplane/mcp_protocol/server/transport/streamable_http/modern_plug_test.exs`
- Modify: `apps/backplane_mcp_protocol/test/backplane/mcp_protocol/server/transport/modern_stdio_test.exs`

- [ ] **Step 1: Write end-to-end dual-era tests**

Cover modern HTTP, modern stdio, auto-to-legacy HTTP/stdio fallback, pinned refusal, MRTR, concurrent subscription, cache/header projection, and absence of modern session/GET/DELETE behavior.

- [ ] **Step 2: Implement package-local conformance entrypoints**

```elixir
Conformance.Server.start_link(opts)
Conformance.Client.run(url, scenario, context, protocol_version)
```

Pin the exact official package/revision and record its invocation in `PIN.md`. Do not accept expected failures.
Use `@modelcontextprotocol/conformance@0.2.0-alpha.11` at git commit `c321dd32035556e6769d3724a8ee97d87c3faaac`; its frozen requirement manifest is anchored to the `0.2.0-alpha.10` scenario release. The client runner receives the scenario server URL as its final argument plus `MCP_CONFORMANCE_SCENARIO`, `MCP_CONFORMANCE_PROTOCOL_VERSION`, and optional JSON `MCP_CONFORMANCE_CONTEXT`; it is a one-shot Streamable HTTP client process, not an MCP-over-stdio adapter. Use Task 10's production authorization helpers for scored OAuth scenarios. Add `plug_cowboy` as a direct test-only dependency if the server runner uses `Plug.Cowboy`; do not rely on Bypass's transitive dependency. Do not replace the frozen requirements with the moving `--suite all`, and do not add expected failures.

The frozen server suite is also the acceptance oracle for production wire behavior. Add regressions and fix any scored package defect it exposes; do not hide production failures in a conformance-only adapter. In particular, required modern body metadata must fail as JSON-RPC invalid params (`-32602`), modern-marked removed methods must fail as method not found (`-32601` / HTTP 404), and progress emitted through the existing `Backplane.McpProtocol.Server.send_progress/3` callback API must precede the final response on modern HTTP SSE and stdio transports.

- [ ] **Step 3: Run integration and frozen official suites**

```sh
cd apps/backplane_mcp_protocol && MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/backplane/deps mix test test/backplane/mcp_protocol/client/dual_era_integration_test.exs

cd apps/backplane_mcp_protocol && MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/backplane/deps mix run --no-halt test/conformance/server_runner.exs -- 4105

npx -y @modelcontextprotocol/conformance@0.2.0-alpha.11 list --requirements 2026-07-28

npx -y @modelcontextprotocol/conformance@0.2.0-alpha.11 server --url http://127.0.0.1:4105/mcp --requirements 2026-07-28

npx -y @modelcontextprotocol/conformance@0.2.0-alpha.11 client --command "MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/backplane/deps mix run test/conformance/client_runner.exs --" --requirements 2026-07-28
```

- [ ] **Step 4: Commit the zero-expected-failure harness**

```sh
git add apps/backplane_mcp_protocol
git commit -m "test(mcp): add 2026 dual-era conformance"
```

### Task 12: Activate the modern default, document it, and run the package release gate

**Files:**

- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/protocol/registry.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/client.ex`
- Modify: `apps/backplane_mcp_protocol/test/backplane/mcp_protocol/protocol/registry_test.exs`
- Modify: `apps/backplane_mcp_protocol/test/backplane/mcp_protocol/client_test.exs`
- Modify: `apps/backplane_mcp_protocol/mix.exs` only to register `pages/authorization.md` with ExDoc.
- Modify: `apps/backplane_mcp_protocol/README.md`
- Modify: `apps/backplane_mcp_protocol/pages/introduction.md`
- Modify: `apps/backplane_mcp_protocol/pages/building-a-client.md`
- Modify: `apps/backplane_mcp_protocol/pages/building-a-server.md`
- Modify: `apps/backplane_mcp_protocol/pages/reference.md`
- Modify: `apps/backplane_mcp_protocol/pages/authorization.md`
- Modify: `apps/backplane_mcp_protocol/CHANGELOG.md`
- Modify: package-local generated files under `apps/backplane_mcp_protocol/priv/static/`

- [ ] **Step 1: Add final activation tests**

```elixir
assert Registry.latest_version() == "2026-07-28"
assert hd(Registry.supported_versions()) == "2026-07-28"
assert Client.default_protocol_preference() == :auto
```

- [ ] **Step 2: Activate only after Task 11 is green**

Register `2026-07-28` as latest and make new clients default to `:auto`. Preserve explicit legacy pinning.

- [ ] **Step 3: Update package documentation and generated LLM docs**

Register the authorization guide with ExDoc. Document modern/legacy selection, per-request metadata, server discovery, modern HTTP headers, MRTR, subscriptions, JSON Schema behavior, authorization, and migration from legacy initialization. State that explicit subscription handles close on connection loss and callers re-listen if they still want events. State that the modern Tasks extension is deferred.

- [ ] **Step 4: Run the complete package gate**

```sh
cd apps/backplane_mcp_protocol && MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/backplane/deps mix test
cd apps/backplane_mcp_protocol && MIX_ENV=dev MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/backplane/deps mix format --check-formatted
cd apps/backplane_mcp_protocol && MIX_ENV=dev MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/backplane/deps mix compile --warnings-as-errors
cd apps/backplane_mcp_protocol && MIX_ENV=dev MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/backplane/deps mix credo --strict
cd apps/backplane_mcp_protocol && MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/backplane/deps mix dialyzer
cd apps/backplane_mcp_protocol && MIX_ENV=dev MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/backplane/deps mix docs
cd apps/backplane_mcp_protocol && MIX_ENV=dev MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/backplane/deps mix hex.build --unpack
```

Re-run both official conformance commands from Task 11 after the full package suite.

- [ ] **Step 5: Run GitNexus change detection and commit final activation**

Verify only `apps/backplane_mcp_protocol` and the scoped design/plan documents changed.

```sh
git add apps/backplane_mcp_protocol docs/superpowers/specs/2026-08-11-mcp-2026-07-28-protocol-support-design.md docs/superpowers/plans/2026-08-11-mcp-2026-07-28-protocol-support.md
git commit -m "docs(mcp): document 2026 protocol support"
```
