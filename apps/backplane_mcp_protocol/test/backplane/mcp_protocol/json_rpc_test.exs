defmodule Backplane.McpProtocol.JsonRpcTest do
  use ExUnit.Case, async: true

  alias Backplane.McpProtocol.JsonRpc

  test "builds request objects" do
    assert %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping", "params" => %{}} =
             JsonRpc.request("ping", %{}, id: 1)
  end

  test "generates request IDs when no ID is supplied" do
    assert %{"id" => id} = JsonRpc.request("ping")
    assert is_integer(id)
    assert id > 0
  end

  test "builds notification objects without id" do
    assert %{"jsonrpc" => "2.0", "method" => "notifications/initialized"} =
             JsonRpc.notification("notifications/initialized")
  end

  test "builds result responses" do
    assert %{"jsonrpc" => "2.0", "id" => "abc", "result" => %{}} =
             JsonRpc.result("abc", %{})
  end

  test "builds result responses for any JSON result value" do
    assert %{"jsonrpc" => "2.0", "id" => "abc", "result" => "pong"} =
             JsonRpc.result("abc", "pong")
  end

  test "builds error responses" do
    assert %{
             "jsonrpc" => "2.0",
             "id" => nil,
             "error" => %{"code" => -32_600, "message" => "Invalid Request"}
           } = JsonRpc.error(nil, -32_600, "Invalid Request")
  end

  test "validates request objects" do
    assert {:ok, %{"method" => "ping"}} =
             JsonRpc.validate_request(%{"jsonrpc" => "2.0", "method" => "ping"})

    assert {:error, -32_600, "Invalid Request"} =
             JsonRpc.validate_request(%{"method" => "ping"})
  end
end
