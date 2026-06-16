defmodule Backplane.McpProtocol.ErrorTest do
  use ExUnit.Case, async: true

  alias Backplane.McpProtocol.Error

  describe "standard errors" do
    test "builds JSON-RPC protocol errors" do
      assert %Error{
               code: -32_700,
               reason: :parse_error,
               message: "Parse error",
               data: %{}
             } = Error.protocol(:parse_error)

      assert %Error{
               code: -32_602,
               reason: :invalid_params,
               message: "Invalid params",
               data: %{field: "name"}
             } = Error.protocol(:invalid_params, %{field: "name"})
    end

    test "builds transport, resource, and execution errors" do
      assert %Error{code: -32_000, reason: :timeout, message: "Timeout"} =
               Error.transport(:timeout)

      assert %Error{
               code: -32_002,
               reason: :resource_not_found,
               message: "Resource not found",
               data: %{uri: "file:///missing"}
             } = Error.resource(:not_found, %{uri: "file:///missing"})

      assert %Error{
               code: -32_000,
               reason: :execution_error,
               message: "database unavailable"
             } = Error.execution("database unavailable")
    end
  end

  describe "JSON-RPC conversion" do
    test "converts incoming JSON-RPC error objects into structs" do
      error =
        Error.from_json_rpc(%{
          "code" => -32_601,
          "message" => "Method not found",
          "data" => %{"method" => "missing"}
        })

      assert %Error{
               code: -32_601,
               reason: :method_not_found,
               message: "Method not found",
               data: %{"method" => "missing"}
             } = error
    end

    test "encodes structs as JSON-RPC error responses" do
      {:ok, json} =
        :invalid_params
        |> Error.protocol(%{field: "limit"})
        |> Error.to_json_rpc("req-1")

      assert %{
               "jsonrpc" => "2.0",
               "id" => "req-1",
               "error" => %{
                 "code" => -32_602,
                 "message" => "Invalid params",
                 "data" => %{"field" => "limit"}
               }
             } = Jason.decode!(json)
    end
  end

  test "inspect output stays compact" do
    assert inspect(Error.protocol(:parse_error)) ==
             "#Backplane.McpProtocol.Error<parse_error: Parse error>"

    assert inspect(Error.execution("failed", %{code: 500})) =~ "code: 500"
  end
end
