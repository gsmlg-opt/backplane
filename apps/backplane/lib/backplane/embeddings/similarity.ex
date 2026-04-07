defmodule Backplane.Embeddings.Similarity do
  @moduledoc """
  Shared cosine similarity and embedding reranking utilities.
  Used by both Docs.Search and Skills.Search for semantic reranking.
  """

  @tsvector_weight 0.7
  @cosine_weight 0.3

  def tsvector_weight, do: @tsvector_weight
  def cosine_weight, do: @cosine_weight

  @doc "Compute cosine similarity between two vectors."
  @spec cosine_similarity([float()], [float()]) :: float()
  def cosine_similarity(a, b) when is_list(a) and is_list(b) and length(a) == length(b) do
    dot = Enum.zip(a, b) |> Enum.reduce(0.0, fn {x, y}, acc -> acc + x * y end)
    mag_a = :math.sqrt(Enum.reduce(a, 0.0, fn x, acc -> acc + x * x end))
    mag_b = :math.sqrt(Enum.reduce(b, 0.0, fn x, acc -> acc + x * x end))

    if mag_a == 0.0 or mag_b == 0.0, do: 0.0, else: dot / (mag_a * mag_b)
  end

  def cosine_similarity(_, _), do: 0.0

  @doc "Convert an embedding value (Pgvector struct or list) to a plain list."
  @spec embedding_to_list(term()) :: [float()]
  def embedding_to_list(%Pgvector{} = v), do: Pgvector.to_list(v)
  def embedding_to_list(v) when is_list(v), do: v
  def embedding_to_list(_), do: []
end
