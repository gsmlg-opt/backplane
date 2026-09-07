defmodule Backplane.HostAgent.Memory.Edge.Store do
  @moduledoc "Separate protected Turso pool for canonical edge state."
  alias Backplane.HostAgent.Memory.Edge.Protection
  require Logger

  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  def start_link(opts) do
    config = opts |> Keyword.get(:config, %{}) |> Map.put(:db_path, Keyword.get(opts, :database))

    case Protection.status(config) do
      :plaintext_development ->
        Logger.warning("Edge memory protection: plaintext_development; development/test only")
        open(opts)

      _ ->
        :ignore
    end
  end

  defdelegate query(store, sql, params \\ [], opts \\ []), to: Backplane.HostAgent.Memory.Store
  defdelegate execute(store, sql, params \\ [], opts \\ []), to: Backplane.HostAgent.Memory.Store
  defdelegate transaction(store, fun, opts \\ []), to: Backplane.HostAgent.Memory.Store

  defp open(opts) do
    database = Keyword.fetch!(opts, :database)

    with :ok <- if(database == ":memory:", do: :ok, else: File.mkdir_p(Path.dirname(database))) do
      # TODO(upstream): gsmlg-dev/concord#91
      # Supported database encryption is unavailable; Protection must precede this open.
      case Turso.start_link(Keyword.take(opts, [:database, :name]) ++ [pool_size: 1]) do
        {:ok, pid} ->
          case Backplane.HostAgent.Memory.Store.configure(pid) do
            :ok ->
              {:ok, pid}

            {:error, reason} ->
              GenServer.stop(pid)
              {:error, reason}
          end

        error ->
          error
      end
    end
  end
end
