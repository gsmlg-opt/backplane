defmodule Relayixir.Proxy.ConnPool do
  @moduledoc """
  Per-upstream Mint HTTP connection pool.

  Each pool is a GenServer holding a bounded set of idle Mint connections keyed
  by `{scheme, host, port}`. When a caller checks out a connection, it is
  removed from the idle set. After the request finishes, the caller checks the
  connection back in (if still open) or discards it.

  Pools are started on-demand via `DynamicSupervisor` and registered in a
  `Registry` for discovery.

  ## Configuration

  Set `pool_size` on an upstream config to enable pooling:

      Relayixir.load(upstreams: %{
        "backend" => %{scheme: :http, host: "localhost", port: 4001, pool_size: 10}
      })

  When `pool_size` is nil (default), `HttpPlug` opens a fresh connection per
  request — the MVP behavior is preserved.
  """

  use GenServer

  require Logger

  alias Relayixir.Proxy.Upstream

  @type pool_key :: {atom(), String.t(), non_neg_integer()}

  defstruct [:key, :max_size, :connect_timeout, idle: :queue.new(), idle_count: 0]

  ## Public API

  @doc """
  Checks out an idle Mint connection from the pool for the given upstream.
  Returns `{:ok, conn}` if an idle connection is available and still open,
  or `{:error, :empty}` if none are available.

  The caller is responsible for calling `checkin/2` after the request, or
  discarding the connection on error.
  """
  @spec checkout(Upstream.t()) :: {:ok, Mint.HTTP.t()} | {:error, :empty}
  def checkout(%Upstream{} = upstream) do
    key = pool_key(upstream)

    case Registry.lookup(Relayixir.Proxy.ConnPool.Registry, key) do
      [{pid, _}] -> GenServer.call(pid, :checkout)
      [] -> {:error, :empty}
    end
  end

  @doc """
  Returns a Mint connection to the pool. The connection is checked for
  liveness before being placed in the idle queue. If the pool is full or
  the connection is dead, it is closed and discarded.
  """
  @spec checkin(Upstream.t(), Mint.HTTP.t()) :: :ok
  def checkin(%Upstream{} = upstream, conn) do
    key = pool_key(upstream)

    case Registry.lookup(Relayixir.Proxy.ConnPool.Registry, key) do
      [{pid, _}] ->
        if Process.alive?(pid) do
          GenServer.cast(pid, {:checkin, conn})
        else
          Mint.HTTP.close(conn)
        end

      [] ->
        Mint.HTTP.close(conn)
    end

    :ok
  end

  @doc """
  Ensures a pool exists for the given upstream. Idempotent — returns
  `{:ok, pid}` if already running.
  """
  @spec ensure_started(Upstream.t()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(%Upstream{} = upstream) do
    key = pool_key(upstream)

    case Registry.lookup(Relayixir.Proxy.ConnPool.Registry, key) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        DynamicSupervisor.start_child(
          Relayixir.Proxy.ConnPool.Supervisor,
          {__MODULE__, {key, upstream.pool_size, upstream.connect_timeout}}
        )
        |> case do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          error -> error
        end
    end
  end

  ## Child spec / start_link

  def child_spec({key, max_size, connect_timeout}) do
    %{
      id: {__MODULE__, key},
      start: {__MODULE__, :start_link, [{key, max_size, connect_timeout}]},
      restart: :temporary,
      type: :worker
    }
  end

  def start_link({key, max_size, connect_timeout}) do
    GenServer.start_link(__MODULE__, {key, max_size, connect_timeout}, name: via_registry(key))
  end

  ## GenServer callbacks

  @impl true
  def init({key, max_size, connect_timeout}) do
    state = %__MODULE__{
      key: key,
      max_size: max_size,
      connect_timeout: connect_timeout
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:checkout, _from, state) do
    case take_idle(state) do
      {:ok, conn, new_state} ->
        if Mint.HTTP.open?(conn) do
          {:reply, {:ok, conn}, new_state}
        else
          Mint.HTTP.close(conn)
          # Try the next one recursively
          handle_call(:checkout, nil, new_state)
        end

      :empty ->
        {:reply, {:error, :empty}, state}
    end
  end

  @impl true
  def handle_cast({:checkin, conn}, state) do
    if Mint.HTTP.open?(conn) && state.idle_count < state.max_size do
      new_state = put_idle(state, conn)
      {:noreply, new_state}
    else
      Mint.HTTP.close(conn)
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("ConnPool #{inspect(state.key)} received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  ## Private helpers

  defp take_idle(%{idle_count: 0}), do: :empty

  defp take_idle(%{idle: queue, idle_count: count} = state) do
    case :queue.out(queue) do
      {{:value, conn}, new_queue} ->
        {:ok, conn, %{state | idle: new_queue, idle_count: count - 1}}

      {:empty, _} ->
        :empty
    end
  end

  defp put_idle(%{idle: queue, idle_count: count} = state, conn) do
    %{state | idle: :queue.in(conn, queue), idle_count: count + 1}
  end

  defp pool_key(%Upstream{} = upstream) do
    {upstream.scheme || :http, upstream.host, upstream.port}
  end

  defp via_registry(key) do
    {:via, Registry, {Relayixir.Proxy.ConnPool.Registry, key}}
  end
end
