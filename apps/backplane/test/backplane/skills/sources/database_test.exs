defmodule Backplane.Skills.Sources.DatabaseTest do
  use Backplane.DataCase, async: true

  alias Backplane.Repo
  alias Backplane.Skills.Skill
  alias Backplane.Skills.Sources.Database

  describe "list/0" do
    test "returns all enabled skills with source db" do
      insert_skill("db/test1", "db", true)
      insert_skill("db/test2", "db", true)
      insert_skill("db/disabled", "db", false)
      insert_skill("git:foo/bar", "git:foo", true)

      {:ok, skills} = Database.list()
      ids = Enum.map(skills, & &1.id)

      assert "db/test1" in ids
      assert "db/test2" in ids
      refute "db/disabled" in ids
      refute "git:foo/bar" in ids
    end
  end

  describe "fetch/1" do
    test "returns skill by ID" do
      insert_skill("db/fetchme", "db", true)

      {:ok, skill} = Database.fetch("db/fetchme")
      assert skill.id == "db/fetchme"
    end

    test "returns error for nonexistent" do
      assert {:error, :not_found} = Database.fetch("nonexistent")
    end
  end

  describe "create/1" do
    test "inserts skill with generated ID" do
      {:ok, skill} =
        Database.create(%{name: "my-skill", description: "A skill", content: "# Content"})

      assert String.starts_with?(skill.id, "db/")
      assert skill.source == "db"
    end

    test "computes content_hash" do
      {:ok, skill} = Database.create(%{name: "hash-test", description: "Test", content: "# Body"})
      assert skill.content_hash != nil
      assert String.length(skill.content_hash) == 64
    end

    test "validates required fields (name, content)" do
      assert {:error, changeset} = Database.create(%{description: "No name or content"})
      assert changeset.valid? == false
    end
  end

  describe "update/2" do
    test "updates content and recomputes hash" do
      insert_skill("db/updatable", "db", true, content: "old content")
      old = Repo.get!(Skill, "db/updatable")

      {:ok, updated} = Database.update("db/updatable", %{content: "new content"})
      assert updated.content == "new content"
      assert updated.content_hash != old.content_hash
    end

    test "updates tags and description" do
      insert_skill("db/tagme", "db", true)

      {:ok, updated} =
        Database.update("db/tagme", %{tags: ["new", "tags"], description: "Updated desc"})

      assert updated.tags == ["new", "tags"]
      assert updated.description == "Updated desc"
    end

    test "rejects update of non-db-sourced skill" do
      insert_skill("git:test/skill", "git:test", true)

      assert {:error, :readonly_source} = Database.update("git:test/skill", %{content: "nope"})
    end
  end

  defp insert_skill(id, source, enabled, opts \\ []) do
    content = Keyword.get(opts, :content, "# Default content")
    hash = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

    %Skill{}
    |> Skill.changeset(%{
      id: id,
      name: "skill-#{id}",
      description: "Test skill",
      content: content,
      content_hash: hash,
      source: source,
      enabled: enabled
    })
    |> Repo.insert!()
  end
end
