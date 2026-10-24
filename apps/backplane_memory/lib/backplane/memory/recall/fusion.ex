defmodule Backplane.Memory.Recall.Fusion do
  @moduledoc "Deterministic weighted reciprocal-rank fusion for Recall V2 channels."

  @channels [:fts, :vector, :graph]
  @kind_order %{memory: 0, lesson: 1, crystal: 2, summary: 3, observation: 4}

  @doc """
  Fuses successful channel outcomes and renormalizes weights over available channels.

  The stable total order is: RRF descending, best channel rank ascending,
  candidate kind order, then candidate UUID ascending.
  """
  def fuse(outcomes, weights, k) when is_map(outcomes) and is_map(weights) and k > 0 do
    available =
      Enum.filter(@channels, fn channel ->
        get_in(outcomes, [channel, :status]) == :ok and numeric_weight(weights, channel) > 0.0
      end)

    total_weight = Enum.sum(Enum.map(available, &numeric_weight(weights, &1)))

    with {:ok, entries} <- channel_entries(outcomes, weights, available, total_weight, k),
         {:ok, fused} <- fuse_entries(entries) do
      {:ok,
       Enum.sort_by(fused, fn item ->
         {-item.scores.rrf, Enum.min(Map.values(item.ranks)), @kind_order[item.candidate.kind],
          item.candidate.id}
       end)}
    end
  end

  defp channel_entries(outcomes, weights, available, total_weight, k) do
    Enum.reduce_while(available, {:ok, []}, fn channel, {:ok, acc} ->
      weight = numeric_weight(weights, channel) / total_weight

      rows =
        outcomes[channel].candidates
        |> Enum.with_index(1)
        |> Enum.map(fn {{candidate, score}, rank} ->
          {{candidate.kind, candidate.id}, candidate, channel, rank, score, weight / (k + rank)}
        end)

      identities = Enum.map(rows, &elem(&1, 0))

      case duplicate(identities) do
        nil -> {:cont, {:ok, rows ++ acc}}
        identity -> {:halt, {:error, {:duplicate_channel_candidate, channel, identity}}}
      end
    end)
  end

  defp fuse_entries(entries) do
    entries
    |> Enum.group_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, []}, fn {identity, occurrences}, {:ok, acc} ->
      candidates = occurrences |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

      case newest_candidate(candidates) do
        {:ok, candidate} ->
          {:cont, {:ok, [fuse_occurrences(occurrences, candidate) | acc]}}

        :error ->
          {:halt, {:error, {:conflicting_candidate, identity}}}
      end
    end)
  end

  defp newest_candidate([first | rest]) do
    Enum.reduce_while(rest, {:ok, first}, fn candidate, {:ok, newest} ->
      case merge_revision(newest, candidate) do
        {:ok, merged} -> {:cont, {:ok, merged}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp merge_revision(
         %{current_context: %{revision: left_revision}} = left,
         %{current_context: %{revision: right_revision}} = right
       )
       when is_integer(left_revision) and is_integer(right_revision) do
    # Parallel channels can straddle an embedding/bookkeeping updated_at write.
    # Reconcile only the timestamp; every semantic and provenance field must match.
    if %{left | current_context: %{left.current_context | revision: right_revision}} === right,
      do: {:ok, if(left_revision >= right_revision, do: left, else: right)},
      else: :error
  end

  defp merge_revision(_left, _right), do: :error

  defp fuse_occurrences(occurrences, candidate) do
    ranks =
      Map.new(occurrences, fn {_id, _candidate, channel, rank, _score, _rrf} ->
        {channel, rank}
      end)

    channel_scores =
      Map.new(occurrences, fn {_id, _candidate, channel, _rank, score, _rrf} ->
        {channel, score}
      end)

    rrf = Enum.sum(Enum.map(occurrences, &elem(&1, 5)))

    %{candidate: candidate, ranks: ranks, scores: Map.put(channel_scores, :rrf, rrf)}
  end

  defp numeric_weight(weights, channel) do
    case Map.get(weights, channel, Map.get(weights, Atom.to_string(channel), 0.0)) do
      value when is_integer(value) and value >= 0 -> value / 1
      value when is_float(value) and value >= 0.0 -> value
      _invalid -> 0.0
    end
  end

  defp duplicate(values) do
    Enum.reduce_while(values, MapSet.new(), fn value, seen ->
      if MapSet.member?(seen, value), do: {:halt, value}, else: {:cont, MapSet.put(seen, value)}
    end)
    |> case do
      %MapSet{} -> nil
      value -> value
    end
  end
end
