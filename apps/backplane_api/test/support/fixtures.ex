defmodule Backplane.Api.Fixtures do
  @moduledoc false

  alias Backplane.Repo
  alias Backplane.Skills.Skill

  def insert_skill(overrides \\ []) do
    id = Keyword.get(overrides, :id, "test-skill-#{System.unique_integer([:positive])}")
    name = Keyword.get(overrides, :name, id)
    content = Keyword.get(overrides, :content, "# #{name}\n\nSkill content here.")

    attrs = %{
      id: id,
      slug: Keyword.get(overrides, :slug, id),
      name: name,
      content: content,
      content_hash: Keyword.get(overrides, :content_hash, hash(content)),
      archive_ref: Keyword.get(overrides, :archive_ref),
      source_kind: Keyword.get(overrides, :source_kind),
      enabled: Keyword.get(overrides, :enabled, true)
    }

    %Skill{}
    |> Skill.changeset(attrs)
    |> Repo.insert!()
  end

  defp hash(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
end
