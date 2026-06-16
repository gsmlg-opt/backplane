defmodule Backplane.McpProtocol.ResponseTest do
  use ExUnit.Case, async: true

  alias Backplane.McpProtocol.Response

  test "wraps successful JSON-RPC results" do
    response =
      Response.from_json_rpc(%{
        "jsonrpc" => "2.0",
        "id" => "req-1",
        "result" => %{"content" => []}
      })

    assert Response.success?(response)
    refute Response.error?(response)
    assert Response.get_id(response) == "req-1"
    assert Response.unwrap(response) == %{"content" => []}
  end

  test "treats MCP isError results as domain errors" do
    response =
      Response.from_json_rpc(%{
        "jsonrpc" => "2.0",
        "id" => "req-2",
        "result" => %{"isError" => true, "content" => []}
      })

    refute Response.success?(response)
    assert Response.error?(response)
    assert Response.get_result(response) == %{"isError" => true, "content" => []}
  end

  test "keeps non-map results available to callers" do
    response =
      Response.from_json_rpc(%{
        "jsonrpc" => "2.0",
        "id" => 3,
        "result" => "pong"
      })

    assert Response.success?(response)
    assert Response.unwrap(response) == "pong"
  end
end
