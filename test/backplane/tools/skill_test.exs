defmodule Backplane.Tools.SkillTest do
  use Backplane.DataCase, async: false

  alias Backplane.Repo
  alias Backplane.Skills.Registry
  alias Backplane.Tools.Skill, as: SkillTool

  setup do
    if :ets.whereis(:backplane_skills) != :undefined do
      :ets.delete_all_objects(:backplane_skills)
    end

    insert_skill("tool/s1", "Elixir Patterns", "Elixir design patterns", ["elixir", "otp"], "db")
    insert_skill("tool/s2", "React Guide", "React component guide", ["react"], "local:web")

    Registry.refresh()
    :ok
  end

  describe "skill::search" do
    test "returns matching skills without content" do
      {:ok, results} = SkillTool.call(%{"_handler" => "search", "query" => "Elixir"})
      assert is_list(results)
      assert Enum.any?(results, fn r -> r.name == "Elixir Patterns" end)
      # Should not include content
      refute Enum.any?(results, fn r -> Map.has_key?(r, :content) end)
    end

    test "filters by tags when provided" do
      {:ok, results} =
        SkillTool.call(%{"_handler" => "search", "query" => "patterns", "tags" => ["otp"]})

      names = Enum.map(results, & &1.name)
      assert "Elixir Patterns" in names
    end
  end

  describe "skill::load" do
    test "returns full content for valid skill_id" do
      {:ok, result} = SkillTool.call(%{"_handler" => "load", "skill_id" => "tool/s1"})
      assert result.id == "tool/s1"
      assert is_binary(result.content)
    end

    test "returns error for nonexistent skill_id" do
      {:error, msg} = SkillTool.call(%{"_handler" => "load", "skill_id" => "nonexistent"})
      assert String.contains?(msg, "not found")
    end
  end

  describe "skill::list" do
    test "returns all enabled skills" do
      {:ok, skills} = SkillTool.call(%{"_handler" => "list"})
      assert length(skills) >= 2
    end

    test "filters by source when provided" do
      {:ok, skills} = SkillTool.call(%{"_handler" => "list", "source" => "local"})
      assert Enum.all?(skills, fn s -> String.starts_with?(s.source, "local") end)
    end
  end

  describe "skill::create" do
    test "creates db-sourced skill and returns entry" do
      {:ok, result} =
        SkillTool.call(%{
          "_handler" => "create",
          "name" => "new-skill",
          "description" => "A test skill",
          "content" => "# New Skill Content"
        })

      assert String.starts_with?(result.id, "db/")
      assert result.source == "db"
    end
  end

  describe "skill::update" do
    test "updates db-sourced skill" do
      # Create one first
      {:ok, created} =
        SkillTool.call(%{
          "_handler" => "create",
          "name" => "updatable",
          "description" => "Will be updated",
          "content" => "# Original"
        })

      {:ok, _updated} =
        SkillTool.call(%{
          "_handler" => "update",
          "skill_id" => created.id,
          "description" => "Updated description"
        })

      # Verify via registry
      {:ok, fetched} = Registry.fetch(created.id)
      assert fetched.description == "Updated description"
    end

    test "rejects update of non-db skill" do
      {:error, msg} =
        SkillTool.call(%{
          "_handler" => "update",
          "skill_id" => "tool/s2",
          "content" => "nope"
        })

      assert String.contains?(msg, "non-database")
    end
  end

  defp insert_skill(id, name, description, tags, source) do
    content = "# #{name}\n\n#{description}"
    hash = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

    %Backplane.Skills.Skill{}
    |> Backplane.Skills.Skill.changeset(%{
      id: id,
      name: name,
      description: description,
      tags: tags,
      content: content,
      content_hash: hash,
      source: source,
      enabled: true
    })
    |> Repo.insert!()
  end
end
