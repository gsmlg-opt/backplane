defmodule Backplane.AiProtocol.TranslationPlan do
  @moduledoc """
  Pure preflight translation plan.

  Produces an executable plan or structured refusal without any request-emission side effects.
  """

  defstruct [:request, executable: true, diagnostics: [], downgrades: []]

  @type diagnostic :: map()

  @type t :: %__MODULE__{
          request: Backplane.AiProtocol.Request.t(),
          executable: boolean(),
          diagnostics: [diagnostic()],
          downgrades: [String.t()]
        }
end
