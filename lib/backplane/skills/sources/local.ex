defmodule Backplane.Skills.Sources.Local do
  @moduledoc """
  Local filesystem skill source. Reads .md files from a configured directory.
  """

  @behaviour Backplane.Skills.Source

  alias Backplane.Skills.Loader

  defstruct [:name, :path]

  @impl true
  def list do
    list(%__MODULE__{})
  end

  def list(%__MODULE__{name: name, path: path}) do
    if File.dir?(path) do
      entries =
        path
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.flat_map(fn filename ->
          filepath = Path.join(path, filename)

          if File.regular?(filepath) do
            content = File.read!(filepath)

            case Loader.parse(content) do
              {:ok, entry} ->
                skill_name = Path.rootname(filename)
                source_label = if name, do: "local:#{name}", else: "local"

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
      {:error, :directory_not_found}
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
end
