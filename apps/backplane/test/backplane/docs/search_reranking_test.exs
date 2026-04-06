defmodule Backplane.Docs.SearchRerankingTest do
  use Backplane.DataCase, async: true

  alias Backplane.Docs.Search

  setup do
    project =
      Backplane.Fixtures.insert_project(
        id: "rerank-test-#{System.unique_integer([:positive])}",
        repo: "https://github.com/test/rerank"
      )

    for {content, type} <- [
          {"Elixir GenServer documentation callback handling", "moduledoc"},
          {"Pattern matching guide for Elixir beginners", "guide"}
        ] do
      Backplane.Fixtures.insert_doc_chunk(
        project_id: project.id,
        content: content,
        chunk_type: type,
        source_path: "lib/test.ex"
      )
    end

    %{project: project}
  end

  describe "query with reranking" do
    test "falls back to tsvector-only when embeddings not configured", %{project: project} do
      refute Backplane.Embeddings.configured?()

      results = Search.query(project.id, "Elixir")
      assert length(results) > 0

      # Results should be ordered by tsvector rank with chunk_type weights applied
      for result <- results do
        assert Map.has_key?(result, :rank)
        assert Map.has_key?(result, :content)
      end
    end

    test "falls back to tsvector-only when rerank: false", %{project: project} do
      results = Search.query(project.id, "Elixir", rerank: false)
      assert length(results) > 0

      for result <- results do
        assert Map.has_key?(result, :rank)
      end
    end

    test "respects explicit rerank: false parameter", %{project: project} do
      results_default = Search.query(project.id, "Elixir")
      results_no_rerank = Search.query(project.id, "Elixir", rerank: false)

      # Both should return the same results since embeddings are not configured anyway
      assert length(results_default) == length(results_no_rerank)

      default_ids = Enum.map(results_default, & &1.id) |> MapSet.new()
      no_rerank_ids = Enum.map(results_no_rerank, & &1.id) |> MapSet.new()
      assert default_ids == no_rerank_ids
    end

    test "returns results without embedding field in output", %{project: project} do
      results = Search.query(project.id, "Elixir")
      assert length(results) > 0

      for result <- results do
        refute Map.has_key?(result, :embedding),
               "Result should not contain :embedding key but got: #{inspect(Map.keys(result))}"
      end
    end
  end
end
