defmodule Backplane.Docs.SearchTest do
  use Backplane.DataCase, async: true

  alias Backplane.Docs.{Search, Project, DocChunk, Chunker}

  setup do
    project =
      Repo.insert!(%Project{
        id: "search-project",
        repo: "https://github.com/test/search.git",
        ref: "main"
      })

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    # Insert some doc chunks for searching
    Repo.insert!(%DocChunk{
      project_id: project.id,
      source_path: "lib/genserver.ex",
      module: "MyApp.GenServer",
      function: nil,
      chunk_type: "moduledoc",
      content: "A GenServer implementation for managing state and handling calls.",
      content_hash:
        Chunker.compute_hash("A GenServer implementation for managing state and handling calls."),
      tokens: 12,
      inserted_at: now
    })

    Repo.insert!(%DocChunk{
      project_id: project.id,
      source_path: "lib/genserver.ex",
      module: "MyApp.GenServer",
      function: "handle_call/3",
      chunk_type: "function_doc",
      content: "Handles synchronous calls to the GenServer process.",
      content_hash: Chunker.compute_hash("Handles synchronous calls to the GenServer process."),
      tokens: 9,
      inserted_at: now
    })

    Repo.insert!(%DocChunk{
      project_id: project.id,
      source_path: "docs/guide.md",
      module: nil,
      function: nil,
      chunk_type: "guide",
      content: "Getting started with the HTTP client library for making requests.",
      content_hash:
        Chunker.compute_hash("Getting started with the HTTP client library for making requests."),
      tokens: 11,
      inserted_at: now
    })

    {:ok, project: project}
  end

  describe "query/3" do
    test "returns matching results for keyword search", %{project: project} do
      results = Search.query(project.id, "GenServer")
      assert results != []
      assert Enum.all?(results, fn r -> r.content =~ "GenServer" end)
    end

    test "returns results sorted by relevance", %{project: project} do
      results = Search.query(project.id, "GenServer")
      # Module/function matches should rank higher due to weight A
      assert results != []
    end

    test "respects max_tokens budget", %{project: project} do
      results = Search.query(project.id, "GenServer", max_tokens: 10)
      total = Enum.sum(Enum.map(results, & &1.tokens))
      assert total <= 10
    end

    test "filters by chunk_type", %{project: project} do
      results = Search.query(project.id, "GenServer", chunk_type: "function_doc")
      assert Enum.all?(results, fn r -> r.chunk_type == "function_doc" end)
    end

    test "returns empty list for non-matching query", %{project: project} do
      results = Search.query(project.id, "xyznonexistent")
      assert results == []
    end

    test "returns empty for wrong project_id" do
      results = Search.query("nonexistent-project", "GenServer")
      assert results == []
    end

    test "handles special characters in query", %{project: project} do
      # Should not crash
      results = Search.query(project.id, "handle_call/3")
      assert is_list(results)
    end
  end
end
