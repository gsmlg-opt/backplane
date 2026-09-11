defmodule Backplane.SkillProtocol.Document do
  @moduledoc "A parsed Skill document retaining its exact source bytes."

  @enforce_keys [:raw, :frontmatter_raw, :body_raw, :metadata, :extensions]
  defstruct [
    :raw,
    :frontmatter_raw,
    :body_raw,
    :name,
    :description,
    :version,
    :license,
    :compatibility,
    metadata: %{},
    extensions: %{},
    diagnostics: []
  ]

  @type t :: %__MODULE__{}
end
