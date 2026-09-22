defmodule Backplane.HostAgent.Memory.Edge.Supervisor do
  @moduledoc "Isolates optional edge storage startup from command and capture services."
  use Supervisor
  require Logger
  alias Backplane.HostAgent.Memory.Edge.{Protection, Store, Migrator}

  def status(config), do: Protection.status(config)

  def start_link(config) do
    case status(config) do
      :plaintext_development -> start_isolated(config)
      _ -> :ignore
    end
  end

  defp start_isolated(config) do
    previous = Process.flag(:trap_exit, true)
    ref = make_ref()

    try do
      result =
        Elixir.Supervisor.start_link(__MODULE__, {config, self(), ref},
          name: Map.get(config, :name, __MODULE__)
        )

      # init identifies this child before its synchronous startup acknowledgement.
      # Only that child's failed-start EXIT may be drained; unrelated exits remain.
      child =
        receive do
          {^ref, pid} -> pid
        after
          0 -> nil
        end

      case result do
        {:ok, _pid} ->
          result

        _ ->
          receive do
            {:EXIT, ^child, _reason} -> :ok
          after
            0 -> :ok
          end

          Logger.warning("Edge memory storage unavailable; command and capture services continue")
          :ignore
      end
    after
      Process.flag(:trap_exit, previous)
    end
  end

  @impl true
  def init({config, caller, ref}) do
    send(caller, {ref, self()})
    store = Map.get(config, :store_name, Store)

    children = [
      {Store, database: Map.fetch!(config, :db_path), name: store, config: config},
      {Migrator, store: store}
    ]

    Elixir.Supervisor.init(children, strategy: :one_for_one)
  end
end
