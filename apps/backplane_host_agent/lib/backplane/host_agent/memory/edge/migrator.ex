defmodule Backplane.HostAgent.Memory.Edge.Migrator do
  @moduledoc """
  Raw SQL migration runner for host-agent memory.
  """

  alias Backplane.HostAgent.Memory.Edge.{Migrations, Store}
  alias Turso.Result

  @migrations [Migrations.V1, Migrations.V2]

  @v1_columns %{
    "edge_partitions" => [
      {"memory_space_id", "TEXT", 1, nil, 1},
      {"scope", "TEXT", 1, nil, 1},
      {"namespace", "TEXT", 1, nil, 1},
      {"applied_revision", "INTEGER", 1, "0", 0},
      {"active_generation", "TEXT", 1, "'0'", 0},
      {"last_batch_id", "TEXT", 0, nil, 0},
      {"last_sync_at", "TEXT", 0, nil, 0},
      {"snapshot_id", "TEXT", 0, nil, 0},
      {"snapshot_revision", "INTEGER", 0, nil, 0},
      {"next_chunk_index", "INTEGER", 0, nil, 0},
      {"chunk_count", "INTEGER", 0, nil, 0},
      {"integrity_hash", "TEXT", 0, nil, 0}
    ],
    "edge_memories" => [
      {"memory_space_id", "TEXT", 1, nil, 1},
      {"scope", "TEXT", 1, nil, 1},
      {"namespace", "TEXT", 1, nil, 1},
      {"generation", "TEXT", 1, nil, 1},
      {"canonical_id", "TEXT", 1, nil, 1},
      {"memory_type", "TEXT", 0, nil, 0},
      {"content", "TEXT", 0, nil, 0},
      {"content_hash", "TEXT", 0, nil, 0},
      {"confidence", "REAL", 0, nil, 0},
      {"lifecycle_state", "TEXT", 1, nil, 0},
      {"tags", "TEXT", 0, nil, 0},
      {"metadata", "TEXT", 0, nil, 0},
      {"source_refs", "TEXT", 0, nil, 0},
      {"server_revision", "INTEGER", 1, nil, 0},
      {"edge_priority", "REAL", 0, nil, 0},
      {"edge_expires_at", "TEXT", 0, nil, 0},
      {"updated_at", "TEXT", 0, nil, 0},
      {"last_accessed_at", "TEXT", 0, nil, 0},
      {"byte_size", "INTEGER", 1, "0", 0}
    ],
    "edge_snapshot_chunks" => [
      {"snapshot_id", "TEXT", 1, nil, 1},
      {"chunk_index", "INTEGER", 1, nil, 1},
      {"chunk_hash", "TEXT", 1, nil, 0},
      {"applied_at", "TEXT", 1, nil, 0}
    ]
  }

  @v2_partition_columns @v1_columns["edge_partitions"] ++
                          [
                            {"sync_status", "TEXT", 0, nil, 0},
                            {"last_delivery_hash", "TEXT", 0, nil, 0}
                          ]

  @primary_keys %{
    "edge_partitions" => ~w(memory_space_id scope namespace),
    "edge_memories" => ~w(memory_space_id scope namespace generation canonical_id),
    "edge_snapshot_chunks" => ~w(snapshot_id chunk_index)
  }

  @doc false
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  @doc """
  Runs migrations synchronously as a supervisor child.

  Returning `:ignore` keeps the migration step out of the supervision tree after
  a successful boot migration while still preserving child start ordering.
  """
  def start_link(opts) do
    store = Keyword.fetch!(opts, :store)

    case migrate(store) do
      :ok -> :ignore
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Returns the highest known migration version."
  def latest_version do
    @migrations
    |> Enum.map(& &1.version())
    |> Enum.max(fn -> 0 end)
  end

  @doc "Reads the database `PRAGMA user_version`."
  def current_version(store) do
    case Store.query(store, "PRAGMA user_version") do
      {:ok, %Result{rows: [row]}} -> {:ok, row_version(row)}
      {:ok, %Result{rows: []}} -> {:ok, 0}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Applies all pending migrations."
  def migrate(store) do
    with {:ok, current} <- current_version(store),
         :ok <- validate_schema(store, current) do
      @migrations
      |> Enum.filter(&(&1.version() > current))
      |> Enum.reduce_while(:ok, fn migration, :ok ->
        case apply_migration(store, migration) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  @doc false
  def validate_schema(store) do
    with {:ok, current} <- current_version(store), do: validate_schema(store, current)
  end

  defp validate_schema(store, current) do
    with {:ok, %{rows: rows}} <-
           Store.query(
             store,
             "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
           ) do
      tables = rows |> Enum.map(& &1["name"]) |> Enum.sort()
      expected = ["edge_memories", "edge_partitions", "edge_snapshot_chunks"]

      validate_tables(store, current, tables, expected)
    end
  end

  defp validate_tables(_store, 0, [], _expected), do: :ok

  defp validate_tables(store, current, tables, expected)
       when current in 1..2 and tables == expected do
    expected_columns =
      if current == 1,
        do: @v1_columns,
        else: Map.put(@v1_columns, "edge_partitions", @v2_partition_columns)

    Enum.reduce_while(expected_columns, :ok, fn {table, columns}, :ok ->
      case Store.query(store, "PRAGMA table_info(#{table})") do
        {:ok, %{rows: rows}} when is_list(rows) ->
          found = Enum.map(rows, &column_contract/1)

          if found == columns and primary_key?(store, table, @primary_keys[table]),
            do: {:cont, :ok},
            else: {:halt, {:error, :invalid_edge_schema}}

        {:error, _reason} ->
          {:halt, {:error, :invalid_edge_schema}}
      end
    end)
  end

  defp validate_tables(_store, _current, _tables, _expected), do: {:error, :invalid_edge_schema}

  defp column_contract(row) do
    {
      row["name"],
      row["type"] |> to_string() |> String.trim() |> String.upcase(),
      normalize_integer(row["notnull"]),
      normalize_default(row["dflt_value"]),
      normalize_integer(row["pk"])
    }
  end

  defp normalize_integer(value) when is_integer(value), do: value
  defp normalize_integer(value) when is_binary(value), do: String.to_integer(value)
  defp normalize_integer(_value), do: -1

  defp normalize_default(nil), do: nil

  defp normalize_default(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.replace(~r/^\((.*)\)$/, "\\1")
  end

  # libSQL reports every composite primary-key member as `pk = 1` from
  # table_info. Read its backing primary-key index to preserve key order.
  defp primary_key?(store, table, expected) do
    with {:ok, %{rows: indexes}} <- Store.query(store, "PRAGMA index_list(#{table})"),
         %{"name" => index} <-
           Enum.find(indexes, &(&1["origin"] == "pk" and &1["unique"] in [1, "1"])),
         {:ok, %{rows: columns}} <-
           Store.query(store, "PRAGMA index_info(#{quote_identifier(index)})") do
      columns
      |> Enum.sort_by(&normalize_integer(&1["seqno"]))
      |> Enum.map(& &1["name"])
      |> Kernel.==(expected)
    else
      _ -> false
    end
  end

  defp quote_identifier(identifier), do: "\"" <> String.replace(identifier, "\"", "\"\"") <> "\""

  defp apply_migration(store, migration) do
    case Store.transaction(store, fn conn ->
           Enum.each(migration.up(), fn sql ->
             case Store.execute(conn, sql) do
               {:ok, _} -> :ok
               {:error, reason} -> DBConnection.rollback(conn, reason)
             end
           end)

           case Store.execute(conn, "PRAGMA user_version = #{migration.version()}") do
             {:ok, _} -> :ok
             {:error, reason} -> DBConnection.rollback(conn, reason)
           end
         end) do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp row_version(%{"user_version" => version}) when is_integer(version), do: version

  defp row_version(%{"user_version" => version}) when is_binary(version),
    do: String.to_integer(version)

  defp row_version(row) when is_map(row), do: row |> Map.values() |> List.first() |> to_version()

  defp to_version(version) when is_integer(version), do: version
  defp to_version(version) when is_binary(version), do: String.to_integer(version)
  defp to_version(_version), do: 0
end
