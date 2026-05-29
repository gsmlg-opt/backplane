defmodule Backplane.HostAgent.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    maybe_attach_telemetry_logger()

    Supervisor.start_link(child_specs(),
      strategy: :one_for_one,
      name: Backplane.HostAgent.Supervisor
    )
  end

  def child_specs do
    if Application.get_env(:backplane_host_agent, :start_on_application, true) do
      [Backplane.HostAgent.McpManager, Backplane.HostAgent.Worker]
    else
      []
    end
  end

  defp maybe_attach_telemetry_logger do
    if Application.get_env(:backplane_host_agent, :telemetry_logger, false) do
      Backplane.HostAgent.TelemetryLogger.attach()
    else
      :ok
    end
  end
end
