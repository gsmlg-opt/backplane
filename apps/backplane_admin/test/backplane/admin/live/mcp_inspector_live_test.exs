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

    {:ok, _view, html} = live(conn, "/admin/mcp/inspector/internal")

    refute html =~ "/github:: (upstream)"
    assert html =~ "github:: (upstream)"
  end

  defp insert_tool(%Tool{} = tool) do
    :ets.insert(:backplane_tools, {tool.name, tool})
  end
end
