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
    assert html =~ ~s(href="/system/host-agents/#{host.id}/overview")
    assert html =~ ~s(href="/system/host-agents/#{offline_host.id}/overview")
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

    assert [] = Backplane.Admin.Audit.list()

    html =
      view
      |> form("#host-agent-form", %{"agent" => %{"name" => "new-host"}})
      |> render_submit()

    assert html =~ "new-host"
    assert html =~ "bha_"
    assert [%{host: %{id: host_id, name: "new-host"}}] = AgentManage.list_agents()

    assert [%{action: "host_agent.create", target_id: ^host_id} = event] =
             Backplane.Admin.Audit.list()

    refute inspect(event) =~ "bha_"
  end

  test "creating an agent has no memory scope input", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/system/host-agents")
    view |> element("#open-agent-modal") |> render_click()
    refute has_element?(view, "#agent-memory-scope")

    view
    |> form("#host-agent-form", %{"agent" => %{"name" => "  scoped-host  "}})
    |> render_submit()

    assert %{name: "scoped-host"} = Enum.find(Hosts.list_hosts(), &(&1.name == "scoped-host"))
  end

  test "host config and memory sync show last known reports as stale without secrets", %{
    conn: conn
  } do
    {:ok, host, token, _} = Hosts.create_agent_with_token(%{"name" => "reported-memory-host"})
    :ok = AgentManage.register_connection(host, token, self(), %{})

    :ok =
      AgentManage.update_runtime(host.id, %{
        "memory" => %{
          "status" => "available",
          "outbox_pending" => 3,
          "outbox_failed" => 1,
          "local_records" => 17,
          "last_sync_at" => "2026-11-09T01:00:00Z",
          "last_error" => "sync: gateway rejected kind"
        }
      })

    :ok =
      AgentManage.report_config(host.id, %{
        "memory" => %{"enabled" => true, "api_key" => "secret-not-rendered"},
        "local_settings_applied_at" => "2026-10-20T01:00:00Z"
      })

    {:ok, view, _} = live(conn, "/system/host-agents/#{host.id}/config")
    assert has_element?(view, "#host-local-settings-report", "2026-10-20T01:00:00Z")
    refute render(view) =~ "secret-not-rendered"
    :ok = AgentManage.disconnect(host.id)
    assert has_element?(view, "#host-report-stale", "stale")
    {:ok, sync, _} = live(conn, "/system/host-agents/#{host.id}/sync")
    assert has_element?(sync, "#host-memory-health", "Pending uploads: 3")
    assert has_element?(sync, "#host-memory-health", "Failed uploads: 1")
    assert has_element?(sync, "#host-memory-health", "sync: gateway rejected kind")
    assert has_element?(sync, "#host-memory-health", "Local records: 17")
    assert has_element?(sync, "#host-memory-health", "2026-11-09T01:00:00Z")
    refute has_element?(sync, "#host-memory-health", "Mirror")
    assert has_element?(sync, "#host-memory-health", "stale")
  end

  test "unreported memory health is unavailable", %{conn: conn} do
    {:ok, host} = Hosts.create_agent(%{"name" => "unreported-memory-host"})
    {:ok, view, _} = live(conn, "/system/host-agents/#{host.id}/sync")
    assert has_element?(view, "#host-memory-health", "Unavailable")
  end

  for {name, failed, error, badge?, shown?} <- [
        {"failed with nil error", 2, nil, true, false},
        {"failed with blank error", 2, "", true, false},
        {"no failures with an error", 0, "sync: stale boom", false, true}
      ] do
    test "memory health #{name}", %{conn: conn} do
      {:ok, host, token, _} = Hosts.create_agent_with_token(%{"name" => "h-#{unquote(name)}"})
      :ok = AgentManage.register_connection(host, token, self(), %{})

      :ok =
        AgentManage.update_runtime(host.id, %{
          "memory" => %{
            "status" => "available",
            "outbox_pending" => 0,
            "outbox_failed" => unquote(failed),
            "last_error" => unquote(error)
          }
        })

      {:ok, view, _} = live(conn, "/system/host-agents/#{host.id}/sync")
      assert has_element?(view, "#host-memory-health", "Failed uploads: #{unquote(failed)}")
      assert has_element?(view, "#host-memory-health", "Needs attention") == unquote(badge?)

      assert has_element?(view, "#host-memory-health", "Last error") ==
               unquote(shown?)

      if unquote(shown?),
        do: assert(has_element?(view, "#host-memory-health", "sync: stale boom"))
    end
  end

  test "unavailable memory store shows not running message", %{conn: conn} do
    {:ok, host, token, _} = Hosts.create_agent_with_token(%{"name" => "unavailable-mem"})
    :ok = AgentManage.register_connection(host, token, self(), %{})
    :ok = AgentManage.update_runtime(host.id, %{"memory" => %{"status" => "unavailable"}})
    {:ok, view, _} = live(conn, "/system/host-agents/#{host.id}/sync")
    assert has_element?(view, "#host-memory-health", "Local memory store is not running")
    assert has_element?(view, "#host-memory-health", "Last heartbeat")
  end

  test "failed uploads show the newest failed upload's reason", %{conn: conn} do
    {:ok, host, token, _} = Hosts.create_agent_with_token(%{"name" => "failed-reason-host"})
    :ok = AgentManage.register_connection(host, token, self(), %{})

    :ok =
      AgentManage.update_runtime(host.id, %{
        "memory" => %{
          "status" => "available",
          "outbox_failed" => 1,
          "last_failed_error" => "invalid: kind is invalid"
        }
      })

    {:ok, view, _} = live(conn, "/system/host-agents/#{host.id}/sync")
    assert has_element?(view, "#host-memory-failed-error", "invalid: kind is invalid")
    refute has_element?(view, "#host-memory-health", "Last error")
  end

  test "disabled memory health says disabled", %{conn: conn} do
    {:ok, host, token, _} = Hosts.create_agent_with_token(%{"name" => "disabled-memory-host"})
    :ok = AgentManage.register_connection(host, token, self(), %{})
    :ok = AgentManage.update_runtime(host.id, %{"memory" => %{"status" => "disabled"}})
    {:ok, view, _} = live(conn, "/system/host-agents/#{host.id}/sync")
    assert has_element?(view, "#host-memory-health", "Local memory is disabled")
  end

  test "legacy detail path redirects to overview tab", %{conn: conn} do
    assert {:ok, host} = Hosts.create_agent(%{"name" => "legacy-host"})
    expected_path = "/system/host-agents/#{host.id}/overview"

    assert {:error, {:live_redirect, %{to: ^expected_path}}} =
             live(conn, "/system/host-agents/#{host.id}")
  end

  test "detail page manages overview auth config plugin desired sync and danger tabs", %{
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
               "agent" => %{
                 "host_id" => host.id,
                 "machine_name" => "t430",
                 "hub_url" => "http://10.100.10.28:4220",
                 "token" => "REDACTED",
                 "http_port" => 4222
               },
               "memory" => %{"enabled" => true, "sync_batch_size" => 50},
               "telemetry" => %{"enabled" => true, "dir" => "/tmp/telemetry"},
               "targets" => [%{"name" => "agents", "path" => "/tmp/skills"}]
             })

    {:ok, view, html} = live(conn, "/system/host-agents/#{host.id}/overview")

    assert html =~ "t430"
    assert html =~ "198.51.100.4"
    assert has_element?(view, "#agent-tab-overview")
    refute has_element?(view, "#agent-tab-setup")
    assert has_element?(view, "#agent-tab-auth")
    assert has_element?(view, "#agent-tab-config")
    assert has_element?(view, "#agent-tab-plugin")
    assert has_element?(view, "#agent-tab-desired")
    assert has_element?(view, "#agent-tab-sync")
    assert has_element?(view, "#agent-tab-danger")
    assert html =~ ~s(href="/system/host-agents/#{host.id}/config")

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
      |> element("#agent-tab-config")
      |> render_click()

    assert html =~ "Setup Example"
    assert html =~ "host_id: #{host.id}"
    assert html =~ "token: REPLACE_WITH_AUTH_TOKEN"
    assert html =~ "http_bind: 127.0.0.1"
    assert html =~ "memory:"
    assert html =~ "telemetry:"
    assert html =~ "db_path: ~/.local/share/backplane/host_agent/memory/host_agent_memory.db"
    assert has_element?(view, "#setup-example-yaml code.language-yaml")
    assert html =~ "Reported Config"
    assert html =~ "hub_url: http://10.100.10.28:4220"
    assert html =~ "token: REDACTED"
    assert html =~ "sync_batch_size: 50"
    assert html =~ "/tmp/skills"
    assert has_element?(view, "#reported-config-yaml code.language-yaml")
    refute has_element?(view, "#host-config-targets-table")
    refute html =~ "Raw Config JSON"

    html =
      view
      |> element("#agent-tab-plugin")
      |> render_click()

    assert html =~ "Packaged Plugins"
    assert html =~ "Backplane Memory"
    assert html =~ "Hermes"
    assert html =~ "OpenClaw"
    assert html =~ "host_agent::install_plugin"
    assert html =~ "http://127.0.0.1:4222/memory/t430/mcp"
    refute html =~ "/memory/#{host.id}/mcp"

    for runtime <- ~w(claude_code codex cursor hermes openclaw) do
      assert has_element?(view, "#install-plugin-#{runtime}")
      assert has_element?(view, "#remove-plugin-#{runtime}")
    end

    assert html =~ "Claude Code"
    assert html =~ "Cursor"
    assert html =~ "~/.cursor/hooks.json + ~/.cursor/mcp.json"

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

  test "installing a plugin shows next steps from the host agent", %{conn: conn} do
    assert {:ok, host, _auth_token, _token} = Hosts.create_agent_with_token(%{"name" => "steps"})

    assert :ok =
             AgentManage.report_config(host.id, %{
               "agent" => %{"host_id" => host.id, "machine_name" => "steps", "http_port" => 4222}
             })

    previous = Application.get_env(:backplane_skills, :host_agent_plugin_http_options)

    Application.put_env(:backplane_skills, :host_agent_plugin_http_options,
      adapter: {HTTP.Test, __MODULE__}
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:backplane_skills, :host_agent_plugin_http_options, previous),
        else: Application.delete_env(:backplane_skills, :host_agent_plugin_http_options)
    end)

    HTTP.Test.stub(__MODULE__, fn _request ->
      status = %{
        "plugin" => "memory",
        "name" => "Backplane Memory",
        "runtime" => "claude_code",
        "installed" => true,
        "valid" => true,
        "next_steps" => ["claude plugin marketplace add /d/plugins/claude"]
      }

      HTTP.Test.json(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "result" => %{
          "isError" => false,
          "content" => [%{"type" => "text", "text" => Jason.encode!(status)}]
        }
      })
    end)

    {:ok, view, _html} = live(conn, "/system/host-agents/#{host.id}/plugin")

    html =
      view
      |> form("#install-plugin-claude_code")
      |> render_submit()

    assert html =~ "claude plugin marketplace add /d/plugins/claude"
  end

  test "delete agent requires typing the agent name and revokes tokens", %{conn: conn} do
    assert {:ok, host, auth_token, token} =
             Hosts.create_agent_with_token(%{"name" => "delete-me"})

    {:ok, view, _html} = live(conn, "/system/host-agents/#{host.id}/overview")

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
