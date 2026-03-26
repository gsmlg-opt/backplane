defmodule Backplane.Skills.Loader do
  @moduledoc """
  Parses SKILL.md files — YAML frontmatter + markdown body.
  """

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
    case meta do
      %{"name" => name} when is_binary(name) and name != "" ->
        hash = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

        entry = %{
          name: name,
          description: Map.get(meta, "description", ""),
          tags: normalize_list(Map.get(meta, "tags", [])),
          tools: normalize_list(Map.get(meta, "tools", [])),
          model: Map.get(meta, "model"),
          version: to_string(Map.get(meta, "version", "1.0.0")),
          content: body,
          content_hash: hash
        }

        {:ok, entry}

      _ ->
        {:error, :missing_frontmatter}
    end
  end

  @doc """
  Parse a skill file from disk, returning a list with one entry or empty on error.
  Used by file-based sources (Local, Git) to convert .md files into skill entries.
  """
  @spec parse_skill_file(String.t(), String.t()) :: [map()]
  def parse_skill_file(filepath, source_label) do
    content = File.read!(filepath)
    skill_name = filepath |> Path.basename() |> Path.rootname()

    case parse(content) do
      {:ok, entry} ->
        [Map.merge(entry, %{id: "#{source_label}/#{skill_name}", source: source_label})]

      {:error, _} ->
        []
    end
  end

  defp normalize_list(list) when is_list(list), do: Enum.map(list, &to_string/1)
  defp normalize_list(_), do: []
end
