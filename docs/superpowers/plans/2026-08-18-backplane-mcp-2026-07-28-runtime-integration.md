# Backplane MCP 2026-07-28 Runtime Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** Make Backplane's public /mcp endpoint and upstream MCP proxy support explicit MCP 2026-07-28 traffic while keeping 2025-11-25 as the default and preserving every existing legacy endpoint version.

**Architecture:** Keep Backplane's authenticated legacy endpoint and upstream coordinator contracts. Route explicitly modern endpoint requests through a conformant stateless protocol-package seam and a thin Backplane server adapter; move shared hub operations behind Backplane.MCP.Dispatch. Replace handwritten upstream wire handling with supervised Backplane.McpProtocol.Client trees selected per upstream.

**Tech Stack:** Elixir 1.18, OTP 28, Plug/Bandit, Finch, Ecto/PostgreSQL, Phoenix LiveView with DuskMoon UI, ExUnit, backplane_mcp_protocol, official @modelcontextprotocol/conformance runner.

---

**Design:** docs/superpowers/specs/2026-08-18-backplane-mcp-2026-07-28-runtime-integration-design.md

**Worktree:** /home/gao/Workspace/gsmlg-opt/backplane/.trees/codex/mcp-2026-runtime-integration

**Scope note:** Endpoint and proxy work remain in one plan because both depend on the same legacy-default boundary and protocol-package seams, and public activation is gated on their combined round-trip proof. Every task still ends in a green, independently reviewable commit.

**Baseline:** Dependency sources compiled in the isolated worktree and the focused metadata suite passed 2 tests, 0 failures.

~~~bash
devenv shell -- bash -lc 'cd /home/gao/Workspace/gsmlg-opt/backplane/.trees/codex/mcp-2026-runtime-integration && MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/backplane/deps mix test --no-deps-check apps/backplane_mcp/test/backplane/mcp/info_test.exs'
~~~

**Execution rules:**

- Run commands from the worktree unless a step explicitly enters apps/backplane_mcp_protocol.
- Before editing an existing Elixir symbol, run GitNexus upstream impact analysis. If it returns UNKNOWN again, record that result and use direct callers plus focused tests as the safety boundary.
- Follow red-green-refactor: add one failing behavior test, confirm the expected failure, implement only that behavior, and rerun the focused suite.
- Preserve unrelated dirty files in the main checkout. Stage only paths named by each task.
- Use devenv shell -- mix. If the worktree Nix cache is unavailable, invoke the realized root shell, cd to the worktree, and set MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/backplane/deps.

## File structure

### Reusable protocol package

- apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/transport/streamable_http.ex — exact endpoint URL, dynamic headers, and transport state.
- apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/transport/streamable_http/request_headers.ex — pure static/dynamic header resolution.
- apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/transport/streamable_http/stream.ex — request-scoped SSE uses the same dynamic headers.
- apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/server/transport/streamable_http/modern_request.ex — reusable pre-authorized modern HTTP execution and response seam.
- apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/server/transport/streamable_http/plug.ex — standalone Plug delegates modern work to ModernRequest.

### Backplane endpoint

- apps/backplane_mcp/lib/backplane/mcp/info.ex — legacy default and support list.
- apps/backplane_mcp/lib/backplane/mcp/dispatch.ex — common hub operations.
- apps/backplane_mcp/lib/backplane/mcp/modern_server.ex — stateless 2026-07-28 adapter.
- apps/backplane_mcp/lib/backplane/transport/mcp_era_router.ex — pure marker routing.
- apps/backplane_mcp/lib/backplane/transport/mcp_plug.ex — common HTTP pipeline and era dispatch.
- apps/backplane_mcp/lib/backplane/transport/mcp_handler.ex — legacy lifecycle/envelope adapter.
- apps/backplane_mcp/lib/backplane/transport/version_header.ex — selected response version.
- apps/backplane_mcp/lib/backplane/transport/idempotency.ex — identity-, era-, and request-bound cache.
- apps/backplane_system/lib/backplane/transport/cors.ex — safe modern browser headers.

### Upstream proxy

- apps/backplane_system/priv/repo/migrations/20260818000001_add_protocol_version_to_mcp_upstreams.exs — persisted selector.
- apps/backplane_mcp/lib/backplane/proxy/mcp_upstream.ex — selector validation.
- apps/backplane_mcp/lib/backplane/proxy/upstreams.ex — schema-to-runtime configuration.
- apps/backplane_mcp/lib/backplane/proxy/client_pool.ex — temporary client trees.
- apps/backplane_mcp/lib/backplane/proxy/protocol_client.ex — names, options, and sanitized client calls.
- apps/backplane_mcp/lib/backplane/proxy/tool_catalog.ex — bounded, lossless catalog normalization.
- apps/backplane_mcp/lib/backplane/proxy/upstream.ex — coordinator and lifecycle owner.
- apps/backplane_system/lib/backplane/registry/tool.ex — retained modern fields.
- apps/backplane_admin/lib/backplane/admin/live/upstreams_live.ex — selector and negotiated status.

### End-to-end proof

- apps/backplane_mcp/test/support/modern_upstream_server.ex — modern package-backed fixture.
- apps/backplane_mcp/test/integration/modern_proxy_round_trip_test.exs — downstream-to-upstream round trip.
- README.md and apps/backplane_mcp_protocol/README.md — compatibility and new transport options.

### Task 1: Restore the legacy-default boundary

**Files:**

- Modify: apps/backplane_mcp/lib/backplane/mcp/info.ex:13-120
- Modify: apps/backplane_mcp/test/backplane/mcp/info_test.exs:12-15
- Modify: apps/backplane_mcp/test/backplane/transport/mcp_handler_test.exs:62-100

- [ ] **Step 1: Run impact analysis**

~~~text
gitnexus_impact({target: "protocol_version", file_path: "apps/backplane_mcp/lib/backplane/mcp/info.ex", direction: "upstream", includeTests: true})
gitnexus_impact({target: "supported_versions", file_path: "apps/backplane_mcp/lib/backplane/mcp/info.ex", direction: "upstream", includeTests: true})
gitnexus_impact({target: "capabilities_for_version", file_path: "apps/backplane_mcp/lib/backplane/mcp/info.ex", direction: "upstream", includeTests: true})
~~~

Expected: review Backplane, McpHandler, Session, VersionHeader, and Upstream callers; record UNKNOWN if symbol resolution still fails.

- [ ] **Step 2: Write failing legacy-boundary tests**

~~~elixir
test "keeps the legacy endpoint default while the package latest is modern" do
  assert Info.protocol_version() == "2025-11-25"

  assert Info.supported_versions() == [
           "2025-11-25",
           "2025-06-18",
           "2025-03-26",
           "2024-11-05"
         ]

  assert Backplane.McpProtocol.Protocol.latest_version() == "2026-07-28"
  refute Backplane.McpProtocol.Protocol.latest_version() in Info.supported_versions()
end

test "keeps a modern version requested through initialize on the legacy default" do
  resp = mcp_request("initialize", %{"protocolVersion" => "2026-07-28"})
  assert resp["result"]["protocolVersion"] == "2025-11-25"
end
~~~

- [ ] **Step 3: Run RED**

~~~bash
devenv shell -- mix test apps/backplane_mcp/test/backplane/mcp/info_test.exs
devenv shell -- mix test apps/backplane_mcp/test/backplane/transport/mcp_handler_test.exs:77
~~~

Expected: metadata returns 2026-07-28; initialize either hangs or fails because capability fallback recursively selects the modern package latest.

- [ ] **Step 4: Pin only the application-facing legacy boundary**

~~~elixir
@legacy_default_version "2025-11-25"
@legacy_versions [
  @legacy_default_version,
  "2025-06-18",
  "2025-03-26",
  "2024-11-05"
]

@spec protocol_version() :: String.t()
def protocol_version, do: @legacy_default_version

@spec supported_versions() :: [String.t()]
def supported_versions, do: @legacy_versions
~~~

Keep version ordering and capability clauses legacy-only. The fallback to capabilities_for_version(protocol_version()) is now finite.

- [ ] **Step 5: Add exact legacy-version regression coverage**

~~~elixir
for version <- ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"] do
  test "initializes exact legacy version #{version}" do
    resp = mcp_request("initialize", %{"protocolVersion" => unquote(version)})
    assert resp["result"]["protocolVersion"] == unquote(version)
  end
end
~~~

- [ ] **Step 6: Run GREEN**

~~~bash
devenv shell -- mix test apps/backplane_mcp/test/backplane/mcp/info_test.exs apps/backplane_mcp/test/backplane/transport/mcp_handler_test.exs
~~~

Expected: all focused tests pass with no hang.

- [ ] **Step 7: Commit the legacy boundary**

~~~bash
git add apps/backplane_mcp/lib/backplane/mcp/info.ex \
  apps/backplane_mcp/test/backplane/mcp/info_test.exs \
  apps/backplane_mcp/test/backplane/transport/mcp_handler_test.exs
git commit -m "fix(mcp): preserve the legacy endpoint default"
~~~

### Task 2: Accept exact Streamable HTTP endpoint URLs

**Files:**

- Modify: apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/transport/streamable_http.ex:140-230
- Modify: apps/backplane_mcp_protocol/test/backplane/mcp_protocol/transport/streamable_http_test.exs:19-63

- [ ] **Step 1: Run impact analysis**

~~~text
gitnexus_impact({target: "start_link", file_path: "apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/transport/streamable_http.ex", direction: "upstream", includeTests: true})
gitnexus_impact({target: "init", file_path: "apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/transport/streamable_http.ex", direction: "upstream", includeTests: true})
~~~

- [ ] **Step 2: Add exact-URL and exclusivity tests**

~~~elixir
test "uses an exact endpoint URL without appending /mcp", %{bypass: bypass} do
  {:ok, stub_client} = StubClient.start_link()

  assert {:ok, transport} =
           StreamableHTTP.start_link(
             client: stub_client,
             url: "http://localhost:#{bypass.port}/custom/mcp?tenant=one",
             transport_opts: @test_http_opts
           )

  assert URI.to_string(:sys.get_state(transport).mcp_url) ==
           "http://localhost:#{bypass.port}/custom/mcp?tenant=one"
