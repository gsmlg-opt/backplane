defmodule Backplane.HostAgent.Memory.Edge.Telemetry do
  @moduledoc "Content-free telemetry for edge storage and synchronization."
  @prefix [:backplane, :host_agent, :memory, :edge]
  @events Enum.map([:state, :delivery, :failure, :eviction], &(@prefix ++ [&1]))

  def events, do: @events

  def state(values) do
    keys = [:items, :bytes, :revision, :lag, :stale_age_seconds, :retry_count, :dead_letter_count]

    measurements =
      keys
      |> Enum.flat_map(fn key ->
        case Map.get(values, key) do
          value when is_number(value) -> [{key, value}]
          _ -> []
        end
      end)
      |> Map.new()

    execute(:state, measurements, %{
      protection_mode: Map.get(values, :protection_mode, :unknown),
      lag_status: if(is_number(Map.get(values, :lag)), do: :known, else: :unavailable)
    })
  end

  def delivery(kind, result) when kind in [:delta, :snapshot] and result in [:ok, :gap],
    do: execute(:delivery, %{count: 1}, %{kind: kind, result: result})

  def failure(class) when class in [:gap, :integrity, :protection, :storage, :transport],
    do: execute(:failure, %{count: 1}, %{class: class})

  def eviction(result),
    do:
      execute(
        :eviction,
        %{count: numeric(result[:evicted]), expired_count: numeric(result[:expired])},
        %{}
      )

  defp execute(event, measurements, metadata) do
    :telemetry.execute(@prefix ++ [event], measurements, metadata)
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp numeric(value) when is_number(value), do: value
  defp numeric(_), do: 0
end
