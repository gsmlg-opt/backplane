defmodule Backplane.Docs.Chunker do
  @moduledoc """
  Post-processes parsed chunks: computes content hashes,
  estimates token counts, and preserves metadata.
  """

  @min_chunk_size 20

  @doc """
  Process a list of parsed chunk maps, adding content_hash and token estimate.
  Filters out chunks below the minimum size.
  """
  @spec process([map()]) :: [map()]
  def process(chunks) when is_list(chunks) do
    chunks
    |> Enum.filter(fn chunk -> String.length(chunk.content) >= @min_chunk_size end)
    |> Enum.map(&enrich/1)
  end

  defp enrich(chunk) do
    chunk
    |> Map.put(:content_hash, compute_hash(chunk.content))
    |> Map.put(:tokens, estimate_tokens(chunk.content))
  end

  @doc """
  Compute SHA256 hex digest of content.
  """
  @spec compute_hash(String.t()) :: String.t()
  def compute_hash(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

  @doc """
  Estimate token count. Approximation: ~4 characters per token.
  """
  @spec estimate_tokens(String.t()) :: pos_integer()
  def estimate_tokens(content) do
    max(1, div(String.length(content), 4))
  end
end
