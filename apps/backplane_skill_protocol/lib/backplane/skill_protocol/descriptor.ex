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
    :user_invocable,
    :document_digest,
    :path,
    :revision,
    :artifact_digest,
    :publication_status,
    :precedence
  ]

  @type t :: %__MODULE__{
          ref: SkillRef.t(),
          name: String.t(),
          description: String.t() | nil,
          argument_hint: String.t() | nil,
          disable_model_invocation: boolean() | nil,
          user_invocable: boolean() | nil,
          document_digest: String.t() | nil,
          path: String.t() | nil,
          revision: String.t() | nil,
          artifact_digest: String.t() | nil,
          publication_status: String.t() | :local | nil,
          precedence: integer()
        }
end
