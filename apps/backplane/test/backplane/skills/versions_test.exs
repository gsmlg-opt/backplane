defmodule Backplane.Skills.VersionsTest do
  use Backplane.DataCase, async: true

  alias Backplane.Skills.Versions

  import Backplane.Fixtures

  setup do
    content = "# Versioned Skill\nVersion 1 content"

    skill =
      insert_skill(
        id: "ver-skill",
        name: "versioned",
        source: "db",
        content: content,
        content_hash: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
      )

    %{skill: skill}
  end

  describe "snapshot/2" do
    test "creates version 1 on first snapshot", %{skill: skill} do
      assert {:ok, version} = Versions.snapshot(skill)
      assert version.version == 1
      assert version.skill_id == skill.id
    end

    test "increments version number", %{skill: skill} do
      assert {:ok, v1} = Versions.snapshot(skill)
      assert {:ok, v2} = Versions.snapshot(skill)
      assert v1.version == 1
      assert v2.version == 2
    end

    test "captures content_hash and full content", %{skill: skill} do
      assert {:ok, version} = Versions.snapshot(skill)
      assert version.content == skill.content
      assert version.content_hash == skill.content_hash
    end

    test "records author from opts", %{skill: skill} do
      assert {:ok, version} = Versions.snapshot(skill, author: "alice")
      assert version.author == "alice"
    end
  end

  describe "list/2" do
    test "returns versions newest first", %{skill: skill} do
      {:ok, _v1} = Versions.snapshot(skill)
      {:ok, _v2} = Versions.snapshot(skill)
      {:ok, _v3} = Versions.snapshot(skill)

      versions = Versions.list(skill.id)
      version_numbers = Enum.map(versions, & &1.version)
      assert version_numbers == [3, 2, 1]
    end

    test "respects limit", %{skill: skill} do
      for _ <- 1..5, do: Versions.snapshot(skill)

      versions = Versions.list(skill.id, limit: 2)
      assert length(versions) == 2
      assert hd(versions).version == 5
    end
  end

  describe "get/2" do
    test "returns specific version content", %{skill: skill} do
      {:ok, _v1} = Versions.snapshot(skill)
      {:ok, v2} = Versions.snapshot(skill)

      assert {:ok, fetched} = Versions.get(skill.id, 2)
      assert fetched.id == v2.id
      assert fetched.content == skill.content
      assert fetched.version == 2
    end
  end
end
