defmodule Backplane.Memory.Eval do
  @moduledoc "Pure evaluation metrics, fixture validation, thresholds, and report serialization."

  @default_fixture Path.expand("../../../priv/memory_fixtures/coding_corpus_v2.json", __DIR__)
  @partition_keys ~w(host_id client_id scope namespace)

  def load_fixture(path \\ @default_fixture) do
    with {:ok, bytes} <- File.read(path),
         {:ok, fixture} <- Jason.decode(bytes),
         :ok <- validate_fixture(fixture) do
      {:ok, fixture}
    end
  end

  def validate_fixture(%{
        "schema_version" => 2,
        "fixture_id" => id,
        "memories" => memories,
        "queries" => queries
      })
      when is_binary(id) and id != "" and is_list(memories) and is_list(queries) do
    memory_ids = Enum.map(memories, & &1["fixture_memory_id"])
    query_ids = Enum.map(queries, & &1["query_id"])

    valid_memories =
      length(memories) >= 20 and Enum.any?(memories, & &1["distractor"]) and
        Enum.any?(memories, & &1["derived"]) and
        Enum.all?(memories, fn memory ->
          Enum.all?(["fixture_memory_id", "content" | @partition_keys], &nonempty?(memory[&1]))
        end)

    valid_queries =
      length(queries) >= 20 and
        Enum.all?(queries, fn query ->
          nonempty?(query["query_id"]) and nonempty?(query["query"]) and
            is_list(query["relevant_ids"]) and query["relevant_ids"] != [] and
            Enum.all?(query["relevant_ids"], &(&1 in memory_ids))
        end)

    if valid_memories and valid_queries and memory_ids == Enum.uniq(memory_ids) and
         query_ids == Enum.uniq(query_ids),
       do: :ok,
       else: {:error, :invalid_fixture}
  end

  def validate_fixture(_fixture), do: {:error, :invalid_fixture}

  def quality_metrics(cases, k \\ 5)

  def quality_metrics(cases, k) when is_list(cases) and cases != [] and k > 0 do
    rows = Enum.map(cases, &case_metrics(&1, k))
    count = length(rows)

    %{
      queries: count,
      recall_any_at_5: mean(rows, :recall_any),
      recall_all_at_5: mean(rows, :recall_all),
      ndcg_at_5: mean(rows, :ndcg),
      mrr: mean(rows, :rr)
    }
  end

  def quality_metrics(_, _),
    do: %{queries: 0, recall_any_at_5: 0.0, recall_all_at_5: 0.0, ndcg_at_5: 0.0, mrr: 0.0}

  def percentile(samples, percentile) when is_list(samples) and samples != [] do
    sorted = Enum.sort(samples)
    index = max(ceil(percentile / 100 * length(sorted)) - 1, 0)
    Enum.at(sorted, index)
  end

  def thresholds_pass?(report, opts \\ []) do
    quality_min = Keyword.get(opts, :recall_any_at_5, 0.95)
    retrieval_max = Keyword.get(opts, :retrieval_fusion_p95_ms, 300)
    e2e_max = Keyword.get(opts, :e2e_p95_ms, 800)

    get_in(report, [:quality, :recall_any_at_5]) >= quality_min and
      get_in(report, [:outage, :availability]) == 1.0 and
      get_in(report, [:outage, :samples]) > 0 and
      get_in(report, [:provenance, :coverage]) == 1.0 and
      get_in(report, [:provenance, :denominator]) > 0 and
      latency_gate?(get_in(report, [:latency, :retrieval_fusion]), retrieval_max) and
      latency_gate?(get_in(report, [:latency, :e2e]), e2e_max)
  rescue
    _ -> false
  end

  def ensure_thresholds!(report) do
    runner_verdicts_pass? =
      Map.get(report, :passed, true) and
        Enum.all?(Map.get(report, :thresholds, %{}), fn {_gate, passed} -> passed == true end)

    if thresholds_pass?(report) and runner_verdicts_pass?,
      do: :ok,
      else: raise("M15 evaluation thresholds failed")
  end

  def longmemeval_export(fixture, returned_by_query) do
    memories = Map.new(fixture["memories"], &{&1["fixture_memory_id"], &1})

    jsonl =
      fixture["queries"]
      |> Enum.map(fn query ->
        returned = returned_by_query |> Map.get(query["query_id"], []) |> Enum.uniq()
        ordered_memories = Enum.sort_by(memories, &elem(&1, 0))

        Jason.encode!(%{
          "question_id" => query["query_id"],
          "question_type" => "single-session-user",
          "question" => query["query"],
          "answer" => nil,
          "question_date" => nil,
          "haystack_session_ids" => Enum.map(ordered_memories, &elem(&1, 0)),
          "haystack_dates" => Enum.map(ordered_memories, fn _ -> nil end),
          "haystack_sessions" =>
            Enum.map(ordered_memories, fn {id, memory} ->
              [
                %{
                  "role" => "user",
                  "content" => memory["content"],
                  "has_answer" => id in query["relevant_ids"]
                }
              ]
            end),
          "answer_session_ids" => query["relevant_ids"],
          "retrieval_results" => %{
            "query" => query["query"],
            "ranked_items" =>
              Enum.map(returned, fn id ->
                %{"corpus_id" => id, "text" => memories[id]["content"], "timestamp" => nil}
              end),
            "metrics" => %{
              "session" => retrieval_metrics(query["relevant_ids"], returned),
              "turn" => %{}
            }
          }
        })
      end)
      |> Enum.join("\n")
      |> Kernel.<>("\n")

    sidecar = %{
      "schema_version" => 1,
      "fixture_id" => fixture["fixture_id"],
      "format" => "LongMemEval-compatible JSONL",
      "evaluation_mode" => "retrieval-only",
      "directly_comparable" => false,
      "comparability_note" =>
        "Backplane coding-corpus retrieval output; not directly comparable to published LongMemEval results."
    }

    {jsonl, sidecar}
  end

  def encode_report(report), do: Jason.encode!(stringify(report), pretty: true) <> "\n"

  defp retrieval_metrics(relevant, returned) do
    Map.new([1, 3, 5, 10, 30, 50], fn k ->
      metrics = quality_metrics([%{relevant: relevant, returned: returned}], k)

      {k,
       %{
         "recall_any@#{k}" => metrics.recall_any_at_5,
         "recall_all@#{k}" => metrics.recall_all_at_5,
         "ndcg_any@#{k}" => metrics.ndcg_at_5
       }}
    end)
    |> Map.values()
    |> Enum.reduce(%{}, &Map.merge/2)
  end

  defp case_metrics(%{relevant: relevant, returned: returned}, k) do
    relevant = MapSet.new(relevant)
    returned = returned |> Enum.uniq() |> Enum.take(k)
    hits = Enum.count(returned, &MapSet.member?(relevant, &1))
    first = Enum.find_index(returned, &MapSet.member?(relevant, &1))

    ideal =
      Enum.take(1..MapSet.size(relevant), k)
      |> Enum.reduce(0.0, fn rank, acc -> acc + discount(rank) end)

    dcg =
      returned
      |> Enum.with_index(1)
      |> Enum.reduce(0.0, fn {id, rank}, acc ->
        if MapSet.member?(relevant, id), do: acc + discount(rank), else: acc
      end)

    %{
      recall_any: if(hits > 0, do: 1.0, else: 0.0),
      recall_all: if(hits == MapSet.size(relevant), do: 1.0, else: 0.0),
      ndcg: if(ideal > 0, do: dcg / ideal, else: 0.0),
      rr: if(first, do: 1.0 / (first + 1), else: 0.0)
    }
  end

  defp discount(rank), do: 1.0 / :math.log2(rank + 1)
  defp mean(rows, key), do: Enum.sum(Enum.map(rows, &Map.fetch!(&1, key))) / length(rows)
  defp nonempty?(value), do: is_binary(value) and String.trim(value) != ""
  defp latency_gate?(%{p95_ms: p95, samples: samples}, max), do: samples >= 100 and p95 < max
  defp latency_gate?(_, _), do: false

  defp stringify(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), stringify(item)} end)

  defp stringify(value) when is_list(value), do: Enum.map(value, &stringify/1)
  defp stringify(value), do: value
end
