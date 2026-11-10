defmodule Backplane.HostAgent.Collectors.GitTest do
  use ExUnit.Case, async: true

  alias Backplane.HostAgent.Collectors.{Command, Git}

  @moduletag :tmp_dir

  @token "ghp_token"

  defp env(runner \\ &Command.run/3), do: %{runner: runner, os: :darwin, home: "/home/test"}

  defp config(root, overrides \\ []) do
    Map.merge(%{enabled: true, roots: [root], max_depth: 4, max_repos: 500}, Map.new(overrides))
  end

  defp git!(path, args) do
    {_, 0} = System.cmd("git", ["-C", path | args], stderr_to_stdout: true)
  end

  defp init_repo(path, opts \\ []) do
    File.mkdir_p!(path)
    git!(path, ["init", "-q", "-b", "main"])
    git!(path, ["config", "user.name", "Test"])
    git!(path, ["config", "user.email", "t@example.com"])
    git!(path, ["config", "commit.gpgsign", "false"])

    if Keyword.get(opts, :commit, true) do
      git!(path, ["commit", "-q", "--allow-empty", "-m", "first commit"])
    end

    if remote = opts[:remote], do: git!(path, ["remote", "add", "origin", remote])
    path
  end

  defp collect(root, overrides \\ [], runner \\ &Command.run/3) do
    Git.collect(config(root, overrides), env(runner))
  end

  test "config_key is :git" do
    assert Git.config_key() == :git
  end

  test "reports a repo with normalized remote, branch and head, never the credentials",
       %{tmp_dir: dir} do
    repo = init_repo(Path.join(dir, "proj"), remote: "https://user:#{@token}@github.com/o/r.git")

    assert [snapshot] = collect(dir)
    assert %{collector: "git", unit: ^dir, complete: true, items: [item]} = snapshot

    assert %{
             "path" => ^repo,
             "repository_id" => "github.com/o/r",
             "branch" => "main",
             "head" => %{"commit" => commit, "subject" => "first commit", "committed_at" => at}
           } = item

    assert commit =~ ~r/^[0-9a-f]{40}$/
    assert {:ok, _, _} = DateTime.from_iso8601(at)
    refute inspect(snapshot) =~ @token
    refute inspect(snapshot) =~ "user:"
  end

  test "repo without remote has nil repository_id", %{tmp_dir: dir} do
    init_repo(Path.join(dir, "local"))
    assert [%{complete: true, items: [%{"repository_id" => nil}]}] = collect(dir)
  end

  test "nested repos are not reported", %{tmp_dir: dir} do
    outer = init_repo(Path.join(dir, "outer"))
    init_repo(Path.join(outer, "inner"))
    assert [%{items: [%{"path" => ^outer}]}] = collect(dir)
  end

  test "skips node_modules, dot dirs and other skip-list dirs", %{tmp_dir: dir} do
    for skipped <- ~w(node_modules .hidden deps _build target vendor Library venv) do
      init_repo(Path.join([dir, skipped, "repo"]))
    end

    keep = init_repo(Path.join(dir, "keep"))
    assert [%{complete: true, items: [%{"path" => ^keep}]}] = collect(dir)
  end

  test "a .git file (worktree) counts as a repo", %{tmp_dir: dir} do
    main = init_repo(Path.join(dir, "main_repo"))
    wt = Path.join(dir, "wt")
    git!(main, ["worktree", "add", "-q", "-b", "feature", wt])

    paths = dir |> collect() |> hd() |> Map.fetch!(:items) |> Enum.map(& &1["path"])
    assert wt in paths
    assert File.regular?(Path.join(wt, ".git"))
  end

  test "detached HEAD yields branch nil", %{tmp_dir: dir} do
    repo = init_repo(Path.join(dir, "d"))
    git!(repo, ["checkout", "-q", "--detach"])
    assert [%{complete: true, items: [%{"branch" => nil, "head" => %{}}]}] = collect(dir)
  end

  test "empty repo yields head nil and stays complete", %{tmp_dir: dir} do
    init_repo(Path.join(dir, "e"), commit: false)

    assert [%{complete: true, items: [%{"branch" => "main", "head" => nil}]}] = collect(dir)
  end

  test "missing root yields no snapshot", %{tmp_dir: dir} do
    assert collect(Path.join(dir, "nope")) == []
  end

  test "max_repos keeps the first N by path and marks incomplete", %{tmp_dir: dir} do
    for n <- ~w(a b c), do: init_repo(Path.join(dir, n))

    assert [%{complete: false, items: items}] = collect(dir, max_repos: 2)
    assert Enum.map(items, & &1["path"]) == [Path.join(dir, "a"), Path.join(dir, "b")]
  end

  test "max_depth bounds the walk", %{tmp_dir: dir} do
    init_repo(Path.join([dir, "x", "y", "deep"]))
    assert [%{items: []}] = collect(dir, max_depth: 2)
    assert [%{items: [_]}] = collect(dir, max_depth: 3)
  end

  test "git not found yields []", %{tmp_dir: dir} do
    init_repo(Path.join(dir, "r"))
    assert collect(dir, [], fn _, _, _ -> {:error, :not_found} end) == []
  end

  defp failing(match, result) do
    fn cmd, args, opts ->
      if match in args, do: result, else: Command.run(cmd, args, opts)
    end
  end

  test "an unexpected symbolic-ref error drops the item and marks the unit incomplete",
       %{tmp_dir: dir} do
    init_repo(Path.join(dir, "r"))
    keep = init_repo(Path.join(dir, "s"))

    runner = fn cmd, args, opts ->
      if "symbolic-ref" in args and hd(tl(args)) == Path.join(dir, "r"),
        do: {:error, :timeout},
        else: Command.run(cmd, args, opts)
    end

    assert [%{complete: false, items: [%{"path" => ^keep}]}] = collect(dir, [], runner)
  end

  test "exit 128 or a timeout from any git command drops the item", %{tmp_dir: dir} do
    init_repo(Path.join(dir, "r"))

    for {match, result} <- [
          {"--get-regexp", {:error, {:exit, 128}}},
          {"--get-regexp", {:error, :timeout}},
          {"symbolic-ref", {:error, {:exit, 128}}},
          {"symbolic-ref", {:error, :timeout}},
          {"log", {:error, :timeout}}
        ] do
      assert [%{complete: false, items: []}] = collect(dir, [], failing(match, result)),
             "#{match} #{inspect(result)}"
    end
  end

  test "git log exiting non-zero on a branch is an empty repo (head nil)", %{tmp_dir: dir} do
    init_repo(Path.join(dir, "r"))

    assert [%{complete: true, items: [%{"branch" => "main", "head" => nil}]}] =
             collect(dir, [], failing("log", {:error, {:exit, 128}}))
  end

  test "exit 1 from config means no remote and keeps the item", %{tmp_dir: dir} do
    init_repo(Path.join(dir, "r"))

    assert [%{complete: true, items: [%{"repository_id" => nil, "branch" => "main"}]}] =
             collect(dir, [], failing("--get-regexp", {:error, {:exit, 1}}))
  end

  test "git log failure on a detached HEAD is not an empty repo: the item is dropped",
       %{tmp_dir: dir} do
    repo = init_repo(Path.join(dir, "d"))
    git!(repo, ["checkout", "-q", "--detach"])

    assert [%{complete: false, items: []}] =
             collect(dir, [], failing("log", {:error, {:exit, 128}}))
  end

  test "an unreadable subdirectory is listed as unscanned and keeps the root complete",
       %{tmp_dir: dir} do
    keep = init_repo(Path.join(dir, "keep"))
    private = Path.join(dir, "private")
    File.mkdir_p!(Path.join(private, "inner"))
    File.chmod!(private, 0o000)
    on_exit(fn -> File.chmod(private, 0o755) end)

    assert [%{complete: true, unscanned: [^private], items: [%{"path" => ^keep}]}] = collect(dir)
  end

  test "a fully readable root has an empty unscanned list", %{tmp_dir: dir} do
    init_repo(Path.join(dir, "r"))
    assert [%{complete: true, unscanned: []}] = collect(dir)
  end

  test "a non-UTF-8 commit subject is reported as valid UTF-8", %{tmp_dir: dir} do
    repo = init_repo(Path.join(dir, "latin"))
    msg = Path.join(dir, "msg")
    File.write!(msg, <<"caf", 0xE9, " fix">>)
    git!(repo, ["commit", "-q", "--allow-empty", "--cleanup=verbatim", "-F", msg])

    assert [%{items: [%{"head" => %{"subject" => subject}}]} = snapshot] = collect(dir)
    assert String.valid?(subject)
    assert {:ok, _} = Jason.encode(snapshot.items)

    # git may re-encode on its own; raw Latin-1 output is replaced, not rejected.
    runner = fn
      "git", [_, _, "log" | _], _ ->
        {:ok, <<"abc123", 0x1F, "caf", 0xE9, " fix", 0x1F, "2026-11-10T00:00:00Z\n">>}

      cmd, args, opts ->
        Command.run(cmd, args, opts)
    end

    assert [%{items: [%{"head" => %{"subject" => "caf\uFFFD fix"}}]}] = collect(dir, [], runner)
  end

  test "non-UTF-8 paths, branches and remotes are sanitized", %{tmp_dir: dir} do
    init_repo(Path.join(dir, "r"))

    runner = fn
      "git", [_, _, "config" | _], _ ->
        {:ok, <<"remote.origin.url https://github.com/o/r", 0xFF, ".git\n">>}

      "git", [_, _, "symbolic-ref" | _], _ ->
        {:ok, <<"br", 0xE9, "\n">>}

      cmd, args, opts ->
        Command.run(cmd, args, opts)
    end

    assert [%{items: [item]}] = collect(dir, [], runner)
    assert String.valid?(item["branch"]) and String.valid?(item["repository_id"])
    assert item["branch"] == "br\uFFFD"
  end

  test "commit subject and branch are truncated to 200 characters", %{tmp_dir: dir} do
    repo = init_repo(Path.join(dir, "long"))
    long = String.duplicate("é", 250)
    git!(repo, ["commit", "-q", "--allow-empty", "-m", long])
    git!(repo, ["checkout", "-q", "-b", String.duplicate("b", 250)])

    assert [%{items: [%{"branch" => branch, "head" => %{"subject" => subject}}]}] = collect(dir)
    assert branch == String.duplicate("b", 200)
    assert subject == String.duplicate("é", 200)
  end

  test "unexpanded ~ in roots is expanded against home", %{tmp_dir: dir} do
    init_repo(Path.join(dir, "r"))
    cfg = config("~/")
    env = %{env() | home: dir}
    assert [%{unit: ^dir}] = Git.collect(cfg, env)
  end
end
