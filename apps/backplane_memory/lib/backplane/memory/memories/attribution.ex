defmodule Backplane.Memory.Memories.Attribution do
  @moduledoc false

  def project(metadata) when is_map(metadata) do
    case Map.fetch(metadata, "project") do
      {:ok, project} when is_binary(project) -> project
      {:ok, _non_string} -> ""
      :error -> project_from_atom_key(metadata)
    end
  end

  def project(_metadata), do: ""

  def metadata_without_project(metadata) when is_map(metadata),
    do: Map.drop(metadata, ["project", :project])

  def metadata_without_project(_metadata), do: %{}

  defp project_from_atom_key(metadata) do
    case Map.get(metadata, :project) do
      project when is_binary(project) -> project
      _non_string -> ""
    end
  end
end
