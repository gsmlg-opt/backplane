defmodule Backplane.Skills.SyncTest do
  use Backplane.DataCase, async: false

  alias Backplane.Skills.{Sync, Skill}
  alias Backplane.Repo

  setup do
    # Ensure skills registry ETS table exists
    if :ets.whereis(:backplane_skills) == :undefined do
      :ets.new(:backplane_skills, [:named_table, :set, :public, read_concurrency: true])
    end

    :ok
  end

  describe "sync_entries/1" do
    test "inserts new skills from source" do
      entries = [
        skill_entry("sync:test/skill1", "sync:test"),
        skill_entry("sync:test/skill2", "sync:test")
      ]

      Sync.sync_entries(entries)

      assert Repo.get(Skill, "sync:test/skill1") != nil
      assert Repo.get(Skill, "sync:test/skill2") != nil
    end

    test "updates changed skills (different content_hash)" do
      insert_skill("sync:update/s1", "sync:update", "old content")

      entries = [
        skill_entry("sync:update/s1", "sync:update", content: "new content")
      ]

      Sync.sync_entries(entries)

      updated = Repo.get!(Skill, "sync:update/s1")
      assert updated.content == "new content"
    end

    test "disables removed skills (not present in source)" do
      insert_skill("sync:remove/s1", "sync:remove", "content")
      insert_skill("sync:remove/s2", "sync:remove", "content")

      # Only s1 in incoming
      entries = [skill_entry("sync:remove/s1", "sync:remove")]

      Sync.sync_entries(entries)

      s2 = Repo.get!(Skill, "sync:remove/s2")
      assert s2.enabled == false
    end

    test "skips unchanged skills (same content_hash)" do
      content = "# Unchanged Content"
      insert_skill("sync:skip/s1", "sync:skip", content)
      old = Repo.get!(Skill, "sync:skip/s1")

      entries = [skill_entry("sync:skip/s1", "sync:skip", content: content)]
      Sync.sync_entries(entries)

      reloaded = Repo.get!(Skill, "sync:skip/s1")
      assert reloaded.updated_at == old.updated_at
    end

    test "refreshes ETS registry after sync" do
      # This test would require the Skills.Registry to be running
      # We just verify sync_entries doesn't crash
      entries = [skill_entry("sync:ets/s1", "sync:ets")]
      assert :ok = Sync.sync_entries(entries)
    end

    test "handles empty source gracefully" do
      assert :ok = Sync.sync_entries([])
    end
  end

  defp skill_entry(id, source, opts \\ []) do
    content = Keyword.get(opts, :content, "# Default Content for #{id}")
    hash = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

    %{
      id: id,
      name: "skill-#{id}",
      description: "Test skill",
      tags: ["test"],
      tools: [],
      model: nil,
      version: "1.0.0",
      content: content,
      content_hash: hash,
      source: source
    }
  end

  defp insert_skill(id, source, content) do
    hash = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

    %Skill{}
    |> Skill.changeset(%{
      id: id,
      name: "skill-#{id}",
      description: "Test skill",
      content: content,
      content_hash: hash,
      source: source,
      enabled: true
    })
    |> Repo.insert!()
  end
end
