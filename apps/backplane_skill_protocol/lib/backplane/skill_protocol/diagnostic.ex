defmodule Backplane.SkillProtocol.Diagnostic do
  @moduledoc "A bounded validation or compatibility diagnostic."

  @enforce_keys [:code, :phase, :severity, :message]
  defstruct [:code, :phase, :severity, :message, context: %{}]

  @type t :: %__MODULE__{
          code: atom(),
          phase: atom(),
          severity: :error | :warning,
          message: String.t(),
          context: map()
        }

  def new(code, phase, severity, message, context \\ %{}) do
    %__MODULE__{
      code: code,
      phase: phase,
      severity: severity,
      message: String.slice(message, 0, 512),
      context: context
    }
  end
end
