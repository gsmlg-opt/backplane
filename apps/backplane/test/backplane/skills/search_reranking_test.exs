defmodule Backplane.Skills.SearchRerankingTest do
  use Backplane.DataCase, async: true

  alias Backplane.Skills.Search

  setup do
    for {name, desc, tags} <- [
          {"elixir-genserver", "Guide to GenServer patterns in Elixir", ["elixir", "otp"]},
          {"elixir-supervisor", "Supervision tree design for Elixir apps", ["elixir", "otp"]},
          {"phoenix-liveview", "LiveView components and hooks", ["elixir", "phoenix"]}
        ] do
      Backplane.Fixtures.insert_skill(
        name: name,
        description: desc,
        tags: tags,
        content: "# #{name}\n\n#{desc}\n\nDetailed content about #{name}."
      )
    end

    :ok
  end

  describe "query with reranking" do
    test "falls back to tsvector-only when embeddings not configured" do
      refute Backplane.Embeddings.configured?()

      results = Search.query("Elixir GenServer")
      assert length(results) > 0

      for result <- results do
        assert Map.has_key?(result, :name)
        assert Map.has_key?(result, :description)
        refute Map.has_key?(result, :embedding)
      end
    end

    test "respects explicit rerank: false parameter" do
      results = Search.query("Elixir", rerank: false)
      assert length(results) > 0

      for result <- results do
        assert Map.has_key?(result, :id)
        assert Map.has_key?(result, :name)
      end
    end

    test "returns consistent results with and without rerank flag" do
      results_default = Search.query("Elixir")
      results_no_rerank = Search.query("Elixir", rerank: false)

      # With embeddings not configured, both paths produce the same set of results
      assert length(results_default) == length(results_no_rerank)

      default_ids = Enum.map(results_default, & &1.id) |> MapSet.new()
      no_rerank_ids = Enum.map(results_no_rerank, & &1.id) |> MapSet.new()
      assert default_ids == no_rerank_ids
    end
  end
end
