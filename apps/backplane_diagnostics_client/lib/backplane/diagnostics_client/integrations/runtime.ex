defmodule Backplane.DiagnosticsClient.Integrations.Runtime do
  @moduledoc "Maps an optional Runtime observer's typed errors before the original cause is discarded."

  alias Backplane.DiagnosticsClient.Integrations.Capture

  @expected ~w(validation forbidden approval_required not_found cancelled budget_exceeded)a

  def error(%{class: class}, _boundary) when class in @expected, do: :ignored

  def error(%{class: class, cause: cause}, boundary) when is_atom(class) do
    {reason, frames} =
      case cause do
        {reason, stack} when is_list(stack) -> {reason, stack}
        nil -> {class, []}
        reason -> {reason, []}
      end

    error_class =
      case class do
        value when value in [:timeout, :transient_transport, :unknown_outcome] ->
          "upstream_failure"

        :overloaded ->
          "environment_failure"

        :unsupported_capability ->
          "configuration_or_compatibility"

        _ ->
          "software_defect"
      end

    Capture.report("handled_error", :error, reason, frames,
      code: Atom.to_string(class),
      phase: boundary,
      error_class: error_class
    )
  end

  def error(_, _), do: :ignored
end
