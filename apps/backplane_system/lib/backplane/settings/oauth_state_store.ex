defmodule Backplane.Settings.OAuthStateStore do
  @moduledoc """
  Short-lived ETS store for OAuth authorization code flow state.

  Each pending authorization gets a random `state` token as the key.
  Entries expire after 10 minutes (enforced on read, not by a timer).
  """

  use GenServer

  @table :oauth_state_store
  @ttl_ms 600_000

  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, []},
      type: :worker,
      restart: :permanent
    }
  end

  def start_link do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    table = :ets.new(@table, [:named_table, :protected, :set])
    {:ok, table}
  end

  @doc "Store OAuth state. Returns the state token."
  @spec put(map()) :: String.t()
  def put(attrs) do
    GenServer.call(__MODULE__, {:put, attrs})
  end

  @doc "Fetch and delete state by token. Returns `{:ok, attrs}` or `:error`."
  @spec pop(String.t()) :: {:ok, map()} | :error
  def pop(state) do
    GenServer.call(__MODULE__, {:pop, state})
  end

  @doc "Clear all stored OAuth states. Intended for test isolation and explicit cleanup."
  @spec clear() :: :ok
  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  @impl true
  def handle_call({:put, attrs}, _from, table) do
    state = :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
    :ets.insert(table, {state, attrs, System.monotonic_time(:millisecond)})

    {:reply, state, table}
  end

  def handle_call({:pop, state}, _from, table) do
    result =
      pop_state(table, state)

    {:reply, result, table}
  end

  def handle_call(:clear, _from, table) do
    :ets.delete_all_objects(table)

    {:reply, :ok, table}
  end

  defp pop_state(table, state) do
    case :ets.take(table, state) do
      [{^state, attrs, inserted_at}] ->
        now = System.monotonic_time(:millisecond)

        if now - inserted_at <= @ttl_ms do
          {:ok, attrs}
        else
          :error
        end

      [] ->
        :error
    end
  end
end