end

test "requires exactly one endpoint configuration", %{bypass: bypass} do
  {:ok, stub_client} = StubClient.start_link()

  assert_raise ArgumentError, fn ->
    StreamableHTTP.start_link(client: stub_client, transport_opts: @test_http_opts)
  end

  assert_raise ArgumentError, fn ->
    StreamableHTTP.start_link(
      client: stub_client,
      url: "http://localhost:#{bypass.port}/mcp",
      base_url: "http://localhost:#{bypass.port}",
      transport_opts: @test_http_opts
    )
  end
end
~~~

- [ ] **Step 3: Run RED**

~~~bash
devenv shell -- bash -lc 'cd apps/backplane_mcp_protocol && MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/backplane/deps mix test test/backplane/mcp_protocol/transport/streamable_http_test.exs'
~~~

Expected: url is rejected or the exclusivity contract is absent.

- [ ] **Step 4: Resolve exactly one endpoint**

~~~elixir
defschema(:options_schema, %{
  name: {{:custom, &Backplane.McpProtocol.genserver_name/1}, {:default, __MODULE__}},
  client: {:required, Backplane.McpProtocol.get_schema(:process_name)},
  url: {{:string, {:transform, &URI.new!/1}}, {:default, nil}},
  base_url: {{:string, {:transform, &URI.new!/1}}, {:default, nil}},
  mcp_path: {:string, {:default, "/mcp"}},
  headers: {:map, {:default, %{}}},
  transport_opts: {:any, {:default, []}},
  http_options: {:any, {:default, []}},
  enable_sse: {:boolean, {:default, false}}
})

defp resolve_mcp_url(%{url: %URI{} = url, base_url: nil}), do: url

defp resolve_mcp_url(%{url: nil, base_url: %URI{} = base_url, mcp_path: path}) do
  URI.append_path(base_url, path)
end

defp resolve_mcp_url(_opts) do
  raise ArgumentError, "configure exactly one of :url or :base_url"
end
~~~

Set mcp_url: resolve_mcp_url(opts) in init/1. Preserve all base_url callers.

- [ ] **Step 5: Run GREEN**

~~~bash
devenv shell -- bash -lc 'cd apps/backplane_mcp_protocol && MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/backplane/deps mix test test/backplane/mcp_protocol/transport/streamable_http_test.exs test/backplane/mcp_protocol/client/dual_era_integration_test.exs'
~~~

Expected: exact URL and all existing base_url callers pass.

- [ ] **Step 6: Commit exact URL support**

~~~bash
git add apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/transport/streamable_http.ex \
  apps/backplane_mcp_protocol/test/backplane/mcp_protocol/transport/streamable_http_test.exs
git commit -m "feat(mcp): accept exact streamable HTTP URLs"
~~~

### Task 3: Resolve outbound HTTP headers per request

**Files:**

- Create: apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/transport/streamable_http/request_headers.ex
- Modify: apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/transport/streamable_http.ex:140-720
- Modify: apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/transport/streamable_http/stream.ex:20-180
- Create: apps/backplane_mcp_protocol/test/backplane/mcp_protocol/transport/streamable_http/request_headers_test.exs
- Modify: apps/backplane_mcp_protocol/test/backplane/mcp_protocol/transport/streamable_http_test.exs
- Modify: apps/backplane_mcp_protocol/test/backplane/mcp_protocol/transport/streamable_http/stream_test.exs

- [ ] **Step 1: Run impact analysis for POST, GET, DELETE, and stream request builders**

~~~text
gitnexus_impact({target: "send_http_request", file_path: "apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/transport/streamable_http.ex", direction: "upstream", includeTests: true})
gitnexus_impact({target: "run_sse_task", file_path: "apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/transport/streamable_http.ex", direction: "upstream", includeTests: true})
gitnexus_impact({target: "delete_session", file_path: "apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/transport/streamable_http.ex", direction: "upstream", includeTests: true})
gitnexus_impact({target: "run_stream", file_path: "apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/transport/streamable_http/stream.ex", direction: "upstream", includeTests: true})
~~~

- [ ] **Step 2: Add pure resolver tests**

~~~elixir
test "merges dynamic headers over static headers on every call" do
  counter = start_supervised!({Agent, fn -> 0 end})

  provider = fn ->
    value = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
    {:ok, %{"authorization" => "Bearer token-#{value}"}}
  end

  assert {:ok, %{"authorization" => "Bearer token-1", "x-static" => "one"}} =
           RequestHeaders.resolve(%{"authorization" => "old", "x-static" => "one"}, provider)

  assert {:ok, %{"authorization" => "Bearer token-2", "x-static" => "one"}} =
           RequestHeaders.resolve(%{"authorization" => "old", "x-static" => "one"}, provider)
end

test "returns sanitized provider failures" do
  assert {:error, :invalid_headers_provider_result} =
           RequestHeaders.resolve(%{}, fn -> {:ok, ["bad"]} end)

  assert {:error, :credential_unavailable} =
           RequestHeaders.resolve(%{}, fn -> {:error, :credential_unavailable} end)
end
~~~

Add Bypass assertions proving rotated values reach normal POST, legacy GET, session DELETE, and request-scoped stream requests.

- [ ] **Step 3: Run RED**

~~~bash
devenv shell -- bash -lc 'cd apps/backplane_mcp_protocol && MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/backplane/deps mix test test/backplane/mcp_protocol/transport/streamable_http/request_headers_test.exs test/backplane/mcp_protocol/transport/streamable_http_test.exs test/backplane/mcp_protocol/transport/streamable_http/stream_test.exs'
~~~

Expected: RequestHeaders is undefined and transport requests retain startup headers.

- [ ] **Step 4: Implement one safe resolver**

~~~elixir
defmodule Backplane.McpProtocol.Transport.StreamableHTTP.RequestHeaders do
  @moduledoc false

  @type provider :: (-> {:ok, map()} | {:error, term()})

  @spec resolve(map(), provider() | nil) :: {:ok, map()} | {:error, term()}
  def resolve(static, nil) when is_map(static), do: {:ok, static}

  def resolve(static, provider) when is_map(static) and is_function(provider, 0) do
    case provider.() do
      {:ok, dynamic} when is_map(dynamic) -> {:ok, Map.merge(static, dynamic)}
      {:ok, _invalid} -> {:error, :invalid_headers_provider_result}
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_headers_provider_result}
    end
  rescue
    _exception -> {:error, :headers_provider_failed}
  catch
    _kind, _reason -> {:error, :headers_provider_failed}
  end
end
~~~

Add headers_provider: {:any, {:default, nil}} to the option schema and state. Call RequestHeaders.resolve/2 before Headers.build/3, legacy GET, DELETE, and Stream.run_stream/1. Pass the provider into Stream.start/1.

- [ ] **Step 5: Run GREEN**

~~~bash
devenv shell -- bash -lc 'cd apps/backplane_mcp_protocol && MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/backplane/deps mix test test/backplane/mcp_protocol/transport/streamable_http test/backplane/mcp_protocol/transport/streamable_http_test.exs'
~~~

Expected: every HTTP path observes current provider headers.

- [ ] **Step 6: Commit dynamic headers**

~~~bash
git add apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/transport/streamable_http.ex \
  apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/transport/streamable_http/request_headers.ex \
  apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/transport/streamable_http/stream.ex \
  apps/backplane_mcp_protocol/test/backplane/mcp_protocol/transport/streamable_http
git commit -m "feat(mcp): resolve streamable HTTP headers per request"
~~~

### Task 4: Extract a reusable modern HTTP request seam

**Files:**

- Create: apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/server/transport/streamable_http/modern_request.ex
- Modify: apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/server/transport/streamable_http/plug.ex:178-270,434-500
- Create: apps/backplane_mcp_protocol/test/backplane/mcp_protocol/server/transport/streamable_http/modern_request_test.exs
- Modify: apps/backplane_mcp_protocol/test/backplane/mcp_protocol/server/transport/streamable_http/modern_plug_test.exs

- [ ] **Step 1: Run impact analysis**

~~~text
gitnexus_impact({target: "dispatch_modern", file_path: "apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/server/transport/streamable_http/plug.ex", direction: "upstream", includeTests: true})
gitnexus_impact({target: "send_modern_response", file_path: "apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/server/transport/streamable_http/plug.ex", direction: "upstream", includeTests: true})
~~~

- [ ] **Step 2: Add a direct pre-authorized test**

Start only an unnamed Task.Supervisor; do not start a package Server.Supervisor.

~~~elixir
task_supervisor = start_supervised!({Task.Supervisor, []})
request = modern_request("server/discover", %{}, id: "direct")

conn =
  conn(:post, "/mcp", JSON.encode!(request))
  |> put_req_header("accept", "application/json, text/event-stream")
  |> put_req_header("mcp-protocol-version", "2026-07-28")
  |> put_req_header("mcp-method", "server/discover")

context = %{
  assigns: %{resource_auth: %{kind: :open, scopes: ["*"]}},
  req_headers: conn.req_headers,
  remote_ip: conn.remote_ip,
  type: :http,
  supported_versions: ["2026-07-28"]
}

conn =
  ModernRequest.call(conn, request, context,
    server: ModernStubServer,
    task_supervisor: task_supervisor,
    timeout: 1_000,
    subscriptions: nil
  )

assert conn.status == 200
assert get_resp_header(conn, "mcp-session-id") == []
assert get_in(JSON.decode!(conn.resp_body), ["result", "supportedVersions"]) == ["2026-07-28"]
~~~

Also assert subscriptions/listen returns 404/-32601 when subscriptions: nil.

- [ ] **Step 3: Run RED**

~~~bash
devenv shell -- bash -lc 'cd apps/backplane_mcp_protocol && MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/backplane/deps mix test test/backplane/mcp_protocol/server/transport/streamable_http/modern_request_test.exs'
~~~

Expected: ModernRequest is undefined.

- [ ] **Step 4: Move modern execution/response ownership into one public boundary**

