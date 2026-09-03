defmodule Backplane.Observability.Buffer do
  @moduledoc false

  use GenServer

  @doc "Starts a named bounded buffer."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Non-blocking enqueue. Reserves capacity before delivering to the buffer process."
  @spec try_enqueue(atom(), map()) :: :ok | {:error, :full | :unavailable}
  def try_enqueue(name, event) when is_atom(name) and is_map(event) do
    case meta(name) do
      nil ->
        {:error, :unavailable}

      %{atomic: atomic, capacity: capacity, pid: pid} ->
        reserved = :atomics.get(atomic, 1)

        if reserved >= capacity do
          {:error, :full}
        else
          :atomics.add(atomic, 1, 1)
          send(pid, {:enqueue, event})
          :ok
        end
    end
  end

  @doc "Drains up to `limit` queued events."
  @spec drain(atom(), pos_integer()) :: [map()]
  def drain(name, limit) when is_atom(name) and is_integer(limit) and limit > 0 do
    GenServer.call(name, {:drain, limit})
  catch
    :exit, _ -> []
  end

  @doc "Releases reserved capacity after persistence."
  @spec release(atom(), non_neg_integer()) :: :ok
  def release(name, count) when is_atom(name) and is_integer(count) and count >= 0 do
    case meta(name) do
      nil ->
        :ok

      %{atomic: atomic} ->
        current = :atomics.get(atomic, 1)
        release_count = min(count, current)
        if release_count > 0, do: :atomics.sub(atomic, 1, release_count)
        :ok
    end
  end

  @doc "Updates the bounded capacity for a named buffer."
  @spec update_capacity(atom(), pos_integer()) :: :ok
  def update_capacity(name, capacity) when is_atom(name) and is_integer(capacity) and capacity > 0 do
    case meta(name) do
      nil ->
        :ok

      %{atomic: atomic, pid: pid} = meta ->
        :persistent_term.put(meta_key(name), %{meta | capacity: capacity})

        if :atomics.get(atomic, 1) > capacity do
          GenServer.call(pid, {:trim_reserved, capacity}, 5_000)
        else
          :ok
        end
    end
  catch
    :exit, _ -> :ok
  end

  @doc "Returns health information for a named buffer."
  @spec health(atom()) :: map()
  def health(name) when is_atom(name) do
    case meta(name) do
      nil ->
        %{status: :unavailable, capacity: default_capacity(name), reserved: 0, queued: 0}

      %{atomic: atomic, capacity: capacity, pid: pid} ->
        %{
          status: if(Process.alive?(pid), do: :ok, else: :unavailable),
          capacity: capacity,
          reserved: :atomics.get(atomic, 1),
          queued: queue_depth(pid)
        }
    end
  end

  @doc "Lists started buffer names."
  @spec list() :: [atom()]
  def list do
    :persistent_term.get({__MODULE__, :names}, [])
  end

  @doc false
  def default_capacity(:llm_proxy), do: 10_000
  def default_capacity(:mcp_proxy_root), do: 20_000
  def default_capacity(:mcp_tool_calls), do: 50_000
  def default_capacity(_), do: 10_000

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    capacity = Keyword.get(opts, :capacity, default_capacity(name))
    atomic = :atomics.new(1, signed: false)
    :atomics.put(atomic, 1, 0)

    meta = %{atomic: atomic, capacity: capacity, pid: self()}
    :persistent_term.put(meta_key(name), meta)

    names =
      :persistent_term.get({__MODULE__, :names}, [])
      |> then(fn names -> if name in names, do: names, else: [name | names] end)

    :persistent_term.put({__MODULE__, :names}, names)

    {:ok, %{name: name, queue: :queue.new()}}
  end

  @impl true
  def terminate(_reason, %{name: name}) do
    :persistent_term.erase(meta_key(name))
    :ok
  end

  @impl true
  def handle_info({:enqueue, event}, state) do
    {:noreply, %{state | queue: :queue.in(event, state.queue)}}
  end

  @impl true
  def handle_call({:trim_reserved, capacity}, _from, state) do
    meta = meta(state.name)

    if meta do
      current = :atomics.get(meta.atomic, 1)

      if current > capacity do
        :atomics.sub(meta.atomic, 1, current - capacity)
      end
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:drain, limit}, _from, state) do
    {events, queue} = drain_queue(state.queue, limit, [])
    {:reply, Enum.reverse(events), %{state | queue: queue}}
  end

  defp drain_queue(queue, 0, acc), do: {acc, queue}

  defp drain_queue(queue, limit, acc) do
    case :queue.out(queue) do
      {{:value, event}, rest} -> drain_queue(rest, limit - 1, [event | acc])
      {:empty, _} -> {acc, queue}
    end
  end

  defp meta(name), do: :persistent_term.get(meta_key(name), nil)
  defp meta_key(name), do: {__MODULE__, name}

  defp queue_depth(pid) do
    :sys.get_state(pid).queue |> :queue.len()
  catch
    :exit, _ -> 0
  end
end
