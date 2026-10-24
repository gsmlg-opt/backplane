defmodule Backplane.Memory.Recall.Relevance do
  @moduledoc "Model-bound raw relevance rejection with lexical fallback; fusion scores are never probabilities."

  def policy_version, do: "recall_relevance.v1"

  def apply(traces, query, embedding_model, reranker_model, calibration) do
    Enum.map(traces, fn trace ->
      if trace.selected and
           not accepted?(
             query,
             trace.candidate.content,
             trace.scores,
             embedding_model,
             reranker_model,
             calibration
           ) do
        %{trace | selected: false, rejection_reason: "below_threshold"}
      else
        trace
      end
    end)
  end

  def accepted?(query, content, scores, embedding_model, reranker_model, calibration) do
    lexical?(query, content, scores) or
      semantic?(scores, embedding_model, reranker_model, calibration)
  end

  defp lexical?(query, content, scores) do
    query = query |> String.trim() |> String.downcase()
    fts = Map.get(scores, :fts)

    (is_number(fts) and fts > 0) or
      (query != "" and String.contains?(String.downcase(content), query))
  end

  defp semantic?(scores, embedding_model, reranker_model, calibration) do
    reranker = Map.get(scores, :reranker)

    if concrete_reranker_model?(reranker_model) and
         calibrated?(
           reranker,
           reranker_model,
           calibration.reranker_model,
           calibration.reranker_min,
           0.0
         ) do
      reranker >= calibration.reranker_min
    else
      vector = Map.get(scores, :vector)

      calibrated?(vector, embedding_model, calibration.vector_model, calibration.vector_min, -1.0) and
        vector >= calibration.vector_min
    end
  end

  # ModelResolver treats provider/raw_model as a direct route. Unprefixed aliases
  # can retarget without changing their selector, so their scores are uncalibrated.
  defp concrete_reranker_model?(model) when is_binary(model) do
    case String.split(model, "/", parts: 2) do
      [provider, raw] -> raw != "" and Regex.match?(~r/^[a-z0-9][a-z0-9-]*$/, provider)
      _ -> false
    end
  end

  defp concrete_reranker_model?(_model), do: false

  defp calibrated?(score, model, calibrated_model, minimum, lower) do
    is_binary(model) and model != "" and model == calibrated_model and
      is_number(score) and score >= lower and score <= 1 and
      is_number(minimum) and minimum >= lower and minimum <= 1
  end
end
