defmodule Backplane.Skills.AgentPluginsTest do
  use ExUnit.Case, async: false

  alias Backplane.Skills.AgentPlugins

  setup do
    previous = Application.get_env(:backplane_skills, :host_agent_plugin_req_options)

    Application.put_env(:backplane_skills, :host_agent_plugin_req_options,
      plug: {Req.Test, __MODULE__}
    )

    on_exit(fn ->
      if previous do
        Application.put_env(:backplane_skills, :host_agent_plugin_req_options, previous)
      else
        Application.delete_env(:backplane_skills, :host_agent_plugin_req_options)
      end
    end)

    :ok
  end

  test "builds endpoint from reported host-agent config" do
    entry = entry(%{"agent" => %{"http_bind" => "0.0.0.0", "http_port" => 4333}})

    assert AgentPlugins.endpoint(entry) == {:ok, "http://198.51.100.9:4333/memory/codex/mcp"}
  end

  test "lists plugin status through host-agent local MCP" do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, mcp_result(%{"plugins" => [plugin_status("hermes", true)]}))
    end)

    assert {:ok, [%{"plugin" => "memory", "runtime" => "hermes", "installed" => true}]} =
             AgentPlugins.list(entry())
  end

  test "installs and removes plugin through host-agent local MCP" do
    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      args = request["params"]["arguments"]

      Req.Test.json(conn, mcp_result(plugin_status(args["runtime"], false)))
    end)

    assert {:ok, %{"plugin" => "memory", "runtime" => "openclaw"}} =
             AgentPlugins.install(entry(), %{"plugin" => "memory", "runtime" => "openclaw"})

    assert {:ok, %{"plugin" => "memory", "runtime" => "hermes"}} =
             AgentPlugins.remove(entry(), %{"plugin" => "memory", "runtime" => "hermes"})
  end

  defp entry(config \\ %{}) do
    %{
      host: %{id: "host-1", name: "codex"},
      connect_ip: "198.51.100.9",
      config: config
    }
  end

  defp plugin_status(runtime, installed) do
    %{
      "plugin" => "memory",
      "runtime" => runtime,
      "name" => "backplane-memory",
      "installed" => installed,
      "valid" => installed,
      "target_path" => "/tmp/backplane-memory"
    }
  end

  defp mcp_result(result) do
    %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "result" => %{
        "content" => [%{"type" => "text", "text" => Jason.encode!(result)}],
        "isError" => false
      }
    }
  end
end
