defmodule Backplane.HostAgent.MemoryRouterTest do
  use ExUnit.Case, async: false

  alias Backplane.HostAgent.Memory.Spool.Turso, as: Spool
  alias Backplane.HostAgent.MemoryProxy
  alias Backplane.HostAgent.MemoryRouter
  alias Backplane.HostAgent.Trace
  alias Backplane.MemoryToolContract

  import Plug.Conn
  import Plug.Test

  @moduletag :tmp_dir

  defmodule StubHubProxy do
    def list_tools do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, :list_tools)

      {:ok,
       [
         %{
           "name" => "memory::search",
           "description" => "hub search",
           "inputSchema" => %{"type" => "object", "x-hub" => true}
         },
         %{"name" => "memory::recall", "description" => "retired legacy tool"},
         %{"name" => "memory::slot_write", "description" => "retired device-local tool"},
         %{"name" => "hub::remote", "description" => "remote hub tool"},
         %{"description" => "missing name"},
         %{"name" => "", "description" => "empty name"},
         "not a tool descriptor"
       ]}
    end

    def call_tool(name, args) do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:call_tool, name, args})

      {:ok, %{"echo" => name, "arguments" => args}}
    end
  end

  defmodule ErrorHubProxy do
    def list_tools, do: {:error, :not_connected}
    def call_tool(_name, _args), do: {:error, :not_connected}
  end

  defmodule RejectingHubProxy do
    def list_tools, do: {:ok, []}
    def call_tool(_name, _args), do: {:error, "not_found"}
  end

  defmodule FakeHubChannel do
    def push(channel, event, payload, _timeout \\ 5_000) do
      send(channel, {:hub_push, event, payload})
      {:ok, %{"ok" => true, "result" => %{"echo" => payload["name"]}}}
    end
  end

  defmodule LifecycleProxy do
    def call(method, args, opts) do
      send(
        :persistent_term.get({Backplane.HostAgent.MemoryRouterTest.StubHubProxy, :owner}),
        {:lifecycle_context, method, args, opts}
      )

      now = DateTime.utc_now()

      {:ok,
       %{
         "kind" => "session_start",
         "context" => "injected",
         "source_revision" => "sha256:live",
         "generated_at" => DateTime.to_iso8601(now),
         "expires_at" => now |> DateTime.add(900, :second) |> DateTime.to_iso8601()
       }}
    end
  end

  defmodule ContextProbeService do
    @behaviour Backplane.HostAgent.LocalService

    @impl true
    def prefix, do: "probe"

    @impl true
    def tools, do: [%{"name" => "probe::context", "description" => "reports call context"}]

    @impl true
    def call("context", _args, ctx) do
      send(self(), {:probe_context, ctx})
      {:ok, %{"ok" => true}}
    end

    def call(method, _args, _ctx), do: {:error, {:unknown_method, method}}
  end

  setup do
    MemoryProxy.set_channel(nil)
    :persistent_term.put({StubHubProxy, :owner}, self())

    on_exit(fn ->
      Application.delete_env(:backplane_host_agent, :local_services)
      Application.delete_env(:backplane_host_agent, :hub_proxy_module)
      Application.delete_env(:backplane_host_agent, :channel_module)
      Application.delete_env(:backplane_host_agent, :capture_runtime)
      MemoryProxy.set_channel(nil)
      _ = :persistent_term.erase({StubHubProxy, :owner})
    end)

    :ok
  end

  describe "POST /memory/:agent_id/mcp tools/list" do
    test "tools/list returns exactly the five memory tools" do
      for proxy <- [StubHubProxy, ErrorHubProxy] do
        Application.put_env(:backplane_host_agent, :hub_proxy_module, proxy)

        tools = mcp_tools("/memory/a1/mcp")

        memory_names =
          tools |> Map.keys() |> Enum.filter(&String.starts_with?(&1, "memory::")) |> Enum.sort()

        assert memory_names == Enum.sort(MemoryToolContract.tools())

        for name <- MemoryToolContract.tools() do
          assert %{"name" => ^name, "description" => description, "inputSchema" => schema} =
                   Map.fetch!(tools, name)

          assert is_binary(description) and description != ""
          assert is_map(schema)
        end
      end
    end

    test "uses hub schemas while connected and contract schemas while disconnected" do
      Application.put_env(:backplane_host_agent, :hub_proxy_module, StubHubProxy)
      connected = mcp_tools("/memory/a1/mcp")
      assert_received :list_tools

      assert connected["memory::search"]["inputSchema"] == %{"type" => "object", "x-hub" => true}

      assert connected["memory::remember"]["inputSchema"] ==
               Map.fetch!(MemoryToolContract.schemas(), "memory::remember")

      Application.put_env(:backplane_host_agent, :hub_proxy_module, ErrorHubProxy)
      disconnected = mcp_tools("/memory/a1/mcp")

      for name <- MemoryToolContract.tools() do
        assert disconnected[name]["inputSchema"] == Map.fetch!(MemoryToolContract.schemas(), name)
      end
    end

    test "keeps non-memory local and hub tools" do
      Application.put_env(:backplane_host_agent, :hub_proxy_module, StubHubProxy)
      tools = mcp_tools("/memory/a1/mcp")

      assert Map.has_key?(tools, "host_agent::install_plugin")
      assert Map.has_key?(tools, "hub::remote")
    end
  end

  describe "POST /memory/:agent_id/mcp tools/call" do
    test "tools/call memory::remember forwards to hub with agent injected" do
      Application.put_env(:backplane_host_agent, :hub_proxy_module, StubHubProxy)

      decoded = tools_call("/memory/a1/mcp", "memory::remember", %{"content" => "note"})

      assert decoded["result"]["isError"] == false
      assert_received {:call_tool, "memory::remember", %{"content" => "note", "agent" => "a1"}}
    end

    test "tools/call keeps a caller-supplied agent" do
      Application.put_env(:backplane_host_agent, :hub_proxy_module, StubHubProxy)

      tools_call("/memory/a1/mcp", "memory::remember", %{"content" => "n", "agent" => "other"})

      assert_received {:call_tool, "memory::remember", %{"content" => "n", "agent" => "other"}}
    end

    test "tools/call does not add an implicit agent filter to reads" do
      Application.put_env(:backplane_host_agent, :hub_proxy_module, StubHubProxy)

      tools_call("/memory/a1/mcp", "memory::search", %{"query" => "q"})
      tools_call("/memory/a1/mcp", "memory::recent", %{})

      assert_received {:call_tool, "memory::search", %{"query" => "q"} = search_args}
      refute Map.has_key?(search_args, "agent")
      assert_received {:call_tool, "memory::recent", recent_args}
      assert recent_args == %{}
    end

    test "when channel is down, tools/call returns gateway_unavailable" do
      Application.put_env(:backplane_host_agent, :hub_proxy_module, ErrorHubProxy)

      for name <- MemoryToolContract.tools() do
        assert %{
                 "result" => %{
                   "isError" => true,
                   "content" => [%{"type" => "text", "text" => "gateway_unavailable"}]
                 }
               } = tools_call("/memory/a1/mcp", name, %{})
      end
    end

    test "gateway tool errors are returned as reason strings" do
      Application.put_env(:backplane_host_agent, :hub_proxy_module, RejectingHubProxy)

      assert %{"result" => %{"isError" => true, "content" => [%{"text" => "not_found"}]}} =
               tools_call("/memory/a1/mcp", "memory::get", %{"id" => "x"})
    end

    test "retired and unknown memory tools are rejected without a hub call" do
      Application.put_env(:backplane_host_agent, :hub_proxy_module, StubHubProxy)

      for name <- ~w(memory::recall memory::slot_write memory::bogus) do
        assert %{"result" => %{"isError" => true, "content" => [%{"text" => text}]}} =
                 tools_call("/memory/a1/mcp", name, %{})

        assert text == "unknown tool: #{name}"
      end

      refute_received {:call_tool, _, _}
    end

    test "routes non-memory local service tools locally" do
      Application.put_env(:backplane_host_agent, :local_services, [ContextProbeService])

      assert %{"result" => %{"isError" => false}} =
               tools_call("/memory/agt_42/mcp", "probe::context", %{})

      assert_received {:probe_context, %{agent_id: "agt_42"}}
    end

    test "proxies unknown service tools through the hub" do
      Application.put_env(:backplane_host_agent, :hub_proxy_module, StubHubProxy)

      decoded = tools_call("/memory/agt_42/mcp", "unknown::tool", %{"x" => 1})

      assert decoded["result"]["isError"] == false
      assert_received {:call_tool, "unknown::tool", %{"x" => 1}}
    end

    test "returns a tool error result when the hub proxy is disconnected" do
      Application.put_env(:backplane_host_agent, :hub_proxy_module, ErrorHubProxy)

      assert %{"result" => %{"isError" => true, "content" => [%{"text" => message}]}} =
               tools_call("/memory/agt_42/mcp", "unknown::tool", %{})

      assert message == "hub unreachable: not_connected"
    end

    test "sets context from incoming traceparent and propagates it to hub calls" do
      incoming = Trace.to_traceparent(Trace.new_ctx())
      "00-" <> trace_id_and_rest = incoming
      <<trace_id::binary-size(32), _rest::binary>> = trace_id_and_rest

      MemoryProxy.set_channel(self())
      Application.put_env(:backplane_host_agent, :channel_module, FakeHubChannel)

      body =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 9,
          "method" => "tools/call",
          "params" => %{"name" => "memory::search", "arguments" => %{"query" => "q"}}
        })

      conn =
        :post
        |> conn("/memory/agt_42/mcp", body)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("traceparent", incoming)
        |> call_router()

      assert conn.status == 200

      assert_receive {:hub_push, "mcp_tool_call",
                      %{"name" => "memory::search", "traceparent" => outgoing}}

      assert outgoing =~ "00-#{trace_id}-"
      assert outgoing != incoming
    end
  end

  describe "POST /memory/:agent_id/mcp protocol" do
    test "initialize reports the running host-agent application version" do
      decoded = jsonrpc("/memory/agt_42/mcp", %{"id" => 1, "method" => "initialize"})

      assert decoded["result"]["serverInfo"] == %{
               "name" => "backplane-host-agent-memory",
               "version" => Application.spec(:backplane_host_agent, :vsn) |> to_string()
             }
    end

    test "returns JSON-RPC error for unknown JSON-RPC method" do
      decoded = jsonrpc("/memory/agt_42/mcp", %{"id" => 7, "method" => "unsupported"})
      assert decoded["error"]["code"] == -32_601
    end
  end

  describe "POST /memory/:agent_id/call/:method" do
    test "call/search maps to memory::search" do
      Application.put_env(:backplane_host_agent, :hub_proxy_module, StubHubProxy)

      conn = post_json("/memory/a1/call/search", %{"query" => "deploy"})

      assert conn.status == 200

      assert %{"ok" => true, "result" => %{"echo" => "memory::search"}} =
               Jason.decode!(conn.resp_body)

      assert_received {:call_tool, "memory::search", %{"query" => "deploy"}}
    end

    test "call/remember injects the route agent" do
      Application.put_env(:backplane_host_agent, :hub_proxy_module, StubHubProxy)

      assert %{status: 200} = post_json("/memory/a1/call/remember", %{"content" => "c"})
      assert_received {:call_tool, "memory::remember", %{"content" => "c", "agent" => "a1"}}
    end

    test "unwraps JSON-RPC params posted to the direct call endpoint" do
      Application.put_env(:backplane_host_agent, :hub_proxy_module, StubHubProxy)

      body = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "memory::forget",
        "params" => %{"id" => "r1", "reason" => "stale"}
      }

      assert %{status: 200} = post_json("/memory/a1/call/forget", body)
      assert_received {:call_tool, "memory::forget", %{"id" => "r1", "reason" => "stale"}}
    end

    test "returns 404 for unknown and retired methods" do
      Application.put_env(:backplane_host_agent, :hub_proxy_module, StubHubProxy)

      for method <- ~w(recall slot_write not-a-method) do
        conn = post_json("/memory/a1/call/#{method}", %{})
        assert conn.status == 404
        assert %{"error" => "unknown method: " <> ^method} = Jason.decode!(conn.resp_body)
      end

      refute_received {:call_tool, _, _}
    end

    test "returns 503 gateway_unavailable when the channel is down" do
      Application.put_env(:backplane_host_agent, :hub_proxy_module, ErrorHubProxy)

      conn = post_json("/memory/a1/call/recent", %{})

      assert conn.status == 503
      assert %{"ok" => false, "error" => "gateway_unavailable"} = Jason.decode!(conn.resp_body)
    end

    test "maps gateway not_found to 404" do
      Application.put_env(:backplane_host_agent, :hub_proxy_module, RejectingHubProxy)

      conn = post_json("/memory/a1/call/get", %{"id" => "missing"})

      assert conn.status == 404
      assert %{"ok" => false, "error" => "not_found"} = Jason.decode!(conn.resp_body)
    end

    test "accepts requests with no JSON body" do
      Application.put_env(:backplane_host_agent, :hub_proxy_module, StubHubProxy)

      conn =
        :post
        |> conn("/memory/a1/call/recent")
        |> call_router()

      assert conn.status == 200
      assert_received {:call_tool, "memory::recent", %{}}
    end
  end

  describe "POST /capture/v1/hooks" do
    test "capture hook returns 202 without context injection", %{tmp_dir: tmp_dir} do
      spool =
        start_supervised!(
          {Spool,
           database: Path.join(tmp_dir, "capture.db"),
           name: nil,
           id: {:memory_router_spool, System.unique_integer([:positive])}}
        )

      Application.put_env(:backplane_host_agent, :capture_runtime, %{
        host_id: "trusted-host",
        spool: spool,
        spool_module: Spool,
        memory_proxy_module: LifecycleProxy,
        config: %{inject_context: true, context_timeout_ms: 1_000}
      })

      Application.put_env(:backplane_host_agent, :hub_proxy_module, StubHubProxy)

      conn =
        post_json("/capture/v1/hooks/claude_code/session-start", %{
          "hook" => "session-start",
          "session_id" => "session-1",
          "agent_id" => "claude-main",
          "source_event_id" => "source-session-start",
          "occurred_at" => "2026-08-04T01:00:00Z",
          "cwd" => "/workspace/backplane"
        })

      assert conn.status == 202
      body = Jason.decode!(conn.resp_body)
      assert %{"ok" => true, "status" => "accepted"} = body
      refute Map.has_key?(body, "lifecycle_context")
      refute_received {:call_tool, _, _}
      refute_received {:lifecycle_context, _, _, _}
      assert %{pending_depth: 1} = Spool.stats(spool)
    end
  end

  defp mcp_tools(path) do
    path
    |> jsonrpc(%{"id" => "list", "method" => "tools/list"})
    |> get_in(["result", "tools"])
    |> Map.new(&{&1["name"], &1})
  end

  defp tools_call(path, name, args) do
    jsonrpc(path, %{
      "id" => "call",
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => args}
    })
  end

  defp jsonrpc(path, body) do
    conn = post_json(path, Map.put(body, "jsonrpc", "2.0"))
    assert conn.status == 200
    Jason.decode!(conn.resp_body)
  end

  defp post_json(path, body) do
    :post
    |> conn(path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> call_router()
  end

  defp call_router(conn), do: MemoryRouter.call(conn, MemoryRouter.init([]))
end
