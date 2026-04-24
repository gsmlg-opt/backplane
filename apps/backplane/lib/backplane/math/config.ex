defmodule Backplane.Math.Config do
  @moduledoc """
  Runtime config for the native Math server.

  Backed by the singleton `mcp_native_math_config` row. Readers use ETS while
  writes and reloads are serialized through this GenServer.
  """

  use GenServer

  alias Backplane.Math.Config.Record
  alias Backplane.Registry.ToolRegistry
  alias Backplane.Repo
  require Logger

  @table :backplane_math_config
  @topic "math:config"

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @spec get() :: Record.t()
  def get do
    case :ets.whereis(@table) do
      :undefined ->
        Record.defaults()

      _tid ->
        case :ets.lookup(@table, :config) do
          [{:config, record}] -> record
          [] -> Record.defaults()
        end
    end
  end

  @spec get(atom()) :: term()
  def get(field) when is_atom(field), do: Map.fetch!(get(), field)

  @spec tool_timeout(String.t()) :: pos_integer()
  def tool_timeout(tool_name) when is_binary(tool_name) do
    cfg = get()

    case Map.get(cfg.timeout_per_tool || %{}, tool_name) do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> cfg.timeout_default_ms
    end
  end

  @spec reload() :: :ok
  def reload, do: GenServer.call(__MODULE__, :reload)

  @spec save(map()) :: {:ok, Record.t()} | {:error, Ecto.Changeset.t()}
  def save(attrs) when is_map(attrs), do: GenServer.call(__MODULE__, {:save, attrs})

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, nil, {:continue, :load}}
  end

  @impl true
  def handle_continue(:load, state) do
    do_reload()
    {:noreply, state}
  end

  @impl true
  def handle_call(:reload, _from, state) do
    do_reload()
    {:reply, :ok, state}
  end

  def handle_call({:save, attrs}, _from, state) do
    record = Repo.get(Record, 1) || %Record{id: 1}
    changeset = Record.changeset(record, attrs)

    case Repo.insert_or_update(changeset) do
      {:ok, updated} ->
        cache(updated)
        sync_registry(updated)
        broadcast(updated)
        {:reply, {:ok, updated}, state}

      {:error, changeset} ->
        {:reply, {:error, changeset}, state}
    end
  end

  defp do_reload do
    record =
      try do
        Repo.get(Record, 1) || Record.defaults()
      rescue
        Postgrex.Error ->
          Logger.warning("Math config table unavailable; using defaults until migrations run")
          Record.defaults()
      end

    cache(record)
    sync_registry(record)
    broadcast(record)
  end

  defp cache(record), do: :ets.insert(@table, {:config, record})

  defp broadcast(record) do
    Backplane.PubSubBroadcaster.broadcast_config_reloaded(%{
      source: :math,
      enabled: record.enabled
    })

    Phoenix.PubSub.broadcast(Backplane.PubSub, @topic, {:math_config_changed, record})
  end

  defp sync_registry(%Record{enabled: true}) do
    ToolRegistry.register_managed(
      Backplane.Services.Math.prefix(),
      Backplane.Services.Math.tools()
    )
  end

  defp sync_registry(%Record{enabled: false}) do
    ToolRegistry.deregister_managed(Backplane.Services.Math.prefix())
  end
end
