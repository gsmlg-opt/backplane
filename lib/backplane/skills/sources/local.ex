defmodule Backplane.Skills.Sources.Local do
  @moduledoc """
  Local filesystem skill source. Reads .md files from a configured directory.
  """

  @behaviour Backplane.Skills.Source

  alias Backplane.Skills.Loader

  defstruct [:name, :path]

  @impl true
  @spec list() :: {:ok, [Backplane.Skills.Source.skill_entry()]} | {:error, term()}
  def list do
    case get_config() do
      nil -> {:ok, []}
      config -> list(config)
    end
  end

  def list(%__MODULE__{path: nil}), do: {:ok, []}

  def list(%__MODULE__{name: name, path: path}) do
    if File.dir?(path) do
      source_label = if name, do: "local:#{name}", else: "local"

      entries =
        path
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.map(&Path.join(path, &1))
        |> Enum.filter(&File.regular?/1)
        |> Enum.flat_map(&parse_skill_file(&1, source_label))

      {:ok, entries}
    else
      {:error, :directory_not_found}
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
    case get_config() do
      nil -> {:error, :not_configured}
      config -> fetch(config, skill_id)
    end
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

  defp get_config do
    case Application.get_env(:backplane, :local_skills) do
      %{path: path} = cfg ->
        %__MODULE__{name: Map.get(cfg, :name), path: path}

      _ ->
        nil
    end
  end
end
