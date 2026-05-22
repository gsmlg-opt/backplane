defmodule Backplane.HostAgent.Manifest do
  @moduledoc """
  Reads and writes the host agent skill manifest.
  """

  defstruct schema_version: 1,
            machine_name: nil,
            updated_at: nil,
            skills: []

  def read(path, machine_name) do
    if File.exists?(path) do
      with {:ok, contents} <- File.read(path),
           {:ok, raw} <- Jason.decode(contents),
           {:ok, manifest} <- parse(raw, machine_name) do
        {:ok, manifest}
      else
        {:error, %Jason.DecodeError{} = error} ->
          manifest_read_error(Exception.message(error))

        {:error, {:manifest_read_error, _message}} = error ->
          error

        {:error, reason} ->
          manifest_read_error("could not read manifest: #{inspect(reason)}")
      end
    else
      {:ok, %__MODULE__{machine_name: machine_name}}
    end
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

  defp parse(raw, machine_name) when is_map(raw) do
    with {:ok, skills} <- parse_skills(Map.get(raw, "skills", [])) do
      {:ok,
       %__MODULE__{
         schema_version: Map.get(raw, "schema_version") || 1,
         machine_name: Map.get(raw, "machine_name") || machine_name,
         updated_at: Map.get(raw, "updated_at"),
         skills: skills
       }}
    end
  end

  defp parse(_raw, _machine_name), do: manifest_read_error("manifest must be a JSON object")

  defp parse_skills(skills) when is_list(skills) do
    skills
    |> Enum.reduce_while({:ok, []}, fn
      skill, {:ok, parsed} when is_map(skill) ->
        {:cont, {:ok, [parse_skill(skill) | parsed]}}

      _skill, {:ok, _parsed} ->
        {:halt, manifest_read_error("manifest skills must be JSON objects")}
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      {:error, {:manifest_read_error, _message}} = error -> error
    end
  end

  defp parse_skills(_skills), do: manifest_read_error("manifest skills must be a list")

  defp parse_skill(skill) do
    %{
      name: Map.get(skill, "name"),
      slug: Map.get(skill, "slug"),
      version: Map.get(skill, "version"),
      checksum: Map.get(skill, "checksum"),
      targets: Map.get(skill, "targets") || [],
      owned: Map.get(skill, "owned") != false,
      installed_at: Map.get(skill, "installed_at")
    }
  end

  defp to_json(%__MODULE__{} = manifest) do
    %{
      schema_version: manifest.schema_version,
      machine_name: manifest.machine_name,
      updated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      skills: manifest.skills
    }
  end

  defp manifest_read_error(message), do: {:error, {:manifest_read_error, message}}
end
