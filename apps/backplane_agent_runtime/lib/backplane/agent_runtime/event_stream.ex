defmodule Backplane.AgentRuntime.EventStream do
  alias Backplane.AgentRuntime.Event

  @moduledoc """
  Ordered event projection and bounded cursor replay.

  Duplicate event IDs and out-of-order aggregate sequences are rejected. Cursor
  expiry returns an explicit snapshot requirement instead of silently replaying
  retained events.
  """

  @type t :: map()

  @spec new(non_neg_integer()) :: {:ok, t()} | {:error, Backplane.AgentRuntime.Error.t()}
  def new(retention) when is_integer(retention) and retention >= 0 do
    {:ok, %{retention: retention, events: [], cursor_floor: 0}}
  end

  @spec append(t(), map()) :: {:ok, t()} | {:error, Backplane.AgentRuntime.Error.t()}
  def append(stream, input) when is_map(stream) and is_map(input) do
    with {:ok, event} <- Event.build(input),
         {:ok, sequence} <- next_sequence(stream, event) do
      event = %{event | sequence: sequence}
      cursor_floor = max(stream.cursor_floor, sequence - stream.retention + 1)

      {:ok,
       %{
         stream
         | events: stream.events ++ [event],
           cursor_floor: cursor_floor
       }}
    end
  end

  @spec replay(t(), non_neg_integer()) ::
          {:ok, list(), keyword()} | {:error, Backplane.AgentRuntime.Error.t()}
  def replay(stream, cursor) when is_integer(cursor) and cursor >= 0 do
    if cursor < stream.cursor_floor do
      {:error, Backplane.AgentRuntime.Error.new(:not_found, "cursor expired")}
    else
      {:ok, Enum.reject(stream.events, &(&1.sequence < cursor)), floor: stream.cursor_floor}
    end
  end

  defp next_sequence(%{events: []}, event), do: {:ok, event.sequence}

  defp next_sequence(%{events: events}, event) do
    last = List.last(events)

    if event.sequence == last.sequence + 1 do
      {:ok, event.sequence}
    else
      {:error,
       Backplane.AgentRuntime.Error.new(:validation, "event sequence gap or duplicate aggregate",
         details: %{received: event.sequence, expected: last.sequence + 1}
       )}
    end
  end
end
