defmodule Backplane.Skills.DepsTest do
  use Backplane.DataCase, async: true

  alias Backplane.Skills.Deps
  alias Backplane.Skills.Registry

  import Backplane.Fixtures

  defp insert_skill_with_deps(name, deps, extra_content \\ "") do
    deps_yaml =
      if deps == [],
        do: "",
        else: "depends_on:\n" <> Enum.map_join(deps, "\n", &"  - #{&1}")

    content = "---\nname: #{name}\n#{deps_yaml}\n---\n# #{name}\n#{extra_content}"
    insert_skill(id: name, name: name, content: content, source: "db")
  end

  describe "resolve/2" do
    test "returns single skill with no dependencies" do
      insert_skill_with_deps("solo-skill", [])
      Registry.refresh()

      assert {:ok, [skill]} = Deps.resolve("solo-skill")
      assert skill.id == "solo-skill"
    end

    test "returns skill + direct dependencies in topological order" do
      insert_skill_with_deps("dep-a", [])
      insert_skill_with_deps("dep-b", [])
      insert_skill_with_deps("parent", ["dep-a", "dep-b"])
      Registry.refresh()

      assert {:ok, skills} = Deps.resolve("parent")
      ids = Enum.map(skills, & &1.id)

      # Dependencies come before the dependent
      assert List.last(ids) == "parent"
      assert "dep-a" in ids
      assert "dep-b" in ids

      # dep-a and dep-b appear before parent
      assert Enum.find_index(ids, &(&1 == "dep-a")) < Enum.find_index(ids, &(&1 == "parent"))
      assert Enum.find_index(ids, &(&1 == "dep-b")) < Enum.find_index(ids, &(&1 == "parent"))
    end

    test "returns transitive dependencies (A -> B -> C returns [C, B, A])" do
      insert_skill_with_deps("skill-c", [])
      insert_skill_with_deps("skill-b", ["skill-c"])
      insert_skill_with_deps("skill-a", ["skill-b"])
      Registry.refresh()

      assert {:ok, skills} = Deps.resolve("skill-a")
      ids = Enum.map(skills, & &1.id)

      assert ids == ["skill-c", "skill-b", "skill-a"]
    end

    test "deduplicates shared dependencies" do
      insert_skill_with_deps("shared", [])
      insert_skill_with_deps("branch-1", ["shared"])
      insert_skill_with_deps("branch-2", ["shared"])
      insert_skill_with_deps("root", ["branch-1", "branch-2"])
      Registry.refresh()

      assert {:ok, skills} = Deps.resolve("root")
      ids = Enum.map(skills, & &1.id)

      # "shared" should appear exactly once
      assert Enum.count(ids, &(&1 == "shared")) == 1
      assert length(ids) == 4
    end

    test "detects direct cycle (A -> B -> A)" do
      insert_skill_with_deps("cycle-a", ["cycle-b"])
      insert_skill_with_deps("cycle-b", ["cycle-a"])
      Registry.refresh()

      assert {:error, msg} = Deps.resolve("cycle-a")
      assert msg =~ "cycle"
    end

    test "detects indirect cycle (A -> B -> C -> A)" do
      insert_skill_with_deps("loop-a", ["loop-b"])
      insert_skill_with_deps("loop-b", ["loop-c"])
      insert_skill_with_deps("loop-c", ["loop-a"])
      Registry.refresh()

      assert {:error, msg} = Deps.resolve("loop-a")
      assert msg =~ "cycle"
    end

    test "returns partial results with warning for missing dependency" do
      insert_skill_with_deps("parent-skill", ["missing-skill"])
      Registry.refresh()

      assert {:ok, skills, warnings} = Deps.resolve("parent-skill")
      assert length(warnings) == 1
      assert hd(warnings) =~ "missing-skill"
      # The parent skill itself should still be returned
      assert Enum.any?(skills, &(&1.id == "parent-skill"))
    end

    test "enforces max depth of 10" do
      # Create a chain of 12 skills: s0 -> s1 -> s2 -> ... -> s11
      for i <- 11..0//-1 do
        deps = if i == 11, do: [], else: ["chain-s#{i + 1}"]
        insert_skill_with_deps("chain-s#{i}", deps)
      end

      Registry.refresh()

      assert {:error, msg} = Deps.resolve("chain-s0")
      assert msg =~ "depth"
    end

    test "returns empty deps for resolve_deps: false" do
      insert_skill_with_deps("dep-x", [])
      insert_skill_with_deps("with-dep", ["dep-x"])
      Registry.refresh()

      assert {:ok, [skill]} = Deps.resolve("with-dep", resolve_deps: false)
      assert skill.id == "with-dep"
    end
  end
end
