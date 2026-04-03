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

    test "returns error for nonexistent directory" do
      config = %Local{name: "test", path: "/tmp/nonexistent_skill_dir_999999"}
      assert {:error, :directory_not_found} = Local.list(config)
    end

    test "returns empty list when path is nil" do
      config = %Local{name: "test", path: nil}
      assert {:ok, []} = Local.list(config)
    end

    test "uses 'local' as source when name is nil", %{dir: dir} do
      config = %Local{name: nil, path: dir}
      {:ok, skills} = Local.list(config)
      assert Enum.all?(skills, fn s -> s.source == "local" end)
    end

    test "list/0 returns empty when no config set" do
      old = Application.get_env(:backplane, :local_skills)
      Application.delete_env(:backplane, :local_skills)

      assert {:ok, []} = Local.list()

      if old, do: Application.put_env(:backplane, :local_skills, old)
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

    test "fetch/1 returns not_configured when no config" do
      old = Application.get_env(:backplane, :local_skills)
      Application.delete_env(:backplane, :local_skills)

      assert {:error, :not_configured} = Local.fetch("some-id")

      if old, do: Application.put_env(:backplane, :local_skills, old)
    end

    test "fetch/1 delegates to fetch(config, skill_id) when Application env is set", %{dir: dir} do
      # L57: the `config -> fetch(config, skill_id)` branch in the zero-arity fetch/1.
      old = Application.get_env(:backplane, :local_skills)

      Application.put_env(:backplane, :local_skills, %{name: "env-test", path: dir})

      result = Local.fetch("local:env-test/elixir-patterns")
      assert {:ok, skill} = result
      assert skill.name == "elixir-patterns"

      if old do
        Application.put_env(:backplane, :local_skills, old)
      else
        Application.delete_env(:backplane, :local_skills)
      end
    end

    test "fetch/1 propagates error from list when directory does not exist", %{dir: _dir} do
      # L67: the `{:error, _} = error -> error` branch in fetch/2.
      # fetch/2 calls list/1 first; if it returns {:error, _} that is propagated.
      config = %Local{
        name: "ghost",
        path: "/tmp/nonexistent_local_skill_dir_#{System.unique_integer([:positive])}"
      }

      assert {:error, :directory_not_found} = Local.fetch(config, "local:ghost/anything")
    end
  end

  describe "list/0 with Application config" do
    test "list/0 delegates to list(config) when Application env has a path", %{dir: dir} do
      # L16: the `config -> list(config)` branch when get_config/0 returns a struct.
      old = Application.get_env(:backplane, :local_skills)

      Application.put_env(:backplane, :local_skills, %{path: dir})

      {:ok, skills} = Local.list()
      names = Enum.map(skills, & &1.name)
      assert "elixir-patterns" in names

      if old do
        Application.put_env(:backplane, :local_skills, old)
      else
        Application.delete_env(:backplane, :local_skills)
      end
    end

    test "get_config/0 uses name from Application env when present", %{dir: dir} do
      # L74: the branch `%{path: path} = cfg ->` where cfg also has a :name key,
      # so `Map.get(cfg, :name)` returns a non-nil value.
      old = Application.get_env(:backplane, :local_skills)

      Application.put_env(:backplane, :local_skills, %{name: "named-src", path: dir})

      {:ok, skills} = Local.list()
      # All returned skills should use source "local:named-src" because the
      # config has an explicit name.
      assert Enum.all?(skills, fn s -> s.source == "local:named-src" end)

      if old do
        Application.put_env(:backplane, :local_skills, old)
      else
        Application.delete_env(:backplane, :local_skills)
      end
    end
  end
end
