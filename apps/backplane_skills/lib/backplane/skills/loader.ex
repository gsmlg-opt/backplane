defmodule Backplane.Skills.Loader do
  @moduledoc """
  Parses SKILL.md files — YAML frontmatter + markdown body.
  """

  require Logger

  alias Backplane.SkillProtocol.{Parser, Validator}

  @doc """
  Parse a SKILL.md file's content into a skill entry map.
  Returns {:ok, map} or {:error, reason}.
  """
  @spec parse(String.t()) :: {:ok, map()} | {:error, atom()}
  def parse(content) when is_binary(content) do
    with {:ok, document} <- Parser.parse(content),
         {:ok, document} <- Validator.validate(document, profile: :legacy) do
      build_entry(document.metadata, String.trim(document.body_raw))
    else
      {:error, %{code: code}} -> {:error, legacy_error(code)}
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
        tools: normalize_list(Map.get(meta, "tools", [])),
        model: optional_string(Map.get(meta, "model")),
        version: version_string(Map.get(meta, "version", "1.0.0")),
        license: optional_string(Map.get(meta, "license")),
        homepage: optional_string(Map.get(meta, "homepage")),
        author: optional_string(Map.get(meta, "author")),
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
            [Map.merge(entry, %{id: "#{source_label}/#{skill_name}", source: source_label})]

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

  defp optional_string(value) when is_binary(value), do: value
  defp optional_string(_), do: nil

  defp version_string(nil), do: "1.0.0"
  defp version_string(value), do: to_string(value)

  defp legacy_error(code) when code in [:missing_frontmatter, :missing_name, :invalid_document],
    do: :missing_frontmatter

  defp legacy_error(_code), do: :malformed_frontmatter
end
