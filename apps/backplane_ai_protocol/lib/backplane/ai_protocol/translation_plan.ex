defmodule Backplane.AiProtocol.TranslationPlan do
  @moduledoc """
  Pure preflight translation plan.

  Produces an executable plan or structured refusal without any request-emission side effects.
  """

  defstruct [
    :request,
    :source,
    :target,
    executable: true,
    diagnostics: [],
    downgrades: [],
    operations: []
  ]

  @type diagnostic :: map()

  @type t :: %__MODULE__{
          request: Backplane.AiProtocol.Request.t(),
          executable: boolean(),
          diagnostics: [diagnostic()],
          downgrades: [String.t()],
          operations: [map()],
          source: map() | nil,
          target: map() | nil
        }
end
