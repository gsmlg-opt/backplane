defmodule Backplane.Transport.McpEraRouterTest do
  use ExUnit.Case, async: true

  alias Backplane.McpProtocol.MCP.Error
  alias Backplane.McpProtocol.Protocol.Profile
  alias Backplane.Transport.McpEraRouter, as: EraRouter

  @modern_version "2026-07-28"
  @legacy_versions ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]

  test "keeps unmarked and initialize traffic legacy" do
    assert {:ok, :legacy} = EraRouter.route(request("ping"), [])

    assert {:ok, :legacy} =
             EraRouter.route(
               request("initialize", %{"protocolVersion" => @modern_version}),
               []
             )
  end

  test "keeps registered legacy protocol headers on the legacy path" do
    for version <- @legacy_versions do
      headers = [{"McP-PrOtOcOl-VeRsIoN", version}]

      refute EraRouter.modern_header?(headers)
      assert {:ok, :legacy} = EraRouter.route(request("tools/list"), headers)
    end
  end

  test "routes explicit modern markers" do
    headers = modern_headers("tools/list")

    assert EraRouter.modern_header?(headers)

    assert {:ok, {:modern, %Profile{version: @modern_version}}} =
             route =
             EraRouter.route(request("tools/list"), headers)

    assert EraRouter.era(route) == :modern
  end

  test "rejects a modern marker combined with a legacy session" do
    headers = [{"mcp-session-id", "legacy"} | modern_headers("tools/list")]

    assert {:error, %Error{reason: :invalid_request}} =
             route =
             EraRouter.route(request("tools/list"), headers)

    assert EraRouter.era(route) == :modern
  end

  test "classifies an unknown protocol version as modern and reports it unsupported" do
    headers = [
      {"MCP-PROTOCOL-VERSION", "2099-01-01"},
      {"MCP-METHOD", "tools/list"}
    ]

    assert EraRouter.modern_header?(headers)

    assert {:error,
            %Error{
              reason: :unsupported_protocol_version,
              data: %{
                "requested" => "2099-01-01",
                "supported" => [@modern_version]
              }
            }} = route = EraRouter.route(request("tools/list"), headers)

    assert EraRouter.era(route) == :modern
  end

  test "rejects duplicate protocol version headers regardless of order or value" do
    legacy = {"mcp-protocol-version", "2025-11-25"}
    modern = {"MCP-Protocol-Version", @modern_version}

    duplicate_headers = [
      [legacy, modern],
      [modern, legacy],
      [modern, {"Mcp-Protocol-Version", @modern_version}],
      [legacy, {"MCP-PROTOCOL-VERSION", "2025-11-25"}]
    ]

    for headers <- duplicate_headers do
      assert EraRouter.modern_header?(headers)

      assert {:error, %Error{reason: :invalid_request}} =
               EraRouter.route(request("tools/list"), headers)
    end
  end

  test "classifies malformed headers as modern errors without raising" do
    malformed_headers = [
      :not_a_list,
      %{"mcp-protocol-version" => @modern_version},
      ["not-a-header-pair"],
      [{"missing-value"}],
      [{:mcp_protocol_version, @modern_version}],
      [{"mcp-protocol-version", :modern}],
      [{42, "value"}],
      [{"x-test", 42}]
    ]

    for headers <- malformed_headers do
      assert EraRouter.modern_header?(headers)

      assert {:error, %Error{reason: :invalid_request}} =
               EraRouter.route(request("tools/list"), headers)
    end
  end

  test "maps only the successful legacy route to the legacy era" do
    assert EraRouter.era({:ok, :legacy}) == :legacy

    assert EraRouter.era({:ok, {:modern, %{version: @modern_version}}}) == :modern

    assert EraRouter.era({:error, Error.protocol(:invalid_request)}) == :modern
  end

  defp request(method, params \\ %{}) do
    %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}
  end

  defp modern_headers(method) do
    [
      {"Mcp-Protocol-Version", @modern_version},
      {"Mcp-Method", method}
    ]
  end
end
