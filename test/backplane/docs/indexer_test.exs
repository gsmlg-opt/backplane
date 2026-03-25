defmodule Backplane.Docs.IndexerTest do
  use Backplane.DataCase, async: true

  alias Backplane.Docs.{DocChunk, Indexer, Project}

  setup do
    project =
      Repo.insert!(%Project{
        id: "test-project",
        repo: "https://github.com/test/test.git",
        ref: "main"
      })

    {:ok, project: project}
  end

  describe "index/2" do
    test "inserts new chunks", %{project: project} do
      chunks = [
        %{
          source_path: "lib/foo.ex",
          module: "Foo",
          function: nil,
          chunk_type: "moduledoc",
          content: "Module documentation for Foo.",
          content_hash: Backplane.Docs.Chunker.compute_hash("Module documentation for Foo."),
          tokens: 7
        }
      ]

      {:ok, stats} = Indexer.index(project.id, chunks)
      assert stats.inserted == 1
      assert stats.deleted == 0

      assert Repo.aggregate(from(c in DocChunk, where: c.project_id == ^project.id), :count) ==
               1
    end

    test "skips unchanged chunks", %{project: project} do
      content = "Existing documentation content."
      hash = Backplane.Docs.Chunker.compute_hash(content)

      Repo.insert!(%DocChunk{
        project_id: project.id,
        source_path: "lib/foo.ex",
        chunk_type: "moduledoc",
        content: content,
        content_hash: hash,
        tokens: 7
      })

      chunks = [
        %{
          source_path: "lib/foo.ex",
          module: nil,
          function: nil,
          chunk_type: "moduledoc",
          content: content,
          content_hash: hash,
          tokens: 7
        }
      ]

      {:ok, stats} = Indexer.index(project.id, chunks)
      assert stats.inserted == 0
      assert stats.skipped == 1
    end

    test "deletes removed chunks", %{project: project} do
      Repo.insert!(%DocChunk{
        project_id: project.id,
        source_path: "lib/old.ex",
        chunk_type: "moduledoc",
        content: "Old content that should be removed.",
        content_hash: Backplane.Docs.Chunker.compute_hash("Old content that should be removed."),
        tokens: 6
      })

      # Index with empty set — old chunk should be deleted
      {:ok, stats} = Indexer.index(project.id, [])
      assert stats.deleted == 1
    end

    test "handles mixed insert/delete/skip", %{project: project} do
      existing_content = "This chunk already exists in the database."
      existing_hash = Backplane.Docs.Chunker.compute_hash(existing_content)

      Repo.insert!(%DocChunk{
        project_id: project.id,
        source_path: "lib/keep.ex",
        chunk_type: "moduledoc",
        content: existing_content,
        content_hash: existing_hash,
        tokens: 8
      })

      Repo.insert!(%DocChunk{
        project_id: project.id,
        source_path: "lib/remove.ex",
        chunk_type: "moduledoc",
        content: "This will be removed from the index.",
        content_hash: Backplane.Docs.Chunker.compute_hash("This will be removed from the index."),
        tokens: 7
      })

      chunks = [
        %{
          source_path: "lib/keep.ex",
          module: nil,
          function: nil,
          chunk_type: "moduledoc",
          content: existing_content,
          content_hash: existing_hash,
          tokens: 8
        },
        %{
          source_path: "lib/new.ex",
          module: nil,
          function: nil,
          chunk_type: "moduledoc",
          content: "Brand new documentation content here.",
          content_hash:
            Backplane.Docs.Chunker.compute_hash("Brand new documentation content here."),
          tokens: 6
        }
      ]

      {:ok, stats} = Indexer.index(project.id, chunks)
      assert stats.inserted == 1
      assert stats.deleted == 1
      assert stats.skipped == 1
    end
  end

  describe "update_reindex_state/2" do
    test "creates new state when none exists", %{project: project} do
      {:ok, state} =
        Indexer.update_reindex_state(project.id, %{
          status: "running",
          started_at: DateTime.utc_now()
        })

      assert state.project_id == project.id
      assert state.status == "running"
    end
  end
end
