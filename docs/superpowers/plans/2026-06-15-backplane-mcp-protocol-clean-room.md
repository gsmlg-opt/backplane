# Backplane MCP Protocol Clean-Room Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a first-party `apps/backplane_mcp_protocol` umbrella app that implements the MCP protocol under the `Backplane.McpProtocol` namespace, then migrate Backplane's MCP hub to use it.

**Architecture:** This is a clean-room implementation, not a fork and not a vendored copy. The protocol app owns JSON-RPC framing, MCP message helpers, Streamable HTTP server transport, stdio/Streamable HTTP client transports, sessions, and client supervision. `apps/backplane_mcp` keeps Backplane-specific hub semantics: auth, scoped tool filtering, registry, managed tools, upstream lifecycle, audit, telemetry, and admin UI integration.

**Tech Stack:** Elixir 1.18 umbrella app, Plug, Req, Jason, ExUnit, current Backplane ETS/session patterns, official MCP specification, JSON-RPC 2.0 specification, and published API behavior references only.

---

## Clean-Room Rules

- Do not clone `zoedsoupe/anubis-mcp`.
- Do not copy or vendor Anubis source files.
- Do not add `{:anubis_mcp, ...}` to any `mix.exs`.
- Do not introduce `Anubis.*` modules, aliases, or package names.
- Do not paste code from Anubis docs or source. Public documentation may be used only to identify API behavior and naming ideas.
- Use official MCP and JSON-RPC specs as the implementation authority.
- Use Backplane's existing tests and mock servers as behavioral regression fixtures.
- Add checks that fail if `anubis_mcp` or `Anubis.` appears in source/deps.

Hex currently lists `anubis_mcp` as LGPL-3.0. This plan avoids that license boundary by implementing first-party code from protocol specs and Backplane behavior tests.

## Public API Target

Expose these first-party modules:

- `Backplane.McpProtocol` - version and helper entry point.
- `Backplane.McpProtocol.JsonRpc` - pure JSON-RPC request/response/error helpers.
- `Backplane.McpProtocol.Message` - MCP method names and common result builders.
- `Backplane.McpProtocol.Server` - behavior for server handlers.
- `Backplane.McpProtocol.Server.Frame` - request context struct.
- `Backplane.McpProtocol.Server.Transport.StreamableHttpPlug` - Plug for POST/GET/DELETE Streamable HTTP endpoint.
- `Backplane.McpProtocol.Client` - supervised MCP client API.
- `Backplane.McpProtocol.Client.Transport.Stdio` - stdio transport process.
- `Backplane.McpProtocol.Client.Transport.StreamableHttp` - Streamable HTTP transport process.
- `Backplane.McpProtocol.Sse` - pure SSE encode/decode helpers.
- `Backplane.McpProtocol.SessionStore` - ETS-backed session store for server/client session IDs.

Initial client API:

```elixir
Backplane.McpProtocol.Client.await_ready(client, opts \\ [])
Backplane.McpProtocol.Client.list_tools(client, opts \\ [])
Backplane.McpProtocol.Client.call_tool(client, name, arguments \\ %{}, opts \\ [])
Backplane.McpProtocol.Client.ping(client, opts \\ [])
Backplane.McpProtocol.Client.close(client)
```

Initial server behavior:

```elixir
@callback init(client_info :: map(), frame :: Backplane.McpProtocol.Server.Frame.t()) ::
            {:ok, Backplane.McpProtocol.Server.Frame.t()} | {:error, term()}

@callback handle_request(method :: String.t(), params :: map() | nil, frame :: Backplane.McpProtocol.Server.Frame.t()) ::
            {:reply, map(), Backplane.McpProtocol.Server.Frame.t()}
            | {:error, integer(), String.t(), Backplane.McpProtocol.Server.Frame.t()}
            | {:noreply, Backplane.McpProtocol.Server.Frame.t()}
```

## Refactor Boundary

`apps/backplane_mcp_protocol` owns protocol and transport:

- JSON-RPC 2.0 validation, request IDs, response maps, error maps, notifications, and batches if retained for compatibility.
- MCP initialize, ping, tools/list, tools/call message constructors and parsers.
- Streamable HTTP POST, GET SSE stream, and DELETE session handling.
- Client-side stdio and Streamable HTTP transports.
- Session ID storage and propagation.
- SSE event formatting/parsing.

`apps/backplane_mcp` keeps Backplane product behavior:

- `/api/mcp` route and middleware stack.
- Client bearer auth and tool scopes.
- `Backplane.Registry.ToolRegistry` and namespace normalization.
- Native/managed/upstream tool execution.
- Upstream supervision/status/reconnect/backoff.
- Audit, telemetry, caching, settings, credentials, and admin UI workflows.

## Files

Create:

- `apps/backplane_mcp_protocol/mix.exs`
- `apps/backplane_mcp_protocol/lib/backplane_mcp_protocol.ex`
- `apps/backplane_mcp_protocol/lib/backplane_mcp_protocol/application.ex`
- `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol.ex`
- `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/json_rpc.ex`
- `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/message.ex`
- `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/session_store.ex`
- `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/sse.ex`
- `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/server.ex`
- `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/server/frame.ex`
- `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/server/transport/streamable_http_plug.ex`
- `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/client.ex`
- `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/client/transport.ex`
- `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/client/transport/stdio.ex`
- `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/client/transport/streamable_http.ex`
- Tests under `apps/backplane_mcp_protocol/test/backplane/mcp_protocol/**`

