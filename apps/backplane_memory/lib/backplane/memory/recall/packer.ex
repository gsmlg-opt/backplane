defmodule Backplane.Memory.Recall.Packer do
  @moduledoc "Deterministic token-budget packing by marginal score per token."

  alias Backplane.Memory.Config
  alias Backplane.Memory.Recall.Candidate

  @rejection_reasons ~w(diversity token_budget lifecycle duplicate below_threshold superseded disputed archived channel_error review)
  @options [:max_per_session]

  def pack(traces, budget, opts \\ [])

  def pack(traces, budget, opts)
      when is_list(traces) and is_integer(budget) and budget in 1..100_000 do
    with :ok <- validate_options(opts),
         max_per_session = Keyword.get(opts, :max_per_session, Config.recall_max_per_session()),
         :ok <- validate_traces(traces) do
      do_pack(traces, budget, max_per_session)
    else
      {:error, _reason} = error -> error
    end
  end

  def pack(_traces, _budget, _opts), do: {:error, :invalid_token_budget}

  def validate_options(opts) do
    with true <- Keyword.keyword?(opts),
         keys = Keyword.keys(opts),
         true <- keys == Enum.uniq(keys) and keys -- @options == [],
         max_per_session = Keyword.get(opts, :max_per_session, Config.recall_max_per_session()),
         true <- is_integer(max_per_session) and max_per_session in 1..100 do
      :ok
    else
      _invalid -> {:error, :invalid_options}
    end
  end

  defp do_pack(traces, budget, max_per_session) do
    eligible = Enum.filter(traces, &(&1.selected and is_nil(&1.rejection_reason)))
    ordered = Enum.sort_by(eligible, &sort_key/1)
    selection_order = reserve_comparable_kind(ordered, budget)

    {selected, deferred, used, _sessions} =
      Enum.reduce(selection_order, {[], [], 0, %{}}, fn trace,
                                                        {selected, deferred, used, sessions} = acc ->
        session = trace.candidate.session_id
        session_count = if is_nil(session), do: 0, else: Map.get(sessions, session, 0)

        cond do
          used + trace.token_estimate > budget ->
            acc

          not is_nil(session) and session_count >= max_per_session ->
            {selected, [trace | deferred], used, sessions}

          true ->
            sessions =
              if is_nil(session),
                do: sessions,
                else: Map.put(sessions, session, session_count + 1)

            {[trace | selected], deferred, used + trace.token_estimate, sessions}
        end
      end)

    {selected, used} =
      deferred
      |> Enum.reverse()
      |> Enum.reduce({selected, used}, fn trace, {selected, used} = acc ->
        if used + trace.token_estimate <= budget,
          do: {[trace | selected], used + trace.token_estimate},
          else: acc
      end)

    selected = Enum.reverse(selected)
    selected_ids = MapSet.new(selected, &identity/1)

    rejected =
      traces
      |> Enum.reject(&MapSet.member?(selected_ids, identity(&1)))
      |> Enum.map(fn trace ->
        if is_nil(trace.rejection_reason),
          do: %{trace | selected: false, rejection_reason: "token_budget"},
          else: trace
      end)
      |> Enum.sort_by(&identity/1)

    {:ok, selected ++ rejected, %{used_tokens: used, token_budget: budget}}
  end

  defp reserve_comparable_kind([], _budget), do: []

  defp reserve_comparable_kind(ordered, budget) do
    case Enum.find(ordered, &(&1.token_estimate <= budget)) do
      nil ->
        ordered

      first ->
        remaining_budget = budget - first.token_estimate

        alternate =
          Enum.find(ordered, fn trace ->
            identity(trace) != identity(first) and trace.candidate.kind != first.candidate.kind and
              trace.scores.final >= first.scores.final * 0.9 and
              trace.token_estimate <= remaining_budget
          end)

        prioritized = if alternate, do: [first, alternate], else: [first]
        prioritized_ids = MapSet.new(prioritized, &identity/1)
        prioritized ++ Enum.reject(ordered, &MapSet.member?(prioritized_ids, identity(&1)))
    end
  end

  defp sort_key(trace) do
    cost = max(trace.token_estimate, 1)
    {-trace.scores.final / cost, -trace.scores.final, trace.token_estimate, identity(trace)}
  end

  defp validate_traces(traces) do
    valid = Enum.all?(traces, &valid_trace?/1)
    identities = Enum.map(traces, &identity/1)
    if valid and identities == Enum.uniq(identities), do: :ok, else: {:error, :invalid_traces}
  end

  defp valid_trace?(%{
         candidate: %Candidate{} = candidate,
         selected: selected,
         rejection_reason: reason,
         scores: %{final: score},
         token_estimate: tokens
       }) do
    valid_selection?(selected, reason) and nonnegative_finite?(score) and
      is_integer(tokens) and tokens >= 0 and tokens == candidate.token_estimate
  end

  defp valid_trace?(_trace), do: false
  defp identity(%{candidate: candidate}), do: {candidate.kind, candidate.id}
  defp valid_selection?(true, nil), do: true
  defp valid_selection?(false, reason), do: reason in @rejection_reasons
  defp valid_selection?(_selected, _reason), do: false
  defp nonnegative_finite?(score), do: is_number(score) and score >= 0 and finite?(score)
  defp finite?(score) when is_integer(score), do: true
  defp finite?(score) when is_float(score), do: score == score and score <= 1.0e308
end