~~~elixir
defmodule Backplane.McpProtocol.Server.Transport.StreamableHTTP.ModernRequest do
  @spec call(Plug.Conn.t(), term(), map(), keyword()) :: Plug.Conn.t()
  def call(conn, message, transport_context, opts) when is_map(message) do
    server = Keyword.fetch!(opts, :server)
    task_supervisor = Keyword.fetch!(opts, :task_supervisor)
    timeout = Keyword.get(opts, :timeout, 30_000)
    subscriptions = Keyword.get(opts, :subscriptions)

    context =
      Map.merge(transport_context, %{
        task_supervisor: task_supervisor,
        request_timeout: timeout
      })

    case {validate_request(message), message["method"], subscriptions} do
      {:ok, "subscriptions/listen", nil} ->
        respond(conn, Error.build_json_rpc(Error.protocol(:method_not_found), message["id"]))

      {:ok, "subscriptions/listen", _hub} ->
        ModernSubscription.call(conn, message, context, Map.new(opts))

      {:ok, _method, _hub} ->
        server
        |> Executor.execute(message, context,
          task_supervisor: task_supervisor,
          timeout: timeout
        )
        |> respond_executor(conn)

      {{:error, error}, _method, _hub} ->
        respond(conn, Error.build_json_rpc(error, message["id"]))
    end
  end

  def call(conn, _invalid_message, _transport_context, _opts) do
    respond(conn, Error.build_json_rpc(Error.protocol(:invalid_request), nil))
  end
end
~~~

Move the Plug's existing modern request validation, JSON/SSE response encoding, and HTTP status mapping into this module unchanged. Keep helpers private.

Expose one additional constructor for parser failures so an outer authenticated Plug can retain modern JSON-RPC error formatting:

~~~elixir
@spec parse_error(Plug.Conn.t()) :: Plug.Conn.t()
def parse_error(conn) do
  error = Error.protocol(:parse_error, %{message: "Invalid JSON"})
  respond(conn, Error.build_json_rpc(error, nil))
end
~~~

- [ ] **Step 5: Delegate the standalone Plug's modern branch**

~~~elixir
ModernRequest.call(conn, message, routing_context,
  server: opts.server,
  task_supervisor: opts.task_supervisor,
  timeout: opts.timeout,
  subscriptions: opts.subscriptions,
  transport: opts.transport
)
~~~

Do not change legacy dispatch.

- [ ] **Step 6: Run GREEN**

~~~bash
devenv shell -- bash -lc 'cd apps/backplane_mcp_protocol && MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/backplane/deps mix test test/backplane/mcp_protocol/server/transport/streamable_http/modern_request_test.exs test/backplane/mcp_protocol/server/transport/streamable_http/modern_plug_test.exs test/backplane/mcp_protocol/server/transport/streamable_http/plug_test.exs'
~~~

Expected: direct and standalone Plug paths remain identical.

- [ ] **Step 7: Commit the reusable modern seam**

~~~bash
git add apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/server/transport/streamable_http \
  apps/backplane_mcp_protocol/test/backplane/mcp_protocol/server/transport/streamable_http
git commit -m "refactor(mcp): expose modern HTTP request dispatch"
~~~

### Task 5: Extract shared Backplane MCP application dispatch

**Files:**

- Create: apps/backplane_mcp/lib/backplane/mcp/dispatch.ex
- Create: apps/backplane_mcp/test/backplane/mcp/dispatch_test.exs
- Modify: apps/backplane_mcp/lib/backplane/transport/mcp_handler.ex:100-1210
- Modify: apps/backplane_mcp/lib/backplane/transport/task_manager.ex:106
- Modify: apps/backplane_api/lib/backplane/api/channels/host_agent_channel.ex:177

- [ ] **Step 1: Run impact analysis**

~~~text
gitnexus_impact({target: "dispatch_tool_call", file_path: "apps/backplane_mcp/lib/backplane/transport/mcp_handler.ex", direction: "upstream", includeTests: true})
gitnexus_impact({target: "compute_result", file_path: "apps/backplane_mcp/lib/backplane/transport/mcp_handler.ex", direction: "upstream", includeTests: true})
~~~

Preserve McpHandler.dispatch_tool_call/3 as a compatibility delegate until TaskManager and HostAgentChannel move.

- [ ] **Step 2: Add neutral dispatch behavior tests**

~~~elixir
context = %{
  protocol_version: "2026-07-28",
  scopes: ["public::echo"],
  client: nil,
  auth: %{kind: :open, client_id: nil, scopes: ["public::echo"]}
}

assert {:ok, %{"tools" => tools}} = Dispatch.execute("tools/list", %{}, context)
assert [%{"name" => "public::echo"}] = Enum.filter(tools, &(&1["name"] == "public::echo"))

assert {:ok, %{"content" => _}} =
         Dispatch.execute(
           "tools/call",
           %{"name" => "public::echo", "arguments" => %{}},
           context
         )

assert {:error, :insufficient_scope, _message} =
         Dispatch.execute(
           "tools/call",
           %{"name" => "private::one", "arguments" => %{}},
           context
         )
~~~

- [ ] **Step 3: Run RED**

~~~bash
devenv shell -- mix test apps/backplane_mcp/test/backplane/mcp/dispatch_test.exs
~~~

Expected: Backplane.MCP.Dispatch is undefined.

- [ ] **Step 4: Create the shared API and move only common operations**

~~~elixir
defmodule Backplane.MCP.Dispatch do
  @type context :: %{
          required(:protocol_version) => String.t(),
          required(:scopes) => [String.t()],
          required(:auth) => map(),
          optional(:client) => map() | nil
        }

  @type error_kind ::
          :invalid_params | :not_found | :method_not_found | :insufficient_scope | :internal_error
  @type result :: {:ok, map()} | {:error, error_kind(), String.t()}

  def execute("tools/list", params, context), do: list_tools(params || %{}, context)
  def execute("tools/call", params, context), do: call_tool(params || %{}, context)
  def execute("resources/list", params, context), do: list_resources(params || %{}, context)
  def execute("resources/templates/list", _params, context), do: list_resource_templates(context)
  def execute("resources/read", params, context), do: read_resource(params || %{}, context)
  def execute("prompts/list", _params, context), do: list_prompts(context)
  def execute("prompts/get", params, context), do: get_prompt(params || %{}, context)
  def execute("completion/complete", params, _context), do: complete(params || %{})
  def execute(_method, _params, _context), do: {:error, :method_not_found, "Method not found"}

  @spec visible_tools(context()) :: [Backplane.Registry.Tool.t()]
  def visible_tools(context) do
    ToolRegistry.list_all()
    |> Enum.reject(&management_tool?(&1.name))
    |> Enum.filter(&Clients.scope_matches?(context.scopes, &1.name))
    |> Enum.sort_by(& &1.name)
  end
end
~~~

Move visible tool serialization, validation/call/result building, resource operations, prompt operations/authorization, completions, cache/audit side effects, and formatting from McpHandler. Return string-keyed payloads and semantic errors. Use Map.has_key?(result, "structuredContent") so false and explicit nil remain present.

Add these concrete assertions to the same test module:

~~~elixir
assert {:ok, %{"resources" => resources}} = Dispatch.execute("resources/list", %{}, context)
assert is_list(resources)
assert {:ok, %{"resourceTemplates" => templates}} =
         Dispatch.execute("resources/templates/list", %{}, context)
assert is_list(templates)
assert {:error, :not_found, _} =
         Dispatch.execute("resources/read", %{"uri" => "memory://missing"}, context)
assert {:ok, %{"prompts" => prompts}} = Dispatch.execute("prompts/list", %{}, context)
assert is_list(prompts)
assert {:error, :not_found, _} =
         Dispatch.execute("prompts/get", %{"name" => "missing"}, context)
assert {:ok, %{"completion" => %{"values" => values}}} =
         Dispatch.execute(
           "completion/complete",
           %{"ref" => %{"type" => "ref/tool", "name" => "public::echo"}, "argument" => %{"name" => "tool_name", "value" => "public"}},
           context
         )
assert is_list(values)
~~~

Leave initialize/session, ETag HTTP behavior, ping, logging, elicitation, legacy Tasks, envelopes, and notifications in McpHandler.

- [ ] **Step 5: Adapt legacy results without wire changes**

~~~elixir
defp legacy_dispatch(method, params, context) do
  case Dispatch.execute(method, params, context) do
    {:ok, result} -> {:result, result}
    {:error, :method_not_found, message} -> {:error, -32_601, message}
    {:error, :insufficient_scope, message} -> {:error, -32_001, message}
    {:error, kind, message} when kind in [:invalid_params, :not_found] ->
      {:error, -32_602, message}
    {:error, :internal_error, message} -> {:error, -32_603, message}
  end
end
~~~

Move TaskManager and HostAgentChannel to Dispatch or retain a one-line McpHandler delegate.

- [ ] **Step 6: Run GREEN**

~~~bash
devenv shell -- mix test \
  apps/backplane_mcp/test/backplane/mcp/dispatch_test.exs \
  apps/backplane_mcp/test/backplane/transport/mcp_handler_test.exs \
  apps/backplane_mcp/test/backplane/transport/managed_prompt_test.exs \
  apps/backplane_mcp/test/backplane/transport/prompt_get_test.exs \
  apps/backplane_mcp/test/integration/math_evaluate_round_trip_test.exs
~~~

Expected: shared application tests pass and legacy JSON remains unchanged.

- [ ] **Step 7: Commit shared dispatch**

~~~bash
git add apps/backplane_mcp/lib/backplane/mcp/dispatch.ex \
  apps/backplane_mcp/lib/backplane/transport/mcp_handler.ex \
  apps/backplane_mcp/lib/backplane/transport/task_manager.ex \
  apps/backplane_api/lib/backplane/api/channels/host_agent_channel.ex \
  apps/backplane_mcp/test/backplane/mcp/dispatch_test.exs
git commit -m "refactor(mcp): share hub application dispatch"
~~~

### Task 6: Classify public endpoint protocol eras

**Files:**

- Create: apps/backplane_mcp/lib/backplane/transport/mcp_era_router.ex
- Create: apps/backplane_mcp/test/backplane/transport/mcp_era_router_test.exs

- [ ] **Step 1: Add marker and conflict tests**

~~~elixir
test "keeps unmarked and initialize traffic legacy" do
  assert {:ok, :legacy} = EraRouter.route(request("ping"), [])

  assert {:ok, :legacy} =
           EraRouter.route(
             request("initialize", %{"protocolVersion" => "2026-07-28"}),
             []
           )
