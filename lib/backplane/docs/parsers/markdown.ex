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
    {sections, current} =
      Enum.reduce(lines, {[], nil}, fn line, {sections, current} ->
        trimmed = String.trim(line)

        cond do
          # ## heading starts a new section
          String.starts_with?(trimmed, "## ") and not String.starts_with?(trimmed, "### ") ->
            heading = String.trim_leading(trimmed, "## ")
            sections = maybe_finalize(sections, current)
            {sections, %{heading: heading, lines: []}}

          # # top-level heading also starts a section
          String.starts_with?(trimmed, "# ") and not String.starts_with?(trimmed, "##") ->
            heading = String.trim_leading(trimmed, "# ")
            sections = maybe_finalize(sections, current)
            {sections, %{heading: heading, lines: []}}

          # Content lines
          current != nil ->
            {sections, %{current | lines: [line | current.lines]}}

          # Lines before first heading — collect as preamble
          true ->
            case sections do
              [] ->
                {sections, %{heading: nil, lines: [line]}}

              _ ->
                {sections, current}
            end
        end
      end)

    sections = maybe_finalize(sections, current)

    sections
    |> Enum.reverse()
    |> Enum.map(fn section ->
      content_lines = Enum.reverse(section.lines)
      body = Enum.join(content_lines, "\n") |> String.trim()

      content =
        if section.heading do
          "## #{section.heading}\n\n#{body}"
        else
          body
        end

      %{
        source_path: source_path,
        module: nil,
        function: nil,
        chunk_type: "guide",
        content: String.trim(content)
      }
    end)
    |> Enum.reject(fn chunk -> chunk.content == "" end)
  end

  defp maybe_finalize(sections, nil), do: sections

  defp maybe_finalize(sections, current) do
    [current | sections]
  end
end
