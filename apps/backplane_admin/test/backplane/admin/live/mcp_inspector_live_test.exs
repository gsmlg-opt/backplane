defmodule Backplane.Admin.McpInspectorLiveTest do
  use Backplane.Admin.LiveCase, async: false

  alias Backplane.Registry.Tool

  setup do
    tools = :ets.tab2list(:backplane_tools)
    :ets.delete_all_objects(:backplane_tools)

    on_exit(fn ->
      :ets.delete_all_objects(:backplane_tools)
      :ets.insert(:backplane_tools, tools)
    end)

    :ok
  end

  test "internal source list merges path-like upstream prefixes", %{conn: conn} do
    insert_tool(%Tool{
      name: "/github::search",
      description: "Search repositories",
      input_schema: %{},
      origin: {:upstream, "/github"},
      original_name: "search"
    })

    insert_tool(%Tool{
      name: "github::create_issue",
      description: "Create issues",
      input_schema: %{},
      origin: {:upstream, "github"},
      original_name: "create_issue"
    })

    {:ok, _view, html} = live(conn, "/mcp/inspector/internal")

    refute html =~ "/github:: (upstream)"
    assert html =~ "github:: (upstream)"
  end

  test "stdio connect reports timeout when process never replies", %{conn: conn} do
    previous_timeout = Application.get_env(:backplane_admin, :mcp_inspector_stdio_timeout_ms)
    Application.put_env(:backplane_admin, :mcp_inspector_stdio_timeout_ms, 20)

    on_exit(fn ->
      if is_nil(previous_timeout) do
        Application.delete_env(:backplane_admin, :mcp_inspector_stdio_timeout_ms)
      else
        Application.put_env(:backplane_admin, :mcp_inspector_stdio_timeout_ms, previous_timeout)
      end
    end)

    {:ok, view, _html} = live(conn, "/mcp/inspector")

    render_change(view, "update_config", %{
      "transport" => "stdio",
      "command" => "/bin/sleep",
      "args" => "2",
      "env" => ""
    })

    render_click(view, "connect")
    Process.sleep(50)

    assert render(view) =~ "Timed out waiting for stdio initialize response"
  end

  defp insert_tool(%Tool{} = tool) do
    :ets.insert(:backplane_tools, {tool.name, tool})
  end
end
