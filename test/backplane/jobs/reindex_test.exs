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
  end
end
