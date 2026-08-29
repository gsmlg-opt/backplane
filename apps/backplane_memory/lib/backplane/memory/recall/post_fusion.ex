defmodule Backplane.Memory.Recall.PostFusion do
  @moduledoc "Deterministic bounded lifecycle scoring and diversity for fused recall items."

  alias Backplane.Memory.Config
  alias Backplane.Memory.Recall.Candidate

  @kind_order %{memory: 0, lesson: 1, crystal: 2, summary: 3, observation: 4}
  @options [:now, :max_per_session, :limit]
  @half_life_days 365.0

  def apply(items, opts \\ [])

  def apply(items, opts) when is_list(items) do
    with :ok <- validate_options(opts) do
      now = Keyword.get(opts, :now, DateTime.utc_now())
      max_per_session = Keyword.get(opts, :max_per_session, Config.recall_max_per_session())
      limit = Keyword.get(opts, :limit)

      with {:ok, traces} <- score_all(items, now) do
        {eligible, rejected} = Enum.split_with(traces, &is_nil(&1.rejection_reason))
        {selected, diversity_rejected} = select(stable_sort(eligible), max_per_session, limit)
        {:ok, selected ++ stable_sort(rejected ++ diversity_rejected)}
      end
    end
  end

  def apply(_items, _opts), do: {:error, :invalid_items}

  def validate_options(opts) do
    with true <- Keyword.keyword?(opts),
         keys = Keyword.keys(opts),
         true <- keys == Enum.uniq(keys) and keys -- @options == [],
         now = Keyword.get(opts, :now, DateTime.utc_now()),
         true <- match?(%DateTime{}, now),
         max_per_session = Keyword.get(opts, :max_per_session, Config.recall_max_per_session()),
         true <- is_integer(max_per_session) and max_per_session in 1..100,
         limit = Keyword.get(opts, :limit),
         true <- is_nil(limit) or (is_integer(limit) and limit in 1..500) do
      :ok
    else
      _invalid -> {:error, :invalid_options}
    end
  end

  defp score_all(items, now) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case score(item, now) do
        {:ok, trace} -> {:cont, {:ok, [trace | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, traces} -> {:ok, Enum.reverse(traces)}
      error -> error
    end
  end

  defp score(%{candidate: %Candidate{} = candidate, ranks: ranks, scores: scores}, now)
       when is_map(ranks) and is_map(scores) do
    rrf = scores[:rrf]

    if is_number(rrf) and rrf >= 0 and map_size(ranks) > 0 and
         Enum.all?(ranks, fn {_channel, rank} -> is_integer(rank) and rank > 0 end) do
      rejection = lifecycle_rejection(candidate, now)
      multiplier = if rejection, do: 0.0, else: multiplier(candidate, now)

      {:ok,
       %{
         candidate: candidate,
         selected: is_nil(rejection),
         rejection_reason: rejection,
         ranks: ranks,
         scores:
           scores
           |> Map.put(:lifecycle, multiplier)
           |> Map.put(:final, rrf * multiplier),
         token_estimate: candidate.token_estimate
       }}
    else
      {:error, :invalid_fused_item}
    end
  end

  defp score(_item, _now), do: {:error, :invalid_fused_item}

  defp multiplier(candidate, now) do
    state =
      case candidate.lifecycle_state do
        :disputed -> 0.6
        :candidate -> 0.9
        _active -> 1.0
      end

    confidence = 0.75 + 0.25 * candidate.confidence
    strength = 0.75 + 0.25 * candidate.strength
    evidence = 1.0 + min(candidate.evidence_count, 10) * 0.02
    utility = 1.0 + min(candidate.application_count, 20) * 0.01

    (state * confidence * strength * evidence * utility * recency(candidate.inserted_at, now))
    |> max(0.25)
    |> min(2.0)
  end

  defp recency(nil, _now), do: 0.9

  defp recency(inserted_at, now) do
    age_days = max(DateTime.diff(now, inserted_at, :second), 0) / 86_400
    0.9 + 0.1 * :math.pow(0.5, age_days / @half_life_days)
  end

  defp lifecycle_rejection(%Candidate{lifecycle_state: :superseded}, _now), do: "superseded"
  defp lifecycle_rejection(%Candidate{lifecycle_state: :archived}, _now), do: "archived"
  defp lifecycle_rejection(%Candidate{lifecycle_state: :tombstoned}, _now), do: "lifecycle"

  defp lifecycle_rejection(%Candidate{expires_at: expires_at}, now) when not is_nil(expires_at) do
    if DateTime.compare(expires_at, now) == :gt, do: nil, else: "lifecycle"
  end

  defp lifecycle_rejection(_candidate, _now), do: nil

  defp select(traces, _max_per_session, nil), do: {traces, []}

  defp select(traces, max_per_session, limit) do
    {preferred, deferred} = apply_session_cap(traces, max_per_session)
    {selected, preferred_overflow} = preferred |> diversify_comparable() |> Enum.split(limit)
    remaining = limit - length(selected)
    {fill, rejected} = Enum.split(deferred ++ preferred_overflow, remaining)
    rejected = Enum.map(rejected, &%{&1 | selected: false, rejection_reason: "diversity"})
    {selected ++ fill, rejected}
  end

  defp apply_session_cap(traces, max_per_session) do
    {selected, rejected, _counts} =
      Enum.reduce(traces, {[], [], %{}}, fn trace, {selected, rejected, counts} ->
        session = trace.candidate.session_id
        count = if is_nil(session), do: 0, else: Map.get(counts, session, 0)

        if is_nil(session) or count < max_per_session do
          counts = if is_nil(session), do: counts, else: Map.put(counts, session, count + 1)
          {[trace | selected], rejected, counts}
        else
          {selected, [trace | rejected], counts}
        end
      end)

    {Enum.reverse(selected), Enum.reverse(rejected)}
  end

  defp diversify_comparable([]), do: []

  defp diversify_comparable([first | rest]) do
    threshold = first.scores.final * 0.9
    {comparable, tail} = Enum.split_with(rest, &(&1.scores.final >= threshold))
    [first | diversify_kinds(comparable, MapSet.new([first.candidate.kind]))] ++ tail
  end

  defp diversify_kinds([], _seen), do: []

  defp diversify_kinds(traces, seen) do
    index = Enum.find_index(traces, &(not MapSet.member?(seen, &1.candidate.kind))) || 0
    {picked, remaining} = List.pop_at(traces, index)
    [picked | diversify_kinds(remaining, MapSet.put(seen, picked.candidate.kind))]
  end

  defp stable_sort(traces) do
    Enum.sort_by(traces, fn trace ->
      best_rank = trace.ranks |> Map.values() |> Enum.min(fn -> 1_000_000 end)
      {-trace.scores.final, best_rank, @kind_order[trace.candidate.kind], trace.candidate.id}
    end)
  end
end
