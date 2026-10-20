defmodule Backplane.Clients.AuthCache do
  @moduledoc """
  Node-local digest index and leased authorization snapshots.

  Requests read protected ETS directly, without SQL, verification tasks or
  negative-cache state. Background snapshot publication and mutations share
  revision fencing and an incarnation/epoch lease checked around every read.
  """
  use GenServer

  alias Backplane.Clients.{Activity, Client}
  alias Backplane.Repo

  @defaults [refresh_interval_ms: 15_000, snapshot_max_age_ms: 30_000, max_token_bytes: 16_384]

  def options,
    do: Keyword.merge(@defaults, Application.get_env(:backplane_system, :client_auth, []))

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  def default_handle do
    %{
      server: __MODULE__,
      clients: :backplane_clients_cache,
      digests: :backplane_client_auth_digests,
      control: :backplane_client_auth_control,
      clock: &monotonic_now/0,
      opts: options(),
      activity: true
    }
  end

  def handle(server), do: GenServer.call(server, :handle)

  def token_size_valid?(token),
    do:
      is_binary(token) and byte_size(token) > 0 and
        byte_size(token) <= options()[:max_token_bytes]

  def token_format_valid?(<<"bp2_", secret::binary-size(43)>>) do
    case Base.url_decode64(secret, padding: false) do
      {:ok, bytes} when byte_size(bytes) == 32 ->
        Base.url_encode64(bytes, padding: false) == secret

      _other ->
        false
    end
  end

  def token_format_valid?(_token), do: false

  def verify(token, handle \\ default_handle()) do
    if token_format_valid?(token) do
      digest = :crypto.hash(:sha256, token)

      with {:ok, epoch, loaded_at, _any?} <- snapshot(handle) do
        result =
          case :ets.lookup(handle.digests, digest) do
            [{^digest, id}] -> resolve_client(id, digest, handle)
            [] -> :error
          end

        if stable?(epoch, loaded_at, handle) do
          case result do
            {:ok, client} -> success(client, handle)
            failure -> failure
          end
        else
          {:error, :unavailable}
        end
      end
    else
      :error
    end
  rescue
    ArgumentError -> {:error, :unavailable}
  end

  def any_clients?(handle \\ default_handle()) do
    case snapshot(handle) do
      {:ok, _epoch, _loaded_at, any?} -> any?
      _unavailable -> true
    end
  rescue
    ArgumentError -> true
  end

  def refresh(handle \\ default_handle()) do
    {revision, loader} = GenServer.call(handle.server, :refresh_ticket)
    result = load(loader, handle.clock)
    GenServer.call(handle.server, {:publish, revision, result})
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  def mutate(handle \\ default_handle(), change),
    do: GenServer.call(handle.server, {:mutate, change})

  def begin_mutation(handle \\ default_handle()),
    do: GenServer.call(handle.server, :begin_mutation)

  def abort_mutation(handle \\ default_handle()),
    do: GenServer.call(handle.server, :abort_mutation)

  def stats(handle \\ default_handle()), do: GenServer.call(handle.server, :stats)

  @impl true
  def init(opts) do
    named? = Keyword.get(opts, :named_tables, true)
    config = Keyword.merge(options(), opts)

    Enum.each(@defaults, fn {key, _default} ->
      true = is_integer(config[key]) and config[key] > 0
    end)

    handle = %{
      server: self(),
      clients: table(:backplane_clients_cache, named?),
      digests: table(:backplane_client_auth_digests, named?),
      control: table(:backplane_client_auth_control, named?),
      opts: config,
      clock: Keyword.get(opts, :clock, &monotonic_now/0),
      activity: Keyword.get(opts, :activity, named?)
    }

    :ets.insert(handle.control, {:snapshot, 0, nil, true})
    if named?, do: Phoenix.PubSub.subscribe(Backplane.PubSub, "client_auth:invalidations")

    state = %{
      handle: handle,
      revision: 0,
      loader:
        Keyword.get(opts, :load, fn -> Repo.all(Client, log: false, telemetry_event: nil) end),
      supervisor: Keyword.get(opts, :task_supervisor, Backplane.Clients.Tasks),
      refresh: nil,
      blocked: false,
      loaded_at: nil,
      mutation_monitor: nil,
      refresh_pending: false
    }

    {:ok, state, {:continue, :refresh}}
  end

  @impl true
  def handle_continue(:refresh, state), do: {:noreply, start_refresh(state)}

  @impl true
  def handle_call(:handle, _from, state), do: {:reply, state.handle, state}

  def handle_call(:refresh_ticket, _from, state) do
    state = %{state | revision: state.revision + 1}
    {:reply, {state.revision, state.loader}, state}
  end

  def handle_call(:stats, _from, state) do
    {:reply,
     %{
       clients: :ets.info(state.handle.clients, :size),
       digests: :ets.info(state.handle.digests, :size)
     }, state}
  end

  def handle_call({:publish, revision, result}, _from, state) do
    {reply, state} = publish(revision, result, state)
    {:reply, reply, state}
  end

  def handle_call(:begin_mutation, {caller, _tag}, state) do
    [{:snapshot, epoch, _loaded, _any?}] = :ets.lookup(state.handle.control, :snapshot)
    :ets.insert(state.handle.control, {:snapshot, epoch + 2, nil, true})

    {:reply, :ok,
     %{
       state
       | revision: state.revision + 1,
         blocked: true,
         mutation_monitor: Process.monitor(caller)
     }}
  end

  def handle_call(:abort_mutation, _from, state), do: {:reply, :ok, end_mutation(state)}

  def handle_call({:mutate, change}, _from, state) do
    state = %{state | revision: state.revision + 1}
    [{:snapshot, epoch, _loaded_at, _any?}] = :ets.lookup(state.handle.control, :snapshot)
    :ets.insert(state.handle.control, {:snapshot, epoch + 1, nil, true})

    case change do
      {:put, client} ->
        remove_digest(client.id, state.handle)
        :ets.insert(state.handle.clients, {client.id, client})
        index_client(client, state.handle)

      {:delete, id} ->
        remove_digest(id, state.handle)
        :ets.delete(state.handle.clients, id)
    end

    any? = :ets.info(state.handle.clients, :size) > 0
    :ets.insert(state.handle.control, {:snapshot, epoch + 2, state.loaded_at, any?})
    {:reply, :ok, end_mutation(state)}
  end

  @impl true
  def handle_info(:refresh, state), do: {:noreply, start_refresh(state)}

  def handle_info(
        {reference, {:snapshot_result, revision, result}},
        %{refresh: %{ref: reference}} = state
      ) do
    Process.demonitor(reference, [:flush])
    {_reply, state} = publish(revision, result, state)
    {:noreply, schedule_refresh(%{state | refresh: nil})}
  end

  def handle_info({:DOWN, reference, :process, _pid, _reason}, state) do
    cond do
      state.mutation_monitor == reference ->
        # The invalid lease remains invalid until a successful reload.
        {:noreply, %{state | blocked: false, mutation_monitor: nil}}

      state.refresh != nil and state.refresh.ref == reference ->
        {:noreply, schedule_refresh(%{state | refresh: nil})}

      true ->
        {:noreply, state}
    end
  end

  def handle_info({:client_auth_invalidated, origin, _client_id}, state) when origin != node() do
    [{:snapshot, epoch, _loaded_at, _any?}] = :ets.lookup(state.handle.control, :snapshot)
    :ets.insert(state.handle.control, {:snapshot, epoch + 2, nil, true})
    state = %{state | revision: state.revision + 1, loaded_at: nil}
    state = if state.refresh, do: %{state | refresh_pending: true}, else: start_refresh(state)
    {:noreply, state}
  end

  def handle_info({:client_auth_invalidated, _origin, _client_id}, state), do: {:noreply, state}

  defp snapshot(handle) do
    incarnation = :ets.info(handle.control, :id)

    case :ets.lookup(incarnation, :snapshot) do
      [{:snapshot, epoch, loaded_at, any?}] when rem(epoch, 2) == 0 and is_integer(loaded_at) ->
        if handle.clock.() - loaded_at < handle.opts[:snapshot_max_age_ms],
          do: {:ok, {incarnation, epoch}, loaded_at, any?},
          else: {:error, :unavailable}

      _other ->
        {:error, :unavailable}
    end
  end

  defp stable?(epoch, loaded_at, handle),
    do: match?({:ok, ^epoch, ^loaded_at, _any?}, snapshot(handle))

  defp resolve_client(id, digest, handle) do
    case :ets.lookup(handle.clients, id) do
      [{^id, %Client{active: true, token_digest: ^digest} = client}] -> {:ok, client}
      _other -> :error
    end
  end

  defp publish(revision, {:ok, clients, loaded_at}, %{revision: revision, blocked: false} = state) do
    [{:snapshot, epoch, _loaded, _any?}] = :ets.lookup(state.handle.control, :snapshot)
    :ets.insert(state.handle.control, {:snapshot, epoch + 1, nil, true})
    :ets.delete_all_objects(state.handle.clients)
    :ets.delete_all_objects(state.handle.digests)
    :ets.insert(state.handle.clients, Enum.map(clients, &{&1.id, &1}))
    Enum.each(clients, &index_client(&1, state.handle))
    :ets.insert(state.handle.control, {:snapshot, epoch + 2, loaded_at, clients != []})
    {:ok, %{state | loaded_at: loaded_at}}
  end

  defp publish(_revision, _result, state), do: {{:error, :unavailable}, state}

  defp remove_digest(id, handle) do
    case :ets.lookup(handle.clients, id) do
      [{^id, %Client{token_digest: digest}}] when is_binary(digest) ->
        :ets.delete(handle.digests, digest)

      _other ->
        :ok
    end
  end

  defp index_client(%Client{active: true, token_digest: digest, id: id}, handle)
       when is_binary(digest) and byte_size(digest) == 32,
       do: :ets.insert(handle.digests, {digest, id})

  defp index_client(_client, _handle), do: :ok

  defp start_refresh(%{blocked: true} = state) do
    Process.send_after(self(), :refresh, 1_000)
    state
  end

  defp start_refresh(%{refresh: nil} = state) do
    state = %{state | revision: state.revision + 1}
    loader = state.loader
    revision = state.revision
    clock = state.handle.clock

    task =
      Task.Supervisor.async_nolink(state.supervisor, fn ->
        {:snapshot_result, revision, load(loader, clock)}
      end)

    %{state | refresh: task}
  end

  defp start_refresh(state), do: state

  defp schedule_refresh(%{refresh_pending: true} = state) do
    send(self(), :refresh)
    %{state | refresh_pending: false}
  end

  defp schedule_refresh(state) do
    Process.send_after(self(), :refresh, state.handle.opts[:refresh_interval_ms])
    state
  end

  defp load(loader, clock) do
    loaded_at = clock.()

    case loader.() do
      clients when is_list(clients) ->
        :telemetry.execute(
          [:backplane, :client_auth, :snapshot_loaded],
          %{clients: length(clients)},
          %{}
        )

        {:ok, clients, loaded_at}

      _other ->
        :error
    end
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  defp success(client, %{activity: true}) do
    Activity.record(client.id)
    {:ok, client}
  end

  defp success(client, _handle), do: {:ok, client}

  defp end_mutation(state) do
    if state.mutation_monitor, do: Process.demonitor(state.mutation_monitor, [:flush])
    %{state | blocked: false, mutation_monitor: nil}
  end

  defp monotonic_now, do: System.monotonic_time(:millisecond)

  defp table(name, named?) do
    opts = [:protected, :set, read_concurrency: true]
    :ets.new(name, if(named?, do: [:named_table | opts], else: opts))
  end
end
