defmodule Backplane.Skills.SkillVersionTest do
  use Backplane.DataCase, async: true

  alias Backplane.Skills.SkillVersion

  import Backplane.Fixtures

  @valid_attrs %{
    skill_id: "test-skill",
    version: 1,
    content_hash: "abc123",
    content: "# Test\nSome content"
  }

  describe "changeset" do
    test "valid with required fields" do
      changeset = SkillVersion.changeset(%SkillVersion{}, @valid_attrs)
      assert changeset.valid?
    end

    test "enforces unique {skill_id, version}" do
      # Insert a real skill first so the FK reference is satisfied
      insert_skill(id: "unique-ver-skill", name: "unique-ver-skill", source: "db")

      attrs = %{@valid_attrs | skill_id: "unique-ver-skill"}

      {:ok, _v1} =
        %SkillVersion{}
        |> SkillVersion.changeset(attrs)
        |> Repo.insert()

      {:error, changeset} =
        %SkillVersion{}
        |> SkillVersion.changeset(attrs)
        |> Repo.insert()

      assert {"has already been taken", _} = changeset.errors[:skill_id]
    end
  end
end
