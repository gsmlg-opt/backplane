defmodule Backplane.Clients.AuthCache do
  @moduledoc """
  Node-local verification evidence and leased authorization snapshots.

  Reads bypass the owner. Only admitted cold callers enter its mailbox; bcrypt
  and snapshot SQL run under a supervised task. Evidence has no time expiry:
  authorization is always checked against a stable, fresh current snapshot.
  """
  use GenServer

  alias Backplane.Clients.{Activity, Client}
  alias Backplane.Repo

  @defaults [
    positive_capacity: 4_096,
    negative_capacity: 1_024,
    negative_ttl_ms: 5_000,
    max_workers: 1,
    max_waiters: 64,
    verification_timeout_ms: 10_000,
    refresh_interval_ms: 15_000,
    snapshot_max_age_ms: 30_000,
    max_token_bytes: 16_384
  ]

  def options,
    do: Keyword.merge(@defaults, Application.get_env(:backplane_system, :client_auth, []))

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def default_handle do
    %{
      server: __MODULE__,
      clients: :backplane_clients_cache,
      evidence: :backplane_client_auth_evidence,
      negatives: :backplane_client_auth_negatives,
      control: :backplane_client_auth_control,
      ingress: :backplane_client_auth_ingress,
      clock: &monotonic_now/0,
      opts: options(),
      activity: true
    }
  end

  def handle(server), do: GenServer.call(server, :handle)

  def token_size_valid?(token) do
    is_binary(token) and byte_size(token) > 0 and byte_size(token) <= options()[:max_token_bytes]
  end

  def verify(token, handle \\ default_handle()) do
    if is_binary(token) and byte_size(token) > 0 and
         byte_size(token) <= handle.opts[:max_token_bytes] do
      digest = :crypto.hash(:sha256, token)

      case lookup(digest, handle) do
        {:ok, client} -> success(client, handle)
        :cold -> admit(token, digest, handle)
        failure -> failure
      end
    else
      :error
    end
  rescue
    ArgumentError -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
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

  def mutate(handle \\ default_handle(), change) do
    GenServer.call(handle.server, {:mutate, change})
  catch
    :exit, _reason -> {:error, :unavailable}
  end

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
      clients: table(:backplane_clients_cache, named?, :protected),
      evidence: table(:backplane_client_auth_evidence, named?, :protected),
      negatives: table(:backplane_client_auth_negatives, named?, :protected),
      control: table(:backplane_client_auth_control, named?, :protected),
      ingress: table(:backplane_client_auth_ingress, named?, :public),
      opts: config,
      clock: Keyword.get(opts, :clock, &monotonic_now/0),
      activity: Keyword.get(opts, :activity, named?)
    }

    :ets.insert(handle.control, {:snapshot, 0, nil, true})
    :ets.insert(handle.control, {:credentials, nil})
    if named?, do: Phoenix.PubSub.subscribe(Backplane.PubSub, "client_auth:invalidations")

    if named? and Application.get_env(:backplane, :env) == :test do
      legacy =
        :ets.new(:backplane_client_token_verifications, [
          :named_table,
          :set,
          :public,
          read_concurrency: true,
          write_concurrency: true
        ])

      :ets.insert(legacy, {:generation, 0})
    end

    state = %{
      handle: handle,
      revision: 0,
      sequence: 0,
      flights: %{},
      monitors: %{},
      loader: Keyword.get(opts, :load, fn -> Repo.all(Client) end),
      verifier: Keyword.get(opts, :verify, &Bcrypt.verify_pass/2),
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
    stats = %{
      workers: map_size(state.flights),
      waiters: map_size(state.monitors),
      ingress: :ets.info(state.handle.ingress, :size),
      positives: :ets.info(state.handle.evidence, :size),
      negatives: :ets.info(state.handle.negatives, :size)
    }

    {:reply, stats, state}
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

  def handle_call(:abort_mutation, _from, state) do
    state = end_mutation(state)
    {:reply, :ok, state}
  end

  def handle_call({:mutate, change}, _from, state) do
    state = %{state | revision: state.revision + 1}
    [{:snapshot, epoch, _loaded_at, _any?}] = :ets.lookup(state.handle.control, :snapshot)
    :ets.insert(state.handle.control, {:snapshot, epoch + 1, nil, true})

    case change do
      {:put, client} -> :ets.insert(state.handle.clients, {client.id, client})
      {:delete, id} -> :ets.delete(state.handle.clients, id)
    end

    prune_evidence(state.handle)
    publish_credentials(state.handle)
    :ets.delete_all_objects(state.handle.negatives)
    any? = :ets.info(state.handle.clients, :size) > 0
    :ets.insert(state.handle.control, {:snapshot, epoch + 2, state.loaded_at, any?})
    {:reply, :ok, end_mutation(state)}
  end

  def handle_call({:verify, token, digest, ticket, deadline}, from, state) do
    cond do
      deadline <= state.handle.clock.() -> reject(from, ticket, :unavailable, state)
      not Process.alive?(elem(from, 0)) -> reject(from, ticket, :unavailable, state)
      true -> cold_request(token, digest, ticket, from, state)
    end
  end

  defp cold_request(token, digest, ticket, from, state) do
    case lookup(digest, state.handle) do
      {:ok, client} -> reply_immediate(from, ticket, {:ok, client}, state)
      :error -> reply_immediate(from, ticket, :error, state)
      {:error, reason} -> reject(from, ticket, reason, state)
      :cold -> join_or_start(token, digest, ticket, from, state)
    end
  end

  defp join_or_start(token, digest, ticket, from, state) do
    cond do
      map_size(state.monitors) >= state.handle.opts[:max_waiters] ->
        reject(from, ticket, :overloaded, state)

      match?(%{expired: true}, state.flights[digest]) ->
        reject(from, ticket, :unavailable, state)

      Map.has_key?(state.flights, digest) ->
        {:noreply, add_waiter(digest, ticket, from, state)}

      map_size(state.flights) >= state.handle.opts[:max_workers] ->
        reject(from, ticket, :overloaded, state)

      true ->
        handle = state.handle
        verifier = state.verifier

        task =
          Task.Supervisor.async_nolink(state.supervisor, fn -> scan(token, handle, verifier) end)

        timer =
          Process.send_after(
            self(),
            {:deadline, digest, task.ref},
            handle.opts[:verification_timeout_ms]
          )

        flight = %{
          task: task,
          timer: timer,
          waiters: %{},
          result: {:error, :unavailable},
          expired: false
        }

        state = put_in(state.flights[digest], flight)
        {:noreply, add_waiter(digest, ticket, from, state)}
    end
  end

  @impl true
  def handle_info(:refresh, state) do
    Enum.each(:ets.tab2list(state.handle.ingress), fn {_slot, _reference, caller} = ticket ->
      unless Process.alive?(caller), do: release_ticket(ticket, state.handle)
    end)

    {:noreply, start_refresh(state)}
  end

  def handle_info(
        {reference, {:snapshot_result, revision, result}},
        %{refresh: %{ref: reference}} = state
      ) do
    Process.demonitor(reference, [:flush])
    {_reply, state} = publish(revision, result, state)
    {:noreply, schedule_refresh(%{state | refresh: nil})}
  end

  def handle_info({reference, result}, state) when is_reference(reference) do
    case Enum.find(state.flights, fn {_digest, flight} -> flight.task.ref == reference end) do
      {digest, _flight} -> {:noreply, put_in(state.flights[digest].result, result)}
      nil -> {:noreply, state}
    end
  end

  def handle_info({:deadline, digest, reference}, state) do
    case state.flights[digest] do
      %{task: %{ref: ^reference}} ->
        state = reply_waiters(digest, {:error, :unavailable}, state)
        {:noreply, put_in(state.flights[digest].expired, true)}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, reference, :process, _pid, reason}, state) do
    cond do
      state.mutation_monitor == reference ->
        {:noreply, %{state | blocked: false, mutation_monitor: nil}}

      state.refresh != nil and state.refresh.ref == reference ->
        {:noreply, schedule_refresh(%{state | refresh: nil})}

      Map.has_key?(state.monitors, reference) ->
        {digest, ticket} = state.monitors[reference]
        release_ticket(ticket, state.handle)
        state = update_in(state.flights[digest].waiters, &Map.delete(&1, reference))
        {:noreply, %{state | monitors: Map.delete(state.monitors, reference)}}

      true ->
        {:noreply, finish_flight(reference, reason, state)}
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

  defp finish_flight(reference, reason, state) do
    case Enum.find(state.flights, fn {_digest, flight} -> flight.task.ref == reference end) do
      nil ->
        state

      {digest, flight} ->
        Process.cancel_timer(flight.timer)

        result =
          if reason == :normal and not flight.expired,
            do: resolve(flight.result, state.handle),
            else: {:error, :unavailable}

        cache_result =
          if result == :error and match?({:miss, _credentials}, flight.result),
            do: flight.result,
            else: result

        state = maybe_cache(digest, cache_result, state)
        state = reply_waiters(digest, result, state)
        %{state | flights: Map.delete(state.flights, digest)}
    end
  end

  defp add_waiter(digest, ticket, from, state) do
    reference = Process.monitor(elem(from, 0))
    state = put_in(state.flights[digest].waiters[reference], {from, ticket})
    %{state | monitors: Map.put(state.monitors, reference, {digest, ticket})}
  end

  defp reply_waiters(digest, result, state) do
    Enum.reduce(state.flights[digest].waiters, state, fn {reference, {from, ticket}}, state ->
      Process.demonitor(reference, [:flush])
      GenServer.reply(from, result)
      release_ticket(ticket, state.handle)
      state = update_in(state.flights[digest].waiters, &Map.delete(&1, reference))
      %{state | monitors: Map.delete(state.monitors, reference)}
    end)
  end

  defp reject(from, ticket, reason, state),
    do: reply_immediate(from, ticket, {:error, reason}, state)

  defp reply_immediate(_from, ticket, result, state) do
    release_ticket(ticket, state.handle)
    {:reply, result, state}
  end

  defp admit(token, digest, handle) do
    case acquire_ticket(handle) do
      {:ok, ticket} ->
        deadline = handle.clock.() + handle.opts[:verification_timeout_ms]

        result =
          GenServer.call(
            handle.server,
            {:verify, token, digest, ticket, deadline},
            handle.opts[:verification_timeout_ms] + 1_000
          )

        case result do
          {:ok, client} -> success(client, handle)
          failure -> failure
        end

      :full ->
        {:error, :overloaded}
    end
  end

  defp acquire_ticket(handle) do
    reference = make_ref()

    Enum.find_value(0..(handle.opts[:max_waiters] - 1), :full, fn slot ->
      ticket = {slot, reference, self()}
      if :ets.insert_new(handle.ingress, ticket), do: {:ok, ticket}
    end)
  end

  defp release_ticket(ticket, handle) do
    :ets.select_delete(handle.ingress, [{ticket, [], [true]}])
    :ok
  end

  defp lookup(digest, handle) do
    with {:ok, epoch, loaded_at, _any?} <- snapshot(handle) do
      result =
        case :ets.lookup(handle.evidence, digest) do
          [{^digest, id, fingerprint, _sequence}] -> resolve_client(id, fingerprint, handle)
          [] -> lookup_negative(digest, handle)
        end

      if stable?(epoch, loaded_at, handle), do: result, else: {:error, :unavailable}
    end
  end

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

  defp stable?(epoch, loaded_at, handle) do
    match?({:ok, ^epoch, ^loaded_at, _any?}, snapshot(handle))
  end

  defp lookup_negative(digest, handle) do
    case :ets.lookup(handle.negatives, digest) do
      [{^digest, credentials, expires_at}] ->
        if expires_at > handle.clock.() and
             :ets.lookup_element(handle.control, :credentials, 2) == credentials,
           do: :error,
           else: :cold

      [] ->
        :cold
    end
  end

  defp resolve({:matched, id, fingerprint}, handle) do
    with {:ok, epoch, loaded_at, _any?} <- snapshot(handle) do
      result =
        case resolve_client(id, fingerprint, handle) do
          :cold -> :error
          result -> result
        end

      if stable?(epoch, loaded_at, handle), do: result, else: {:error, :unavailable}
    end
  end

  defp resolve({:miss, credentials}, handle) do
    with {:ok, epoch, loaded_at, _any?} <- snapshot(handle) do
      if :ets.lookup_element(handle.control, :credentials, 2) == credentials and
           stable?(epoch, loaded_at, handle),
         do: :error,
         else: {:error, :unavailable}
    end
  end

  defp resolve(_other, _handle), do: {:error, :unavailable}

  defp resolve_client(id, fingerprint, handle) do
    case :ets.lookup(handle.clients, id) do
      [{^id, %Client{active: true} = client}] ->
        if fingerprint(client) == fingerprint, do: {:ok, client}, else: :cold

      _other ->
        :cold
    end
  end

  defp scan(token, handle, verifier) do
    with {:ok, epoch, loaded_at, _any?} <- snapshot(handle) do
      clients = :ets.tab2list(handle.clients)
      credentials = :ets.lookup_element(handle.control, :credentials, 2)

      if stable?(epoch, loaded_at, handle) do
        :telemetry.execute([:backplane, :client_auth, :scan], %{count: 1}, %{})

        deadline = handle.clock.() + handle.opts[:verification_timeout_ms]
        verify_candidates(clients, token, verifier, handle, deadline, credentials)
      else
        {:error, :unavailable}
      end
    end
  end

  defp verify_candidates([], _token, _verifier, _handle, _deadline, credentials),
    do: {:miss, credentials}

  defp verify_candidates(
         [{id, client} | remaining],
         token,
         verifier,
         handle,
         deadline,
         credentials
       ) do
    cond do
      handle.clock.() >= deadline -> {:error, :unavailable}
      client.active and verifier.(token, client.token_hash) -> {:matched, id, fingerprint(client)}
      true -> verify_candidates(remaining, token, verifier, handle, deadline, credentials)
    end
  end

  defp maybe_cache(digest, {:ok, client}, state) do
    if :ets.info(state.handle.evidence, :size) >= state.handle.opts[:positive_capacity] do
      [{oldest, _id, _fingerprint, _sequence}] =
        Enum.min_by(:ets.tab2list(state.handle.evidence), &elem(&1, 3)) |> List.wrap()

      :ets.delete(state.handle.evidence, oldest)
    end

    sequence = state.sequence + 1
    :ets.insert(state.handle.evidence, {digest, client.id, fingerprint(client), sequence})
    %{state | sequence: sequence}
  end

  defp maybe_cache(digest, {:miss, credentials}, state) do
    if :ets.info(state.handle.negatives, :size) >= state.handle.opts[:negative_capacity] do
      {oldest, _credentials, _expires_at} =
        Enum.min_by(:ets.tab2list(state.handle.negatives), &elem(&1, 2))

      :ets.delete(state.handle.negatives, oldest)
    end

    expires_at = state.handle.clock.() + state.handle.opts[:negative_ttl_ms]
    :ets.insert(state.handle.negatives, {digest, credentials, expires_at})
    state
  end

  defp maybe_cache(_digest, _failure, state), do: state

  defp prune_evidence(handle) do
    Enum.each(:ets.tab2list(handle.evidence), fn {digest, id, fingerprint, _sequence} ->
      unless match?({:ok, _client}, resolve_client(id, fingerprint, handle)),
        do: :ets.delete(handle.evidence, digest)
    end)
  end

  defp publish(revision, {:ok, clients, loaded_at}, %{revision: revision, blocked: false} = state) do
    [{:snapshot, epoch, _loaded, _any?}] = :ets.lookup(state.handle.control, :snapshot)
    :ets.insert(state.handle.control, {:snapshot, epoch + 1, nil, true})
    :ets.delete_all_objects(state.handle.clients)
    :ets.insert(state.handle.clients, Enum.map(clients, &{&1.id, &1}))
    prune_evidence(state.handle)
    publish_credentials(state.handle)
    :ets.insert(state.handle.control, {:snapshot, epoch + 2, loaded_at, clients != []})

    if state.handle.clients == :backplane_clients_cache and
         :ets.whereis(:backplane_client_token_verifications) != :undefined do
      :ets.update_counter(:backplane_client_token_verifications, :generation, 2)
    end

    {:ok, %{state | loaded_at: loaded_at}}
  end

  defp publish(_revision, _result, state), do: {{:error, :unavailable}, state}

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
      clients when is_list(clients) -> {:ok, clients, loaded_at}
      _other -> :error
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

  defp publish_credentials(handle) do
    credentials =
      handle.clients
      |> :ets.tab2list()
      |> Enum.filter(fn {_id, client} -> client.active end)
      |> Enum.map(fn {id, client} -> {id, client.token_hash} end)
      |> Enum.sort()
      |> :erlang.term_to_binary()
      |> then(&:crypto.hash(:sha256, &1))

    :ets.insert(handle.control, {:credentials, credentials})
  end

  defp fingerprint(client), do: :crypto.hash(:sha256, client.token_hash)
  defp monotonic_now, do: System.monotonic_time(:millisecond)

  defp table(name, named?, access) do
    opts = [access, :set, read_concurrency: true, write_concurrency: true]
    :ets.new(name, if(named?, do: [:named_table | opts], else: opts))
  end
end