Modify:

- `apps/backplane_mcp/mix.exs`
- `apps/backplane_mcp/lib/backplane/transport/mcp_plug.ex`
- `apps/backplane_mcp/lib/backplane/transport/mcp_handler.ex`
- `apps/backplane_mcp/lib/backplane/transport/task_manager.ex`
- `apps/backplane_mcp/lib/backplane/proxy/upstream.ex`
- `apps/backplane_mcp/lib/backplane/proxy/pool.ex` only if client supervision requires it.
- `apps/backplane_web/lib/backplane_web/live/mcp_inspector_live.ex`
- Existing transport/proxy tests under `apps/backplane_mcp/test/backplane/**`

Retire after migration:

- `apps/backplane_mcp/lib/backplane/proxy/sse_parser.ex`
- `apps/backplane_mcp/lib/backplane/proxy/sse_client.ex`
- `apps/backplane_mcp/lib/backplane/transport/sse.ex`
- JSON-RPC helper code inside `Backplane.Transport.McpHandler`
- stdio/HTTP protocol code inside `Backplane.Proxy.Upstream`

## Task 1: Create First-Party Protocol App

**Files:**
- Create: `apps/backplane_mcp_protocol/mix.exs`
- Create: `apps/backplane_mcp_protocol/lib/backplane_mcp_protocol.ex`
- Create: `apps/backplane_mcp_protocol/lib/backplane_mcp_protocol/application.ex`
- Create: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol.ex`
- Create: `apps/backplane_mcp_protocol/test/test_helper.exs`
- Create: `apps/backplane_mcp_protocol/test/backplane/mcp_protocol_test.exs`

- [ ] **Step 1: Create umbrella app skeleton**

Run:

```bash
mix new apps/backplane_mcp_protocol --sup
```

Expected: app skeleton exists under `apps/backplane_mcp_protocol`.

- [ ] **Step 2: Replace generated mix project with Backplane-style umbrella paths**

Set `apps/backplane_mcp_protocol/mix.exs` to:

```elixir
defmodule BackplaneMcpProtocol.MixProject do
  use Mix.Project

  def project do
    [
      app: :backplane_mcp_protocol,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {BackplaneMcpProtocol.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:plug, "~> 1.16"},
      {:req, "~> 0.5", override: true},
      {:jason, "~> 1.4"},
      {:bandit, "~> 1.5", only: :test},
      {:mox, "~> 1.1", only: :test}
    ]
  end
end
```

- [ ] **Step 3: Add root API module**

Create `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol.ex`:

```elixir
defmodule Backplane.McpProtocol do
  @moduledoc """
  First-party clean-room MCP protocol implementation for Backplane.
  """

  @latest_protocol_version "2025-11-25"
  @supported_protocol_versions ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

  @spec protocol_version() :: String.t()
  def protocol_version, do: @latest_protocol_version

  @spec supported_protocol_versions() :: [String.t()]
  def supported_protocol_versions, do: @supported_protocol_versions

  @spec negotiate_version(String.t() | nil) :: String.t()
  def negotiate_version(nil), do: @latest_protocol_version
  def negotiate_version(version) when version in @supported_protocol_versions, do: version
  def negotiate_version(_version), do: @latest_protocol_version
end
```

- [ ] **Step 4: Add generated app compatibility module**

Set `apps/backplane_mcp_protocol/lib/backplane_mcp_protocol.ex` to:

```elixir
defmodule BackplaneMcpProtocol do
  @moduledoc false

  defdelegate protocol_version(), to: Backplane.McpProtocol
  defdelegate supported_protocol_versions(), to: Backplane.McpProtocol
  defdelegate negotiate_version(version), to: Backplane.McpProtocol
end
```

- [ ] **Step 5: Add application supervisor**

Set `apps/backplane_mcp_protocol/lib/backplane_mcp_protocol/application.ex` to:

```elixir
defmodule BackplaneMcpProtocol.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = []

    Supervisor.start_link(children, strategy: :one_for_one, name: BackplaneMcpProtocol.Supervisor)
  end
end
```

- [ ] **Step 6: Add initial version test**

Create `apps/backplane_mcp_protocol/test/backplane/mcp_protocol_test.exs`:

```elixir
defmodule Backplane.McpProtocolTest do
  use ExUnit.Case, async: true

  test "reports supported protocol versions" do
    assert Backplane.McpProtocol.protocol_version() == "2025-11-25"
    assert "2025-11-25" in Backplane.McpProtocol.supported_protocol_versions()
    assert "2025-06-18" in Backplane.McpProtocol.supported_protocol_versions()
  end

  test "negotiates unknown versions to latest supported version" do
    assert Backplane.McpProtocol.negotiate_version("1999-01-01") == "2025-11-25"
  end
end
```

- [ ] **Step 7: Run test**

Run:

```bash
mix test apps/backplane_mcp_protocol/test/backplane/mcp_protocol_test.exs
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add apps/backplane_mcp_protocol
git commit -m "feat(mcp): add first-party protocol app"
```

## Task 2: Implement JSON-RPC Core

**Files:**
- Create: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/json_rpc.ex`
- Create: `apps/backplane_mcp_protocol/test/backplane/mcp_protocol/json_rpc_test.exs`

