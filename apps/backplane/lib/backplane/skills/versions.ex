defmodule Backplane.Skills.Versions do
  @moduledoc """
  Version history for DB-sourced skills.
  Snapshots are created before each update. Version numbers auto-increment.
  """

  import Ecto.Query

  alias Backplane.Repo
  alias Backplane.Skills.{Skill, SkillVersion}

  @doc """
  Snapshot the current state of a skill before an update.
  Creates version 1 on first snapshot, increments thereafter.
  """
  @spec snapshot(Skill.t(), keyword()) :: {:ok, SkillVersion.t()} | {:error, term()}
  def snapshot(%Skill{} = skill, opts \\ []) do
    author = Keyword.get(opts, :author, "system")
    change_summary = Keyword.get(opts, :change_summary)

    next_version =
      case latest_version_number(skill.id) do
        nil -> 1
        n -> n + 1
      end

    metadata = %{
      name: skill.name,
      description: skill.description,
      tags: skill.tags,
      source: skill.source
    }

    %SkillVersion{}
    |> SkillVersion.changeset(%{
      skill_id: skill.id,
      version: next_version,
      content_hash: skill.content_hash,
      content: skill.content,
      metadata: metadata,
      author: author,
      change_summary: change_summary
    })
    |> Repo.insert()
  end

  @doc "List versions for a skill, newest first."
  @spec list(String.t(), keyword()) :: [SkillVersion.t()]
  def list(skill_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)

    SkillVersion
    |> where(skill_id: ^skill_id)
    |> order_by(desc: :version)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Get a specific version of a skill."
  @spec get(String.t(), integer()) :: {:ok, SkillVersion.t()} | {:error, :not_found}
  def get(skill_id, version) do
    case Repo.get_by(SkillVersion, skill_id: skill_id, version: version) do
      nil -> {:error, :not_found}
      sv -> {:ok, sv}
    end
  end

  defp latest_version_number(skill_id) do
    SkillVersion
    |> where(skill_id: ^skill_id)
    |> select([v], max(v.version))
    |> Repo.one()
  end
end
