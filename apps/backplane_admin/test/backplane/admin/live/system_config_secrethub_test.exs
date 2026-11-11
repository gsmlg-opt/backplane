defmodule Backplane.Admin.SystemConfigSecretHubTest do
  use Backplane.Admin.LiveCase, async: false

  alias Backplane.Admin.{Audit, SystemConfigLive}
  alias Backplane.Repo
  alias Backplane.SecretHub.{Publication, Sync}
  alias Backplane.Settings
  alias Backplane.Settings.Credentials

  setup do
    keys = [Sync.enabled_key(), Sync.socket_key()]
    previous = for key <- keys, do: {key, :ets.lookup(:backplane_settings, key)}
    for key <- keys, do: :ets.delete(:backplane_settings, key)

    on_exit(fn ->
      for {key, entries} <- previous do
        :ets.delete(:backplane_settings, key)
        :ets.insert(:backplane_settings, entries)
      end
    end)

    :ok
  end

  test "sync is off by default and explains what is published", %{conn: conn} do
    {:ok, view, html} = live(conn, "/system/config")

    refute has_element?(view, "#secrethub-sync-enabled[checked]")
    assert has_element?(view, "#secrethub-sync-now[disabled]")
    assert html =~ "backplane.&lt;kind&gt;.&lt;name&gt;"
    assert html =~ "never depends on SecretHub"
  end

  test "enabling and the socket path persist with setting-only audit targets", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, SystemConfigLive)

    view |> form("#secrethub-sync-form", secrethub: %{enabled: "true"}) |> render_change()
    assert Sync.enabled?()
    assert has_element?(view, "#secrethub-sync-enabled[checked]")
    refute has_element?(view, "#secrethub-sync-now[disabled]")

    view
    |> form("#secrethub-socket-form", secrethub: %{socket_path: "  /run/secrethub/agent.sock "})
    |> render_submit()

    assert Settings.get(Sync.socket_key()) == "/run/secrethub/agent.sock"

    html =
      view
      |> form("#secrethub-socket-form", secrethub: %{socket_path: "relative.sock"})
      |> render_submit()

    assert html =~ "must be an absolute path"
    assert Settings.get(Sync.socket_key()) == "/run/secrethub/agent.sock"

    view |> form("#secrethub-socket-form", secrethub: %{socket_path: ""}) |> render_submit()
    assert Settings.get(Sync.socket_key()) == nil

    targets =
      Audit.list(%{target_type: "system_setting"})
      |> Enum.map(& &1.target_id)

    assert Sync.enabled_key() in targets
    assert Sync.socket_key() in targets
  end

  test "status lists failing credentials by name and code only", %{conn: conn} do
    {:ok, _} = Credentials.store("failing-key", "sk-must-not-render", "llm")

    Repo.insert!(%Publication{
      credential_name: "failing-key",
      path: "backplane.llm.failing-key",
      last_attempt_at: DateTime.utc_now(),
      last_error: "forbidden"
    })

    {:ok, view, html} = live(conn, "/system/config")

    assert has_element?(view, "#secrethub-sync-errors", "failing-key: forbidden")
    assert html =~ "1 failing"
    refute html =~ "sk-must-not-render"
  end
end
