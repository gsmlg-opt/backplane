defmodule Backplane.Skills.Sources.Git do
  @moduledoc """
  Git-sourced skills. Clones/pulls repo and discovers .md files with frontmatter.
  """

  @behaviour Backplane.Skills.Source

  alias Backplane.Skills.Loader

  defstruct [:name, :repo, :path, ref: "main"]

  @clone_base "/tmp/backplane_skills"

  @impl true
  def list do
    list(%__MODULE__{})
  end

  def list(%__MODULE__{name: name, repo: repo, path: subdir, ref: ref}) do
    clone_dir = Path.join(@clone_base, name || "default")

    with :ok <- ensure_clone(repo, clone_dir, ref) do
      scan_dir = if subdir, do: Path.join(clone_dir, subdir), else: clone_dir

      if File.dir?(scan_dir) do
        entries =
          scan_dir
          |> File.ls!()
          |> Enum.filter(&String.ends_with?(&1, ".md"))
          |> Enum.flat_map(fn filename ->
            filepath = Path.join(scan_dir, filename)

            if File.regular?(filepath) do
              content = File.read!(filepath)

              case Loader.parse(content) do
                {:ok, entry} ->
                  skill_name = Path.rootname(filename)
                  source_label = "git:#{name}"

                  [
                    Map.merge(entry, %{
                      id: "#{source_label}/#{skill_name}",
                      source: source_label
                    })
                  ]

                {:error, _} ->
                  []
              end
            else
              []
            end
          end)

        {:ok, entries}
      else
        {:ok, []}
      end
    end
  end

  @impl true
  def fetch(skill_id) do
    fetch(%__MODULE__{}, skill_id)
  end

  def fetch(%__MODULE__{} = config, skill_id) do
    case list(config) do
      {:ok, entries} ->
        case Enum.find(entries, fn e -> e.id == skill_id end) do
          nil -> {:error, :not_found}
          entry -> {:ok, entry}
        end

      error ->
        error
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
