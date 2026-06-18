defmodule Backplane.HostAgent.Memory.Facts do
  @moduledoc """
  Applies hub-originated memory facts and wipe directives to the local store.
  """

  alias Backplane.HostAgent.Memory.{Reducer, Store}
  alias ExTurso.Result

  @doc "Applies a full or incremental fact reconcile payload."
  def apply_facts(payload, opts \\ []) when is_map(payload) do
    store = Keyword.get(opts, :store, Store)

    with {:ok, scope} <- Reducer.required_string(payload, "scope"),
         facts when is_list(facts) <- Reducer.value(payload, "facts", []),
         {:ok, normalized} <- normalize_facts(facts) do
      full? = truthy?(Reducer.value(payload, "full", false))

      transaction(store, fn conn ->
        if full? do
          case Store.execute(conn, "DELETE FROM facts WHERE scope = ?", [scope]) do
            {:ok, _result} -> :ok
            {:error, reason} -> DBConnection.rollback(conn, {:storage_error, reason})
          end
        end

        Enum.each(normalized, fn fact ->
          case upsert_fact(conn, scope, fact) do
            :ok -> :ok
            {:error, reason} -> DBConnection.rollback(conn, {:storage_error, reason})
          end
        end)

        %{"scope" => scope, "count" => length(normalized), "full" => full?}
      end)
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, {:invalid_args, "facts must be a list"}}
    end
  end

  @doc "Applies a governance wipe directive and returns an ack payload."
  def apply_wipe(payload, opts \\ []) when is_map(payload) do
    store = Keyword.get(opts, :store, Store)

    with {:ok, directive_id} <- Reducer.required_string(payload, "directive_id"),
         items when is_list(items) <- Reducer.value(payload, "items", []) do
      transaction(store, fn conn ->
        ack_items = Enum.map(items, &wipe_item(conn, directive_id, &1))
        %{"directive_id" => directive_id, "items" => ack_items}
      end)
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, {:invalid_args, "items must be a list"}}
    end
  end

  defp normalize_facts(facts) do
    facts
    |> Enum.reduce_while({:ok, []}, fn fact, {:ok, acc} ->
      case normalize_fact(fact) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_fact(%{} = fact) do
    with {:ok, id} <- Reducer.required_string(fact, "id"),
         {:ok, content} <- Reducer.required_string(fact, "content"),
         {:ok, tags} <- Reducer.normalize_tags(Reducer.value(fact, "tags", [])),
         {:ok, metadata} <- Reducer.normalize_metadata(Reducer.value(fact, "metadata", %{})),
         {:ok, tags_json} <- Reducer.encode_json(tags),
         {:ok, metadata_json} <- Reducer.encode_json(metadata) do
      content_hash =
        Reducer.optional_string(fact, "content_hash") ||
          Reducer.content_hash(content)

      updated_at =
        Reducer.optional_string(fact, "updated_at") ||
          timestamp()

      {:ok,
       %{
         id: id,
         content: content,
         content_hash: content_hash,
         tags_json: tags_json,
         metadata_json: metadata_json,
         updated_at: updated_at
       }}
    end
  end

  defp normalize_fact(_fact), do: {:error, {:invalid_args, "fact must be an object"}}

  defp upsert_fact(conn, scope, fact) do
    sql = """
    INSERT INTO facts(id, content, content_hash, scope, tags, metadata, updated_at)
    VALUES (?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(id) DO UPDATE SET
      content = excluded.content,
      content_hash = excluded.content_hash,
      scope = excluded.scope,
      tags = excluded.tags,
      metadata = excluded.metadata,
      updated_at = excluded.updated_at
    """

    case Store.execute(conn, sql, [
           fact.id,
           fact.content,
           fact.content_hash,
           scope,
           fact.tags_json,
           fact.metadata_json,
           fact.updated_at
         ]) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp wipe_item(conn, directive_id, %{} = item) do
    scope = Reducer.optional_string(item, "scope")
    content_hash = Reducer.optional_string(item, "content_hash")
    remote_id = Reducer.optional_string(item, "remote_id")
    wiped_at = timestamp()

    memory_ids = matching_memory_ids(conn, scope, content_hash, remote_id)
    cancel_outbox(conn, memory_ids)
    delete_memories(conn, scope, content_hash, remote_id)
    delete_facts(conn, scope, content_hash)
    insert_tombstone(conn, content_hash, scope, wiped_at, directive_id)

    %{
      "remote_id" => remote_id,
      "content_hash" => content_hash,
      "scope" => scope,
      "status" => "ok"
    }
  end

  defp wipe_item(_conn, _directive_id, _item) do
    %{"status" => "error", "error" => "wipe item must be an object"}
  end

  defp matching_memory_ids(conn, scope, content_hash, remote_id) do
    {clause, params} =
      cond do
        is_binary(remote_id) and is_binary(scope) ->
          {"scope = ? AND remote_id = ?", [scope, remote_id]}

        is_binary(content_hash) and is_binary(scope) ->
          {"scope = ? AND content_hash = ?", [scope, content_hash]}

        true ->
          {"1 = 0", []}
      end

    case Store.query(conn, "SELECT id FROM memories WHERE #{clause}", params) do
      {:ok, %Result{rows: []}} when is_binary(remote_id) and is_binary(content_hash) ->
        matching_memory_ids(conn, scope, content_hash, nil)

      {:ok, %Result{rows: rows}} ->
        Enum.map(rows, & &1["id"])

      {:error, reason} ->
        DBConnection.rollback(conn, {:storage_error, reason})
    end
  end

  defp cancel_outbox(_conn, []), do: :ok

  defp cancel_outbox(conn, memory_ids) do
    placeholders = placeholders(memory_ids)

    case Store.execute(
           conn,
           """
           UPDATE memory_outbox
           SET state = 'done', last_error = 'wiped', updated_at = ?
           WHERE state IN ('pending', 'inflight') AND memory_id IN (#{placeholders})
           """,
           [timestamp() | memory_ids]
         ) do
      {:ok, _result} -> :ok
      {:error, reason} -> DBConnection.rollback(conn, {:storage_error, reason})
    end
  end

  defp delete_memories(conn, scope, content_hash, remote_id) do
    {clause, params} =
      cond do
        is_binary(remote_id) and is_binary(scope) ->
          {"scope = ? AND remote_id = ?", [scope, remote_id]}

        is_binary(content_hash) and is_binary(scope) ->
          {"scope = ? AND content_hash = ?", [scope, content_hash]}

        true ->
          {"1 = 0", []}
      end

    case Store.execute(conn, "DELETE FROM memories WHERE #{clause}", params) do
      {:ok, %Result{num_rows: 0}} when is_binary(remote_id) and is_binary(content_hash) ->
        delete_memories(conn, scope, content_hash, nil)

      {:ok, _result} ->
        :ok

      {:error, reason} ->
        DBConnection.rollback(conn, {:storage_error, reason})
    end
  end

  defp delete_facts(_conn, nil, _content_hash), do: :ok
  defp delete_facts(_conn, _scope, nil), do: :ok

  defp delete_facts(conn, scope, content_hash) do
    case Store.execute(conn, "DELETE FROM facts WHERE scope = ? AND content_hash = ?", [
           scope,
           content_hash
         ]) do
      {:ok, _result} -> :ok
      {:error, reason} -> DBConnection.rollback(conn, {:storage_error, reason})
    end
  end

  defp insert_tombstone(_conn, nil, _scope, _wiped_at, _directive_id), do: :ok
  defp insert_tombstone(_conn, _content_hash, nil, _wiped_at, _directive_id), do: :ok

  defp insert_tombstone(conn, content_hash, scope, wiped_at, directive_id) do
    case Store.execute(
           conn,
           """
           INSERT INTO tombstones(content_hash, scope, wiped_at, directive_id)
           VALUES (?, ?, ?, ?)
           ON CONFLICT(content_hash) DO UPDATE SET
             scope = excluded.scope,
             wiped_at = excluded.wiped_at,
             directive_id = excluded.directive_id
           """,
           [content_hash, scope, wiped_at, directive_id]
         ) do
      {:ok, _result} -> :ok
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

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(1), do: true
  defp truthy?(_value), do: false

  defp placeholders(values), do: values |> Enum.map(fn _ -> "?" end) |> Enum.join(",")

  defp timestamp do
    DateTime.utc_now()
    |> DateTime.truncate(:microsecond)
    |> DateTime.to_iso8601()
  end
end
