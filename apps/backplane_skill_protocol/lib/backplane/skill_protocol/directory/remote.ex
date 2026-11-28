defmodule Backplane.SkillProtocol.Directory.Remote do
  @moduledoc false

  use GenServer

  alias Backplane.SkillProtocol.{Client, Error, SkillRef, Wire}
  alias Backplane.SkillProtocol.Source.Backplane
  alias HTTP.WebSocket.Event

  @retry_ms 1_000
  @max_retry_ms 30_000
  @max_loads 4
  @max_prefetch @max_loads - 1

  def start_link(owner, tasks, source, options) do
    GenServer.start_link(__MODULE__, {owner, tasks, source, options})
  end

  def reload(pid), do: GenServer.cast(pid, :reload)

  def read(pid, ref, path) do
    GenServer.call(pid, {:read, ref, path}, :infinity)
  catch
    :exit, _ -> unavailable()
  end

  @impl true
  def init({owner, tasks, source, options}) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       owner: owner,
       tasks: tasks,
       source: source,
       websocket: options.websocket,
       socket: nil,
       retry: nil,
       retry_ms: @retry_ms,
       credential: nil,
       generation: nil,
       descriptors: %{},
       search_categories: [],
       pending_entries: MapSet.new(),
       entry_task: nil,
       connection: :connecting,
       entries: %{},
       cache_bytes: 0,
       max_cache_bytes: options.remote_cache_bytes,
       loads: %{},
       prefetch: MapSet.new()
     }, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state), do: {:noreply, connect(state, state.generation)}

  @impl true
  def handle_call({:read, ref, path}, from, state) do
    with {:ok, headers} <- headers(state.source.client),
         true <- credential(headers) == state.credential do
      read_current(ref, path, from, state, headers)
    else
      _ ->
        denied = error(:unauthorized, "remote skill credential changed")
        {:reply, denied, connect(reset_connection(clear(state), denied), nil)}
    end
  end

  defp read_current(ref, path, from, state, headers) do
    load = state.loads[ref]
    entry = state.entries[ref]

    cond do
      not exact?(ref, state.source.client.source_id) or not is_binary(path) ->
        {:reply,
         error(:invalid_request, "an exact remote skill reference and resource are required"),
         state}

      entry != nil and state.connection in [:online, :offline] ->
        {:reply, resource(entry, path, state), state}

      state.connection == :offline ->
        {:reply,
         error(
           :temporarily_unavailable,
           "remote skill is not cached while notifications are offline"
         ), state}

      state.connection != :online ->
        {:reply, unavailable(), state}

      match?(%{active?: true}, load) ->
        {:noreply, put_in(state, [:loads, ref, :waiters], [{from, path} | load.waiters])}

      Map.has_key?(state.loads, ref) ->
        {:reply, unavailable(), state}

      map_size(state.loads) >= @max_loads ->
        {:reply, error(:capacity_exceeded, "remote skill loads are at capacity"), state}

      true ->
        {:noreply, start_load(state, ref, [{from, path}], headers)}
    end
  end

  defp start_load(state, ref, waiters, headers) do
    source = %{state.source | client: pinned_client(state, headers)}

    task =
      Task.Supervisor.async_nolink(state.tasks, fn -> Backplane.read_verified(source, ref) end)

    load = %{task: task, waiters: waiters, active?: true}

    state
    |> put_in([:loads, ref], load)
    |> update_in([:prefetch], &MapSet.delete(&1, ref))
  end

  @impl true
  def handle_cast(:reload, state) do
    state = reset_connection(state, unavailable())
    {:noreply, connect(state, nil)}
  end

  def handle_cast(:stop, state), do: {:stop, :normal, state}

  @impl true
  def handle_info({:retry, token}, %{retry: token} = state) do
    {:noreply, connect(%{state | retry: nil}, state.generation)}
  end

  def handle_info({HTTP.WebSocket, socket, %Event.Message{data: data}}, %{socket: socket} = state) do
    case decode(data, state) do
      {:snapshot, generation, descriptors, categories} ->
        state = if generation == state.generation, do: state, else: clear(state)

        state = %{
          state
          | generation: generation,
            descriptors: Map.new(descriptors, &{&1.ref.skill_id, &1}),
            search_categories: categories,
            pending_entries: MapSet.new(),
            entry_task: discard_entry_task(state.entry_task)
        }

        {:noreply, online(state, true)}

      {:unchanged, categories} ->
        {:noreply, online(%{state | search_categories: categories}, state.connection != :online)}

      {:search_categories, categories} ->
        state = %{state | search_categories: categories}
        announce_online(state)
        {:noreply, state}

      {:changed, generation, ids} ->
        state = state |> invalidate(ids) |> Map.put(:generation, generation)
        {:noreply, online(state, false)}

      :heartbeat ->
        {:noreply, state}

      {:error, _} = error ->
        {:noreply, retry(reset_connection(clear(state), error))}
    end
  end

  def handle_info(
        {HTTP.WebSocket, socket, %Event.Error{handshake: %{status: status}}},
        %{socket: socket} = state
      )
      when status in [401, 403] do
    denied = error(:forbidden, "remote skill notification access was denied")
    {:noreply, reset_connection(clear(state), denied)}
  end

  def handle_info({HTTP.WebSocket, socket, %Event.Close{code: 1008}}, %{socket: socket} = state) do
    denied = error(:forbidden, "remote skill notification access was denied")
    {:noreply, reset_connection(clear(state), denied)}
  end

  def handle_info(
        {HTTP.WebSocket, socket, %Event.Error{handshake: %{status: 404}}},
        %{socket: socket} = state
      ) do
    error =
      error(
        :unsupported_capability,
        "remote skill notifications are unavailable at this endpoint"
      )

    {:noreply, reset_connection(clear(state), error)}
  end

  def handle_info({HTTP.WebSocket, socket, %Event.Close{code: 1009}}, %{socket: socket} = state) do
    error = error(:limit_exceeded, "remote skill snapshot exceeds the notification limit")
    {:noreply, reset_connection(clear(state), error)}
  end

  def handle_info({HTTP.WebSocket, socket, %Event.Close{}}, %{socket: socket} = state),
    do: {:noreply, retry(reset_connection(state, unavailable()))}

  def handle_info({ref, result}, %{entry_task: %{task: %{ref: ref}}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, complete_entries(state, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _}, %{entry_task: %{task: %{ref: ref}}} = state),
    do: {:noreply, complete_entries(state, unavailable())}

  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, state |> complete(ref, result) |> start_prefetch()}
  end

  def handle_info({:DOWN, ref, :process, _pid, _}, state),
    do: {:noreply, state |> complete(ref, unavailable()) |> start_prefetch()}

  def handle_info({:EXIT, pid, reason}, %{owner: pid} = state), do: {:stop, reason, state}
  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    close(state)
    _ = cancel_loads(state, unavailable())
    :ok
  end

  defp connect(state, generation) do
    case headers(state.source.client) do
      {:ok, headers} ->
        credential = credential(headers)

        if state.credential == credential do
          open(state, generation, headers)
        else
          state = %{clear(state) | credential: credential}

          state =
            if state.connection == :offline do
              reset_connection(state, error(:unauthorized, "remote skill credential changed"))
            else
              state
            end

          open(state, nil, headers)
        end

      {:error, %Error{code: :unauthorized}} = denied ->
        reset_connection(clear(state), denied)
    end
  end

  defp open(state, generation, headers) do
    client = state.source.client
    uri = URI.parse(client.endpoint)
    query = if generation, do: URI.encode_query(%{"generation" => generation})

    url =
      URI.to_string(%{
        uri
        | scheme: if(uri.scheme == "https", do: "wss", else: "ws"),
          path: "/skill-protocol/v1/events",
          query: query
      })

    case state.websocket.new(url, [],
           headers: headers,
           idle_timeout: 35_000,
           max_message_size: client.max_json_bytes
         ) do
      %HTTP.WebSocket{} = socket -> %{state | socket: socket}
      _ -> retry(reset_connection(state, unavailable()))
    end
  end

  defp credential(headers), do: :crypto.hash(:sha256, :erlang.term_to_binary(headers))
  defp token([]), do: nil
  defp token([{"authorization", "Bearer " <> token}]), do: token

  defp headers(client) do
    case client.credential_supplier.() do
      nil -> {:ok, []}
      {:ok, nil} -> {:ok, []}
      {:ok, token} when is_binary(token) -> {:ok, [{"authorization", "Bearer " <> token}]}
      token when is_binary(token) -> {:ok, [{"authorization", "Bearer " <> token}]}
      _ -> error(:unauthorized, "remote skill credential is unavailable")
    end
  rescue
    _ -> error(:unauthorized, "remote skill credential is unavailable")
  end

  defp pinned_client(state, headers),
    do: %{state.source.client | credential_supplier: fn -> token(headers) end}

  defp active_headers(state) do
    with {:ok, headers} <- headers(state.source.client),
         true <- credential(headers) == state.credential do
      {:ok, headers}
    else
      _ -> error(:unauthorized, "remote skill credential changed")
    end
  end

  defp online(state, prefetch_all?) do
    state = %{state | connection: :online, retry_ms: @retry_ms}

    state =
      if prefetch_all?, do: enqueue_prefetch(state, Map.values(state.descriptors)), else: state

    announce_online(state)
    state |> start_entry_fetch() |> start_prefetch()
  end

  defp announce_online(state) do
    send(
      state.owner,
      {:remote_snapshot, self(), state.generation, Map.values(state.descriptors),
       state.search_categories}
    )
  end

  defp enqueue_prefetch(state, descriptors) do
    refs =
      for %{ref: ref} <- descriptors,
          exact?(ref, state.source.client.source_id) and not Map.has_key?(state.entries, ref),
          into: state.prefetch,
          do: ref

    %{state | prefetch: refs}
  end

  defp start_prefetch(%{connection: :online} = state)
       when map_size(state.loads) < @max_prefetch and state.cache_bytes < state.max_cache_bytes do
    case Enum.find(state.prefetch, &(not Map.has_key?(state.loads, &1))) do
      nil ->
        state

      ref ->
        case active_headers(state) do
          {:ok, headers} -> state |> start_load(ref, [], headers) |> start_prefetch()
          {:error, _} = denied -> reset_connection(clear(state), denied)
        end
    end
  end

  defp start_prefetch(state), do: state

  defp start_entry_fetch(%{connection: :online, entry_task: nil} = state) do
    if MapSet.size(state.pending_entries) == 0 do
      state
    else
      case active_headers(state) do
        {:ok, headers} ->
          client = pinned_client(state, headers)
          ids = state.pending_entries
          task = Task.Supervisor.async_nolink(state.tasks, fn -> fetch_entries(client, ids) end)

          %{
            state
            | entry_task: %{task: task, ids: ids, apply?: true},
              pending_entries: MapSet.new()
          }

        {:error, _} = denied ->
          reset_connection(clear(state), denied)
      end
    end
  end

  defp start_entry_fetch(state), do: state

  defp fetch_entries(client, ids) do
    Enum.reduce_while(ids, {:ok, %{}}, fn id, {:ok, entries} ->
      case Client.catalog_entry(client, id) do
        {:ok, entry} -> {:cont, {:ok, Map.put(entries, id, entry)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp complete_entries(%{entry_task: %{apply?: false}} = state, _result),
    do: start_entry_fetch(%{state | entry_task: nil})

  defp complete_entries(state, {:ok, entries}) do
    updated = Map.drop(entries, MapSet.to_list(state.pending_entries))

    descriptors =
      Map.merge(
        state.descriptors,
        Map.reject(updated, fn {_id, descriptor} -> is_nil(descriptor) end)
      )

    state =
      %{state | descriptors: descriptors, entry_task: nil}
      |> enqueue_prefetch(Enum.reject(Map.values(updated), &is_nil/1))

    announce_online(state)
    state |> start_entry_fetch() |> start_prefetch()
  end

  defp complete_entries(state, {:error, %Error{code: code}} = denied)
       when code in [:unauthorized, :forbidden],
       do: reset_connection(clear(%{state | entry_task: nil}), denied)

  defp complete_entries(state, {:error, _}) do
    pending = MapSet.union(state.pending_entries, state.entry_task.ids)
    state = %{state | pending_entries: pending, entry_task: nil}
    retry(reset_connection(state, unavailable()))
  end

  defp invalidate(state, ids) do
    changed? = fn %SkillRef{skill_id: id} -> MapSet.member?(ids, id) end
    {discarded, entries} = Enum.split_with(state.entries, fn {ref, _} -> changed?.(ref) end)

    bytes =
      Enum.reduce(discarded, state.cache_bytes, fn {_ref, entry}, total ->
        total - entry.manifest.unpacked_bytes
      end)

    %{
      state
      | descriptors: Map.drop(state.descriptors, MapSet.to_list(ids)),
        pending_entries: MapSet.union(state.pending_entries, ids),
        entries: Map.new(entries),
        cache_bytes: bytes,
        loads: cancel_loads(state, unavailable(), changed?),
        prefetch: MapSet.reject(state.prefetch, changed?)
    }
  end

  defp decode(data, state) when is_binary(data) do
    case JSON.decode(data) do
      {:ok, %{"type" => "snapshot", "generation" => generation, "catalog" => catalog} = frame}
      when is_binary(generation) and byte_size(generation) in 1..128 ->
        with {:ok, %{data: descriptors, next_cursor: nil}} <-
               Wire.decode_catalog(JSON.encode!(catalog), state.source.client.source_id, "always"),
             {:ok, categories} <- decode_categories(frame, []) do
          {:snapshot, generation, descriptors, categories}
        else
          _ -> invalid_snapshot()
        end

      {:ok, %{"type" => "unchanged", "generation" => generation} = frame}
      when is_binary(generation) and generation == state.generation ->
        with {:ok, categories} <- decode_categories(frame, state.search_categories),
             do: {:unchanged, categories}

      {:ok,
       %{"type" => "search_categories", "generation" => generation, "search_categories" => _} =
           frame}
      when state.connection == :online and generation == state.generation ->
        with {:ok, categories} <- decode_categories(frame, []),
             do: {:search_categories, categories}

      {:ok,
       %{
         "type" => "changed",
         "previous_generation" => previous,
         "generation" => next,
         "skill_ids" => ids
       }}
      when is_binary(previous) and previous == state.generation and next != previous and
             is_binary(next) and byte_size(next) in 1..128 and is_list(ids) ->
        if ids != [] and length(ids) <= 10_000 and
             Enum.all?(ids, &(is_binary(&1) and byte_size(&1) in 1..256)),
           do: {:changed, next, MapSet.new(ids)},
           else: invalid_snapshot()

      {:ok, %{"type" => "heartbeat", "generation" => generation}}
      when state.connection == :online and generation == state.generation ->
        :heartbeat

      _ ->
        invalid_snapshot()
    end
  end

  defp decode(_, _state), do: invalid_snapshot()

  defp decode_categories(frame, default) do
    categories = Map.get(frame, "search_categories", default)

    if is_list(categories) and length(categories) <= 32 and
         Enum.all?(categories, &(is_binary(&1) and byte_size(&1) in 1..512)),
       do: {:ok, categories},
       else: invalid_snapshot()
  end

  defp invalid_snapshot, do: error(:invalid_request, "invalid remote skill notification")

  defp retry(state) do
    token = make_ref()
    Process.send_after(self(), {:retry, token}, state.retry_ms)
    %{state | retry: token, retry_ms: min(state.retry_ms * 2, @max_retry_ms)}
  end

  defp reset_connection(state, {:error, error} = failure) do
    close(state)
    state = pause_entry_fetch(state)
    connection = notification_failure(error.code)

    descriptors =
      if connection == :offline do
        Enum.filter(Map.values(state.descriptors), &Map.has_key?(state.entries, &1.ref))
      else
        []
      end

    categories = if connection == :offline, do: state.search_categories, else: []

    send(
      state.owner,
      {:remote_unavailable, self(), connection, state.generation, descriptors, categories, error}
    )

    %{
      state
      | socket: nil,
        retry: nil,
        connection: connection,
        loads: cancel_loads(state, failure)
    }
  end

  defp notification_failure(:temporarily_unavailable), do: :offline
  defp notification_failure(code) when code in [:unauthorized, :forbidden], do: :denied
  defp notification_failure(_), do: :error

  defp clear(state, failure \\ unavailable()) do
    %{
      state
      | generation: nil,
        descriptors: %{},
        search_categories: [],
        pending_entries: MapSet.new(),
        entry_task: discard_entry_task(state.entry_task),
        prefetch: MapSet.new(),
        entries: %{},
        cache_bytes: 0,
        loads: cancel_loads(state, failure)
    }
  end

  defp pause_entry_fetch(%{entry_task: %{apply?: true, ids: ids}} = state) do
    %{
      state
      | pending_entries: MapSet.union(state.pending_entries, ids),
        entry_task: discard_entry_task(state.entry_task)
    }
  end

  defp pause_entry_fetch(state), do: state
  defp discard_entry_task(nil), do: nil
  defp discard_entry_task(task), do: %{task | apply?: false}

  defp close(%{socket: nil}), do: :ok
  defp close(state), do: state.websocket.close(state.socket)

  defp cancel_loads(state, result, affected? \\ fn _ -> true end) do
    Map.new(state.loads, fn {ref, load} ->
      if affected?.(ref) do
        Enum.each(load.waiters, fn {from, _path} -> GenServer.reply(from, result) end)
        {ref, %{load | waiters: [], active?: false}}
      else
        {ref, load}
      end
    end)
  end

  defp complete(state, task_ref, result) do
    load = Enum.find(state.loads, fn {_ref, load} -> load.task.ref == task_ref end)

    case {load, result} do
      {{ref, %{active?: false}}, _} ->
        %{state | loads: Map.delete(state.loads, ref)}

      {{ref, _load}, {:error, %Error{code: code}} = denied}
      when code in [:unauthorized, :forbidden] ->
        state = clear(state, denied)
        reset_connection(%{state | loads: Map.delete(state.loads, ref)}, denied)

      {{ref, load}, result} ->
        {state, result} = store(state, ref, result)

        Enum.each(load.waiters, fn {from, path} ->
          reply = with {:ok, entry} <- result, do: resource(entry, path, state)
          GenServer.reply(from, reply)
        end)

        %{state | loads: Map.delete(state.loads, ref)}

      {nil, _} ->
        state
    end
  end

  defp store(state, ref, {:ok, %{manifest: manifest} = entry} = result)
       when state.cache_bytes + manifest.unpacked_bytes <= state.max_cache_bytes do
    {%{
       state
       | entries: Map.put(state.entries, ref, entry),
         cache_bytes: state.cache_bytes + manifest.unpacked_bytes
     }, result}
  end

  defp store(state, _ref, {:ok, _}),
    do: {state, error(:capacity_exceeded, "remote skill cache is full")}

  defp store(state, _ref, error), do: {state, error}

  defp resource(entry, path, state) do
    case Map.fetch(entry.files, path) do
      {:ok, content} ->
        {:ok,
         %{
           content: content,
           document: entry.document,
           manifest: entry.manifest,
           generation: state.generation,
           availability: state.connection
         }}

      :error ->
        error(:not_found, "resource is not in the verified inventory")
    end
  end

  defp exact?(
         %SkillRef{source_id: id, skill_id: skill, revision: revision, artifact_digest: digest},
         id
       ),
       do:
         is_binary(skill) and skill != "" and is_binary(revision) and revision != "" and
           is_binary(digest)

  defp exact?(_, _), do: false

  defp unavailable,
    do: error(:temporarily_unavailable, "remote skill notifications are unavailable")

  defp error(code, message), do: {:error, Error.new(code, :directory, message)}
end
