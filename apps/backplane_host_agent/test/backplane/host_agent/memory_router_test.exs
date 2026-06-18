defmodule Backplane.HostAgent.MemoryRouterTest do
  use ExUnit.Case, async: false

  alias Backplane.HostAgent.Memory.{Migrator, Store}
  alias Backplane.HostAgent.MemoryRouter
  alias ExTurso.Result

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
    end)

    {:ok, store: store}
  end

  describe "POST /memory/:agent_id/call/:method" do
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

    test "works without a channel process", %{store: store} do
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
                 "hits" => [
                   %{"id" => "mem_1", "content" => "offline local recall", "source" => "local"}
                 ]
               }
             } = Jason.decode!(conn.resp_body)
    end

    test "recall accepts query and limit and returns local rows" do
      remember!("hello world")

      conn =
        :post
        |> conn("/memory/agt_42/call/recall", Jason.encode!(%{"query" => "hello", "limit" => 5}))
        |> put_req_header("content-type", "application/json")
        |> call_router()

      assert conn.status == 200

      assert %{
               "ok" => true,
               "result" => %{"hits" => [%{"content" => "hello world", "quality" => "degraded"}]}
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

    test "stats returns local counts" do
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
                 "memories" => %{"pending" => 1},
                 "outbox" => %{"pending" => 1},
                 "known_scopes" => ["proj_local"]
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
      assert %{"ok" => true, "result" => %{"facts" => 0}} = Jason.decode!(conn.resp_body)
    end

    test "keeps the root call path as a compatibility alias" do
      conn =
        :post
        |> conn("/agt_42/call/stats", Jason.encode!(%{}))
        |> put_req_header("content-type", "application/json")
        |> call_router()

      assert conn.status == 200
      assert %{"ok" => true, "result" => %{"facts" => 0}} = Jason.decode!(conn.resp_body)
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

    test "returns JSON-RPC error for unknown memory tools" do
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
      assert decoded["error"]["code"] == -32_601
      assert decoded["error"]["message"] == "Unknown memory method: semantic_search"
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
