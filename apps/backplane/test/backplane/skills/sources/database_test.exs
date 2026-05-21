defmodule Backplane.Skills.Sources.DatabaseTest do
  use Backplane.DataCase, async: true

  alias Backplane.Repo
  alias Backplane.Skills.Skill
  alias Backplane.Skills.Sources.Database

  describe "list/0" do
    test "returns all enabled skills with metadata" do
      insert_skill("db/test1", true, slug: "test-one", version: "1.0.0")
      insert_skill("db/test2", true, slug: "test-two", archive_ref: "sha256/abc.tar.gz")
      insert_skill("db/disabled", false, slug: "disabled")

      {:ok, skills} = Database.list()

      assert [
               %{id: "db/test1", slug: "test-one", version: "1.0.0"},
               %{id: "db/test2", slug: "test-two", archive_ref: "sha256/abc.tar.gz"}
             ] = Enum.sort_by(skills, & &1.id)
    end
  end

  describe "fetch/1" do
    test "returns skill by ID" do
      insert_skill("db/fetchme", true, slug: "fetchme")

      {:ok, skill} = Database.fetch("db/fetchme")
      assert skill.id == "db/fetchme"
      assert skill.slug == "fetchme"
    end

    test "returns skill by slug" do
      insert_skill("db/fetchme", true, slug: "fetchme")

      {:ok, skill} = Database.fetch("fetchme")
      assert skill.id == "db/fetchme"
      assert skill.slug == "fetchme"
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
      assert skill.slug == "my-skill"
      assert skill.meta == %{}
    end

    test "computes content_hash" do
      {:ok, skill} = Database.create(%{name: "hash-test", description: "Test", content: "# Body"})
      assert skill.content_hash != nil
      assert String.length(skill.content_hash) == 64
    end

    test "accepts an explicit slug and archive metadata" do
      {:ok, skill} =
        Database.create(%{
          name: "Archive Skill",
          slug: "archive-skill",
          description: "Test",
          content: "# Body",
          archive_ref: "sha256/abc.tar.gz",
          size_bytes: 123,
          file_count: 2,
          meta: %{"schema" => "backplane.skill.meta/v1"}
        })

      assert skill.slug == "archive-skill"
      assert skill.archive_ref == "sha256/abc.tar.gz"
      assert skill.size_bytes == 123
      assert skill.file_count == 2
      assert skill.meta == %{"schema" => "backplane.skill.meta/v1"}
    end

    test "validates required fields (name, content)" do
      assert {:error, changeset} = Database.create(%{description: "No name or content"})
      assert changeset.valid? == false
    end
  end

  describe "update/2" do
    test "updates content and recomputes hash" do
      insert_skill("db/updatable", true, content: "old content")
      old = Repo.get!(Skill, "db/updatable")

      {:ok, updated} = Database.update("db/updatable", %{content: "new content"})
      assert updated.content == "new content"
      assert updated.content_hash != old.content_hash
    end

    test "updates tags and description" do
      insert_skill("db/tagme", true)

      {:ok, updated} =
        Database.update("db/tagme", %{tags: ["new", "tags"], description: "Updated desc"})

      assert updated.tags == ["new", "tags"]
      assert updated.description == "Updated desc"
    end

    test "updates archive metadata" do
      insert_skill("db/archive", true)

      {:ok, updated} =
        Database.update("db/archive", %{
          archive_ref: "sha256/def.tar.gz",
          size_bytes: 456,
          file_count: 5
        })

      assert updated.archive_ref == "sha256/def.tar.gz"
      assert updated.size_bytes == 456
      assert updated.file_count == 5
    end
  end

  defp insert_skill(id, enabled, opts \\ []) do
    content = Keyword.get(opts, :content, "# Default content")
    hash = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
    name = Keyword.get(opts, :name, "skill-#{id}")

    %Skill{}
    |> Skill.changeset(%{
      id: id,
      slug: Keyword.get(opts, :slug, String.replace(id, ~r/[^a-zA-Z0-9]+/, "-")),
      name: name,
      description: "Test skill",
      content: content,
      content_hash: hash,
      version: Keyword.get(opts, :version),
      archive_ref: Keyword.get(opts, :archive_ref),
      enabled: enabled
    })
    |> Repo.insert!()
  end
end
