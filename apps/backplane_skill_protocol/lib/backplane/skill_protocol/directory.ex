defmodule Backplane.SkillProtocol.Directory do
  @moduledoc """
  Host-supervised directory of local skills and remote Always return summaries.

  Registration starts background indexing. Snapshot reads and subscriptions
  only access the published in-memory view. See the package README for host
  setup, policies, and recovery.
  """

  use GenServer

  alias Backplane.SkillProtocol.Directory.{Remote, Snapshot, Source, Watch}
  alias Backplane.SkillProtocol.{Error, SkillRef, Source.Backplane}

  @defaults [
    debounce_ms: 35,
    remote_events: true,
    remote_cache_bytes: 64 * 1024 * 1024,
    websocket: HTTP.WebSocket,
    watch: true
  ]

  @type source :: {:local, Path.t()} | {:local, Path.t(), keyword()} | Backplane.t()
  @type registration :: {String.t(), source()} | {String.t(), source(), integer()}
  @type server :: GenServer.server()

  @doc "Starts a directory under the caller's supervision tree."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {server_opts, opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, opts, server_opts)
  end

  @doc """
  Replaces the effective configuration of a scope.

  Supply `:sources` as a list of `{source_id, source}` or
  `{source_id, source, precedence}` tuples. Equal source configurations share an
  index even if scopes assign different precedence. `:disabled` contains names
  or `{source_id, skill_id}` pairs. `:allow_explicit` defaults to true.
  """
  @spec register_scope(server(), term(), keyword()) :: :ok | {:error, Error.t()}
  def register_scope(server, scope, opts) do
    with {:ok, registration} <- registration(opts) do
      GenServer.call(server, {:register, scope, registration})
    end
  end

  @doc "Removes a scope and releases sources no longer used by any scope."
  @spec unregister_scope(server(), term()) :: :ok
  def unregister_scope(server, scope), do: GenServer.call(server, {:unregister, scope})

  @doc "Returns the current in-memory snapshot, or `{:error, :unknown_scope}`."
  @spec snapshot(server(), term()) :: {:ok, Snapshot.t()} | {:error, :unknown_scope}
  def snapshot(server, scope), do: GenServer.call(server, {:snapshot, scope})

  @doc """
  Subscribes the caller and returns the current snapshot in the same operation.

  Changes send `{:skill_directory_updated, directory_pid, scope, revision}`.
  Read the latest snapshot after a notification. Caller exit removes the subscription.
  """
  @spec subscribe(server(), term()) :: {:ok, Snapshot.t()} | {:error, :unknown_scope}
  def subscribe(server, scope), do: GenServer.call(server, {:subscribe, scope})

  @doc "Removes the caller's subscription for the scope."
  @spec unsubscribe(server(), term()) :: :ok
  def unsubscribe(server, scope), do: GenServer.call(server, {:unsubscribe, scope})

  @doc "Schedules a full reload of a scope or one enabled source in that scope."
  @spec force_reload(server(), term(), String.t() | :all) ::
          :ok | {:error, :unknown_scope | :unknown_source}
  def force_reload(server, scope, source_id \\ :all),
    do: GenServer.call(server, {:force_reload, scope, source_id})

  @doc """
  Loads a resource from an exact remote reference using the notification-backed cache.

  The returned map contains `:content`, the parsed `:document`, and the verified `:manifest`.
  The source must have an authorized notification connection for this scope.
  """
  @spec read_remote(server(), term(), SkillRef.t(), String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def read_remote(server, scope, ref, path \\ "SKILL.md") do
    with {:ok, pid} <- GenServer.call(server, {:remote_reader, scope, ref}),
         {:ok, result} <- Remote.read(pid, ref, path),
         :ok <-
           GenServer.call(
             server,
             {:validate_remote_read, scope, ref, pid, result.generation, result.manifest}
           ) do
      {:ok, Map.delete(result, :generation)}
    end
  end

  @impl true
  def init(opts) do
    options = Map.merge(Map.new(@defaults), Map.new(opts))

    if Keyword.keys(opts) -- Keyword.keys(@defaults) == [] and valid_options?(options) do
      Process.flag(:trap_exit, true)
      {:ok, tasks} = Task.Supervisor.start_link()

      {:ok,
       %{
         options: options,
         tasks: tasks,
         scopes: %{},
         indexes: %{},
         jobs: %{},
         watches: %{},
         remotes: %{}
       }}
    else
      {:stop, :invalid_directory_options}
    end
  end

  @impl true
  def handle_call({:register, scope, config}, _from, state) do
    previous = Map.get(state.scopes, scope, %{config: nil, snapshot: nil, subscribers: %{}})

    state =
      if previous.config == config do
        state
      else
        state
        |> put_in([:scopes, scope], %{previous | config: config})
        |> reconcile_sources()
        |> publish(scope, true)
      end

    {:reply, :ok, state}
  end

  def handle_call({:unregister, scope}, _from, state) do
    case Map.pop(state.scopes, scope) do
      {nil, _} ->
        {:reply, :ok, state}

      {removed, scopes} ->
        notify(removed.subscribers, scope, revision())
        Enum.each(removed.subscribers, fn {_pid, ref} -> Process.demonitor(ref, [:flush]) end)
        {:reply, :ok, reconcile_sources(%{state | scopes: scopes})}
    end
  end

  def handle_call({:snapshot, scope}, _from, state), do: {:reply, lookup(state, scope), state}

  def handle_call({:subscribe, scope}, {pid, _tag}, state) do
    case lookup(state, scope) do
      {:ok, _} = result ->
        state =
          update_in(state, [:scopes, scope, :subscribers], fn subscribers ->
            Map.put_new_lazy(subscribers, pid, fn -> Process.monitor(pid) end)
          end)

        {:reply, result, state}

      result ->
        {:reply, result, state}
    end
  end

  def handle_call({:unsubscribe, scope}, {pid, _tag}, state) do
    case get_in(state, [:scopes, scope, :subscribers, pid]) do
      nil ->
        {:reply, :ok, state}

      ref ->
        Process.demonitor(ref, [:flush])
        {:reply, :ok, update_in(state, [:scopes, scope, :subscribers], &Map.delete(&1, pid))}
    end
  end

  def handle_call({:force_reload, scope, source_id}, _from, state) do
    case refresh_keys(state, scope, source_id) do
      {:ok, keys} ->
        # An explicit refresh must also find writes whose filesystem stamps match.
        {:reply, :ok, Enum.reduce(keys, state, &force_source_reload(&2, &1))}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:remote_reader, scope, ref}, _from, state) do
    result =
      with {:ok, _config, %{remote: pid, status: status}}
           when is_pid(pid) and status in [:ready, :stale] <-
             remote_access(state, scope, ref) do
        {:ok, pid}
      else
        {:error, _} = error -> error
        _ -> read_error(:temporarily_unavailable, "remote skill notifications are unavailable")
      end

    {:reply, result, state}
  end

  def handle_call({:validate_remote_read, scope, ref, pid, generation, manifest}, _from, state) do
    result =
      with {:ok, config, %{remote: ^pid, generation: ^generation, status: status}}
           when status in [:ready, :stale] <-
             remote_access(state, scope, ref) do
        if MapSet.member?(config.disabled, manifest.document_metadata["name"]),
          do: read_error(:forbidden, "remote skill is disabled"),
          else: :ok
      else
        {:error, _} = error -> error
        _ -> read_error(:temporarily_unavailable, "remote skill authorization changed")
      end

    {:reply, result, state}
  end

  def handle_call({:watch_targets, key, targets, reload?}, {pid, _tag}, state) do
    case state.indexes do
      %{^key => %{task: %{pid: ^pid}, watcher: watcher}} ->
        state = watch_targets(state, key, watcher, targets, reload?)

        case state.indexes[key].watcher do
          {watcher_pid, _root} -> {:reply, {:watching, watcher_pid}, state}
          nil -> {:reply, :ok, state}
        end

      _ ->
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info({:refresh, key, ticket}, state) do
    case state.indexes do
      %{^key => %{ticket: ^ticket, records: records, pending: changes} = index} ->
        directory = self()
        before_scan = root_listener(directory, key, state.options.watch, changes)

        task =
          Task.Supervisor.async_nolink(state.tasks, fn ->
            Source.refresh(key, records, changes, before_scan)
          end)

        state =
          state
          |> put_in([:indexes, key], %{index | task: task, pending: nil, ticket: nil})
          |> put_in([:jobs, task.ref], key)

        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({ref, result}, state) when is_reference(ref) and is_map_key(state.jobs, ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish(state, ref, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _}, state) when is_map_key(state.jobs, ref) do
    error =
      Error.new(:temporarily_unavailable, :directory, "source refresh exited", retryable: true)

    {:noreply, finish(state, ref, {:error, error})}
  end

  def handle_info({:DOWN, ref, :process, pid, _}, state) when is_map_key(state.watches, pid) do
    case state.watches[pid] do
      {key, ^ref} ->
        {:noreply,
         state
         |> update_in([:watches], &Map.delete(&1, pid))
         |> put_in([:indexes, key, :watcher], nil)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, pid, _}, state) do
    scopes =
      Map.new(state.scopes, fn {scope, config} ->
        case config.subscribers do
          %{^pid => ^ref} -> {scope, %{config | subscribers: Map.delete(config.subscribers, pid)}}
          _ -> {scope, config}
        end
      end)

    {:noreply, %{state | scopes: scopes}}
  end

  def handle_info({:file_event, pid, {path, _events}}, state)
      when is_map_key(state.watches, pid) do
    {key, _ref} = Map.fetch!(state.watches, pid)
    {:noreply, queue(state, key, {:path, Path.expand(path)})}
  end

  def handle_info({:EXIT, pid, reason}, %{tasks: pid} = state), do: {:stop, reason, state}

  def handle_info({:remote_snapshot, pid, generation, descriptors, categories}, state)
      when is_map_key(state.remotes, pid) do
    {:noreply,
     publish_remote(state, pid, %{
       status: :ready,
       notifications: :online,
       generation: generation,
       descriptors: descriptors,
       search_categories: categories,
       error: nil
     })}
  end

  def handle_info(
        {:remote_unavailable, pid, notifications, generation, descriptors, categories, error},
        state
      )
      when is_map_key(state.remotes, pid) do
    status = if notifications == :offline and is_binary(generation), do: :stale, else: :error

    {:noreply,
     publish_remote(state, pid, %{
       status: status,
       notifications: notifications,
       generation: generation,
       descriptors: descriptors,
       search_categories: categories,
       error: error
     })}
  end

  def handle_info({:EXIT, pid, _}, state) when is_map_key(state.remotes, pid) do
    {:error, error} =
      read_error(:temporarily_unavailable, "remote skill notification process exited")

    state =
      publish_remote(state, pid, %{
        status: :error,
        notifications: :error,
        generation: nil,
        descriptors: [],
        search_categories: [],
        error: error
      })

    {key, remotes} = Map.pop!(state.remotes, pid)
    {:noreply, open_remote(%{state | remotes: remotes}, key)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp publish_remote(state, pid, attrs) do
    key = Map.fetch!(state.remotes, pid)
    previous = Map.fetch!(state.indexes, key)
    index = Map.merge(previous, attrs)
    state = put_in(state, [:indexes, key], index)
    publish_source(state, key, previous, index)
  end

  defp registration(opts) do
    with true <- Keyword.keyword?(opts),
         [] <- Keyword.keys(opts) -- [:sources, :disabled, :allow_explicit],
         true <- is_list(opts[:sources]),
         {:ok, sources} <- normalize_sources(opts[:sources]),
         disabled when is_list(disabled) <- Keyword.get(opts, :disabled, []),
         true <- Enum.all?(disabled, &valid_disabled?/1),
         allow_explicit when is_boolean(allow_explicit) <-
           Keyword.get(opts, :allow_explicit, true) do
      {:ok, %{sources: sources, disabled: MapSet.new(disabled), allow_explicit: allow_explicit}}
    else
      {:error, _} = error -> error
      _ -> {:error, Error.new(:invalid_request, :directory, "invalid scope registration")}
    end
  end

  defp normalize_sources(sources) do
    Enum.reduce_while(sources, {:ok, %{}}, fn registration, {:ok, sources} ->
      case Source.normalize(registration) do
        {:ok, {{id, _spec}, _precedence} = source} ->
          if Map.has_key?(sources, id) do
            {:halt,
             {:error, Error.new(:invalid_request, :directory, "duplicate scope source ID")}}
          else
            {:cont, {:ok, Map.put(sources, id, source)}}
          end

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, sources} -> {:ok, sources |> Map.values() |> Enum.sort()}
      error -> error
    end
  end

  defp valid_disabled?(name) when is_binary(name), do: true
  defp valid_disabled?({source, id}) when is_binary(source) and is_binary(id), do: true
  defp valid_disabled?(_), do: false

  defp valid_options?(options) do
    is_boolean(options.watch) and is_integer(options.debounce_ms) and options.debounce_ms >= 0 and
      is_boolean(options.remote_events) and is_atom(options.websocket) and
      is_integer(options.remote_cache_bytes) and options.remote_cache_bytes > 0
  end

  defp root_listener(directory, {_, {:local, path, _}} = key, true, {_paths, reload?}) do
    fn root ->
      targets = Watch.targets(path, root)

      case GenServer.call(directory, {:watch_targets, key, targets, reload?}) do
        :ok -> :ok
        {:watching, pid} -> Watch.await_start(pid)
      end
    end
  end

  defp root_listener(_directory, _key, _watch?, _changes), do: fn _root -> :ok end

  defp lookup(state, scope) do
    case state.scopes do
      %{^scope => %{snapshot: snapshot}} -> {:ok, snapshot}
      _ -> {:error, :unknown_scope}
    end
  end

  defp refresh_keys(state, scope, source_id) do
    case state.scopes do
      %{^scope => %{config: config}} ->
        keys = for {{id, _spec} = key, _} <- config.sources, source_id in [:all, id], do: key

        if keys == [] and source_id != :all, do: {:error, :unknown_source}, else: {:ok, keys}

      _ ->
        {:error, :unknown_scope}
    end
  end

  defp remote_access(state, scope, %SkillRef{source_id: id, skill_id: skill_id}) do
    with %{config: config} <- state.scopes[scope],
         {{^id, {:remote, _}} = key, _} <-
           Enum.find(config.sources, fn {{source_id, _}, _} -> source_id == id end),
         false <- MapSet.member?(config.disabled, {id, skill_id}) do
      {:ok, config, state.indexes[key]}
    else
      true -> read_error(:forbidden, "remote skill is disabled")
      _ -> read_error(:not_found, "remote skill source is not registered in this scope")
    end
  end

  defp remote_access(_state, _scope, _ref),
    do: read_error(:invalid_request, "an exact remote skill reference is required")

  defp read_error(code, message), do: {:error, Error.new(code, :directory, message)}

  defp reconcile_sources(state) do
    needed =
      for {_scope, entry} <- state.scopes,
          {key, _} <- entry.config.sources,
          into: MapSet.new(),
          do: key

    state =
      Enum.reduce(state.indexes, state, fn {key, index}, state ->
        if MapSet.member?(needed, key), do: state, else: drop_source(state, key, index)
      end)

    Enum.reduce(needed, state, fn key, state ->
      if Map.has_key?(state.indexes, key) do
        state
      else
        index = %{
          status: :warming,
          descriptors: [],
          diagnostics: [],
          error: nil,
          records: nil,
          task: nil,
          pending: nil,
          ticket: nil,
          watcher: nil,
          generation: nil,
          notifications: nil,
          search_categories: [],
          remote: nil
        }

        state
        |> put_in([:indexes, key], index)
        |> start_source(key)
      end
    end)
  end

  defp start_source(%{options: %{remote_events: true}} = state, {_, {:remote, _}} = key),
    do: open_remote(state, key)

  defp start_source(state, key), do: queue(state, key, :scan)

  defp open_remote(state, {_, {:remote, source}} = key) do
    {:ok, pid} = Remote.start_link(self(), state.tasks, source, state.options)

    state
    |> put_in([:remotes, pid], key)
    |> put_in([:indexes, key, :remote], pid)
    |> put_in([:indexes, key, :notifications], :connecting)
  end

  defp force_source_reload(state, key) do
    case state.indexes[key].remote do
      nil ->
        queue(state, key, :audit)

      pid ->
        Remote.reload(pid)
        state
    end
  end

  defp drop_source(state, key, index) do
    state = stop_watcher(state, index.watcher)
    state = stop_remote(state, index.remote)

    state =
      case index.task do
        nil ->
          state

        task ->
          Process.demonitor(task.ref, [:flush])
          Process.exit(task.pid, :kill)
          update_in(state.jobs, &Map.delete(&1, task.ref))
      end

    update_in(state.indexes, &Map.delete(&1, key))
  end

  defp stop_remote(state, nil), do: state

  defp stop_remote(state, pid) do
    Process.unlink(pid)
    GenServer.cast(pid, :stop)
    update_in(state.remotes, &Map.delete(&1, pid))
  end

  defp queue(state, key, change) do
    state
    |> update_in([:indexes, key, :pending], &merge_change(&1, change))
    |> schedule_refresh(key)
  end

  defp merge_change(nil, change), do: merge_change({MapSet.new(), false}, change)
  defp merge_change({paths, _}, :audit), do: {paths, true}
  defp merge_change({paths, audit?}, {:path, path}), do: {MapSet.put(paths, path), audit?}
  defp merge_change(pending, :scan), do: pending

  defp schedule_refresh(state, key) do
    case state.indexes[key] do
      %{pending: pending, task: nil, ticket: nil} when not is_nil(pending) ->
        ticket = make_ref()
        Process.send_after(self(), {:refresh, key, ticket}, state.options.debounce_ms)
        put_in(state, [:indexes, key, :ticket], ticket)

      _ ->
        state
    end
  end

  defp finish(state, ref, result) do
    {key, jobs} = Map.pop!(state.jobs, ref)
    index = %{state.indexes[key] | task: nil}
    state = %{state | jobs: jobs}

    case {result, index.pending} do
      {{:retry, records}, _} ->
        state
        |> put_in([:indexes, key], %{index | records: records})
        |> queue(key, :scan)

      {{:ok, %{records: records}}, pending} when not is_nil(pending) ->
        state
        |> put_in([:indexes, key], %{index | records: records})
        |> schedule_refresh(key)

      {{:error, _}, pending} when not is_nil(pending) ->
        state
        |> put_in([:indexes, key], index)
        |> schedule_refresh(key)

      {result, nil} ->
        next = record_outcome(index, result)
        state = put_in(state, [:indexes, key], next)
        publish_source(state, key, index, next)
    end
  end

  defp record_outcome(index, {:ok, view}),
    do: %{Map.merge(index, view) | status: :ready, error: nil}

  defp record_outcome(
         %{status: status} = index,
         {:error, %Error{retryable: retryable, code: code} = error}
       )
       when status in [:ready, :stale] and
              (code in [:temporarily_unavailable, :timeout] or
                 (retryable and code not in [:unauthorized, :forbidden])),
       do: %{index | status: :stale, error: error}

  defp record_outcome(index, {:error, error}),
    do: %{index | status: :error, error: error, descriptors: [], diagnostics: [], records: nil}

  defp watch_targets(state, _key, {_pid, targets}, targets, false), do: state
  defp watch_targets(state, _key, nil, [], _reload?), do: state

  defp watch_targets(state, key, watcher, targets, _reload?) do
    state = stop_watcher(state, watcher)

    case targets do
      [_ | _] ->
        directory = self()

        {:ok, pid} =
          Task.Supervisor.start_child(state.tasks, fn -> Watch.run(directory, targets) end)

        state
        |> put_in([:watches, pid], {key, Process.monitor(pid)})
        |> put_in([:indexes, key, :watcher], {pid, targets})

      [] ->
        put_in(state, [:indexes, key, :watcher], nil)
    end
  end

  defp stop_watcher(state, nil), do: state

  defp stop_watcher(state, {pid, _root}) do
    {{_key, ref}, watches} = Map.pop!(state.watches, pid)
    Process.demonitor(ref, [:flush])
    Process.exit(pid, :shutdown)
    %{state | watches: watches}
  end

  defp publish_source(state, key, previous, current) do
    fields = [
      :status,
      :descriptors,
      :diagnostics,
      :error,
      :generation,
      :notifications,
      :search_categories
    ]

    if Map.take(previous, fields) == Map.take(current, fields) do
      state
    else
      Enum.reduce(state.scopes, state, fn {scope, entry}, state ->
        if List.keymember?(entry.config.sources, key, 0),
          do: publish(state, scope, false),
          else: state
      end)
    end
  end

  defp publish(state, scope, config_changed?) do
    entry = state.scopes[scope]
    previous_revision = if entry.snapshot, do: entry.snapshot.revision
    snapshot = Snapshot.build(scope, entry.config, state.indexes, previous_revision)

    if config_changed? or snapshot != entry.snapshot do
      snapshot = %{snapshot | revision: revision()}
      notify(entry.subscribers, scope, snapshot.revision)
      put_in(state, [:scopes, scope, :snapshot], snapshot)
    else
      state
    end
  end

  defp notify(subscribers, scope, revision) do
    Enum.each(subscribers, fn {pid, _} ->
      send(pid, {:skill_directory_updated, self(), scope, revision})
    end)
  end

  defp revision, do: System.unique_integer([:positive, :monotonic])
end
