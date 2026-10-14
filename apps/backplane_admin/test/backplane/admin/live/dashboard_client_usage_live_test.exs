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

    {:ok, view, html} = live_with_sandbox(conn, "/dashboard/usage/clients")

    assert html =~ "Client Usage"
    assert html =~ "usage-client"
    assert html =~ "1,000"
    assert html =~ "250"
    assert html =~ "MCP Usage"
    assert html =~ "gpt-test"
    assert html =~ "math::add"
    refute has_element?(view, "#client-#{client.id}-models th", "Cached Tokens")

    assert has_element?(
             view,
             "#client-#{client.id}-models td",
             "1,000 / 200 (20.0%)"
           )
  end

  test "filters client LLM and MCP usage by the selected time range", %{conn: conn} do
    {client, _token} = insert_client(name: "range-client", token: "range-client-token")
    now = DateTime.utc_now()

    insert_llm_log(%{
      client_id: client.id,
      requested_model: "current-model",
      input_tokens: 100,
      output_tokens: 50,
      inserted_at: DateTime.add(now, -60, :second)
    })

    insert_llm_log(%{
      client_id: client.id,
      requested_model: "old-model",
      input_tokens: 9_999,
      output_tokens: 9_999,
      inserted_at: DateTime.add(now, -172_800, :second)
    })

    current_mcp =
      insert_mcp_log(%{
        client_id: client.id,
        rpc_method: "current/method",
        inserted_at: DateTime.add(now, -60, :second)
      })

    old_mcp =
      insert_mcp_log(%{
        client_id: client.id,
        rpc_method: "old/method",
        inserted_at: DateTime.add(now, -172_800, :second)
      })

    insert_mcp_tool_call(%{mcp_request_id: current_mcp.event_id, tool_name: "current::tool"})
    insert_mcp_tool_call(%{mcp_request_id: old_mcp.event_id, tool_name: "old::tool"})

    query =
      URI.encode_query(%{
        "since" => DateTime.to_iso8601(DateTime.add(now, -3_600, :second)),
        "until" => DateTime.to_iso8601(DateTime.add(now, 60, :second))
      })

    {:ok, view, html} = live_with_sandbox(conn, "/dashboard/usage/clients?#{query}")

    assert html =~ "current-model"
    assert html =~ "current/method"
    assert html =~ "current::tool"
    refute html =~ "old-model"
    refute html =~ "old/method"
    refute html =~ "old::tool"
    assert has_element?(view, ~s(form[action="/dashboard/usage/clients"]))
  end
end
