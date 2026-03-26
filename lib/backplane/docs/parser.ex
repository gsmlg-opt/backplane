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

  alias Backplane.Docs.Parsers.Elixir, as: ElixirParser
  alias Backplane.Docs.Parsers.{Generic, HexDocs, Markdown}

  @callback parse(content :: String.t(), source_path :: String.t()) ::
              {:ok, [chunk_map()]} | {:error, term()}

  @doc """
  Select the appropriate parser for a given file path based on extension.
  """
  def parser_for(path) do
    case Path.extname(path) do
      ext when ext in [".ex", ".exs"] -> ElixirParser
      ".md" -> Markdown
      ext when ext in [".html", ".htm"] -> HexDocs
      _ -> Generic
    end
  end
end
