defmodule Backplane.SkillProtocol.Eligibility do
  @moduledoc "Pure trigger and host-policy eligibility; it grants no tool authority."

  alias Backplane.SkillProtocol.{Descriptor, Document, Error}

  @type trigger :: :automatic | :explicit

  @spec evaluate(Document.t() | Descriptor.t(), trigger(), map()) ::
          {:ok, :eligible} | {:error, Error.t()}
  def evaluate(%Document{} = document, trigger, policy) when trigger in [:automatic, :explicit] do
    manual_only = document.metadata["disable-model-invocation"] == true
    user_invocable = Map.get(document.metadata, "user-invocable", true)
    evaluate_flags(trigger, policy, manual_only, user_invocable)
  end

  def evaluate(%Descriptor{} = descriptor, trigger, policy)
      when trigger in [:automatic, :explicit] do
    evaluate_flags(
      trigger,
      policy,
      descriptor.disable_model_invocation == true,
      descriptor.user_invocable != false
    )
  end

  def evaluate(_document, _trigger, _policy),
    do:
      denied(
        :invalid_request,
        "eligibility requires a document or descriptor, trigger, and policy"
      )

  defp evaluate_flags(trigger, policy, manual_only, user_invocable) do
    enabled = Map.get(policy, :enabled, Map.get(policy, "enabled", true))
    allow_explicit = Map.get(policy, :allow_explicit, Map.get(policy, "allow_explicit", true))

    cond do
      enabled != true ->
        denied(:host_disabled, "skill is disabled by host policy")

      trigger == :automatic and manual_only ->
        denied(:manual_only, "skill requires explicit selection")

      trigger == :explicit and allow_explicit != true ->
        denied(:explicit_disabled, "explicit selection is disabled by host policy")

      trigger == :explicit and user_invocable != true ->
        denied(:not_user_invocable, "skill does not permit explicit user invocation")

      true ->
        {:ok, :eligible}
    end
  end

  defp denied(code, message), do: {:error, Error.new(code, :eligibility, message)}
end
