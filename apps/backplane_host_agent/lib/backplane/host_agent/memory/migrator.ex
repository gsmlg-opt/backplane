defmodule Backplane.HostAgent.Memory.Migrator do
  @moduledoc """
  Raw SQL migration runner for host-agent memory.
  """

  alias Backplane.HostAgent.Memory.{Migrations, Store}
  alias ExTurso.Result

  @migrations [Migrations.V1]

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
    with {:ok, current} <- current_version(store) do
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
