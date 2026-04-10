defmodule Backplane.Skills.Sources.Database do
  @moduledoc """
  Database-backed skill source. DB skills are the source of truth.
  """

  @behaviour Backplane.Skills.Source

  import Ecto.Query
  alias Backplane.Repo
  alias Backplane.Skills.Skill

  @impl true
  @spec list() :: {:ok, [Backplane.Skills.Source.skill_entry()]}
  def list do
    skills =
      Skill
      |> where([s], s.enabled == true)
      |> Repo.all()
      |> Enum.map(&to_entry/1)

    {:ok, skills}
  end

  @impl true
  @spec fetch(String.t()) :: {:ok, Backplane.Skills.Source.skill_entry()} | {:error, :not_found}
  def fetch(skill_id) do
    case Repo.get(Skill, skill_id) do
      nil -> {:error, :not_found}
      skill -> {:ok, to_entry(skill)}
    end
  end

  @doc "Create a new database-sourced skill."
  @spec create(map()) :: {:ok, Skill.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    hash =
      :crypto.hash(:sha256, attrs[:content] || attrs["content"] || "")
      |> Base.encode16(case: :lower)

    id = generate_id()

    params =
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.merge(%{"id" => id, "content_hash" => hash})

    %Skill{}
    |> Skill.changeset(params)
    |> Repo.insert()
  end

  @doc "Update a skill by ID."
  @spec update(String.t(), map()) :: {:ok, Skill.t()} | {:error, atom() | Ecto.Changeset.t()}
  def update(skill_id, attrs) do
    case Repo.get(Skill, skill_id) do
      nil ->
        {:error, :not_found}

      skill ->
        attrs = maybe_recompute_hash(attrs)

        skill
        |> Skill.update_changeset(attrs)
        |> Repo.update()
    end
  end

  defp maybe_recompute_hash(attrs) do
    content = attrs[:content] || attrs["content"]

    if content do
      hash = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
      Map.put(attrs, :content_hash, hash)
    else
      attrs
    end
  end

  defp generate_id do
    "db/" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp to_entry(%Skill{} = s) do
    %{
      id: s.id,
      name: s.name,
      description: s.description,
      tags: s.tags,
      content: s.content,
      content_hash: s.content_hash
    }
  end
end
