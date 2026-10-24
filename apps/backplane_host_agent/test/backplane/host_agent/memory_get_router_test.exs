defmodule Backplane.HostAgent.MemoryGetRouterTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Backplane.HostAgent.{MemoryProxy, MemoryRouter}

  @id "11111111-1111-4111-8111-111111111111"

  defmodule Channel do
    def push(channel, "memory_call", payload, _timeout) do
      send(channel, {:canonical_get, payload})
      Process.get(:canonical_get_reply)
    end
  end

  defmodule ForbiddenHub do
    def call_tool(_, _), do: raise("exact get bypassed the canonical memory channel")
  end

  setup do
    previous =
      Map.new(
        [:channel_module, :hub_proxy_module],
        &{&1, Application.fetch_env(:backplane_host_agent, &1)}
      )

    MemoryProxy.set_channel(self())
    Application.put_env(:backplane_host_agent, :channel_module, Channel)
    Application.put_env(:backplane_host_agent, :hub_proxy_module, ForbiddenHub)
    Process.put(:canonical_get_reply, {:ok, %{"ok" => true, "result" => result()}})

    on_exit(fn ->
      MemoryProxy.set_channel(nil)

      for {key, value} <- previous do
        case value do
          {:ok, setting} -> Application.put_env(:backplane_host_agent, key, setting)
          :error -> Application.delete_env(:backplane_host_agent, key)
        end
      end
    end)

    :ok
  end

  test "direct and MCP get return identical complete canonical records" do
    direct = request("/memory/consumer/call/get", %{"id" => @id})
    assert direct.status == 200
    assert Jason.decode!(direct.resp_body) == %{"ok" => true, "result" => result()}
    assert_received {:canonical_get, %{"method" => "get", "arguments" => %{"id" => @id}}}

    mcp = request("/memory/consumer/mcp", mcp_args(%{"id" => @id}))
    assert mcp.status == 200

    assert %{"result" => %{"content" => [%{"text" => text}], "isError" => false}} =
             Jason.decode!(mcp.resp_body)

    assert Jason.decode!(text) == result()
    assert_received {:canonical_get, %{"method" => "get", "arguments" => %{"id" => @id}}}
  end

  test "get direct HTTP statuses preserve canonical classifications" do
    for {code, status} <- [
          {"not_found", 404},
          {"unauthorized", 403},
          {"invalid_arguments", 400},
          {"unsupported_filter", 400},
          {"payload_too_large", 413},
          {"unsupported_operation", 501}
        ] do
      Process.put(:canonical_get_reply, {:ok, %{"ok" => false, "error" => code}})
      conn = request("/memory/consumer/call/get", %{"id" => @id})
      assert conn.status == status
      assert Jason.decode!(conn.resp_body) == %{"ok" => false, "error" => code}
      MemoryProxy.set_channel(nil)
      MemoryProxy.set_channel(self())
    end
  end

  test "disconnected get fails explicitly on direct and MCP without HubProxy fallback" do
    MemoryProxy.set_channel(nil)
    conn = request("/memory/consumer/call/get", %{"id" => @id})
    assert conn.status == 503
    assert Jason.decode!(conn.resp_body) == %{"ok" => false, "error" => "canonical_unavailable"}

    conn = request("/memory/consumer/mcp", mcp_args(%{"id" => @id}))
    assert %{"error" => %{"message" => "canonical_unavailable"}} = Jason.decode!(conn.resp_body)
    refute_received {:canonical_get, _}
  end

  test "unknown get input never reaches the channel" do
    conn = request("/memory/consumer/call/get", %{"id" => @id, "scope" => "other"})
    assert conn.status == 400
    refute_received {:canonical_get, _}
  end

  defp request(path, body) do
    :post
    |> conn(path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> MemoryRouter.call(MemoryRouter.init([]))
  end

  defp mcp_args(args),
    do: %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{"name" => "memory::get", "arguments" => args}
    }

  defp result,
    do: %{
      "record" => %{
        "id" => @id,
        "canonical_id" => @id,
        "kind" => "memory",
        "content" => String.duplicate("whole record ", 100)
      },
      "mode" => "online",
      "authority" => "canonical",
      "consistency" => "canonical",
      "stale" => false,
      "history_available" => true
    }
end
