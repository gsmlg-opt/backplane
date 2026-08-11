defmodule Backplane.McpProtocol.MCP.ModernErrorTest do
  use ExUnit.Case, async: true

  alias Backplane.McpProtocol.MCP.Error

  test "uses the protocol-reserved modern error codes" do
    assert %Error{code: -32_020, reason: :header_mismatch} =
             Error.for_version("2026-07-28", :header_mismatch)

    assert %Error{code: -32_021, reason: :missing_client_capability} =
             Error.for_version("2026-07-28", :missing_client_capability)

    assert %Error{
             code: -32_022,
             reason: :unsupported_protocol_version,
             data: %{"requested" => "x", "supported" => ["2026-07-28"]}
           } =
             Error.for_version("2026-07-28", :unsupported_protocol_version, %{
               requested: "x",
               supported: ["2026-07-28"]
             })
  end

  test "carries required capabilities in the modern capability error" do
    required = %{"elicitation" => %{"form" => %{}}}

    assert %Error{data: %{"requiredCapabilities" => ^required}} =
             Error.for_version("2026-07-28", :missing_client_capability, %{
               requiredCapabilities: required
             })
  end

  test "keeps legacy resource-not-found behavior" do
    assert %Error{code: -32_002, reason: :resource_not_found} =
             Error.for_version("2025-11-25", :resource_not_found, %{uri: "file:///missing"})

    assert %Error{code: -32_602, reason: :invalid_params} =
             Error.for_version("2026-07-28", :resource_not_found, %{uri: "file:///missing"})
  end
end
