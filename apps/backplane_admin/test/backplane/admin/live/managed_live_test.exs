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

  test "concurrent Skills clicks each flip the state atomically", %{conn: conn} do
    :ok = Skills.set_enabled(false)
    {:ok, first_view, _html} = live(conn, "/mcp/managed")
    {:ok, second_view, _html} = live(recycle(conn), "/mcp/managed")

    handler_id = "managed-skills-toggle-race-#{System.unique_integer([:positive])}"
    parent = self()
    release_query = make_ref()
    gate = start_supervised!({Agent, fn -> false end})

    :ok =
      :telemetry.attach(
        handler_id,
        [:backplane, :repo, :query],
        fn _event, _measurements, metadata, {test_pid, query_ref, gate} ->
          first_settings_query? =
            metadata[:source] == "system_settings" and
              Agent.get_and_update(gate, fn
                false -> {true, true}
                true -> {false, true}
              end)

          if first_settings_query? do
            send(test_pid, {:ui_toggle_query_blocked, self()})

            receive do
              {:release_ui_toggle_query, ^query_ref} -> :ok
            end
          end
        end,
        {parent, release_query, gate}
      )

    first_click =
      Task.async(fn -> render_click(first_view, "toggle", %{"prefix" => "skill"}) end)

    on_exit(fn ->
      :telemetry.detach(handler_id)

      if Process.alive?(first_click.pid) do
        if settings_pid = Process.whereis(Settings) do
          send(settings_pid, {:release_ui_toggle_query, release_query})
        end

        safely_resume(first_click.pid)
      end
    end)

    assert_receive {:ui_toggle_query_blocked, settings_pid}, 1_000

    second_click =
      Task.async(fn ->
        send(parent, :second_ui_toggle_started)
        render_click(second_view, "toggle", %{"prefix" => "skill"})
      end)

    on_exit(fn ->
      if Process.alive?(second_click.pid), do: safely_resume(second_click.pid)
    end)

    assert_receive :second_ui_toggle_started, 1_000
    assert Task.yield(second_click, 100) == nil

    send(settings_pid, {:release_ui_toggle_query, release_query})
    assert is_binary(Task.await(first_click, 1_000))
    assert is_binary(Task.await(second_click, 1_000))

    refute Skills.enabled?()
    refute Settings.get(@skills_setting)
    assert ToolRegistry.resolve("skill::list") == :not_found
  end

  defp flush_mcp_notifications do
    receive do
      {:mcp_notification, _notification} -> flush_mcp_notifications()
    after
      0 -> :ok
    end
  end

  defp safely_resume(pid) do
    :erlang.resume_process(pid)
  catch
    :error, :badarg -> :ok
  end
end
