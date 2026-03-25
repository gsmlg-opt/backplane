defmodule Backplane.Docs.IngestionTest do
  use Backplane.DataCase, async: true

  alias Backplane.Docs.{DocChunk, Ingestion, Project}

  @test_dir "/tmp/backplane_test_repo_#{System.unique_integer([:positive])}"

  setup do
    # Create a temporary directory with test files
    File.rm_rf!(@test_dir)
    File.mkdir_p!(Path.join(@test_dir, "lib"))
    File.mkdir_p!(Path.join(@test_dir, "docs"))

    File.write!(Path.join(@test_dir, "lib/example.ex"), """
    defmodule Example do
      @moduledoc \"\"\"
      An example module for testing the ingestion pipeline.
      \"\"\"

      @doc "Returns hello"
      def hello, do: :world
    end
    """)

    File.write!(Path.join(@test_dir, "docs/guide.md"), """
    ## Getting Started

    This is the getting started guide for the project.

    ## Configuration

    Configure the application using environment variables.
    """)

    File.write!(Path.join(@test_dir, "README.md"), """
    # Test Project

    A test project for documentation indexing.
    """)

    project =
      Repo.insert!(%Project{
        id: "ingestion-test",
        repo: "file://#{@test_dir}",
        ref: "main"
      })

    on_exit(fn -> File.rm_rf!(@test_dir) end)

    {:ok, project: project, test_dir: @test_dir}
  end

  describe "process_files/2" do
    test "processes Elixir files", %{project: project, test_dir: dir} do
      {:ok, chunks} = Ingestion.process_files(dir, project.id)
      elixir_chunks = Enum.filter(chunks, &String.ends_with?(&1.source_path, ".ex"))
      assert elixir_chunks != []
    end

    test "processes Markdown files", %{test_dir: dir, project: project} do
      {:ok, chunks} = Ingestion.process_files(dir, project.id)
      md_chunks = Enum.filter(chunks, &String.ends_with?(&1.source_path, ".md"))
      assert md_chunks != []
    end

    test "adds content_hash to all chunks", %{test_dir: dir, project: project} do
      {:ok, chunks} = Ingestion.process_files(dir, project.id)
      assert Enum.all?(chunks, fn c -> is_binary(c.content_hash) end)
    end

    test "adds token estimate to all chunks", %{test_dir: dir, project: project} do
      {:ok, chunks} = Ingestion.process_files(dir, project.id)
      assert Enum.all?(chunks, fn c -> is_integer(c.tokens) and c.tokens > 0 end)
    end

    test "skips .git directories", %{test_dir: dir, project: project} do
      git_dir = Path.join(dir, ".git")
      File.mkdir_p!(git_dir)
      File.write!(Path.join(git_dir, "config.ex"), "defmodule Git do\nend")

      {:ok, chunks} = Ingestion.process_files(dir, project.id)
      assert Enum.all?(chunks, fn c -> not String.contains?(c.source_path, ".git") end)
    end

    test "handles empty directory" do
      empty_dir = "/tmp/backplane_empty_#{System.unique_integer([:positive])}"
      File.mkdir_p!(empty_dir)

      {:ok, chunks} = Ingestion.process_files(empty_dir, "empty")
      assert chunks == []

      File.rm_rf!(empty_dir)
    end
  end

  describe "run/1" do
    test "returns error for non-existent project" do
      assert {:error, :project_not_found} = Ingestion.run("nonexistent")
    end
  end

  describe "run_pipeline/1 with local files" do
    test "indexes chunks from local directory structure", %{project: project, test_dir: dir} do
      # We can't do a real git clone in tests, so test process_files + indexer directly
      {:ok, chunks} = Ingestion.process_files(dir, project.id)
      {:ok, stats} = Backplane.Docs.Indexer.index(project.id, chunks)

      assert stats.inserted > 0
      assert stats.total > 0

      db_chunks = Repo.all(from(c in DocChunk, where: c.project_id == ^project.id))
      assert length(db_chunks) == stats.inserted
    end

    test "reindexing is idempotent", %{project: project, test_dir: dir} do
      {:ok, chunks} = Ingestion.process_files(dir, project.id)
      {:ok, stats1} = Backplane.Docs.Indexer.index(project.id, chunks)
      assert stats1.inserted > 0

      # Second index with same content
      {:ok, stats2} = Backplane.Docs.Indexer.index(project.id, chunks)
      assert stats2.inserted == 0
      assert stats2.skipped == stats1.total
    end

    test "detects content changes on reindex", %{project: project, test_dir: dir} do
      {:ok, chunks} = Ingestion.process_files(dir, project.id)
      {:ok, _stats1} = Backplane.Docs.Indexer.index(project.id, chunks)

      # Modify a file
      File.write!(Path.join(dir, "lib/example.ex"), """
      defmodule Example do
        @moduledoc \"\"\"
        Updated module documentation with new content.
        \"\"\"
      end
      """)

      {:ok, chunks2} = Ingestion.process_files(dir, project.id)
      {:ok, stats2} = Backplane.Docs.Indexer.index(project.id, chunks2)

      # Should have some inserts and deletes due to changed content
      assert stats2.inserted > 0 or stats2.deleted > 0
    end
  end
end
