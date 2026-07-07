defmodule Backplane.HostAgent.AgentChannelTest do
  use ExUnit.Case, async: false

  alias Backplane.HostAgent.AgentChannel

  setup do
    previous_services = Application.get_env(:backplane_host_agent, :local_services)
    :persistent_term.put({__MODULE__.FakeService, :owner}, self())
    Application.put_env(:backplane_host_agent, :local_services, [__MODULE__.FakeService])

    on_exit(fn ->
      if previous_services do
        Application.put_env(:backplane_host_agent, :local_services, previous_services)
      else
        Application.delete_env(:backplane_host_agent, :local_services)
      end

      :persistent_term.erase({__MODULE__.FakeService, :owner})
    end)
  end

  defmodule FakeService do
    def prefix, do: "host_agent"
    def tools, do: []

    def call("install_plugin", args, _ctx) do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:local_call, "install_plugin", args})

      {:ok,
       %{
         "plugin" => args["plugin"],
         "runtime" => args["runtime"],
         "installed" => true
       }}
    end
  end

  test "builds a plugin_call_result by executing the local host-agent service" do
    payload = %{
      "call_id" => "call-1",
      "name" => "host_agent::install_plugin",
      "arguments" => %{"plugin" => "memory", "runtime" => "hermes"}
    }

    assert %{
             "call_id" => "call-1",
             "ok" => true,
             "result" => %{
               "plugin" => "memory",
               "runtime" => "hermes",
               "installed" => true
             }
           } = AgentChannel.plugin_call_result(payload)

    assert_received {:local_call, "install_plugin",
                     %{"plugin" => "memory", "runtime" => "hermes"}}
  end

  test "returns a stable plugin_call_result error for malformed payloads" do
    assert %{"call_id" => nil, "ok" => false, "error" => error} =
             AgentChannel.plugin_call_result(%{"name" => "host_agent::install_plugin"})

    assert error =~ "invalid plugin call"
  end
end
