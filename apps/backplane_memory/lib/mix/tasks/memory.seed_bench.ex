defmodule Mix.Tasks.Memory.SeedBench do
  @shortdoc "Seed the benchmark fixture corpus into the memory store"

  @moduledoc """
  Loads the bench_corpus.json fixture into the memory store.
  Used to populate the database before running `mix memory.eval`.

  ## Examples

      mix memory.seed_bench

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

    Mix.shell().info("Seeding #{length(memories)} memories...")

    results =
      Enum.map(memories, fn mem ->
        BackplaneMemory.Memory.remember(mem["content"],
          type: mem["type"] || "semantic",
          scope: mem["scope"] || "global",
          agent_id: mem["agent_id"] || "bench-agent",
          host_id: mem["host_id"] || "bench",
          tags: mem["tags"] || []
        )
      end)

    ok_count = Enum.count(results, &match?({:ok, _}, &1))
    err_count = length(results) - ok_count

    Mix.shell().info("Seeded #{ok_count} memories (#{err_count} duplicates/errors skipped).")
  end
end
