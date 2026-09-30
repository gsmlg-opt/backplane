defmodule Backplane.Clients.Activity do
  @moduledoc "Bounded, approximate client activity; no task or mailbox message per request."
  use GenServer
  import Ecto.Query

  alias Backplane.Clients.Client
  alias Backplane.Repo

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  def handle(server), do: GenServer.call(server, :handle)

  def default_handle,
    do: %{
      table: :backplane_client_activity,
      capacity: config()[:activity_capacity],
      now: &DateTime.utc_now/0,
      clock: &clock/0
    }

  def flush(server \\ __MODULE__), do: GenServer.call(server, :flush, 15_000)

  def record(id, handle \\ default_handle()) do
    observed = DateTime.to_unix(handle.now.(), :microsecond)
    mark(id, observed, handle)
  rescue
    ArgumentError -> :ok
  end

  defp mark(id, observed, handle) do
    case :ets.lookup(handle.table, id) do
      [{^id, previous, flushed}] = rows ->
        if observed > previous do
          replacement = [{hd(rows), [], [{:const, {id, observed, flushed}}]}]
          if :ets.select_replace(handle.table, replacement) == 0, do: mark(id, observed, handle)
        end

      [] ->
        count = :ets.update_counter(handle.table, :count, 1)

        if count <= handle.capacity do
          unless :ets.insert_new(handle.table, {id, observed, nil}) do
            :ets.update_counter(handle.table, :count, -1)
            mark(id, observed, handle)
          end
        else
          :ets.update_counter(handle.table, :count, -1)
        end
    end

    :ok
  end

  @impl true
  def init(opts) do
    config = Keyword.merge(config(), opts)
    named? = Keyword.get(opts, :named_table, true)
    table_opts = [:public, :set, read_concurrency: true, write_concurrency: true]

    table =
      :ets.new(
        :backplane_client_activity,
        if(named?, do: [:named_table | table_opts], else: table_opts)
      )

    :ets.insert(table, {:count, 0})

    handle = %{
      table: table,
      capacity: config[:activity_capacity],
      now: Keyword.get(opts, :now, &DateTime.utc_now/0),
      clock: Keyword.get(opts, :clock, &clock/0)
    }

    timer = Process.send_after(self(), :tick, 1_000)

    {:ok,
     %{
       handle: handle,
       opts: config,
       task: nil,
       caller: nil,
       backoff: 1_000,
       timer: timer,
       supervisor: Keyword.get(opts, :task_supervisor, Backplane.Clients.Tasks),
       persist: Keyword.get(opts, :persist, &persist/2),
       alive: Keyword.get(opts, :alive, &alive?/1)
     }}
  end

  @impl true
  def handle_call(:handle, _from, state), do: {:reply, state.handle, state}

  def handle_call(:flush, from, %{task: nil} = state),
    do: {:noreply, start_flush(%{state | caller: from})}

  def handle_call(:flush, _from, state), do: {:reply, {:error, :busy}, state}

  @impl true
  def handle_info(:tick, %{task: nil} = state), do: {:noreply, start_flush(state)}
  def handle_info(:tick, state), do: {:noreply, state}

  def handle_info({reference, result}, %{task: %{ref: reference}} = state) do
    Process.demonitor(reference, [:flush])
    {:noreply, finished(result, state)}
  end

  def handle_info(
        {:DOWN, reference, :process, _pid, _reason},
        %{task: %{ref: reference}} = state
      ),
      do: {:noreply, finished({:error, :unavailable}, state)}

  defp finished(result, state) do
    if state.caller, do: GenServer.reply(state.caller, result)
    backoff = if result == :ok, do: 1_000, else: min(state.backoff * 2, 30_000)
    if state.timer, do: Process.cancel_timer(state.timer)
    timer = Process.send_after(self(), :tick, backoff)
    %{state | task: nil, caller: nil, backoff: backoff, timer: timer}
  end

  defp start_flush(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    task = Task.Supervisor.async_nolink(state.supervisor, fn -> flush_batch(state) end)
    %{state | task: task, timer: nil}
  end

  defp flush_batch(state) do
    now = state.handle.clock.()
    interval = state.opts[:activity_interval_ms]
    rows = :ets.select(state.handle.table, [{{:"$1", :"$2", :"$3"}, [], [:"$_"]}])

    Enum.each(rows, fn {id, _observed, _flushed} ->
      unless state.alive.(id), do: remove(id, state.handle.table)
    end)

    rows
    |> Enum.filter(fn {_id, observed, flushed} ->
      observed > 0 and (is_nil(flushed) or now - flushed >= interval)
    end)
    |> Enum.take(state.opts[:activity_batch_size])
    |> Enum.each(fn {id, observed, _flushed} ->
      if state.alive.(id) do
        :ok = state.persist.(id, DateTime.from_unix!(observed, :microsecond))
        acknowledge(id, observed, now, state.handle.table)
      end
    end)

    :ok
  rescue
    _error -> {:error, :unavailable}
  end

  defp acknowledge(id, observed, now, table) do
    case :ets.lookup(table, id) do
      [{^id, current, previous}] ->
        pending = if current == observed, do: 0, else: current
        spec = [{{id, current, previous}, [], [{:const, {id, pending, now}}]}]
        if :ets.select_replace(table, spec) == 0, do: acknowledge(id, observed, now, table)

      [] ->
        :ok
    end
  end

  defp remove(id, table) do
    if :ets.take(table, id) != [], do: :ets.update_counter(table, :count, -1)
  end

  defp persist(id, timestamp) do
    from(client in Client,
      where: client.id == ^id,
      update: [set: [last_seen_at: fragment("GREATEST(?, ?)", client.last_seen_at, ^timestamp)]]
    )
    |> Repo.update_all([])

    :telemetry.execute([:backplane, :client_auth, :activity_write], %{count: 1}, %{})
    :ok
  end

  defp alive?(id) do
    before = :ets.lookup(:backplane_client_auth_control, :snapshot)
    exists? = :ets.member(:backplane_clients_cache, id)
    after_read = :ets.lookup(:backplane_client_auth_control, :snapshot)

    case {before, after_read} do
      {[{:snapshot, epoch, loaded_at, _}], [{:snapshot, epoch, loaded_at, _}]}
      when rem(epoch, 2) == 0 and is_integer(loaded_at) ->
        exists?

      _publishing_or_unavailable ->
        true
    end
  end

  defp config do
    defaults = [activity_capacity: 4_096, activity_batch_size: 100, activity_interval_ms: 30_000]
    config = Keyword.merge(defaults, Application.get_env(:backplane_system, :client_auth, []))
    true = is_integer(config[:activity_capacity]) and config[:activity_capacity] > 0
    true = is_integer(config[:activity_batch_size]) and config[:activity_batch_size] > 0
    true = config[:activity_interval_ms] >= 30_000
    config
  end

  defp clock, do: System.monotonic_time(:millisecond)
end
