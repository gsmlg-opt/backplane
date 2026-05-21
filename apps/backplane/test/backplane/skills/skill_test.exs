defmodule Backplane.Skills.SkillTest do
  use Backplane.DataCase, async: true

  alias Backplane.Skills, as: SkillsContext
  alias Backplane.Skills.Skill

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
          archive_ref: "sha256:abc123",
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
      assert get_change(changeset, :archive_ref) == "sha256:abc123"
      assert get_change(changeset, :size_bytes) == 4096
      assert get_change(changeset, :file_count) == 12
      assert get_change(changeset, :source_kind) == "git"
      assert get_change(changeset, :source_uri) == "https://github.com/example/skills.git"
      assert get_change(changeset, :source_rev) == "abc123"
      assert get_change(changeset, :enabled) == false
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

    test "returns explicit not implemented errors for archive operations" do
      assert {:error, :not_implemented} = SkillsContext.ingest_archive("archive bytes", %{})
      assert {:error, :not_implemented} = SkillsContext.archive_stream("test/context-skill")
      assert {:error, :not_implemented} = SkillsContext.export("test/context-skill")
      assert {:error, :not_implemented} = SkillsContext.import("archive bytes", %{})
    end
  end
end
