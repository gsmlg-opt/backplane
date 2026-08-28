defmodule Backplane.HostAgent.MemoryRouterTest do
  use ExUnit.Case, async: false

  alias Backplane.HostAgent.Memory.{Migrator, Store}
  alias Backplane.HostAgent.MemoryProxy
  alias Backplane.HostAgent.MemoryRouter
  alias Backplane.HostAgent.Trace
  alias Turso.Result

  import Plug.Conn
  import Plug.Test

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    store = start_memory!(tmp_dir)

    Application.put_env(:backplane_host_agent, :memory_store, store)

    Application.put_env(:backplane_host_agent, :memory_config, %{
      bound_scope: "proj_local",
      tombstone_relearn: "block"
    })

    on_exit(fn ->
      Application.delete_env(:backplane_host_agent, :memory_store)
      Application.delete_env(:backplane_host_agent, :memory_config)
      Application.delete_env(:backplane_host_agent, :local_services)
      Application.delete_env(:backplane_host_agent, :hub_proxy_module)
      Application.delete_env(:backplane_host_agent, :channel_module)
      MemoryProxy.set_channel(nil)
      _ = :persistent_term.erase({StubHubProxy, :owner})
    end)

    {:ok, store: store}
  end

  defmodule StubHubProxy do
    def list_tools do
      owner = :persistent_term.get({__MODULE__, :owner})

      send(owner, :list_tools)

      {:ok,
       [
         %{"name" => "memory::recall", "description" => "must not replace local recall"},
         %{"name" => "memory::recall_explain", "description" => "hub-only memory tool"},
         %{"name" => "memory::recall_explain", "description" => "duplicate must be dropped"},
         %{"name" => "memory::semantic_search", "description" => "hub-only memory tool"},
         %{"name" => "hub::remote", "description" => "remote hub tool"},
         %{"description" => "missing name"},
         %{"name" => "", "description" => "empty name"},
         %{"name" => "   ", "description" => "blank name"},
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

  defmodule FakeHubChannel do
    def push(channel, event, payload, _timeout \\ 5_000) do
      send(channel, {:hub_push, event, payload})
      {:ok, %{"ok" => true, "result" => %{"echo" => payload["name"]}}}
    end
  end

  defmodule FakeMemoryFacade do
    def call("recall", args, ctx) do
      send(self(), {:memory_facade_call, "recall", args, ctx})

      {:ok,
       %{
         "mode" => "online",
         "authority" => "canonical",
         "consistency" => "canonical",
         "history_available" => true,
         "pending_operations" => 0,
         "recall_run_id" => "run-router-1",
         "hits" => [
           %{
             "id" => "canonical-1",
             "content" => "canonical router result",
             "score" => 0.97
           }
         ]
       }}
    end
  end

  defmodule RaisingMemoryFacade do
    def call(_method, _args, _ctx), do: raise("canonical facade crashed")
  end

  defmodule ExitingMemoryFacade do
    def call(_method, _args, _ctx), do: exit(:canonical_facade_down)
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
      {:ok, %{"has_memory_facade" => Map.has_key?(ctx, :memory_facade)}}
    end

    def call(method, _args, _ctx), do: {:error, {:unknown_method, method}}
  end

  describe "POST /memory/:agent_id/call/:method" do
    test "delegates direct recall to the canonical facade and preserves metadata" do
      conn =
        :post
        |> conn(
          "/memory/agt_42/call/recall",
          Jason.encode!(%{"query" => "canonical", "limit" => 3})
        )
        |> put_req_header("content-type", "application/json")
        |> put_private(:backplane_memory_facade, FakeMemoryFacade)
        |> call_router()

      assert conn.status == 200

      assert %{
               "ok" => true,
               "result" => %{
                 "mode" => "online",
                 "authority" => "canonical",
                 "consistency" => "canonical",
                 "history_available" => true,
                 "recall_run_id" => "run-router-1",
                 "hits" => [
                   %{
                     "id" => "canonical-1",
                     "content" => "canonical router result",
                     "score" => 0.97
                   }
                 ]
               }
             } = Jason.decode!(conn.resp_body)

      assert_received {:memory_facade_call, "recall", %{"query" => "canonical", "limit" => 3},
                       %{agent_id: "agt_42", memory_facade: FakeMemoryFacade}}
    end

    test "returns a stable canonical-facade error when the facade raises" do
      conn =
        :post
        |> conn("/memory/agt_42/call/recall", Jason.encode!(%{"query" => "canonical"}))
        |> put_req_header("content-type", "application/json")
        |> put_private(:backplane_memory_facade, RaisingMemoryFacade)
        |> call_router()

      assert conn.status == 503

      assert %{"ok" => false, "error" => "canonical memory facade is unavailable"} =
               Jason.decode!(conn.resp_body)
    end

    test "handles remember locally and stores the route agent_id", %{store: store} do
      conn =
        :post
        |> conn("/memory/agt_42/call/remember", Jason.encode!(%{"content" => "hello"}))
        |> put_req_header("content-type", "application/json")
        |> call_router()

      assert conn.status == 200

      assert %{"ok" => true, "result" => %{"id" => id, "scope" => "proj_local"}} =
               Jason.decode!(conn.resp_body)

      assert {:ok, %Result{rows: [%{"agent_id" => "agt_42"}]}} =
               Store.query(store, "SELECT agent_id FROM memories WHERE id = ?", [id])
    end

    test "returns 404 for unknown memory methods" do
      conn =
        :post
        |> conn("/memory/agt_42/call/teleport", Jason.encode!(%{}))
        |> put_req_header("content-type", "application/json")
        |> call_router()

      assert conn.status == 404

      assert %{"ok" => false, "error" => "unknown method: teleport"} =
               Jason.decode!(conn.resp_body)
    end

    test "does not expose historical local rows without a channel", %{store: store} do
      assert {:ok, _} =
               Store.execute(
                 store,
                 """
                 INSERT INTO memories(id, content, content_hash, scope, agent_id, inserted_at, updated_at)
                 VALUES (?, ?, ?, ?, ?, ?, ?)
                 """,
                 [
                   "mem_1",
                   "offline local recall",
                   hash("offline local recall"),
                   "proj_local",
                   "agt_42",
                   "2026-06-17T00:00:00Z",
                   "2026-06-17T00:00:00Z"
                 ]
               )

      conn =
        :post
        |> conn("/memory/agt_42/call/recall", Jason.encode!(%{"query" => "offline"}))
        |> put_req_header("content-type", "application/json")
        |> call_router()

      assert conn.status == 200

      assert %{
               "ok" => true,
               "result" => %{
                 "mode" => "offline",
                 "authority" => "provisional",
                 "consistency" => "provisional_only",
                 "history_available" => false,
                 "pending_operations" => 0,
                 "hits" => []
               }
             } = Jason.decode!(conn.resp_body)
    end

    test "recall accepts query and limit and returns pending writes during an outage" do
      remember!("hello world")

      conn =
        :post
        |> conn("/memory/agt_42/call/recall", Jason.encode!(%{"query" => "hello", "limit" => 5}))
        |> put_req_header("content-type", "application/json")
        |> call_router()

      assert conn.status == 200

      assert %{
               "ok" => true,
               "result" => %{
                 "mode" => "offline",
                 "authority" => "provisional",
                 "consistency" => "provisional_only",
                 "history_available" => false,
                 "pending_operations" => 1,
                 "hits" => [%{"content" => "hello world", "provisional" => true}]
               }
             } = Jason.decode!(conn.resp_body)
    end

    test "list returns local memory rows" do
      remember!("older", tags: ["ops"])

      conn =
        :post
        |> conn("/memory/agt_42/call/list", Jason.encode!(%{"tag" => "ops", "limit" => 10}))
        |> put_req_header("content-type", "application/json")
        |> call_router()

      assert conn.status == 200

      assert %{"ok" => true, "result" => %{"items" => [%{"content" => "older"}]}} =
               Jason.decode!(conn.resp_body)
    end

    test "forget soft-deletes locally" do
      id = remember!("delete me")

      conn =
        :post
        |> conn("/memory/agt_42/call/forget", Jason.encode!(%{"id" => id}))
        |> put_req_header("content-type", "application/json")
        |> call_router()

      assert conn.status == 200

      assert %{"ok" => true, "result" => %{"id" => ^id, "sync_state" => "pending"}} =
               Jason.decode!(conn.resp_body)
    end

    test "stats reports pending commands without claiming local history" do
      remember!("stats memory")

      conn =
        :post
        |> conn("/memory/agt_42/call/stats", Jason.encode!(%{}))
        |> put_req_header("content-type", "application/json")
        |> call_router()

      assert conn.status == 200

      assert %{
               "ok" => true,
               "result" => %{
                 "mode" => "offline",
                 "authority" => "provisional",
                 "consistency" => "provisional_only",
                 "history_available" => false,
                 "pending_operations" => 1,
                 "upserts" => [%{"content" => "stats memory", "provisional" => true}]
               }
             } = Jason.decode!(conn.resp_body)
    end

    test "returns validation errors as 400" do
      conn =
        :post
        |> conn("/memory/agt_42/call/remember", Jason.encode!(%{}))
        |> put_req_header("content-type", "application/json")
        |> call_router()

      assert conn.status == 400
      assert %{"ok" => false, "error" => "content is required"} = Jason.decode!(conn.resp_body)
    end

    test "accepts requests with no JSON body" do
      conn =
        :post
        |> conn("/memory/agt_42/call/stats", "")
        |> put_req_header("content-type", "application/json")
        |> call_router()

      assert conn.status == 200

      assert %{
               "ok" => true,
               "result" => %{
                 "mode" => "offline",
                 "consistency" => "provisional_only",
                 "pending_operations" => 0
               }
             } = Jason.decode!(conn.resp_body)
    end

    test "keeps the root call path as a compatibility alias" do
      conn =
        :post
        |> conn("/agt_42/call/stats", Jason.encode!(%{}))
        |> put_req_header("content-type", "application/json")
        |> call_router()

      assert conn.status == 200

      assert %{
               "ok" => true,
               "result" => %{
                 "mode" => "offline",
                 "consistency" => "provisional_only",
                 "pending_operations" => 0
               }
             } = Jason.decode!(conn.resp_body)
    end

    test "unwraps JSON-RPC params when posted to the direct call endpoint" do
      remember!("json rpc direct")

      conn =
        :post
        |> conn(
          "/memory/agt_42/call/list",
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "id" => 1,
            "method" => "list",
            "params" => %{"q" => "json", "limit" => 5}
          })
        )
        |> put_req_header("content-type", "application/json")
        |> call_router()

      assert conn.status == 200

      assert %{"ok" => true, "result" => %{"items" => [%{"content" => "json rpc direct"}]}} =
               Jason.decode!(conn.resp_body)
    end
  end

  describe "POST /memory/:agent_id/mcp" do
    test "lists local memory tools via tools/list" do
      body = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})

      conn =
        :post
        |> conn("/memory/agt_42/mcp", body)
        |> put_req_header("content-type", "application/json")
        |> call_router()

      assert conn.status == 200
      decoded = Jason.decode!(conn.resp_body)
      assert decoded["jsonrpc"] == "2.0"
      assert decoded["id"] == 1

      tool_names = Enum.map(decoded["result"]["tools"], & &1["name"])
      assert "memory::remember" in tool_names
      assert "memory::slot_write" in tool_names
      assert "memory::facet_query" in tool_names
      assert "host_agent::install_plugin" in tool_names
      assert "host_agent::remove_plugin" in tool_names
    end

    test "routes tools/call through local memory" do
      body =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => "abc",
          "method" => "tools/call",
          "params" => %{
            "name" => "memory::remember",
            "arguments" => %{"content" => "hi"}
          }
        })

      conn =
        :post
        |> conn("/memory/agt_42/mcp", body)
        |> put_req_header("content-type", "application/json")
        |> call_router()

      assert conn.status == 200
      decoded = Jason.decode!(conn.resp_body)
      assert decoded["id"] == "abc"
      assert decoded["result"]["isError"] == false

      assert %{"id" => _id, "scope" => "proj_local"} =
               decoded["result"]["content"]
               |> hd()
               |> Map.fetch!("text")
               |> Jason.decode!()
    end

    test "delegates MCP recall to the canonical facade and preserves metadata" do
      body =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => "recall",
          "method" => "tools/call",
          "params" => %{
            "name" => "memory::recall",
            "arguments" => %{"query" => "canonical", "limit" => 1}
          }
        })

      conn =
        :post
        |> conn("/memory/agt_42/mcp", body)
        |> put_req_header("content-type", "application/json")
        |> put_private(:backplane_memory_facade, FakeMemoryFacade)
        |> call_router()

      assert conn.status == 200

      decoded = Jason.decode!(conn.resp_body)
      assert decoded["id"] == "recall"
      assert decoded["result"]["isError"] == false

      assert %{
               "mode" => "online",
               "authority" => "canonical",
               "consistency" => "canonical",
               "history_available" => true,
               "recall_run_id" => "run-router-1",
               "hits" => [%{"content" => "canonical router result", "score" => 0.97}]
             } =
               decoded["result"]["content"]
               |> hd()
               |> Map.fetch!("text")
               |> Jason.decode!()

      assert_received {:memory_facade_call, "recall", %{"query" => "canonical", "limit" => 1},
                       %{agent_id: "agt_42", memory_facade: FakeMemoryFacade}}
    end

    test "returns a stable canonical-facade MCP error when the facade exits" do
      body =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => "facade-down",
          "method" => "tools/call",
          "params" => %{
            "name" => "memory::recall",
            "arguments" => %{"query" => "canonical"}
          }
        })

      conn =
        :post
        |> conn("/memory/agt_42/mcp", body)
        |> put_req_header("content-type", "application/json")
        |> put_private(:backplane_memory_facade, ExitingMemoryFacade)
        |> call_router()

      assert conn.status == 200

      assert %{
               "jsonrpc" => "2.0",
               "id" => "facade-down",
               "error" => %{
                 "code" => -32_003,
                 "message" => "canonical memory facade is unavailable"
               }
             } = Jason.decode!(conn.resp_body)
    end

    test "does not inject the memory facade into other local services" do
      Application.put_env(:backplane_host_agent, :local_services, [
        Backplane.HostAgent.Services.Memory,
        ContextProbeService
      ])

      body =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => "probe-context",
          "method" => "tools/call",
          "params" => %{"name" => "probe::context", "arguments" => %{}}
        })

      conn =
        :post
        |> conn("/memory/agt_42/mcp", body)
        |> put_req_header("content-type", "application/json")
        |> put_private(:backplane_memory_facade, FakeMemoryFacade)
        |> call_router()

      assert conn.status == 200

      assert %{"result" => %{"isError" => false, "content" => [%{"text" => text}]}} =
               Jason.decode!(conn.resp_body)

      assert %{"has_memory_facade" => false} = Jason.decode!(text)
      assert_received {:probe_context, %{agent_id: "agt_42"}}
    end

    test "routes Hub-only memory tools through the hub" do
      :persistent_term.put({StubHubProxy, :owner}, self())
      Application.put_env(:backplane_host_agent, :hub_proxy_module, StubHubProxy)

      body =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 7,
          "method" => "tools/call",
          "params" => %{"name" => "memory::semantic_search", "arguments" => %{}}
        })

      conn =
        :post
        |> conn("/memory/agt_42/mcp", body)
        |> put_req_header("content-type", "application/json")
        |> call_router()

      assert conn.status == 200
      decoded = Jason.decode!(conn.resp_body)
      assert decoded["result"]["isError"] == false

      assert %{"echo" => "memory::semantic_search", "arguments" => %{}} =
               decoded["result"]["content"] |> hd() |> Map.fetch!("text") |> Jason.decode!()

      assert_received {:call_tool, "memory::semantic_search", %{}}
      _ = :persistent_term.erase({StubHubProxy, :owner})
    end

    test "proxies unknown service tools through the hub" do
      :persistent_term.put({StubHubProxy, :owner}, self())
      Application.put_env(:backplane_host_agent, :hub_proxy_module, StubHubProxy)

      body =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 8,
          "method" => "tools/call",
          "params" => %{"name" => "unknown::tool", "arguments" => %{"x" => 1}}
        })

      conn =
        :post
        |> conn("/memory/agt_42/mcp", body)
        |> put_req_header("content-type", "application/json")
        |> call_router()

      assert conn.status == 200
      decoded = Jason.decode!(conn.resp_body)
      assert decoded["result"]["isError"] == false

      assert %{"echo" => "unknown::tool", "arguments" => %{"x" => 1}} =
               decoded["result"]["content"] |> hd() |> Map.fetch!("text") |> Jason.decode!()

      assert_received {:call_tool, "unknown::tool", %{"x" => 1}}
      _ = :persistent_term.erase({StubHubProxy, :owner})
    end

    test "sets context from incoming traceparent and propagates it to hub calls" do
      incoming = Trace.to_traceparent(Trace.new_ctx())
      "00-" <> trace_id_and_rest = incoming
      <<trace_id::binary-size(32), _rest::binary>> = trace_id_and_rest

      MemoryProxy.set_channel(self())
      Application.delete_env(:backplane_host_agent, :hub_proxy_module)
      Application.put_env(:backplane_host_agent, :channel_module, FakeHubChannel)

      body =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 9,
          "method" => "tools/call",
          "params" => %{"name" => "unknown::tool", "arguments" => %{"x" => 1}}
        })

      conn =
        :post
        |> conn("/memory/agt_42/mcp", body)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("traceparent", incoming)
        |> call_router()

      assert conn.status == 200

      assert_receive {:hub_push, "mcp_tool_call",
                      %{
                        "name" => "unknown::tool",
                        "arguments" => %{"x" => 1},
                        "traceparent" => outgoing
                      }}

      assert outgoing =~ "00-#{trace_id}-"
      assert outgoing != incoming
    end

    test "returns a tool error result when the hub proxy is disconnected" do
      Application.put_env(:backplane_host_agent, :hub_proxy_module, ErrorHubProxy)

      body =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 8,
          "method" => "tools/call",
          "params" => %{"name" => "unknown::tool", "arguments" => %{}}
        })

      conn =
        :post
        |> conn("/memory/agt_42/mcp", body)
        |> put_req_header("content-type", "application/json")
        |> call_router()

      assert conn.status == 200

      assert %{"result" => %{"isError" => true, "content" => [%{"text" => message}]}} =
               Jason.decode!(conn.resp_body)

      assert message == "hub unreachable: not_connected"
    end

    test "merges tools/list with hub tools by exact name" do
      :persistent_term.put({StubHubProxy, :owner}, self())
      Application.put_env(:backplane_host_agent, :hub_proxy_module, StubHubProxy)

      body = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})

      conn =
        :post
        |> conn("/memory/agt_42/mcp", body)
        |> put_req_header("content-type", "application/json")
        |> call_router()

      assert conn.status == 200

      tools =
        conn.resp_body
        |> Jason.decode!()
        |> get_in(["result", "tools"])

      tool_names = Enum.map(tools, & &1["name"])

      assert "memory::remember" in tool_names
      assert "memory::recall_explain" in tool_names
      assert "memory::semantic_search" in tool_names
      assert Enum.count(tool_names, &(&1 == "memory::recall")) == 1
      assert Enum.count(tool_names, &(&1 == "memory::recall_explain")) == 1
      assert "hub::remote" in tool_names

      assert Enum.all?(tools, fn tool ->
               is_map(tool) and is_binary(tool["name"]) and String.trim(tool["name"]) != ""
             end)

      assert %{"description" => "hub-only memory tool"} =
               Enum.find(tools, &(&1["name"] == "memory::recall_explain"))

      assert Enum.find_index(tool_names, &(&1 == "memory::recall_explain")) <
               Enum.find_index(tool_names, &(&1 == "memory::semantic_search"))

      assert Enum.find_index(tool_names, &(&1 == "memory::semantic_search")) <
               Enum.find_index(tool_names, &(&1 == "hub::remote"))

      assert_received :list_tools
      _ = :persistent_term.erase({StubHubProxy, :owner})
    end

    test "tools/list returns local tools only when hub proxy is disconnected" do
      Application.put_env(:backplane_host_agent, :hub_proxy_module, ErrorHubProxy)

      body = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})

      conn =
        :post
        |> conn("/memory/agt_42/mcp", body)
        |> put_req_header("content-type", "application/json")
        |> call_router()

      assert conn.status == 200

      tool_names =
        conn.resp_body
        |> Jason.decode!()
        |> get_in(["result", "tools"])
        |> Enum.map(& &1["name"])

      assert "memory::remember" in tool_names
      refute "hub::remote" in tool_names
    end

    test "root /mcp defaults tool context agent_id to local", %{store: store} do
      body =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => "local-agent",
          "method" => "tools/call",
          "params" => %{
            "name" => "memory::remember",
            "arguments" => %{"content" => "root mcp"}
          }
        })

      conn =
        :post
        |> conn("/mcp", body)
        |> put_req_header("content-type", "application/json")
        |> call_router()

      assert conn.status == 200

      assert %{"result" => %{"isError" => false, "content" => [%{"text" => text}]}} =
               Jason.decode!(conn.resp_body)

      assert %{"id" => id} = Jason.decode!(text)

      assert {:ok, %Result{rows: [%{"agent_id" => "local"}]}} =
               Store.query(store, "SELECT agent_id FROM memories WHERE id = ?", [id])
    end

    test "returns JSON-RPC error for unknown JSON-RPC method" do
      body = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 7, "method" => "unsupported"})

      conn =
        :post
        |> conn("/memory/agt_42/mcp", body)
        |> put_req_header("content-type", "application/json")
        |> call_router()

      assert conn.status == 200
      decoded = Jason.decode!(conn.resp_body)
      assert decoded["error"]["code"] == -32_601
    end
  end

  defp remember!(content, opts \\ []) do
    tags = Keyword.get(opts, :tags, [])

    conn =
      :post
      |> conn(
        "/memory/agt_42/call/remember",
        Jason.encode!(%{"content" => content, "tags" => tags})
      )
      |> put_req_header("content-type", "application/json")
      |> call_router()

    assert conn.status == 200
    %{"ok" => true, "result" => %{"id" => id}} = Jason.decode!(conn.resp_body)
    id
  end

  defp call_router(conn), do: MemoryRouter.call(conn, MemoryRouter.init([]))

  defp start_memory!(tmp_dir) do
    name = :"host_agent_memory_router_#{System.unique_integer([:positive])}"
    db_path = Path.join(tmp_dir, "#{name}.db")

    start_supervised!(
      {Store, database: db_path, name: name, pool_size: 1, busy_timeout_ms: 5_000}
    )

    assert :ok = Migrator.migrate(name)
    name
  end

  defp hash(content) do
    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
  end
end
