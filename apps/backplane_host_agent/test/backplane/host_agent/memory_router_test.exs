defmodule Backplane.HostAgent.MemoryRouterTest do
  use ExUnit.Case, async: false

  alias Backplane.HostAgent.Memory.{Local, Migrator, Store}
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

  defmodule OnlineProxy do
    def list_tools, do: {:ok, []}

    def call_tool(_name, args) do
      send(
        :persistent_term.get({Backplane.HostAgent.MemoryRouterTest.StubHubProxy, :owner}),
        {:args, args}
      )

      {:ok, :persistent_term.get({__MODULE__, :record})}
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

  defmodule ScriptedHubProxy do
    def list_tools, do: {:ok, []}

    def call_tool(_name, args) do
      owner = :persistent_term.get({Backplane.HostAgent.MemoryRouterTest.StubHubProxy, :owner})
      send(owner, {:scripted_args, args})
      Process.get(:scripted_hub_reply)
    end
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
      Application.delete_env(:backplane_host_agent, :memory_store)
      Application.delete_env(:backplane_host_agent, :memory_config)
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

    test "transport and coded gateway errors map to stable reason strings" do
      Application.put_env(:backplane_host_agent, :hub_proxy_module, ScriptedHubProxy)

      for {reply, text} <- [
            {{:error, :timeout}, "gateway_timeout"},
            {{:error, :noproc}, "gateway_unavailable"},
            {{:error, %{"code" => "unauthorized"}}, "unauthorized"}
          ] do
        Process.put(:scripted_hub_reply, reply)

        assert %{"result" => %{"isError" => true, "content" => [%{"text" => ^text}]}} =
                 tools_call("/memory/a1/mcp", "memory::remember", %{"content" => "c"})
      end
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

    test "initialize serves the canonical resident instructions" do
      decoded = jsonrpc("/memory/agt_42/mcp", %{"id" => 1, "method" => "initialize"})

      assert decoded["result"]["instructions"] ==
               Backplane.MemoryToolContract.instructions()
    end

    test "returns JSON-RPC error for unknown JSON-RPC method" do
      decoded = jsonrpc("/memory/agt_42/mcp", %{"id" => 7, "method" => "unsupported"})
      assert decoded["error"]["code"] == -32_601
    end

    for path <- ["/memory/agt_42/mcp", "/agt_42/mcp", "/mcp"] do
      test "#{path} accepts a JSON-RPC notification with 202 and an empty body" do
        conn =
          post_json(unquote(path), %{
            "jsonrpc" => "2.0",
            "method" => "notifications/initialized"
          })

        assert conn.status == 202
        assert conn.resp_body == ""
      end

      test "#{path} accepts a client JSON-RPC response with 202 and an empty body" do
        conn = post_json(unquote(path), %{"jsonrpc" => "2.0", "id" => 3, "result" => %{}})

        assert conn.status == 202
        assert conn.resp_body == ""
      end

      test "#{path} answers GET with 405 and allow: POST" do
        conn = :get |> conn(unquote(path)) |> call_router()

        assert conn.status == 405
        assert get_resp_header(conn, "allow") == ["POST"]
      end
    end

    test "still rejects a body that is not JSON-RPC with 400" do
      conn = post_json("/memory/agt_42/mcp", %{"method" => "initialize", "id" => 1})
      assert conn.status == 400
      assert Jason.decode!(conn.resp_body)["error"] == "invalid JSON-RPC request"

      conn = post_json("/memory/agt_42/mcp", %{"jsonrpc" => "2.0"})
      assert conn.status == 400
    end

    test "GET on unrelated paths stays 404" do
      conn = :get |> conn("/memory/agt_42/other") |> call_router()
      assert conn.status == 404
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

    test "maps coded and timeout gateway errors to HTTP statuses" do
      Application.put_env(:backplane_host_agent, :hub_proxy_module, ScriptedHubProxy)

      for {reply, status, error} <- [
            {{:error, %{"code" => "unauthorized"}}, 403, "unauthorized"},
            {{:error, :timeout}, 504, "gateway_timeout"},
            {{:error, :noproc}, 503, "gateway_unavailable"}
          ] do
        Process.put(:scripted_hub_reply, reply)
        conn = post_json("/memory/a1/call/remember", %{"content" => "c"})

        assert conn.status == status
        assert %{"ok" => false, "error" => ^error} = Jason.decode!(conn.resp_body)
      end
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

  describe "offline memory" do
    setup %{tmp_dir: dir} do
      name = :"router_local_store_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Store,
         database: Path.join(dir, "local.db"), name: name, pool_size: 1, busy_timeout_ms: 5_000},
        id: name
      )

      :ok = Migrator.migrate(name)
      Application.put_env(:backplane_host_agent, :memory_store, name)
      Application.put_env(:backplane_host_agent, :hub_proxy_module, ScriptedHubProxy)
      {:ok, store: name}
    end

    test "offline remember returns pending 200 and queues an outbox row", %{store: store} do
      Process.put(:scripted_hub_reply, {:error, :noproc})

      conn =
        post_json("/memory/a1/call/remember", %{"content" => "saved offline", "kind" => "fact"})

      assert conn.status == 200

      assert %{"ok" => true, "result" => %{"sync" => "pending", "content" => "saved offline"}} =
               Jason.decode!(conn.resp_body)

      assert length(Local.pending_outbox(store, 10)) == 1
    end

    test "timeout remember queues too", %{store: store} do
      Process.put(:scripted_hub_reply, {:error, :timeout})
      conn = post_json("/memory/a1/call/remember", %{"content" => "maybe written"})

      assert conn.status == 200
      assert length(Local.pending_outbox(store, 10)) == 1
    end

    test "online remember sends a request_key and caches the record", %{store: store} do
      remote = %{
        "id" => "remote-1",
        "kind" => "fact",
        "content" => "online",
        "status" => "active",
        "subjects" => [],
        "tags" => []
      }

      :persistent_term.put({OnlineProxy, :record}, remote)
      on_exit(fn -> :persistent_term.erase({OnlineProxy, :record}) end)
      Application.put_env(:backplane_host_agent, :hub_proxy_module, OnlineProxy)

      conn = post_json("/memory/a1/call/remember", %{"content" => "online"})
      assert conn.status == 200
      assert_received {:args, %{"request_key" => "host-agent:" <> _}}
      assert {:ok, %{"content" => "online"}} = Local.get(store, "remote-1")
      assert Local.pending_outbox(store, 10) == []
    end

    test "validation errors are returned and nothing is queued", %{store: store} do
      Process.put(:scripted_hub_reply, {:error, %{"code" => "invalid"}})
      conn = post_json("/memory/a1/call/remember", %{"content" => "c"})

      assert conn.status == 400
      assert %{"error" => "invalid"} = Jason.decode!(conn.resp_body)
      assert Local.pending_outbox(store, 10) == []
    end

    test "offline search answers from local active records", %{store: store} do
      {:ok, _} =
        Local.queue_remember(
          store,
          %{"content" => "alpha banana", "kind" => "fact"},
          "host-agent:k"
        )

      Process.put(:scripted_hub_reply, {:error, :noproc})

      conn = post_json("/memory/a1/call/search", %{"query" => "banana"})
      assert conn.status == 200

      assert %{
               "result" => %{
                 "offline" => true,
                 "source" => "local",
                 "results" => [%{"content" => "alpha banana"}]
               }
             } =
               Jason.decode!(conn.resp_body)
    end

    test "offline get and recent answer locally", %{store: store} do
      {:ok, rec} =
        Local.queue_remember(store, %{"content" => "w", "kind" => "worklog"}, "host-agent:k")

      Process.put(:scripted_hub_reply, {:error, :noproc})

      conn = post_json("/memory/a1/call/get", %{"id" => rec["id"]})

      assert %{"result" => %{"record" => %{"content" => "w"}, "history" => [], "offline" => true}} =
               Jason.decode!(conn.resp_body)

      conn = post_json("/memory/a1/call/get", %{"id" => "nope"})
      assert conn.status == 404

      conn = post_json("/memory/a1/call/recent", %{})
      assert %{"result" => %{"offline" => true, "results" => [_]}} = Jason.decode!(conn.resp_body)
    end

    test "offline forget queues known records and rejects unknown ones", %{store: store} do
      {:ok, rec} =
        Local.queue_remember(store, %{"content" => "x", "kind" => "fact"}, "host-agent:k")

      Process.put(:scripted_hub_reply, {:error, :noproc})

      conn = post_json("/memory/a1/call/forget", %{"id" => rec["id"], "reason" => "stale"})
      assert conn.status == 200

      assert %{"result" => %{"status" => "forgotten", "sync" => "pending"}} =
               Jason.decode!(conn.resp_body)

      conn = post_json("/memory/a1/call/forget", %{"id" => "unknown", "reason" => "r"})
      assert conn.status == 503
      assert %{"error" => "gateway_unavailable"} = Jason.decode!(conn.resp_body)
    end

    test "timeout remember keeps the sent request_key and agent stamp in the queued payload", %{
      store: store
    } do
      Process.put(:scripted_hub_reply, {:error, :timeout})
      conn = post_json("/memory/a1/call/remember", %{"content" => "maybe written"})

      assert conn.status == 200
      assert_received {:scripted_args, %{"request_key" => "host-agent:" <> _ = key}}

      assert [%{"payload" => %{"request_key" => ^key, "agent" => "a1"}}] =
               Local.pending_outbox(store, 10)
    end

    test "non-binary caller request_key is replaced" do
      Process.put(:scripted_hub_reply, {:error, :noproc})
      post_json("/memory/a1/call/remember", %{"content" => "c", "request_key" => 5})
      assert_received {:scripted_args, %{"request_key" => "host-agent:" <> _}}
    end

    test "offline remember with invalid subjects is rejected and not queued", %{store: store} do
      Process.put(:scripted_hub_reply, {:error, :noproc})
      conn = post_json("/memory/a1/call/remember", %{"content" => "c", "subjects" => "bad"})

      assert conn.status == 400
      assert %{"error" => "invalid_subjects"} = Jason.decode!(conn.resp_body)
      assert Local.pending_outbox(store, 10) == []
    end

    test "offline mcp tools/call remember returns a pending result", %{store: store} do
      Process.put(:scripted_hub_reply, {:error, :noproc})
      resp = tools_call("/memory/a1/mcp", "memory::remember", %{"content" => "via mcp"})

      assert %{"result" => %{"isError" => false}} = resp
      assert Jason.encode!(resp) =~ "pending"
      assert length(Local.pending_outbox(store, 10)) == 1
    end

    test "local store failure after a gateway write still succeeds" do
      :persistent_term.put({OnlineProxy, :record}, %{
        "id" => "r2",
        "content" => "x",
        "subjects" => []
      })

      on_exit(fn -> :persistent_term.erase({OnlineProxy, :record}) end)
      Application.put_env(:backplane_host_agent, :hub_proxy_module, OnlineProxy)

      bogus = :"bogus_store_#{System.unique_integer([:positive])}"
      register_crashing_store(bogus)
      Application.put_env(:backplane_host_agent, :memory_store, bogus)

      conn = post_json("/memory/a1/call/remember", %{"content" => "x"})
      assert conn.status == 200
      assert %{"ok" => true, "result" => %{"id" => "r2"}} = Jason.decode!(conn.resp_body)
    end

    test "local store failure while offline reports local_store_error" do
      bogus = :"bogus_store_#{System.unique_integer([:positive])}"
      register_crashing_store(bogus)
      Application.put_env(:backplane_host_agent, :memory_store, bogus)
      Process.put(:scripted_hub_reply, {:error, :noproc})

      conn = post_json("/memory/a1/call/remember", %{"content" => "x"})
      assert conn.status == 500
      assert %{"error" => "local_store_error"} = Jason.decode!(conn.resp_body)
    end

    test "offline remember stamps the configured host id and keeps observed_at", %{store: store} do
      Application.put_env(:backplane_host_agent, :memory_config, %{host_id: "host-cfg-1"})
      Process.put(:scripted_hub_reply, {:error, :noproc})

      conn =
        post_json("/memory/a1/call/remember", %{
          "content" => "with provenance",
          "observed_at" => "2026-01-02T03:04:05Z"
        })

      assert conn.status == 200

      assert %{"result" => %{"provenance" => %{"host" => "host-cfg-1", "agent" => "a1"}} = rec} =
               Jason.decode!(conn.resp_body)

      assert rec["observed_at"] == "2026-01-02T03:04:05Z"

      assert [%{"payload" => %{"observed_at" => "2026-01-02T03:04:05Z"}}] =
               Local.pending_outbox(store, 10)
    end

    test "while the outbox has pending writes, online writes queue behind them and kick a sync",
         %{store: store} do
      sync_name = :"router_sync_#{System.unique_integer([:positive])}"
      Process.register(self(), sync_name)
      Application.put_env(:backplane_host_agent, :memory_config, %{sync_name: sync_name})

      {:ok, first} = Local.queue_remember(store, %{"content" => "first"}, "host-agent:first")

      :persistent_term.put({OnlineProxy, :record}, %{"id" => "never", "content" => "x"})
      on_exit(fn -> :persistent_term.erase({OnlineProxy, :record}) end)
      Application.put_env(:backplane_host_agent, :hub_proxy_module, OnlineProxy)

      conn = post_json("/memory/a1/call/remember", %{"content" => "second"})
      assert conn.status == 200
      assert %{"result" => %{"sync" => "pending"}} = Jason.decode!(conn.resp_body)
      assert_receive {:"$gen_cast", :sync_now}

      conn = post_json("/memory/a1/call/forget", %{"id" => first["id"], "reason" => "stale"})
      assert conn.status == 200
      assert_receive {:"$gen_cast", :sync_now}

      refute_received {:args, _}

      assert [
               %{"op" => "remember", "payload" => %{"content" => "first"}},
               %{"op" => "remember", "payload" => %{"content" => "second"}},
               %{"op" => "forget", "local_id" => forgotten}
             ] = Local.pending_outbox(store, 10)

      assert forgotten == first["local_id"]

      # Reads still go to the gateway while online.
      post_json("/memory/a1/call/search", %{"query" => "first"})
      assert_received {:args, %{"query" => "first"}}

      # A forget for a record not cached locally cannot be ordered, so it goes direct.
      post_json("/memory/a1/call/forget", %{"id" => "remote-only", "reason" => "r"})
      assert_received {:args, %{"id" => "remote-only"}}
    end

    test "queued writes are validated like the gateway tools", %{store: store} do
      Process.put(:scripted_hub_reply, {:error, :noproc})

      for {args, error} <- [
            {%{}, "invalid: content is required"},
            {%{"content" => 5}, "invalid: content is required"},
            {%{"content" => "  "}, "invalid: content can't be blank"},
            {%{"content" => "c", "kind" => "bogus"}, "invalid: kind is invalid"},
            {%{"content" => "c", "observed_at" => "later"}, "invalid: observed_at"}
          ] do
        conn = post_json("/memory/a1/call/remember", args)
        assert conn.status == 400
        assert %{"error" => ^error} = Jason.decode!(conn.resp_body)
      end

      {:ok, rec} = Local.queue_remember(store, %{"content" => "x"}, "host-agent:v")
      before = Local.pending_outbox(store, 10)

      for {args, error} <- [
            {%{"id" => rec["id"]}, "invalid: reason is required"},
            {%{"id" => rec["id"], "reason" => ""}, "invalid: reason is required"},
            {%{"reason" => "r"}, "invalid: id and reason are required"}
          ] do
        conn = post_json("/memory/a1/call/forget", args)
        assert conn.status == 400
        assert %{"error" => ^error} = Jason.decode!(conn.resp_body)
      end

      assert Local.pending_outbox(store, 10) == before
    end

    test "store disabled behaves like plan 1" do
      Application.put_env(:backplane_host_agent, :memory_store, :no_such_store_process)
      Process.put(:scripted_hub_reply, {:error, :noproc})

      conn = post_json("/memory/a1/call/remember", %{"content" => "c"})
      assert conn.status == 503
      assert %{"error" => "gateway_unavailable"} = Jason.decode!(conn.resp_body)

      conn = post_json("/memory/a1/call/search", %{"query" => "c"})
      assert conn.status == 503
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
        config: %{}
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

  defp register_crashing_store(name) do
    pid = spawn(fn -> receive do: (_ -> exit(:boom)) end)
    Process.register(pid, name)
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
