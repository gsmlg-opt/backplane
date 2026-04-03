defmodule Backplane.Skills.Sync do
  @moduledoc """
  Oban worker that syncs skills from external sources (git, local) into the database.

  Supports periodic re-sync: when `sync_interval` is present in the job args
  (e.g. `"1h"`), the worker schedules the next sync after successful completion.
  """

  use Oban.Worker, queue: :sync, unique: [period: 60, fields: [:args, :worker]]

  require Logger

  import Ecto.Query
  alias Backplane.Repo
  alias Backplane.Skills.{Registry, Skill}
  alias Backplane.Skills.Sources.{Git, Local}
  alias Backplane.Utils

  @default_sync_interval 3600

  @allowed_source_modules %{
    "Elixir.Backplane.Skills.Sources.Local" => Local,
    "Elixir.Backplane.Skills.Sources.Git" => Git
  }

  @doc """
  Build an Oban job changeset for a skill source config map.

  The config map should have keys: `source`, `name`, and source-specific keys
  (`path` for local, `repo`/`ref`/`path` for git). Optionally includes
  `sync_interval` (e.g. `"1h"`) to enable periodic re-sync.
  """
  @spec build_job(map(), keyword()) :: Oban.Job.changeset()
  def build_job(source_config, opts \\ []) do
    args = build_job_args(source_config)
    new(args, opts)
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"source_module" => source_module} = args}) do
    module =
      Map.get(@allowed_source_modules, source_module) ||
        raise "Disallowed source module: #{source_module}"

    config = build_config(module, args)

    Backplane.PubSubBroadcaster.broadcast_skills_sync(:started, %{name: args["name"]})

    case module.list(config) do
      {:ok, entries} ->
        sync_entries(entries)
        Registry.refresh()
        schedule_next(args)

        Backplane.PubSubBroadcaster.broadcast_skills_sync(:completed, %{
          name: args["name"],
          count: length(entries)
        })

        :ok

      {:error, reason} ->
        Backplane.PubSubBroadcaster.broadcast_skills_sync(:failed, %{
          name: args["name"],
          reason: reason
        })

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
  @spec sync_entries([map()]) :: :ok
  def sync_entries(entries) do
    source = get_source(entries)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    existing =
      Skill
      |> where([s], like(s.source, ^"#{Utils.escape_like(source)}%"))
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
        case %Skill{}
             |> Skill.changeset(Map.merge(entry, %{inserted_at: now, updated_at: now}))
             |> Repo.insert() do
          {:ok, skill} ->
            skill

          {:error, changeset} ->
            Logger.warning("Failed to insert skill #{entry.id}: #{inspect(changeset.errors)}")
            nil
        end

      existing_skill ->
        maybe_update_skill(existing_skill, entry, now)
    end
  end

  defp maybe_update_skill(existing_skill, entry, now) do
    if existing_skill.content_hash != entry.content_hash do
      case existing_skill
           |> Skill.update_changeset(
             Map.merge(entry, %{content_hash: entry.content_hash, updated_at: now})
           )
           |> Repo.update() do
        {:ok, skill} ->
          skill

        {:error, changeset} ->
          Logger.warning("Failed to update skill #{entry.id}: #{inspect(changeset.errors)}")

          nil
      end
    end
  end

  defp maybe_disable_skill({id, skill}, incoming_ids, now) do
    if skill.enabled and not MapSet.member?(incoming_ids, id) do
      case skill
           |> Skill.update_changeset(%{enabled: false, updated_at: now})
           |> Repo.update() do
        {:ok, skill} ->
          skill

        {:error, changeset} ->
          Logger.warning("Failed to disable skill #{id}: #{inspect(changeset.errors)}")
          nil
      end
    end
  end

  defp get_source([]), do: ""
  defp get_source([first | _]), do: first.source

  @doc false
  def schedule_next(%{"sync_interval" => interval} = args) when is_binary(interval) do
    seconds =
      case Utils.parse_interval(interval) do
        {:ok, s} ->
          s

        :error ->
          Logger.warning(
            "Invalid sync_interval '#{interval}' for #{args["name"]}, using default #{@default_sync_interval}s"
          )

          @default_sync_interval
      end

    case args |> new(schedule_in: seconds) |> Oban.insert() do
      {:ok, _job} ->
        Logger.debug("Scheduled next skill sync for #{args["name"]} in #{seconds}s")
        :ok

      {:error, reason} ->
        Logger.warning("Failed to schedule next sync for #{args["name"]}: #{inspect(reason)}")

        :ok
    end
  end

  def schedule_next(_args), do: :ok

  defp build_job_args(%{source: "git"} = config) do
    %{
      "source_module" => "Elixir.Backplane.Skills.Sources.Git",
      "name" => config.name,
      "repo" => config.repo,
      "path" => config[:path],
      "ref" => config[:ref] || "main",
      "sync_interval" => config[:sync_interval]
    }
  end

  defp build_job_args(%{source: "local"} = config) do
    %{
      "source_module" => "Elixir.Backplane.Skills.Sources.Local",
      "name" => config.name,
      "path" => config.path
    }
  end

  defp build_job_args(config) do
    Logger.warning("Unknown skill source type: #{inspect(config[:source])}")
    %{}
  end

  defp build_config(module, args) do
    case module do
      Local ->
        %Local{
          name: args["name"],
          path: args["path"]
        }

      Git ->
        %Git{
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
