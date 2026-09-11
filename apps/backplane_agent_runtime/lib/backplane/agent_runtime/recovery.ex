defmodule Backplane.AgentRuntime.Recovery do
  alias Backplane.AgentRuntime.Error

  @moduledoc """
  Conservative recovery classification for committed nonterminal work.

  Old incarnations are fenced. Unknown or externally mutated work is never
  resumed automatically; explicitly read-only or idempotent effects can resume
  only when their recorded dispatch evidence is consistent.
  """

  @type t :: map()

  @spec recover(map(), map()) :: {:ok, t()} | {:error, Error.t()}
  def recover(record, opts) when is_map(record) and is_map(opts) do
    incarnation = Map.get(opts, :incarnation)

    if is_integer(incarnation) and incarnation > Map.get(record, :incarnation, 0) do
      effects = classify_effects(Map.get(record, :effects, []))

      {:ok,
       %{
         run_id: Map.get(record, :run_id),
         incarnation: incarnation,
         fenced_incarnation: Map.get(record, :incarnation, 0),
         effects: effects,
         uncertain_effects: uncertain_effects(effects)
       }}
    else
      {:error, Error.new(:forbidden, "recovery incarnation must fence an older executor")}
    end
  end

  def recover(_record, _opts) do
    {:error, Error.new(:validation, "invalid recovery record")}
  end

  defp classify_effects(effects) when is_list(effects) do
    Enum.map(effects, fn effect ->
      case {Map.get(effect, :effect_id), Map.get(effect, :class), Map.get(effect, :dispatch)} do
        {effect_id, class, dispatch}
        when is_binary(effect_id) and class in [:read_only, :idempotent, :mutation] and
               is_map(dispatch) ->
          state = normalize_dispatch(dispatch)

          %{
            effect_id: effect_id,
            class: class,
            dispatch_state: state,
            safe_to_resume?: safe_to_resume?(class, state),
            outcome: Map.get(effect, :outcome, :unknown)
          }

        _ ->
          %{
            effect_id: nil,
            class: :unknown,
            dispatch_state: :unknown,
            safe_to_resume?: false,
            outcome: :unknown
          }
      end
    end)
  end

  defp classify_effects(_effects) do
    [
      %{
        effect_id: nil,
        class: :unknown,
        dispatch_state: :unknown,
        safe_to_resume?: false,
        outcome: :unknown
      }
    ]
  end

  defp normalize_dispatch(%{state: state}) when state in [:not_dispatched, :dispatched, :unknown],
    do: state

  defp normalize_dispatch(_), do: :unknown

  defp safe_to_resume?(_class, :dispatched), do: false
  defp safe_to_resume?(class, :not_dispatched), do: class in [:read_only, :idempotent]
  defp safe_to_resume?(_, _), do: false

  defp uncertain_effects(effects) do
    for effect <- effects, effect.outcome == :unknown do
      effect
    end
  end
end
