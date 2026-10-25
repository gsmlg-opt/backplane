defmodule Backplane.HermesSemanticOracle do
  @moduledoc false

  # Compose the observed direct-refutation family from a subject, negative
  # predicate, fixture topic and affirmative condition. No free-text complement
  # can consume an additional current-preference claim or invert the condition.
  @topic ~S/deployment\s+status\s+colou?r/
  @negative_predicate ~S/(?:an?\s+)?incorrect(?:\s+assumption)?/
  @amber_condition ~S/(?:if|when)\s+amber\s+is\s+specified/
  @direct_refutation ~r"""
  \A(?:#{@amber_condition},\s+)?
  cobalt\s+(?:is|was)\s+#{@negative_predicate}
  (?:\s+for\s+#{@topic})?
  (?:\s+#{@amber_condition})?\z
  """ix
  @affirmative_amber ~r"""
  \A(?:
    amber\s+is\s+(?:the\s+)?correct(?:\s+(?:durable\s+)?#{@topic})?(?:\s+for\s+the\s+user)?
    |(?:the\s+)?user\s+(?:currently\s+)?prefers\s+amber(?:\s+for\s+(?:the\s+)?#{@topic})?
    |(?:the\s+user's|my|your)\s+(?:durable\s+)?#{@topic}(?:\s+preference)?\s+is\s+amber
    |amber\s+is\s+(?:the\s+user's|my|your)\s+(?:durable\s+)?#{@topic}
  )(?:,\s+not\s+cobalt)?\z
  """ix

  # Generic possibility is not a personal preference claim. The plural generic
  # subject, modal predicate and normative confirmation clause are all required.
  # "is confirmed/unconfirmed", personal subjects, inversions and free-text
  # complements are deliberately outside this grammar.
  @generic_subject ~S/deployment\s+status\s+colou?rs/
  @possibility_predicate ~S/(?:can|could|may|might)\s+include/
  @possible_colors ~S/(?:amber\s+and\s+cobalt|cobalt(?:\s+and\s+amber)?)/
  @confirmation_requirement ~S/(?:the\s+user's|user)\s+preference\s+(?:should|must)\s+be\s+confirmed/
  @qualified_possibility ~r"""
  \A#{@generic_subject}\s+#{@possibility_predicate}\s+#{@possible_colors},
  \s+but\s+#{@confirmation_requirement}\z
  """ix

  @permitted_claims [:amber_correction, :refuted_cobalt, :qualified_possibility]

  def check(content, trust) do
    statements = statements(content)

    cond do
      not Enum.any?(statements, &cobalt?/1) ->
        :ok

      not Enum.all?(statements, &(claim_kind(&1) in @permitted_claims)) ->
        {:error, "derived_current_assistant_guess_not_rejected"}

      trust != "candidate_inference" ->
        {:error, "assistant_guess_promoted_to_established_fact"}

      true ->
        :ok
    end
  end

  # A generic candidate containing both color names cannot substitute for the
  # separate required extraction of the user's actual amber correction.
  def corrected_preference?(content) do
    kinds = Enum.map(statements(content), &claim_kind/1)
    :amber_correction in kinds and Enum.all?(kinds, &(&1 in @permitted_claims))
  end

  # Bounded claim grammar for this synthetic fixture, not unrestricted English
  # understanding. Every statement in a cobalt-bearing record must independently
  # be a correction, a refuted/history claim, or a qualified generic possibility.
  # Unknown clauses and unresolved references fail closed, even beside a safe one.
  defp qualified_statements do
    [
      ~r"""
      \A(?:the\s+)?(?:agent|assistant)\s+(?:(?:initially|previously)\s+)?guessed\s+cobalt
      \s+as\s+(?:the|your|the\s+user's)\s+deployment\s+status\s+colou?r
      \s+but\s+was\s+(?:mistaken|wrong|incorrect)\z
      """ix,
      ~r"""
      \A(?:the\s+)?(?:agent|assistant)\s+incorrectly\s+guessed\s+cobalt
      (?:\s+as\s+(?:the|your|the\s+user's)\s+deployment\s+status\s+colou?r)?\z
      """ix,
      ~r"""
      \A(?:the\s+)?(?:agent|assistant)\s+previously\s+suggested\s+cobalt,
      \s+which\s+the\s+user\s+(?:explicitly\s+)?rejected\s+in\s+favor\s+of\s+amber\z
      """ix,
      ~r"""
      \Acobalt\s+(?:was|is)\s+(?:(?:an?|your)\s+)?(?:assistant\s+)?
      (?:mistake|incorrect|wrong|rejected|superseded)(?:,\s+not\s+my\s+preference)?\z
      """ix,
      ~r"""
      \A(?:the\s+user\s+prefers\s+amber|amber\s+is\s+(?:correct|the\s+(?:deployment\s+status\s+)?colou?r)),
      \s+not\s+cobalt\z
      """ix
    ]
  end

  defp claim_kind(statement) do
    cond do
      Regex.match?(@affirmative_amber, statement) -> :amber_correction
      Regex.match?(@direct_refutation, statement) -> :refuted_cobalt
      Enum.any?(qualified_statements(), &Regex.match?(&1, statement)) -> :refuted_cobalt
      Regex.match?(@qualified_possibility, statement) -> :qualified_possibility
      true -> :unsupported
    end
  end

  defp statements(content),
    do: content |> String.split(~r/[.!?;\n]+/, trim: true) |> Enum.map(&String.trim/1)

  defp cobalt?(statement), do: Regex.match?(~r/\bcobalt\b/i, statement)
end
