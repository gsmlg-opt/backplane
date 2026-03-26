defmodule Backplane.Skills.Sync do
  @moduledoc """
  Oban worker that syncs skills from external sources (git, local) into the database.
  """

  use Oban.Worker, queue: :sync

  import Ecto.Query
  alias Backplane.Repo
  alias Backplane.Skills.Skill

  @allowed_source_modules %{
    "Elixir.Backplane.Skills.Sources.Local" => Backplane.Skills.Sources.Local,
    "Elixir.Backplane.Skills.Sources.Git" => Backplane.Skills.Sources.Git
  }

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"source_module" => source_module} = args}) do
    module =
      Map.get(@allowed_source_modules, source_module) ||
        raise "Disallowed source module: #{source_module}"

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
      |> where([s], like(s.source, ^"#{Backplane.Utils.escape_like(source)}%"))
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    incoming_ids = MapSet.new(entries, & &1.id)

    # Insert or update
    Enum.each(entries, &upsert_skill(&1, existing, now))

    # Disable removed skills
    Enum.each(existing, &maybe_disable_skill(&1, incoming_ids, now))

    :ok
  end

  defp upsert_skill(entry, existing, now) do
    case Map.get(existing, entry.id) do
      nil ->
        %Skill{}
        |> Skill.changeset(Map.merge(entry, %{inserted_at: now, updated_at: now}))
        |> Repo.insert!()

      existing_skill ->
        maybe_update_skill(existing_skill, entry, now)
    end
  end

  defp maybe_update_skill(existing_skill, entry, now) do
    if existing_skill.content_hash != entry.content_hash do
      existing_skill
      |> Skill.update_changeset(
        Map.merge(entry, %{content_hash: entry.content_hash, updated_at: now})
      )
      |> Repo.update!()
    end
  end

  defp maybe_disable_skill({id, skill}, incoming_ids, now) do
    if skill.enabled and not MapSet.member?(incoming_ids, id) do
      skill
      |> Skill.update_changeset(%{enabled: false, updated_at: now})
      |> Repo.update!()
    end
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
