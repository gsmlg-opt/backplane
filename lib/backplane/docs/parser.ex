defmodule Backplane.Docs.Parser do
  @moduledoc """
  Behaviour for documentation parsers.

  Each parser implementation extracts structured chunks from source files.
  A chunk map has the shape:
    %{source_path: String.t(), module: String.t() | nil, function: String.t() | nil,
      chunk_type: String.t(), content: String.t()}
  """

  @type chunk_map :: %{
          source_path: String.t(),
          module: String.t() | nil,
          function: String.t() | nil,
          chunk_type: String.t(),
          content: String.t()
        }

  @callback parse(content :: String.t(), source_path :: String.t()) ::
              {:ok, [chunk_map()]} | {:error, term()}

  @doc """
  Select the appropriate parser for a given file path based on extension.
  """
  def parser_for(path) do
    case Path.extname(path) do
      ext when ext in [".ex", ".exs"] -> Backplane.Docs.Parsers.Elixir
      ".md" -> Backplane.Docs.Parsers.Markdown
      ext when ext in [".html", ".htm"] -> Backplane.Docs.Parsers.HexDocs
      _ -> Backplane.Docs.Parsers.Generic
    end
  end
end
