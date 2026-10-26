defmodule Backplane.HostAgent.Memory do
  @moduledoc """
  Host Memory API and authority-bound command store.

  Core methods route through MemoryFacade and Access; only slots are device-local.
  This module owns command-store transactions and JSON-compatible receipts.
  """

  alias Backplane.HostAgent.Memory.{Access, Reducer, Store, UUID7}
  alias Backplane.HostAgent.Memory.Mirror.Store, as: MirrorStore
  alias Turso.Result

  @default_agent_id "local"
  @default_scope "proj_local"
  @overlay_cap 100
  @overlay_query_limit @overlay_cap + 1
  @methods ~w(remember recall list forget stats slot_read slot_write slot_list facet_tag facet_query)

  @doc "List of local memory methods exposed by the host-agent router."
  def methods, do: @methods

  @doc "True if `method` is a local memory method."
  def valid_method?(method) when is_binary(method), do: method in @methods
  def valid_method?(_method), do: false

  @doc false
  def shared_enqueue(target, operation, args, agent) do
    with true <- Access.local_owner?(target),
         {:ok, normalized} <- shared_arguments(operation, args, agent),
         {:ok, normalized} <- command_dependency(target, operation, normalized, agent),
         key = args["idempotency_key"],
         true <- is_nil(key) or (is_binary(key) and byte_size(key) in 1..512) do
      identity = %{
        "op" => operation,
        "access" => Access.claim(target),
        "partition" => target.partition,
        "arguments" => normalized
      }

      digest = MirrorStore.hash(identity)

      if byte_size(Jason.encode!(identity)) > 500_000 do
        {:error, :payload_too_large}
      else
        transaction(target.store, fn conn ->
          prior =
            if key,
              do:
                List.first(
                  rows!(
                    conn,
                    "SELECT * FROM memory_outbox WHERE request_agent_id=? AND access_id=? AND op=? AND request_key=?",
                    [agent, target.access_id, operation, key]
                  )
                )

          if prior do
            if prior["payload_digest"] != digest,
              do: DBConnection.rollback(conn, :idempotency_conflict)

            Map.put(shared_receipt!(conn, prior["command_id"], target), "dedup", true)
          else
            id = UUID7.generate()
            payload = Map.put(identity, "command_id", id)

            execute!(
              conn,
              "INSERT INTO memory_outbox(op,memory_id,payload,command_id,access_id,authority_version,target_partition,payload_digest,request_key,request_agent_id,inserted_at,updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
              [
                operation,
                id,
                Jason.encode!(payload),
                id,
                target.access_id,
                target.authority_version,
                Jason.encode!(target.partition),
                digest,
                key,
                agent,
                timestamp(),
                timestamp()
              ]
            )

            Map.put(shared_receipt!(conn, id, target), "dedup", false)
          end
        end)
      end
    else
      false -> {:error, :invalid_request}
      error -> error
    end
  end

  defp command_dependency(target, "forget", %{"id" => id} = args, agent) do
    case Store.query(
           target.store,
           "SELECT command_id FROM memory_outbox WHERE command_id=? AND access_id=? AND authority_version=? AND target_partition=? AND request_agent_id=? AND op='remember'",
           [
             id,
             target.access_id,
             target.authority_version,
             Jason.encode!(target.partition),
             agent
           ]
         ) do
      {:ok, %Result{rows: [%{"command_id" => command}]}} ->
        {:ok, Map.put(args, "remember_command_id", command)}

      {:ok, %Result{rows: []}} ->
        {:ok, args}

      {:error, reason} ->
        storage_error(reason)
    end
  end

  defp command_dependency(_target, _operation, args, _agent), do: {:ok, args}

  defp shared_arguments("remember", args, agent) do
    args = Backplane.HostAgent.Memory.GitContext.enrich_arguments(args)

    normalized =
      args
      |> Map.drop(~w(scope idempotency_key))
      |> Map.put_new("agent_id", agent)
      |> Map.put_new("type", "semantic")
      |> Map.put_new("tags", [])
      |> Map.put_new("metadata", %{})
      |> Map.put_new("facets", [])

    with {:ok, _} <- Reducer.required_string(normalized, "content"),
         {:ok, _} <- normalize_command(normalized),
         true <-
           Enum.all?(
             Map.keys(normalized),
             &(&1 in ~w(content type tags metadata agent_id session_id facets))
           ),
         true <-
           is_list(normalized["tags"]) and length(normalized["tags"]) <= 100 and
             Enum.all?(normalized["tags"], &(is_binary(&1) and byte_size(&1) in 1..512)),
         true <-
           is_map(normalized["metadata"]) and
             not Enum.any?(
               ~w(host_memory host_memory_command_revision requesting_actor),
               &Map.has_key?(normalized["metadata"], &1)
             ),
         true <-
           byte_size(normalized["content"]) <= 262_144 and
             not String.contains?(normalized["content"], <<0>>) do
      {:ok, normalized}
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp shared_arguments("forget", args, _agent) do
    normalized = Map.drop(args, ~w(scope idempotency_key agent_id))

    if map_size(normalized) == 1 and is_binary(normalized["id"]) and
         Regex.match?(
           ~r/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/,
           normalized["id"]
         ),
       do: {:ok, normalized},
       else: {:error, :invalid_request}
  end

  @doc false
  def shared_receipt(target, id) do
    if Access.local_owner?(target),
      do: transaction(target.store, &shared_receipt!(&1, id, target)),
      else: {:error, :unauthorized}
  end

  defp shared_receipt!(conn, id, target) do
    case rows!(
           conn,
           "SELECT command_id,state,ack_canonical_id,ack_revision,last_error FROM memory_outbox WHERE command_id=? AND access_id=? AND authority_version=? AND target_partition=?",
           [id, target.access_id, target.authority_version, Jason.encode!(target.partition)]
         ) do
      [row] ->
        if row["state"] == "dead_letter",
          do: DBConnection.rollback(conn, {:command_rejected, row["last_error"]})

        %{
          "command_id" => id,
          "status" => if(row["state"] == "done", do: "committed", else: "pending"),
          "canonical_id" => row["ack_canonical_id"],
          "revision" => row["ack_revision"],
          "authority" => if(row["state"] == "done", do: "canonical", else: "provisional"),
          "consistency" =>
            if(row["state"] == "done", do: "canonical", else: "pending_canonical_ack")
        }

      _ ->
        DBConnection.rollback(conn, :not_found)
    end
  end

  @doc false
  def shared_claim(context, now, max_attempts) do
    if Access.local_owner?(context) do
      transaction(context.store, fn conn ->
        {:ok, utc, _} = DateTime.from_iso8601(now)
        stale_before = utc |> DateTime.add(-10, :second) |> DateTime.to_iso8601()

        execute!(
          conn,
          "UPDATE memory_outbox SET state=CASE WHEN attempts+1>=? THEN 'dead_letter' ELSE 'retry_wait' END,attempts=attempts+1,next_attempt_at=?,last_error='recovered after restart',updated_at=? WHERE access_id IS NOT NULL AND state='inflight' AND updated_at<?",
          [max_attempts, now, now, stale_before]
        )

        rows =
          rows!(
            conn,
            "SELECT * FROM memory_outbox WHERE access_id IS NOT NULL AND (state='pending' OR (state='retry_wait' AND next_attempt_at<=?)) ORDER BY seq LIMIT 50",
            [now]
          )

        {accepted, _bytes} =
          Enum.reduce(rows, {[], 0}, fn row, {acc, bytes} ->
            entry = context.accesses[row["access_id"]]
            size = byte_size(row["payload"])

            dependency =
              get_in(Jason.decode!(row["payload"]), ["arguments", "remember_command_id"])

            dependency_ready =
              is_nil(dependency) or
                Enum.any?(acc, &(&1["command_id"] == dependency)) or
                rows!(
                  conn,
                  "SELECT command_id FROM memory_outbox WHERE command_id=? AND state='done' AND ack_canonical_id IS NOT NULL",
                  [dependency]
                ) != []

            if (dependency_ready and entry) && entry.status != "fenced" &&
                 entry.authority_version == row["authority_version"] &&
                 Access.allowed_operation?(row["op"], entry.capabilities) &&
                 "memory_commands.v2" in context.extensions &&
                 (row["op"] not in ~w(source_mutate source_reconcile) or
                    ("memory_sources.v1" in context.extensions and
                       (get_in(Jason.decode!(row["payload"]), [
                          "arguments",
                          "source",
                          "integration"
                        ]) != "openclaw" or
                          "openclaw_source.v1" in context.extensions))) &&
                 bytes + size < 500_000 do
              execute!(
                conn,
                "UPDATE memory_outbox SET state='inflight',updated_at=? WHERE seq=?",
                [now, row["seq"]]
              )

              {[row | acc], bytes + size}
            else
              {acc, bytes}
            end
          end)

        Enum.reverse(accepted)
      end)
    else
      {:error, :unauthorized}
    end
  end

  @doc false
  def shared_settle(context, rows, reply, now, max_attempts) do
    if Access.local_owner?(context) do
      transaction(context.store, fn conn ->
        case reply do
          {:ok, %{"protocol" => "memory_commands.v2", "items" => items} = batch}
          when is_list(items) ->
            valid =
              byte_size(Jason.encode!(batch)) <= 524_288 and length(items) == length(rows) and
                Enum.all?(Enum.zip(rows, items), fn {row, ack} -> shared_ack?(row, ack) end)

            if not valid, do: DBConnection.rollback(conn, :invalid_ack)

            fences =
              Enum.flat_map(Enum.zip(rows, items), fn {row, ack} ->
                rejected = ack["status"] == "rejected"

                execute!(
                  conn,
                  "UPDATE memory_outbox SET state=?,ack_canonical_id=?,ack_revision=?,ack_partition=?,last_error=?,completed_at=?,dead_lettered_at=?,next_attempt_at=NULL,updated_at=?,ack_result=? WHERE command_id=? AND state IN ('inflight','dead_letter')",
                  [
                    if(rejected, do: "dead_letter", else: "done"),
                    ack["canonical_id"],
                    ack["revision"],
                    row["target_partition"],
                    ack["code"],
                    if(not rejected, do: now),
                    if(rejected, do: now),
                    now,
                    if(ack["source_result"], do: Jason.encode!(ack["source_result"])),
                    row["command_id"]
                  ]
                )

                if rejected and
                     ack["code"] in ~w(unauthorized authority_changed partition_mismatch),
                   do: [{row["access_id"], row["authority_version"]}],
                   else: []
              end)

            %{drained: length(rows), fences: Enum.uniq(fences)}

          {:error, reason} ->
            permanent = not Backplane.HostAgent.MemoryFacade.transport_error?(reason)

            Enum.each(rows, fn row ->
              dead = permanent or row["attempts"] + 1 >= max_attempts

              execute!(
                conn,
                "UPDATE memory_outbox SET state=?,attempts=attempts+1,last_error=?,next_attempt_at=?,dead_lettered_at=?,updated_at=? WHERE command_id=? AND state='inflight'",
                [
                  if(dead, do: "dead_letter", else: "retry_wait"),
                  if(permanent, do: "unauthorized", else: "transport_failure"),
                  if(not dead, do: now),
                  if(dead, do: now),
                  now,
                  row["command_id"]
                ]
              )
            end)

            %{
              drained: 0,
              fences:
                if(permanent and shared_fence_error?(reason),
                  do: Enum.map(rows, &{&1["access_id"], &1["authority_version"]}),
                  else: []
                )
            }

          _ ->
            DBConnection.rollback(conn, :invalid_ack)
        end
      end)
    else
      {:error, :unauthorized}
    end
  end

  defp shared_fence_error?(%{"reason" => reason}), do: shared_fence_error?(reason)

  defp shared_fence_error?(reason),
    do:
      reason in [
        :unauthorized,
        :authority_changed,
        :partition_mismatch,
        :invalid_protocol,
        "unauthorized",
        "authority_changed",
        "partition_mismatch",
        "invalid_protocol"
      ]

  defp shared_ack?(row, ack) when is_map(ack) do
    payload = Jason.decode!(row["payload"])

    ack["command_id"] == row["command_id"] and ack["access"] == payload["access"] and
      ack["partition"] == payload["partition"] and
      case ack["status"] do
        status when status in ["committed", "duplicate"] ->
          if row["op"] in ~w(source_mutate source_reconcile) do
            is_map(ack["source_result"]) and
              ack["source_result"]["protocol"] == "memory_sources.v1" and
              ack["source_result"]["event_id"] == row["command_id"]
          else
            is_binary(ack["canonical_id"]) and
              Regex.match?(
                ~r/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/,
                ack["canonical_id"]
              ) and
              ((is_integer(ack["revision"]) and ack["revision"] > 0) or
                 (is_nil(ack["revision"]) and ack["mirror_status"] == "not_eligible"))
          end

        "rejected" ->
          ack["code"] in ~w(unauthorized authority_changed partition_mismatch not_found invalid_request idempotency_conflict)

        _ ->
          false
      end
  end

  defp shared_ack?(_, _), do: false

  @doc false
  def shared_overlay(target, method, args, mode, revision) do
    if Access.local_owner?(target) do
      {clauses, filters} = overlay_remember_filters(args, method)

      sql = """
      SELECT memory.* FROM (
        SELECT *, NULL AS deleted_at, json_extract(payload, '$.arguments.content') AS content,
          json_extract(payload, '$.arguments.type') AS memory_type,
          json_extract(payload, '$.arguments.tags') AS tags,
          json_extract(payload, '$.arguments.metadata') AS metadata,
          json_extract(payload, '$.arguments.agent_id') AS agent_id
        FROM memory_outbox
      ) AS memory
      WHERE access_id=? AND authority_version=? AND target_partition=?
        AND (state IN ('pending','inflight','retry_wait') OR (? AND state='done' AND (ack_revision>? OR ack_revision IS NULL)))
        AND (op='forget' OR (op='remember' AND #{Enum.join(clauses, " AND ")}))
      """

      params =
        [
          target.access_id,
          target.authority_version,
          Jason.encode!(target.partition),
          if(mode == :offline, do: 1, else: 0),
          revision || -1
        ] ++ filters

      with :ok <- read_filter_support(method, args, mode, false),
           :ok <- check_overlay_support(target.store, sql, params, method, args, mode),
           {:ok, visible, truncated?} <-
             shared_overlay_rows(target.store, sql, params, method) do
        upserts =
          for row <- visible,
              row["op"] == "remember",
              item = Jason.decode!(row["payload"])["arguments"],
              do:
                Map.merge(item, %{
                  "id" => row["ack_canonical_id"] || row["command_id"],
                  "canonical_id" => row["ack_canonical_id"],
                  "memory_type" => item["type"],
                  "scope" => target.partition["scope"],
                  "source" => "shared_command",
                  "authority" => if(row["state"] == "done", do: "canonical", else: "provisional"),
                  "provisional" => row["state"] != "done"
                })

        deletes =
          for row <- visible,
              row["op"] == "forget",
              do: row["delete_id"] || Jason.decode!(row["payload"])["arguments"]["id"]

        {:ok,
         %{
           "upserts" => if(method == "stats", do: [], else: upserts),
           "delete_ids" => deletes,
           "pending_operations" => Enum.count(visible, &(&1["state"] != "done")),
           "acknowledged_operations" => Enum.count(visible, &(&1["state"] == "done")),
           "overlay_truncated" => truncated?
         }}
      end
    else
      {:error, :unauthorized}
    end
  end

  defp shared_overlay_rows(store, sql, params, "stats") do
    case Store.query(store, sql <> " ORDER BY seq DESC LIMIT ?", params ++ [@overlay_query_limit]) do
      {:ok, %Result{rows: rows}} ->
        {:ok, Enum.take(rows, @overlay_cap), length(rows) > @overlay_cap}

      {:error, reason} ->
        storage_error(reason)
    end
  end

  defp shared_overlay_rows(store, sql, params, _method),
    do:
      read_overlay_rows(
        store,
        sql,
        params,
        "COALESCE((SELECT parent.ack_canonical_id FROM memory_outbox parent WHERE parent.command_id=json_extract(eligible.payload, '$.arguments.remember_command_id')),json_extract(payload, '$.arguments.id'))"
      )

  # Forget identities suppress canonical rows regardless of how many content rows fit.
  # The unbounded query projects identifiers and state only, never memory content.
  defp read_overlay_rows(store, sql, params, delete_id_sql) do
    with {:ok, %Result{rows: remembers}} <-
           Store.query(
             store,
             "SELECT * FROM (#{sql}) AS eligible WHERE op='remember' ORDER BY seq DESC LIMIT ?",
             params ++ [@overlay_query_limit]
           ),
         {:ok, %Result{rows: forgets}} <-
           Store.query(
             store,
             "SELECT seq, op, state, #{delete_id_sql} AS delete_id FROM (#{sql}) AS eligible WHERE op='forget' ORDER BY seq DESC",
             params
           ) do
      {:ok, Enum.take(remembers, @overlay_cap) ++ forgets, length(remembers) > @overlay_cap}
    else
      {:error, reason} -> storage_error(reason)
    end
  end

  @doc false
  def read_filter_support(method, args, mode, eligible_upserts?, mirror? \\ false) do
    fields = unsupported_read_filters(method, args, mirror?)

    if fields != [] and (mode == :offline or eligible_upserts?),
      do: {:error, {:unsupported_filter, fields}},
      else: :ok
  end

  defp unsupported_read_filters("recall", args, _mirror?) do
    explicit =
      Enum.filter(
        ~w(agent_id host_id tag channel_weights include_working),
        &(not is_nil(Reducer.value(args, &1)))
      )

    collections =
      Enum.filter(
        ~w(facets temporal_hints entity_hints),
        &nonempty_collection?(Reducer.value(args, &1))
      )

    Enum.sort(explicit ++ collections)
  end

  defp unsupported_read_filters("list", args, mirror?) do
    []
    |> then(fn fields -> if wildcard_query?(args), do: ["q" | fields], else: fields end)
    |> then(fn fields ->
      if mirror? and Reducer.value(args, "offset", 0) > 0, do: ["offset" | fields], else: fields
    end)
    |> then(fn fields ->
      if mirror? and not is_nil(Reducer.value(args, "agent_id")),
        do: ["agent_id" | fields],
        else: fields
    end)
    |> Enum.sort()
  end

  defp unsupported_read_filters(_method, _args, _mirror?), do: []

  defp wildcard_query?(args) do
    case Reducer.value(args, "q") do
      value when is_binary(value) -> String.contains?(value, ["%", "_", "\\"])
      _ -> false
    end
  end

  defp check_overlay_support(store, sql, params, method, args, mode) do
    if mode == :offline or unsupported_read_filters(method, args, false) == [] do
      read_filter_support(method, args, mode, false)
    else
      case Store.query(
             store,
             "SELECT 1 FROM (#{sql}) AS candidates WHERE op='remember' LIMIT 1",
             params
           ) do
        {:ok, %Result{rows: rows}} -> read_filter_support(method, args, mode, rows != [])
        {:error, reason} -> storage_error(reason)
      end
    end
  end

  @doc false
  def read_item_matches?(method, args, item) do
    metadata = item["metadata"] || %{}
    project = Reducer.value(args, "project")

    query =
      if method == "recall", do: Reducer.value(args, "query"), else: Reducer.value(args, "q")

    type = item["memory_type"] || item["type"]

    (is_nil(query) or
       String.contains?(String.downcase(item["content"] || ""), String.downcase(query))) and
      (is_nil(project) or project == "" or
         (is_map(metadata) and is_binary(metadata["project"]) and metadata["project"] == project)) and
      (method != "recall" or type != "working") and
      (is_nil(read_value(args, "type")) or args["type"] == type) and
      (is_nil(read_value(args, "tag")) or args["tag"] in (item["tags"] || []))
  end

  def remember(args, opts \\ []) when is_map(args),
    do: command_call("remember", args, opts)

  def forget(args, opts \\ []) when is_map(args),
    do: command_call("forget", args, opts)

  defp command_call(method, args, opts) do
    context =
      opts
      |> Map.new()
      |> Map.merge(%{
        agent_id: agent_id(args, opts),
        access_server: Keyword.get(opts, :access_server, Access),
        sync_opts: Keyword.get(opts, :sync_opts, [])
      })

    Backplane.HostAgent.MemoryFacade.call(method, args, context)
  end

  defp rows!(conn, sql, params) do
    case Store.query(conn, sql, params) do
      {:ok, %Result{rows: rows}} -> rows
      {:error, reason} -> DBConnection.rollback(conn, {:storage_error, reason})
    end
  end

  defp execute!(conn, sql, params) do
    case Store.execute(conn, sql, params) do
      {:ok, result} -> result
      {:error, reason} -> DBConnection.rollback(conn, {:storage_error, reason})
    end
  end

  defp normalize_command(args) do
    type = Reducer.value(args, "type", "semantic")
    facets = Reducer.value(args, "facets", [])
    key = Reducer.value(args, "idempotency_key")

    cond do
      type not in ~w(working episodic semantic procedural) ->
        {:error, {:invalid_args, "unsupported memory type"}}

      not is_list(facets) or
          not Enum.all?(facets, fn
            %{"dimension" => dimension, "value" => value}
            when is_binary(dimension) and dimension != "" and is_binary(value) and value != "" ->
              true

            _ ->
              false
          end) ->
        {:error, {:invalid_args, "facets must contain dimension and value strings"}}

      not is_nil(key) and (not is_binary(key) or String.trim(key) == "") ->
        {:error, {:invalid_args, "idempotency_key must be a nonempty string"}}

      true ->
        {:ok, %{"type" => type, "facets" => facets, "idempotency_key" => key}}
    end
  end

  def recall(args, opts \\ []) when is_map(args), do: command_call("recall", args, opts)
  def list(args, opts \\ []) when is_map(args), do: command_call("list", args, opts)
  def stats(args \\ %{}, opts \\ []) when is_map(args), do: command_call("stats", args, opts)

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

  def facet_tag(args, opts \\ []) when is_map(args), do: command_call("facet_tag", args, opts)
  def facet_query(args, opts \\ []) when is_map(args), do: command_call("facet_query", args, opts)

  defp overlay_remember_filters(args, method) do
    query =
      if method == "list" and wildcard_query?(args),
        do: nil,
        else: read_value(args, "query") || read_value(args, "q")

    project = read_value(args, "project")

    {clauses, params} =
      {[], []}
      |> add_optional_clause(query, "instr(lower(memory.content), lower(?)) > 0", & &1)
      |> add_optional_clause(read_value(args, "type"), "memory.memory_type = ?", & &1)
      |> add_optional_clause(read_value(args, "agent_id"), "memory.agent_id = ?", & &1)
      |> add_optional_clause(
        read_value(args, "tag"),
        "EXISTS (SELECT 1 FROM json_each(COALESCE(memory.tags, '[]')) WHERE value = ?)",
        & &1
      )
      |> add_optional_clause(
        project,
        "(json_type(memory.metadata, '$.project') = 'text' AND json_extract(memory.metadata, '$.project') = ?)",
        & &1
      )

    clauses =
      if method == "recall" and Reducer.value(args, "include_working") != true,
        do: ["memory.memory_type != 'working'" | clauses],
        else: clauses

    clauses = ["memory.deleted_at IS NULL" | clauses]
    {clauses, params}
  end

  defp nonempty_collection?(value) when is_map(value), do: map_size(value) > 0
  defp nonempty_collection?(value) when is_list(value), do: value != []
  defp nonempty_collection?(_value), do: false

  defp read_value(args, key) do
    case Reducer.value(args, key) do
      "" -> nil
      value -> value
    end
  end

  defp transaction(store, fun) do
    case Store.transaction(store, fun) do
      {:ok, value} -> {:ok, value}
      {:error, {:storage_error, _reason} = error} -> {:error, error}
      {:error, reason} -> {:error, reason}
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
    case Store.query(store, "SELECT scope FROM slots WHERE scope=? LIMIT 1", [scope]) do
      {:ok, %Result{rows: [_ | _]}} -> true
      _ -> false
    end
  end

  defp add_optional_clause({clauses, params}, nil, _clause, _mapper), do: {clauses, params}

  defp add_optional_clause({clauses, params}, value, clause, mapper) do
    {clauses ++ [clause], params ++ [mapper.(value)]}
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

  defp timestamp do
    DateTime.utc_now()
    |> DateTime.truncate(:microsecond)
    |> DateTime.to_iso8601()
  end

  defp storage_error(reason), do: {:error, {:storage_error, reason}}
end
