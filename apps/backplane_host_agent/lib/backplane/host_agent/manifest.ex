defmodule Backplane.HostAgent.Manifest do
  @moduledoc """
  Reads and writes the host agent skill manifest.
  """

  defstruct schema_version: 1,
            machine_name: nil,
            updated_at: nil,
            skills: []

  def read(path, machine_name) do
    manifest =
      if File.exists?(path) do
        path
        |> File.read!()
        |> Jason.decode!()
        |> parse(machine_name)
      else
        %__MODULE__{machine_name: machine_name}
      end

    {:ok, manifest}
  end

  def write(path, %__MODULE__{} = manifest) do
    path
    |> Path.dirname()
    |> File.mkdir_p!()

    tmp_path = "#{path}.#{System.unique_integer([:positive])}.tmp"

    File.write!(tmp_path, Jason.encode!(to_json(manifest)))
    File.rename!(tmp_path, path)

    :ok
  end

  defp parse(raw, machine_name) do
    %__MODULE__{
      schema_version: raw["schema_version"] || 1,
      machine_name: raw["machine_name"] || machine_name,
      updated_at: raw["updated_at"],
      skills: parse_skills(raw["skills"] || [])
    }
  end

  defp parse_skills(skills) when is_list(skills) do
    Enum.map(skills, fn skill ->
      %{
        name: skill["name"],
        slug: skill["slug"],
        version: skill["version"],
        checksum: skill["checksum"],
        targets: skill["targets"] || [],
        owned: skill["owned"] != false,
        installed_at: skill["installed_at"]
      }
    end)
  end

  defp parse_skills(_skills), do: []

  defp to_json(%__MODULE__{} = manifest) do
    %{
      schema_version: manifest.schema_version,
      machine_name: manifest.machine_name,
      updated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      skills: manifest.skills
    }
  end
end
