defmodule Backplane.Memory.Crystals do
  @moduledoc "Structured, versioned completed-session episodic digests."

  import Ecto.Query

  alias Backplane.Memory.Crystals.{Crystal, LessonLink, SourceAction, SourceEvent, SourceSummary}
  alias Backplane.Memory.Events.Event
  alias Backplane.Memory.LLM
  alias Backplane.Memory.Lessons
  alias Backplane.Memory.Memories.Memory
  alias Backplane.Memory.Memories.Evidence
  alias Backplane.Memory.Privacy.Filter
  alias Backplane.Memory.Projections.{ProjectedSession, ReadModels, Revision, Source}
  alias Backplane.Memory.Summaries.Summary
  alias Backplane.Memory.Workers.CrystalWorker

  @processing_version "crystal-v1"
  @prompt_version "crystal-session-v1"
  @action_processing_version "crystal-action-v1"
  @action_prompt_version "crystal-action-v1"

  @doc "Builds one idempotent crystal for the bounded connected component containing root_action_id."
  def build_action_chain(root_action_id, partition, opts \\ [])

  def build_action_chain(root_action_id, partition, opts)
      when is_binary(root_action_id) and is_map(partition) and is_list(opts) do
    with true <- Backplane.Memory.Config.crystal_action_enabled?(),
         {:ok, partition} <- normalize_partition(partition),
         {:ok, limit} <- action_limit(opts),
         {:ok, actions} <- connected_actions(root_action_id, partition, limit),
         {:ok, override?} <- terminal_policy(actions, opts) do
      persist_action_chain(actions, partition, override?, opts)
    else
      false -> {:error, :crystal_action_disabled}
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_arguments}
    end
  end

  def build_action_chain(_root_action_id, _partition, _opts), do: {:error, :invalid_arguments}

  @doc "Returns a crystal with typed action and lesson joins in one exact partition."
  def get(id, partition) when is_binary(id) and is_map(partition) do
    with {:ok, partition} <- normalize_partition(partition),
         %Crystal{} = crystal <-
           repo().one(
             from(c in Crystal,
               where:
                 c.id == ^id and c.host_id == ^partition.host_id and
                   c.client_id == ^partition.client_id and c.scope == ^partition.scope and
                   c.namespace == ^partition.namespace
             )
           ) do
      action_ids =
        repo().all(
          from(l in SourceAction,
            where: l.crystal_id == ^id,
            order_by: l.action_id,
            select: l.action_id
          )
        )

      lesson_ids =
        repo().all(
          from(l in LessonLink,
            where: l.crystal_id == ^id,
            order_by: l.lesson_memory_id,
            select: l.lesson_memory_id
          )
        )

      summary_ids =
        repo().all(
          from(l in SourceSummary,
            where: l.crystal_id == ^id,
            order_by: l.summary_id,
            select: l.summary_id
          )
        )

      event_ids =
        repo().all(
          from(l in SourceEvent,
            where: l.crystal_id == ^id,
            order_by: l.event_id,
            select: l.event_id
          )
        )

      {:ok,
       %{
         crystal: crystal,
         source_action_ids: action_ids,
         lesson_memory_ids: lesson_ids,
         source_summary_ids: summary_ids,
         source_event_ids: event_ids
       }}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def get(_id, _partition), do: {:error, :not_found}

  @doc "Exact-partition validated session crystallization enqueue."
  def enqueue_session(session_id, partition) when is_binary(session_id) and is_map(partition) do
    with true <- Backplane.Memory.Config.crystal_session_enabled?(),
         {:ok, partition} <- normalize_partition(partition),
         %ProjectedSession{input_revision: revision} when is_binary(revision) <-
           repo().one(
             from(s in ProjectedSession,
               where:
                 s.session_id == ^session_id and s.host_id == ^partition.host_id and
                   s.client_id == ^partition.client_id and s.scope == ^partition.scope and
                   s.namespace == ^partition.namespace and
                   s.status in ["stopped", "completed", "abandoned"],
               lock: "FOR SHARE"
             )
           ),
         {:ok, enqueue_result} <- CrystalWorker.enqueue(partition.host_id, session_id, revision) do
      case enqueue_result do
        {:stale, _state} ->
          {:ok, %{status: "skipped", job: nil, input_revision: revision}}

        job ->
          {:ok, %{status: "enqueued", job: job, input_revision: revision}}
      end
    else
      false -> {:error, :crystal_session_disabled}
      nil -> {:error, :not_found}
      {:error, _} = error -> error
      _ -> {:error, :not_ready}
    end
  end

  def enqueue_session(_session_id, _partition), do: {:error, :not_found}

  @doc "Lists a bounded deterministic page of crystals in one exact partition."
  def list(partition, opts \\ [])

  def list(partition, opts) when is_map(partition) and is_list(opts) do
    with {:ok, partition} <- normalize_partition(partition),
         limit when is_integer(limit) and limit in 1..100 <- Keyword.get(opts, :limit, 20),
         {:ok, cursor} <- normalize_cursor(Keyword.get(opts, :after)) do
      query =
        from(c in Crystal,
          where:
            c.host_id == ^partition.host_id and c.client_id == ^partition.client_id and
              c.scope == ^partition.scope and c.namespace == ^partition.namespace and
              c.status == "complete",
          order_by: [desc: c.completed_at, desc: c.id],
          limit: ^(limit + 1)
        )

      query =
        if cursor,
          do: where(query, [c], {c.completed_at, c.id} < {^cursor.completed_at, ^cursor.id}),
          else: query

      rows = repo().all(query)
      entries = Enum.take(rows, limit)
      next = if length(rows) > limit, do: encode_cursor(List.last(entries)), else: nil
      {:ok, %{entries: entries, next_cursor: next}}
    else
      _ -> {:error, :invalid_list}
    end
  end

  def list(_partition, _opts), do: {:error, :invalid_list}

  def build_session(host_id, session_id, expected_revision, opts \\ [])

  def build_session(host_id, session_id, expected_revision, opts)
      when is_binary(host_id) and is_binary(session_id) and is_binary(expected_revision) and
             is_list(opts) do
    version = Keyword.get(opts, :processing_version, @processing_version)
    enrich_fn = Keyword.get(opts, :enrich_fn, &default_enrich/1)

    if Keyword.get(opts, :enforce_feature_gate, false) and
         not Backplane.Memory.Config.crystal_session_enabled?() do
      {:error, :crystal_session_disabled}
    else
      repo().transaction(fn ->
        subject_id = Source.subject_id!(host_id, session_id)
        Source.lock_streams(host_id, session_id)
        lock_identity(subject_id, version)

        case current(host_id, session_id, version) do
          %Crystal{input_revision: ^expected_revision} = crystal ->
            case Source.input_revision(host_id, session_id) do
              {:ok, %{input_revision: ^expected_revision}} -> crystal
              {:ok, _newer_input} -> repo().rollback(:stale_input_revision)
            end

          %Crystal{} ->
            repo().rollback(:stale_input_revision)

          nil ->
            with {:ok, %{input_revision: ^expected_revision} = input} <-
                   ReadModels.summary_input(host_id, session_id,
                     limit: 100,
                     allow_incomplete: true
                   ),
                 {:ok, partition} <- exact_partition(input),
                 :ok <- requested_partition(partition, Keyword.get(opts, :partition)),
                 %Summary{} = summary <- current_summary(input),
                 {:ok, structured, model} <- enrich(input, summary, enrich_fn) do
              persist(input, partition, summary, structured, model, version)
            else
              nil -> repo().rollback(:summary_not_ready)
              {:ok, _newer} -> repo().rollback(:stale_input_revision)
              {:error, reason} -> repo().rollback(reason)
            end
        end
      end)
      |> case do
        {:ok, %Crystal{} = crystal} -> {:ok, crystal}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def build_session(_host_id, _session_id, _expected_revision, _opts),
    do: {:error, :invalid_arguments}

  @doc "Searches complete crystals inside one exact four-field partition."
  def search(query, partition, opts \\ [])

  def search(query, partition, opts) when is_binary(query) and is_map(partition) do
    limit = Keyword.get(opts, :limit, 20)

    with {:ok, %{host_id: host, client_id: client, scope: scope, namespace: namespace}} <-
           normalize_partition(partition),
         true <- is_integer(limit) and limit in 1..100 do
      rows =
        Crystal
        |> join(:inner, [crystal], memory in Memory, on: memory.id == crystal.memory_id)
        |> where(
          [crystal, memory],
          crystal.host_id == ^host and crystal.client_id == ^client and crystal.scope == ^scope and
            crystal.namespace == ^namespace and crystal.status == "complete" and
            is_nil(memory.deleted_at) and
            fragment(
              "search_tsv @@ websearch_to_tsquery('english', ?)",
              ^String.trim(query)
            )
        )
        |> order_by([crystal, memory],
          desc:
            fragment(
              "ts_rank(search_tsv, websearch_to_tsquery('english', ?))",
              ^String.trim(query)
            ),
          asc: crystal.id
        )
        |> limit(^limit)
        |> select([crystal, _memory], crystal)
        |> repo().all()

      {:ok, rows}
    else
      _invalid -> {:error, :invalid_search}
    end
  end

  def search(_query, _partition, _opts), do: {:error, :invalid_search}

  defp persist(input, partition, summary, structured, model, version) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    content = searchable_content(structured, version)

    memory_attrs = %{
      content: content,
      memory_type: "episodic",
      scope: partition.scope,
      namespace: partition.namespace,
      agent_id: input.agent_id || "unknown",
      host_id: partition.host_id,
      client_id: partition.client_id,
      session_id: input.session_id,
      tags: ["crystal"],
      metadata: %{
        "kind" => "crystal",
        "project" => input.project,
        "processing_version" => version
      }
    }

    memory = %Memory{} |> Memory.changeset(memory_attrs) |> repo().insert!()

    output = %{
      "memory_id" => memory.id,
      "title" => structured.title,
      "narrative" => structured.narrative,
      "key_outcomes" => structured.key_outcomes,
      "decisions" => structured.decisions,
      "files_affected" => structured.files_affected,
      "unresolved_items" => structured.unresolved_items,
      "processing_version" => version,
      "prompt_version" => @prompt_version,
      "input_revision" => input.input_revision
    }

    {:ok, output_revision} = Revision.output_revision(output)

    crystal =
      %Crystal{}
      |> Crystal.changeset(%{
        memory_id: memory.id,
        subject_id: input.subject_id,
        host_id: partition.host_id,
        client_id: partition.client_id,
        scope: partition.scope,
        namespace: partition.namespace,
        source_session_id: input.session_id,
        title: structured.title,
        project: input.project,
        narrative: structured.narrative,
        key_outcomes: structured.key_outcomes,
        decisions: structured.decisions,
        files_affected: structured.files_affected,
        unresolved_items: structured.unresolved_items,
        processing_version: version,
        model: model,
        prompt_version: @prompt_version,
        input_revision: input.input_revision,
        output_revision: output_revision,
        status: "complete",
        started_at: now,
        completed_at: now
      })
      |> repo().insert!()

    %Evidence{}
    |> Evidence.changeset(%{
      memory_id: memory.id,
      source_summary_id: summary.id,
      session_id: input.session_id,
      agent_id: input.agent_id,
      host_id: partition.host_id,
      evidence_kind: "derives",
      support_score: 1.0,
      excerpt: bounded(summary.content, 1_000)
    })
    |> repo().insert!()

    insert_sources(crystal, summary, input, partition)
    crystal
  end

  defp insert_sources(crystal, summary, input, partition) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    repo().insert_all(SourceSummary, [
      %{crystal_id: crystal.id, summary_id: summary.id, inserted_at: now}
    ])

    rows =
      Event
      |> where(
        [event],
        not is_nil(event.schema_version) and event.host_id == ^partition.host_id and
          event.client_id == ^partition.client_id and event.scope == ^partition.scope and
          event.namespace == ^partition.namespace and event.session_id == ^input.session_id
      )
      |> order_by([event], asc: event.source_sequence, asc: event.event_type, asc: event.id)
      |> select([event], event.id)
      |> repo().all()
      |> Enum.map(&%{crystal_id: crystal.id, event_id: &1, inserted_at: now})

    expected = input.counts["events"] || 0
    if length(rows) != expected, do: repo().rollback(:source_provenance_mismatch)
    repo().insert_all(SourceEvent, rows)
  end

  defp enrich(input, summary, enrich_fn) when is_function(enrich_fn, 1) do
    fallback = fallback(input, summary)

    case enrich_fn.(%{input: input, summary: summary, fallback: fallback}) do
      {:ok, structured, model} -> {:ok, merge_structured(fallback, structured), model}
      {:skip, _reason} -> {:ok, fallback, nil}
      {:error, _reason} -> {:ok, fallback, nil}
      _invalid -> {:ok, fallback, nil}
    end
  end

  defp fallback(input, summary) do
    files =
      (input.observations ++ input.errors)
      |> Enum.flat_map(&(&1.file_paths || []))
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()
      |> Enum.sort()

    %{
      title: bounded("Session #{input.session_id}", 500),
      narrative: bounded(summary.content, 65_536),
      key_outcomes: fallback_outcomes(input),
      decisions: [],
      files_affected: Enum.take(files, 500),
      unresolved_items:
        Enum.map(input.errors, &bounded(&1.message || &1.content, 1_000)) |> Enum.take(100)
    }
  end

  defp fallback_outcomes(input) do
    input.observations
    |> Enum.map(&bounded(&1.content, 1_000))
    |> Enum.reject(&(&1 == ""))
    |> Enum.take(100)
  end

  defp merge_structured(fallback, structured) when is_map(structured) do
    Map.new(fallback, fn {key, value} ->
      candidate = Map.get(structured, key, Map.get(structured, Atom.to_string(key)))
      {key, valid_field(key, candidate, value)}
    end)
  end

  defp merge_structured(fallback, _invalid), do: fallback

  defp valid_field(key, value, fallback) when key in [:title, :narrative] and is_binary(value),
    do: bounded(value, if(key == :title, do: 500, else: 65_536)) |> empty_fallback(fallback)

  defp valid_field(key, value, fallback)
       when key in [:key_outcomes, :decisions, :files_affected, :unresolved_items] and
              is_list(value) do
    max = if key == :files_affected, do: 500, else: 100

    values =
      value
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&bounded(&1, 1_000))
      |> Enum.reject(&(&1 == ""))
      |> Enum.take(max)

    if values == [], do: fallback, else: values
  end

  defp valid_field(_key, _value, fallback), do: fallback
  defp empty_fallback("", fallback), do: fallback
  defp empty_fallback(value, _fallback), do: value

  defp searchable_content(structured, version) do
    [
      structured.title,
      structured.narrative,
      Enum.join(structured.key_outcomes, "\n"),
      Enum.join(structured.decisions, "\n"),
      Enum.join(structured.files_affected, "\n"),
      Enum.join(structured.unresolved_items, "\n"),
      "processing_version=#{version}"
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp bounded(value, max) when is_binary(value) do
    {:ok, filtered} = Filter.apply_bounded(value, max)
    filtered
  end

  defp bounded(_value, _max), do: ""

  defp exact_partition(input) do
    repo().one(
      from(session in ProjectedSession,
        where:
          session.subject_id == ^input.subject_id and session.host_id == ^input.host_id and
            session.session_id == ^input.session_id,
        select: %{
          host_id: session.host_id,
          client_id: session.client_id,
          scope: session.scope,
          namespace: session.namespace
        }
      )
    )
    |> case do
      %{host_id: host, client_id: client, scope: scope, namespace: namespace} = partition
      when is_binary(host) and is_binary(client) and is_binary(scope) and is_binary(namespace) ->
        {:ok, partition}

      _missing ->
        {:error, :partition_mismatch}
    end
  end

  defp requested_partition(_actual, nil), do: :ok
  defp requested_partition(actual, actual), do: :ok
  defp requested_partition(_actual, _requested), do: {:error, :partition_mismatch}

  defp normalize_partition(partition) do
    normalized =
      Map.new([:host_id, :client_id, :scope, :namespace], fn key ->
        {key, Map.get(partition, key, Map.get(partition, Atom.to_string(key)))}
      end)

    if Enum.all?(normalized, fn {_key, value} -> valid_identifier?(value) end),
      do: {:ok, normalized},
      else: {:error, :invalid_partition}
  end

  defp valid_identifier?(value), do: is_binary(value) and String.trim(value) != ""

  defp current_summary(input) do
    repo().one(
      from(summary in Summary,
        where:
          summary.subject_id == ^input.subject_id and summary.host_id == ^input.host_id and
            summary.session_id == ^input.session_id and
            summary.input_revision == ^input.input_revision and
            summary.processing_version == "summary-v1",
        lock: "FOR SHARE"
      )
    )
  end

  defp current(host_id, session_id, version) do
    repo().one(
      from(crystal in Crystal,
        where:
          crystal.host_id == ^host_id and crystal.source_session_id == ^session_id and
            crystal.processing_version == ^version,
        lock: "FOR UPDATE"
      )
    )
  end

  defp lock_identity(subject_id, version) do
    repo().query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      "crystal:#{subject_id}:#{version}"
    ])
  end

  defp default_enrich(input), do: LLM.crystallize(input)

  defp action_limit(opts) do
    case Keyword.get(opts, :limit, 100) do
      limit when is_integer(limit) and limit in 1..500 -> {:ok, limit}
      _ -> {:error, :invalid_action_limit}
    end
  end

  defp normalize_cursor(nil), do: {:ok, nil}

  defp normalize_cursor(cursor) when is_binary(cursor) do
    with {:ok, json} <- Base.url_decode64(cursor, padding: false),
         {:ok, %{"completed_at" => completed_at, "id" => id}} <- Jason.decode(json),
         {:ok, completed_at, 0} <- DateTime.from_iso8601(completed_at),
         {:ok, _} <- Ecto.UUID.cast(id) do
      {:ok, %{completed_at: completed_at, id: id}}
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  defp normalize_cursor(_), do: {:error, :invalid_cursor}

  defp encode_cursor(crystal) do
    Jason.encode!(%{
      "completed_at" => DateTime.to_iso8601(crystal.completed_at),
      "id" => crystal.id
    })
    |> Base.url_encode64(padding: false)
  end

  defp connected_actions(root_id, partition, limit) do
    sql = """
    WITH RECURSIVE traversal(visited, frontier) AS (
      SELECT ARRAY[id]::uuid[], ARRAY[id]::uuid[] FROM memory_actions
      WHERE id = $1 AND host_id = $2 AND client_id = $3 AND scope = $4 AND namespace = $5
      UNION ALL
      SELECT traversal.visited || next_frontier.ids, next_frontier.ids
      FROM traversal
      CROSS JOIN LATERAL (
        SELECT COALESCE(array_agg(candidate.id ORDER BY candidate.id), ARRAY[]::uuid[]) AS ids
        FROM (
          SELECT DISTINCT
            CASE WHEN edge.source_id = current.id THEN edge.target_id ELSE edge.source_id END AS id
          FROM unnest(traversal.frontier) AS current(id)
          JOIN memory_action_edges edge
            ON edge.source_id = current.id OR edge.target_id = current.id
          JOIN memory_actions adjacent
            ON adjacent.id =
                 CASE WHEN edge.source_id = current.id THEN edge.target_id ELSE edge.source_id END
           AND adjacent.host_id = $2 AND adjacent.client_id = $3
           AND adjacent.scope = $4 AND adjacent.namespace = $5
          WHERE NOT (
            CASE WHEN edge.source_id = current.id THEN edge.target_id ELSE edge.source_id END =
              ANY(traversal.visited)
          )
          ORDER BY id
          LIMIT $6 - cardinality(traversal.visited)
        ) AS candidate
      ) AS next_frontier
      WHERE cardinality(traversal.frontier) > 0 AND cardinality(traversal.visited) < $6
    ), bounded AS (
      SELECT visited FROM traversal ORDER BY cardinality(visited) DESC LIMIT 1
    )
    SELECT DISTINCT action.id, action.title, action.description, action.status, action.project,
           action.created_by, action.tags, action.created_at, action.updated_at
    FROM bounded
    CROSS JOIN unnest(bounded.visited) AS connected(id)
    JOIN memory_actions action ON action.id = connected.id
    ORDER BY action.id
    """

    rows =
      repo().query!(sql, [
        Ecto.UUID.dump!(root_id),
        partition.host_id,
        partition.client_id,
        partition.scope,
        partition.namespace,
        limit + 1
      ]).rows

    cond do
      rows == [] ->
        {:error, :action_not_found}

      length(rows) > limit ->
        {:error, :action_chain_too_large}

      true ->
        {:ok,
         Enum.map(rows, fn [
                             id,
                             title,
                             description,
                             status,
                             project,
                             created_by,
                             tags,
                             created_at,
                             updated_at
                           ] ->
           %{
             id: Ecto.UUID.load!(id),
             title: title,
             description: description,
             status: status,
             project: project,
             created_by: created_by,
             tags: tags || [],
             created_at: created_at,
             updated_at: updated_at
           }
         end)}
    end
  rescue
    _ -> {:error, :invalid_action_id}
  end

  defp terminal_policy(actions, opts) do
    nonterminal = Enum.reject(actions, &(&1.status in ["done", "cancelled"]))

    cond do
      nonterminal == [] ->
        {:ok, false}

      Keyword.get(opts, :allow_nonterminal) == true and
          Keyword.get(opts, :authorized_override) == true ->
        {:ok, true}

      Keyword.get(opts, :allow_nonterminal) == true ->
        {:error, :override_forbidden}

      true ->
        {:error, {:nonterminal_actions, Enum.map(nonterminal, & &1.id)}}
    end
  end

  defp persist_action_chain(actions, partition, override?, opts) do
    ids = Enum.map(actions, & &1.id) |> Enum.sort()
    key = :crypto.hash(:sha256, Enum.join(ids, ":")) |> Base.encode16(case: :lower)
    version = Keyword.get(opts, :processing_version, @action_processing_version)

    repo().transaction(fn ->
      lock_identity("action-chain:#{key}", version)
      actions = lock_action_snapshot!(ids, partition, override?)

      case repo().one(
             from(c in Crystal,
               where:
                 c.host_id == ^partition.host_id and c.client_id == ^partition.client_id and
                   c.scope == ^partition.scope and c.namespace == ^partition.namespace and
                   c.action_chain_key == ^key and c.processing_version == ^version,
               lock: "FOR UPDATE"
             )
           ) do
        %Crystal{} = crystal -> crystal
        nil -> insert_action_crystal(actions, ids, key, version, partition, override?, opts)
      end
    end)
    |> case do
      {:ok, %Crystal{} = crystal} -> {:ok, crystal}
      {:error, reason} -> {:error, reason}
    end
  end

  defp lock_action_snapshot!(ids, partition, override?) do
    actions =
      repo().all(
        from(a in "memory_actions",
          where:
            type(a.id, :binary_id) in ^ids and a.host_id == ^partition.host_id and
              a.client_id == ^partition.client_id and a.scope == ^partition.scope and
              a.namespace == ^partition.namespace,
          order_by: type(a.id, :binary_id),
          select: %{
            id: type(a.id, :binary_id),
            title: a.title,
            description: a.description,
            status: a.status,
            project: a.project,
            created_by: a.created_by,
            tags: a.tags,
            created_at: a.created_at,
            updated_at: a.updated_at
          },
          lock: "FOR SHARE"
        )
      )

    if Enum.map(actions, & &1.id) != ids or
         (not override? and Enum.any?(actions, &(&1.status not in ["done", "cancelled"]))) do
      repo().rollback(:action_chain_changed)
    end

    actions
  end

  defp insert_action_crystal(actions, ids, key, version, partition, override?, opts) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    session_id = "action-chain:#{key}"

    project =
      actions
      |> Enum.map(& &1.project)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> case do
        [one] -> one
        _ -> nil
      end

    title = bounded("Action chain: " <> (actions |> List.first() |> Map.fetch!(:title)), 1_000)

    outcomes =
      actions
      |> Enum.filter(&(&1.status == "done"))
      |> Enum.map(&bounded(&1.title, 1_000))

    unresolved =
      actions
      |> Enum.filter(&(&1.status != "done"))
      |> Enum.map(&bounded(&1.title, 1_000))

    narrative =
      actions
      |> Enum.map(
        &"#{&1.status}: #{&1.title}#{if &1.description, do: " — #{&1.description}", else: ""}"
      )
      |> Enum.join("\n")
      |> bounded(65_536)

    input = %{
      "action_ids" => ids,
      "statuses" => Enum.map(actions, &%{"id" => &1.id, "status" => &1.status}),
      "version" => version
    }

    {:ok, input_revision} = Revision.output_revision(input)

    structured = %{
      title: title,
      narrative: narrative,
      key_outcomes: outcomes,
      decisions: [],
      files_affected: [],
      unresolved_items: unresolved
    }

    output =
      structured
      |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
      |> Map.merge(%{"processing_version" => version, "input_revision" => input_revision})

    {:ok, output_revision} = Revision.output_revision(output)

    memory =
      %Memory{}
      |> Memory.changeset(%{
        content: searchable_content(structured, version),
        memory_type: "episodic",
        scope: partition.scope,
        namespace: partition.namespace,
        agent_id: List.first(actions).created_by || "system",
        host_id: partition.host_id,
        client_id: partition.client_id,
        session_id: session_id,
        tags: ["crystal", "action-chain"],
        metadata: %{
          "kind" => "crystal",
          "source_kind" => "action_chain",
          "project" => project,
          "processing_version" => version
        }
      })
      |> repo().insert!()

    crystal =
      %Crystal{}
      |> Crystal.changeset(%{
        memory_id: memory.id,
        subject_id: "action-chain:#{key}",
        host_id: partition.host_id,
        client_id: partition.client_id,
        scope: partition.scope,
        namespace: partition.namespace,
        source_session_id: session_id,
        source_kind: "action_chain",
        action_chain_key: key,
        title: title,
        project: project,
        narrative: narrative,
        key_outcomes: outcomes,
        decisions: [],
        files_affected: [],
        unresolved_items: unresolved,
        processing_version: version,
        model: nil,
        prompt_version: @action_prompt_version,
        input_revision: input_revision,
        output_revision: output_revision,
        status: "complete",
        started_at: now,
        completed_at: now
      })
      |> repo().insert!()

    repo().insert_all(
      SourceAction,
      Enum.map(
        ids,
        &%{crystal_id: crystal.id, action_id: &1, terminal_override: override?, inserted_at: now}
      )
    )

    insert_lesson_candidates(
      crystal,
      project,
      partition,
      Keyword.get(opts, :lesson_candidates, []),
      now
    )

    crystal
  end

  defp insert_lesson_candidates(_crystal, _project, _partition, [], _now), do: :ok

  defp insert_lesson_candidates(crystal, project, partition, candidates, now)
       when is_list(candidates) do
    candidates
    |> Enum.with_index()
    |> Enum.each(fn {candidate, index} ->
      candidate = Map.new(candidate, fn {k, v} -> {to_string(k), v} end)

      if lesson_memory_id = candidate["lesson_memory_id"] do
        reinforce_lesson(crystal, lesson_memory_id, index, partition, now)
      else
        attrs =
          candidate
          |> Map.merge(%{
            "project" => project || "unknown",
            "session_id" => crystal.source_session_id,
            "source_kind" => "crystal",
            "idempotency_key" => "crystal:#{crystal.id}:lesson:#{index}",
            "confidence" => Map.get(candidate, "confidence", 0.5),
            "evidence" => [
              %{
                source_crystal_id: crystal.id,
                session_id: crystal.source_session_id,
                host_id: partition.host_id,
                evidence_kind: "derives",
                support_score: 1.0
              }
            ]
          })

        case Lessons.create_candidate(attrs, partition, %{
               actor: "crystal",
               request_id: "crystal:#{crystal.id}",
               correlation_id: crystal.id
             }) do
          {:ok, lesson} ->
            repo().insert_all(
              LessonLink,
              [
                %{
                  crystal_id: crystal.id,
                  lesson_memory_id: lesson.memory_id,
                  relation_type: "extracted",
                  inserted_at: now
                }
              ],
              on_conflict: :nothing
            )

          {:error, reason} ->
            repo().rollback({:lesson_candidate_failed, reason})
        end
      end
    end)
  end

  defp reinforce_lesson(crystal, lesson_memory_id, index, partition, now) do
    case Lessons.strengthen(
           lesson_memory_id,
           "independent_evidence",
           "crystal:#{crystal.id}:reinforce:#{index}",
           %{"source_crystal_id" => crystal.id},
           partition,
           %{actor: "crystal", request_id: "crystal:#{crystal.id}", correlation_id: crystal.id}
         ) do
      {:ok, %{lesson: lesson}} ->
        repo().insert_all(
          LessonLink,
          [
            %{
              crystal_id: crystal.id,
              lesson_memory_id: lesson.memory_id,
              relation_type: "reinforced",
              inserted_at: now
            }
          ],
          on_conflict: :nothing
        )

      {:error, reason} ->
        repo().rollback({:lesson_reinforcement_failed, reason})
    end
  end

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
end