end

test "routes explicit modern markers" do
  assert {:ok, {:modern, %{version: "2026-07-28"}}} =
           EraRouter.route(modern_request("server/discover"), modern_headers("server/discover"))
end

test "rejects a modern marker combined with a legacy session" do
  headers = [{"mcp-session-id", "legacy"} | modern_headers("tools/list")]
  assert {:error, %Error{reason: :invalid_request}} =
           EraRouter.route(modern_request("tools/list"), headers)
end
~~~

Also assert an unknown version header returns unsupported_protocol_version through modern handling.

- [ ] **Step 2: Run RED**

~~~bash
devenv shell -- mix test apps/backplane_mcp/test/backplane/transport/mcp_era_router_test.exs
~~~

Expected: Backplane.Transport.McpEraRouter is undefined.

- [ ] **Step 3: Wrap the package ProfileRouter without duplicating parsing**

~~~elixir
defmodule Backplane.Transport.McpEraRouter do
  alias Backplane.McpProtocol.Protocol.Profile
  alias Backplane.McpProtocol.Protocol.Registry
  alias Backplane.McpProtocol.Server.ProfileRouter

  @modern_versions ["2026-07-28"]

  def route(message, headers) when is_map(message) and is_list(headers) do
    ProfileRouter.route(message, %{
      req_headers: headers,
      supported_versions: @modern_versions,
      connection_era: hard_connection_era(message, headers)
    })
  end

  def modern_header?(headers) when is_list(headers) do
    Enum.any?(headers, fn {name, value} ->
      if String.downcase(name) == "mcp-protocol-version" do
        case Registry.profile(value) do
          {:ok, %Profile{era: :legacy}} -> false
          _modern_or_unknown -> true
        end
      else
        false
      end
    end)
  end

  def era({:ok, :legacy}), do: :legacy
  def era(_modern_or_error), do: :modern

  defp hard_connection_era(%{"method" => "initialize"}, _headers), do: :legacy

  defp hard_connection_era(_message, headers) do
    if Enum.any?(headers, fn {name, _} -> String.downcase(name) == "mcp-session-id" end),
      do: :legacy,
      else: nil
  end
end
~~~

- [ ] **Step 4: Run GREEN**

~~~bash
devenv shell -- mix test apps/backplane_mcp/test/backplane/transport/mcp_era_router_test.exs
devenv shell -- bash -lc 'cd apps/backplane_mcp_protocol && MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/backplane/deps mix test test/backplane/mcp_protocol/server/profile_router_test.exs'
~~~

Expected: Backplane routing matches package profile routing.

- [ ] **Step 5: Commit era routing**

~~~bash
git add apps/backplane_mcp/lib/backplane/transport/mcp_era_router.ex \
  apps/backplane_mcp/test/backplane/transport/mcp_era_router_test.exs
git commit -m "feat(mcp): classify legacy and modern endpoint requests"
~~~

### Task 7: Add the stateless Backplane modern server adapter

**Files:**

- Create: apps/backplane_mcp/lib/backplane/mcp/modern_server.ex
- Create: apps/backplane_mcp/test/backplane/mcp/modern_server_test.exs
- Modify: apps/backplane_mcp/lib/backplane_mcp/application.ex:7-20

- [ ] **Step 1: Run supervision impact analysis**

~~~text
gitnexus_impact({target: "start", file_path: "apps/backplane_mcp/lib/backplane_mcp/application.ex", direction: "upstream", includeTests: true})
~~~

- [ ] **Step 2: Add direct Executor tests**

Start a Task.Supervisor, register an allowed and denied tool, and execute discovery/list/call with request-local scopes.

~~~elixir
assert {:response, %{"result" => discovery}} =
         Executor.execute(ModernServer, modern_request("server/discover", %{}), context,
           task_supervisor: task_supervisor,
           timeout: 1_000
         )

assert discovery["supportedVersions"] == ["2026-07-28"]
assert Map.keys(discovery["capabilities"]) |> Enum.sort() ==
         ~w(completions prompts resources tools)
refute Map.has_key?(discovery["capabilities"], "extensions")
refute Map.has_key?(discovery["capabilities"], "experimental")

assert {:response, %{"result" => %{"tools" => tools}}} =
         execute_modern("tools/list", %{}, context)

assert Enum.map(tools, & &1["name"]) == ["public::echo"]
~~~

Assert two calls do not change Backplane.Transport.Session.count().

- [ ] **Step 3: Run RED**

~~~bash
devenv shell -- mix test apps/backplane_mcp/test/backplane/mcp/modern_server_test.exs
~~~

Expected: Backplane.MCP.ModernServer is undefined.

- [ ] **Step 4: Implement the module-only adapter**

~~~elixir
defmodule Backplane.MCP.ModernServer do
  use Backplane.McpProtocol.Server,
    name: "backplane",
    version: Backplane.MCP.Info.version(),
    capabilities: [:tools, :resources, :prompts, :completion],
    protocol_versions: ["2026-07-28"],
    instructions: "Backplane is an MCP hub. Tools use prefix::name namespaces."

  alias Backplane.MCP.Dispatch
  alias Backplane.McpProtocol.MCP.Error
  alias Backplane.McpProtocol.Server.Component.Schema
  alias Backplane.McpProtocol.Server.Frame

  @impl true
  def init_request(context, frame) do
    dispatch_context = dispatch_context(context.assigns)

    frame =
      dispatch_context
      |> Dispatch.visible_tools()
      |> Enum.reduce(Frame.assign(frame, :dispatch_context, dispatch_context), fn tool, acc ->
        Frame.register_tool(acc, tool.name,
          title: tool.name,
          description: tool.description,
          input_schema: Schema.raw(tool.input_schema),
          output_schema: raw_optional(tool.output_schema),
          annotations: tool.annotations
        )
      end)

    {:ok, frame}
  end

  @impl true
  def handle_request(%{"method" => method} = request, frame) do
    case Dispatch.execute(method, request["params"] || %{}, frame.assigns.dispatch_context) do
      {:ok, result} -> {:reply, result, frame}
      {:error, kind, message} -> {:error, modern_error(kind, message), frame}
    end
  end

  defp dispatch_context(assigns) do
    auth = assigns[:resource_auth] || %{kind: :open, client_id: nil, scopes: ["*"]}

    %{
      protocol_version: "2026-07-28",
      scopes: assigns[:tool_scopes] || auth[:scopes] || ["*"],
      client: assigns[:client],
      auth: auth
    }
  end

  defp raw_optional(nil), do: nil
  defp raw_optional(schema), do: Schema.raw(schema)
end
~~~

Map method_not_found to Error.protocol(:method_not_found), invalid_params/not_found to Error.protocol(:invalid_params), insufficient_scope to Error.execution("insufficient_scope"), and internal_error to Error.protocol(:internal_error). Do not advertise Tasks, subscriptions, logging, or experimental capabilities.

- [ ] **Step 5: Supervise only callback tasks**

Add before Backplane.Proxy.Pool:

~~~elixir
{Task.Supervisor, name: Backplane.MCP.ModernTaskSupervisor}
~~~

Do not add a session registry, subscription hub, or listener.

- [ ] **Step 6: Run GREEN**

~~~bash
devenv shell -- mix test \
  apps/backplane_mcp/test/backplane/mcp/modern_server_test.exs \
  apps/backplane_mcp/test/backplane/mcp/dispatch_test.exs \
  apps/backplane_mcp/test/backplane/transport/mcp_handler_test.exs
~~~

Expected: stateless adapter and legacy suites pass.

- [ ] **Step 7: Commit the modern adapter**

~~~bash
git add apps/backplane_mcp/lib/backplane/mcp/modern_server.ex \
  apps/backplane_mcp/lib/backplane_mcp/application.ex \
  apps/backplane_mcp/test/backplane/mcp/modern_server_test.exs
git commit -m "feat(mcp): add the stateless Backplane server adapter"
~~~

### Task 8: Wire explicit modern traffic into /mcp

**Files:**

- Modify: apps/backplane_mcp/lib/backplane/transport/mcp_plug.ex:1-100
- Modify: apps/backplane_mcp/lib/backplane/transport/version_header.ex:1-20
- Modify: apps/backplane_mcp/lib/backplane/transport/mcp_handler.ex:425-620
- Create: apps/backplane_mcp/test/backplane/transport/modern_mcp_test.exs
- Modify: apps/backplane_mcp/test/backplane/transport/router_test.exs
- Modify: apps/backplane_mcp/test/backplane/transport/version_header_test.exs

- [ ] **Step 1: Run public-boundary impact analysis**

~~~text
gitnexus_impact({target: "call", file_path: "apps/backplane_mcp/lib/backplane/transport/mcp_plug.ex", direction: "upstream", includeTests: true})
gitnexus_impact({target: "handle", file_path: "apps/backplane_mcp/lib/backplane/transport/mcp_handler.ex", direction: "upstream", includeTests: true})
gitnexus_impact({target: "call", file_path: "apps/backplane_mcp/lib/backplane/transport/version_header.ex", direction: "upstream", includeTests: true})
~~~

Treat this as manually high risk even if GitNexus reports UNKNOWN.

- [ ] **Step 2: Add endpoint-level stateless tests**

~~~elixir
test "discovers and lists tools without creating a session" do
  before_count = Session.count()

  discover = modern_conn("server/discover", %{}, id: "discover") |> call_mcp()
  tools = modern_conn("tools/list", %{}, id: "tools") |> call_mcp()

  assert discover.status == 200
  assert get_resp_header(discover, "mcp-session-id") == []
  assert get_in(JSON.decode!(discover.resp_body), ["result", "supportedVersions"]) ==
           ["2026-07-28"]
  assert get_in(JSON.decode!(tools.resp_body), ["result", "resultType"]) == "complete"
  assert Session.count() == before_count
end

test "keeps unmarked initialize on the legacy default" do
  conn = legacy_initialize(%{"protocolVersion" => "2026-07-28"}) |> call_mcp()
  assert get_in(JSON.decode!(conn.resp_body), ["result", "protocolVersion"]) == "2025-11-25"
  assert [_session] = get_resp_header(conn, "mcp-session-id")
