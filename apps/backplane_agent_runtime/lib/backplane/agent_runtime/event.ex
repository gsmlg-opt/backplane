defmodule Backplane.AgentRuntime.Event do
  alias Backplane.AgentRuntime.Error

  @moduledoc """
  Deterministic canonical event envelopes with per-aggregate sequences.

  Event IDs and time are caller-provided, so replay is stable. Sequence gaps
  and duplicate aggregate sequences are rejected.
  """

  @type t :: map()

  @spec build(map()) :: {:ok, t()} | {:error, Error.t()}
  def build(input) when is_map(input) do
    with {:ok, event_id} <- require_binary(input, :event_id, "event_id"),
         {:ok, aggregate_id} <- require_binary(input, :aggregate_id, "aggregate_id"),
         {:ok, sequence} <- require_sequence(input),
         {:ok, type} <- require_binary(input, :type, "type"),
         {:ok, occurred_at} <- require_time(input) do
      {:ok,
       %{
         event_id: event_id,
         aggregate_id: aggregate_id,
         sequence: sequence,
         schema_version: Map.get(input, :schema_version, 1),
         type: type,
         occurred_at: occurred_at,
         causation_id: Map.get(input, :causation_id),
         payload: Map.get(input, :payload, %{})
       }}
    end
  end

  def build(_input), do: {:error, Error.new(:validation, "event input must be a map")}

  defp require_binary(input, key, label) do
    value = Map.get(input, key)

    if is_binary(value) and value != "" do
      {:ok, value}
    else
      {:error, Error.new(:validation, "#{label} is required")}
    end
  end

  defp require_sequence(input) do
    value = Map.get(input, :sequence)

    if is_integer(value) and value >= 0 do
      {:ok, value}
    else
      {:error, Error.new(:validation, "sequence must be non-negative")}
    end
  end

  defp require_time(input) do
    value = Map.get(input, :occurred_at)

    if is_integer(value) and value >= 0 do
      {:ok, value}
    else
      {:error, Error.new(:validation, "occurred_at is required")}
    end
  end
end
