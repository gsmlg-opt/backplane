defmodule Backplane.McpProtocol.Server.ProfileRouterTest do
  use ExUnit.Case, async: true

  alias Backplane.McpProtocol.MCP.Error
  alias Backplane.McpProtocol.Protocol.Profile
  alias Backplane.McpProtocol.Server.ProfileRouter

  @modern_version "2026-07-28"

  test "routes body metadata independently to the modern profile" do
    request = modern_request("tools/list")

    assert {:ok, {:modern, %Profile{version: @modern_version}}} =
             ProfileRouter.route(request, %{
               transport: :http,
               connection_era: :unknown
             })
  end

  test "routes the real HTTP request-header shape independently to the modern profile" do
    request = %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list", "params" => %{}}

    assert {:ok, {:modern, %Profile{version: @modern_version}}} =
             ProfileRouter.route(request, %{
               type: :http,
               req_headers: [{"MCP-Protocol-Version", @modern_version}],
               connection_era: :unknown
             })
  end

  test "routes a bare server/discover request to modern metadata validation" do
    request = %{"jsonrpc" => "2.0", "id" => 1, "method" => "server/discover", "params" => %{}}

    assert {:ok, {:modern, %Profile{version: @modern_version}}} =
             ProfileRouter.route(request, %{transport: :stdio, connection_era: :unknown})
  end

  test "guardedly routes malformed server/discover params to modern metadata validation" do
    for params <- [[], "invalid", %{"_meta" => []}] do
      request = %{"jsonrpc" => "2.0", "id" => 1, "method" => "server/discover", "params" => params}

      assert {:ok, {:modern, %Profile{version: @modern_version}}} =
               ProfileRouter.route(request, %{transport: :stdio, connection_era: :unknown})
    end
  end

  test "routes initialize and an already-legacy stdio connection to the legacy executor" do
    assert {:ok, :legacy} =
             ProfileRouter.route(
               %{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize", "params" => %{}},
               %{transport: :stdio, connection_era: :unknown}
             )

    assert {:ok, :legacy} =
             ProfileRouter.route(
               %{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list", "params" => %{}},
               %{transport: :stdio, connection_era: :legacy}
             )
  end

  test "ignores a stray session identifier on a conclusively modern request" do
    assert {:ok, {:modern, %Profile{version: @modern_version}}} =
             ProfileRouter.route(modern_request("server/discover"), %{
               transport: :http,
               protocol_version_header: @modern_version,
               session_id: "stray-legacy-session"
             })
  end

  test "rejects modern markers mixed with initialize or an already-legacy connection" do
    request = modern_request("initialize")

    assert {:error, %Error{code: -32_600}} =
             ProfileRouter.route(request, %{
               transport: :http,
               protocol_version_header: @modern_version
             })

    assert {:error, %Error{code: -32_600}} =
             ProfileRouter.route(modern_request("tools/list"), %{
               transport: :stdio,
               connection_era: :legacy
             })
  end

  test "returns the modern unsupported-version error with exact requested and supported data" do
    request = modern_request("server/discover", "2099-01-01")

    assert {:error,
            %Error{
              code: -32_022,
              data: %{"requested" => "2099-01-01", "supported" => supported}
            }} = ProfileRouter.route(request, %{transport: :stdio, connection_era: :unknown})

    assert @modern_version in supported
  end

  test "does not preempt a header/body mismatch with unsupported-version handling" do
    request = modern_request("tools/list", "2099-01-01")

    assert {:ok, {:modern, %Profile{version: @modern_version}}} =
             ProfileRouter.route(request, %{
               transport: :http,
               protocol_version_header: @modern_version
             })
  end

  test "routes a header/body mismatch through a global profile when the server has no modern versions" do
    request = modern_request("tools/list")

    for supported_versions <- [[], ["2025-11-25"]] do
      assert {:ok, {:modern, %Profile{version: @modern_version}}} =
               ProfileRouter.route(request, %{
                 transport: :http,
                 protocol_version_header: "2099-01-01",
                 supported_versions: supported_versions
               })
    end
  end

  test "rejects a globally known modern version excluded by the server" do
    request = modern_request("tools/list")

    assert {:error,
            %Error{
              code: -32_022,
              data: %{"requested" => @modern_version, "supported" => []}
            }} =
             ProfileRouter.route(request, %{
               transport: :stdio,
               supported_versions: ["2025-11-25"]
             })
  end

  test "a session identifier without modern markers remains legacy" do
    request = %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list", "params" => %{}}

    assert {:ok, :legacy} =
             ProfileRouter.route(request, %{transport: :http, session_id: "legacy-session"})
  end

  defp modern_request(method, version \\ @modern_version) do
    %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => method,
      "params" => %{
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => version,
          "io.modelcontextprotocol/clientCapabilities" => %{}
        }
      }
    }
  end
end