end
~~~

Add this table-driven removed-surface assertion:

~~~elixir
for method <- [
      "initialize",
      "ping",
      "logging/setLevel",
      "resources/subscribe",
      "resources/unsubscribe",
      "tasks/create",
      "tasks/get",
      "tasks/result",
      "tasks/cancel"
    ] do
  conn = modern_conn(method, %{}, id: method) |> call_mcp()
  assert conn.status == 404
  assert get_in(JSON.decode!(conn.resp_body), ["error", "code"]) == -32_601
end
~~~

Add explicit tests for missing clientCapabilities (-32602), header/body mismatch (-32020), unsupported version (-32022), a JSON batch (-32600), callback failure (-32603), scoped tools/list and tools/call, resources list/read, prompts list/get, and completion/complete. Reuse modern_conn/3 so every case carries required headers and metadata unless that requirement is the behavior under test.

- [ ] **Step 3: Run RED**

~~~bash
devenv shell -- mix test apps/backplane_mcp/test/backplane/transport/modern_mcp_test.exs
~~~

Expected: server/discover reaches the legacy handler or lacks modern result metadata.

- [ ] **Step 4: Parse once, assign route, and dispatch by era**

Move Plug.Parsers before Idempotency and insert:

~~~elixir
plug Plug.Parsers,
  parsers: [:json],
  pass: ["application/json"],
  json_decoder: Jason,
  length: 1_000_000,
  body_reader: {CacheBodyReader, :read_body, []}
plug :assign_mcp_route
plug Backplane.Transport.Idempotency
plug :dispatch

defp assign_mcp_route(conn, _opts) do
  route = McpEraRouter.route(conn.body_params, conn.req_headers)

  conn
  |> Plug.Conn.assign(:mcp_route, route)
  |> Plug.Conn.assign(:mcp_era, McpEraRouter.era(route))
end

post "/" do
  case conn.assigns.mcp_route do
    {:ok, :legacy} -> McpHandler.handle(conn)
    {:ok, {:modern, _profile}} -> dispatch_modern(conn)
    {:error, _error} -> dispatch_modern(conn)
  end
end
~~~

Build context only from trusted conn.assigns, req_headers, remote_ip, and type: :http. Call ModernRequest with ModernServer, ModernTaskSupervisor, configured timeout, and subscriptions: nil.

For GET/DELETE, a modern protocol header returns 405 before the legacy stream/session branch. Unmarked GET/DELETE remain unchanged.

In McpPlug.call/2's Plug.Parsers.ParseError rescue, use McpEraRouter.modern_header?(conn.req_headers). Modern-marked malformed JSON calls ModernRequest.parse_error(conn); unmarked malformed JSON retains the existing legacy 400 body.

- [ ] **Step 5: Report the selected version**

~~~elixir
def call(conn, _opts) do
  conn
  |> Plug.Conn.put_resp_header("x-backplane-version", @app_version)
  |> Plug.Conn.register_before_send(fn conn ->
    version = conn.assigns[:mcp_protocol_version] || Backplane.MCP.Info.protocol_version()
    Plug.Conn.put_resp_header(conn, "x-mcp-protocol-version", version)
  end)
end
~~~

Assign 2026-07-28 before modern dispatch. Assign the negotiated version during legacy initialize and the stored session version for subsequent calls.

- [ ] **Step 6: Run GREEN**

~~~bash
devenv shell -- mix test \
  apps/backplane_mcp/test/backplane/transport/modern_mcp_test.exs \
  apps/backplane_mcp/test/backplane/transport/router_test.exs \
  apps/backplane_mcp/test/backplane/transport/version_header_test.exs \
  apps/backplane_mcp/test/backplane/transport/mcp_handler_test.exs
~~~

Expected: modern endpoint tests pass and all legacy transport tests remain green.

- [ ] **Step 7: Commit endpoint activation**

~~~bash
git add apps/backplane_mcp/lib/backplane/transport \
  apps/backplane_mcp/test/backplane/transport/modern_mcp_test.exs \
  apps/backplane_mcp/test/backplane/transport/router_test.exs \
  apps/backplane_mcp/test/backplane/transport/version_header_test.exs
git commit -m "feat(mcp): serve explicit stateless modern requests"
~~~

### Task 9: Isolate browser and idempotency state

**Files:**

- Modify: apps/backplane_system/lib/backplane/transport/cors.ex:18-64
- Modify: apps/backplane_system/test/backplane/transport/cors_test.exs
- Modify: apps/backplane_mcp/lib/backplane/transport/idempotency.ex:18-108
- Modify: apps/backplane_mcp/test/backplane/transport/idempotency_test.exs
- Modify: apps/backplane_mcp/lib/backplane/transport/mcp_plug.ex

- [ ] **Step 1: Run impact analysis**

~~~text
gitnexus_impact({target: "call", file_path: "apps/backplane_system/lib/backplane/transport/cors.ex", direction: "upstream", includeTests: true})
gitnexus_impact({target: "call", file_path: "apps/backplane_mcp/lib/backplane/transport/idempotency.ex", direction: "upstream", includeTests: true})
~~~

- [ ] **Step 2: Add safe-preflight tests**

~~~elixir
conn =
  Plug.Test.conn(:options, "/mcp")
  |> put_req_header("origin", "http://localhost:3000")
  |> put_req_header(
    "access-control-request-headers",
    "MCP-Protocol-Version, Mcp-Method, Mcp-Name, Idempotency-Key, Mcp-Param-Region, X-Unsafe"
  )
  |> CORS.call([])

allowed = get_header(conn, "access-control-allow-headers")
assert allowed =~ "MCP-Protocol-Version"
assert allowed =~ "Mcp-Param-Region"
refute allowed =~ "X-Unsafe"
~~~

Also assert malformed Mcp-Param names are not reflected.

- [ ] **Step 3: Add idempotency-isolation tests**

Use the same external key with different authenticated client IDs, methods/names, and bodies. Assert no response crosses those boundaries. Add an Accept: text/event-stream request and assert it is never replayed as an ETS hit.

- [ ] **Step 4: Run RED**

~~~bash
devenv shell -- mix test \
  apps/backplane_system/test/backplane/transport/cors_test.exs \
  apps/backplane_mcp/test/backplane/transport/idempotency_test.exs
~~~

Expected: modern preflight headers are missing and external keys collide.

- [ ] **Step 5: Reflect only safe requested headers**

~~~elixir
@base_headers ~w(Content-Type Authorization Accept Mcp-Session-Id MCP-Protocol-Version Mcp-Method Mcp-Name Idempotency-Key)
@param_header ~r/\Amcp-param-[a-z0-9][a-z0-9-]*\z/i

defp allowed_headers(conn) do
  dynamic =
    conn
    |> get_req_header("access-control-request-headers")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&Regex.match?(@param_header, &1))

  Enum.join(Enum.uniq(@base_headers ++ dynamic), ", ")
end
~~~

- [ ] **Step 6: Build a composite cache key and skip SSE**

~~~elixir
defp cache_key(conn, external_key) do
  auth = conn.assigns[:resource_auth] || %{}
  message = conn.body_params || %{}

  identity = {
    auth[:kind],
    auth[:subject],
    auth[:client_id],
    conn.assigns[:mcp_era],
    message["method"],
    get_in(message, ["params", "name"]),
    :crypto.hash(:sha256, conn.assigns[:raw_body] || "")
  }

  {external_key, identity}
end
~~~

Use the composite term in ETS. Do not store text/event-stream responses, chunked responses, or non-binary bodies.

- [ ] **Step 7: Run GREEN**

~~~bash
devenv shell -- mix test \
  apps/backplane_system/test/backplane/transport/cors_test.exs \
  apps/backplane_mcp/test/backplane/transport/idempotency_test.exs \
  apps/backplane_mcp/test/backplane/transport/modern_mcp_test.exs \
  apps/backplane_mcp/test/backplane/transport/router_test.exs
~~~

Expected: safe browser headers and identity-isolated idempotency pass.

- [ ] **Step 8: Commit cross-request isolation**

~~~bash
git add apps/backplane_system/lib/backplane/transport/cors.ex \
  apps/backplane_system/test/backplane/transport/cors_test.exs \
  apps/backplane_mcp/lib/backplane/transport/idempotency.ex \
  apps/backplane_mcp/lib/backplane/transport/mcp_plug.ex \
  apps/backplane_mcp/test/backplane/transport/idempotency_test.exs
git commit -m "fix(mcp): isolate modern HTTP request state"
~~~

### Task 10: Persist and expose upstream protocol preference

**Files:**

- Create: apps/backplane_system/priv/repo/migrations/20260818000001_add_protocol_version_to_mcp_upstreams.exs
- Modify: apps/backplane_mcp/lib/backplane/proxy/mcp_upstream.ex:14-50
- Modify: apps/backplane_mcp/lib/backplane/proxy/upstreams.ex:1-100
- Modify: apps/backplane/lib/backplane/application.ex:74-104
- Modify: apps/backplane_admin/lib/backplane/admin/live/upstreams_live.ex:32-360,420-660
- Modify: apps/backplane_mcp/lib/backplane/proxy/upstream.ex:181-195
- Modify: apps/backplane_mcp/test/backplane/proxy/mcp_upstream_test.exs
- Modify: apps/backplane_mcp/test/backplane/proxy/upstream_test.exs
- Modify: apps/backplane_admin/test/backplane/admin/live/upstreams_live_test.exs

- [ ] **Step 1: Load required Ecto/Phoenix/DuskMoon skills**

Read ecto-thinking, phoenix-thinking, phoenix-duskmoon-design, and phoenix-duskmoon-ui before editing.

- [ ] **Step 2: Run impact analysis**

~~~text
gitnexus_impact({target: "changeset", file_path: "apps/backplane_mcp/lib/backplane/proxy/mcp_upstream.ex", direction: "upstream", includeTests: true})
gitnexus_impact({target: "start_db_upstreams", file_path: "apps/backplane/lib/backplane/application.ex", direction: "upstream", includeTests: true})
gitnexus_impact({target: "runtime_config", file_path: "apps/backplane_admin/lib/backplane/admin/live/upstreams_live.ex", direction: "upstream", includeTests: true})
~~~

- [ ] **Step 3: Add defaults, validation, and UI tests**

