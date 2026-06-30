defmodule Backplane.HostAgent.Memory do
  @moduledoc """
  Public local API for host-agent memory.

  This module owns store transactions and returns JSON-compatible result maps.
  """

  alias Backplane.HostAgent.Memory.{Reducer, Store, UUID7}
  alias ExTurso.Result

  @default_agent_id "local"
  @default_scope "proj_local"
  @methods ~w(remember recall list forget stats slot_read slot_write slot_list facet_tag facet_query)

  @doc "List of local memory methods exposed by the host-agent router."
  def methods, do: @methods

  @doc "True if `method` is a local memory method."
  def valid_method?(method) when is_binary(method), do: method in @methods
  def valid_method?(_method), do: false

  def remember(args, opts \\ []) when is_map(args) do
    store = store(opts)
    config = memory_config(opts)

    with {:ok, content} <- Reducer.required_string(args, "content"),
         {:ok, scope} <- Reducer.resolve_scope(args, config),
         {:ok, facets} <- Reducer.normalize_facets(args),
         hash = Reducer.content_hash(content),
         :ok <- reject_tombstone(store, hash, scope, config) do
      id = UUID7.generate()
      now = timestamp()
      agent_id = agent_id(args, opts)
      session_id = Reducer.optional_string(args, "session_id")
      confidence = normalize_confidence(args)

      transaction(store, fn conn ->
        insert_memory(conn, %{
          id: id,
          content: content,
          content_hash: hash,
          scope: scope,
          agent_id: agent_id,
          session_id: session_id,
          tags_json: facets.tags_json,
          metadata_json: facets.metadata_json,
          confidence: confidence,
          now: now
        })
      end)
    end
  end

  def forget(args, opts \\ []) when is_map(args) do
    store = store(opts)

    with {:ok, id} <- Reducer.required_string(args, "id") do
      case fetch_live_memory(store, id) do
        {:ok, row} ->
          forget_memory(store, row)

        {:error, :not_found} ->
          if fact_exists?(store, id), do: {:error, :read_only_fact}, else: {:error, :not_found}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def recall(args, opts \\ []) when is_map(args) do
    store = store(opts)
    config = memory_config(opts)

    with {:ok, query} <- Reducer.required_string(args, "query"),
         {:ok, scope} <- resolve_read_scope(store, args, config) do
      pattern = Reducer.like_pattern(query)
      limit = Reducer.limit(args)

      sql = """
      SELECT id, content, scope, tags, metadata, confidence, inserted_at, 'local' AS source
      FROM memories
      WHERE deleted_at IS NULL
        AND scope = ?
        AND lower(content) LIKE ? ESCAPE '\\'
      UNION ALL
      SELECT id, content, scope, tags, metadata, 1.0 AS confidence, updated_at AS inserted_at,
             'hub_fact' AS source
      FROM facts
      WHERE scope = ?
        AND lower(content) LIKE ? ESCAPE '\\'
      """

      case Store.query(store, sql, [scope, pattern, scope, pattern]) do
        {:ok, %Result{rows: rows}} ->
          {:ok, %{"hits" => Reducer.rank_hits(rows, query, limit)}}

        {:error, reason} ->
          storage_error(reason)
      end
    end
  end

  def list(args, opts \\ []) when is_map(args) do
    store = store(opts)
    config = memory_config(opts)

    with {:ok, scope} <- resolve_read_scope(store, args, config) do
      q = Reducer.optional_string(args, "q")
      tag = Reducer.optional_string(args, "tag")
      agent_id = Reducer.optional_string(args, "agent_id")
      include_facts? = truthy?(Reducer.value(args, "include_facts", false))
      limit = Reducer.limit(args)
      offset = Reducer.offset(args)

      with {:ok, local_rows} <- list_local_rows(store, scope, q, agent_id),
           {:ok, fact_rows} <-
             list_fact_rows(store, scope, q, include_facts? and is_nil(agent_id)) do
        items =
          (fact_rows ++ local_rows)
          |> Enum.map(&Reducer.row_to_item(&1))
          |> Enum.filter(&matches_tag?(&1, tag))
          |> Enum.sort_by(&{source_sort(&1["source"]), &1["id"]})
          |> Enum.drop(offset)
          |> Enum.take(limit)

        {:ok, %{"items" => items}}
      end
    end
  end

  def stats(args \\ %{}, opts \\ []) when is_map(args) do
    store = store(opts)

    with {:ok, memories} <- grouped_counts(store, "memories", "sync_state", "deleted_at IS NULL"),
         {:ok, outbox} <- grouped_counts(store, "memory_outbox", "state", "1 = 1"),
         {:ok, facts} <- scalar_count(store, "facts"),
         {:ok, tombstones} <- scalar_count(store, "tombstones"),
         {:ok, known_scopes} <- known_scopes(store) do
      {:ok,
       %{
         "memories" => memories,
         "outbox" => outbox,
         "facts" => facts,
         "tombstones" => tombstones,
         "known_scopes" => known_scopes
       }}
    end
  end

  def slot_write(args, opts \\ []) when is_map(args) do
    store = store(opts)
    config = memory_config(opts)

    with {:ok, scope} <- Reducer.resolve_scope(args, config),
         {:ok, key} <- slot_key(args),
         {:ok, value_json} <- slot_value_json(args) do
      now = timestamp()

      sql = """
      INSERT INTO slots(scope, key, value, updated_at)
      VALUES (?, ?, ?, ?)
      ON CONFLICT(scope, key) DO UPDATE SET
        value = excluded.value,
        updated_at = excluded.updated_at
      """

      case Store.execute(store, sql, [scope, key, value_json, now]) do
        {:ok, _result} ->
          {:ok,
           %{
             "scope" => scope,
             "key" => key,
             "value" => Reducer.decode_json(value_json, nil),
             "updated_at" => now
           }}

        {:error, reason} ->
          storage_error(reason)
      end
    end
  end

  def slot_read(args, opts \\ []) when is_map(args) do
    store = store(opts)
    config = memory_config(opts)

    with {:ok, scope} <- resolve_read_scope(store, args, config),
         {:ok, key} <- slot_key(args) do
      case Store.query(
             store,
             "SELECT scope, key, value, updated_at FROM slots WHERE scope = ? AND key = ?",
             [
               scope,
               key
             ]
           ) do
        {:ok, %Result{rows: [row]}} -> {:ok, slot_result(row)}
        {:ok, %Result{rows: []}} -> {:error, :not_found}
        {:error, reason} -> storage_error(reason)
      end
    end
  end

  def slot_list(args, opts \\ []) when is_map(args) do
    store = store(opts)
    config = memory_config(opts)

    with {:ok, scope} <- resolve_read_scope(store, args, config) do
      case Store.query(
             store,
             "SELECT scope, key, value, updated_at FROM slots WHERE scope = ? ORDER BY key",
             [
               scope
             ]
           ) do
        {:ok, %Result{rows: rows}} -> {:ok, %{"slots" => Enum.map(rows, &slot_result/1)}}
        {:error, reason} -> storage_error(reason)
      end
    end
  end

  def facet_tag(args, opts \\ []) when is_map(args) do
    store = store(opts)

    with {:ok, id} <- Reducer.required_string(args, "id"),
         {:ok, row} <- fetch_live_memory(store, id),
         {:ok, tags} <- facet_tags(args, row),
         {:ok, metadata} <- facet_metadata(args, row),
         {:ok, tags_json} <- Reducer.encode_json(tags),
         {:ok, metadata_json} <- Reducer.encode_json(metadata) do
      now = timestamp()

      case Store.execute(
             store,
             "UPDATE memories SET tags = ?, metadata = ?, updated_at = ? WHERE id = ? AND deleted_at IS NULL",
             [tags_json, metadata_json, now, id]
           ) do
        {:ok, %Result{num_rows: 1}} ->
          {:ok,
           %{
             "id" => id,
             "scope" => row["scope"],
             "tags" => tags,
             "metadata" => metadata
           }}

        {:ok, _result} ->
          {:error, :not_found}

        {:error, reason} ->
          storage_error(reason)
      end
    end
  end

  def facet_query(args, opts \\ []) when is_map(args) do
    store = store(opts)
    config = memory_config(opts)

    with {:ok, scope} <- resolve_read_scope(store, args, config),
         {:ok, facet} <- query_facet(args) do
      tag = Reducer.optional_string(args, "tag")

      with {:ok, rows} <- list_local_rows(store, scope, Reducer.optional_string(args, "q"), nil) do
        items =
          rows
          |> Enum.map(&Reducer.row_to_item(&1))
          |> Enum.filter(&(matches_tag?(&1, tag) and matches_facet?(&1, facet)))
          |> Enum.take(Reducer.limit(args))

        {:ok, %{"items" => items}}
      end
    end
  end

  defp insert_memory(conn, attrs) do
    insert_sql = """
    INSERT INTO memories(
      id, content, content_hash, scope, agent_id, session_id, tags, metadata,
      confidence, sync_state, inserted_at, updated_at
    )
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?, ?)
    ON CONFLICT DO NOTHING
    """

    params = [
      attrs.id,
      attrs.content,
      attrs.content_hash,
      attrs.scope,
      attrs.agent_id,
      attrs.session_id,
      attrs.tags_json,
      attrs.metadata_json,
      attrs.confidence,
      attrs.now,
      attrs.now
    ]

    case Store.execute(conn, insert_sql, params) do
      {:ok, %Result{num_rows: 1}} ->
        insert_outbox(conn, "remember", attrs.id, attrs.now, fn ->
          %{
            "id" => attrs.id,
            "scope" => attrs.scope,
            "dedup" => false,
            "sync_state" => "pending"
          }
        end)

      {:ok, %Result{num_rows: 0}} ->
        case fetch_live_memory_by_hash(conn, attrs.content_hash, attrs.scope) do
          {:ok, row} ->
            %{
              "id" => row["id"],
              "scope" => row["scope"],
              "dedup" => true,
              "sync_state" => row["sync_state"]
            }

          {:error, reason} ->
            DBConnection.rollback(conn, reason)
        end

      {:error, reason} ->
        DBConnection.rollback(conn, {:storage_error, reason})
    end
  end

  defp forget_memory(store, row) do
    now = timestamp()

    transaction(store, fn conn ->
      case Store.execute(
             conn,
             """
             UPDATE memories
             SET deleted_at = ?, updated_at = ?, sync_state = 'pending'
             WHERE id = ? AND deleted_at IS NULL
             """,
             [now, now, row["id"]]
           ) do
        {:ok, %Result{num_rows: 1}} ->
          insert_outbox(conn, "forget", row["id"], now, fn ->
            %{"id" => row["id"], "scope" => row["scope"], "sync_state" => "pending"}
          end)

        {:ok, _result} ->
          DBConnection.rollback(conn, :not_found)

        {:error, reason} ->
          DBConnection.rollback(conn, {:storage_error, reason})
      end
    end)
  end

  defp insert_outbox(conn, op, memory_id, now, result_fun) do
    case Store.execute(
           conn,
           """
           INSERT INTO memory_outbox(op, memory_id, inserted_at, updated_at)
           VALUES (?, ?, ?, ?)
           """,
           [op, memory_id, now, now]
         ) do
      {:ok, _result} -> result_fun.()
      {:error, reason} -> DBConnection.rollback(conn, {:storage_error, reason})
    end
  end

  defp transaction(store, fun) do
    case Store.transaction(store, fun) do
      {:ok, value} -> {:ok, value}
      {:error, {:storage_error, _reason} = error} -> {:error, error}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reject_tombstone(_store, _hash, _scope, %{tombstone_relearn: "allow_with_log"}), do: :ok

  defp reject_tombstone(_store, _hash, _scope, %{"tombstone_relearn" => "allow_with_log"}),
    do: :ok

  defp reject_tombstone(store, hash, scope, _config) do
    case Store.query(
           store,
           "SELECT content_hash FROM tombstones WHERE content_hash = ? AND scope = ? LIMIT 1",
           [hash, scope]
         ) do
      {:ok, %Result{rows: []}} -> :ok
      {:ok, %Result{rows: [_row | _]}} -> {:error, :wiped}
      {:error, reason} -> storage_error(reason)
    end
  end

  defp fetch_live_memory(store, id) do
    case Store.query(
           store,
           """
           SELECT id, content, content_hash, scope, agent_id, session_id, tags, metadata,
                  confidence, sync_state, remote_id, synced_at, inserted_at, updated_at
           FROM memories
           WHERE id = ? AND deleted_at IS NULL
           LIMIT 1
           """,
           [id]
         ) do
      {:ok, %Result{rows: [row]}} -> {:ok, row}
      {:ok, %Result{rows: []}} -> {:error, :not_found}
      {:error, reason} -> storage_error(reason)
    end
  end

  defp fetch_live_memory_by_hash(store, hash, scope) do
    case Store.query(
           store,
           """
           SELECT id, scope, sync_state
           FROM memories
           WHERE content_hash = ? AND scope = ? AND deleted_at IS NULL
           LIMIT 1
           """,
           [hash, scope]
         ) do
      {:ok, %Result{rows: [row]}} -> {:ok, row}
      {:ok, %Result{rows: []}} -> {:error, :not_found}
      {:error, reason} -> storage_error(reason)
    end
  end

  defp fact_exists?(store, id) do
    case Store.query(store, "SELECT id FROM facts WHERE id = ? LIMIT 1", [id]) do
      {:ok, %Result{rows: [_row | _]}} -> true
      _ -> false
    end
  end

  defp resolve_read_scope(store, args, config) do
    bound_scope = Map.get(config, :bound_scope, Map.get(config, "bound_scope", @default_scope))

    case Reducer.optional_string(args, "scope") do
      nil ->
        {:ok, bound_scope}

      ^bound_scope ->
        {:ok, bound_scope}

      scope ->
        if known_scope?(store, scope), do: {:ok, scope}, else: {:error, :unknown_scope}
    end
  end

  defp known_scope?(store, scope) do
    sql = """
    SELECT scope FROM memories WHERE scope = ? LIMIT 1
    UNION ALL
    SELECT scope FROM facts WHERE scope = ? LIMIT 1
    UNION ALL
    SELECT scope FROM tombstones WHERE scope = ? LIMIT 1
    UNION ALL
    SELECT scope FROM slots WHERE scope = ? LIMIT 1
    """

    case Store.query(store, sql, [scope, scope, scope, scope]) do
      {:ok, %Result{rows: [_row | _]}} -> true
      _ -> false
    end
  end

  defp list_local_rows(store, scope, q, agent_id) do
    {clauses, params} =
      {["deleted_at IS NULL", "scope = ?"], [scope]}
      |> add_optional_clause(q, "lower(content) LIKE ? ESCAPE '\\'", fn value ->
        Reducer.like_pattern(value)
      end)
      |> add_optional_clause(agent_id, "agent_id = ?", & &1)

    sql = """
    SELECT id, content, scope, tags, metadata, confidence, inserted_at, 'local' AS source
    FROM memories
    WHERE #{Enum.join(clauses, " AND ")}
    ORDER BY inserted_at DESC, id ASC
    """

    case Store.query(store, sql, params) do
      {:ok, %Result{rows: rows}} -> {:ok, rows}
      {:error, reason} -> storage_error(reason)
    end
  end

  defp list_fact_rows(_store, _scope, _q, false), do: {:ok, []}

  defp list_fact_rows(store, scope, q, true) do
    {clauses, params} =
      {["scope = ?"], [scope]}
      |> add_optional_clause(q, "lower(content) LIKE ? ESCAPE '\\'", fn value ->
        Reducer.like_pattern(value)
      end)

    sql = """
    SELECT id, content, scope, tags, metadata, 1.0 AS confidence, updated_at AS inserted_at,
           'hub_fact' AS source
    FROM facts
    WHERE #{Enum.join(clauses, " AND ")}
    ORDER BY updated_at DESC, id ASC
    """

    case Store.query(store, sql, params) do
      {:ok, %Result{rows: rows}} -> {:ok, rows}
      {:error, reason} -> storage_error(reason)
    end
  end

  defp add_optional_clause({clauses, params}, nil, _clause, _mapper), do: {clauses, params}

  defp add_optional_clause({clauses, params}, value, clause, mapper) do
    {clauses ++ [clause], params ++ [mapper.(value)]}
  end

  defp grouped_counts(store, table, column, where) do
    case Store.query(
           store,
           "SELECT #{column} AS name, COUNT(*) AS count FROM #{table} WHERE #{where} GROUP BY #{column}"
         ) do
      {:ok, %Result{rows: rows}} ->
        {:ok, Map.new(rows, fn row -> {row["name"], row["count"]} end)}

      {:error, reason} ->
        storage_error(reason)
    end
  end

  defp scalar_count(store, table) do
    case Store.query(store, "SELECT COUNT(*) AS count FROM #{table}") do
      {:ok, %Result{rows: [%{"count" => count}]}} -> {:ok, count}
      {:error, reason} -> storage_error(reason)
    end
  end

  defp known_scopes(store) do
    sql = """
    SELECT DISTINCT scope
    FROM (
      SELECT scope FROM memories
      UNION ALL SELECT scope FROM facts
      UNION ALL SELECT scope FROM tombstones
      UNION ALL SELECT scope FROM slots
    )
    ORDER BY scope
    """

    case Store.query(store, sql) do
      {:ok, %Result{rows: rows}} -> {:ok, Enum.map(rows, & &1["scope"])}
      {:error, reason} -> storage_error(reason)
    end
  end

  defp slot_key(args) do
    case Reducer.optional_string(args, "key") || Reducer.optional_string(args, "name") do
      nil -> {:error, {:invalid_args, "key is required"}}
      key -> {:ok, key}
    end
  end

  defp slot_value_json(args) do
    cond do
      Map.has_key?(args, "value") -> Reducer.encode_json(args["value"])
      Map.has_key?(args, :value) -> Reducer.encode_json(args[:value])
      Map.has_key?(args, "content") -> Reducer.encode_json(args["content"])
      Map.has_key?(args, :content) -> Reducer.encode_json(args[:content])
      true -> {:error, {:invalid_args, "value is required"}}
    end
  end

  defp slot_result(row) do
    %{
      "scope" => row["scope"],
      "key" => row["key"],
      "value" => Reducer.decode_json(row["value"], nil),
      "updated_at" => row["updated_at"]
    }
  end

  defp facet_tags(args, row) do
    if Map.has_key?(args, "tags") or Map.has_key?(args, :tags) do
      Reducer.normalize_tags(Reducer.value(args, "tags", []))
    else
      {:ok, Reducer.decode_json(row["tags"], [])}
    end
  end

  defp facet_metadata(args, row) do
    if Map.has_key?(args, "metadata") or Map.has_key?(args, :metadata) do
      Reducer.normalize_metadata(Reducer.value(args, "metadata", %{}))
    else
      {:ok, Reducer.decode_json(row["metadata"], %{})}
    end
  end

  defp query_facet(args) do
    case Reducer.value(args, "facet", Reducer.value(args, "metadata", %{})) do
      nil -> {:ok, %{}}
      facet when is_map(facet) -> Reducer.normalize_metadata(facet)
      _other -> {:error, {:invalid_args, "facet must be an object"}}
    end
  end

  defp matches_tag?(_item, nil), do: true
  defp matches_tag?(item, tag), do: tag in item["tags"]

  defp matches_facet?(_item, facet) when facet == %{}, do: true

  defp matches_facet?(item, facet) do
    metadata = item["metadata"] || %{}
    Enum.all?(facet, fn {key, value} -> Map.get(metadata, key) == value end)
  end

  defp source_sort("hub_fact"), do: 0
  defp source_sort(_source), do: 1

  defp store(opts), do: Keyword.get(opts, :store, Store)

  defp memory_config(opts) do
    opts
    |> Keyword.get(:config, %{})
    |> case do
      %{memory: memory} when is_map(memory) -> memory
      %{"memory" => memory} when is_map(memory) -> memory
      memory when is_map(memory) -> memory
      _other -> %{}
    end
    |> Map.put_new(:bound_scope, @default_scope)
    |> Map.put_new(:tombstone_relearn, "block")
  end

  defp agent_id(args, opts) do
    Keyword.get(opts, :agent_id) ||
      Reducer.optional_string(args, "agent_id") ||
      @default_agent_id
  end

  defp normalize_confidence(args) do
    case Reducer.value(args, "confidence", 1.0) do
      value when is_integer(value) -> value * 1.0
      value when is_float(value) -> value
      _other -> 1.0
    end
  end

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(1), do: true
  defp truthy?(_value), do: false

  defp timestamp do
    DateTime.utc_now()
    |> DateTime.truncate(:microsecond)
    |> DateTime.to_iso8601()
  end

  defp storage_error(reason), do: {:error, {:storage_error, reason}}
end
