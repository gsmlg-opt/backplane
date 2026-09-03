defmodule BackplaneTelemetry.Application do
  @moduledoc false

  use Application

  alias Backplane.Observability.{Flags, RuntimeConfig, Settings}

  @impl true
  def start(_type, _args) do
    children =
      [
        Settings
      ]
      |> maybe_runtime_sink()
      |> maybe_legacy_logger()
      |> Enum.reverse()

    Supervisor.start_link(children, strategy: :one_for_one, name: BackplaneTelemetry.Supervisor)
  end

  defp maybe_runtime_sink(children) do
    if Flags.runtime_sink?() do
      [{Backplane.Observability.RuntimeSink, RuntimeConfig.runtime_sink_opts()} | children]
    else
      children
    end
  end

  defp maybe_legacy_logger(children) do
    start_logger? =
      Application.get_env(:backplane_telemetry, :start_logger, true) and not Flags.runtime_sink?()

    if start_logger? do
      [BackplaneTelemetry.TelemetryLogger | children]
    else
      children
    end
  end
end
