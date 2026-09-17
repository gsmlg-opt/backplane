defmodule Backplane.Admin.SystemConfigLiveTest do
  use Backplane.Admin.LiveCase, async: false

  alias Backplane.Admin.{Audit, SystemConfigLive}
  alias Backplane.Monitor.{ApiAccounts, ApiUsageServer}
  alias Backplane.Repo
  alias Backplane.Settings
  alias Backplane.Settings.Setting

  @setting "monitor.api_usage.enabled"

  defmodule FailingSettings do
    use GenServer

    def start_link(reason), do: GenServer.start_link(__MODULE__, reason)

    @impl true
    def init(reason), do: {:ok, reason}

    @impl true
    def handle_call({:set, "monitor.api_usage.enabled", _value}, _from, reason) do
      {:reply, {:error, reason}, reason}
    end
  end

  setup do
    previous = :ets.lookup(:backplane_settings, @setting)
    :ok = Settings.set(@setting, true)

    on_exit(fn ->
      :ets.delete(:backplane_settings, @setting)
      :ets.insert(:backplane_settings, previous)

      :ok = ApiUsageServer.reload_fetching_policy()
      ApiUsageServer.sync([])
    end)

    :ok
  end

  test "defaults to enabled and explains the independent global policy", %{conn: conn} do
    if setting = Repo.get(Setting, @setting), do: Repo.delete!(setting)
    :ets.delete(:backplane_settings, @setting)

    {:ok, view, html} = live(conn, "/system/config")

    assert has_element?(view, "#api-information-fetching[role=switch][checked]")
    assert html =~ "API information fetching"
    assert html =~ "Plan Usage"
    assert html =~ "per-account"
    assert html =~ "automatic and manual"
    assert html =~ "in-flight"
    assert html =~ "snapshots"
    assert has_element?(view, "a[href='/system/monitor/api-usage']")
    assert has_element?(view, "a[href='/dashboard/usage/api']")
  end

  test "persists disabling and re-enabling with setting-only audit targets", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, SystemConfigLive)

    view
    |> form("#api-fetching-config-form", config: %{enabled: "false"})
    |> render_change()

    refute ApiAccounts.fetching_enabled?()
    assert Repo.get!(Setting, @setting).value == %{"v" => false}
    refute has_element?(view, "#api-information-fetching[checked]")

    {:ok, reopened, _html} = live_isolated(conn, SystemConfigLive)
    refute has_element?(reopened, "#api-information-fetching[checked]")

    view
    |> form("#api-fetching-config-form", config: %{enabled: "true"})
    |> render_change()

    assert ApiAccounts.fetching_enabled?()
    assert Repo.get!(Setting, @setting).value == %{"v" => true}
    assert has_element?(view, "#api-information-fetching[checked]")

    events = Audit.list(%{target_type: "system_setting", target_id: @setting})
    assert length(events) == 2
    assert Enum.all?(events, &(&1.action == "system_setting.update"))
  end

  test "loads a previously disabled setting", %{conn: conn} do
    :ok = Settings.set(@setting, false)
    {:ok, view, _html} = live_isolated(conn, SystemConfigLive)
    refute has_element?(view, "#api-information-fetching[checked]")
  end

  test "follows Settings PubSub without auditing external changes", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, SystemConfigLive)

    :ok = Settings.set(@setting, false)
    refute has_element?(view, "#api-information-fetching[checked]")

    :ok = Settings.set(@setting, true)
    assert has_element?(view, "#api-information-fetching[checked]")
    assert Audit.list(%{target_type: "system_setting", target_id: @setting}) == []
  end

  test "ignores unrelated setting notifications", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, SystemConfigLive)
    send(view.pid, {:setting_changed, "other.secret", "do-not-render-secret"})

    assert has_element?(view, "#api-information-fetching[checked]")
    refute render(view) =~ "do-not-render-secret"
  end

  test "reads authoritative policy instead of trusting a notification payload", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, SystemConfigLive)
    send(view.pid, {:setting_changed, @setting, false})
    assert has_element?(view, "#api-information-fetching[checked]")
  end

  test "never accepts a caller-selected setting or audit target", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, SystemConfigLive)

    render_change(view, "set-fetching", %{
      "config" => %{"enabled" => false, "key" => "other.secret", "value" => "secret-value"}
    })

    refute ApiAccounts.fetching_enabled?()
    refute render(view) =~ "secret-value"
    assert Settings.get("other.secret") == nil

    assert [%{action: "system_setting.update", target_id: @setting}] =
             Audit.list(%{target_type: "system_setting"})
  end

  test "rejects unknown and malformed boolean events without mutation or secrets", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, SystemConfigLive)

    for params <- [
          %{},
          %{"config" => %{}},
          %{"config" => %{"enabled" => "do-not-render-secret"}},
          %{"config" => %{"enabled" => "0"}},
          %{"config" => %{"enabled" => "on"}},
          %{"config" => %{"enabled" => nil}},
          %{"config" => %{"enabled" => ["true"]}}
        ] do
      html = render_change(view, "set-fetching", params)
      assert html =~ "Invalid API fetching setting."
      refute html =~ "do-not-render-secret"
      assert ApiAccounts.fetching_enabled?()
      assert Repo.get!(Setting, @setting).value == %{"v" => true}
    end

    assert Audit.list(%{target_type: "system_setting", target_id: @setting}) == []
  end

  test "accepts actual boolean payloads", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, SystemConfigLive)

    render_change(view, "set-fetching", %{"config" => %{"enabled" => false}})
    refute ApiAccounts.fetching_enabled?()

    render_change(view, "set-fetching", %{"config" => %{"enabled" => true}})
    assert ApiAccounts.fetching_enabled?()
  end

  test "shows a safe setter error without auditing or changing the switch", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, SystemConfigLive)
    settings = Process.whereis(Settings)
    failing_settings = start_supervised!({FailingSettings, {:provider, "do-not-render-secret"}})
    Process.unregister(Settings)

    try do
      Process.register(failing_settings, Settings)
      html = render_change(view, "set-fetching", %{"config" => %{"enabled" => false}})

      assert html =~ "Could not update API information fetching. Please try again."
      refute html =~ "do-not-render-secret"
      assert has_element?(view, "#api-information-fetching[checked]")
      assert Settings.get(@setting)
      assert Repo.get!(Setting, @setting).value == %{"v" => true}
      assert Audit.list(%{target_type: "system_setting", target_id: @setting}) == []
    after
      if Process.whereis(Settings) == failing_settings, do: Process.unregister(Settings)
      Process.register(settings, Settings)
    end
  end
end
