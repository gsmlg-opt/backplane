defmodule Mix.Tasks.Memory.Eval do
  @shortdoc "Run recall quality evaluation against the benchmark fixture corpus"

  @moduledoc """
  Evaluates recall quality against priv/memory_fixtures/bench_corpus.json.
  Prints Precision@5, Recall@5, and MRR to the terminal.

  Requires the corpus to be seeded first:

      mix memory.seed_bench
      mix memory.eval

  """

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    fixture_path =
      Path.join([__DIR__, "../../../priv/memory_fixtures/bench_corpus.json"])
      |> Path.expand()

    corpus = fixture_path |> File.read!() |> Jason.decode!()
    memories = corpus["memories"]
    queries = corpus["queries"]

    Mix.shell().info("\n=== Memory Recall Evaluation ===\n")

    # Look up the actual DB memory IDs by content substring
    db_memories = lookup_memories(memories)

    results =
      Enum.map(queries, fn q ->
        query_text = q["query"]
        relevant_indices = q["relevant_ids"]
        topic = q["topic"]

        # Get the actual DB UUIDs for relevant memories
        relevant_db_ids =
          relevant_indices
          |> Enum.flat_map(fn idx ->
            case Enum.at(db_memories, idx) do
              nil -> []
              %{id: id} -> [id]
            end
          end)
          |> MapSet.new()

        # Run recall
        recalled_rows =
          case BackplaneMemory.Memories.Search.recall(query_text, limit: 5) do
            {:ok, rows} -> rows
            {:error, _} -> []
          end

        recalled_ids = Enum.map(recalled_rows, & &1.id) |> Enum.take(5)

        # Compute metrics
        hits = Enum.filter(recalled_ids, &MapSet.member?(relevant_db_ids, &1))
        precision_at_5 = length(hits) / 5

        recall_at_5 =
          if MapSet.size(relevant_db_ids) > 0 do
            length(hits) / MapSet.size(relevant_db_ids)
          else
            0.0
          end

        # MRR: reciprocal rank of the first relevant result (1-indexed)
        first_hit =
          recalled_ids
          |> Enum.with_index(1)
          |> Enum.find(fn {id, _rank} -> MapSet.member?(relevant_db_ids, id) end)

        rr = if first_hit, do: 1.0 / elem(first_hit, 1), else: 0.0

        %{
          topic: topic,
          query: query_text,
          precision_at_5: precision_at_5,
          recall_at_5: recall_at_5,
          rr: rr
        }
      end)

    # Print per-query results
    Mix.shell().info("Results per query:")

    Mix.shell().info(
      String.pad_trailing("Topic", 14) <>
        String.pad_trailing("P@5", 8) <>
        String.pad_trailing("R@5", 8) <>
        "MRR"
    )

    Mix.shell().info(String.duplicate("-", 44))

    Enum.each(results, fn r ->
      Mix.shell().info(
        String.pad_trailing(r.topic, 14) <>
          String.pad_trailing(format_pct(r.precision_at_5), 8) <>
          String.pad_trailing(format_pct(r.recall_at_5), 8) <>
          format_pct(r.rr)
      )
    end)

    # Aggregate
    n = length(results)
    mean_p = Enum.sum(Enum.map(results, & &1.precision_at_5)) / n
    mean_r = Enum.sum(Enum.map(results, & &1.recall_at_5)) / n
    mrr = Enum.sum(Enum.map(results, & &1.rr)) / n

    Mix.shell().info(String.duplicate("-", 44))

    Mix.shell().info(
      String.pad_trailing("MEAN", 14) <>
        String.pad_trailing(format_pct(mean_p), 8) <>
        String.pad_trailing(format_pct(mean_r), 8) <>
        format_pct(mrr)
    )

    Mix.shell().info("\nMean Precision@5: #{format_pct(mean_p)}")
    Mix.shell().info("Mean Recall@5:    #{format_pct(mean_r)}")
    Mix.shell().info("MRR:              #{format_pct(mrr)}")
  end

  # Fetch DB records by content substring to resolve corpus indices to actual UUIDs.
  # Uses the first 60 characters of each memory's content as the lookup key.
  defp lookup_memories(memories) do
    Enum.map(memories, fn mem ->
      snippet = String.slice(mem["content"], 0, 60)

      case BackplaneMemory.Memory.list(q: snippet, limit: 1) do
        [%{id: id} = m] -> %{id: id, content: m.content}
        _ -> nil
      end
    end)
  end

  defp format_pct(f) when is_float(f) do
    :io_lib.format("~.1f%", [f * 100]) |> IO.iodata_to_binary()
  end

  defp format_pct(_), do: "N/A"
end