~~~elixir
test "defaults protocol preference to the legacy version" do
  changeset = changeset(valid_http_attrs())
  assert Ecto.Changeset.get_field(changeset, :protocol_version) == "2025-11-25"
end

test "accepts only supported preferences" do
  for value <- ["2025-11-25", "2026-07-28", "auto"] do
    assert changeset(Map.put(valid_http_attrs(), :protocol_version, value)).valid?
  end

  refute changeset(Map.put(valid_http_attrs(), :protocol_version, "latest")).valid?
end
~~~

In LiveView tests, assert the form field exists, defaults to 2025-11-25, persists 2026-07-28, and renders configured plus negotiated status.

- [ ] **Step 4: Run RED**

~~~bash
devenv shell -- mix test \
  apps/backplane_mcp/test/backplane/proxy/mcp_upstream_test.exs \
  apps/backplane_admin/test/backplane/admin/live/upstreams_live_test.exs
~~~

Expected: field and control are missing.

- [ ] **Step 5: Add migration and schema**

~~~elixir
defmodule Backplane.Repo.Migrations.AddProtocolVersionToMcpUpstreams do
  use Ecto.Migration

  def change do
    alter table(:mcp_upstreams) do
      add :protocol_version, :string, null: false, default: "2025-11-25"
    end
  end
end
~~~

Add field :protocol_version, :string, default: "2025-11-25"; cast it and validate inclusion in ["2025-11-25", "2026-07-28", "auto"].

- [ ] **Step 6: Centralize runtime mapping**

~~~elixir
@spec runtime_config(%McpUpstream{}) :: map()
def runtime_config(%McpUpstream{} = upstream) do
  %{
    name: upstream.name,
    prefix: upstream.prefix,
    transport: upstream.transport,
    protocol_version: upstream.protocol_version || "2025-11-25",
    url: upstream.url,
    command: upstream.command,
    args: upstream.args || [],
    timeout: upstream.timeout_ms,
    refresh_interval: upstream.refresh_interval_ms,
    headers: upstream.headers || %{},
    credential: upstream.credential,
    auth_scheme: upstream.auth_scheme || "none",
    auth_header_name: upstream.auth_header_name
  }
end
~~~

Use Upstreams.runtime_config/1 from Backplane.Application and UpstreamsLive; delete duplicate maps.

- [ ] **Step 7: Add DuskMoon selector and status**

~~~heex
<.dm_select
  id="upstream-protocol-version"
  name="mcp_upstream[protocol_version]"
  label="Protocol preference"
  options={[
    {"2025-11-25", "2025-11-25 (legacy default)"},
    {"2026-07-28", "2026-07-28 (strict modern)"},
    {"auto", "Auto (modern discovery, classified legacy fallback)"}
  ]}
  value={Phoenix.HTML.Form.input_value(@form, :protocol_version) || "2025-11-25"}
/>
~~~

Render protocol_preference, negotiated_version, era, and negotiation_status when present. Never render credentials.

Until Task 13 replaces the wire client, extend the existing status map without changing its behavior:

~~~elixir
protocol_preference = state.config[:protocol_version] || "2025-11-25"

info = %{
  name: state.name,
  prefix: state.prefix,
  transport: state.transport,
  status: state.status,
  tool_count: length(state.tools),
  last_ping_at: state.last_ping_at,
  last_pong_at: state.last_pong_at,
  consecutive_ping_failures: state.consecutive_ping_failures,
  post_url_known: false,
  protocol_preference: protocol_preference,
  negotiated_version: state.upstream_version,
  era: if(state.initialized, do: :legacy, else: nil),
  negotiation_status: if(state.initialized, do: :ready, else: :connecting)
}
~~~

- [ ] **Step 8: Apply the migration**

~~~bash
devenv shell -- mix ecto.migrate
~~~

Expected: the migration adds the non-null default without rewriting unrelated tables.

- [ ] **Step 9: Run GREEN**

~~~bash
devenv shell -- mix test \
  apps/backplane_mcp/test/backplane/proxy/mcp_upstream_test.exs \
  apps/backplane_admin/test/backplane/admin/live/upstreams_live_test.exs
~~~

Expected: schema, form, runtime mapping, and status tests pass.

- [ ] **Step 10: Commit persisted preference**

~~~bash
git add apps/backplane_system/priv/repo/migrations/20260818000001_add_protocol_version_to_mcp_upstreams.exs \
  apps/backplane_mcp/lib/backplane/proxy/mcp_upstream.ex \
  apps/backplane_mcp/lib/backplane/proxy/upstreams.ex \
  apps/backplane/lib/backplane/application.ex \
  apps/backplane_admin/lib/backplane/admin/live/upstreams_live.ex \
  apps/backplane_mcp/lib/backplane/proxy/upstream.ex \
  apps/backplane_mcp/test/backplane/proxy/mcp_upstream_test.exs \
  apps/backplane_mcp/test/backplane/proxy/upstream_test.exs \
  apps/backplane_admin/test/backplane/admin/live/upstreams_live_test.exs
git commit -m "feat(mcp): persist upstream protocol preferences"
~~~

### Task 11: Supervise reusable protocol clients

**Files:**

- Create: apps/backplane_mcp/lib/backplane/proxy/client_pool.ex
- Create: apps/backplane_mcp/lib/backplane/proxy/protocol_client.ex
- Create: apps/backplane_mcp/test/backplane/proxy/protocol_client_test.exs
- Modify: apps/backplane_mcp/lib/backplane_mcp/application.ex:12-18
- Modify: apps/backplane_mcp/test/backplane/proxy/pool_test.exs

- [ ] **Step 1: Load OTP guidance and run impact analysis**

Read otp-thinking, then run:

~~~text
gitnexus_impact({target: "start", file_path: "apps/backplane_mcp/lib/backplane_mcp/application.ex", direction: "upstream", includeTests: true})
gitnexus_impact({target: "start_upstream", file_path: "apps/backplane_mcp/lib/backplane/proxy/pool.ex", direction: "upstream", includeTests: true})
~~~

- [ ] **Step 2: Add naming, selector, and credential-provider tests**

~~~elixir
assert ProtocolClient.protocol_preference(%{protocol_version: "2025-11-25"}) == "2025-11-25"
assert ProtocolClient.protocol_preference(%{protocol_version: "2026-07-28"}) == "2026-07-28"
assert ProtocolClient.protocol_preference(%{protocol_version: "auto"}) == :auto

assert {:via, Registry, {Backplane.Proxy.ProcessRegistry, {"github", :client}}} =
         ProtocolClient.client_name("github")

assert {:via, Registry, {Backplane.Proxy.ProcessRegistry, {"github", :transport}}} =
         ProtocolClient.transport_name("github")
~~~

Rotate a credential through the existing credential test seam and call the generated provider twice; expect two bearer values.

- [ ] **Step 3: Run RED**

~~~bash
devenv shell -- mix test apps/backplane_mcp/test/backplane/proxy/protocol_client_test.exs
~~~

Expected: ClientPool, ProcessRegistry, and ProtocolClient are undefined.

- [ ] **Step 4: Add Registry and temporary DynamicSupervisor**

~~~elixir
defmodule Backplane.Proxy.ClientPool do
  use DynamicSupervisor

  def start_link(opts), do: DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  def start_client(opts) do
    spec = Backplane.McpProtocol.Client.child_spec(opts) |> Map.put(:restart, :temporary)
    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  def stop_client(pid), do: DynamicSupervisor.terminate_child(__MODULE__, pid)
end
~~~

Add before Backplane.Proxy.Pool:

~~~elixir
{Registry, keys: :unique, name: Backplane.Proxy.ProcessRegistry},
Backplane.Proxy.ClientPool,
~~~

- [ ] **Step 5: Build options in ProtocolClient**

~~~elixir
def client_name(prefix),
  do: {:via, Registry, {Backplane.Proxy.ProcessRegistry, {prefix, :client}}}

def transport_name(prefix),
  do: {:via, Registry, {Backplane.Proxy.ProcessRegistry, {prefix, :transport}}}

def protocol_preference(%{protocol_version: "auto"}), do: :auto
def protocol_preference(%{protocol_version: version})
    when version in ["2025-11-25", "2026-07-28"],
    do: version
def protocol_preference(_config), do: "2025-11-25"

def client_options(config) do
  [
    name: client_name(config.prefix),
    transport_name: transport_name(config.prefix),
    protocol_version: protocol_preference(config),
    client_info: %{"name" => "backplane", "version" => Backplane.MCP.Info.version()},
    capabilities: %{},
    timeout: config[:timeout] || 30_000,
    transport: transport_options(config)
  ]
end

def error_message(%Backplane.McpProtocol.MCP.Error{reason: reason}) when is_atom(reason),
  do: Atom.to_string(reason)
def error_message(%Backplane.McpProtocol.MCP.Error{}), do: "upstream protocol error"
def error_message(_other), do: "upstream connection error"
~~~

HTTP transport uses exact url, static configured headers, and a per-request provider that calls AuthInjector. Stdio uses command, args, env. Lower-case provider keys and include current request ID without retaining it.

- [ ] **Step 6: Run GREEN**

~~~bash
devenv shell -- mix test \
  apps/backplane_mcp/test/backplane/proxy/protocol_client_test.exs \
  apps/backplane_mcp/test/backplane/proxy/pool_test.exs
~~~

Expected: registry names, temporary supervision, selector mapping, and dynamic credentials pass.

- [ ] **Step 7: Commit client supervision**

~~~bash
git add apps/backplane_mcp/lib/backplane/proxy/client_pool.ex \
  apps/backplane_mcp/lib/backplane/proxy/protocol_client.ex \
  apps/backplane_mcp/lib/backplane_mcp/application.ex \
  apps/backplane_mcp/test/backplane/proxy/protocol_client_test.exs \
  apps/backplane_mcp/test/backplane/proxy/pool_test.exs
git commit -m "feat(mcp): supervise upstream protocol clients"
~~~

### Task 12: Preserve and bound upstream catalogs

**Files:**

