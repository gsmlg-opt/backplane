defmodule Backplane.Jobs.EmbedSkillsTest do
  use Backplane.DataCase, async: true

  alias Backplane.Jobs.EmbedSkills

  describe "perform/1" do
    test "skips when embeddings not configured" do
      refute Backplane.Embeddings.configured?()

      job = %Oban.Job{args: %{}}
      assert :ok = EmbedSkills.perform(job)
    end

    test "returns :ok when not configured even with skills in database" do
      refute Backplane.Embeddings.configured?()

      Backplane.Fixtures.insert_skill(
        name: "embed-test-skill",
        description: "A skill for testing embed_skills worker",
        content: "# Embed Test\n\nThis skill exists to verify embed_skills skips gracefully."
      )

      job = %Oban.Job{args: %{}}
      assert :ok = EmbedSkills.perform(job)
    end
  end

  describe "new/1" do
    test "creates a valid Oban job changeset on the embeddings queue" do
      changeset = EmbedSkills.new(%{})
      assert changeset.valid?
      assert changeset.changes.queue == "embeddings"
    end
  end
end
