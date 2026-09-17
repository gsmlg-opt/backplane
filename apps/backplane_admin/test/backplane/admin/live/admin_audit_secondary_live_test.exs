defmodule Backplane.Admin.AuditSecondaryLiveTest do
  use Backplane.Admin.LiveCase, async: false

  alias Backplane.Admin.Audit
  alias Backplane.Skills.AgentMcpServers

  test "agent MCP validates and fails without audit, then records durable mutations only", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, "/mcp/agent/new")
    invalid = %{"agent_mcp_server" => %{"name" => "", "prefix" => "", "url" => ""}}
    render_change(view, "validate", invalid)
    render_submit(view, "save", invalid)
    assert [] = Audit.list()

    render_submit(view, "save", %{
      "agent_mcp_server" => %{
        "name" => "audit-server",
        "prefix" => "audit",
        "transport" => "http",
        "url" => "https://example.test/mcp?secret=sensitive-url-token"
      }
    })

    assert_patch(view, "/mcp/agent")
    assert [%{action: "agent_mcp_server.create", target_id: id} = event] = Audit.list()
    assert AgentMcpServers.get!(id).name == "audit-server"
    refute inspect(event) =~ "sensitive-url-token"
    refute inspect(event) =~ "example.test"

    render_click(view, "toggle_server", %{"id" => id})

    assert [
             %{action: "agent_mcp_server.toggle", target_id: ^id},
             %{action: "agent_mcp_server.create", target_id: ^id}
           ] = Audit.list()

    render_click(view, "delete", %{"id" => id})

    assert [
             %{action: "agent_mcp_server.delete", target_id: ^id},
             %{action: "agent_mcp_server.toggle", target_id: ^id},
             %{action: "agent_mcp_server.create", target_id: ^id}
           ] = Audit.list()
  end
end