- Create: apps/backplane_mcp/lib/backplane/proxy/tool_catalog.ex
- Create: apps/backplane_mcp/test/backplane/proxy/tool_catalog_test.exs
- Modify: apps/backplane_system/lib/backplane/registry/tool.ex:1-40
- Modify: apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/server/component/tool.ex
- Modify: apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/server/frame.ex:120-190
- Modify: apps/backplane_mcp/lib/backplane/mcp/modern_server.ex
- Create: apps/backplane_mcp_protocol/test/backplane/mcp_protocol/server/component/tool_icons_test.exs

- [ ] **Step 1: Run impact analysis**

~~~text
gitnexus_impact({target: "Backplane.Registry.Tool", direction: "upstream", includeTests: true})
gitnexus_impact({target: "register_tool", file_path: "apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/server/frame.ex", direction: "upstream", includeTests: true})
~~~

- [ ] **Step 2: Add lossless normalization and bounded-pagination tests**

~~~elixir
raw = %{
  "name" => "lookup",
  "title" => "Lookup",
  "description" => "Find one record",
  "inputSchema" => %{"$schema" => "https://json-schema.org/draft/2020-12/schema", "type" => "object"},
  "outputSchema" => %{"oneOf" => [%{"type" => "boolean"}, %{"type" => "null"}]},
  "annotations" => %{"readOnlyHint" => true},
  "icons" => [%{"src" => "https://example.test/icon.svg"}],
  "_meta" => %{"vendor" => %{"stable" => true}},
  "execution" => %{"taskSupport" => "forbidden"}
}

assert {:ok, tool} = ToolCatalog.normalize(raw, "search", self(), 30_000)
assert tool.title == "Lookup"
assert tool.input_schema == raw["inputSchema"]
assert tool.output_schema == raw["outputSchema"]
assert tool.icons == raw["icons"]
assert tool.meta == raw["_meta"]
assert tool.execution == raw["execution"]
~~~

Assert invalid names fail, pagination follows distinct cursors, repeated cursors fail, page count is capped at 100, and failures never return a partial catalog.

- [ ] **Step 3: Run RED**

~~~bash
devenv shell -- mix test apps/backplane_mcp/test/backplane/proxy/tool_catalog_test.exs
~~~

Expected: ToolCatalog and modern fields are undefined.

- [ ] **Step 4: Extend internal tool data**

Add title, meta, execution, and icons to Backplane.Registry.Tool while retaining singular legacy icon. Extend the protocol package component Tool, JSON encoder, and Frame.register_tool/3 with icons. Store execution internally but do not expose task support from ModernServer while Tasks are unadvertised.

Update ModernServer's request-frame projection only after those fields exist:

~~~elixir
Frame.register_tool(acc, tool.name,
  title: tool.title || tool.name,
  description: tool.description,
  input_schema: Schema.raw(tool.input_schema),
  output_schema: raw_optional(tool.output_schema),
  annotations: tool.annotations,
  meta: tool.meta,
  icons: tool.icons
)
~~~

- [ ] **Step 5: Implement normalization**

~~~elixir
@max_pages 100

def normalize(%{"name" => name} = raw, prefix, upstream_pid, timeout)
    when is_binary(name) and name != "" do
  {:ok,
   %Tool{
     name: name,
     title: raw["title"],
     description: Map.get(raw, "description", ""),
     input_schema: Map.get(raw, "inputSchema", %{}),
     output_schema: raw["outputSchema"],
     annotations: raw["annotations"],
     icon: raw["icon"],
     icons: raw["icons"],
     meta: raw["_meta"],
     execution: raw["execution"],
     origin: {:upstream, prefix},
     upstream_pid: upstream_pid,
     original_name: name,
     timeout: timeout
   }}
end

def normalize(_raw, _prefix, _pid, _timeout), do: {:error, :invalid_tool}

