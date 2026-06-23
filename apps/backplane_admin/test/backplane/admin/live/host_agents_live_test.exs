defmodule Backplane.Admin.HostAgentsLiveTest do
  use Backplane.Admin.LiveCase

  alias Backplane.Skills.{AgentManage, Hosts}

  setup do
    AgentManage.clear()
    on_exit(fn -> AgentManage.clear() end)
  end

  test "/system/host-agents lists durable agents with manager runtime state", %{conn: conn} do
    assert {:ok, offline_host} = Hosts.create_agent(%{"name" => "offline-host"})
    assert {:ok, host, auth_token, _token} = Hosts.create_agent_with_token(%{"name" => "t430"})

    assert :ok =
             AgentManage.register_connection(host, auth_token, self(), %{
               connect_ip: "203.0.113.7",
               connect_ip_source: "x-real-ip"
             })

    assert :ok =
             AgentManage.update_runtime(host.id, %{
               "status" => "online",
               "agent_version" => "0.1.0",
               "targets" => [%{"name" => "agents"}, %{"name" => "commands"}]
             })

    {:ok, view, html} = live(conn, "/system/host-agents")

    assert html =~ "Host Agent Management"
    assert has_element?(view, "#host-agents-table", "t430")
    assert has_element?(view, "#host-agents-table", "offline-host")
    assert html =~ "203.0.113.7"
    assert html =~ "0.1.0"
    assert html =~ "agents, commands"
    assert html =~ ~s(href="/system/host-agents/#{host.id}")
    assert html =~ ~s(href="/system/host-agents/#{offline_host.id}")
    refute html =~ "Agent Auth"
    refute html =~ "Agent Live"
    refute html =~ ~s(href="/system/host-agents/manage")
    refute html =~ ~s(href="/system/host-agents/auth")
    refute html =~ "Disconnect"
  end

  test "creating an agent stays on the list and reveals its initial token", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/system/host-agents")

    view
    |> element("#open-agent-modal")
    |> render_click()

    html =
      view
      |> form("#host-agent-form", %{"agent" => %{"name" => "new-host"}})
      |> render_submit()

    assert html =~ "new-host"
    assert html =~ "bha_"
    assert [%{host: %{name: "new-host"}}] = AgentManage.list_agents()
  end

  test "detail page manages overview auth setup config desired sync and danger tabs", %{
    conn: conn
  } do
    assert {:ok, host, auth_token, _token} = Hosts.create_agent_with_token(%{"name" => "t430"})

    assert :ok =
             AgentManage.register_connection(host, auth_token, self(), %{
               connect_ip: "198.51.100.4",
               connect_ip_source: "x-forwarded-for"
             })

    assert :ok =
             AgentManage.report_config(host.id, %{
               "agent" => %{"machine_name" => "t430"},
               "targets" => [%{"name" => "agents", "path" => "/tmp/skills"}]
             })

    {:ok, view, html} = live(conn, "/system/host-agents/#{host.id}")

    assert html =~ "t430"
    assert html =~ "198.51.100.4"
    assert has_element?(view, "#agent-tab-overview")
    assert has_element?(view, "#agent-tab-setup")
    assert has_element?(view, "#agent-tab-auth")
    assert has_element?(view, "#agent-tab-config")
    assert has_element?(view, "#agent-tab-desired")
    assert has_element?(view, "#agent-tab-sync")
    assert has_element?(view, "#agent-tab-danger")

    html =
      view
      |> element("#agent-tab-auth")
      |> render_click()

    assert html =~ "t430 token"

    html =
      view
      |> element("#reveal-token-#{auth_token.id}")
      |> render_click()

    assert html =~ "bha_"

    html =
      view
      |> element("#agent-tab-setup")
      |> render_click()

    assert html =~ "host_id: #{host.id}"
    assert html =~ "token: PASTE_TOKEN_HERE"

    html =
      view
      |> element("#agent-tab-config")
      |> render_click()

    assert html =~ "Reported Config"
    assert html =~ "/tmp/skills"

    html =
      view
      |> element("#agent-tab-desired")
      |> render_click()

    assert html =~ "Desired State"
    assert html =~ host.id
    assert html =~ "mcp_servers"

    html =
      view
      |> element("#agent-tab-sync")
      |> render_click()

    assert html =~ "Desired Servers"
    assert html =~ "Desired Skills"

    html =
      view
      |> element("#agent-tab-danger")
      |> render_click()

    assert html =~ "Delete Agent"
    assert has_element?(view, "#open-delete-agent-modal")
    refute has_element?(view, "#delete-agent-modal")
    refute html =~ "Disconnect"
  end

  test "delete agent requires typing the agent name and revokes tokens", %{conn: conn} do
    assert {:ok, host, auth_token, token} =
             Hosts.create_agent_with_token(%{"name" => "delete-me"})

    {:ok, view, _html} = live(conn, "/system/host-agents/#{host.id}")

    view
    |> element("#agent-tab-danger")
    |> render_click()

    html =
      view
      |> element("#open-delete-agent-modal")
      |> render_click()

    assert html =~ "delete-agent-modal"
    assert html =~ "Type"

    html =
      view
      |> form("#delete-agent-form", %{"delete" => %{"confirmation" => "wrong"}})
      |> render_submit()

    assert html =~ "Type the agent name to confirm"
    assert html =~ "delete-agent-modal"
    assert Hosts.get_host(host.id)
    assert Hosts.get_auth_token(auth_token.id)

    assert {:ok, _verified_host, _verified_token} = Hosts.verify_token(token)

    assert {:error, {:live_redirect, %{to: "/system/host-agents"}}} =
             view
             |> form("#delete-agent-form", %{"delete" => %{"confirmation" => "delete-me"}})
             |> render_submit()

    refute Hosts.get_host(host.id)
    refute Hosts.get_auth_token(auth_token.id)
    assert :error = Hosts.verify_token(token)
  end
end
