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

    test "returns :ok when ingestion succeeds for a valid local repo" do
      # Create a temporary git repo with an indexable .md file
      base_dir =
        Path.join(
          System.tmp_dir!(),
          "backplane_reindex_ok_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(base_dir)

      System.cmd("git", ["init"], cd: base_dir)
      System.cmd("git", ["checkout", "-b", "main"], cd: base_dir)

      File.write!(Path.join(base_dir, "guide.md"), """
      # Getting Started

      This is a guide for testing the reindex success path.
      """)

      System.cmd("git", ["add", "."], cd: base_dir)
      System.cmd("git", ["commit", "-m", "init"], cd: base_dir)

      project_id = "reindex-ok-#{System.unique_integer([:positive])}"

      # Clean up any stale clone dir from previous test runs
      clone_dir = Path.join("/tmp/backplane_repos", project_id)
      File.rm_rf!(clone_dir)

      Repo.insert!(%Backplane.Docs.Project{
        id: project_id,
        repo: base_dir,
        ref: "main"
      })

      job = %Oban.Job{args: %{"project_id" => project_id}}
      assert :ok = Reindex.perform(job)

      File.rm_rf!(base_dir)
      File.rm_rf!(clone_dir)
    end
  end
end