def normalize_all(raw_tools, prefix, upstream_pid, timeout) do
  Enum.reduce_while(raw_tools, {:ok, []}, fn raw, {:ok, tools} ->
    case normalize(raw, prefix, upstream_pid, timeout) do
      {:ok, tool} -> {:cont, {:ok, [tool | tools]}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end)
  |> case do
    {:ok, tools} -> {:ok, Enum.reverse(tools)}
    error -> error
  end
end

def fetch_all(page_fun), do: fetch_pages(page_fun, nil, MapSet.new(), [], 0)

defp fetch_pages(_page_fun, _cursor, _seen, _tools, pages) when pages >= @max_pages,
  do: {:error, :too_many_pages}

defp fetch_pages(page_fun, cursor, seen, tools, pages) do
  with {:ok, %Response{result: %{"tools" => page_tools} = result}} <- page_fun.(cursor),
       true <- is_list(page_tools) do
    case result["nextCursor"] do
      nil -> {:ok, tools ++ page_tools}
      next when is_binary(next) ->
        if MapSet.member?(seen, next) do
          {:error, :cursor_cycle}
        else
          fetch_pages(page_fun, next, MapSet.put(seen, next), tools ++ page_tools, pages + 1)
        end
      _invalid -> {:error, :invalid_cursor}
    end
  else
    {:error, reason} -> {:error, reason}
    _invalid -> {:error, :invalid_catalog_page}
  end
end
~~~

- [ ] **Step 6: Run GREEN**

~~~bash
devenv shell -- mix test apps/backplane_mcp/test/backplane/proxy/tool_catalog_test.exs
devenv shell -- bash -lc 'cd apps/backplane_mcp_protocol && MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/backplane/deps mix test test/backplane/mcp_protocol/server/component test/backplane/mcp_protocol/server/response_test.exs'
~~~

Expected: catalogs preserve fields and pagination fails atomically.

- [ ] **Step 7: Commit catalog preservation**

~~~bash
git add apps/backplane_mcp/lib/backplane/proxy/tool_catalog.ex \
  apps/backplane_mcp/test/backplane/proxy/tool_catalog_test.exs \
  apps/backplane_system/lib/backplane/registry/tool.ex \
  apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/server/component/tool.ex \
  apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/server/frame.ex \
  apps/backplane_mcp/lib/backplane/mcp/modern_server.ex \
  apps/backplane_mcp_protocol/test/backplane/mcp_protocol/server/component
git commit -m "feat(mcp): preserve upstream tool catalogs"
~~~

### Task 13: Move Upstream onto the reusable client

**Files:**

- Modify: apps/backplane_mcp/lib/backplane/proxy/upstream.ex:1-792
- Modify: apps/backplane_mcp/test/backplane/proxy/upstream_test.exs
- Modify: apps/backplane_mcp/test/support/mock_mcp_plug.ex
- Modify: apps/backplane_mcp/test/support/mock_stdio_mcp.sh

- [ ] **Step 1: Run coordinator impact analysis**

~~~text
gitnexus_impact({target: "forward", file_path: "apps/backplane_mcp/lib/backplane/proxy/upstream.ex", direction: "upstream", includeTests: true})
gitnexus_impact({target: "status", file_path: "apps/backplane_mcp/lib/backplane/proxy/upstream.ex", direction: "upstream", includeTests: true})
gitnexus_impact({target: "handle_continue", file_path: "apps/backplane_mcp/lib/backplane/proxy/upstream.ex", direction: "upstream", includeTests: true})
~~~

Preserve start_link/1, forward/4, status/1, and refresh/1.

- [ ] **Step 2: Upgrade fixtures to record methods/headers**

Support server/discover, initialize, tools/list, tools/call, and ping. Add a modern-only mode that fails if initialize, a session header, or ping appears. Give stdio the same modes.

- [ ] **Step 3: Add default, modern, auto, status, credential, health, and recovery tests**

~~~elixir
assert_receive {:upstream_method, "initialize"}
refute_receive {:upstream_method, "server/discover"}, 50

assert %{protocol_preference: "2025-11-25", era: :legacy, negotiated_version: "2025-11-25"} =
         Upstream.status(legacy_pid)

assert_receive {:upstream_method, "server/discover"}
refute_receive {:upstream_method, "initialize"}, 50

assert %{protocol_preference: "2026-07-28", era: :modern, negotiated_version: "2026-07-28"} =
         Upstream.status(modern_pid)
~~~

For auto, test modern success, recognized legacy fallback, and no fallback on 500/malformed JSON. Rotate a credential after readiness. Trigger modern health and assert no ping. Kill the client supervisor and assert tools deregister before backoff recovery.

Make the modern fixture return one resultType: input_required tool response that requires sampling while Backplane advertises outbound capabilities %{}. Assert Upstream.forward/4 returns a sanitized missing-capability error, emits only one tools/call request, and performs no MRTR retry or callback.

- [ ] **Step 4: Run RED**

~~~bash
devenv shell -- mix test apps/backplane_mcp/test/backplane/proxy/upstream_test.exs
~~~

Expected: the handwritten implementation always initializes and lacks approved status fields.

- [ ] **Step 5: Replace wire state with protocol-client state**

~~~elixir
%{
  name: config.name,
  prefix: config.prefix,
  transport: config.transport,
  config: config,
  client: ProtocolClient.client_name(config.prefix),
  client_supervisor: nil,
  client_monitor: nil,
  protocol_preference: ProtocolClient.protocol_preference(config),
  negotiated_version: nil,
  era: nil,
  negotiation_status: :connecting,
  tools: [],
  status: :connecting,
  reconnect_attempts: 0,
  consecutive_call_failures: 0,
  last_health_at: nil,
  tool_timeout: config[:timeout] || 30_000,
  refresh_interval: config[:refresh_interval]
}
~~~

In handle_continue, start the temporary tree outside the negotiation helper so every later failure can stop it:

~~~elixir
case ClientPool.start_client(ProtocolClient.client_options(state.config)) do
  {:ok, supervisor} ->
    monitor = Process.monitor(supervisor)

    case connect_client(state, supervisor, monitor) do
      {:ok, connected} ->
        {:ok, connected}

      {:error, reason} ->
        Process.demonitor(monitor, [:flush])
        _ = ClientPool.stop_client(supervisor)
        ToolRegistry.deregister_upstream(state.prefix)
        schedule_reconnect(state.reconnect_attempts)
        {:error, ProtocolClient.error_message(reason), %{state | reconnect_attempts: state.reconnect_attempts + 1}}
    end

  {:error, reason} ->
    schedule_reconnect(state.reconnect_attempts)
    {:error, ProtocolClient.error_message(reason), %{state | reconnect_attempts: state.reconnect_attempts + 1}}
end

defp connect_client(state, supervisor, monitor) do
  with :ok <- Client.await_ready(state.client, timeout: state.tool_timeout),
       info <- Client.get_protocol_info(state.client),
       {:ok, raw_tools} <- ToolCatalog.fetch_all(&list_tools_page(state.client, &1)),
       {:ok, tools} <- ToolCatalog.normalize_all(raw_tools, state.prefix, self(), state.tool_timeout) do
    ToolRegistry.register_upstream(state.prefix, self(), tools)

    {:ok,
     %{state |
       client_supervisor: supervisor,
       client_monitor: monitor,
       protocol_preference: info.protocol_preference,
       negotiated_version: info.negotiated_version,
       era: info.era,
       negotiation_status: info.negotiation_status,
       tools: tools,
       status: :connected,
       reconnect_attempts: 0}}
  end
end

defp list_tools_page(client, nil), do: Client.list_tools(client)
defp list_tools_page(client, cursor), do: Client.list_tools(client, cursor: cursor)
~~~

- [ ] **Step 6: Forward and health through Client**

~~~elixir
def handle_call({:tools_call, name, arguments}, _from, state) do
  result =
    case Client.call_tool(state.client, name, arguments, timeout: state.tool_timeout) do
      {:ok, %Response{result: result}} -> {:ok, result}
      {:error, error} -> {:error, ProtocolClient.error_message(error)}
    end

  {:reply, result, track_call_result(state, result)}
end
~~~

Refresh uses bounded list_tools pagination. Legacy health uses Client.ping/2; modern health uses a list refresh. Handle monitored client DOWN by deregistering, clearing names/PIDs, marking disconnected, and scheduling one reconnect. terminate/2 stops the tree and deregisters.

Delete handwritten Req/Port/buffer/request-ID/SSE/stdio wire code only after tests pass. Do not delete standalone SSE modules unless repository-wide search proves no callers.

- [ ] **Step 7: Run GREEN**

~~~bash
devenv shell -- mix test \
  apps/backplane_mcp/test/backplane/proxy/upstream_test.exs \
  apps/backplane_mcp/test/backplane/proxy/pool_test.exs \
  apps/backplane_mcp/test/backplane/transport/health_check_test.exs \
  apps/backplane_mcp/test/backplane/tools/hub_test.exs \
  apps/backplane_admin/test/backplane/admin/live/upstreams_live_test.exs
~~~

Expected: legacy, modern, auto, credential, health, recovery, and existing hub tests pass.

- [ ] **Step 8: Commit the protocol-client proxy**

~~~bash
git add apps/backplane_mcp/lib/backplane/proxy/upstream.ex \
  apps/backplane_mcp/test/backplane/proxy/upstream_test.exs \
  apps/backplane_mcp/test/support/mock_mcp_plug.ex \
  apps/backplane_mcp/test/support/mock_stdio_mcp.sh
git commit -m "feat(mcp): proxy upstreams through the protocol client"
~~~

### Task 14: Prove end-to-end dual-era behavior

**Files:**

- Create: apps/backplane_mcp/test/support/modern_upstream_server.ex
- Create: apps/backplane_mcp/test/integration/modern_proxy_round_trip_test.exs
- Modify: README.md:9-12,65-83,149-180
- Modify: apps/backplane_mcp_protocol/README.md

- [ ] **Step 1: Add real modern fixture and failing round-trip test**

~~~elixir
defmodule Backplane.Test.ModernUpstreamServer do
  use Backplane.McpProtocol.Server,
    name: "backplane-modern-upstream-test",
    version: "1.0.0",
    capabilities: [:tools],
    protocol_versions: ["2026-07-28"]

  alias Backplane.McpProtocol.Server.{Frame, Handlers, Response}

  @impl true
  def init_request(_context, frame) do
    {:ok,
     Frame.register_tool(frame, "echo",
       description: "Echo arguments",
       input_schema: %{"type" => "object", "additionalProperties" => true}
     )}
  end

  @impl true
  def handle_request(request, frame), do: Handlers.handle(request, __MODULE__, frame)

  @impl true
  def handle_tool_call("echo", arguments, frame) do
    {:reply, Response.structured(Response.tool(), arguments), frame}
  end
end
~~~

Mount it through the package Plug in a test server. Start a strict-modern Backplane Upstream and wait by monotonic deadline, not fixed sleep.

~~~elixir
assert {:ok, %{"structuredContent" => %{"value" => false}}} =
         Upstream.forward(pid, "echo", %{"value" => false})

response = modern_endpoint_tool_call("modern::echo", %{"value" => nil})
assert get_in(response, ["result", "structuredContent", "value"]) == nil
assert response["result"]["resultType"] == "complete"
~~~

Also assert no downstream session header.

- [ ] **Step 2: Run RED**

~~~bash
devenv shell -- mix test apps/backplane_mcp/test/integration/modern_proxy_round_trip_test.exs
~~~

Expected: modern upstream connection or downstream structured-content preservation is incomplete.

- [ ] **Step 3: Add a bounded readiness helper and finish through public APIs**

~~~elixir
defp eventually(fun, timeout_ms \\ 2_000) do
  deadline = System.monotonic_time(:millisecond) + timeout_ms
  do_eventually(fun, deadline)
end

defp do_eventually(fun, deadline) do
  if fun.() do
    true
  else
    if System.monotonic_time(:millisecond) >= deadline do
      false
    else
      Process.sleep(10)
      do_eventually(fun, deadline)
    end
  end
end
~~~

Start the fixture with start_supervised!/1, start the upstream through Pool.start_upstream/1, wait until Upstream.status(pid).negotiation_status == :ready, invoke Upstream.forward/4, then invoke the public McpPlug with a modern tools/call request. Add no production-only testing hook.

- [ ] **Step 4: Document compatibility and new package options**

Add:

~~~markdown
### MCP protocol compatibility

The public /mcp endpoint defaults to legacy 2025-11-25 and continues to accept
2024-11-05, 2025-03-26, and 2025-06-18 through legacy initialization.
Clients explicitly marked for 2026-07-28 use stateless discovery and requests.

Each upstream selects 2025-11-25 (default), 2026-07-28 (strict modern), or
auto (modern discovery with classified legacy fallback). Downstream and upstream
protocol eras are independent.
~~~

Document exact url: and headers_provider: in the package README, including provider return shapes.

- [ ] **Step 5: Run scoped application suites**

~~~bash
devenv shell -- mix test \
  apps/backplane_mcp/test/backplane/mcp \
  apps/backplane_mcp/test/backplane/proxy \
  apps/backplane_mcp/test/backplane/transport \
  apps/backplane_mcp/test/integration \
  apps/backplane_auth/test \
  apps/backplane_system/test/backplane/transport \
  apps/backplane_admin/test/backplane/admin/live/upstreams_live_test.exs
~~~

Expected: all in-scope tests pass. Report and stop for out-of-scope failures.

- [ ] **Step 6: Run complete protocol-package suite**

~~~bash
devenv shell -- bash -lc 'cd apps/backplane_mcp_protocol && MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/backplane/deps mix test'
~~~

Expected: package unit/integration/doctests pass. Prior reference: 33 doctests, 1288 tests, 0 failures, 11 excluded.

- [ ] **Step 7: Run frozen official conformance**

Terminal 1:

~~~bash
devenv shell -- bash -lc 'cd apps/backplane_mcp_protocol && MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/backplane/deps mix run --no-halt test/conformance/server_runner.exs -- 4105'
~~~

Terminal 2:

~~~bash
npx -y @modelcontextprotocol/conformance@0.2.0-alpha.11 server \
  --url http://127.0.0.1:4105/mcp \
  --requirements 2026-07-28

devenv shell -- bash -lc 'cd apps/backplane_mcp_protocol && MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/backplane/deps mix compile'

cd apps/backplane_mcp_protocol
npx -y @modelcontextprotocol/conformance@0.2.0-alpha.11 client \
  --command "ERL_LIBS=../../_build/test/lib elixir test/conformance/client_runner.exs --" \
  --requirements 2026-07-28
~~~

Expected: every scored server and client scenario passes. Optional Tasks/auth extension scenarios remain unsupported per test/conformance/PIN.md.

- [ ] **Step 8: Prove the real endpoint in both eras**

After coordinating the currently running devenv process, start this worktree's service.

Legacy:

~~~bash
curl --fail-with-body --silent --show-error \
  -H 'content-type: application/json' \
  -H 'accept: application/json, text/event-stream' \
  --data '{"jsonrpc":"2.0","id":"legacy","method":"initialize","params":{"capabilities":{},"clientInfo":{"name":"live-legacy","version":"1"}}}' \
  http://127.0.0.1:4220/mcp | jq -e '.result.protocolVersion == "2025-11-25"'
~~~

Modern:

~~~bash
curl --fail-with-body --silent --show-error \
  -H 'content-type: application/json' \
  -H 'accept: application/json, text/event-stream' \
  -H 'MCP-Protocol-Version: 2026-07-28' \
  -H 'Mcp-Method: server/discover' \
  --data '{"jsonrpc":"2.0","id":"modern","method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{},"io.modelcontextprotocol/clientInfo":{"name":"live-modern","version":"1"}}}}' \
  http://127.0.0.1:4220/mcp | jq -e '.result.supportedVersions == ["2026-07-28"] and .result.resultType == "complete"'
~~~

Verify zero process restarts, modern tools/list, and one real namespaced tools/call.

- [ ] **Step 9: Run format, diff, and graph checks**

~~~bash
devenv shell -- mix format --check-formatted
git diff --check
~~~

Then:

~~~text
gitnexus_detect_changes({scope: "all", repo: "backplane"})
~~~

Expected: only approved protocol seams, endpoint, proxy, migration/admin, tests, and docs. Review unexpected flows.

- [ ] **Step 10: Commit integration proof**

~~~bash
git add README.md \
  apps/backplane_mcp_protocol/README.md \
  apps/backplane_mcp/test/support/modern_upstream_server.ex \
  apps/backplane_mcp/test/integration/modern_proxy_round_trip_test.exs
git commit -m "test(mcp): prove dual-era runtime integration"
~~~

Do not bump versions, push, release, or deploy.
