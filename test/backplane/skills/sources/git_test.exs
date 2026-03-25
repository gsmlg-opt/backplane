defmodule Backplane.Skills.Sources.GitTest do
  use ExUnit.Case, async: true

  alias Backplane.Skills.Sources.Git

  setup do
    # Create a fake git repo for testing
    base_dir = Path.join(System.tmp_dir!(), "backplane_git_test_#{:rand.uniform(100_000)}")
    repo_dir = Path.join(base_dir, "repo")
    skills_dir = Path.join(repo_dir, "skills")
    File.mkdir_p!(skills_dir)

    # Init a git repo
    System.cmd("git", ["init"], cd: repo_dir)
    System.cmd("git", ["checkout", "-b", "main"], cd: repo_dir)

    # Write skill files
    File.write!(Path.join(skills_dir, "elixir-patterns.md"), """
    ---
    name: elixir-patterns
    description: Elixir design patterns
    tags: [elixir]
    ---

    # Elixir Patterns
    """)

    File.write!(Path.join(skills_dir, "otp-guide.md"), """
    ---
    name: otp-guide
    description: OTP guide
    tags: [otp]
    ---

    # OTP Guide
    """)

    # Non-md file (should be ignored)
    File.write!(Path.join(skills_dir, "notes.txt"), "plain text")

    # MD without frontmatter (should be ignored)
    File.write!(Path.join(skills_dir, "bad.md"), "# No frontmatter")

    System.cmd("git", ["add", "."], cd: repo_dir)
    System.cmd("git", ["commit", "-m", "init", "--allow-empty"], cd: repo_dir)

    on_exit(fn -> File.rm_rf!(base_dir) end)

    %{repo_dir: repo_dir}
  end

  describe "list/0" do
    test "clones repo and discovers SKILL.md files", %{repo_dir: repo_dir} do
      config = %Git{
        name: "test-git-#{:rand.uniform(100_000)}",
        repo: repo_dir,
        path: "skills",
        ref: "main"
      }

      {:ok, skills} = Git.list(config)
      names = Enum.map(skills, & &1.name)
      assert "elixir-patterns" in names
      assert "otp-guide" in names
    end

    test "scans only configured subdirectory path", %{repo_dir: repo_dir} do
      config = %Git{
        name: "test-subdir-#{:rand.uniform(100_000)}",
        repo: repo_dir,
        path: "skills",
        ref: "main"
      }

      {:ok, skills} = Git.list(config)
      # Should only find skills in the skills/ subdirectory
      assert length(skills) >= 2
    end

    test "ignores non-.md files", %{repo_dir: repo_dir} do
      config = %Git{
        name: "test-nonmd-#{:rand.uniform(100_000)}",
        repo: repo_dir,
        path: "skills",
        ref: "main"
      }

      {:ok, skills} = Git.list(config)
      names = Enum.map(skills, & &1.name)
      refute "notes" in names
    end

    test "ignores .md files without valid frontmatter", %{repo_dir: repo_dir} do
      config = %Git{
        name: "test-nofm-#{:rand.uniform(100_000)}",
        repo: repo_dir,
        path: "skills",
        ref: "main"
      }

      {:ok, skills} = Git.list(config)
      ids = Enum.map(skills, & &1.id)
      refute Enum.any?(ids, &String.contains?(&1, "bad"))
    end

    test "returns skill entries with source set to git:<name>", %{repo_dir: repo_dir} do
      name = "test-source-#{:rand.uniform(100_000)}"
      config = %Git{name: name, repo: repo_dir, path: "skills", ref: "main"}
      {:ok, skills} = Git.list(config)
      assert Enum.all?(skills, fn s -> s.source == "git:#{name}" end)
    end
  end

  describe "fetch/1" do
    test "returns specific skill by ID", %{repo_dir: repo_dir} do
      name = "test-fetch-#{:rand.uniform(100_000)}"
      config = %Git{name: name, repo: repo_dir, path: "skills", ref: "main"}
      {:ok, skill} = Git.fetch(config, "git:#{name}/elixir-patterns")
      assert skill.name == "elixir-patterns"
    end

    test "returns error for nonexistent skill", %{repo_dir: repo_dir} do
      name = "test-noexist-#{:rand.uniform(100_000)}"
      config = %Git{name: name, repo: repo_dir, path: "skills", ref: "main"}
      assert {:error, :not_found} = Git.fetch(config, "git:#{name}/nonexistent")
    end
  end
end
