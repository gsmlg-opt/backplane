defmodule Backplane.Admin.DashboardClientUsageLiveTest do
  use Backplane.Admin.LiveCase, async: false

  import Backplane.Admin.Fixtures
  import Backplane.Admin.ObservabilityCase

  test "renders LLM and MCP usage for each registered client", %{conn: conn} do
    {client, _token} = insert_client(name: "usage-client", token: "usage-client-token")

    insert_llm_log(%{
      client_id: client.id,
      requested_model: "gpt-test",
      input_tokens: 1_000,
      cached_tokens: 200,
      output_tokens: 250
    })

    mcp_log = insert_mcp_log(%{client_id: client.id, duration_ms: 40, rpc_method: "tools/call"})
    insert_mcp_tool_call(%{mcp_request_id: mcp_log.event_id, tool_name: "math::add"})

    {:ok, _view, html} = live_with_sandbox(conn, "/dashboard/usage/clients")

    assert html =~ "Client Usage"
    assert html =~ "usage-client"
    assert html =~ "1,200"
    assert html =~ "250"
    assert html =~ "MCP Usage"
    assert html =~ "gpt-test"
    assert html =~ "math::add"
  end
end
