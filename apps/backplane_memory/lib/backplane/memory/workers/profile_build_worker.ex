defmodule Backplane.Memory.Workers.ProfileBuildWorker do
  @moduledoc "Oban worker: build or refresh the project intelligence profile from recent session memories."

  use Oban.Worker, queue: :memory, max_attempts: 3

  import Ecto.Query
  alias Backplane.Memory.Memories.Memory
  alias Backplane.Memory.Crystals.Crystal
  alias Backplane.Memory.Lessons.Lesson
  alias Backplane.Memory.Profiles.Profile
  alias Backplane.Memory.Summaries.Summary

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)

  @cache_ttl_seconds 3600

  @impl Oban.Worker
  def perform(
        %Oban.Job{
          args:
            %{
              "project" => project,
              "host_id" => _host_id,
              "client_id" => _client_id,
              "scope" => _scope,
              "namespace" => _namespace
            } = partition
        } = job
      ) do
    Backplane.Memory.PipelineTelemetry.span("profile", job.args, fn ->
      perform_partition(project, partition, job.args["force"] == true)
    end)
  end

  def perform(%Oban.Job{}), do: {:discard, :ambiguous_partition}

  defp perform_partition(project, partition, force?) do
    host_id = partition["host_id"]
    client_id = partition["client_id"]
    scope = partition["scope"]
    namespace = partition["namespace"]

    existing =
      repo().get_by(Profile,
        project: project,
        host_id: host_id,
        client_id: client_id,
        scope: scope,
        namespace: namespace
      )

    if fresh?(existing) and not force? do
      {:ok, :cached}
    else
      build_and_upsert(project, partition)
    end
  end

  @doc "Enqueue a profile build job for a project."
  def enqueue(_project), do: {:error, :unauthorized}

  def enqueue(project, partition) do
    enqueue(project, partition, [])
  end

  def enqueue(project, partition, opts) when is_list(opts) do
    %{
      project: project,
      host_id: Map.fetch!(partition, :host_id),
      client_id: Map.fetch!(partition, :client_id),
      scope: Map.fetch!(partition, :scope),
      namespace: Map.fetch!(partition, :namespace),
      force: Keyword.get(opts, :force, false)
    }
    |> new()
    |> Oban.insert()
  end

  defp fresh?(nil), do: false

  defp fresh?(%Profile{updated_at: updated_at}) do
    DateTime.diff(DateTime.utc_now(), updated_at, :second) < @cache_ttl_seconds
  end

  defp build_and_upsert(project, partition) do
    host_id = partition["host_id"]
    client_id = partition["client_id"]
    scope = partition["scope"]
    namespace = partition["namespace"]

    recent_session_ids =
      repo().all(
        from(m in Memory,
          where:
            m.scope == ^scope and m.host_id == ^host_id and m.client_id == ^client_id and
              m.namespace == ^namespace and fragment("?->>'project'", m.metadata) == ^project and
              is_nil(m.deleted_at) and not is_nil(m.session_id),
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
            where:
              m.session_id in ^recent_session_ids and m.host_id == ^host_id and
                m.client_id == ^client_id and m.scope == ^scope and
                m.namespace == ^namespace and fragment("?->>'project'", m.metadata) == ^project and
                is_nil(m.deleted_at),
            select: %{
              id: m.id,
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
        from(m in Memory,
          where:
            m.scope == ^scope and m.host_id == ^host_id and m.client_id == ^client_id and
              m.namespace == ^namespace and fragment("?->>'project'", m.metadata) == ^project and
              is_nil(m.deleted_at)
        ),
        :count,
        :id
      )

    top_concepts = tally(Enum.flat_map(memories, & &1.tags))
    top_files = tally(Enum.flat_map(memories, fn m -> Map.get(m.metadata, "files", []) end))
    patterns = tally(Enum.map(memories, & &1.memory_type))
    session_ids = Enum.uniq(Enum.map(memories, & &1.session_id))
    active_lessons = active_lessons(partition, project)
    recent_crystals = recent_crystals(partition, project)
    recent_summaries = recent_summaries(partition, project, session_ids)
    session_count = length(session_ids)

    attrs = %{
      project: project,
      host_id: host_id,
      client_id: client_id,
      scope: scope,
      namespace: namespace,
      top_concepts: top_concepts,
      top_files: top_files,
      patterns: patterns,
      active_lessons: active_lessons,
      recent_crystals: recent_crystals,
      recent_summaries: recent_summaries,
      source_records: %{
        "memory_ids" => Enum.map(memories, & &1.id),
        "session_ids" => session_ids,
        "lesson_ids" => Map.keys(active_lessons),
        "crystal_ids" => Map.keys(recent_crystals),
        "summary_ids" => Map.keys(recent_summaries)
      },
      summary: "#{total_obs} observations across #{session_count} sessions",
      session_count: session_count,
      total_observations: total_obs,
      updated_at: DateTime.utc_now()
    }

    %Profile{}
    |> Profile.changeset(attrs)
    |> repo().insert(
      on_conflict:
        {:replace,
         [
           :top_concepts,
           :top_files,
           :patterns,
           :active_lessons,
           :recent_crystals,
           :recent_summaries,
           :source_records,
           :summary,
           :session_count,
           :total_observations,
           :updated_at
         ]},
      conflict_target: [:host_id, :client_id, :scope, :namespace, :project]
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

  defp active_lessons(partition, project) do
    repo().all(
      from(l in Lesson,
        join: m in Memory,
        on: m.id == l.memory_id,
        where:
          l.status == "active" and m.host_id == ^partition["host_id"] and
            m.client_id == ^partition["client_id"] and m.scope == ^partition["scope"] and
            m.namespace == ^partition["namespace"] and m.scope == ^project and
            is_nil(m.deleted_at),
        order_by: [desc: l.updated_at],
        limit: 20,
        select: {l.memory_id, m.content}
      )
    )
    |> Map.new()
  end

  defp recent_crystals(partition, project) do
    repo().all(
      from(c in Crystal,
        where:
          c.host_id == ^partition["host_id"] and c.client_id == ^partition["client_id"] and
            c.scope == ^partition["scope"] and c.namespace == ^partition["namespace"] and
            c.project == ^project and c.status == "complete",
        order_by: [desc: c.completed_at, desc: c.id],
        limit: 10,
        select: {c.id, c.title}
      )
    )
    |> Map.new()
  end

  defp recent_summaries(_partition, _project, []), do: %{}

  defp recent_summaries(partition, project, session_ids) do
    repo().all(
      from(s in Summary,
        where:
          s.host_id == ^partition["host_id"] and s.project == ^project and
            s.session_id in ^session_ids and is_nil(s.superseded_at),
        order_by: [desc: s.created_at, desc: s.id],
        limit: 10,
        select: {s.id, fragment("left(?, 500)", s.content)}
      )
    )
    |> Map.new()
  end
end
