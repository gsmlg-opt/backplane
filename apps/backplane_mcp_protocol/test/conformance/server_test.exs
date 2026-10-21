Code.require_file("conformance_server.ex", __DIR__)

defmodule Conformance.ServerTest do
  use ExUnit.Case, async: false

  test "Bandit serves modern discovery over the actual loopback listener" do
    supervisor = start_supervised!({Conformance.Server, port: 0, name: __MODULE__.Supervisor})

    {_id, listener, _, _} =
      Enum.find(Supervisor.which_children(supervisor), fn {_id, _pid, _type, modules} ->
        modules == [Bandit]
      end)

    assert {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(listener)
    assert port > 0

    response =
      Req.post!("http://127.0.0.1:#{port}/mcp",
        headers: [
          {"mcp-protocol-version", "2026-07-28"},
          {"mcp-method", "server/discover"},
          {"accept", "application/json, text/event-stream"}
        ],
        json: %{
          jsonrpc: "2.0",
          id: "smoke",
          method: "server/discover",
          params: %{
            "_meta" => %{
              "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
              "io.modelcontextprotocol/clientCapabilities" => %{}
            }
          }
        },
        retry: false
      )

    assert response.status == 200
    assert response.body["id"] == "smoke"
    assert response.body["result"]["resultType"] == "complete"

    assert response.body["result"]["_meta"]["io.modelcontextprotocol/serverInfo"]["name"] ==
             "backplane-mcp-conformance-server"

    assert "2026-07-28" in response.body["result"]["supportedVersions"]
    refute Map.has_key?(response.headers, "mcp-session-id")
  end
end
