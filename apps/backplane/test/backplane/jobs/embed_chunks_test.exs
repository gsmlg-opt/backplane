defmodule Backplane.Jobs.EmbedChunksTest do
  use Backplane.DataCase, async: true

  alias Backplane.Jobs.EmbedChunks

  describe "perform/1" do
    test "skips when embeddings not configured" do
      # Default test env has no [embeddings] config, so configured?() is false
      refute Backplane.Embeddings.configured?()

      job = %Oban.Job{args: %{"project_id" => "test-project"}}
      assert :ok = EmbedChunks.perform(job)
    end

    test "skips when embeddings not configured and no project_id" do
      refute Backplane.Embeddings.configured?()

      job = %Oban.Job{args: %{}}
      assert :ok = EmbedChunks.perform(job)
    end

    test "returns :ok regardless of args when not configured" do
      refute Backplane.Embeddings.configured?()

      job = %Oban.Job{
        args: %{"project_id" => "nonexistent-id-#{System.unique_integer([:positive])}"}
      }

      assert :ok = EmbedChunks.perform(job)
    end
  end

  describe "new/1" do
    test "creates a valid Oban job changeset" do
      changeset = EmbedChunks.new(%{"project_id" => "test-embed"})
      assert changeset.valid?
    end

    test "job is assigned to the embeddings queue" do
      changeset = EmbedChunks.new(%{"project_id" => "test-embed"})
      assert changeset.changes.queue == "embeddings"
    end
  end
end
