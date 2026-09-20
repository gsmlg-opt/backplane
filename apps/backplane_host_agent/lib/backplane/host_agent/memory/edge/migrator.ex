defmodule Backplane.HostAgent.Memory.Edge.Migrator do
  @moduledoc """
  Raw SQL migration runner for host-agent memory.
  """

  alias Backplane.HostAgent.Memory.Edge.{Migrations, Store}
  alias Turso.Result

  @migrations [Migrations.V1, Migrations.V2]

  @v1_columns %{
    "edge_partitions" =>
      ~w(memory_space_id scope namespace applied_revision active_generation last_batch_id last_sync_at snapshot_id snapshot_revision next_chunk_index chunk_count integrity_hash),
    "edge_memories" =>
      ~w(memory_space_id scope namespace generation canonical_id memory_type content content_hash confidence lifecycle_state tags metadata source_refs server_revision edge_priority edge_expires_at updated_at last_accessed_at byte_size),
    "edge_snapshot_chunks" => ~w(snapshot_id chunk_index chunk_hash applied_at)
  }

  @v2_partition_columns ~w(memory_space_id scope namespace applied_revision active_generation last_batch_id last_sync_at snapshot_id snapshot_revision next_chunk_index chunk_count integrity_hash sync_status last_delivery_hash)

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
          found = rows |> Enum.map(& &1["name"]) |> Enum.sort()

          if found == Enum.sort(columns),
            do: {:cont, :ok},
            else: {:halt, {:error, :invalid_edge_schema}}

        {:error, _reason} ->
          {:halt, {:error, :invalid_edge_schema}}
      end
    end)
  end

  defp validate_tables(_store, _current, _tables, _expected), do: {:error, :invalid_edge_schema}

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
