defmodule Backplane.Skills.Loader do
  @moduledoc """
  Parses SKILL.md files — YAML frontmatter + markdown body.
  """

  require Logger

  @doc """
  Parse a SKILL.md file's content into a skill entry map.
  Returns {:ok, map} or {:error, reason}.
  """
  @spec parse(String.t()) :: {:ok, map()} | {:error, atom()}
  def parse(content) when is_binary(content) do
    case extract_frontmatter(content) do
      {:ok, yaml_str, body} ->
        case YamlElixir.read_from_string(yaml_str) do
          {:ok, meta} when is_map(meta) ->
            build_entry(meta, body)

          {:ok, _} ->
            {:error, :malformed_frontmatter}

          {:error, _} ->
            {:error, :malformed_frontmatter}
        end

      :error ->
        {:error, :missing_frontmatter}
    end
  end

  defp extract_frontmatter(content) do
    case String.split(content, ~r/^---\s*$/m, parts: 3) do
      ["", yaml, body] ->
        {:ok, yaml, String.trim(body)}

      [before, yaml, body] ->
        if String.trim(before) == "" do
          {:ok, yaml, String.trim(body)}
        else
          :error
        end

      _ ->
        :error
    end
  end

  defp build_entry(meta, body) do
    with {:ok, name} <- validate_required_string(meta, "name"),
         {:ok, description} <- validate_optional_string(meta, "description", "") do
      hash = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

      entry = %{
        name: name,
        description: description,
        tags: normalize_list(Map.get(meta, "tags", [])),
        content: body,
        content_hash: hash
      }

      {:ok, entry}
    end
  end

  defp validate_required_string(meta, key) do
    case Map.get(meta, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      nil -> {:error, :missing_frontmatter}
      _ -> {:error, :missing_frontmatter}
    end
  end

  defp validate_optional_string(meta, key, default) do
    case Map.get(meta, key, default) do
      value when is_binary(value) -> {:ok, value}
      _ -> {:ok, default}
    end
  end

  @doc """
  Parse a skill file from disk, returning a list with one entry or empty on error.
  Used by file-based sources (Local, Git) to convert .md files into skill entries.
  """
  @spec parse_skill_file(String.t(), String.t()) :: [map()]
  def parse_skill_file(filepath, source_label) do
    case File.read(filepath) do
      {:ok, content} ->
        skill_name = filepath |> Path.basename() |> Path.rootname()

        case parse(content) do
          {:ok, entry} ->
            [Map.merge(entry, %{id: "#{source_label}/#{skill_name}"})]

          {:error, _} ->
            []
        end

      {:error, reason} ->
        Logger.warning("Failed to read skill file #{filepath}: #{reason}")
        []
    end
  end

  defp normalize_list(list) when is_list(list), do: Enum.map(list, &to_string/1)
  defp normalize_list(_), do: []
end
