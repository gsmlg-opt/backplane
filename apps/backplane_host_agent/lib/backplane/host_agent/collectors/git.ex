defmodule Backplane.HostAgent.Collectors.Git do
  @moduledoc """
  Snapshots git checkouts under the configured roots, one snapshot per root.

  A directory containing `.git` (directory or worktree file) is a repository
  and is not descended into. Remote URLs are reduced to credential-free
  repository ids via `Backplane.MemoryRepository.select_remote/1`.
  """

  @behaviour Backplane.HostAgent.Collectors.Collector

  alias Backplane.MemoryRepository

  @skip_dirs ~w(node_modules deps _build target vendor Library venv)

  @impl true
  def config_key, do: :git

  @impl true
  def collect(config, %{runner: runner, home: home}) do
    config.roots
    |> Enum.map(&expand(&1, home))
    |> Enum.flat_map(&collect_root(&1, config, runner))
  catch
    :git_not_found -> []
  end

  defp collect_root(root, config, runner) do
    case File.ls(root) do
      {:error, _reason} ->
        []

      {:ok, _entries} ->
        {repos, walk_complete?} = walk(root, 0, config.max_depth, config.max_repos + 1)
        repos = Enum.sort(repos)
        {kept, over} = Enum.split(repos, config.max_repos)
        results = Enum.map(kept, &describe(&1, runner))

        [
          %{
            collector: "git",
            unit: root,
            complete: walk_complete? and over == [] and Enum.all?(results, &elem(&1, 1)),
            items: Enum.map(results, &elem(&1, 0))
          }
        ]
    end
  end

  defp expand("~" <> rest, home), do: Path.expand(home <> rest)
  defp expand(path, _home), do: Path.expand(path)

  # Returns {repo_paths, complete?}; stops early once `limit` repos are found.
  defp walk(dir, depth, max_depth, limit) do
    cond do
      File.exists?(Path.join(dir, ".git")) ->
        {[dir], true}

      depth >= max_depth ->
        {[], true}

      true ->
        case File.ls(dir) do
          {:ok, entries} -> walk_children(dir, Enum.sort(entries), depth, max_depth, limit)
          {:error, _reason} -> {[], false}
        end
    end
  end

  defp walk_children(dir, entries, depth, max_depth, limit) do
    Enum.reduce_while(entries, {[], true}, fn entry, {repos, complete?} ->
      path = Path.join(dir, entry)

      if length(repos) >= limit or not descend?(entry, path) do
        {:cont, {repos, complete?}}
      else
        {found, child_complete?} = walk(path, depth + 1, max_depth, limit - length(repos))
        {:cont, {repos ++ found, complete? and child_complete?}}
      end
    end)
  end

  defp descend?("." <> _hidden, _path), do: false
  defp descend?(entry, _path) when entry in @skip_dirs, do: false

  defp descend?(_entry, path) do
    match?({:ok, %File.Stat{type: :directory}}, File.lstat(path))
  end

  defp describe(path, runner) do
    {remotes, c1} = remotes(path, runner)
    {branch, c2} = branch(path, runner)
    {head, c3} = head(path, runner)

    item = %{
      "path" => path,
      "repository_id" => MemoryRepository.select_remote(remotes),
      "branch" => branch,
      "head" => head
    }

    {item, c1 and c2 and c3}
  end

  defp remotes(path, runner) do
    case git(runner, path, ["config", "--get-regexp", "^remote\\..*\\.url$"]) do
      {:ok, out} -> {parse_remotes(out), true}
      {:error, {:exit, 1}} -> {%{}, true}
      {:error, _} -> {%{}, false}
    end
  end

  defp parse_remotes(out) do
    for line <- String.split(out, "\n", trim: true),
        [_, name, url] <- [Regex.run(~r/^remote\.(.+)\.url (.+)$/, line)],
        into: %{},
        do: {name, url}
  end

  defp branch(path, runner) do
    case git(runner, path, ["symbolic-ref", "--short", "-q", "HEAD"]) do
      {:ok, out} -> {blank_to_nil(String.trim(out)), true}
      {:error, {:exit, 1}} -> {nil, true}
      {:error, _} -> {nil, false}
    end
  end

  defp head(path, runner) do
    case git(runner, path, ["log", "-1", "--format=%H%x1f%s%x1f%cI"]) do
      {:ok, out} -> {parse_head(out), true}
      {:error, {:exit, _status}} -> {nil, true}
      {:error, _} -> {nil, false}
    end
  end

  defp parse_head(out) do
    case out |> String.trim_trailing("\n") |> String.split("\u001F") do
      [commit, subject, committed_at] when commit != "" ->
        %{"commit" => commit, "subject" => subject, "committed_at" => committed_at}

      _ ->
        nil
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp git(runner, path, args) do
    case runner.("git", ["-C", path | args], []) do
      {:error, :not_found} -> throw(:git_not_found)
      result -> result
    end
  end
end
