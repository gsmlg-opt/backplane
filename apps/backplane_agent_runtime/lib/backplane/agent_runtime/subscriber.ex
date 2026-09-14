defmodule Backplane.AgentRuntime.Subscriber do
  alias Backplane.AgentRuntime.EventStream

  @moduledoc """
  Bounded event subscriptions with cursor retention and gap markers.

  Slow subscribers cannot block execution. When a cursor expires, replay
  explicitly requests a snapshot instead of silently losing events.
  """

  @type t :: map()

  @spec new(non_neg_integer()) :: {:ok, t()} | {:error, Backplane.AgentRuntime.Error.t()}
  def new(retention) when is_integer(retention) and retention >= 0 do
    EventStream.new(retention)
  end

  @spec append(t(), map()) :: {:ok, t()} | {:error, Backplane.AgentRuntime.Error.t()}
  def append(subscriber, event) when is_map(subscriber) and is_map(event) do
    EventStream.append(subscriber, event)
  end

  @spec replay(t(), non_neg_integer()) ::
          {:ok, list(), keyword()} | {:error, Backplane.AgentRuntime.Error.t()}
  def replay(subscriber, cursor) when is_integer(cursor) and cursor >= 0 do
    EventStream.replay(subscriber, cursor)
  end

  @spec gap(t(), non_neg_integer()) :: {:ok, %{gap: boolean(), from: non_neg_integer()}}
  def gap(subscriber, cursor) when is_integer(cursor) and cursor >= 0 do
    floor = subscriber.cursor_floor
    from = if cursor < floor, do: floor, else: cursor

    {:ok, %{gap: cursor < floor, from: from}}
  end
end
