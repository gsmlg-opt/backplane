defmodule Backplane.Memory.Operations.Inventory do
  @moduledoc """
  Trusted-operator inventory across stored memory spaces. This read surface is
  separate from the exact-partition public APIs: optional provenance predicates
  are applied in SQL before the global count, ordering, limit and offset.
  """

  import Ecto.Query

  alias Backplane.Memory.Coordination.Action
  alias Backplane.Memory.Crystals.Crystal
  alias Backplane.Memory.Graph.{Edge, Node}
  alias Backplane.Memory.Lessons.Lesson
  alias Backplane.Memory.Memories.{Memory, Relation}
  alias Backplane.Memory.Profiles.Profile

  alias Backplane.Memory.Projections.{
    ActivityContribution,
    ProjectedObservation,
    ProjectedSession,
    Snapshot,
    State
  }

  alias Backplane.Memory.Events.{Event, Stream}
  alias Backplane.Memory.Recall.Run

  @identity_fields [:memory_space_id, :host_id, :client_id, :source_client_id, :scope, :namespace]
  @source_fields [:memory_space_id, :host_id, :client_id, :scope, :namespace, :project]

  def memories(filters, opts \\ []) do
    query = from(m in Memory, as: :inventory, where: is_nil(m.deleted_at))

    query =
      query
      |> text_filter(:memory_type, opts[:type])
      |> text_filter(:session_id, opts[:session_id])

    query = search(query, opts[:q], [:content])
    fields = Memory.__schema__(:fields) -- [:embedding, :embedding_half]
    query = query |> source_filters(filters) |> select([m], struct(m, ^fields))

    query =
      if opts[:sort] == "oldest",
        do: order_by(query, [m], asc: m.inserted_at, asc: m.id),
        else: order_by(query, [m], desc: m.inserted_at, desc: m.id)

    paginate(query, opts)
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  def actions(filters, opts \\ []) do
    from(a in Action, as: :inventory, order_by: [desc: a.updated_at, desc: a.id])
    |> source_filters(Map.merge(filters, compact(%{project: opts[:project]})))
    |> paginate(opts)
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  def profiles(filters, opts \\ []) do
    from(p in Profile, as: :inventory, order_by: [desc: p.updated_at, desc: p.id])
    |> source_filters(filters)
    |> text_filter(:id, opts[:id])
    |> paginate(opts)
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  def lessons(filters, opts \\ []) do
    query =
      from(l in Lesson,
        join: m in Memory,
        on: m.id == l.memory_id,
        as: :inventory,
        order_by: [desc: l.updated_at, desc: l.memory_id],
        select: m.id
      )

    query = query |> source_filters(Map.merge(filters, compact(%{project: opts[:project]})))
    query = if opts[:status], do: where(query, [l], l.status == ^opts[:status]), else: query

    with {:ok, page} <-
           paginate(query,
             limit: opts[:per_page] || 25,
             offset: ((opts[:page] || 1) - 1) * (opts[:per_page] || 25)
           ) do
      entries =
        Enum.map(page.entries, fn id ->
          {:ok, partition} = identity(:memory, id)
          {:ok, entry} = Backplane.Memory.Lessons.get_admin(id, partition)
          entry
        end)

      per_page = opts[:per_page] || 25

      {:ok,
       Map.merge(page, %{
         entries: entries,
         page: opts[:page] || 1,
         per_page: per_page,
         total_pages: ceil(page.total / per_page)
       })}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  def crystals(filters, opts \\ []) do
    query =
      from(c in Crystal, as: :inventory, order_by: [desc_nulls_last: c.completed_at, desc: c.id])

    query = query |> source_filters(filters) |> search(opts[:q], [:title, :narrative])

    with {:ok, offset} <- cursor_offset(opts[:after]),
         {:ok, page} <- paginate(query, limit: opts[:limit] || 25, offset: offset) do
      {:ok, Map.put(page, :next_cursor, if(page.next_offset, do: "offset:#{page.next_offset}"))}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  def sessions(filters, opts \\ []) do
    query =
      from(s in Snapshot,
        as: :inventory,
        join: state in State,
        on:
          state.projector == s.projector and state.subject_type == s.subject_type and
            state.subject_id == s.subject_id,
        where: s.projector == "session" and s.subject_type == "captured_session",
        order_by: [
          desc: fragment("COALESCE(?->>'started_at', '')", s.read_model),
          asc: s.subject_id
        ],
        select: %{
          memory_space_id: s.memory_space_id,
          source_client_id: s.source_client_id,
          model: s.read_model,
          processing_status: state.status
        }
      )

    query =
      query
      |> source_filters(Map.merge(filters, compact(%{project: opts[:project]})))
      |> text_filter(:session_id, opts[:session_id])

    with {:ok, page} <- paginate(query, opts) do
      entries =
        Enum.map(page.entries, fn row ->
          Map.merge(
            Map.new(
              ~w(host_id client_id scope namespace session_id project status started_at),
              &{String.to_existing_atom(&1), row.model[&1]}
            ),
            Map.drop(row, [:model])
          )
          |> Map.put(:repository_sources, row.model["repository_sources"] || [])
        end)

      {:ok, %{page | entries: entries}}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  def timeline(filters, opts \\ []) do
    if opts[:minimum_importance] == :invalid or opts[:is_error] == :invalid,
      do: throw(:invalid_options)

    query =
      from(o in ProjectedObservation,
        as: :inventory,
        left_join: state in State,
        on:
          state.projector == "observations" and state.subject_type == "captured_session" and
            state.subject_id == o.subject_id,
        order_by: [
          asc: o.occurred_at,
          asc: o.host_id,
          asc: o.session_id,
          asc_nulls_last: o.source_sequence,
          asc: o.event_id
        ],
        select: {o, state.status}
      )

    query = source_filters(query, filters)

    query =
      Enum.reduce([:session_id, :event_type, :tool_name], query, &text_filter(&2, &1, opts[&1]))

    query =
      if is_integer(opts[:minimum_importance]),
        do: where(query, [o], o.importance >= ^opts[:minimum_importance]),
        else: query

    query =
      if is_boolean(opts[:is_error]),
        do: where(query, [o], o.is_error == ^opts[:is_error]),
        else: query

    query =
      if opts[:file_path], do: where(query, [o], ^opts[:file_path] in o.file_paths), else: query

    with {:ok, query} <- time_filters(query, opts, :occurred_at),
         {:ok, page} <- paginate(query, opts) do
      {:ok,
       %{
         page
         | entries:
             Enum.map(page.entries, fn {row, status} ->
               row |> Map.from_struct() |> Map.put(:processing_status, status || "pending")
             end)
       }}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    :invalid_options -> {:error, :invalid_options}
    :exit, _ -> {:error, :unavailable}
  end

  def audit(filters, opts \\ []) do
    query =
      from(a in "memory_audit_log",
        as: :inventory,
        order_by: [desc: a.created_at, desc: a.id],
        select: %{
          id: a.id,
          operation: a.operation,
          actor: a.actor,
          target_ids: a.target_ids,
          metadata: a.metadata,
          created_at: a.created_at
        }
      )

    query =
      query
      |> source_filters(filters)
      |> text_filter(:operation, opts[:operation])
      |> text_filter(:actor, opts[:actor])

    query =
      if opts[:target],
        do:
          where(
            query,
            [a],
            fragment(
              "EXISTS (SELECT 1 FROM jsonb_each_text(CASE WHEN jsonb_typeof(?) = 'object' THEN ? ELSE '{}'::jsonb END) t WHERE t.value = ?) OR ? @> jsonb_build_array(?::text)",
              a.target_ids,
              a.target_ids,
              ^opts[:target],
              a.target_ids,
              ^opts[:target]
            )
          ),
        else: query

    empty_purge =
      dynamic(
        [a],
        a.operation == "memory.activity.purge" and
          fragment("COALESCE(?, '')", a.actor) == "system" and
          fragment(
            "? @> '{\"daily_deleted\":0,\"contributions_deleted\":0}'::jsonb",
            a.metadata
          )
      )

    empty_purge_count =
      query
      |> where(^empty_purge)
      |> exclude(:order_by)
      |> exclude(:select)
      |> select([a], count())
      |> repo().one()

    query =
      if Keyword.get(opts, :include_empty_runs, true),
        do: query,
        else: where(query, ^dynamic([a], not (^empty_purge)))

    with {:ok, result} <- paginate(query, opts) do
      {:ok, Map.put(result, :empty_purge_count, empty_purge_count)}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  def recall(filters, opts \\ []) do
    query = from(r in Run, as: :inventory, order_by: [desc: r.inserted_at, desc: r.id])

    query =
      query
      |> source_filters(filters)
      |> text_filter(:status, opts[:status])
      |> text_filter(:correlation_id, opts[:correlation_id])

    with {:ok, offset} <- cursor_offset(opts[:cursor]),
         {:ok, query} <- time_filters(query, opts, :inserted_at),
         {:ok, page} <- paginate(query, Keyword.put(opts, :offset, offset)) do
      {:ok,
       %{
         runs: page.entries,
         total: page.total,
         next_cursor: if(page.next_offset, do: "offset:#{page.next_offset}")
       }}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  def stages(filters, opts \\ []) do
    sessions = from(s in ProjectedSession, as: :inventory) |> source_filters(filters)
    memories = from(m in Memory, as: :inventory) |> source_filters(filters)

    session_partitions =
      from(s in sessions,
        select:
          fragment(
            "?::text || ':' || ? || ':' || ? || ':' || ? || ':' || ? || ':' || COALESCE(?, '')",
            s.memory_space_id,
            s.host_id,
            s.client_id,
            s.scope,
            s.namespace,
            s.project
          )
      )

    memory_partitions =
      from(m in memories,
        select:
          fragment(
            "?::text || ':' || ? || ':' || ? || ':' || ? || ':' || ? || ':' || COALESCE(?->>'project', '')",
            m.memory_space_id,
            m.host_id,
            m.client_id,
            m.scope,
            m.namespace,
            m.metadata
          )
      )

    query =
      from(s in State,
        as: :inventory,
        left_join: session in subquery(sessions),
        on:
          session.memory_space_id == s.memory_space_id and session.host_id == s.host_id and
            session.scope == s.scope and session.namespace == s.namespace and
            ((s.subject_type == "captured_session" and session.subject_id == s.subject_id) or
               (s.subject_type == "captured_session_window" and
                  fragment("starts_with(?, ? || ':window:')", s.subject_id, session.subject_id))),
        left_join: memory in subquery(memories),
        on:
          s.subject_type == "memory" and fragment("?::text", memory.id) == s.subject_id and
            memory.memory_space_id == s.memory_space_id and memory.host_id == s.host_id and
            memory.scope == s.scope and memory.namespace == s.namespace,
        order_by: [desc: s.updated_at, desc: s.id],
        select: %{
          id: s.id,
          projector: s.projector,
          subject_type: s.subject_type,
          subject_id: s.subject_id,
          status: s.status,
          input_revision: s.input_revision,
          output_revision: s.output_revision,
          attempt_count: s.attempt_count,
          session_id: session.session_id,
          memory_space_id: s.memory_space_id,
          host_id: s.host_id,
          scope: s.scope,
          namespace: s.namespace,
          client_id: session.client_id
        }
      )

    query = source_filters(query, Map.drop(filters, [:client_id, :project, :repository]))

    query =
      if Enum.any?([:client_id, :project, :repository], &Map.has_key?(filters, &1)) do
        profile_subjects =
          from(p in Profile, as: :inventory)
          |> source_filters(filters)
          |> select([p], [
            p.memory_space_id,
            p.host_id,
            p.client_id,
            p.scope,
            p.namespace,
            p.project
          ])
          |> repo().all()
          |> Enum.map(
            &(&1
              |> :erlang.term_to_binary([:deterministic])
              |> Base.url_encode64(padding: false))
          )

        where(
          query,
          [s, session, memory],
          not is_nil(session.subject_id) or not is_nil(memory.id) or
            (s.subject_type == "memory_partition" and s.projector == "procedural" and
               (s.subject_id in subquery(session_partitions) or
                  s.subject_id in subquery(memory_partitions))) or
            (s.subject_type == "memory_profile" and s.projector == "profile" and
               s.subject_id in ^profile_subjects)
        )
      else
        query
      end

    with {:ok, page} <- paginate(query, Keyword.put_new(opts, :limit, 50)) do
      {:ok,
       %{page | entries: Enum.map(page.entries, &Map.put(&1, :reason, stage_reason(&1.status)))}}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  def graph(filters, domain, opts \\ []) do
    nodes = from(n in Node, as: :inventory) |> source_filters(filters)

    edges =
      from(e in Edge, join: source in Node, on: source.id == e.source_id, as: :inventory)
      |> source_filters(filters)

    relations =
      from(r in Relation,
        join: source in Memory,
        on: source.id == r.source_memory_id,
        as: :inventory,
        join: target in Memory,
        on: target.id == r.target_memory_id,
        where:
          source.memory_space_id == target.memory_space_id and source.scope == target.scope and
            source.namespace == target.namespace
      )
      |> source_filters(filters)

    stats = %{
      node_count_by_type:
        nodes
        |> group_by([n], n.type)
        |> select([n], {n.type, count()})
        |> repo().all()
        |> Map.new(),
      edge_count_by_relation:
        edges
        |> group_by([e], e.relation)
        |> select([e], {e.relation, count()})
        |> repo().all()
        |> Map.new(),
      relation_count_by_domain:
        relations
        |> group_by([r], r.domain)
        |> select([r], {r.domain, count()})
        |> repo().all()
        |> Map.new()
    }

    rows =
      relations
      |> where([r], r.domain == ^domain)
      |> order_by([r], desc: r.created_at, desc: r.id)
      |> select([r, source, target], %{
        id: r.id,
        relation_type: r.relation_type,
        status: r.status,
        source_content: source.content,
        target_content: target.content
      })

    {:ok, page} = paginate(rows, Keyword.put_new(opts, :limit, 50))
    {stats, page}
  end

  def activity(filters, opts) do
    from_date = Keyword.fetch!(opts, :date_from)
    to_date = Keyword.fetch!(opts, :date_to)

    query =
      from(c in ActivityContribution,
        as: :inventory,
        where: c.date >= ^from_date and c.date <= ^to_date
      )
      |> source_filters(filters)

    query = Enum.reduce([:project, :agent_id, :event_type], query, &text_filter(&2, &1, opts[&1]))

    counters = [
      :event_count,
      :memory_count,
      :lesson_count,
      :crystal_count,
      :recall_count,
      :action_count,
      :error_count
    ]

    zero = Map.new([:session_count | counters], &{&1, 0})

    totals = fn q ->
      q
      |> select([c], %{
        event_count: type(sum(c.event_count), :integer),
        session_count: count(c.subject_id, :distinct),
        memory_count: type(sum(c.memory_count), :integer),
        lesson_count: type(sum(c.lesson_count), :integer),
        crystal_count: type(sum(c.crystal_count), :integer),
        recall_count: type(sum(c.recall_count), :integer),
        action_count: type(sum(c.action_count), :integer),
        error_count: type(sum(c.error_count), :integer)
      })
    end

    rows =
      query
      |> group_by([c], c.date)
      |> totals.()
      |> select_merge([c], %{date: c.date})
      |> repo().all()
      |> Map.new(&{&1.date, &1})

    first_date =
      rows
      |> Map.values()
      |> Enum.filter(&(&1.event_count > 0))
      |> Enum.map(& &1.date)
      |> Enum.min(Date, fn -> nil end)

    trends =
      if first_date do
        Enum.map(Date.range(first_date, to_date), &Map.get(rows, &1, Map.put(zero, :date, &1)))
      else
        []
      end

    breakdown = fn dimension ->
      query
      |> group_by([c], field(c, ^dimension))
      |> where([c], field(c, ^dimension) != "")
      |> order_by([c], desc: sum(c.event_count), asc: field(c, ^dimension))
      |> limit(100)
      |> select([c], %{
        key: field(c, ^dimension),
        event_count: type(sum(c.event_count), :integer),
        error_count: type(sum(c.error_count), :integer),
        session_count: count(c.subject_id, :distinct)
      })
      |> repo().all()
    end

    summary = query |> totals.() |> repo().one!() |> Map.new(fn {k, v} -> {k, v || 0} end)

    events =
      from(e in Event,
        as: :inventory,
        order_by: [desc: e.occurred_at, desc: e.id],
        limit: 20,
        where:
          e.occurred_at >= ^DateTime.new!(from_date, ~T[00:00:00], "Etc/UTC") and
            e.occurred_at < ^DateTime.new!(Date.add(to_date, 1), ~T[00:00:00], "Etc/UTC"),
        select: %{
          id: e.id,
          event_type: e.event_type,
          project: e.project,
          agent_id: e.agent_id,
          occurred_at: e.occurred_at
        }
      )
      |> source_filters(filters)

    events =
      Enum.reduce([:project, :agent_id, :event_type], events, &text_filter(&2, &1, opts[&1]))

    {:ok,
     %{
       heatmap: trends,
       trends: trends,
       distribution: breakdown.(:event_type),
       project_breakdown: breakdown.(:project),
       agent_breakdown: breakdown.(:agent_id),
       host_breakdown: breakdown.(:host_id),
       recent_events: repo().all(events),
       summary: Map.merge(summary, %{date_from: first_date, date_to: to_date})
     }}
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  def events(filters, raw) do
    with {:ok, normalized} <- Backplane.Memory.Operations.Params.timeline(raw),
         {:ok, cursor} <- event_cursor(normalized.values[:cursor]) do
      opts = Map.to_list(normalized.values)

      query =
        from(e in Event, as: :inventory, order_by: [desc: e.occurred_at, desc: e.id])
        |> source_filters(filters)

      fields = [
        stream: :stream_id,
        project: :project,
        agent: :agent_id,
        session: :session_id,
        run: :run_id,
        type: :event_type,
        tool: :tool_name,
        status: :status
      ]

      query =
        Enum.reduce(fields, query, fn {option, field}, q ->
          text_filter(q, field, normalized.values[option])
        end)

      with {:ok, query} <- time_filters(query, opts, :occurred_at) do
        query =
          if cursor,
            do:
              where(
                query,
                [e],
                e.occurred_at < ^elem(cursor, 0) or
                  (e.occurred_at == ^elem(cursor, 0) and e.id < ^elem(cursor, 1))
              ),
            else: query

        rows = query |> limit(^(normalized.values.limit + 1)) |> repo().all()
        {entries, remaining} = Enum.split(rows, normalized.values.limit)

        next =
          if remaining != [],
            do:
              entries
              |> List.last()
              |> then(
                &Base.url_encode64(
                  Jason.encode!(%{occurred_at: DateTime.to_iso8601(&1.occurred_at), id: &1.id}),
                  padding: false
                )
              )

        {:ok, %{events: entries, next_cursor: next, filters: normalized.query}}
      end
    else
      {:error, :invalid_cursor} -> {:error, {:invalid_param, :cursor, Map.delete(raw, "cursor")}}
      error -> error
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  def streams(filters, raw) do
    with {:ok, normalized} <- Backplane.Memory.Operations.Params.streams(raw),
         {:ok, cursor} <- decode_stream_cursor(normalized.values[:cursor]) do
      query =
        from(s in Stream,
          as: :inventory,
          order_by: [desc_nulls_last: s.last_event_at, desc: s.stream_id]
        )
        |> source_filters(filters)

      query =
        Enum.reduce(
          [
            project: :project,
            agent: :agent_id,
            host: :host_id,
            session: :session_id,
            run: :run_id
          ],
          query,
          fn {option, field}, q -> text_filter(q, field, normalized.values[option]) end
        )

      query =
        case normalized.values[:state] do
          "open" -> where(query, [s], is_nil(s.closed_at))
          "closed" -> where(query, [s], not is_nil(s.closed_at))
          _ -> query
        end

      total = query |> exclude(:order_by) |> select([s], count()) |> repo().one()

      rows =
        query
        |> apply_stream_cursor(cursor)
        |> limit(^(normalized.values.limit + 1))
        |> repo().all()

      {entries, remaining} = Enum.split(rows, normalized.values.limit)
      next_cursor = if remaining != [], do: entries |> List.last() |> encode_stream_cursor()

      {:ok,
       %{streams: entries, total: total, next_cursor: next_cursor, filters: normalized.query}}
    else
      {:error, :invalid_cursor} -> {:error, {:invalid_param, :cursor, Map.delete(raw, "cursor")}}
      error -> error
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp apply_stream_cursor(query, nil), do: query

  defp apply_stream_cursor(query, {:dated, last_event_at, stream_id}) do
    where(
      query,
      [stream],
      stream.last_event_at < ^last_event_at or
        (stream.last_event_at == ^last_event_at and stream.stream_id < ^stream_id) or
        is_nil(stream.last_event_at)
    )
  end

  defp apply_stream_cursor(query, {:undated, stream_id}) do
    where(
      query,
      [stream],
      is_nil(stream.last_event_at) and stream.stream_id < ^stream_id
    )
  end

  defp decode_stream_cursor(nil), do: {:ok, nil}

  defp decode_stream_cursor(cursor) when is_binary(cursor) do
    with {:ok, json} <- Base.url_decode64(cursor, padding: false),
         {:ok, decoded} <- Jason.decode(json) do
      decode_stream_cursor_map(decoded)
    else
      _error -> {:error, :invalid_cursor}
    end
  end

  defp decode_stream_cursor(_cursor), do: {:error, :invalid_cursor}

  defp decode_stream_cursor_map(
         cursor = %{
           "branch" => "dated",
           "last_event_at" => last_event_at,
           "stream_id" => stream_id
         }
       )
       when map_size(cursor) == 3 and is_binary(last_event_at) and
              is_binary(stream_id) and byte_size(stream_id) > 0 do
    case DateTime.from_iso8601(last_event_at) do
      {:ok, datetime, _offset} -> {:ok, {:dated, datetime, stream_id}}
      _error -> {:error, :invalid_cursor}
    end
  end

  defp decode_stream_cursor_map(cursor = %{"branch" => "undated", "stream_id" => stream_id})
       when map_size(cursor) == 2 and is_binary(stream_id) and byte_size(stream_id) > 0 do
    {:ok, {:undated, stream_id}}
  end

  defp decode_stream_cursor_map(_cursor), do: {:error, :invalid_cursor}

  defp encode_stream_cursor(%Stream{last_event_at: nil, stream_id: stream_id}) do
    %{"branch" => "undated", "stream_id" => stream_id}
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp encode_stream_cursor(%Stream{} = stream) do
    %{
      "branch" => "dated",
      "last_event_at" => DateTime.to_iso8601(stream.last_event_at),
      "stream_id" => stream.stream_id
    }
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp event_cursor(nil), do: {:ok, nil}

  defp event_cursor(cursor) do
    with {:ok, decoded} <- Base.url_decode64(cursor, padding: false),
         {:ok, %{"occurred_at" => at, "id" => id}} <- Jason.decode(decoded),
         {:ok, at, _} <- DateTime.from_iso8601(at),
         {:ok, id} <- Ecto.UUID.cast(id),
         do: {:ok, {at, id}},
         else: (_ -> {:error, :invalid_cursor})
  end

  @doc "Resolve an operator-selected record from stored identity; URL source fields are filters, never grants."
  def identity(kind, id, filters \\ %{}) do
    schema =
      case kind do
        :event -> Event
        :memory -> Memory
        :lesson -> Memory
        :crystal -> Crystal
        :action -> Action
        :recall -> Run
        :session -> Snapshot
      end

    query = from(r in schema, as: :inventory)

    query =
      if kind == :session do
        query
        |> where(
          [r],
          r.projector == "session" and fragment("?->>'session_id'", r.read_model) == ^id
        )
      else
        case Ecto.UUID.cast(id) do
          {:ok, id} -> where(query, [r], r.id == ^id)
          _ -> where(query, false)
        end
      end

    query =
      if kind in [:memory, :lesson], do: where(query, [r], is_nil(r.deleted_at)), else: query

    rows = query |> source_filters(filters) |> limit(2) |> repo().all()

    case rows do
      [row] ->
        values =
          if kind == :session,
            do:
              Map.merge(Map.new(row.read_model, fn {k, v} -> {k, v} end), %{
                "memory_space_id" => row.memory_space_id,
                "source_client_id" => row.source_client_id
              }),
            else: Map.from_struct(row)

        {:ok,
         Map.new(@identity_fields, fn key ->
           {key, Map.get(values, key) || Map.get(values, to_string(key))}
         end)}

      _ ->
        {:error, :not_found}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp source_filters(query, filters) do
    query =
      Enum.reduce(@source_fields, query, fn key, q ->
        text_filter(q, key, Map.get(filters, key))
      end)

    case Map.get(filters, :repository) do
      value when is_binary(value) and value != "" ->
        where(
          query,
          [inventory: row],
          fragment(
            """
            EXISTS (
              SELECT 1 FROM (SELECT to_jsonb(?) AS doc, ?::text AS repository) source
              WHERE jsonb_path_query_array(doc, '$.**.repository_sources[*].repository_id') @> jsonb_build_array(repository)
              OR EXISTS (
                SELECT 1 FROM bpm_events event
                WHERE event.memory_space_id::text = COALESCE(doc->>'memory_space_id', doc->'metadata'->>'memory_space_id')
                  AND event.scope = COALESCE(doc->>'scope', doc->'read_model'->>'scope', doc->'metadata'->>'scope')
                  AND event.namespace = COALESCE(doc->>'namespace', doc->'read_model'->>'namespace', doc->'metadata'->>'namespace')
                  AND event.host_id = COALESCE(doc->>'host_id', doc->'read_model'->>'host_id', doc->'metadata'->>'host_id')
                  AND (
                    event.session_id = COALESCE(doc->>'session_id', doc->>'source_session_id', doc->'read_model'->>'session_id',
                      (SELECT ss.read_model->>'session_id' FROM bpm_projection_snapshots ss
                       WHERE ss.projector = 'session' AND ss.subject_type = 'captured_session'
                         AND ss.subject_id = doc->>'subject_id'
                         AND ss.memory_space_id::text = doc->>'memory_space_id'
                         AND ss.scope = doc->>'scope' AND ss.namespace = doc->>'namespace'
                         AND ss.host_id = doc->>'host_id'))
                    OR doc->'source_session_ids' @> jsonb_build_array(event.session_id)
                    OR doc->'source_observation_ids' @> jsonb_build_array(event.id::text)
                    OR doc->'source_records'->'session_ids' @> jsonb_build_array(event.session_id)
                  )
                  AND jsonb_path_query_array(event.payload, '$.**.repository_sources[*].repository_id') @> jsonb_build_array(repository)
              )
              OR EXISTS (
                SELECT 1 FROM bpm_memories memory
                WHERE memory.memory_space_id::text = COALESCE(doc->>'memory_space_id', doc->'metadata'->>'memory_space_id')
                  AND memory.scope = COALESCE(doc->>'scope', doc->'read_model'->>'scope', doc->'metadata'->>'scope')
                  AND memory.namespace = COALESCE(doc->>'namespace', doc->'read_model'->>'namespace', doc->'metadata'->>'namespace')
                  AND (
                    memory.id::text IN (doc->>'memory_id', doc->>'id', doc->>'subject_id')
                    OR doc->'source_memory_ids' @> jsonb_build_array(memory.id::text)
                    OR doc->'source_lesson_ids' @> jsonb_build_array(memory.id::text)
                    OR jsonb_path_query_array(doc->'source_records', '$.**') @> jsonb_build_array(memory.id::text)
                    OR EXISTS (SELECT 1 FROM memory_crystals crystal WHERE crystal.memory_id = memory.id
                      AND (doc->'source_crystal_ids' @> jsonb_build_array(crystal.id::text)
                        OR doc->'source_records'->'crystal_ids' @> jsonb_build_array(crystal.id::text)))
                  )
                  AND jsonb_path_query_array(memory.metadata, '$.**.repository_sources[*].repository_id') @> jsonb_build_array(repository)
              )
            )
            """,
            row,
            ^value
          )
        )

      _ ->
        query
    end
  end

  defp text_filter(query, _key, value) when value in [nil, ""], do: query

  defp text_filter(query, key, value) do
    key = to_string(key)

    where(
      query,
      [inventory: row],
      fragment(
        "COALESCE(to_jsonb(?)->>?::text, to_jsonb(?)->'read_model'->>?::text, to_jsonb(?)->'metadata'->>?::text) = ?",
        row,
        ^key,
        row,
        ^key,
        row,
        ^key,
        ^to_string(value)
      )
    )
  end

  defp search(query, value, fields) when is_binary(value) and value != "" do
    pattern = "%" <> value <> "%"

    predicate =
      Enum.reduce(fields, dynamic(false), fn field, acc ->
        dynamic([inventory: row], ^acc or ilike(field(row, ^field), ^pattern))
      end)

    where(query, ^predicate)
  end

  defp search(query, _value, _fields), do: query

  defp paginate(query, opts) do
    limit = opts[:limit] || 25
    offset = opts[:offset] || 0

    if is_integer(limit) and limit in 1..100 and is_integer(offset) and offset in 0..10_000 do
      total =
        query |> exclude(:order_by) |> exclude(:select) |> select([r], count()) |> repo().one()

      rows = query |> limit(^limit) |> offset(^offset) |> repo().all()

      {:ok,
       %{
         entries: rows,
         total: total,
         next_offset: if(offset + length(rows) < total, do: offset + limit)
       }}
    else
      {:error, :invalid_options}
    end
  end

  defp cursor_offset(nil), do: {:ok, 0}

  defp cursor_offset("offset:" <> raw) do
    case Integer.parse(raw) do
      {n, ""} when n in 0..10_000 -> {:ok, n}
      _ -> {:error, :invalid_cursor}
    end
  end

  defp cursor_offset(_), do: {:error, :invalid_cursor}

  defp time_filters(query, opts, field) do
    Enum.reduce_while(
      [{:occurred_from, :>=}, {:occurred_to, :<=}, {:from, :>=}, {:to, :<=}],
      {:ok, query},
      fn {key, direction}, {:ok, query} ->
        case opts[key] do
          nil ->
            {:cont, {:ok, query}}

          value ->
            parsed =
              if is_struct(value, DateTime),
                do: {:ok, value, 0},
                else: DateTime.from_iso8601(to_string(value))

            case parsed do
              {:ok, datetime, _} ->
                query =
                  if direction == :>=,
                    do: where(query, [row], field(row, ^field) >= ^datetime),
                    else: where(query, [row], field(row, ^field) <= ^datetime)

                {:cont, {:ok, query}}

              _ ->
                {:halt, {:error, :invalid_options}}
            end
        end
      end
    )
  end

  defp stage_reason("failed"), do: "Processing failed. Inspect the source session and retry."

  defp stage_reason("dead_letter"),
    do: "Retry limit reached. Inspect the source session before retrying."

  defp stage_reason("skipped_no_model"), do: "Select a Memory model in Config before retrying."
  defp stage_reason("skipped_disabled"), do: "Stage disabled. Enable its policy before retrying."
  defp stage_reason("complete"), do: "Processing complete."
  defp stage_reason(_), do: "Awaiting processing."
  defp compact(map), do: Map.reject(map, fn {_, v} -> v in [nil, ""] end)
  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
end