- [ ] **Step 1: Write JSON-RPC tests**

Create `apps/backplane_mcp_protocol/test/backplane/mcp_protocol/json_rpc_test.exs`:

```elixir
defmodule Backplane.McpProtocol.JsonRpcTest do
  use ExUnit.Case, async: true

  alias Backplane.McpProtocol.JsonRpc

  test "builds request objects" do
    assert %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping", "params" => %{}} =
             JsonRpc.request("ping", %{}, id: 1)
  end

  test "builds result responses" do
    assert %{"jsonrpc" => "2.0", "id" => "abc", "result" => %{}} =
             JsonRpc.result("abc", %{})
  end

  test "builds error responses" do
    assert %{
             "jsonrpc" => "2.0",
             "id" => nil,
             "error" => %{"code" => -32_600, "message" => "Invalid Request"}
           } = JsonRpc.error(nil, -32_600, "Invalid Request")
  end

  test "validates requests" do
    assert {:ok, %{"method" => "ping"}} = JsonRpc.validate_request(%{"jsonrpc" => "2.0", "method" => "ping"})
    assert {:error, -32_600, _message} = JsonRpc.validate_request(%{"method" => "ping"})
  end

  test "decodes batch request bodies" do
    body = Jason.encode!([JsonRpc.request("ping", %{}, id: 1), %{"jsonrpc" => "2.0", "method" => "notice"}])
    assert {:ok, [_first, _second]} = JsonRpc.decode_body(body)
  end
end
```

- [ ] **Step 2: Implement JSON-RPC pure helpers**

Create `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/json_rpc.ex`:

```elixir
defmodule Backplane.McpProtocol.JsonRpc do
  @moduledoc """
  JSON-RPC 2.0 helpers used by MCP transports.
  """

  @jsonrpc "2.0"

  @spec request(String.t(), map() | nil, keyword()) :: map()
  def request(method, params \\ nil, opts \\ []) when is_binary(method) do
    id = Keyword.get(opts, :id, System.unique_integer([:positive]))

    %{"jsonrpc" => @jsonrpc, "id" => id, "method" => method}
    |> maybe_put("params", params)
  end

  @spec notification(String.t(), map() | nil) :: map()
  def notification(method, params \\ nil) when is_binary(method) do
    %{"jsonrpc" => @jsonrpc, "method" => method}
    |> maybe_put("params", params)
  end

  @spec result(term(), term()) :: map()
  def result(id, result), do: %{"jsonrpc" => @jsonrpc, "id" => id, "result" => result}

  @spec error(term(), integer(), String.t(), term()) :: map()
  def error(id, code, message, data \\ nil) when is_integer(code) and is_binary(message) do
    error = %{"code" => code, "message" => message} |> maybe_put("data", data)
    %{"jsonrpc" => @jsonrpc, "id" => id, "error" => error}
  end

  @spec decode_body(binary()) :: {:ok, map() | [map()]} | {:error, map()}
  def decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) or is_list(decoded) ->
        {:ok, decoded}

      {:ok, _other} ->
        {:error, error(nil, -32_600, "Invalid Request")}

      {:error, _reason} ->
        {:error, error(nil, -32_700, "Parse error")}
    end
  end

  @spec validate_request(term()) :: {:ok, map()} | {:error, integer(), String.t()}
  def validate_request(%{"jsonrpc" => @jsonrpc, "method" => method} = request) when is_binary(method) do
    {:ok, request}
  end

  def validate_request(_request), do: {:error, -32_600, "Invalid Request"}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
```

- [ ] **Step 3: Run test**

Run:

```bash
mix test apps/backplane_mcp_protocol/test/backplane/mcp_protocol/json_rpc_test.exs
```

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/json_rpc.ex \
  apps/backplane_mcp_protocol/test/backplane/mcp_protocol/json_rpc_test.exs
git commit -m "feat(mcp): implement json-rpc helpers"
```

## Task 3: Implement Sessions and SSE Helpers

**Files:**
- Create: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/session_store.ex`
- Create: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/sse.ex`
- Modify: `apps/backplane_mcp_protocol/lib/backplane_mcp_protocol/application.ex`
- Create: `apps/backplane_mcp_protocol/test/backplane/mcp_protocol/session_store_test.exs`
- Create: `apps/backplane_mcp_protocol/test/backplane/mcp_protocol/sse_test.exs`

- [ ] **Step 1: Add session store tests**

Create `apps/backplane_mcp_protocol/test/backplane/mcp_protocol/session_store_test.exs`:

```elixir
defmodule Backplane.McpProtocol.SessionStoreTest do
  use ExUnit.Case, async: false

  alias Backplane.McpProtocol.SessionStore

  test "creates, fetches, touches, and deletes sessions" do
    assert {:ok, id} = SessionStore.create(%{protocol_version: "2025-06-18"})
    assert %{protocol_version: "2025-06-18"} = SessionStore.get(id)
    assert :ok = SessionStore.touch(id)
    assert :ok = SessionStore.delete(id)
    assert SessionStore.get(id) == nil
  end
