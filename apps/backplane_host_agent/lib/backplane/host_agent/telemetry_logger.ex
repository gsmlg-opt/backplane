defmodule Backplane.HostAgent.TelemetryLogger do
  @moduledoc """
  Logger adapter for host-agent telemetry events.
  """

  require Logger

  @handler_id "backplane-host-agent-telemetry-logger"
  @events [
    [:backplane, :host_agent, :memory, :call, :start],
    [:backplane, :host_agent, :memory, :call, :stop],
    [:backplane, :host_agent, :memory, :call, :exception]
  ]

  @doc "Attach the host-agent telemetry logger."
  @spec attach() :: :ok
  def attach do
    detach()

    :telemetry.attach_many(
      @handler_id,
      @events,
      &__MODULE__.handle_event/4,
      nil
    )

    :ok
  end

  @doc "Detach the host-agent telemetry logger."
  @spec detach() :: :ok
  def detach do
    case :telemetry.detach(@handler_id) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end

  @doc false
  def handle_event(
        [:backplane, :host_agent, :memory, :call, :start],
        _measurements,
        metadata,
        _config
      ) do
    Logger.debug("Host agent memory call started #{format_metadata(metadata)}",
      agent_id: metadata[:agent_id],
      method: metadata[:method]
    )
  end

  def handle_event(
        [:backplane, :host_agent, :memory, :call, :stop],
        measurements,
        metadata,
        _config
      ) do
    Logger.debug(
      "Host agent memory call completed #{format_metadata(metadata)} duration_ms=#{duration_ms(measurements)}",
      agent_id: metadata[:agent_id],
      method: metadata[:method],
      result: metadata[:result]
    )
  end

  def handle_event(
        [:backplane, :host_agent, :memory, :call, :exception],
        measurements,
        metadata,
        _config
      ) do
    Logger.error(
      "Host agent memory call failed #{format_metadata(metadata)} duration_ms=#{duration_ms(measurements)} reason=#{inspect(metadata[:reason])}",
      agent_id: metadata[:agent_id],
      method: metadata[:method]
    )
  end

  defp format_metadata(metadata) do
    [
      "method=#{metadata[:method]}",
      "agent_id=#{metadata[:agent_id]}",
      "result=#{metadata[:result]}",
      "argument_keys=#{Enum.join(metadata[:argument_keys] || [], ",")}"
    ]
    |> Enum.reject(&String.ends_with?(&1, "="))
    |> Enum.join(" ")
  end

  defp duration_ms(measurements) do
    measurements
    |> Map.get(:duration, 0)
    |> System.convert_time_unit(:native, :millisecond)
  end
end
