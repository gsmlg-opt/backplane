defmodule Backplane.Endpoints.Cache do
  @moduledoc """
  Read-through cache of endpoints keyed by name.

  The GenServer only owns the public ETS table; reads and the loader run in the
  caller process (so Ecto sandbox ownership is unaffected). Only hits are cached,
  so unknown names cannot grow the table. Context writes call `delete/1` for the affected name.
  """

  use GenServer

  @table :backplane_endpoints

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end

  @doc "Return the cached value for `name`, loading it with `loader` on a miss."
  @spec fetch(String.t(), (-> struct() | nil)) :: struct() | nil
  def fetch(name, loader) do
    case lookup(name) do
      {:ok, value} ->
        value

      :miss ->
        generation = generation(name)
        value = loader.()
        if value, do: store(name, value, generation)
        value
    end
  end

  @doc """
  Drop `name` and bump its generation so any load that started earlier cannot
  store its (possibly stale) result. When called inside a transaction, call it
  again after the outermost commit.
  """
  @spec delete(String.t()) :: :ok
  def delete(name) do
    if running?(), do: GenServer.call(__MODULE__, {:invalidate, name})
    :ok
  end

  @spec clear() :: :ok
  def clear do
    if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)
    :ok
  end

  # Stores and invalidations are serialized through the owner so the
  # generation check and the insert are atomic with respect to invalidation.
  @impl true
  def handle_call({:invalidate, name}, _from, state) do
    :ets.update_counter(@table, {:generation, name}, 1, {{:generation, name}, 0})
    :ets.delete(@table, name)
    {:reply, :ok, state}
  end

  def handle_call({:store, name, value, generation}, _from, state) do
    if generation(name) == generation, do: :ets.insert(@table, {name, value})
    {:reply, :ok, state}
  end

  defp running?, do: :ets.whereis(@table) != :undefined

  defp generation(name) do
    case :ets.lookup(@table, {:generation, name}) do
      [{_, n}] -> n
      [] -> 0
    end
  end

  defp lookup(name) do
    if running?() do
      case :ets.lookup(@table, name) do
        [{^name, value}] -> {:ok, value}
        [] -> :miss
      end
    else
      :miss
    end
  end

  defp store(name, value, generation) do
    if running?(), do: GenServer.call(__MODULE__, {:store, name, value, generation})
    :ok
  end
end
