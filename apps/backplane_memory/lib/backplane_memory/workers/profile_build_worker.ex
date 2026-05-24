defmodule BackplaneMemory.Workers.ProfileBuildWorker do
  @moduledoc "Oban worker: build or refresh the project intelligence profile from recent session memories."

  use Oban.Worker, queue: :memory, max_attempts: 3

  import Ecto.Query
  alias BackplaneMemory.Memories.{Memory, Profile}

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)

  @cache_ttl_seconds 3600

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"project" => project}}) do
    existing = repo().get(Profile, project)

    if fresh?(existing) do
      {:ok, :cached}
    else
      build_and_upsert(project)
    end
  end

  @doc "Enqueue a profile build job for a project."
  def enqueue(project) do
    %{project: project}
    |> new()
    |> Oban.insert()
  end

  defp fresh?(nil), do: false

  defp fresh?(%Profile{updated_at: updated_at}) do
    DateTime.diff(DateTime.utc_now(), updated_at, :second) < @cache_ttl_seconds
  end

  defp build_and_upsert(project) do
    recent_session_ids =
      repo().all(
        from(m in Memory,
          where: m.scope == ^project and is_nil(m.deleted_at) and not is_nil(m.session_id),
          distinct: m.session_id,
          order_by: [desc: m.inserted_at],
          select: m.session_id,
          limit: 20
        )
      )

    memories =
      if recent_session_ids == [] do
        []
      else
        repo().all(
          from(m in Memory,
            where: m.session_id in ^recent_session_ids and is_nil(m.deleted_at),
            select: %{
              tags: m.tags,
              metadata: m.metadata,
              memory_type: m.memory_type,
              session_id: m.session_id
            }
          )
        )
      end

    total_obs =
      repo().aggregate(
        from(m in Memory, where: m.scope == ^project and is_nil(m.deleted_at)),
        :count,
        :id
      )

    top_concepts = tally(Enum.flat_map(memories, & &1.tags))
    top_files = tally(Enum.flat_map(memories, fn m -> Map.get(m.metadata, "files", []) end))
    patterns = tally(Enum.map(memories, & &1.memory_type))

    attrs = %{
      project: project,
      top_concepts: top_concepts,
      top_files: top_files,
      patterns: patterns,
      session_count: length(Enum.uniq(Enum.map(memories, & &1.session_id))),
      total_observations: total_obs,
      updated_at: DateTime.utc_now()
    }

    %Profile{}
    |> Profile.changeset(attrs)
    |> repo().insert(
      on_conflict:
        {:replace,
         [:top_concepts, :top_files, :patterns, :session_count, :total_observations, :updated_at]},
      conflict_target: [:project]
    )

    {:ok, :built}
  end

  # Returns top-20 entries sorted by frequency as a map %{item => count}
  defp tally(items) do
    items
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_, count} -> count end, :desc)
    |> Enum.take(20)
    |> Map.new()
  end
end
