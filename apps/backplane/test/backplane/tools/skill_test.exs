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
      # With resolve_deps (default), result is a list of skills
      assert is_list(result)
      skill = List.last(result)
      assert skill.id == "tool/s1"
      assert is_binary(skill.content)
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

    test "returns error for nonexistent skill update" do
      {:error, msg} =
        SkillTool.call(%{
          "_handler" => "update",
          "skill_id" => "nonexistent/id",
          "content" => "nope"
        })

      assert msg =~ "not found"
    end
  end

  describe "skill::create error" do
    test "returns error when required name is missing" do
      {:error, msg} =
        SkillTool.call(%{
          "_handler" => "create",
          "description" => "A skill without a name",
          "content" => "# No Name"
        })

      assert msg =~ "Failed to create skill"
      assert msg =~ "name"
    end
  end

  describe "skill::search with limit" do
    test "respects limit parameter" do
      {:ok, results} =
        SkillTool.call(%{"_handler" => "search", "query" => "guide", "limit" => 1})

      assert length(results) <= 1
    end
  end

  describe "unknown handler" do
    test "returns error for unknown handler" do
      {:error, msg} = SkillTool.call(%{"unknown" => "handler"})
      assert msg =~ "Unknown skill tool handler"
    end
  end

  describe "skill::load with dependencies" do
    test "loads skill with all resolved dependencies" do
      insert_skill_with_content(
        "db/base-lib",
        "base-lib",
        "A base library skill",
        ["elixir"],
        "db",
        "---\nname: base-lib\n---\n# Base Library\nFoundation utilities."
      )

      insert_skill_with_content(
        "db/app-skill",
        "app-skill",
        "App depending on base-lib",
        ["elixir"],
        "db",
        "---\nname: app-skill\ndepends_on:\n  - base-lib\n---\n# App Skill\nUses base-lib."
      )

      Registry.refresh()

      {:ok, result} = SkillTool.call(%{"_handler" => "load", "skill_id" => "db/app-skill"})
      assert is_list(result)
      ids = Enum.map(result, & &1.id)
      assert "db/base-lib" in ids
      assert "db/app-skill" in ids
    end

    test "returns topological order (deps before dependents)" do
      insert_skill_with_content(
        "db/dep-a",
        "dep-a",
        "Dependency A",
        [],
        "db",
        "---\nname: dep-a\n---\n# Dep A"
      )

      insert_skill_with_content(
        "db/dep-b",
        "dep-b",
        "Depends on dep-a",
        [],
        "db",
        "---\nname: dep-b\ndepends_on:\n  - dep-a\n---\n# Dep B"
      )

      Registry.refresh()

      {:ok, result} = SkillTool.call(%{"_handler" => "load", "skill_id" => "db/dep-b"})
      ids = Enum.map(result, & &1.id)
      dep_a_idx = Enum.find_index(ids, &(&1 == "db/dep-a"))
      dep_b_idx = Enum.find_index(ids, &(&1 == "db/dep-b"))
      assert dep_a_idx < dep_b_idx
    end

    test "returns error on cycle" do
      insert_skill_with_content(
        "db/cycle-x",
        "cycle-x",
        "Cycle X",
        [],
        "db",
        "---\nname: cycle-x\ndepends_on:\n  - cycle-y\n---\n# Cycle X"
      )

      insert_skill_with_content(
        "db/cycle-y",
        "cycle-y",
        "Cycle Y",
        [],
        "db",
        "---\nname: cycle-y\ndepends_on:\n  - cycle-x\n---\n# Cycle Y"
      )

      Registry.refresh()

      {:error, msg} = SkillTool.call(%{"_handler" => "load", "skill_id" => "db/cycle-x"})
      assert msg =~ "cycle"
    end

    test "includes warning for unresolved deps" do
      insert_skill_with_content(
        "db/orphan-skill",
        "orphan-skill",
        "Depends on missing skill",
        [],
        "db",
        "---\nname: orphan-skill\ndepends_on:\n  - nonexistent-dep\n---\n# Orphan"
      )

      Registry.refresh()

      {:ok, result} = SkillTool.call(%{"_handler" => "load", "skill_id" => "db/orphan-skill"})
      assert is_map(result)
      assert Map.has_key?(result, :warnings)
      assert Enum.any?(result.warnings, &String.contains?(&1, "nonexistent-dep"))
    end
  end

  describe "skill::load with version" do
    test "loads specific version of DB skill" do
      insert_skill("db/versioned", "versioned", "Version test skill", ["test"], "db")
      Registry.refresh()

      # Snapshot current state as version 1
      skill = Repo.get!(Backplane.Skills.Skill, "db/versioned")
      {:ok, _v1} = Backplane.Skills.Versions.snapshot(skill)

      # Update the skill content
      Backplane.Skills.Sources.Database.update("db/versioned", %{
        content: "# Updated Content\nNew version."
      })

      Registry.refresh()

      # Load version 1 — should get the original content
      {:ok, result} =
        SkillTool.call(%{
          "_handler" => "load",
          "skill_id" => "db/versioned",
          "version" => 1
        })

      assert result.version == 1
      assert result.content =~ "Version test skill"
    end

    test "returns error for version on non-db skill" do
      {:error, msg} =
        SkillTool.call(%{
          "_handler" => "load",
          "skill_id" => "tool/s2",
          "version" => 1
        })

      assert msg =~ "not available"
    end
  end

  describe "skill::versions" do
    test "returns version history" do
      insert_skill("db/hist-skill", "hist-skill", "History test", ["test"], "db")
      Registry.refresh()

      skill = Repo.get!(Backplane.Skills.Skill, "db/hist-skill")
      {:ok, _v1} = Backplane.Skills.Versions.snapshot(skill)

      # Update and snapshot again
      Backplane.Skills.Sources.Database.update("db/hist-skill", %{
        content: "# Updated once"
      })

      skill = Repo.get!(Backplane.Skills.Skill, "db/hist-skill")
      {:ok, _v2} = Backplane.Skills.Versions.snapshot(skill)

      Registry.refresh()

      {:ok, result} =
        SkillTool.call(%{"_handler" => "versions", "skill_id" => "db/hist-skill"})

      assert is_map(result)
      assert length(result.versions) == 2
      version_numbers = Enum.map(result.versions, & &1.version)
      assert 1 in version_numbers
      assert 2 in version_numbers
    end

    test "returns message for non-db skill" do
      {:ok, result} =
        SkillTool.call(%{"_handler" => "versions", "skill_id" => "tool/s2"})

      assert result.versions == []
      assert result.message =~ "git log"
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

  defp insert_skill_with_content(id, name, description, tags, source, content) do
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
