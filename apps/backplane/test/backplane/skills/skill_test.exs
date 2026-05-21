defmodule Backplane.Skills.SkillTest do
  use Backplane.DataCase, async: true

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

    test "requires id, slug, name, and content" do
      changeset = Skill.changeset(%Skill{}, %{})
      refute changeset.valid?

      for field <- ~w(id slug name content)a do
        assert {_, [validation: :required]} = changeset.errors[field]
      end
    end

    test "accepts archive metadata fields" do
      attrs =
        Map.merge(@valid_attrs, %{
          description: "A test skill",
          tags: ["elixir", "testing"],
          version: "2.0.0",
          license: "MIT",
          homepage: "https://example.com/skill",
          author: "gsmlg",
          meta: %{"schema" => "backplane.skill.meta/v1"},
          archive_ref: "sha256/abc123.tar.gz",
          size_bytes: 1234,
          file_count: 3,
          source_kind: "git",
          source_uri: "https://github.com/org/repo",
          source_rev: "abc123",
          enabled: false
        })

      changeset = Skill.changeset(%Skill{}, attrs)
      assert changeset.valid?
      assert get_change(changeset, :tags) == ["elixir", "testing"]
      assert get_change(changeset, :archive_ref) == "sha256/abc123.tar.gz"
      assert get_change(changeset, :meta) == %{"schema" => "backplane.skill.meta/v1"}
      assert get_change(changeset, :enabled) == false
    end

    test "uses default values for optional fields" do
      {:ok, skill} = Repo.insert(Skill.changeset(%Skill{}, @valid_attrs))
      assert skill.description == ""
      assert skill.tags == []
      assert skill.meta == %{}
      assert skill.version == nil
      assert skill.enabled == true
    end

    test "derives slug from name when omitted" do
      attrs = Map.delete(@valid_attrs, :slug) |> Map.put(:name, "My Great Skill!")
      changeset = Skill.changeset(%Skill{}, attrs)
      assert changeset.valid?
      assert get_change(changeset, :slug) == "my-great-skill"
    end
  end

  describe "update_changeset/2" do
    test "updates content fields" do
      changeset = Skill.update_changeset(%Skill{}, %{content: "new", content_hash: "def456"})
      assert changeset.valid?
      assert get_change(changeset, :content) == "new"
      assert get_change(changeset, :content_hash) == "def456"
    end

    test "updates archive metadata" do
      changeset =
        Skill.update_changeset(%Skill{}, %{
          archive_ref: "sha256/def456.tar.gz",
          size_bytes: 5678,
          file_count: 4
        })

      assert changeset.valid?
      assert get_change(changeset, :archive_ref) == "sha256/def456.tar.gz"
      assert get_change(changeset, :size_bytes) == 5678
      assert get_change(changeset, :file_count) == 4
    end

    test "does not allow updating id, slug, or name" do
      changeset =
        Skill.update_changeset(%Skill{}, %{id: "new-id", slug: "new-slug", name: "new-name"})

      refute Map.has_key?(changeset.changes, :id)
      refute Map.has_key?(changeset.changes, :slug)
      refute Map.has_key?(changeset.changes, :name)
    end
  end
end
