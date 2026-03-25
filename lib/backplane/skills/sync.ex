defmodule Backplane.Skills.Sync do
  @moduledoc """
  Oban worker that syncs skills from external sources (git, local) into the database.
  """

  use Oban.Worker, queue: :sync

  import Ecto.Query
  alias Backplane.Repo
  alias Backplane.Skills.Skill

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"source_module" => source_module} = args}) do
    module = String.to_existing_atom(source_module)
    config = build_config(module, args)

    case module.list(config) do
      {:ok, entries} ->
        sync_entries(entries)
        Backplane.Skills.Registry.refresh()
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Sync a list of skill entries into the database.
  - Insert new skills
  - Update changed skills (different content_hash)
  - Disable removed skills (not present in source)
  - Skip unchanged skills (same content_hash)
  """
  def sync_entries(entries) do
    source = get_source(entries)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    existing =
      Skill
      |> where([s], like(s.source, ^"#{source}%"))
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    incoming_ids = MapSet.new(entries, & &1.id)

    # Insert or update
    Enum.each(entries, fn entry ->
      case Map.get(existing, entry.id) do
        nil ->
          # New skill
          %Skill{}
          |> Skill.changeset(Map.merge(entry, %{inserted_at: now, updated_at: now}))
          |> Repo.insert!()

        existing_skill ->
          if existing_skill.content_hash != entry.content_hash do
            existing_skill
            |> Skill.update_changeset(
              Map.merge(entry, %{content_hash: entry.content_hash, updated_at: now})
            )
            |> Repo.update!()
          end

          # Same hash — skip
      end
    end)

    # Disable removed skills
    existing
    |> Enum.each(fn {id, skill} ->
      if skill.enabled and not MapSet.member?(incoming_ids, id) do
        skill
        |> Skill.update_changeset(%{enabled: false, updated_at: now})
        |> Repo.update!()
      end
    end)

    :ok
  end

  defp get_source([]), do: ""
  defp get_source([first | _]), do: first.source

  defp build_config(module, args) do
    case module do
      Backplane.Skills.Sources.Local ->
        %Backplane.Skills.Sources.Local{
          name: args["name"],
          path: args["path"]
        }

      Backplane.Skills.Sources.Git ->
        %Backplane.Skills.Sources.Git{
          name: args["name"],
          repo: args["repo"],
          path: args["path"],
          ref: args["ref"] || "main"
        }

      _ ->
        %{}
    end
  end
end
