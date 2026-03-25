defmodule Backplane.Docs.Parsers.Markdown do
  @moduledoc """
  Parser for Markdown (.md) files.

  Splits on ## headings into chunks, with ### sub-sections within.
  """

  @behaviour Backplane.Docs.Parser

  @impl true
  def parse(content, source_path) do
    chunks = split_by_headings(content, source_path)
    {:ok, chunks}
  end

  defp split_by_headings(content, source_path) do
    lines = String.split(content, "\n")

    case find_first_heading(lines) do
      nil ->
        # No headings at all: single chunk
        trimmed = String.trim(content)

        if trimmed == "" do
          []
        else
          [
            %{
              source_path: source_path,
              module: nil,
              function: nil,
              chunk_type: "guide",
              content: trimmed
            }
          ]
        end

      _ ->
        build_sections(lines, source_path)
    end
  end

  defp find_first_heading(lines) do
    Enum.find(lines, fn line ->
      String.starts_with?(String.trim(line), "## ") or
        String.starts_with?(String.trim(line), "# ")
    end)
  end

  defp build_sections(lines, source_path) do
    {sections, current} = Enum.reduce(lines, {[], nil}, &classify_line/2)
    sections = maybe_finalize(sections, current)

    sections
    |> Enum.reverse()
    |> Enum.map(&section_to_chunk(&1, source_path))
    |> Enum.reject(fn chunk -> chunk.content == "" end)
  end

  defp classify_line(line, {sections, current}) do
    trimmed = String.trim(line)

    cond do
      heading_level_2?(trimmed) ->
        heading = String.trim_leading(trimmed, "## ")
        {maybe_finalize(sections, current), %{heading: heading, lines: []}}

      heading_level_1?(trimmed) ->
        heading = String.trim_leading(trimmed, "# ")
        {maybe_finalize(sections, current), %{heading: heading, lines: []}}

      current != nil ->
        {sections, %{current | lines: [line | current.lines]}}

      sections == [] ->
        {sections, %{heading: nil, lines: [line]}}

      true ->
        {sections, current}
    end
  end

  defp heading_level_2?(line),
    do: String.starts_with?(line, "## ") and not String.starts_with?(line, "### ")

  defp heading_level_1?(line),
    do: String.starts_with?(line, "# ") and not String.starts_with?(line, "##")

  defp section_to_chunk(section, source_path) do
    body = section.lines |> Enum.reverse() |> Enum.join("\n") |> String.trim()

    content =
      if section.heading,
        do: "## #{section.heading}\n\n#{body}",
        else: body

    %{
      source_path: source_path,
      module: nil,
      function: nil,
      chunk_type: "guide",
      content: String.trim(content)
    }
  end

  defp maybe_finalize(sections, nil), do: sections

  defp maybe_finalize(sections, current) do
    [current | sections]
  end
end
