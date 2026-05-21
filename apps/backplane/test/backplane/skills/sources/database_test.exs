defmodule Backplane.Skills.Sources.DatabaseTest do
  use Backplane.DataCase, async: true

  alias Backplane.Repo
  alias Backplane.Skills.Skill
  alias Backplane.Skills.Sources.Database

  describe "list/0" do
    test "returns all enabled skills" do
      insert_skill("db/test1", true)
      insert_skill("db/test2", true)
      insert_skill("db/disabled", false)

      {:ok, skills} = Database.list()
      ids = Enum.map(skills, & &1.id)

      assert "db/test1" in ids
      assert "db/test2" in ids
      refute "db/disabled" in ids
    end

    test "returns archive metadata when present" do
      insert_skill("db/archived", true,
        slug: "archived-skill",
        version: "1.2.3",
        license: "MIT",
        homepage: "https://example.com/archived",
        author: "Backplane Team",
        meta: %{"entrypoint" => "SKILL.md"},
        archive_ref: "sha256:abc123",
        size_bytes: 2048,
        file_count: 7,
        source_kind: "git",
        source_uri: "https://github.com/example/skills.git",
        source_rev: "abc123"
      )

      {:ok, skills} = Database.list()
      skill = Enum.find(skills, &(&1.id == "db/archived"))

      assert skill.slug == "archived-skill"
      assert skill.version == "1.2.3"
      assert skill.license == "MIT"
      assert skill.homepage == "https://example.com/archived"
      assert skill.author == "Backplane Team"
      assert skill.meta == %{"entrypoint" => "SKILL.md"}
      assert skill.archive_ref == "sha256:abc123"
      assert skill.size_bytes == 2048
      assert skill.file_count == 7
      assert skill.source_kind == "git"
      assert skill.source_uri == "https://github.com/example/skills.git"
      assert skill.source_rev == "abc123"
    end
  end

  describe "fetch/1" do
    test "returns skill by ID" do
      insert_skill("db/fetchme", true, slug: "fetchme")

      {:ok, skill} = Database.fetch("db/fetchme")
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
      assert skill.slug =~ ~r/^my-skill-[a-f0-9]{8}$/
      assert skill.source_kind == "database"
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

    test "accepts archive metadata" do
      {:ok, skill} =
        Database.create(%{
          name: "archive-create",
          content: "# Body",
          version: "0.1.0",
          meta: %{"entrypoint" => "SKILL.md"},
          archive_ref: "sha256:def456",
          size_bytes: 512,
          file_count: 3,
          source_kind: "upload",
          source_uri: "file:///tmp/skill.tar.gz",
          source_rev: "def456"
        })

      assert skill.version == "0.1.0"
      assert skill.meta == %{"entrypoint" => "SKILL.md"}
      assert skill.archive_ref == "sha256:def456"
      assert skill.size_bytes == 512
      assert skill.file_count == 3
      assert skill.source_kind == "upload"
      assert skill.source_uri == "file:///tmp/skill.tar.gz"
      assert skill.source_rev == "def456"
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
  end

  defp insert_skill(id, enabled, opts \\ []) do
    content = Keyword.get(opts, :content, "# Default content")
    hash = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

    attrs = %{
      id: id,
      slug: Keyword.get(opts, :slug, slug_from_id(id)),
      name: "skill-#{id}",
      description: "Test skill",
      content: content,
      content_hash: hash,
      enabled: enabled
    }

    archive_attrs =
      opts
      |> Keyword.take([
        :version,
        :license,
        :homepage,
        :author,
        :meta,
        :archive_ref,
        :size_bytes,
        :file_count,
        :source_kind,
        :source_uri,
        :source_rev
      ])
      |> Map.new()

    %Skill{}
    |> Skill.changeset(Map.merge(attrs, archive_attrs))
    |> Repo.insert!()
  end

  defp slug_from_id(id) do
    id
    |> String.replace(~r/[^a-zA-Z0-9]+/, "-")
    |> String.trim("-")
    |> String.downcase()
  end
end
