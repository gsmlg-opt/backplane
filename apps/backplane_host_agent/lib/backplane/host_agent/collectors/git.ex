defmodule Backplane.HostAgent.Collectors.Git do
  @moduledoc """
  Snapshots git checkouts under the configured roots, one snapshot per root.

  A directory containing `.git` (directory or worktree file) is a repository
  and is not descended into. Remote URLs are reduced to credential-free
  repository ids via `Backplane.MemoryRepository.select_remote/1`.

  A subdirectory that cannot be read is listed in `unscanned` (the root stays
  complete; the gateway keeps facts below it). A repository whose git commands
  fail unexpectedly is dropped and the root marked incomplete, so a transient
  failure never reports wrong facts. Strings are sanitized to valid UTF-8 and
  branch names and commit subjects truncated to 200 characters.
  """

  @behaviour Backplane.HostAgent.Collectors.Collector

  alias Backplane.HostAgent.Collectors.Collector
  alias Backplane.MemoryRepository

  @skip_dirs ~w(node_modules deps _build target vendor Library venv)
  @max_text 200

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
        {repos, unscanned} = walk(root, 0, config.max_depth, config.max_repos + 1)
        repos = Enum.sort(repos)
        {kept, over} = Enum.split(repos, config.max_repos)
        results = Enum.map(kept, &describe(&1, runner))
        items = for {:ok, item} <- results, do: item
        root_failed? = root in unscanned

        [
          %{
            collector: "git",
            unit: Collector.sanitize(root),
            complete: not root_failed? and over == [] and length(items) == length(results),
            unscanned:
              unscanned |> List.delete(root) |> Enum.map(&Collector.sanitize/1) |> Enum.sort(),
            items: items
          }
        ]
    end
  end

  defp expand("~" <> rest, home), do: Path.expand(home <> rest)
  defp expand(path, _home), do: Path.expand(path)

  # Returns {repo_paths, unscanned_dirs}; stops early once `limit` repos are found.
  defp walk(dir, depth, max_depth, limit) do
    cond do
      File.exists?(Path.join(dir, ".git")) ->
        {[dir], []}

      depth >= max_depth ->
        {[], []}

      true ->
        case File.ls(dir) do
          {:ok, entries} -> walk_children(dir, Enum.sort(entries), depth, max_depth, limit)
          {:error, _reason} -> {[], [dir]}
        end
    end
  end

  defp walk_children(dir, entries, depth, max_depth, limit) do
    Enum.reduce_while(entries, {[], []}, fn entry, {repos, unscanned} ->
      path = Path.join(dir, entry)

      if length(repos) >= limit or not descend?(entry, path) do
        {:cont, {repos, unscanned}}
      else
        {found, child_unscanned} = walk(path, depth + 1, max_depth, limit - length(repos))
        {:cont, {repos ++ found, unscanned ++ child_unscanned}}
      end
    end)
  end

  defp descend?("." <> _hidden, _path), do: false
  defp descend?(entry, _path) when entry in @skip_dirs, do: false

  defp descend?(_entry, path) do
    match?({:ok, %File.Stat{type: :directory}}, File.lstat(path))
  end

  # Returns {:ok, item} or :error when any git command failed unexpectedly.
  defp describe(path, runner) do
    with {:ok, remotes} <- remotes(path, runner),
         {:ok, branch} <- branch(path, runner),
         {:ok, head} <- head(path, runner, branch) do
      {:ok,
       %{
         "path" => Collector.sanitize(path),
         "repository_id" => remotes |> MemoryRepository.select_remote() |> sanitize(),
         "branch" => branch,
         "head" => head
       }}
    end
  end

  defp remotes(path, runner) do
    case git(runner, path, ["config", "--get-regexp", "^remote\\..*\\.url$"]) do
      {:ok, out} -> {:ok, out |> Collector.sanitize() |> parse_remotes()}
      # exit 1: no remote configured
      {:error, {:exit, 1}} -> {:ok, %{}}
      {:error, _} -> :error
    end
  end

  defp parse_remotes(out) do
    for line <- String.split(out, "\n", trim: true),
        [_, name, url] <- [Regex.run(~r/^remote\.(.+)\.url (.+)$/, line)],
        into: %{},
        do: {name, url}
  end

  # {:ok, nil} is a detached HEAD (symbolic-ref exits 1); {:ok, name} is a branch.
  defp branch(path, runner) do
    case git(runner, path, ["symbolic-ref", "--short", "-q", "HEAD"]) do
      {:ok, out} ->
        {:ok, out |> Collector.sanitize() |> String.trim() |> text() |> blank_to_nil()}

      {:error, {:exit, 1}} ->
        {:ok, nil}

      {:error, _} ->
        :error
    end
  end

  # A failing `git log` means "no commits yet" only on a branch (unborn HEAD);
  # on a detached HEAD a commit must exist, so the failure is unexpected.
  defp head(path, runner, branch) do
    case git(runner, path, ["log", "-1", "--format=%H%x1f%s%x1f%cI"]) do
      {:ok, out} -> {:ok, out |> Collector.sanitize() |> parse_head()}
      {:error, {:exit, _status}} when is_binary(branch) -> {:ok, nil}
      {:error, _} -> :error
    end
  end

  defp parse_head(out) do
    case out |> String.trim_trailing("\n") |> String.split("\u001F") do
      [commit, subject, committed_at] when commit != "" ->
        %{"commit" => commit, "subject" => text(subject), "committed_at" => committed_at}

      _ ->
        nil
    end
  end

  defp text(value), do: String.slice(value, 0, @max_text)

  defp sanitize(nil), do: nil
  defp sanitize(value), do: Collector.sanitize(value)

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp git(runner, path, args) do
    case runner.("git", ["-C", path | args], []) do
      {:error, :not_found} -> throw(:git_not_found)
      result -> result
    end
  end
end
