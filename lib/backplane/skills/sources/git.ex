defmodule Backplane.Skills.Sources.Git do
  @moduledoc """
  Git-sourced skills. Clones/pulls repo and discovers .md files with frontmatter.
  """

  @behaviour Backplane.Skills.Source

  alias Backplane.Skills.Loader

  defstruct [:name, :repo, :path, ref: "main"]

  @clone_base "/tmp/backplane_skills"

  @impl true
  @spec list() :: {:ok, [Backplane.Skills.Source.skill_entry()]} | {:error, term()}
  def list do
    list(%__MODULE__{})
  end

  def list(%__MODULE__{name: name, repo: repo, path: subdir, ref: ref}) do
    clone_dir = Path.join(@clone_base, name || "default")

    with :ok <- ensure_clone(repo, clone_dir, ref) do
      scan_dir = if subdir, do: Path.join(clone_dir, subdir), else: clone_dir
      source_label = "git:#{name}"

      if File.dir?(scan_dir) do
        entries =
          scan_dir
          |> File.ls!()
          |> Enum.filter(&String.ends_with?(&1, ".md"))
          |> Enum.map(&Path.join(scan_dir, &1))
          |> Enum.filter(&File.regular?/1)
          |> Enum.flat_map(&parse_skill_file(&1, source_label))

        {:ok, entries}
      else
        {:ok, []}
      end
    end
  end

  defp parse_skill_file(filepath, source_label) do
    content = File.read!(filepath)
    skill_name = filepath |> Path.basename() |> Path.rootname()

    case Loader.parse(content) do
      {:ok, entry} ->
        [Map.merge(entry, %{id: "#{source_label}/#{skill_name}", source: source_label})]

      {:error, _} ->
        []
    end
  end

  @impl true
  @spec fetch(String.t()) :: {:ok, Backplane.Skills.Source.skill_entry()} | {:error, term()}
  def fetch(skill_id) do
    fetch(%__MODULE__{}, skill_id)
  end

  def fetch(%__MODULE__{} = config, skill_id) do
    with {:ok, entries} <- list(config),
         entry when not is_nil(entry) <- Enum.find(entries, fn e -> e.id == skill_id end) do
      {:ok, entry}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp ensure_clone(repo, clone_dir, ref) do
    if File.dir?(Path.join(clone_dir, ".git")) do
      pull(clone_dir, ref)
    else
      clone(repo, clone_dir, ref)
    end
  end

  defp clone(repo, clone_dir, ref) do
    File.mkdir_p!(Path.dirname(clone_dir))

    case System.cmd("git", ["clone", "--depth", "1", "--branch", ref, repo, clone_dir],
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      {output, _} -> {:error, {:clone_failed, output}}
    end
  end

  defp pull(clone_dir, _ref) do
    case System.cmd("git", ["pull", "--ff-only"], cd: clone_dir, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, _} -> {:error, {:pull_failed, output}}
    end
  end
end
