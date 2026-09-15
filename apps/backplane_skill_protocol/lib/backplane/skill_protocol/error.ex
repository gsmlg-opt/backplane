defmodule Backplane.SkillProtocol.Error do
  @moduledoc "Stable error returned for expected protocol failures."

  @enforce_keys [:code, :phase, :message]
  defstruct [:code, :phase, :message, context: %{}, retryable: false]

  @type t :: %__MODULE__{
          code: atom(),
          phase: atom(),
          message: String.t(),
          context: map(),
          retryable: boolean()
        }

  @spec new(atom(), atom(), String.t(), keyword()) :: t()
  def new(code, phase, message, opts \\ []) do
    %__MODULE__{
      code: code,
      phase: phase,
      message: String.slice(message, 0, 512),
      context: Keyword.get(opts, :context, %{}),
      retryable: Keyword.get(opts, :retryable, false)
    }
  end
end
