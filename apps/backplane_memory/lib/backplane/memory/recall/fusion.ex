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

      if length(candidates) == 1,
        do: {:cont, {:ok, [fuse_occurrences(occurrences) | acc]}},
        else: {:halt, {:error, {:conflicting_candidate, identity}}}
    end)
  end

  defp fuse_occurrences(occurrences) do
    # Fixed channel precedence makes the representative candidate deterministic.
    candidate =
      occurrences
      |> Enum.min_by(fn {_identity, _candidate, channel, rank, _score, _rrf} ->
        {Enum.find_index(@channels, &(&1 == channel)), rank}
      end)
      |> elem(1)

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
