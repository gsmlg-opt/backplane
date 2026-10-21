defmodule Backplane.HostAgent.Memory do
  @moduledoc """
  Public local API for host-agent memory.

  This module owns store transactions and returns JSON-compatible result maps.
  """

  alias Backplane.HostAgent.Memory.{Access, Reducer, Store, UUID7}
  alias Backplane.HostAgent.Memory.Mirror.Store, as: MirrorStore
  alias Turso.Result

  @default_agent_id "local"
  @default_scope "proj_local"
  @overlay_cap 100
  @overlay_query_limit @overlay_cap + 1
  @methods ~w(remember recall list forget stats slot_read slot_write slot_list facet_tag facet_query)
  @request_fields ~w(content scope agent_id session_id tags metadata confidence type facets idempotency_key)

  @doc "List of local memory methods exposed by the host-agent router."
  def methods, do: @methods

  @doc "True if `method` is a local memory method."
  def valid_method?(method) when is_binary(method), do: method in @methods
  def valid_method?(_method), do: false

  @doc false
  def shared_enqueue(target, operation, args, agent) do
    with true <- Access.local_owner?(target),
         {:ok, normalized} <- shared_arguments(operation, args, agent),
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

            shared_receipt!(conn, prior["command_id"], target)
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

            shared_receipt!(conn, id, target)
          end
        end)
      end
    else
      false -> {:error, :invalid_request}
      error -> error
    end
  end

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

            if entry && entry.status != "fenced" &&
                 entry.authority_version == row["authority_version"] &&
                 row["op"] in entry.capabilities && "memory_commands.v2" in context.extensions &&
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
                  "UPDATE memory_outbox SET state=?,ack_canonical_id=?,ack_revision=?,ack_partition=?,last_error=?,completed_at=?,dead_lettered_at=?,next_attempt_at=NULL,updated_at=? WHERE command_id=? AND state IN ('inflight','dead_letter')",
                  [
                    if(rejected, do: "dead_letter", else: "done"),
                    ack["canonical_id"],
                    ack["revision"],
                    row["target_partition"],
                    ack["code"],
                    if(not rejected, do: now),
                    if(rejected, do: now),
                    now,
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
          is_binary(ack["canonical_id"]) and is_integer(ack["revision"]) and ack["revision"] > 0

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
      with {:ok, %Result{rows: rows}} <-
             Store.query(
               target.store,
               "SELECT * FROM memory_outbox WHERE access_id=? AND authority_version=? AND target_partition=? AND (state IN ('pending','inflight','retry_wait') OR (? AND state='done' AND ack_revision>?)) ORDER BY seq DESC LIMIT 101",
               [
                 target.access_id,
                 target.authority_version,
                 Jason.encode!(target.partition),
                 if(mode == :offline, do: 1, else: 0),
                 revision || -1
               ]
             ) do
        visible = Enum.take(rows, 100)

        upserts =
          for row <- visible,
              row["op"] == "remember",
              payload = Jason.decode!(row["payload"]),
              item = payload["arguments"],
              shared_visible?(item, args),
              do:
                Map.merge(item, %{
                  "id" => row["ack_canonical_id"] || row["command_id"],
                  "canonical_id" => row["ack_canonical_id"],
                  "scope" => target.partition["scope"],
                  "source" => "shared_command"
                })

        deletes =
          for row <- visible,
              row["op"] == "forget",
              do: Jason.decode!(row["payload"])["arguments"]["id"]

        {:ok,
         %{
           "upserts" => if(method == "stats", do: [], else: upserts),
           "delete_ids" => deletes,
           "pending_operations" => Enum.count(visible, &(&1["state"] != "done")),
           "acknowledged_operations" => Enum.count(visible, &(&1["state"] == "done")),
           "overlay_truncated" => length(rows) > 100
         }}
      end
    else
      {:error, :unauthorized}
    end
  end

  defp shared_visible?(item, args) do
    query = args["query"] || args["q"] || ""

    String.contains?(String.downcase(item["content"]), String.downcase(query)) and
      (is_nil(args["type"]) or args["type"] == item["type"]) and
      (is_nil(args["tag"]) or args["tag"] in item["tags"]) and
      (is_nil(args["agent_id"]) or args["agent_id"] == item["agent_id"])
  end

  def remember(args, opts \\ []) when is_map(args) do
    args = Backplane.HostAgent.Memory.GitContext.enrich_arguments(args)
    store = store(opts)
    config = memory_config(opts)

    with {:ok, content} <- Reducer.required_string(args, "content"),
         {:ok, scope} <- Reducer.resolve_scope(args, config),
         {:ok, facets} <- Reducer.normalize_facets(args),
         {:ok, command} <- normalize_command(args),
         hash = Reducer.content_hash(content),
         :ok <- reject_tombstone(store, hash, scope, config) do
      id = UUID7.generate()
      now = timestamp()
      agent_id = agent_id(args, opts)
      session_id = Reducer.optional_string(args, "session_id")
      confidence = normalize_confidence(args)

      transaction(store, fn conn ->
        attrs = %{
          id: id,
          content: content,
          content_hash: hash,
          scope: scope,
          agent_id: agent_id,
          session_id: session_id,
          tags_json: facets.tags_json,
          metadata_json: facets.metadata_json,
          confidence: confidence,
          now: now,
          command: command,
          partition: Keyword.get(opts, :edge_partition, %{})
        }

        remember_command(conn, attrs)
      end)
    end
  end

  def forget(args, opts \\ []) when is_map(args) do
    store = store(opts)

    with {:ok, id} <- Reducer.required_string(args, "id") do
      case fetch_live_memory(store, id) do
        {:ok, row} ->
          if row["agent_id"] == agent_id(args, opts),
            do: forget_memory(store, row),
            else: {:error, :not_found}

        {:error, :not_found} ->
          if fact_exists?(store, id) do
            {:error, :read_only_fact}
          else
            forget_canonical(store, id, opts)
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc "Records only identities returned by a successful canonical read in its authorized partition."
  def record_canonical_result(result, partition, opts) do
    items = Map.get(result, "results", Map.get(result, "items", Map.get(result, "hits", [])))

    ids =
      items
      |> Enum.map(&(Map.get(&1, "canonical_id") || Map.get(&1, "id")))
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    case transaction(store(opts), fn conn ->
           for id <- ids do
             execute!(
               conn,
               "INSERT INTO canonical_memory_receipts(canonical_id, memory_space_id, scope, namespace, agent_id, received_at) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT DO NOTHING",
               [
                 id,
                 partition["memory_space_id"],
                 partition["scope"],
                 partition["namespace"],
                 agent_id(%{}, opts),
                 timestamp()
               ]
             )
           end
         end) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp forget_canonical(store, id, opts) do
    transaction(store, fn conn ->
      scope = memory_config(opts) |> Map.fetch!(:bound_scope)

      receipts =
        rows!(
          conn,
          "SELECT * FROM canonical_memory_receipts WHERE canonical_id = ? AND scope = ? AND agent_id = ?",
          [id, scope, agent_id(%{}, opts)]
        )

      receipts =
        case Keyword.get(opts, :edge_partition) do
          nil ->
            receipts

          partition ->
            Enum.filter(
              receipts,
              &(Map.take(&1, ["memory_space_id", "scope", "namespace"]) == partition)
            )
        end

      case receipts do
        [receipt] ->
          partition = Map.take(receipt, ["memory_space_id", "scope", "namespace"])
          command_id = "canonical:" <> id

          prior =
            rows!(
              conn,
              "SELECT state, last_error, ack_revision FROM memory_outbox WHERE memory_id = ? AND op = 'forget' ORDER BY seq DESC LIMIT 1",
              [command_id]
            )
            |> List.first()

          case prior do
            %{"state" => "dead_letter", "last_error" => error} ->
              DBConnection.rollback(conn, {:command_rejected, error})

            _ ->
              :ok
          end

          if is_nil(prior) do
            now = timestamp()

            payload =
              Map.merge(partition, %{
                "op" => "forget",
                "id" => command_id,
                "canonical_id" => id,
                "agent_id" => agent_id(%{}, opts)
              })

            execute!(
              conn,
              "INSERT INTO memory_outbox(op, memory_id, payload, inserted_at, updated_at) VALUES ('forget', ?, ?, ?, ?)",
              [command_id, Jason.encode!(payload), now, now]
            )
          end

          %{
            "id" => id,
            "canonical_id" => id,
            "scope" => partition["scope"],
            "sync_state" => if(prior && prior["state"] == "done", do: "synced", else: "pending"),
            "revision" => prior && prior["ack_revision"]
          }

        _ ->
          DBConnection.rollback(conn, :not_found)
      end
    end)
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

  defp remember_command(conn, attrs) do
    key = attrs.command["idempotency_key"]

    request =
      Map.merge(attrs.command, %{
        "content" => attrs.content,
        "scope" => attrs.scope,
        "agent_id" => attrs.agent_id,
        "session_id" => attrs.session_id,
        "tags" => Jason.decode!(attrs.tags_json),
        "metadata" => Jason.decode!(attrs.metadata_json),
        "confidence" => attrs.confidence
      })

    hash = "v2:" <> Reducer.content_hash(Jason.encode!(ordered_json(request)))

    prior =
      if key do
        case Store.query(
               conn,
               "SELECT memory_id, request_hash FROM memory_request_keys WHERE agent_id = ? AND scope = ? AND idempotency_key = ?",
               [attrs.agent_id, attrs.scope, key]
             ) do
          {:ok, %Result{rows: rows}} -> List.first(rows)
          {:error, reason} -> DBConnection.rollback(conn, {:storage_error, reason})
        end
      end

    result =
      case prior do
        %{"request_hash" => stored_hash, "memory_id" => id} ->
          unless stored_hash == hash or legacy_request_matches?(conn, id, stored_hash, request),
            do: DBConnection.rollback(conn, :idempotency_conflict)

          if stored_hash != hash do
            execute!(
              conn,
              "UPDATE memory_request_keys SET request_hash = ? WHERE agent_id = ? AND scope = ? AND idempotency_key = ? AND memory_id = ?",
              [hash, attrs.agent_id, attrs.scope, key, id]
            )
          end

          case fetch_live_memory(conn, id) do
            {:ok, row} ->
              %{
                "id" => id,
                "scope" => row["scope"],
                "sync_state" => row["sync_state"],
                "dedup" => true,
                "canonical_id" => row["remote_id"],
                "revision" => row["remote_revision"]
              }

            {:error, reason} ->
              DBConnection.rollback(conn, reason)
          end

        nil ->
          insert_memory(conn, attrs)
      end

    if not is_nil(key) and is_nil(prior),
      do:
        execute!(
          conn,
          "INSERT INTO memory_request_keys(agent_id, scope, idempotency_key, request_hash, memory_id) VALUES (?, ?, ?, ?, ?)",
          [attrs.agent_id, attrs.scope, key, hash, result["id"]]
        )

    result
  end

  # Atom-keyed map enumeration depends on VM atom creation order. Sort every
  # JSON object by its string keys, including nested metadata and facet objects.
  defp ordered_json(value) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, item} -> {key, ordered_json(item)} end)
    |> Jason.OrderedObject.new()
  end

  defp ordered_json(value) when is_list(value), do: Enum.map(value, &ordered_json/1)
  defp ordered_json(value), do: value

  # A legacy hash cannot be reconstructed reliably across VM boots. Only the
  # immutable original outbox payload can prove equality; mutable memory rows
  # and absent/pruned payloads must never authorize a fingerprint upgrade.
  defp legacy_request_matches?(conn, id, stored_hash, request) do
    with true <- is_binary(stored_hash) and Regex.match?(~r/\A[0-9a-f]{64}\z/, stored_hash),
         [%{"payload" => encoded}] <-
           rows!(
             conn,
             "SELECT payload FROM memory_outbox WHERE memory_id = ? AND op = 'remember' ORDER BY seq LIMIT 1",
             [id]
           ),
         true <- is_binary(encoded),
         {:ok, %{"id" => ^id, "op" => "remember"} = payload} <- Jason.decode(encoded),
         true <- Enum.all?(@request_fields, &Map.has_key?(payload, &1)) do
      Map.take(payload, @request_fields) === request
    else
      _ -> false
    end
  end

  @doc "Returns unresolved host commands that may be overlaid on canonical reads."
  def pending_overlay(args, opts \\ []) when is_map(args) do
    store = store(opts)
    config = memory_config(opts)

    with {:ok, scope} <- resolve_read_scope(store, args, config) do
      method = Keyword.get(opts, :method)

      result =
        case method do
          "stats" -> pending_overlay_stats(store, scope, opts)
          _method -> pending_overlay_rows(store, scope, args, method, opts)
        end

      with {:ok, overlay} <- result,
           {:ok, commands} <- acknowledged_overlay(store, scope, args, opts) do
        overlay =
          if method == "stats" do
            overlay
          else
            overlay
            |> Map.update("delete_ids", commands.delete_ids, &(&1 ++ commands.delete_ids))
            |> Map.update("upserts", commands.upserts, &(&1 ++ commands.upserts))
          end

        {:ok,
         overlay
         |> Map.update!("pending_operations", &(&1 + commands.pending))
         |> Map.put("acknowledged_operations", commands.acknowledged)
         |> Map.update!("overlay_truncated", &(&1 or commands.truncated))}
      end
    end
  end

  defp acknowledged_overlay(store, scope, args, opts) do
    offline = Keyword.get(opts, :overlay_mode) == :offline
    partition = Keyword.get(opts, :edge_partition)
    revision = Keyword.get(opts, :mirror_revision, -1) || -1

    {partition_clause, partition_params} =
      if is_map(partition) do
        {"AND COALESCE(json_extract(outbox.ack_partition, '$.memory_space_id'), json_extract(outbox.payload, '$.memory_space_id'), memory.memory_space_id) = ? AND COALESCE(json_extract(outbox.ack_partition, '$.namespace'), json_extract(outbox.payload, '$.namespace'), memory.namespace) = ?",
         [partition["memory_space_id"], partition["namespace"]]}
      else
        {"", []}
      end

    stats? = Keyword.get(opts, :method) == "stats"

    fields =
      if stats? do
        "outbox.state, COUNT(*) AS operation_count"
      else
        "outbox.seq, outbox.op, outbox.state, outbox.payload, outbox.ack_revision, outbox.ack_canonical_id, memory.id, memory.content, memory.scope, memory.tags, memory.facets, memory.metadata, memory.confidence, memory.remote_id, memory.memory_type, memory.agent_id"
      end

    suffix = if stats?, do: "GROUP BY outbox.state", else: "ORDER BY outbox.seq DESC LIMIT ?"

    params =
      [scope] ++ partition_params ++ [if(offline and is_map(partition), do: 1, else: 0), revision]

    params = if stats?, do: params, else: params ++ [@overlay_query_limit]

    sql = """
    SELECT #{fields}
    FROM memory_outbox AS outbox LEFT JOIN memories AS memory ON memory.id = outbox.memory_id
    WHERE outbox.access_id IS NULL AND COALESCE(json_extract(outbox.ack_partition, '$.scope'), json_extract(outbox.payload, '$.scope'), memory.scope) = ?
      #{partition_clause}
      AND (outbox.op = 'forget' OR memory.id IS NOT NULL)
      AND NOT EXISTS (SELECT 1 FROM memory_outbox newer WHERE newer.memory_id = outbox.memory_id AND newer.seq > outbox.seq)
      AND ((outbox.state IN ('pending','inflight','retry_wait') AND json_extract(outbox.payload, '$.canonical_id') IS NOT NULL)
        OR (? AND outbox.state = 'done' AND (outbox.ack_revision IS NULL OR outbox.ack_revision > ?)))
    #{suffix}
    """

    case Store.query(store, sql, params) do
      {:ok, %Result{rows: rows}} when stats? ->
        acknowledged =
          Enum.find_value(rows, 0, fn row ->
            if row["state"] == "done", do: row["operation_count"]
          end)

        pending =
          Enum.reduce(rows, 0, fn row, count ->
            if row["state"] != "done", do: count + row["operation_count"], else: count
          end)

        {:ok,
         %{
           upserts: [],
           delete_ids: [],
           pending: pending,
           acknowledged: acknowledged,
           truncated: pending + acknowledged > @overlay_cap
         }}

      {:ok, %Result{rows: rows}} ->
        rows =
          Enum.filter(rows, fn row -> row["op"] == "forget" or overlay_visible?(row, args) end)

        commands = Enum.take(rows, @overlay_cap)

        result =
          Enum.reduce(
            commands,
            %{
              upserts: [],
              delete_ids: [],
              pending: 0,
              acknowledged: 0,
              truncated: length(rows) > @overlay_cap
            },
            fn row, acc ->
              acc =
                if row["state"] == "done",
                  do: %{acc | acknowledged: acc.acknowledged + 1},
                  else: %{acc | pending: acc.pending + 1}

              case row["op"] do
                "forget" ->
                  payload = Reducer.decode_json(row["payload"], %{})

                  %{
                    acc
                    | delete_ids:
                        acc.delete_ids ++
                          [
                            row["ack_canonical_id"] || payload["canonical_id"] || row["remote_id"] ||
                              row["id"]
                          ]
                  }

                "remember" ->
                  item =
                    provisional_item(row)
                    |> Map.merge(%{
                      "authority" => "canonical",
                      "provisional" => false,
                      "source" => "acknowledged_command",
                      "revision" => row["ack_revision"]
                    })

                  %{acc | upserts: acc.upserts ++ [item]}
              end
            end
          )

        {:ok, result}

      {:error, reason} ->
        storage_error(reason)
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
      confidence, sync_state, inserted_at, updated_at, memory_type, facets, memory_space_id, namespace
    )
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?, ?, ?, ?, ?, ?)
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
      attrs.now,
      attrs.command["type"],
      Jason.encode!(attrs.command["facets"]),
      attrs.partition["memory_space_id"],
      attrs.partition["namespace"]
    ]

    case Store.execute(conn, insert_sql, params) do
      {:ok, %Result{num_rows: 1}} ->
        payload =
          attrs.command
          |> Map.merge(%{
            "id" => attrs.id,
            "op" => "remember",
            "content" => attrs.content,
            "content_hash" => attrs.content_hash,
            "scope" => attrs.scope,
            "agent_id" => attrs.agent_id,
            "session_id" => attrs.session_id,
            "tags" => Jason.decode!(attrs.tags_json),
            "metadata" => Jason.decode!(attrs.metadata_json),
            "confidence" => attrs.confidence,
            "inserted_at" => attrs.now,
            "updated_at" => attrs.now
          })
          |> Map.merge(attrs.partition)

        insert_outbox(
          conn,
          "remember",
          attrs.id,
          attrs.now,
          fn ->
            %{
              "id" => attrs.id,
              "scope" => attrs.scope,
              "dedup" => false,
              "sync_state" => "pending"
            }
          end,
          payload
        )

      {:ok, %Result{num_rows: 0}} ->
        case fetch_live_memory_by_hash(
               conn,
               attrs.content_hash,
               attrs.scope,
               attrs.command["type"],
               attrs.agent_id
             ) do
          {:ok, row} ->
            %{
              "id" => row["id"],
              "scope" => row["scope"],
              "dedup" => true,
              "sync_state" => row["sync_state"],
              "canonical_id" => row["remote_id"],
              "revision" => row["remote_revision"]
            }

          {:error, reason} ->
            DBConnection.rollback(conn, reason)
        end

      {:error, reason} ->
        DBConnection.rollback(conn, {:storage_error, reason})
    end
  end

  defp pending_partition_filter(opts) do
    case Keyword.get(opts, :edge_partition) do
      %{"memory_space_id" => space, "namespace" => namespace} ->
        {"AND (memory.memory_space_id IS NULL OR (memory.memory_space_id = ? AND memory.namespace = ?))",
         [space, namespace]}

      _ ->
        {"", []}
    end
  end

  defp pending_overlay_rows(store, scope, args, "list", opts) do
    if Keyword.get(opts, :overlay_mode) == :offline do
      pending_overlay_offline_list(store, scope, args, opts)
    else
      pending_overlay_combined_rows(store, scope, args, opts)
    end
  end

  defp pending_overlay_rows(store, scope, args, _method, opts) do
    pending_overlay_combined_rows(store, scope, args, opts)
  end

  defp pending_overlay_combined_rows(store, scope, args, opts) do
    {partition_sql, partition_params} = pending_partition_filter(opts)
    {remember_clauses, remember_params} = overlay_remember_filters(args)
    remember_filter = Enum.join(remember_clauses, " AND ")

    sql = """
    SELECT outbox.seq, outbox.op, memory.id, memory.content, memory.scope, memory.tags,
           memory.metadata, memory.confidence, memory.remote_id, memory.memory_type,
           memory.agent_id, memory.facets
    FROM memory_outbox AS outbox
    INNER JOIN memories AS memory ON memory.id = outbox.memory_id
    WHERE outbox.access_id IS NULL AND outbox.state IN ('pending', 'inflight', 'retry_wait')
      AND memory.sync_state != 'synced'
      AND memory.scope = ?
      #{partition_sql}
      AND NOT EXISTS (
        SELECT 1
        FROM memory_outbox AS newer
        WHERE newer.memory_id = outbox.memory_id AND newer.seq > outbox.seq
      )
      AND (
        outbox.op = 'forget'
        OR (outbox.op = 'remember' AND #{remember_filter})
    )
    ORDER BY outbox.seq DESC
    LIMIT ?
    """

    params = [scope] ++ partition_params ++ remember_params ++ [@overlay_query_limit]

    case Store.query(store, sql, params) do
      {:ok, %Result{rows: rows}} ->
        truncated? = length(rows) > @overlay_cap

        visible_rows =
          rows
          |> Enum.take(@overlay_cap)
          |> Enum.filter(&overlay_visible?(&1, args))

        {:ok, overlay_from_rows(visible_rows, truncated?)}

      {:error, reason} ->
        storage_error(reason)
    end
  end

  defp pending_overlay_offline_list(store, scope, args, opts) do
    {partition_sql, partition_params} = pending_partition_filter(opts)
    {remember_clauses, remember_params} = overlay_remember_filters(args)
    remember_filter = Enum.join(remember_clauses, " AND ")

    remember_sql = """
    SELECT outbox.seq, outbox.op, memory.id, memory.content, memory.scope, memory.tags,
           memory.metadata, memory.confidence, memory.remote_id, memory.memory_type,
           memory.agent_id, memory.facets
    FROM memory_outbox AS outbox
    INNER JOIN memories AS memory ON memory.id = outbox.memory_id
    WHERE outbox.access_id IS NULL AND outbox.state IN ('pending', 'inflight', 'retry_wait')
      AND memory.sync_state != 'synced'
      AND memory.scope = ?
      #{partition_sql}
      AND NOT EXISTS (
        SELECT 1
        FROM memory_outbox AS newer
        WHERE newer.memory_id = outbox.memory_id AND newer.seq > outbox.seq
      )
      AND outbox.op = 'remember'
      AND #{remember_filter}
    ORDER BY outbox.seq DESC
    LIMIT ?
    OFFSET ?
    """

    remember_params =
      [scope] ++
        partition_params ++ remember_params ++ [@overlay_query_limit, Reducer.offset(args)]

    with {:ok, %Result{rows: remember_rows}} <- Store.query(store, remember_sql, remember_params),
         bounded_remembers =
           remember_rows
           |> Enum.take(@overlay_cap)
           |> Enum.filter(&overlay_visible?(&1, args)),
         remaining = @overlay_cap - length(bounded_remembers),
         {:ok, %Result{rows: forget_rows}} <-
           pending_overlay_forget_rows(store, scope, remaining, opts) do
      truncated? =
        length(remember_rows) > @overlay_cap or length(forget_rows) > remaining

      overlay =
        (bounded_remembers ++ Enum.take(forget_rows, remaining))
        |> overlay_from_rows(truncated?)
        |> maybe_mark_offset_applied(true)

      {:ok, overlay}
    else
      {:error, reason} -> storage_error(reason)
    end
  end

  defp pending_overlay_forget_rows(store, scope, remaining, opts) do
    {partition_sql, partition_params} = pending_partition_filter(opts)

    sql = """
    SELECT outbox.seq, 'forget' AS op, memory.id, memory.remote_id
    FROM memory_outbox AS outbox
    INNER JOIN memories AS memory ON memory.id = outbox.memory_id
    WHERE outbox.access_id IS NULL AND outbox.state IN ('pending', 'inflight', 'retry_wait')
      AND memory.sync_state != 'synced'
      AND memory.scope = ?
      #{partition_sql}
      AND outbox.op = 'forget'
      AND NOT EXISTS (
        SELECT 1
        FROM memory_outbox AS newer
        WHERE newer.memory_id = outbox.memory_id AND newer.seq > outbox.seq
      )
    ORDER BY outbox.seq DESC
    LIMIT ?
    """

    Store.query(store, sql, [scope] ++ partition_params ++ [remaining + 1])
  end

  defp maybe_mark_offset_applied(overlay, true), do: Map.put(overlay, :offset_applied, true)

  defp overlay_remember_filters(args) do
    if unsupported_recall_facets?(args) do
      {["0 = 1"], []}
    else
      query = Reducer.optional_string(args, "query") || Reducer.optional_string(args, "q")
      memory_type = Reducer.optional_string(args, "type")
      agent_id = Reducer.optional_string(args, "agent_id")
      tag = Reducer.optional_string(args, "tag")

      {[], []}
      |> add_optional_clause(query, "lower(memory.content) LIKE ? ESCAPE '\\'", fn value ->
        Reducer.like_pattern(value)
      end)
      |> add_optional_clause(memory_type, "memory.memory_type = ?", & &1)
      |> add_optional_clause(agent_id, "memory.agent_id = ?", & &1)
      |> add_optional_clause(
        tag,
        "EXISTS (SELECT 1 FROM json_each(COALESCE(memory.tags, '[]')) WHERE value = ?)",
        & &1
      )
      |> then(fn
        {[], []} -> {["1 = 1"], []}
        filters -> filters
      end)
    end
  end

  defp pending_overlay_stats(store, scope, opts) do
    {partition_sql, partition_params} = pending_partition_filter(opts)

    sql = """
    SELECT COUNT(*) AS count
    FROM memory_outbox AS outbox
    INNER JOIN memories AS memory ON memory.id = outbox.memory_id
    WHERE outbox.access_id IS NULL AND outbox.state IN ('pending', 'inflight', 'retry_wait')
      AND memory.sync_state != 'synced'
      AND memory.scope = ?
      #{partition_sql}
      AND NOT EXISTS (
        SELECT 1
        FROM memory_outbox AS newer
        WHERE newer.memory_id = outbox.memory_id AND newer.seq > outbox.seq
      )
    """

    case Store.query(store, sql, [scope] ++ partition_params) do
      {:ok, %Result{rows: [%{"count" => count}]}} ->
        {:ok,
         %{
           "pending_operations" => count,
           "overlay_truncated" => count > @overlay_cap
         }}

      {:error, reason} ->
        storage_error(reason)
    end
  end

  defp overlay_from_rows(rows, truncated?) do
    {upserts, delete_ids} =
      Enum.reduce(rows, {[], []}, fn
        %{"op" => "remember"} = row, {upserts, delete_ids} ->
          {[provisional_item(row) | upserts], delete_ids}

        %{"op" => "forget"} = row, {upserts, delete_ids} ->
          delete_id = row["remote_id"] || row["id"]
          {upserts, [delete_id | delete_ids]}
      end)

    %{
      "upserts" => Enum.reverse(upserts),
      "delete_ids" => Enum.reverse(delete_ids),
      "pending_operations" => length(rows),
      "overlay_truncated" => truncated?
    }
  end

  defp overlay_visible?(%{"op" => "forget"}, _args), do: true

  defp overlay_visible?(%{"op" => "remember"} = row, args) do
    not unsupported_recall_facets?(args) and
      matches_overlay_query?(row, args) and
      matches_overlay_value?(row, "memory_type", Reducer.optional_string(args, "type")) and
      matches_overlay_value?(row, "agent_id", Reducer.optional_string(args, "agent_id")) and
      matches_overlay_tag?(row, Reducer.optional_string(args, "tag"))
  end

  defp unsupported_recall_facets?(args) do
    is_binary(Reducer.optional_string(args, "query")) and
      nonempty_collection?(Reducer.value(args, "facets"))
  end

  defp nonempty_collection?(value) when is_map(value), do: map_size(value) > 0
  defp nonempty_collection?(value) when is_list(value), do: value != []
  defp nonempty_collection?(_value), do: false

  defp matches_overlay_query?(row, args) do
    query = Reducer.optional_string(args, "query") || Reducer.optional_string(args, "q")

    is_nil(query) or
      String.contains?(String.downcase(row["content"] || ""), String.downcase(query))
  end

  defp matches_overlay_value?(_row, _key, nil), do: true
  defp matches_overlay_value?(row, key, value), do: row[key] == value

  defp matches_overlay_tag?(_row, nil), do: true

  defp matches_overlay_tag?(row, tag) do
    tag in Reducer.decode_json(row["tags"], [])
  end

  defp provisional_item(row) do
    %{
      "id" => row["id"],
      "canonical_id" => row["remote_id"],
      "content" => row["content"],
      "scope" => row["scope"],
      "tags" => Reducer.decode_json(row["tags"], []),
      "facets" => Reducer.decode_json(row["facets"], []),
      "metadata" => Reducer.decode_json(row["metadata"], %{}),
      "confidence" => row["confidence"],
      "memory_type" => row["memory_type"],
      "agent_id" => row["agent_id"],
      "origin" => "host_command",
      "authority" => "provisional",
      "provisional" => true
    }
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
            %{
              "id" => row["id"],
              "canonical_id" => row["remote_id"],
              "scope" => row["scope"],
              "sync_state" => "pending"
            }
          end)

        {:ok, _result} ->
          DBConnection.rollback(conn, :not_found)

        {:error, reason} ->
          DBConnection.rollback(conn, {:storage_error, reason})
      end
    end)
  end

  defp insert_outbox(conn, op, memory_id, now, result_fun, payload \\ nil) do
    case Store.execute(
           conn,
           """
           INSERT INTO memory_outbox(op, memory_id, inserted_at, updated_at, payload)
           VALUES (?, ?, ?, ?, ?)
           """,
           [op, memory_id, now, now, if(payload, do: Jason.encode!(payload))]
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
                  confidence, sync_state, remote_id, remote_revision, synced_at, inserted_at, updated_at
           FROM memories
           WHERE (id = ? OR remote_id = ?) AND deleted_at IS NULL
           LIMIT 1
           """,
           [id, id]
         ) do
      {:ok, %Result{rows: [row]}} -> {:ok, row}
      {:ok, %Result{rows: []}} -> {:error, :not_found}
      {:error, reason} -> storage_error(reason)
    end
  end

  defp fetch_live_memory_by_hash(store, hash, scope, type, agent) do
    case Store.query(
           store,
           """
           SELECT id, scope, sync_state, remote_id, remote_revision
           FROM memories
           WHERE content_hash = ? AND scope = ? AND memory_type = ? AND agent_id = ? AND deleted_at IS NULL
           LIMIT 1
           """,
           [hash, scope, type, agent]
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
