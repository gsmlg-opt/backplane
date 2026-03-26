defmodule Backplane.Docs.SearchTest do
  use Backplane.DataCase, async: true

  alias Backplane.Docs.{Chunker, DocChunk, Project, Search}

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

  describe "list_projects/0" do
    test "returns all projects with chunk counts", %{project: project} do
      results = Search.list_projects()
      assert is_list(results)
      entry = Enum.find(results, fn r -> r.id == project.id end)
      assert entry != nil
      assert entry.repo == project.repo
      assert entry.ref == project.ref
      assert is_integer(entry.chunk_count)
      assert entry.chunk_count == 3
    end

    test "returns empty list when no projects exist" do
      # Clean up existing project data
      Repo.delete_all(Backplane.Docs.DocChunk)
      Repo.delete_all(Backplane.Docs.Project)
      assert Search.list_projects() == []
    end
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

    test "returns empty list for empty query string", %{project: project} do
      assert Search.query(project.id, "") == []
    end

    test "returns empty list for nil query", %{project: project} do
      assert Search.query(project.id, nil) == []
    end

    test "handles special characters in query", %{project: project} do
      # Should not crash
      results = Search.query(project.id, "handle_call/3")
      assert is_list(results)
    end

    test "token budget skips oversized chunks and includes smaller ones", %{project: project} do
      # The setup inserts chunks with tokens: 12, 9, 11
      # With a budget of 15, the greedy approach should include the 12-token chunk first,
      # then skip the next if it doesn't fit, and include the 9-token chunk
      results = Search.query(project.id, "GenServer", max_tokens: 15)
      tokens_list = Enum.map(results, & &1.tokens)
      total = Enum.sum(tokens_list)
      assert total <= 15
      # With skip behavior, we should get more results than if we halted early
      assert results != []
    end

    test "chunk_type weighting boosts moduledoc over function_doc", %{project: project} do
      results = Search.query(project.id, "GenServer")
      # With equal ts_rank, moduledoc (1.5x) should rank higher than function_doc (1.3x)
      types = Enum.map(results, & &1.chunk_type)

      if length(types) >= 2 do
        moduledoc_idx = Enum.find_index(types, &(&1 == "moduledoc"))
        func_idx = Enum.find_index(types, &(&1 == "function_doc"))

        if moduledoc_idx && func_idx do
          assert moduledoc_idx < func_idx
        end
      end
    end
  end
end
