defmodule Backplane.Admin.LayoutsTest do
  use ExUnit.Case, async: true

  alias Backplane.Admin.Layouts

  test "desktop grouping keeps standalone links before the separate System groups" do
    assert [links, monitor, logs] = Layouts.left_nav_groups("/system/monitor/plans")

    assert [links.id, monitor.id, logs.id] == ["links-system-config", "monitor", "log"]

    assert Enum.map(links.items, & &1.to) == [
             "/system/config",
             "/system/appearance",
             "/system/clients",
             "/system/credentials",
             "/system/host-agents"
           ]

    assert Enum.map(monitor.items, & &1.to) == [
             "/system/monitor/plans",
             "/system/monitor/api-usage"
           ]

    assert hd(logs.items).to == "/system/logs/llm"
  end

  test "standalone Dashboard links remain after the Overview group" do
    assert [overview, links] = Layouts.left_nav_groups("/dashboard/overview")
    assert overview.id == "overview"
    assert links.id == "links-dashboard-usage-plans"
    assert Enum.map(links.items, & &1.to) == ["/dashboard/usage/plans", "/dashboard/usage/api"]
  end

  test "active navigation follows nested routes across all sections" do
    for {path, expected_id} <- [
          {"/dashboard/overview", "dashboard-overview"},
          {"/dashboard/usage/llm", "dashboard-usage-llm"},
          {"/llama/providers/example", "llama-providers"},
          {"/mcp/upstreams/new", "mcp-upstreams"},
          {"/memory/sessions/example", "memory-sessions"},
          {"/skills/browse/example", "skills-browse"},
          {"/auth/oauth/clients/example/edit", "auth-oauth-clients"},
          {"/system/credentials/new", "system-credentials"}
        ] do
      assert Layouts.active_left_nav_id(path) == expected_id
    end
  end

  test "Overview entries require an exact route match" do
    assert Layouts.active_left_nav_id("/memory") == "memory"
    assert Layouts.active_left_nav_id("/skills") == "skills"

    refute Layouts.active_left_nav_id("/memory/not-a-menu-item") == "memory"
    refute Layouts.active_left_nav_id("/skills/not-a-menu-item") == "skills"

    refute Layouts.active_left_nav_id("/dashboard/overview/not-a-menu-item") ==
             "dashboard-overview"
  end
end
