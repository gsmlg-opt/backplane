defmodule Backplane.Memory.Workers.ProfileBuildWorker do
  @moduledoc "Oban worker: build or refresh the project intelligence profile from recent session memories."

  use Oban.Worker, queue: :memory, max_attempts: 3

  import Ecto.Query
  alias Backplane.Memory.Memories.Memory
  alias Backplane.Memory.Crystals.Crystal
  alias Backplane.Memory.Lessons.Lesson
  alias Backplane.Memory.Profiles.Profile
  alias Backplane.Memory.Summaries.Summary
  alias Backplane.Memory.PartitionIdentity
  alias Backplane.Memory.Projections.ProjectedSession

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)

  @cache_ttl_seconds 3600

  @impl Oban.Worker
  def perform(
        %Oban.Job{
          args:
            %{
              "project" => project,
              "memory_space_id" => _memory_space_id,
              "host_id" => _host_id,
              "client_id" => _client_id,
              "scope" => _scope,
              "namespace" => _namespace
            } = partition
        } = job
      ) do
    Backplane.Memory.PipelineTelemetry.span("profile", job.args, fn ->
      case generator_partition(project, partition) do
        {:ok, partition} ->
          perform_partition(project, partition, job.args["force"] == true)

        {:error, reason} ->
          record_partition_issue(project, partition, reason)
          {:discard, reason}
      end
    end)
  end

  def perform(%Oban.Job{}), do: {:discard, :ambiguous_partition}

  defp perform_partition(project, partition, force?) do
    host_id = partition.host_id
    memory_space_id = partition.memory_space_id
    client_id = partition.client_id
    scope = partition.scope
    namespace = partition.namespace

    existing =
      repo().get_by(Profile,
        project: project,
        memory_space_id: memory_space_id,
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
    case generator_partition(project, partition) do
      {:ok, partition} ->
        %{
          project: project,
          memory_space_id: Map.fetch!(partition, :memory_space_id),
          host_id: Map.fetch!(partition, :host_id),
          client_id: Map.fetch!(partition, :client_id),
          source_client_id: Map.get(partition, :source_client_id),
          scope: Map.fetch!(partition, :scope),
          namespace: Map.fetch!(partition, :namespace),
          force: Keyword.get(opts, :force, false)
        }
        |> new()
        |> Oban.insert()

      {:error, reason} = error ->
        record_partition_issue(project, partition, reason)
        error
    end
  end

  defp fresh?(nil), do: false

  defp fresh?(%Profile{updated_at: updated_at}) do
    DateTime.diff(DateTime.utc_now(), updated_at, :second) < @cache_ttl_seconds
  end

  defp build_and_upsert(project, partition) do
    host_id = partition.host_id
    memory_space_id = partition.memory_space_id
    client_id = partition.client_id
    scope = partition.scope
    namespace = partition.namespace

    recent_session_ids =
      repo().all(
        from(m in Memory,
          where:
            m.memory_space_id == ^memory_space_id and m.scope == ^scope and
              m.host_id == ^host_id and m.client_id == ^client_id and
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
              m.session_id in ^recent_session_ids and m.memory_space_id == ^memory_space_id and
                m.host_id == ^host_id and
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
            m.memory_space_id == ^memory_space_id and m.scope == ^scope and
              m.host_id == ^host_id and m.client_id == ^client_id and
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
      memory_space_id: memory_space_id,
      host_id: host_id,
      client_id: client_id,
      source_client_id: partition[:source_client_id],
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
      conflict_target: [:memory_space_id, :host_id, :client_id, :scope, :namespace, :project]
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
          l.status == "active" and m.memory_space_id == ^partition.memory_space_id and
            m.host_id == ^partition.host_id and
            m.client_id == ^partition.client_id and m.scope == ^partition.scope and
            m.namespace == ^partition.namespace and m.scope == ^project and
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
          c.memory_space_id == ^partition.memory_space_id and
            c.host_id == ^partition.host_id and c.client_id == ^partition.client_id and
            c.scope == ^partition.scope and c.namespace == ^partition.namespace and
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
          s.memory_space_id == ^partition.memory_space_id and
            s.host_id == ^partition.host_id and
            s.source_client_id == ^partition[:source_client_id] and s.scope == ^partition.scope and
            s.namespace == ^partition.namespace and s.project == ^project and
            s.session_id in ^session_ids and is_nil(s.superseded_at),
        order_by: [desc: s.created_at, desc: s.id],
        limit: 10,
        select: {s.id, fragment("left(?, 500)", s.content)}
      )
    )
    |> Map.new()
  end

  defp generator_partition(project, partition) do
    with {:ok, claim} <- PartitionIdentity.validate_generator(partition),
         {:ok, expected} <- authoritative_partition(project, claim),
         {:ok, validated} <- PartitionIdentity.validate_generator(claim, expected) do
      {:ok, validated}
    end
  end

  defp authoritative_partition(project, claim) do
    cond do
      exact_source?(project, claim) -> {:ok, claim}
      any_source?(project) -> {:error, :partition_mismatch}
      true -> {:error, :incomplete_partition}
    end
  end

  defp exact_source?(project, claim) do
    repo().exists?(
      from(m in Memory,
        where:
          fragment("?->>'project'", m.metadata) == ^project and
            m.memory_space_id == ^claim.memory_space_id and m.host_id == ^claim.host_id and
            m.client_id == ^claim.client_id and m.scope == ^claim.scope and
            m.namespace == ^claim.namespace and is_nil(m.deleted_at)
      )
    ) or
      repo().exists?(
        from(s in Summary,
          join: session in ProjectedSession,
          on: session.subject_id == s.subject_id,
          where:
            s.project == ^project and is_nil(s.superseded_at) and
              session.memory_space_id == ^claim.memory_space_id and
              session.host_id == ^claim.host_id and session.client_id == ^claim.client_id and
              session.scope == ^claim.scope and session.namespace == ^claim.namespace
        )
      ) or
      repo().exists?(
        from(p in Profile,
          where:
            p.project == ^project and p.memory_space_id == ^claim.memory_space_id and
              p.host_id == ^claim.host_id and p.client_id == ^claim.client_id and
              p.scope == ^claim.scope and p.namespace == ^claim.namespace
        )
      )
  end

  defp any_source?(project) do
    repo().exists?(
      from(m in Memory,
        where: fragment("?->>'project'", m.metadata) == ^project and is_nil(m.deleted_at)
      )
    ) or
      repo().exists?(
        from(s in Summary,
          join: session in ProjectedSession,
          on: session.subject_id == s.subject_id,
          where: s.project == ^project and is_nil(s.superseded_at)
        )
      ) or repo().exists?(from(p in Profile, where: p.project == ^project))
  end

  defp record_partition_issue(project, partition, reason) do
    claim = issue_partition(partition)
    details = Map.put(claim, :project, project)

    source_id =
      [project, claim]
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    Backplane.Memory.Memories.record_partition_issue(
      "memory_profile_generator",
      source_id,
      reason,
      details
    )
  end

  defp issue_partition(partition) do
    Map.new([:memory_space_id, :host_id, :client_id, :scope, :namespace], fn key ->
      value = Map.get(partition, key, Map.get(partition, Atom.to_string(key)))
      {key, if(is_binary(value), do: String.trim(value), else: value)}
    end)
  end
end
