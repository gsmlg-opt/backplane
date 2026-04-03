defmodule Backplane.Tools.DocsTest do
  use Backplane.DataCase, async: true

  alias Backplane.Docs.{Chunker, DocChunk, Project}
  alias Backplane.Tools.Docs

  setup do
    project =
      Repo.insert!(%Project{
        id: "tools-test-project",
        repo: "https://github.com/test/tools.git",
        ref: "main",
        description: "A test project for tools"
      })

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.insert!(%DocChunk{
      project_id: project.id,
      source_path: "lib/example.ex",
      module: "Example",
      function: nil,
      chunk_type: "moduledoc",
      content: "Example module documentation for testing the tools endpoint.",
      content_hash:
        Chunker.compute_hash("Example module documentation for testing the tools endpoint."),
      tokens: 10,
      inserted_at: now
    })

    {:ok, project: project}
  end

  describe "tools/0" do
    test "returns tool definitions" do
      tools = Docs.tools()
      assert length(tools) == 2

      names = Enum.map(tools, & &1.name)
      assert "docs::resolve-project" in names
      assert "docs::query-docs" in names
    end

    test "tool definitions have required fields" do
      for tool <- Docs.tools() do
        assert is_binary(tool.name)
        assert is_binary(tool.description)
        assert is_map(tool.input_schema)
        assert tool.module == Backplane.Tools.Docs
        assert is_atom(tool.handler)
      end
    end
  end

  describe "call resolve_project" do
    test "finds project by ID", %{project: project} do
      {:ok, result} = Docs.call(%{"_handler" => "resolve_project", "query" => "tools-test"})
      assert result.count > 0

      ids = Enum.map(result.projects, & &1.id)
      assert project.id in ids
    end

    test "finds project by description" do
      {:ok, result} =
        Docs.call(%{"_handler" => "resolve_project", "query" => "test project for tools"})

      assert result.count > 0
      ids = Enum.map(result.projects, & &1.id)
      assert "tools-test-project" in ids
    end

    test "returns at most 5 results" do
      for i <- 1..7 do
        Repo.insert!(
          %Project{
            id: "resolve-limit-#{i}",
            repo: "https://github.com/test/resolve#{i}.git",
            ref: "main"
          },
          on_conflict: :nothing
        )
      end

      {:ok, result} = Docs.call(%{"_handler" => "resolve_project", "query" => "resolve"})
      assert result.count <= 5
    end

    test "returns empty for non-matching query" do
      {:ok, result} = Docs.call(%{"_handler" => "resolve_project", "query" => "xyznonexistent"})
      assert result.count == 0
    end

    test "exact ID match ranks first" do
      Repo.insert!(%Project{
        id: "phoenix",
        repo: "https://github.com/phoenixframework/phoenix.git",
        ref: "main",
        description: "Web framework"
      })

      Repo.insert!(%Project{
        id: "phoenix-live-view",
        repo: "https://github.com/phoenixframework/phoenix_live_view.git",
        ref: "main",
        description: "Phoenix LiveView"
      })

      {:ok, result} = Docs.call(%{"_handler" => "resolve_project", "query" => "phoenix"})
      assert result.count >= 2
      assert hd(result.projects).id == "phoenix"
    end
  end

  describe "call query_docs" do
    test "searches and returns results with score", %{project: project} do
      {:ok, result} =
        Docs.call(%{
          "_handler" => "query_docs",
          "project_id" => project.id,
          "query" => "Example module"
        })

      assert result.count > 0
      assert is_integer(result.total_tokens)

      [first | _] = result.results
      assert is_float(first.score)
      assert first.score > 0
      assert Map.has_key?(first, :source_path)
      assert Map.has_key?(first, :content)
    end

    test "returns empty for non-matching query", %{project: project} do
      {:ok, result} =
        Docs.call(%{
          "_handler" => "query_docs",
          "project_id" => project.id,
          "query" => "xyznonexistent"
        })

      assert result.count == 0
    end

    test "returns error for unknown handler" do
      {:error, _msg} = Docs.call(%{"_handler" => "unknown"})
    end

    test "accepts version matching project ref", %{project: project} do
      {:ok, result} =
        Docs.call(%{
          "_handler" => "query_docs",
          "project_id" => project.id,
          "query" => "Example",
          "version" => "main"
        })

      assert result.count > 0
    end

    test "returns error for mismatched version", %{project: project} do
      {:error, msg} =
        Docs.call(%{
          "_handler" => "query_docs",
          "project_id" => project.id,
          "query" => "Example",
          "version" => "v2.0"
        })

      assert msg =~ "Version 'v2.0' not indexed"
      assert msg =~ "ref 'main'"
    end

    test "ignores nil version parameter", %{project: project} do
      {:ok, result} =
        Docs.call(%{
          "_handler" => "query_docs",
          "project_id" => project.id,
          "query" => "Example",
          "version" => nil
        })

      assert result.count > 0
    end
  end
end
