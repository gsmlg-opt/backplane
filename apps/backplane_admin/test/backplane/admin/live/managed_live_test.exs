defmodule Backplane.Admin.ManagedLiveTest do
  use Backplane.Admin.LiveCase, async: false

  alias Backplane.Math.Config
  alias Backplane.PubSubBroadcaster
  alias Backplane.Registry.ToolRegistry
  alias Backplane.Services.Skills
  alias Backplane.Settings

  @skills_setting "services.skill.enabled"

  setup do
    previous_setting = :ets.lookup(:backplane_settings, @skills_setting)
    previous_tools = :ets.tab2list(:backplane_tools)

    on_exit(fn ->
      :ets.delete(:backplane_settings, @skills_setting)

      if previous_setting != [] do
        :ets.insert(:backplane_settings, previous_setting)
      end

      :ets.delete_all_objects(:backplane_tools)

      if previous_tools != [] do
        :ets.insert(:backplane_tools, previous_tools)
      end
    end)

    :ok
  end

  test "renders math in managed services", %{conn: conn} do
    {:ok, _record} = Config.save(%{enabled: true})

    {:ok, _view, html} = live(conn, "/mcp/managed")

    assert html =~ "Managed Services"
    assert html =~ "Math"
    assert html =~ "math::"
    assert html =~ "math::evaluate"
    assert html =~ ~s(href="/mcp/managed/math")
  end

  test "renders web service in managed services", %{conn: conn} do
    Backplane.Settings.set("services.web.enabled", true)
    Backplane.Registry.ToolRegistry.register_managed("web", Backplane.Services.Web.tools())

    {:ok, _view, html} = live(conn, "/mcp/managed")

    assert html =~ "Managed Services"
    assert html =~ "Web"
    assert html =~ "web::"
    assert html =~ "web::fetch"
    assert html =~ "web::search"
    assert html =~ "web::live_search"
    assert html =~ "web::x_search"
    assert html =~ ~s(href="/mcp/managed/web")
  end

  test "renders the managed Skills service and its tools", %{conn: conn} do
    :ok = Skills.set_enabled(true)

    {:ok, _view, html} = live(conn, "/mcp/managed")

    assert html =~ "Skills"
    assert html =~ "skill::"
    assert html =~ "skill::search"
    assert html =~ "skill::load"
    assert html =~ "skill::list"
    assert html =~ "skill::download"
    assert html =~ "skill::publish"
    assert html =~ ~s(href="/mcp/managed/skill")
    assert html =~ ~s(href="/mcp/managed/skill/tool/list")
  end

  test "page load does not reconcile or broadcast tool changes", %{conn: conn} do
    Backplane.Settings.set("services.web.enabled", true)

    stale_tools =
      Backplane.Services.Web.tools()
      |> Enum.reject(&(&1.name == "web::live_search"))

    Backplane.Registry.ToolRegistry.deregister_managed("web")
    Backplane.Registry.ToolRegistry.register_managed("web", stale_tools)
    PubSubBroadcaster.subscribe(PubSubBroadcaster.mcp_notifications_topic())
    flush_mcp_notifications()

    {:ok, _view, html} = live(conn, "/mcp/managed")

    refute html =~ "web::live_search"
    assert ToolRegistry.resolve("web::live_search") == :not_found

    refute_receive {:mcp_notification, %{method: "notifications/tools/list_changed"}}
  end

  test "rejects an unknown service prefix without mutating the registry", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/mcp/managed")
    previous_tools = Map.new(:ets.tab2list(:backplane_tools))

    html = render_click(view, "toggle", %{"prefix" => "missing"})

    assert html =~ "Failed to update service"
    assert Map.new(:ets.tab2list(:backplane_tools)) == previous_tools
  end

  test "links managed services to settings pages", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/mcp/managed")

    assert html =~ ~s(href="/mcp/managed/day")
    assert html =~ ~s(href="/mcp/managed/web")
    assert html =~ ~s(href="/mcp/managed/math")
    assert html =~ ~s(href="/mcp/managed/skill")
  end

  test "toggles web service through settings", %{conn: conn} do
    Backplane.Settings.set("services.web.enabled", true)
    {:ok, view, _html} = live(conn, "/mcp/managed")

    view
    |> element("[phx-value-prefix='web']")
    |> render_click()

    refute Backplane.Services.Web.enabled?()

    view
    |> element("[phx-value-prefix='web']")
    |> render_click()

    assert Backplane.Services.Web.enabled?()
  end

  test "toggles math service through math config", %{conn: conn} do
    {:ok, _record} = Config.save(%{enabled: true})
    {:ok, view, _html} = live(conn, "/mcp/managed")

    view
    |> element("[phx-value-prefix='math']")
    |> render_click()

    refute Config.get(:enabled)

    view
    |> element("[phx-value-prefix='math']")
    |> render_click()

    assert Config.get(:enabled)
  end

  test "toggles the Skills setting and registry entries", %{conn: conn} do
    :ok = Skills.set_enabled(true)
    {:ok, view, _html} = live(conn, "/mcp/managed")

    view
    |> element("[phx-value-prefix='skill']")
    |> render_click()

    refute Skills.enabled?()
    refute Settings.get(@skills_setting)
    assert ToolRegistry.resolve("skill::list") == :not_found

    view
    |> element("[phx-value-prefix='skill']")
    |> render_click()

    assert Skills.enabled?()
    assert Settings.get(@skills_setting)
    assert {:managed, _} = ToolRegistry.resolve("skill::list")
  end

  defp flush_mcp_notifications do
    receive do
      {:mcp_notification, _notification} -> flush_mcp_notifications()
    after
      0 -> :ok
    end
  end
end
