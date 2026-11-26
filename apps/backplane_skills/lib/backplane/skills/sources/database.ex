defmodule Backplane.Skills.Sources.Database do
  @moduledoc """
  Database-backed skill source. DB skills are the source of truth.
  """

  @behaviour Backplane.Skills.Source

  import Ecto.Query
  alias Backplane.Repo
  alias Backplane.Skills.{Publication, Skill}

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
    Repo.transact(fn -> insert_skill(attrs) end)
  end

  @doc "Create and publish atomically, returning the exact manifest to a protocol writer."
  @spec create_manifest(map()) :: {:ok, map()} | {:error, term()}
  def create_manifest(attrs) do
    Repo.transact(fn ->
      with {:ok, %Skill{publication_status: "ready"} = skill} <- insert_skill(attrs),
           {:ok, revision} <- Publication.resolve(skill.id, skill.current_revision) do
        {:ok, revision.manifest}
      else
        {:ok, %Skill{}} ->
          {:error, :invalid_document}

        {:error, %Ecto.Changeset{errors: errors}} ->
          case errors[:slug] do
            {_, [constraint: :unique, constraint_name: _]} -> {:error, :already_exists}
            _ -> {:error, :invalid_document}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  defp insert_skill(attrs) do
    hash =
      :crypto.hash(:sha256, attrs[:content] || attrs["content"] || "")
      |> Base.encode16(case: :lower)

    id = generate_id()
    name = attrs[:name] || attrs["name"] || ""

    params =
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.merge(%{"id" => id, "content_hash" => hash})
      |> Map.put_new("slug", derive_slug(name, id))
      |> Map.put_new("source_kind", "database")

    save_and_publish(Skill.changeset(%Skill{}, params), :insert)
  end

  @doc "Update a skill by ID."
  @spec update(String.t(), map()) :: {:ok, Skill.t()} | {:error, atom() | Ecto.Changeset.t()}
  def update(skill_id, attrs) do
    Repo.transact(fn ->
      case Repo.one(from(s in Skill, where: s.id == ^skill_id, lock: "FOR UPDATE")) do
        nil ->
          {:error, :not_found}

        skill ->
          attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

          attrs =
            if is_binary(attrs["content"]),
              do:
                Map.put(
                  attrs,
                  "content_hash",
                  Base.encode16(:crypto.hash(:sha256, attrs["content"]), case: :lower)
                ),
              else: attrs

          save_and_publish(Skill.update_changeset(skill, attrs), :update)
      end
    end)
  end

  defp save_and_publish(changeset, action) do
    with {:ok, skill} <- apply(Repo, action, [changeset]) do
      if skill.source_kind == "database" and skill.publication_status != "ready" do
        Publication.publish_database(skill)
      else
        {:ok, skill}
      end
    end
  end

  defp generate_id do
    "db/" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp derive_slug(name, id) do
    base =
      name
      |> to_string()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    hash =
      :md5
      |> :crypto.hash(id)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 8)

    "#{if base == "", do: "skill", else: base}-#{hash}"
  end

  defp to_entry(%Skill{} = s) do
    %{
      id: s.id,
      slug: s.slug,
      name: s.name,
      description: s.description,
      tags: s.tags,
      category: s.category,
      content: s.content,
      content_hash: s.content_hash,
      version: s.version,
      license: s.license,
      homepage: s.homepage,
      author: s.author,
      meta: s.meta,
      archive_ref: s.archive_ref,
      size_bytes: s.size_bytes,
      file_count: s.file_count,
      source_kind: s.source_kind,
      source_uri: s.source_uri,
      source_rev: s.source_rev
    }
  end
end
