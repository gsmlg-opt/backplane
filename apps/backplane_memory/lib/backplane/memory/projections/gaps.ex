defmodule Backplane.Memory.Projections.Gaps do
  @moduledoc "Finds missing positive source-sequence ranges without expanding sparse gaps."

  def find(events) when is_list(events) do
    sequences =
      events
      |> Enum.map(& &1.source_sequence)
      |> Enum.filter(&(is_integer(&1) and &1 > 0))
      |> MapSet.new()

    sequences
    |> Enum.sort()
    |> Enum.reduce({1, []}, fn sequence, {expected, gaps} ->
      if sequence > expected do
        {sequence + 1, [%{"from" => expected, "to" => sequence - 1} | gaps]}
      else
        {max(expected, sequence + 1), gaps}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end
end
