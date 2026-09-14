defmodule Backplane.AgentRuntime.EventStream do
  alias Backplane.AgentRuntime.Event

  @moduledoc """
  Per-aggregate ordered event projection and bounded cursor replay.

  Duplicate or out-of-order aggregate sequences are rejected. Cursor expiry
  returns an explicit snapshot requirement instead of silently replaying
  retained events. Each stream is bound to its first event's aggregate so it
  does not imply a global ordering across aggregates.
  """

  @type t :: map()

  @spec new(non_neg_integer()) :: {:ok, t()} | {:error, Backplane.AgentRuntime.Error.t()}
  def new(retention) when is_integer(retention) and retention >= 0 do
    {:ok,
     %{
       retention: retention,
       events: [],
       cursor_floor: 0,
       aggregate_id: nil,
       last_sequence: nil
     }}
  end

  @spec append(t(), map()) :: {:ok, t()} | {:error, Backplane.AgentRuntime.Error.t()}
  def append(stream, input) when is_map(stream) and is_map(input) do
    with {:ok, event} <- Event.build(input),
         {:ok, sequence} <- next_sequence(stream, event) do
      event = %{event | sequence: sequence}
      events = retain(stream.events ++ [event], stream.retention)
      cursor_floor = replay_floor(events, sequence)

      {:ok,
       %{
         stream
         | events: events,
           cursor_floor: cursor_floor,
           aggregate_id: event.aggregate_id,
           last_sequence: sequence
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

  defp next_sequence(%{aggregate_id: nil, last_sequence: nil}, event), do: {:ok, event.sequence}

  defp next_sequence(%{aggregate_id: aggregate_id}, %{aggregate_id: received})
       when aggregate_id != received do
    {:error,
     Backplane.AgentRuntime.Error.new(:validation, "event aggregate does not match stream",
       details: %{received: received, expected: aggregate_id}
     )}
  end

  defp next_sequence(%{last_sequence: last_sequence}, event) do
    expected = last_sequence + 1

    if event.sequence == expected do
      {:ok, event.sequence}
    else
      {:error,
       Backplane.AgentRuntime.Error.new(:validation, "event sequence gap or duplicate aggregate",
         details: %{received: event.sequence, expected: expected}
       )}
    end
  end

  defp retain(_events, 0), do: []
  defp retain(events, retention), do: Enum.take(events, -retention)

  defp replay_floor([first | _events], _last_sequence), do: first.sequence
  defp replay_floor([], last_sequence), do: last_sequence + 1
end
