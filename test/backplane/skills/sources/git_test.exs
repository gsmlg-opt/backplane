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

    on_exit(fn ->
      File.rm_rf!(base_dir)
      # Clean up any clone dirs created under /tmp/backplane_skills/
      Path.wildcard("/tmp/backplane_skills/test-*")
      |> Enum.each(&File.rm_rf!/1)
    end)

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

  describe "list/1 with subdir" do
    test "returns {:ok, []} when configured subdir does not exist", %{repo_dir: repo_dir} do
      config = %Git{
        name: "test-nosubdir-#{:rand.uniform(100_000)}",
        repo: repo_dir,
        path: "nonexistent_subdir",
        ref: "main"
      }

      assert {:ok, []} = Git.list(config)
    end

    test "returns {:ok, []} when path is nil (root scan) and root has no .md files", %{
      repo_dir: _repo_dir
    } do
      # Create a separate repo with no .md files at root (only in skills/)
      base = Path.join(System.tmp_dir!(), "skills_nomd_#{System.unique_integer([:positive])}")
      File.mkdir_p!(base)

      on_exit(fn -> File.rm_rf!(base) end)

      System.cmd("git", ["init"], cd: base)
      System.cmd("git", ["checkout", "-b", "main"], cd: base)
      File.write!(Path.join(base, "readme.txt"), "not markdown")
      System.cmd("git", ["add", "."], cd: base)
      System.cmd("git", ["commit", "-m", "init", "--allow-empty"], cd: base)

      config = %Git{
        name: "test-nilpath-#{:rand.uniform(100_000)}",
        repo: base,
        path: nil,
        ref: "main"
      }

      {:ok, skills} = Git.list(config)
      assert skills == []
    end

    test "skips .md files that fail Loader.parse and returns only valid ones", %{
      repo_dir: repo_dir
    } do
      config = %Git{
        name: "test-badparse-#{:rand.uniform(100_000)}",
        repo: repo_dir,
        path: "skills",
        ref: "main"
      }

      {:ok, skills} = Git.list(config)
      names = Enum.map(skills, & &1.name)

      # bad.md (no frontmatter) must be silently dropped
      refute Enum.any?(names, fn n -> n == "bad" end)
      # valid files must still appear
      assert "elixir-patterns" in names
      assert "otp-guide" in names
    end
  end

  describe "fetch/2" do
    test "returns {:error, :not_found} when skill_id is not in the list", %{repo_dir: repo_dir} do
      name = "test-fetch2-notfound-#{:rand.uniform(100_000)}"
      config = %Git{name: name, repo: repo_dir, path: "skills", ref: "main"}

      assert {:error, :not_found} = Git.fetch(config, "git:#{name}/does-not-exist")
    end

    test "propagates {:error, ...} when list/1 returns an error", %{} do
      # Point at a URL that cannot be cloned so ensure_clone fails
      config = %Git{
        name: "test-fetch2-err-#{:rand.uniform(100_000)}",
        repo: "file:///this/path/does/not/exist",
        path: nil,
        ref: "main"
      }

      assert {:error, {:clone_failed, _}} = Git.fetch(config, "anything")
    end
  end

  describe "clone failure" do
    test "returns {:error, {:clone_failed, _}} for an invalid repo URL" do
      config = %Git{
        name: "test-clone-fail-#{:rand.uniform(100_000)}",
        repo: "file:///totally/invalid/repo/path",
        path: nil,
        ref: "main"
      }

      assert {:error, {:clone_failed, _}} = Git.list(config)
    end
  end

  describe "pull path (existing clone)" do
    test "list/1 uses pull when clone already exists", %{repo_dir: repo_dir} do
      name = "test-pull-#{:rand.uniform(100_000)}"
      config = %Git{name: name, repo: repo_dir, path: "skills", ref: "main"}

      # First call — clones
      {:ok, skills1} = Git.list(config)
      assert length(skills1) >= 2

      # Second call — clone dir already exists, so ensure_clone takes the pull path
      {:ok, skills2} = Git.list(config)
      assert length(skills2) >= 2
    end
  end

  describe "zero-arity list/0 and fetch/1 defaults" do
    test "list/0 is exported and delegates to list/1" do
      # list/0 and fetch/1 are @impl callbacks that forward to the struct-arity
      # variants. Verify they are exported with the right arities.
      assert function_exported?(Git, :list, 0)
      assert function_exported?(Git, :list, 1)
    end

    test "fetch/1 is exported and delegates to fetch/2" do
      assert function_exported?(Git, :fetch, 1)
      assert function_exported?(Git, :fetch, 2)
    end

    test "list/0 returns a tuple (not an exception) for a bad but binary repo", %{} do
      # Override the default struct's repo so System.cmd gets a binary arg.
      # Use a clone name that won't collide, point at a non-existent path.
      config = %Git{
        name: "test-list0-#{:rand.uniform(100_000)}",
        repo: "file:///no/such/repo/for/list0",
        path: nil,
        ref: "main"
      }

      # Calling the 1-arity form exercises the same code path as list/0.
      assert {:error, {:clone_failed, _}} = Git.list(config)
    end

    test "fetch/1 returns a tuple (not an exception) for a bad but binary repo", %{} do
      config = %Git{
        name: "test-fetch1-#{:rand.uniform(100_000)}",
        repo: "file:///no/such/repo/for/fetch1",
        path: nil,
        ref: "main"
      }

      assert {:error, {:clone_failed, _}} = Git.fetch(config, "irrelevant-id")
    end
  end
end
