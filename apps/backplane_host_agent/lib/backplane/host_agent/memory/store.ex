defmodule Backplane.HostAgent.Memory.Store do
  @moduledoc """
  Thin wrapper around the ExTurso DBConnection pool used by host-agent memory.
  """

  @default_busy_timeout_ms 5_000

  @doc false
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @doc """
  Starts the ExTurso pool and applies connection pragmas required by PR1.
  """
  def start_link(opts) do
    busy_timeout_ms = Keyword.get(opts, :busy_timeout_ms, @default_busy_timeout_ms)
    db_opts = Keyword.delete(opts, :busy_timeout_ms)

    with :ok <- ensure_database_dir(db_opts) do
      start_configured_pool(db_opts, busy_timeout_ms)
    end
  end

  @doc "Runs a read query through ExTurso."
  def query(store, sql, params \\ [], opts \\ []) do
    ExTurso.query(store, sql, params, opts)
  end

  @doc "Runs a write statement through ExTurso."
  def execute(store, sql, params \\ [], opts \\ []) do
    ExTurso.execute(store, sql, params, opts)
  end

  @doc "Runs a DBConnection transaction."
  def transaction(store, fun, opts \\ []) do
    DBConnection.transaction(store, fun, opts)
  end

  @doc "Applies the SQLite pragmas required for local host-agent memory."
  def configure(store, busy_timeout_ms \\ @default_busy_timeout_ms)
      when is_integer(busy_timeout_ms) and busy_timeout_ms >= 0 do
    with {:ok, _} <- query(store, "PRAGMA journal_mode = WAL"),
         {:ok, _} <- execute(store, "PRAGMA busy_timeout = #{busy_timeout_ms}") do
      :ok
    end
  end

  defp ensure_database_dir(opts) do
    case Keyword.fetch(opts, :database) do
      {:ok, ":memory:"} ->
        :ok

      {:ok, database} when is_binary(database) ->
        File.mkdir_p!(Path.dirname(database))
        :ok

      :error ->
        {:error, :missing_database}
    end
  end

  defp start_configured_pool(db_opts, busy_timeout_ms) do
    case ExTurso.start_link(db_opts) do
      {:ok, pid} ->
        case configure(Keyword.get(db_opts, :name, pid), busy_timeout_ms) do
          :ok ->
            {:ok, pid}

          {:error, reason} ->
            GenServer.stop(pid)
            {:error, reason}
        end

      {:error, _reason} = error ->
        error
    end
  end
end
