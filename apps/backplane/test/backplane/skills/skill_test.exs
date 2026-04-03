defmodule Backplane.Skills.SkillTest do
  use Backplane.DataCase, async: true

  alias Backplane.Skills.Skill

  @valid_attrs %{
    id: "test/skill-1",
    name: "test-skill",
    content: "# Test Skill\nDo the thing.",
    content_hash: "abc123",
    source: "local"
  }

  describe "changeset/2" do
    test "valid with all required fields" do
      changeset = Skill.changeset(%Skill{}, @valid_attrs)
      assert changeset.valid?
    end

    test "invalid without required fields" do
      changeset = Skill.changeset(%Skill{}, %{})
      refute changeset.valid?

      for field <- ~w(id name content content_hash source)a do
        assert {_, [validation: :required]} = changeset.errors[field]
      end
    end

    test "accepts optional fields" do
      attrs =
        Map.merge(@valid_attrs, %{
          description: "A test skill",
          tags: ["elixir", "testing"],
          tools: ["hub::inspect"],
          model: "claude-sonnet",
          version: "2.0.0",
          enabled: false
        })

      changeset = Skill.changeset(%Skill{}, attrs)
      assert changeset.valid?
      assert get_change(changeset, :tags) == ["elixir", "testing"]
      assert get_change(changeset, :enabled) == false
    end

    test "uses default values for optional fields" do
      {:ok, skill} = Repo.insert(Skill.changeset(%Skill{}, @valid_attrs))
      assert skill.description == ""
      assert skill.tags == []
      assert skill.tools == []
      assert skill.version == "1.0.0"
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

    test "does not allow updating id, name, or source" do
      changeset =
        Skill.update_changeset(%Skill{}, %{id: "new-id", name: "new-name", source: "git"})

      refute Map.has_key?(changeset.changes, :id)
      refute Map.has_key?(changeset.changes, :name)
      refute Map.has_key?(changeset.changes, :source)
    end
  end
end
