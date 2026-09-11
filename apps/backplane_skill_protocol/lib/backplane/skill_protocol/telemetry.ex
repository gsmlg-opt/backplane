defmodule Backplane.SkillProtocol.Telemetry do
  @moduledoc "Bounded operational telemetry for Skill Protocol reads and cache operations."

  alias Backplane.SkillProtocol.Error

  @event [:backplane, :skill_protocol, :operation]
  @metadata_keys [
    :phase,
    :operation,
    :outcome,
    :error_code,
    :source_id,
    :skill_id,
    :revision,
    :artifact_digest,
    :cache_outcome,
    :http_status
  ]
  @measurement_keys [
    :duration_ms,
    :request_bytes,
    :response_bytes,
    :artifact_bytes,
    :prepared_bytes
  ]
  @max_string_bytes 256
  @max_measurement 9_007_199_254_740_991

  @doc "Returns a monotonic timestamp suitable for `emit/5`."
  @spec start() :: integer()
  def start, do: System.monotonic_time(:microsecond)

  @doc "Emits the stable Skill Protocol operation event and returns `result` unchanged."
  @spec emit(atom(), atom(), term(), integer(), keyword()) :: term()
  def emit(phase, operation, result, started_at, opts \\ []) do
    metadata =
      opts
      |> Keyword.get(:metadata, %{})
      |> Map.new()
      |> Map.merge(%{
        phase: phase,
        operation: operation,
        outcome: outcome(result),
        error_code: error_code(result)
      })
      |> sanitize_metadata()

    measurements =
      opts
      |> Keyword.get(:measurements, %{})
      |> Map.new()
      |> Map.put(:duration_ms, elapsed_ms(started_at))
      |> sanitize_measurements()

    :telemetry.execute(@event, measurements, metadata)
    result
  end

  defp outcome({:error, _reason}), do: :error
  defp outcome(_result), do: :ok

  defp error_code({:error, %Error{code: code}}), do: code
  defp error_code({:error, code}) when is_atom(code), do: code
  defp error_code({:error, code}) when is_binary(code), do: code
  defp error_code(_result), do: nil

  defp elapsed_ms(started_at) do
    System.monotonic_time(:microsecond)
    |> Kernel.-(started_at)
    |> max(0)
    |> div(1_000)
  end

  defp sanitize_metadata(metadata) do
    metadata
    |> Map.take(@metadata_keys)
    |> Map.new(fn {key, value} -> {key, sanitize_metadata_value(value)} end)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp sanitize_metadata_value(value) when is_binary(value),
    do: binary_part(value, 0, min(byte_size(value), @max_string_bytes))

  defp sanitize_metadata_value(value) when is_atom(value) or is_integer(value), do: value
  defp sanitize_metadata_value(_value), do: nil

  defp sanitize_measurements(measurements) do
    measurements
    |> Map.take(@measurement_keys)
    |> Map.new(fn {key, value} -> {key, bounded_measurement(value)} end)
  end

  defp bounded_measurement(value) when is_integer(value),
    do: value |> max(0) |> min(@max_measurement)

  defp bounded_measurement(_value), do: 0
end
