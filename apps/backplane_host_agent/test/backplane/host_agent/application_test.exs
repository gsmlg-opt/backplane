defmodule Backplane.HostAgent.ApplicationTest do
  use ExUnit.Case, async: false

  alias Backplane.HostAgent.Application, as: HostAgentApplication

  setup do
    previous = Application.get_env(:backplane_host_agent, :start_on_application)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:backplane_host_agent, :start_on_application)
      else
        Application.put_env(:backplane_host_agent, :start_on_application, previous)
      end
    end)
  end

  test "does not supervise the worker when application autostart is disabled" do
    Application.put_env(:backplane_host_agent, :start_on_application, false)

    assert HostAgentApplication.child_specs() == []
  end

  test "supervises the worker when application autostart is enabled" do
    Application.put_env(:backplane_host_agent, :start_on_application, true)

    assert HostAgentApplication.child_specs() == [Backplane.HostAgent.McpManager, Backplane.HostAgent.Worker]
  end
end
