defmodule Backplane.SkillProtocol.Catalog do
  @moduledoc "Deterministic catalog helpers."

  alias Backplane.SkillProtocol.Descriptor

  @spec sort([Descriptor.t()]) :: [Descriptor.t()]
  def sort(descriptors) do
    Enum.sort_by(descriptors, fn descriptor ->
      {descriptor.precedence, descriptor.name, descriptor.ref.source_id, descriptor.ref.skill_id}
    end)
  end
end
