defmodule Backplane.SkillProtocol.Descriptor do
  @moduledoc "Lightweight discovery result; it is not proof of bundle verification."

  alias Backplane.SkillProtocol.SkillRef

  @enforce_keys [:ref, :name, :path, :precedence]
  defstruct [
    :ref,
    :name,
    :description,
    :argument_hint,
    :disable_model_invocation,
    :path,
    :revision,
    :artifact_digest,
    :publication_status,
    :precedence
  ]

  @type t :: %__MODULE__{
          ref: SkillRef.t(),
          name: String.t(),
          argument_hint: String.t() | nil,
          path: String.t(),
          precedence: integer()
        }
end
