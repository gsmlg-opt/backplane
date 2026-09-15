defmodule Backplane.SkillProtocol.SkillRef do
  @moduledoc "Source-scoped stable Skill identity, optionally resolved exactly."

  @enforce_keys [:source_id, :skill_id]
  defstruct [:source_id, :skill_id, :revision, :artifact_digest]

  @type t :: %__MODULE__{
          source_id: String.t(),
          skill_id: String.t(),
          revision: String.t() | nil,
          artifact_digest: String.t() | nil
        }
end
