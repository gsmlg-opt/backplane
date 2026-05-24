defmodule Backplane.Skills.SkillTest do
  use Backplane.DataCase, async: true

  alias Backplane.Skills, as: SkillsContext
  alias Backplane.Skills.Skill
  alias Backplane.Skills.Registry
  alias Backplane.Fixtures

  @archive_ref "sha256/#{String.duplicate("a", 64)}.tar.gz"

  @valid_attrs %{
    id: "test/skill-1",
    slug: "test-skill",
    name: "test-skill",
    content: "# Test Skill\nDo the thing.",
    content_hash: "abc123"
  }

  describe "changeset/2" do
    test "valid with all required fields" do
      changeset = Skill.changeset(%Skill{}, @valid_attrs)
      assert changeset.valid?
    end

    test "invalid without required fields" do
      changeset = Skill.changeset(%Skill{}, %{})
      refute changeset.valid?

      for field <- ~w(id slug name content)a do
        assert {_, [validation: :required]} = changeset.errors[field]
      end
    end

    test "accepts archive metadata and source fields" do
      attrs =
        Map.merge(@valid_attrs, %{
          description: "A test skill",
          tags: ["elixir", "testing"],
          version: "2.0.0",
          license: "MIT",
          homepage: "https://example.com/test-skill",
          author: "Backplane Team",
          meta: %{"entrypoint" => "SKILL.md"},
          archive_ref: @archive_ref,
          size_bytes: 4096,
          file_count: 12,
          source_kind: "git",
          source_uri: "https://github.com/example/skills.git",
          source_rev: "abc123",
          enabled: false
        })

      changeset = Skill.changeset(%Skill{}, attrs)
      assert changeset.valid?
      assert get_change(changeset, :tags) == ["elixir", "testing"]
      assert get_change(changeset, :version) == "2.0.0"
      assert get_change(changeset, :license) == "MIT"
      assert get_change(changeset, :homepage) == "https://example.com/test-skill"
      assert get_change(changeset, :author) == "Backplane Team"
      assert get_change(changeset, :meta) == %{"entrypoint" => "SKILL.md"}
      assert get_change(changeset, :archive_ref) == @archive_ref
      assert get_change(changeset, :size_bytes) == 4096
      assert get_change(changeset, :file_count) == 12
      assert get_change(changeset, :source_kind) == "git"
      assert get_change(changeset, :source_uri) == "https://github.com/example/skills.git"
      assert get_change(changeset, :source_rev) == "abc123"
      assert get_change(changeset, :enabled) == false
    end

    test "rejects malformed archive_ref values" do
      changeset = Skill.changeset(%Skill{}, Map.put(@valid_attrs, :archive_ref, "sha256:abc123"))

      refute changeset.valid?
      assert {_, [validation: :format]} = changeset.errors[:archive_ref]
    end

    test "uses default values for optional fields" do
      {:ok, skill} = Repo.insert(Skill.changeset(%Skill{}, @valid_attrs))
      assert skill.description == ""
      assert skill.tags == []
      assert skill.meta == %{}
      assert skill.enabled == true
    end
  end

  describe "update_changeset/2" do
    test "updates content fields" do
      changeset = Skill.update_changeset(%Skill{}, %{content: "new", content_hash: "def456"})
      assert changeset.valid?
      assert get_change(changeset, :content) == "new"
      assert get_change(changeset, :content_hash) == "def456"
    end

    test "does not allow updating identity or source fields" do
      changeset =
        Skill.update_changeset(%Skill{}, %{
          id: "new-id",
          slug: "new-slug",
          name: "new-name",
          source_kind: "git"
        })

      refute Map.has_key?(changeset.changes, :id)
      refute Map.has_key?(changeset.changes, :slug)
      refute Map.has_key?(changeset.changes, :name)
      refute Map.has_key?(changeset.changes, :source_kind)
    end
  end

  describe "public context" do
    test "lists, searches, gets, gets by slug, and deletes skills" do
      skill =
        %Skill{}
        |> Skill.changeset(%{
          id: "test/context-skill",
          slug: "context-skill",
          name: "Context Skill",
          description: "Findable context skill",
          tags: ["context"],
          content: "# Context Skill",
          content_hash: "hash"
        })
        |> Repo.insert!()

      assert Enum.any?(SkillsContext.list(), &(&1.id == skill.id))
      assert Enum.any?(SkillsContext.search("Findable"), &(&1.id == skill.id))
      assert {:ok, ^skill} = SkillsContext.get(skill.id)
      assert {:ok, ^skill} = SkillsContext.get_by_slug("context-skill")
      assert {:ok, %Skill{id: "test/context-skill"}} = SkillsContext.delete(skill.id)
      assert {:error, :not_found} = SkillsContext.get(skill.id)
    end

    test "delete refreshes the skills registry" do
      skill =
        %Skill{}
        |> Skill.changeset(%{
          id: "test/registry-delete",
          slug: "registry-delete",
          name: "Registry Delete Skill",
          description: "Delete refresh test",
          tags: ["context"],
          content: "# Registry Delete Skill",
          content_hash: "hash"
        })
        |> Repo.insert!()

      Registry.refresh()
      assert {:ok, %{id: "test/registry-delete"}} = Registry.fetch(skill.id)

      assert {:ok, %Skill{id: "test/registry-delete"}} = SkillsContext.delete(skill.id)
      assert {:error, :not_found} = Registry.fetch(skill.id)
    end

    test "returns explicit errors for unavailable archive operations" do
      assert {:error, :enoent} = SkillsContext.ingest_archive("archive bytes", %{})
      assert {:error, :not_found} = SkillsContext.archive_stream("test/context-skill")
      assert {:error, :not_implemented} = SkillsContext.export("test/context-skill")
      assert {:error, :not_implemented} = SkillsContext.import("archive bytes", %{})
    end
  end

  describe "fixtures" do
    test "insert_skill generates slug and accepts archive metadata overrides" do
      skill =
        Fixtures.insert_skill(
          id: "fixture/archive-skill",
          name: "Fixture Archive Skill",
          version: "1.0.0",
          license: "MIT",
          homepage: "https://example.com/fixture",
          author: "Backplane Team",
          meta: %{"entrypoint" => "SKILL.md"},
          archive_ref: @archive_ref,
          size_bytes: 1024,
          file_count: 4,
          source_kind: "git",
          source_uri: "https://github.com/example/skills.git",
          source_rev: "abc123"
        )

      assert String.starts_with?(skill.slug, "fixture-archive-skill-")
      assert skill.version == "1.0.0"
      assert skill.license == "MIT"
      assert skill.homepage == "https://example.com/fixture"
      assert skill.author == "Backplane Team"
      assert skill.meta == %{"entrypoint" => "SKILL.md"}
      assert skill.archive_ref == @archive_ref
      assert skill.size_bytes == 1024
      assert skill.file_count == 4
      assert skill.source_kind == "git"
      assert skill.source_uri == "https://github.com/example/skills.git"
      assert skill.source_rev == "abc123"
    end

    test "build_skill default slugs avoid duplicate name collisions" do
      first = Fixtures.build_skill(id: "fixture/one", name: "Duplicate Name")
      second = Fixtures.build_skill(id: "fixture/two", name: "Duplicate Name")

      assert first.slug != second.slug
      assert String.starts_with?(first.slug, "duplicate-name-")
      assert String.starts_with?(second.slug, "duplicate-name-")
    end
  end
end
