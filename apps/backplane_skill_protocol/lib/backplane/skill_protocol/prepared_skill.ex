defmodule Backplane.SkillProtocol.PreparedSkill do
  @moduledoc "A verified immutable-root view whose lifetime is owned by its host."

  @enforce_keys [:root, :document, :manifest]
  defstruct [:root, :document, :manifest]

  @type t :: %__MODULE__{}
end
