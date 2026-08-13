defmodule Backplane.Memory.Memories.RelationPolicy do
  @moduledoc false

  @automatic_confirmation_confidence 0.9
  @strong_evidence_score 0.8

  def outcome(%{"classification" => "unrelated"}, _source_evidence, _target_evidence),
    do: :reject_noop

  def outcome(attrs, source_evidence, target_evidence) do
    if strong_evidence?(source_evidence) and strong_evidence?(target_evidence) do
      classify(attrs)
    else
      :review
    end
  end

  defp classify(%{
         "classification" => "temporal_replacement",
         "confidence" => confidence,
         "automatic_confirmation" => true
       })
       when confidence >= @automatic_confirmation_confidence,
       do: :confirm

  defp classify(%{"classification" => classification})
       when classification in ~w(duplicate extension temporal_replacement contradiction),
       do: :review

  defp classify(_attrs), do: :reject_noop

  defp strong_evidence?(evidence) do
    typed = Enum.reject(evidence, & &1.source_request_id)
    evidence = if typed == [], do: evidence, else: typed

    Enum.any?(evidence, fn item ->
      item.evidence_kind in ~w(supports derives confirms applies) and
        item.support_score >= @strong_evidence_score
    end)
  end
end
