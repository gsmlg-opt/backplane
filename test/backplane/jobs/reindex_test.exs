defmodule Backplane.Jobs.ReindexTest do
  use Backplane.DataCase, async: true

  alias Backplane.Jobs.Reindex

  describe "perform/1" do
    test "returns error for nonexistent project" do
      job = %Oban.Job{args: %{"project_id" => "nonexistent-project"}}
      assert {:error, :project_not_found} = Reindex.perform(job)
    end

    test "creates a valid Oban job changeset" do
      changeset = Reindex.new(%{"project_id" => "test-project"})
      assert changeset.valid?
    end

    test "job has correct queue" do
      changeset = Reindex.new(%{"project_id" => "test-project"})
      assert changeset.changes.queue == "indexing"
    end

    test "perform returns error when ingestion fails for invalid repo" do
      project =
        Repo.insert!(%Backplane.Docs.Project{
          id: "reindex-bad-#{System.unique_integer([:positive])}",
          repo: "file:///nonexistent/path",
          ref: "main"
        })

      job = %Oban.Job{args: %{"project_id" => project.id}}
      assert {:error, _reason} = Reindex.perform(job)
    end

    test "job changeset includes unique key for project_id" do
      changeset = Reindex.new(%{"project_id" => "unique-test"})
      assert changeset.changes.args == %{"project_id" => "unique-test"}
    end
  end
end
