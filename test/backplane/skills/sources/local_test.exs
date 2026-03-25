defmodule Backplane.Skills.Sources.LocalTest do
  use ExUnit.Case, async: true

  alias Backplane.Skills.Sources.Local

  setup do
    dir = Path.join(System.tmp_dir!(), "backplane_local_skills_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(dir)

    # Write valid skill files
    File.write!(Path.join(dir, "elixir-patterns.md"), """
    ---
    name: elixir-patterns
    description: Elixir design patterns
    tags: [elixir, patterns]
    ---

    # Elixir Patterns
    Some content here.
    """)

    File.write!(Path.join(dir, "otp-guide.md"), """
    ---
    name: otp-guide
    description: OTP supervision guide
    tags: [otp]
    ---

    # OTP Guide
    Supervision content.
    """)

    # Write non-md file
    File.write!(Path.join(dir, "readme.txt"), "This should be ignored")

    # Write md without frontmatter
    File.write!(Path.join(dir, "no-frontmatter.md"), "# Just a heading\nNo YAML here.")

    on_exit(fn -> File.rm_rf!(dir) end)

    %{dir: dir}
  end

  describe "list/0" do
    test "reads configured directory for SKILL.md files", %{dir: dir} do
      config = %Local{name: "test", path: dir}
      {:ok, skills} = Local.list(config)

      names = Enum.map(skills, & &1.name)
      assert "elixir-patterns" in names
      assert "otp-guide" in names
    end

    test "ignores non-.md files", %{dir: dir} do
      config = %Local{name: "test", path: dir}
      {:ok, skills} = Local.list(config)
      names = Enum.map(skills, & &1.name)
      refute "readme" in names
    end

    test "ignores .md files without valid frontmatter", %{dir: dir} do
      config = %Local{name: "test", path: dir}
      {:ok, skills} = Local.list(config)
      ids = Enum.map(skills, & &1.id)
      refute Enum.any?(ids, &String.contains?(&1, "no-frontmatter"))
    end

    test "returns skill entries with source set to local:<name>", %{dir: dir} do
      config = %Local{name: "experiments", path: dir}
      {:ok, skills} = Local.list(config)
      assert Enum.all?(skills, fn s -> s.source == "local:experiments" end)
    end
  end

  describe "fetch/1" do
    test "returns specific skill by ID", %{dir: dir} do
      config = %Local{name: "test", path: dir}
      {:ok, skill} = Local.fetch(config, "local:test/elixir-patterns")
      assert skill.name == "elixir-patterns"
    end

    test "returns error for nonexistent skill", %{dir: dir} do
      config = %Local{name: "test", path: dir}
      assert {:error, :not_found} = Local.fetch(config, "local:test/nonexistent")
    end
  end
end
