defmodule Backplane.Docs.Parsers.Generic do
  @moduledoc """
  Fallback parser for files without a specialized parser.

  Splits content on blank-line-separated paragraphs.
  """

  @behaviour Backplane.Docs.Parser

  @impl true
  @spec parse(String.t(), String.t()) :: {:ok, [Backplane.Docs.Parser.chunk_map()]}
  def parse(content, source_path) do
    chunks =
      content
      |> String.split(~r/\n\s*\n/, trim: true)
      |> Enum.map(fn paragraph ->
        %{
          source_path: source_path,
          module: nil,
          function: nil,
          chunk_type: "code",
          content: String.trim(paragraph)
        }
      end)
      |> Enum.reject(fn chunk -> chunk.content == "" end)

    {:ok, chunks}
  end
end