end
```

- [ ] **Step 2: Implement ETS-backed session store**

Create `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/session_store.ex`:

```elixir
defmodule Backplane.McpProtocol.SessionStore do
  @moduledoc "ETS-backed MCP session store."

  use GenServer

  @table :backplane_mcp_protocol_sessions
  @cleanup_interval_ms 300_000
  @max_age_seconds 3600

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def create(attrs) when is_map(attrs) do
    id = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
    now = System.system_time(:second)
    :ets.insert(@table, {id, Map.merge(attrs, %{created_at: now, last_seen_at: now})})
    {:ok, id}
  end

  def get(id) when is_binary(id) do
    case :ets.lookup(@table, id) do
      [{^id, session}] -> session
      [] -> nil
    end
  end

  def touch(id) when is_binary(id) do
    case get(id) do
      nil -> :ok
      session -> :ets.insert(@table, {id, %{session | last_seen_at: System.system_time(:second)}})
    end

    :ok
  end

  def delete(id) when is_binary(id) do
    :ets.delete(@table, id)
    :ok
  end

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    schedule_cleanup()
    {:ok, %{table: table}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_stale(@max_age_seconds)
    schedule_cleanup()
    {:noreply, state}
  end

  def cleanup_stale(max_age_seconds \\ @max_age_seconds) do
    cutoff = System.system_time(:second) - max_age_seconds
    :ets.select_delete(@table, [{{:_, %{last_seen_at: :"$1"}}, [{:<, :"$1", cutoff}], [true]}])
  end

  defp schedule_cleanup, do: Process.send_after(self(), :cleanup, @cleanup_interval_ms)
end
```

Update `apps/backplane_mcp_protocol/lib/backplane_mcp_protocol/application.ex` so the session store is supervised:

```elixir
children = [
  Backplane.McpProtocol.SessionStore
]
```

- [ ] **Step 3: Add SSE tests**

Create `apps/backplane_mcp_protocol/test/backplane/mcp_protocol/sse_test.exs`:

```elixir
defmodule Backplane.McpProtocol.SseTest do
  use ExUnit.Case, async: true

  alias Backplane.McpProtocol.Sse

  test "encodes message events" do
    assert Sse.encode("message", %{"jsonrpc" => "2.0", "id" => 1, "result" => %{}}) =~ "event: message"
  end

  test "parses complete events" do
    chunk = "event: message\ndata: {\"ok\":true}\n\n"
    assert {[%{event: "message", data: "{\"ok\":true}"}], ""} = Sse.parse(chunk, "")
  end
end
```

- [ ] **Step 4: Implement SSE helpers**

Create `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/sse.ex`:

```elixir
defmodule Backplane.McpProtocol.Sse do
  @moduledoc "Small SSE encoder/parser for MCP Streamable HTTP."

  def encode(event, data) when is_binary(event) do
    encoded = if is_binary(data), do: data, else: Jason.encode!(data)
    "event: #{event}\ndata: #{encoded}\n\n"
  end

  def parse(chunk, buffer \\ "") when is_binary(chunk) and is_binary(buffer) do
    (buffer <> chunk)
    |> String.split("\n\n")
    |> split_events()
  end

  defp split_events(parts) do
    {complete, rest} =
      case parts do
        [] -> {[], ""}
        [_single] -> {[], List.first(parts)}
        parts -> {Enum.drop(parts, -1), List.last(parts)}
      end

    events =
      complete
      |> Enum.map(&parse_event/1)
      |> Enum.reject(&is_nil/1)

    {events, rest}
  end

  defp parse_event(raw) do
    lines = String.split(raw, "\n")
    event = Enum.find_value(lines, "message", &line_value(&1, "event:"))
    data = lines |> Enum.flat_map(&data_value/1) |> Enum.join("\n")
    if data == "", do: nil, else: %{event: event, data: data}
  end

  defp line_value(line, prefix) do
    if String.starts_with?(line, prefix), do: line |> String.replace_prefix(prefix, "") |> String.trim_leading()
  end

  defp data_value(line) do
    case line_value(line, "data:") do
      nil -> []
      value -> [value]
    end
  end
end
```

- [ ] **Step 5: Run tests**

Run:

```bash
mix test apps/backplane_mcp_protocol/test/backplane/mcp_protocol/session_store_test.exs
mix test apps/backplane_mcp_protocol/test/backplane/mcp_protocol/sse_test.exs
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add apps/backplane_mcp_protocol/lib/backplane_mcp_protocol/application.ex \
  apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/session_store.ex \
  apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/sse.ex \
  apps/backplane_mcp_protocol/test/backplane/mcp_protocol/session_store_test.exs \
  apps/backplane_mcp_protocol/test/backplane/mcp_protocol/sse_test.exs
git commit -m "feat(mcp): add sessions and sse helpers"
```

## Task 4: Implement Streamable HTTP Server Transport

**Files:**
- Create: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/server.ex`
- Create: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/server/frame.ex`
- Create: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/server/transport/streamable_http_plug.ex`
- Create: `apps/backplane_mcp_protocol/test/backplane/mcp_protocol/server/transport/streamable_http_plug_test.exs`

- [ ] **Step 1: Add server behavior and frame**

Create `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/server.ex`:

```elixir
defmodule Backplane.McpProtocol.Server do
  @moduledoc "Behavior for MCP server handlers."

  alias Backplane.McpProtocol.Server.Frame

  @callback init(map(), Frame.t()) :: {:ok, Frame.t()} | {:error, term()}
  @callback handle_request(String.t(), map() | nil, Frame.t()) ::
              {:reply, map(), Frame.t()}
              | {:error, integer(), String.t(), Frame.t()}
              | {:noreply, Frame.t()}
end
```

Create `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/server/frame.ex`:

```elixir
defmodule Backplane.McpProtocol.Server.Frame do
  @moduledoc "Request context passed through MCP server handlers."

  defstruct assigns: %{}, session_id: nil, protocol_version: nil, conn: nil

  @type t :: %__MODULE__{
          assigns: map(),
          session_id: String.t() | nil,
          protocol_version: String.t() | nil,
          conn: Plug.Conn.t() | nil
        }

  def assign(%__MODULE__{assigns: assigns} = frame, key, value) do
    %{frame | assigns: Map.put(assigns, key, value)}
  end
end
```

- [ ] **Step 2: Add Plug tests**

Create `apps/backplane_mcp_protocol/test/backplane/mcp_protocol/server/transport/streamable_http_plug_test.exs`:

```elixir
defmodule Backplane.McpProtocol.Server.Transport.StreamableHttpPlugTest do
  use ExUnit.Case, async: false
  use Plug.Test

  alias Backplane.McpProtocol.Server.Transport.StreamableHttpPlug

  defmodule Handler do
    @behaviour Backplane.McpProtocol.Server

    def init(_client_info, frame), do: {:ok, frame}

    def handle_request("initialize", params, frame) do
      result = %{
        "protocolVersion" => Backplane.McpProtocol.negotiate_version(params["protocolVersion"]),
        "serverInfo" => %{"name" => "test", "version" => "0.1.0"},
        "capabilities" => %{"tools" => %{}}
      }

      {:reply, result, frame}
    end

    def handle_request("ping", _params, frame), do: {:reply, %{}, frame}
    def handle_request(_method, _params, frame), do: {:error, -32_601, "Method not found", frame}
  end

  test "POST initialize returns JSON-RPC result and session header" do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{"protocolVersion" => "2025-06-18", "clientInfo" => %{}, "capabilities" => %{}}
      })

    conn =
      conn(:post, "/", body)
      |> put_req_header("content-type", "application/json")
      |> StreamableHttpPlug.call(StreamableHttpPlug.init(handler: Handler))

    assert conn.status == 200
    assert [session_id] = get_resp_header(conn, "mcp-session-id")
    assert String.length(session_id) > 10
    assert %{"result" => %{"serverInfo" => %{"name" => "test"}}} = Jason.decode!(conn.resp_body)
  end

  test "POST ping returns JSON-RPC result" do
    body = Jason.encode!(%{"jsonrpc" => "2.0", "id" => "p", "method" => "ping"})

    conn =
      conn(:post, "/", body)
      |> put_req_header("content-type", "application/json")
      |> StreamableHttpPlug.call(StreamableHttpPlug.init(handler: Handler))

    assert %{"id" => "p", "result" => %{}} = Jason.decode!(conn.resp_body)
  end

  test "DELETE removes session" do
    {:ok, session_id} = Backplane.McpProtocol.SessionStore.create(%{})

    conn =
      conn(:delete, "/")
      |> put_req_header("mcp-session-id", session_id)
      |> StreamableHttpPlug.call(StreamableHttpPlug.init(handler: Handler))

    assert conn.status == 200
    assert Backplane.McpProtocol.SessionStore.get(session_id) == nil
  end
end
```

- [ ] **Step 3: Implement Plug**

Create `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/server/transport/streamable_http_plug.ex` with these requirements:

- `POST /` reads raw body, decodes JSON-RPC, validates request, dispatches to handler, and returns JSON.
- `initialize` creates a session and returns `mcp-session-id`.
- Notifications return `202` with an empty body.
- `GET /` opens an SSE stream and sends keepalives; notification pubsub can be added later when Backplane wires it.
- `DELETE /` deletes `mcp-session-id` if present and returns `200`.
- Malformed JSON returns HTTP 400 with JSON-RPC parse error body.
- Oversized body returns HTTP 413 if `length` option is exceeded.

Use `Plug.Conn.read_body/2`, `Backplane.McpProtocol.JsonRpc`, and `Backplane.McpProtocol.SessionStore`.

- [ ] **Step 4: Run server transport tests**

Run:

```bash
mix test apps/backplane_mcp_protocol/test/backplane/mcp_protocol/server/transport/streamable_http_plug_test.exs
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/server.ex \
  apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/server/frame.ex \
  apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/server/transport/streamable_http_plug.ex \
  apps/backplane_mcp_protocol/test/backplane/mcp_protocol/server/transport/streamable_http_plug_test.exs
git commit -m "feat(mcp): implement streamable http server transport"
```

## Task 5: Implement Client API and Transports

**Files:**
- Create: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/client.ex`
- Create: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/client/transport.ex`
- Create: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/client/transport/stdio.ex`
- Create: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/client/transport/streamable_http.ex`
- Create: `apps/backplane_mcp_protocol/test/backplane/mcp_protocol/client_test.exs`

- [ ] **Step 1: Write client integration tests**

Create `apps/backplane_mcp_protocol/test/backplane/mcp_protocol/client_test.exs` with a local Plug handler and stdio fixture. Cover:

- `start_link/1` performs initialize handshake.
- `await_ready/2` returns `:ok` after handshake.
- `list_tools/2` returns tools from server.
- `call_tool/4` returns tool result.
- `ping/2` returns `:pong`.
- `close/1` terminates client and transport.

Use pattern matching assertions and keep tests scoped to public API.

- [ ] **Step 2: Implement `Backplane.McpProtocol.Client`**

Requirements:

- `use GenServer` is justified because the client owns mutable session state, request IDs, server info, capabilities, and a persistent transport.
- `start_link/1` accepts `:name`, `:transport`, `:client_info`, `:capabilities`, `:protocol_version`, and optional `:transport_name`.
- `init/1` starts/connects transport and sends `initialize` in `handle_continue/2`.
- `await_ready/2` waits until initialization is complete.
- Public calls delegate to JSON-RPC methods through the transport.
- Expected failures return `{:error, reason}`; unexpected process failures can crash and be supervised.

- [ ] **Step 3: Implement transport behavior**

Create a transport behavior with:

```elixir
@callback start_link(keyword()) :: GenServer.on_start()
@callback request(GenServer.server(), map(), timeout()) :: {:ok, map()} | {:error, term()}
@callback close(GenServer.server()) :: :ok
```

- [ ] **Step 4: Implement Streamable HTTP transport**

Requirements:

- Use `Req` for POST/DELETE.
- Send `accept: application/json, text/event-stream`.
- Store `mcp-session-id` from initialize response and include it on subsequent requests.
- Decode JSON response bodies.
- Decode `text/event-stream` response bodies via `Backplane.McpProtocol.Sse`.
- Return `{:ok, json_rpc_response_map}` or `{:error, reason}`.

- [ ] **Step 5: Implement stdio transport**

Requirements:

- Use `Port.open/2` with `:binary`, `:exit_status`, `:use_stdio`, args, and env.
- Maintain request ID to caller mapping.
- Buffer stdout by newline.
- Decode one JSON-RPC response per line.
- Reply to all pending callers if the port exits.
- Enforce max buffer size.

- [ ] **Step 6: Run client tests**

Run:

```bash
mix test apps/backplane_mcp_protocol/test/backplane/mcp_protocol/client_test.exs
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/client* \
  apps/backplane_mcp_protocol/test/backplane/mcp_protocol/client_test.exs
git commit -m "feat(mcp): implement supervised client transports"
```

## Task 6: Integrate Protocol App into Backplane MCP

**Files:**
- Modify: `apps/backplane_mcp/mix.exs`
- Create: `apps/backplane_mcp/lib/backplane/mcp/server_surface.ex`
- Create: `apps/backplane_mcp/lib/backplane/transport/backplane_mcp_server.ex`
- Modify: `apps/backplane_mcp/lib/backplane/transport/mcp_plug.ex`
- Modify: `apps/backplane_mcp/lib/backplane/transport/mcp_handler.ex`
- Modify: `apps/backplane_mcp/lib/backplane/transport/task_manager.ex`
- Modify: `apps/backplane_web/lib/backplane_web/live/mcp_inspector_live.ex`

- [ ] **Step 1: Run GitNexus impact before source edits**

Run `npx gitnexus analyze`, then run GitNexus impact for:

- `apps/backplane_mcp/lib/backplane/transport/mcp_plug.ex`
- `apps/backplane_mcp/lib/backplane/transport/mcp_handler.ex`
- `apps/backplane_mcp/lib/backplane/transport/task_manager.ex`
- `apps/backplane_web/lib/backplane_web/live/mcp_inspector_live.ex`

If risk is HIGH or CRITICAL, stop and report before editing.

- [ ] **Step 2: Add in-umbrella dependency**

In `apps/backplane_mcp/mix.exs`, add:

```elixir
{:backplane_mcp_protocol, in_umbrella: true},
```

Do not add `:anubis_mcp`.

- [ ] **Step 3: Extract Backplane server surface**

Create `Backplane.MCP.ServerSurface` in `apps/backplane_mcp/lib/backplane/mcp/server_surface.ex`. It should own:

- initialize result shape using existing `Backplane.MCP.Info`.
- scoped tools/list using `Backplane.Clients.filter_tools/2`.
- tools/call validation and execution.
- resources, prompts, completions, logging, elicitation, and tasks behavior currently in `McpHandler`.

Move behavior without changing response shapes.

- [ ] **Step 4: Add protocol server adapter**

Create `apps/backplane_mcp/lib/backplane/transport/backplane_mcp_server.ex`:

```elixir
defmodule Backplane.Transport.BackplaneMcpServer do
  @behaviour Backplane.McpProtocol.Server

  alias Backplane.Clients
  alias Backplane.MCP.ServerSurface
  alias Backplane.McpProtocol.Server.Frame

  @impl true
  def init(client_info, frame) do
    {:ok, Frame.assign(frame, :client_info, client_info || %{})}
  end

  @impl true
  def handle_request("initialize", params, frame) do
    {:reply, ServerSurface.initialize(params || %{}), frame}
  end

  def handle_request("tools/list", params, frame) do
    scopes = frame.assigns[:tool_scopes] || ["*"]
    {:reply, ServerSurface.list_tools(params || %{}, scopes), frame}
  end

  def handle_request("tools/call", %{"name" => name} = params, frame) do
    scopes = frame.assigns[:tool_scopes] || ["*"]

    if Clients.scope_matches?(scopes, name) do
      ServerSurface.call_tool(name, params["arguments"] || %{}, frame.assigns[:client], frame)
    else
      {:error, -32_001, "Tool '#{name}' is not in scope for this client", frame}
    end
  end

  def handle_request(method, params, frame) do
    ServerSurface.method_result(method, params || %{}, frame)
  end
end
```

Adjust exact return values to match the extracted `ServerSurface`.

- [ ] **Step 5: Replace `McpPlug` dispatch**

Keep Backplane middleware in `McpPlug`, then forward to:

```elixir
forward "/",
  to: Backplane.McpProtocol.Server.Transport.StreamableHttpPlug,
  init_opts: [handler: Backplane.Transport.BackplaneMcpServer]
```

Pass `conn.assigns[:client]` and `conn.assigns[:tool_scopes]` into `Frame.assigns` inside the protocol plug.

- [ ] **Step 6: Move non-transport callers**

Replace `Backplane.Transport.McpHandler.dispatch_tool_call/2` calls with:

```elixir
Backplane.MCP.ServerSurface.dispatch_tool_call(name, args)
```

Keep `McpHandler` as a temporary compatibility facade only if tests still reference it.

- [ ] **Step 7: Run server parity tests**

Run:

```bash
mix test apps/backplane_mcp/test/backplane/transport/mcp_handler_test.exs
mix test apps/backplane_mcp/test/backplane/transport/router_test.exs
mix test apps/backplane_mcp/test/backplane/transport/idempotency_test.exs
mix test apps/backplane_mcp/test/integration/math_evaluate_round_trip_test.exs
mix test apps/backplane_web/test/backplane_web/live/mcp_inspector_live_test.exs
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add apps/backplane_mcp/mix.exs \
  apps/backplane_mcp/lib/backplane/mcp/server_surface.ex \
  apps/backplane_mcp/lib/backplane/transport/backplane_mcp_server.ex \
  apps/backplane_mcp/lib/backplane/transport/mcp_plug.ex \
  apps/backplane_mcp/lib/backplane/transport/mcp_handler.ex \
  apps/backplane_mcp/lib/backplane/transport/task_manager.ex \
  apps/backplane_web/lib/backplane_web/live/mcp_inspector_live.ex
git commit -m "refactor(mcp): serve hub through first-party protocol"
```

## Task 7: Migrate Upstream Proxy Client

**Files:**
- Modify: `apps/backplane_mcp/lib/backplane/proxy/upstream.ex`
- Modify: `apps/backplane_mcp/test/backplane/proxy/upstream_test.exs`
- Modify: `apps/backplane_mcp/test/backplane/proxy/pool_test.exs`

- [ ] **Step 1: Run GitNexus impact**

Run GitNexus impact for `apps/backplane_mcp/lib/backplane/proxy/upstream.ex`.

- [ ] **Step 2: Replace hand-rolled client state**

In `Backplane.Proxy.Upstream`, keep lifecycle/status fields, but replace protocol fields with:

```elixir
client: nil,
client_name: nil,
transport_name: nil
```

Remove `port`, `buffer`, `pending_requests`, `next_id`, and `pending_ping_id` after tests pass.

- [ ] **Step 3: Connect using `Backplane.McpProtocol.Client`**

Use a local `Registry`/`DynamicSupervisor` or existing upstream process name to start clients:

```elixir
Backplane.McpProtocol.Client.start_link(
  name: client_name,
  transport: transport_config(state.config),
  client_info: %{"name" => "backplane", "version" => Backplane.MCP.Info.version()},
  capabilities: %{},
  protocol_version: Backplane.MCP.Info.protocol_version()
)
```

Use `handle_continue/2` for connection work and `await_ready/2` before discovery.

- [ ] **Step 4: Replace discovery and calls**

Use:

```elixir
Backplane.McpProtocol.Client.list_tools(client, timeout: state.tool_timeout)
Backplane.McpProtocol.Client.call_tool(client, tool_name, arguments, timeout: timeout)
Backplane.McpProtocol.Client.ping(client, timeout: state.tool_timeout)
```

Preserve registry mapping to `prefix::tool_name`, per-tool timeout, call failure tracking, reconnects, cache behavior, and PubSub broadcasts.

- [ ] **Step 5: Run upstream parity tests**

Run:

```bash
mix test apps/backplane_mcp/test/backplane/proxy/upstream_test.exs
mix test apps/backplane_mcp/test/backplane/proxy/pool_test.exs
mix test apps/backplane_mcp/test/backplane/transport/health_check_test.exs
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add apps/backplane_mcp/lib/backplane/proxy/upstream.ex \
  apps/backplane_mcp/test/backplane/proxy/upstream_test.exs \
  apps/backplane_mcp/test/backplane/proxy/pool_test.exs
git commit -m "refactor(mcp): use first-party protocol client"
```

## Task 8: Remove Old Protocol Plumbing and Add Clean-Room Checks

**Files:**
- Delete: `apps/backplane_mcp/lib/backplane/proxy/sse_parser.ex`
- Delete: `apps/backplane_mcp/lib/backplane/proxy/sse_client.ex`
- Delete: `apps/backplane_mcp/lib/backplane/transport/sse.ex`
- Delete or rewrite corresponding tests.
- Create: `apps/backplane_mcp_protocol/test/backplane/mcp_protocol/clean_room_test.exs`

- [ ] **Step 1: Verify no old protocol callers remain**

Run:

```bash
rg -n "Backplane\\.Proxy\\.SSEParser|Backplane\\.Proxy\\.SSEClient|Backplane\\.Transport\\.SSE|jsonrpc_request\\(|send_stdio\\(|parse_sse_response" apps/backplane_mcp apps/backplane_mcp_protocol
```

Expected: no production callers remain.

- [ ] **Step 2: Delete obsolete modules**

Delete old protocol modules and tests only after the `rg` check is clean.

- [ ] **Step 3: Add clean-room guard test**

Create `apps/backplane_mcp_protocol/test/backplane/mcp_protocol/clean_room_test.exs`:

```elixir
defmodule Backplane.McpProtocol.CleanRoomTest do
  use ExUnit.Case, async: true

  @root Path.expand("../../../../..", __DIR__)

  test "does not depend on or namespace upstream anubis code" do
    files =
      ["apps/backplane_mcp_protocol", "apps/backplane_mcp"]
      |> Enum.flat_map(fn path ->
        Path.wildcard(Path.join([@root, path, "**/*.{ex,exs}"]))
      end)

    contents = Enum.map_join(files, "\n", &File.read!/1)

    forbidden_module = "An" <> "ubis."
    forbidden_dep = "anubis" <> "_mcp"

    refute contents =~ forbidden_module
    refute contents =~ forbidden_dep
  end
end
```

- [ ] **Step 4: Run cleanup tests**

Run:

```bash
mix test apps/backplane_mcp_protocol/test
mix test apps/backplane_mcp/test/backplane/transport
mix test apps/backplane_mcp/test/backplane/proxy
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/backplane_mcp apps/backplane_mcp_protocol
git commit -m "refactor(mcp): remove legacy protocol plumbing"
```

## Task 9: Final Verification

**Files:**
- No expected source changes unless verification exposes scoped defects.

- [ ] **Step 1: Run dependency/source guardrails**

Run:

```bash
rg -n "anubis_mcp|Anubis\\." mix.exs mix.lock apps config docs/superpowers/plans/2026-06-15-backplane-mcp-protocol-clean-room.md
mix deps.tree | rg "anubis|Anubis" && exit 1 || true
```

Expected: no source/dependency references except this plan's explanatory clean-room guardrails.

- [ ] **Step 2: Run protocol and MCP suites**

Run:

```bash
mix test apps/backplane_mcp_protocol/test
mix test apps/backplane_mcp/test/backplane/transport
mix test apps/backplane_mcp/test/backplane/proxy
mix test apps/backplane_mcp/test/integration/math_evaluate_round_trip_test.exs
mix test apps/backplane_web/test/backplane_web/live/mcp_inspector_live_test.exs
```

Expected: PASS.

- [ ] **Step 3: Run format and static checks**

Run:

```bash
mix format --check-formatted
mix credo --strict apps/backplane_mcp_protocol apps/backplane_mcp apps/backplane_web
```

Expected: PASS.

- [ ] **Step 4: Run GitNexus detect changes before commit**

Run:

```bash
npx gitnexus analyze
```

Then run GitNexus `detect_changes(scope: "all", repo: "backplane")`.

Expected: affected scope is limited to first-party protocol app, MCP transport/proxy, and inspector test-call path.

## Acceptance Criteria

- `apps/backplane_mcp_protocol` exists as a first-party umbrella app.
- All public modules use `Backplane.McpProtocol.*`.
- No `anubis_mcp` dependency exists.
- No `Anubis.*` module references exist.
- `/api/mcp` still supports POST, GET, and DELETE.
- `initialize`, `ping`, `tools/list`, and `tools/call` preserve current Backplane behavior.
- Upstream HTTP and stdio MCP servers work through `Backplane.McpProtocol.Client`.
- Old hand-rolled protocol code in `apps/backplane_mcp` is removed or reduced to Backplane-specific adapter code.
- Scoped MCP, proxy, inspector, format, and clean-room guard tests pass.

## References

- MCP specification 2025-06-18: https://modelcontextprotocol.io/specification/2025-06-18
- MCP tools specification: https://modelcontextprotocol.io/specification/2025-06-18/server/tools
- MCP Streamable HTTP transport notes: https://modelcontextprotocol.io/specification/2025-03-26/basic/transports
- JSON-RPC 2.0 specification: https://www.jsonrpc.org/specification
- Anubis Hex package metadata used only to confirm license boundary: https://hex.pm/packages/anubis_mcp
- Anubis public client docs used only as API behavior reference: https://anubis-mcp.hexdocs.pm/Anubis.Client.html
