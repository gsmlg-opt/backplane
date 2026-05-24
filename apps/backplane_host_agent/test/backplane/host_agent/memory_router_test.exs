defmodule Backplane.HostAgent.MemoryRouterTest do
  use ExUnit.Case, async: false

  alias Backplane.HostAgent.{MemoryProxy, MemoryRouter}

  import Plug.Test
  import Plug.Conn

  defmodule FakeChannel do
    @moduledoc false

    def push(_channel_pid, event, payload, _timeout \\ 5_000) do
      send(__owner__(), {:proxy_push, event, payload})

      case payload do
        %{"method" => "remember", "arguments" => %{"content" => content}}
        when is_binary(content) and content != "" ->
          {:ok, %{"ok" => true, "result" => %{"id" => "mem_123", "scope" => "global"}}}

        %{"method" => "remember"} ->
          {:ok, %{"ok" => false, "error" => "content is required"}}

        %{"method" => "recall"} ->
          {:ok,
           %{
             "ok" => true,
             "result" => %{
               "results" => [
                 %{"id" => "m1", "content" => "hello world", "scope" => "/tmp/proj"}
               ]
             }
           }}

        %{"method" => "list"} ->
          {:ok,
           %{
             "ok" => true,
             "result" => %{
               "results" => [
                 %{"id" => "m1", "content" => "older", "scope" => "/tmp/proj"}
               ]
             }
           }}

        %{"method" => "forget"} ->
          {:ok, %{"ok" => true, "result" => %{"id" => "m1", "status" => "deleted"}}}

        %{"method" => "stats"} ->
          {:ok, %{"ok" => true, "result" => %{"stats" => %{"semantic" => 3}}}}

        _ ->
          {:ok, %{"ok" => true, "result" => %{}}}
      end
    end

    defp __owner__ do
      :persistent_term.get({__MODULE__, :owner})
    end
  end

  setup do
    :persistent_term.put({FakeChannel, :owner}, self())
    MemoryProxy.set_channel(self())
    Application.put_env(:backplane_host_agent, :channel_module, FakeChannel)

    on_exit(fn ->
      MemoryProxy.set_channel(nil)
      Application.delete_env(:backplane_host_agent, :channel_module)
      _ = :persistent_term.erase({FakeChannel, :owner})
    end)

    :ok
  end

  describe "POST /:agent_id/call/:method" do
    test "forwards a remember call and injects agent_id" do
      conn =
        :post
        |> conn("/agt_42/call/remember", Jason.encode!(%{"content" => "hello"}))
        |> put_req_header("content-type", "application/json")
        |> call_router()

      assert conn.status == 200
      assert %{"ok" => true, "result" => %{"id" => "mem_123"}} = Jason.decode!(conn.resp_body)

      assert_received {:proxy_push, "memory_call", %{"method" => "remember", "arguments" => args}}

      assert args["agent_id"] == "agt_42"
      assert args["content"] == "hello"
    end

    test "returns 404 for unknown memory methods" do
      conn =
        :post
        |> conn("/agt_42/call/teleport", Jason.encode!(%{}))
        |> put_req_header("content-type", "application/json")
        |> call_router()

      assert conn.status == 404

      assert %{"ok" => false, "error" => "unknown method: teleport"} =
               Jason.decode!(conn.resp_body)
    end

    test "returns 503 when no channel is set" do
      MemoryProxy.set_channel(nil)

      conn =
        :post
        |> conn("/agt_42/call/recall", Jason.encode!(%{"query" => "x"}))
        |> put_req_header("content-type", "application/json")
        |> call_router()

      assert conn.status == 503
      assert %{"error" => "host agent is not connected"} = Jason.decode!(conn.resp_body)
    end

    # Mirrors Hermes prefetch / OpenClaw before_agent_start.
    test "recall forwards query+scope+limit and returns memory rows" do
      conn =
        :post
        |> conn(
          "/agt_42/call/recall",
          Jason.encode!(%{"query" => "hello", "limit" => 5, "scope" => "/tmp/proj"})
        )
        |> put_req_header("content-type", "application/json")
        |> call_router()

      assert conn.status == 200

      assert %{
               "ok" => true,
               "result" => %{"results" => [%{"id" => "m1", "content" => "hello world"}]}
             } = Jason.decode!(conn.resp_body)

      assert_received {:proxy_push, "memory_call", %{"method" => "recall", "arguments" => args}}
      assert args["agent_id"] == "agt_42"
      assert args["query"] == "hello"
      assert args["limit"] == 5
      assert args["scope"] == "/tmp/proj"
    end

    # Mirrors Hermes system_prompt_block / memory_list tool.
    test "list forwards scope+limit and returns memory rows" do
      conn =
        :post
        |> conn(
          "/agt_42/call/list",
          Jason.encode!(%{"scope" => "/tmp/proj", "limit" => 10})
        )
        |> put_req_header("content-type", "application/json")
        |> call_router()

      assert conn.status == 200

      assert %{
               "ok" => true,
               "result" => %{"results" => [%{"id" => "m1", "content" => "older"}]}
             } = Jason.decode!(conn.resp_body)

      assert_received {:proxy_push, "memory_call", %{"method" => "list", "arguments" => args}}
      assert args["agent_id"] == "agt_42"
      assert args["scope"] == "/tmp/proj"
      assert args["limit"] == 10
    end

    # Mirrors Hermes memory_forget tool.
    test "forget forwards the id and returns deletion status" do
      conn =
        :post
        |> conn("/agt_42/call/forget", Jason.encode!(%{"id" => "m1"}))
        |> put_req_header("content-type", "application/json")
        |> call_router()

      assert conn.status == 200

      assert %{"ok" => true, "result" => %{"id" => "m1", "status" => "deleted"}} =
               Jason.decode!(conn.resp_body)

      assert_received {:proxy_push, "memory_call", %{"method" => "forget", "arguments" => args}}
      assert args["id"] == "m1"
      assert args["agent_id"] == "agt_42"
    end

    test "stats returns aggregated counts" do
      conn =
        :post
        |> conn("/agt_42/call/stats", Jason.encode!(%{}))
        |> put_req_header("content-type", "application/json")
        |> call_router()

      assert conn.status == 200

      assert %{"ok" => true, "result" => %{"stats" => %{"semantic" => 3}}} =
               Jason.decode!(conn.resp_body)

      assert_received {:proxy_push, "memory_call", %{"method" => "stats"}}
    end

    test "propagates service errors back to the caller as 400" do
      # FakeChannel returns ok=false for remember without content.
      conn =
        :post
        |> conn("/agt_42/call/remember", Jason.encode!(%{}))
        |> put_req_header("content-type", "application/json")
        |> call_router()

      assert conn.status == 400
      assert %{"ok" => false, "error" => "content is required"} = Jason.decode!(conn.resp_body)
    end

    test "accepts requests with no JSON body" do
      conn =
        :post
        |> conn("/agt_42/call/stats", "")
        |> put_req_header("content-type", "application/json")
        |> call_router()

      assert conn.status == 200
      assert_received {:proxy_push, "memory_call", %{"method" => "stats", "arguments" => args}}
      assert args["agent_id"] == "agt_42"
    end
  end

  describe "POST /:agent_id/mcp" do
    test "lists memory tools via tools/list" do
      body = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})

      conn =
        :post
        |> conn("/agt_42/mcp", body)
        |> put_req_header("content-type", "application/json")
        |> call_router()

      assert conn.status == 200
      decoded = Jason.decode!(conn.resp_body)
      assert decoded["jsonrpc"] == "2.0"
      assert decoded["id"] == 1

      assert Enum.any?(decoded["result"]["tools"], &(&1["name"] == "memory::remember"))
    end

    test "routes tools/call through MemoryProxy" do
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
        |> conn("/agt_42/mcp", body)
        |> put_req_header("content-type", "application/json")
        |> call_router()

      assert conn.status == 200
      decoded = Jason.decode!(conn.resp_body)
      assert decoded["id"] == "abc"
      assert decoded["result"]["isError"] == false

      assert_received {:proxy_push, "memory_call",
                       %{"method" => "remember", "arguments" => %{"agent_id" => "agt_42"}}}
    end

    test "returns JSON-RPC error for unknown method" do
      body = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 7, "method" => "unsupported"})

      conn =
        :post
        |> conn("/agt_42/mcp", body)
        |> put_req_header("content-type", "application/json")
        |> call_router()

      assert conn.status == 200
      decoded = Jason.decode!(conn.resp_body)
      assert decoded["error"]["code"] == -32_601
    end
  end

  defp call_router(conn) do
    MemoryRouter.call(conn, MemoryRouter.init([]))
  end
end
