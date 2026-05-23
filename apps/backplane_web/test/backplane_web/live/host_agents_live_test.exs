defmodule BackplaneWeb.HostAgentsLiveTest do
  use Backplane.LiveCase

  alias Backplane.Skills.{HostConnectionRegistry, Hosts}

  setup do
    HostConnectionRegistry.clear()
    on_exit(fn -> HostConnectionRegistry.clear() end)
  end

  test "/admin/system/host-agents lists only live connected agents", %{conn: conn} do
    assert {:ok, _offline_host} = Hosts.create_agent(%{"name" => "offline-host"})
    {host, auth_token, _token} = create_agent_with_token!("t430")

    assert :ok = HostConnectionRegistry.register(host, auth_token, self())

    assert :ok =
             HostConnectionRegistry.update_runtime(host.id, %{
               "status" => "online",
               "agent_version" => "0.1.0",
               "targets" => [%{"name" => "agents"}, %{"name" => "commands"}]
             })

    {:ok, view, html} = live(conn, "/admin/system/host-agents")

    assert html =~ "Host Agent Management"
    assert has_element?(view, ~s(a[href="/admin/system/host-agents"]), "Agent Live")
    assert html =~ ~s(href="/admin/system/host-agents")
    assert html =~ ~s(href="/admin/system/host-agents/manage")
    assert html =~ ~s(href="/admin/system/host-agents/auth")
    refute html =~ "Auth Settings"
    assert has_element?(view, "#host-agents-table", "t430")
    refute html =~ "offline-host"
    assert html =~ "0.1.0"
    assert html =~ "online"
    assert html =~ ~s(href="/admin/system/host-agents/#{host.id}/config")
    assert has_element?(view, "#host-agents-table thead th", "Name")
    assert has_element?(view, "#host-agents-table thead th", "Status")
    assert has_element?(view, "#host-agents-table thead th", "Agent Version")
    assert has_element?(view, "#host-agents-table thead th", "Targets")
    assert has_element?(view, "#host-agents-table thead th", "Connected")
    assert has_element?(view, "#host-agents-table thead th", "Config")
    refute has_element?(view, "#host-agent-form")
    refute html =~ "Rotate Token"
    refute html =~ "Remove"
  end

  test "/admin/system/host-agents/:id/config redirects when agent is not connected", %{conn: conn} do
    assert {:ok, host} = Hosts.create_agent(%{"name" => "offline-host"})

    assert {:error, {:live_redirect, %{to: "/admin/system/host-agents"}}} =
             live(conn, "/admin/system/host-agents/#{host.id}/config")
  end

  test "/admin/system/host-agents/:id/config shows live config when connected", %{conn: conn} do
    {host, auth_token, _token} = create_agent_with_token!("t430")
    assert :ok = HostConnectionRegistry.register(host, auth_token, self())

    assert :ok =
             HostConnectionRegistry.report_config(host.id, %{
               "agent" => %{"machine_name" => "t430"},
               "targets" => [%{"name" => "agents", "path" => "/tmp/skills"}]
             })

    {:ok, view, html} = live(conn, "/admin/system/host-agents/#{host.id}/config")

    assert html =~ "Host Agent Config"
    assert html =~ "t430"
    assert html =~ host.id
    assert html =~ "Reported Config"
    assert html =~ "Raw Config JSON"
    assert html =~ "/tmp/skills"
    assert has_element?(view, "#host-config-targets-table", "agents")
    refute html =~ "backplane_host_agent.toml"
    refute html =~ "copy-from-auth-settings"
  end

  test "/admin/system/host-agents/:id/config handles missing reported config", %{conn: conn} do
    {host, auth_token, _token} = create_agent_with_token!("t430")
    assert :ok = HostConnectionRegistry.register(host, auth_token, self())

    {:ok, _view, html} = live(conn, "/admin/system/host-agents/#{host.id}/config")

    assert html =~ "Config not reported yet."
  end

  test "/admin/system/host-agents/auth creates and deletes unassigned tokens", %{conn: conn} do
    {:ok, view, html} = live(conn, "/admin/system/host-agents/auth")

    assert html =~ "Agent Auth"
    assert html =~ "Create and manage auth tokens for host agents"
    assert has_element?(view, "#open-auth-token-modal")
    refute has_element?(view, "#host-auth-token-form")
    refute has_element?(view, "#host-agent-form")
    refute html =~ "/host-agent/socket/websocket"
    refute html =~ "Rotate Token"
    refute html =~ "Deactivate"

    html =
      view
      |> element("#open-auth-token-modal")
      |> render_click()

    assert html =~ "Create Token"
    assert has_element?(view, "#host-auth-token-modal")
    assert has_element?(view, "#host-auth-token-form")

    html =
      view
      |> form("#host-auth-token-form", %{"token" => %{"name" => "workstations"}})
      |> render_submit()

    assert html =~ "Host agent token"
    assert html =~ "workstations"
    assert html =~ "bha_"
    assert html =~ "No"
    refute has_element?(view, "#host-auth-token-modal")
    assert Hosts.list_hosts() == []
    assert [auth_token] = Hosts.list_auth_tokens()

    view
    |> element("#delete-auth-token-#{auth_token.id}")
    |> render_click()

    assert Hosts.list_auth_tokens() == []
  end

  test "/admin/system/host-agents/auth blocks deleting assigned tokens", %{conn: conn} do
    assert {:ok, auth_token, _token} = Hosts.create_auth_token(%{"name" => "workstations"})

    assert {:ok, _host} =
             Hosts.create_agent(%{"name" => "t430", "auth_token_ids" => [auth_token.id]})

    {:ok, view, html} = live(conn, "/admin/system/host-agents/auth")

    assert html =~ "workstations"
    assert html =~ "t430"

    html =
      view
      |> element("#delete-auth-token-#{auth_token.id}")
      |> render_click()

    assert html =~ "Unassign token from agent before deleting"
    assert Hosts.get_auth_token(auth_token.id)
  end

  test "/admin/system/host-agents/manage adds edits and removes agents", %{conn: conn} do
    assert {:ok, first_token, first_plaintext} =
             Hosts.create_auth_token(%{"name" => "workstations-a"})

    assert {:ok, second_token, _second_plaintext} =
             Hosts.create_auth_token(%{"name" => "workstations-b"})

    {:ok, view, html} = live(conn, "/admin/system/host-agents/manage")

    assert html =~ "Agent Management"
    assert html =~ "Add, edit, and remove host agents"
    assert has_element?(view, "#open-agent-modal")
    refute has_element?(view, "#host-agent-form")

    html =
      view
      |> element("#open-agent-modal")
      |> render_click()

    assert has_element?(view, "#host-agent-modal")
    assert has_element?(view, "#host-agent-form")
    assert html =~ "workstations-a"
    assert html =~ "workstations-b"

    html =
      view
      |> form("#host-agent-form", %{
        "agent" => %{"name" => "t430", "auth_token_ids" => [first_token.id, second_token.id]}
      })
      |> render_submit()

    assert html =~ "t430"
    assert html =~ "workstations-a"
    assert html =~ "workstations-b"
    refute has_element?(view, "#host-agent-modal")
    host = Hosts.list_hosts() |> Enum.find(&(&1.name == "t430"))
    assert {:ok, verified, _auth_token} = Hosts.verify_token(first_plaintext)
    assert verified.id == host.id

    html =
      view
      |> element("#edit-agent-#{host.id}")
      |> render_click()

    assert html =~ "Edit Agent"
    assert has_element?(view, "#host-agent-modal")
    assert has_element?(view, "#host-agent-form")

    html =
      view
      |> form("#host-agent-form", %{
        "agent" => %{"name" => "x1", "auth_token_ids" => [second_token.id]}
      })
      |> render_submit()

    assert html =~ "x1"
    refute has_element?(view, "#host-agent-modal")
    assert Hosts.get_host(host.id).name == "x1"
    assert Hosts.auth_token_ids_for_host(host) == [second_token.id]

    view
    |> element("#delete-agent-#{host.id}")
    |> render_click()

    refute Hosts.get_host(host.id)

    assert Hosts.list_auth_tokens() |> Enum.map(& &1.name) |> Enum.sort() == [
             "workstations-a",
             "workstations-b"
           ]
  end

  test "/admin/system/host-agents/manage allows agents without tokens", %{conn: conn} do
    {:ok, view, html} = live(conn, "/admin/system/host-agents/manage")

    refute html =~ "No auth tokens available."
    assert has_element?(view, "#open-agent-modal")
    refute has_element?(view, "#host-agent-form")

    html =
      view
      |> element("#open-agent-modal")
      |> render_click()

    assert html =~ "No auth tokens available."
    refute html =~ "Create an auth token before adding an agent."
    assert has_element?(view, "#host-agent-form")

    html =
      view
      |> form("#host-agent-form", %{"agent" => %{"name" => "tokenless"}})
      |> render_submit()

    assert html =~ "tokenless"
    assert html =~ "No tokens"
  end

  test "/admin/system/host-agents/manage hides already assigned tokens when adding agent", %{
    conn: conn
  } do
    assert {:ok, assigned_token, _assigned_plaintext} =
             Hosts.create_auth_token(%{"name" => "already-assigned"})

    assert {:ok, _existing_host} =
             Hosts.create_agent(%{
               "name" => "existing-agent",
               "auth_token_ids" => [assigned_token.id]
             })

    assert {:ok, available_token, _available_plaintext} =
             Hosts.create_auth_token(%{"name" => "available-token"})

    {:ok, view, _html} = live(conn, "/admin/system/host-agents/manage")

    view
    |> element("#open-agent-modal")
    |> render_click()

    assert has_element?(view, "#host-agent-modal", "available-token")
    refute has_element?(view, "#host-agent-modal", "already-assigned")
    assert has_element?(view, ~s(#host-agent-form input[value="#{available_token.id}"]))
    refute has_element?(view, ~s(#host-agent-form input[value="#{assigned_token.id}"]))
  end

  defp create_agent_with_token!(name) do
    assert {:ok, auth_token, token} = Hosts.create_auth_token(%{"name" => "#{name} token"})

    assert {:ok, host} =
             Hosts.create_agent(%{"name" => name, "auth_token_ids" => [auth_token.id]})

    {host, auth_token, token}
  end
end
