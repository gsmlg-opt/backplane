defmodule Backplane.HostAgent.Memory.Access do
  @moduledoc "Serializes host shared authority, durable fences, and bounded local store work."
  use GenServer

  alias Backplane.HostAgent.Memory.{Store, RecallCache}
  alias Backplane.HostAgent.Memory.Mirror.Store, as: MirrorStore
  alias Turso.Result

  @caps ~w(read deliver remember forget)
  @permanent ~w(unauthorized authority_changed partition_mismatch invalid_protocol protocol_mismatch)
  @partition_keys ~w(memory_space_id scope namespace)
  @max_tickets 256

  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  def install_inventory(generation, inventory, server \\ __MODULE__),
    do: call(server, {:inventory, generation, inventory})

  def fence(selector, reason, generation, server \\ __MODULE__),
    do: call(server, {:fence, selector, reason, generation})

  def begin_request(selector, operation, server \\ __MODULE__),
    do: call(server, {:begin, selector, operation})

  def finish_request(ticket, reply, server \\ __MODULE__),
    do: call(server, {:finish, ticket, reply})

  def run_local(target, operation, fun, server \\ __MODULE__) when is_function(fun, 1),
    do: call(server, {:local, target, operation, fun})

  def status(server \\ __MODULE__), do: call(server, :status)

  # A cached target is never sufficient to call a shared store outside this process.
  def local_owner?(%{owner: owner}),
    do: owner == self() and Process.get({__MODULE__, :local}) == true

  def local_owner?(_), do: false

  defp call(server, message) do
    GenServer.call(server, message, 10_000)
  catch
    :exit, _ -> {:error, :access_owner_unavailable}
  end

  @impl true
  def init(opts) do
    store = Keyword.fetch!(opts, :store)

    with {:ok, %Result{rows: rows}} <- Store.query(store, "SELECT * FROM memory_access_state"),
         {:ok, %Result{rows: [global]}} <-
           Store.query(store, "SELECT fenced FROM memory_access_global WHERE id=1") do
      entries =
        Map.new(rows, fn row ->
          {row["access_id"],
           %{
             access_id: row["access_id"],
             partition: Jason.decode!(row["partition"]),
             authority_version: row["authority_version"],
             status: row["status"],
             capabilities: Jason.decode!(row["capabilities"]),
             offline_read_lease_seconds: row["lease_seconds"],
             fence_reason: row["fence_reason"],
             deadline: nil
           }}
        end)

      {:ok,
       %{
         store: store,
         edge_store: Keyword.get(opts, :edge_store, Backplane.HostAgent.Memory.Edge.Store),
         edge_config: Keyword.get(opts, :edge_config, %{}),
         recall_cache: Keyword.get(opts, :recall_cache, RecallCache),
         now_fun: Keyword.get(opts, :now_fun, fn -> System.monotonic_time(:millisecond) end),
         entries: entries,
         channel: nil,
         generation: nil,
         inventory_sent_at: nil,
         extensions: [],
         default_access_id: nil,
         negotiated: false,
         blocked: false,
         global_fenced: global["fenced"] == 1,
         tickets: %{},
         permits: %{}
       }}
    else
      {:error, reason} -> {:stop, {:access_storage_unavailable, reason}}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    safe =
      Map.take(state, [:negotiated, :blocked, :generation, :default_access_id, :global_fenced])

    {:reply, Map.put(safe, :accesses, Map.values(state.entries)), state}
  end

  def handle_call({:inventory, generation, inventory}, _from, state) do
    with {:ok, id, sent_at} <- generation(generation, state),
         :ok <- inventory_order(state, id, sent_at),
         {:ok, entries, extensions, default} <- validate_inventory(inventory),
         false <- state.blocked do
      newer_connection = state.generation != id
      allowed_global = not state.global_fenced or newer_connection

      if allowed_global do
        install(state, entries, extensions, default, id, sent_at, Map.get(generation, :channel))
      else
        {:reply, {:error, :unauthorized}, state}
      end
    else
      {:error, :stale_connection} ->
        {:reply, {:error, :stale_connection}, state}

      _ ->
        {result, state} = persist_fence(state, :all, :invalid_protocol)
        {:reply, if(result == :ok, do: {:error, :invalid_inventory}, else: result), state}
    end
  end

  def handle_call({:fence, selector, reason, generation}, _from, state) do
    if generation_id(generation) == state.generation do
      {result, state} = persist_fence(state, selector, reason)
      {:reply, result, state}
    else
      {:reply, {:error, :stale_connection}, state}
    end
  end

  def handle_call({:begin, selector, operation}, _from, state) do
    with {:ok, entry} <- admit(state, selector, operation),
         true <- map_size(state.tickets) < @max_tickets do
      ticket = %{
        id: make_ref(),
        access_id: entry.access_id,
        authority_version: entry.authority_version,
        partition: entry.partition,
        operation: operation,
        generation: state.generation,
        sent_at_ms: now(state)
      }

      target = target(state, entry)

      {:reply, {:ok, target, ticket},
       %{state | tickets: Map.put(state.tickets, ticket.id, ticket)}}
    else
      false -> {:reply, {:error, :access_capacity}, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:finish, ticket, reply}, _from, state) do
    with %{id: ref} <- ticket,
         ^ticket <- state.tickets[ref] do
      state = %{state | tickets: Map.delete(state.tickets, ref)}
      finish(state, ticket, reply)
    else
      _ -> {:reply, {:error, :stale_request}, state}
    end
  end

  def handle_call({:local, :all, operation, fun}, _from, state)
      when operation in [:drain, :settle, :diagnostics] do
    if state.blocked or (operation == :drain and (not state.negotiated or state.global_fenced)) do
      {:reply, {:error, :unauthorized}, state}
    else
      context = %{
        owner: self(),
        store: state.store,
        edge_store: state.edge_store,
        edge_config: state.edge_config,
        accesses: state.entries,
        generation: state.generation,
        channel: state.channel,
        extensions: state.extensions,
        negotiated: state.negotiated,
        global_fenced: state.global_fenced,
        now_ms: now(state)
      }

      result = invoke_local(fun, context)
      {result, state} = apply_settlement_fences(result, state)
      {:reply, result, state}
    end
  end

  def handle_call({:local, target, operation, fun}, _from, state) do
    with {:ok, entry} <- current_target(state, target, operation),
         :ok <- local_admission(state, target, entry, operation) do
      result =
        invoke_local(
          fun,
          Map.merge(target(state, entry), Map.take(target, [:permit, :local_mode]))
        )

      # Deadline is checked again after composition; a long read cannot cross expiry.
      result =
        case local_admission(state, target, entry, operation) do
          :ok -> result
          error -> error
        end

      state = %{state | permits: Map.delete(state.permits, Map.get(target, :permit))}

      state =
        if operation == :deliver and match?({:ok, _}, result),
          do: activate_if_complete(state, entry),
          else: state

      {:reply, result, state}
    else
      error -> {:reply, error, state}
    end
  end

  defp install(state, offered, extensions, default, id, sent_at, channel) do
    entries =
      Map.new(offered, fn entry ->
        prior = state.entries[entry.access_id]

        same =
          not is_nil(prior) and prior.authority_version == entry.authority_version and
            prior.partition == entry.partition

        stale = not is_nil(prior) and entry.authority_version < prior.authority_version
        fresh_connection = state.generation != id

        fenced =
          same and prior.status == "fenced" and
            (prior.fence_reason not in ["connection_rejected", "credential_policy"] or
               not fresh_connection)

        changed_capabilities = same and prior.capabilities != entry.capabilities

        changed_lease =
          same and prior.offline_read_lease_seconds != entry.offline_read_lease_seconds

        cond do
          stale or (changed_lease and not changed_capabilities) ->
            {entry.access_id,
             Map.merge(prior, %{
               status: "fenced",
               deadline: nil,
               fence_reason: "authority_changed"
             })}

          fenced ->
            {entry.access_id, prior}

          changed_capabilities and not fresh_connection ->
            {entry.access_id,
             Map.merge(prior, %{
               status: "fenced",
               deadline: nil,
               fence_reason: "credential_policy"
             })}

          true ->
            status =
              if same and prior.status == "active" and not changed_capabilities,
                do: "active",
                else: "needs_sync"

            status = if entry.status == "revoked", do: "fenced", else: status

            {entry.access_id,
             Map.merge(entry, %{
               status: status,
               deadline: lease_deadline(entry, sent_at),
               fence_reason: if(status == "fenced", do: "unauthorized")
             })}
        end
      end)

    entries =
      Enum.reduce(state.entries, entries, fn {access_id, old}, acc ->
        Map.put_new(
          acc,
          access_id,
          Map.merge(old, %{status: "fenced", deadline: nil, fence_reason: "unauthorized"})
        )
      end)

    next = %{
      state
      | entries: entries,
        generation: id,
        channel: channel,
        inventory_sent_at: sent_at,
        extensions: extensions,
        default_access_id: default,
        negotiated: true,
        global_fenced: false,
        tickets: %{},
        permits: %{}
    }

    result =
      Store.transaction(state.store, fn conn ->
        Enum.each(entries, fn {_id, entry} ->
          persist_entry!(conn, entry)
          reject_old_commands!(conn, entry)
        end)

        execute!(
          conn,
          "UPDATE memory_access_global SET fenced=0, reason=NULL, updated_at=? WHERE id=1",
          [timestamp()]
        )
      end)

    case result do
      {:ok, _} ->
        Enum.each(entries, fn {access_id, entry} ->
          old = state.entries[access_id]

          if entry.status == "fenced" or
               (not is_nil(old) and
                  (old.authority_version != entry.authority_version or
                     old.capabilities != entry.capabilities)),
             do: hide_mirror(next, entry)
        end)

        {:reply, :ok, next}

      {:error, _} ->
        {:reply, {:error, :access_storage_unavailable}, %{next | blocked: true}}
    end
  end

  defp finish(state, ticket, {:error, reason}) do
    if ticket.generation != state.generation do
      {:reply, {:error, :stale_request}, state}
    else
      cond do
        credential_rejection?(reason) ->
          Backplane.HostAgent.MemoryProxy.retain_credential_rejection(
            reason,
            state.channel,
            state.generation
          )

          {_result, state} = persist_fence(state, :all, :connection_rejected)
          {:reply, {:error, reason}, state}

        permanent?(reason) ->
          {_result, state} =
            persist_fence(state, {:access_id, ticket.access_id}, error_code(reason))

          {:reply, {:error, reason}, state}

        true ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  defp finish(state, ticket, {:ok, reply}) when is_map(reply) do
    selector = {:access_id, ticket.access_id}

    with {:ok, entry} <- admit(state, selector, ticket.operation),
         true <-
           ticket.generation == state.generation and
             ticket.authority_version == entry.authority_version,
         true <- reply["access"] == claim(entry) and reply["partition"] == entry.partition,
         true <- byte_size(Jason.encode!(reply)) <= 524_288,
         :ok <- validate_reply(reply, entry, state),
         true <-
           is_map(reply["result"]) or
             reply["status"] in ["batch", "current", "advanced", "progress", "duplicate"] do
      entry =
        if ticket.operation in [:remember, :forget] or
             reply["status"] in ["advanced", "progress", "duplicate"],
           do: entry,
           else: %{entry | deadline: lease_deadline(entry, ticket.sent_at_ms)}

      permit = make_ref()
      next_target = target(state, entry) |> Map.merge(%{permit: permit, local_mode: :online})

      state = %{
        state
        | entries: Map.put(state.entries, entry.access_id, entry),
          permits:
            Map.put(
              state.permits,
              permit,
              {entry.access_id, entry.authority_version, state.generation}
            )
      }

      {:reply, {:ok, next_target, Map.get(reply, "result", reply)}, state}
    else
      _ ->
        # A stale old connection cannot fence or reactivate the current generation.
        if ticket.generation != state.generation do
          {:reply, {:error, :stale_request}, state}
        else
          {_result, state} = persist_fence(state, selector, :authority_changed)
          {:reply, {:error, :authority_changed}, state}
        end
    end
  end

  defp finish(state, ticket, _), do: finish(state, ticket, {:error, :invalid_protocol})

  defp validate_reply(%{"status" => "batch"} = reply, entry, state),
    do:
      Backplane.HostAgent.Memory.Mirror.validate_delivery(reply,
        partition: entry.partition,
        config: state.edge_config
      )

  defp validate_reply(_reply, _entry, _state), do: :ok

  defp admit(state, selector, operation) do
    id =
      case selector do
        {:access_id, id} -> id
        :default -> state.default_access_id
        _ -> nil
      end

    entry = state.entries[id]

    cond do
      state.blocked ->
        {:error, :access_storage_unavailable}

      not state.negotiated or state.global_fenced ->
        {:error, :unauthorized}

      is_nil(entry) or entry.status == "fenced" ->
        {:error, :unauthorized}

      operation not in [:read, :deliver, :remember, :forget] ->
        {:error, :invalid_request}

      to_string(operation) not in entry.capabilities ->
        {:error, :unauthorized}

      operation in [:remember, :forget] and "memory_commands.v2" not in state.extensions ->
        {:error, :unsupported_shared_commands}

      true ->
        {:ok, entry}
    end
  end

  defp current_target(state, target, operation) when is_map(target) do
    with {:ok, entry} <- admit(state, {:access_id, target[:access_id]}, operation),
         true <-
           entry.authority_version == target[:authority_version] and
             entry.partition == target[:partition] and
             state.generation == target[:connection_generation] do
      {:ok, entry}
    else
      false -> {:error, :authority_changed}
      error -> error
    end
  end

  defp current_target(_, _, _), do: {:error, :invalid_request}

  defp local_admission(state, %{local_mode: :online, permit: permit}, entry, _operation) do
    if state.permits[permit] == {entry.access_id, entry.authority_version, state.generation},
      do: :ok,
      else: {:error, :stale_request}
  end

  defp local_admission(state, %{local_mode: :private_default}, entry, :read) do
    default = state.entries[state.default_access_id]

    if default && default.status != "fenced" &&
         default.partition["memory_space_id"] == entry.partition["memory_space_id"] &&
         entry.status == "active" && "deliver" in entry.capabilities,
       do: :ok,
       else: {:error, :unauthorized}
  end

  defp local_admission(state, _target, entry, :read) do
    cond do
      "deliver" not in entry.capabilities or entry.status != "active" ->
        {:error, :no_committed_mirror}

      is_nil(entry.deadline) or now(state) >= entry.deadline ->
        {:error, :access_lease_expired}

      true ->
        :ok
    end
  end

  defp local_admission(_state, _target, _entry, operation) when operation in [:remember, :forget],
    do: :ok

  defp local_admission(_, _, _, _), do: {:error, :stale_request}

  defp target(state, entry),
    do:
      Map.merge(entry, %{
        owner: self(),
        store: state.store,
        edge_store: state.edge_store,
        edge_config: state.edge_config,
        connection_generation: state.generation
      })

  def claim(target),
    do: %{"access_id" => target.access_id, "authority_version" => target.authority_version}

  defp persist_fence(state, selector, reason) do
    id =
      case selector do
        {:access_id, id} -> id
        id when is_binary(id) -> id
        _ -> nil
      end

    entries =
      Map.new(state.entries, fn {key, entry} ->
        if (selector == :all or key == id) and
             not (selector == :all and entry.status == "fenced" and
                    entry.fence_reason != "connection_rejected"),
           do:
             {key,
              Map.merge(entry, %{
                status: "fenced",
                deadline: nil,
                fence_reason:
                  if(selector == :all, do: "connection_rejected", else: error_code(reason))
              })},
           else: {key, entry}
      end)

    next = %{
      state
      | entries: entries,
        global_fenced: state.global_fenced or selector == :all,
        tickets: %{},
        permits: %{}
    }

    result =
      Store.transaction(state.store, fn conn ->
        Enum.each(entries, fn {key, entry} ->
          if selector == :all or key == id do
            persist_entry!(conn, entry)
            reject_old_commands!(conn, entry)
          end
        end)

        if selector == :all,
          do:
            execute!(
              conn,
              "UPDATE memory_access_global SET fenced=1, reason=?, updated_at=? WHERE id=1",
              [error_code(reason), timestamp()]
            )
      end)

    case result do
      {:ok, _} ->
        Enum.each(entries, fn {key, entry} ->
          if selector == :all or key == id, do: hide_mirror(next, entry)
        end)

        if selector == :all, do: clear_recall_cache(state.recall_cache)
        {:ok, next}

      {:error, _} ->
        {{:error, :access_storage_unavailable}, %{next | blocked: true}}
    end
  end

  defp persist_entry!(conn, entry) do
    execute!(
      conn,
      """
      INSERT INTO memory_access_state(access_id,partition,authority_version,status,capabilities,lease_seconds,fence_reason,updated_at)
      VALUES (?,?,?,?,?,?,?,?) ON CONFLICT(access_id) DO UPDATE SET partition=excluded.partition,authority_version=excluded.authority_version,
      status=excluded.status,capabilities=excluded.capabilities,lease_seconds=excluded.lease_seconds,fence_reason=excluded.fence_reason,updated_at=excluded.updated_at
      """,
      [
        entry.access_id,
        Jason.encode!(entry.partition),
        entry.authority_version,
        entry.status,
        Jason.encode!(entry.capabilities),
        entry.offline_read_lease_seconds,
        entry.fence_reason,
        timestamp()
      ]
    )
  end

  defp reject_old_commands!(conn, entry) do
    execute!(
      conn,
      """
      UPDATE memory_outbox SET state='dead_letter', last_error='authority_changed', dead_lettered_at=?, next_attempt_at=NULL, updated_at=?
      WHERE access_id=? AND state IN ('pending','retry_wait') AND (authority_version != ? OR ?='fenced'
        OR op NOT IN (SELECT value FROM json_each(?)))
      """,
      [
        timestamp(),
        timestamp(),
        entry.access_id,
        entry.authority_version,
        entry.status,
        Jason.encode!(entry.capabilities)
      ]
    )
  end

  defp hide_mirror(state, entry) do
    try do
      MirrorStore.fence(state.edge_store, entry)
    catch
      :exit, _ -> :ok
    end
  rescue
    _ -> :ok
  end

  defp activate_if_complete(state, entry) do
    if MirrorStore.complete?(state.edge_store, entry) do
      active = %{entry | status: "active"}

      case Store.transaction(state.store, &persist_entry!(&1, active)) do
        {:ok, _} -> %{state | entries: Map.put(state.entries, entry.access_id, active)}
        _ -> %{state | blocked: true}
      end
    else
      state
    end
  catch
    :exit, _ -> state
  end

  defp apply_settlement_fences({:ok, %{fences: ids} = result}, state) do
    state =
      Enum.reduce(ids, state, fn {id, version}, acc ->
        case acc.entries[id] do
          %{authority_version: ^version} ->
            elem(persist_fence(acc, {:access_id, id}, :unauthorized), 1)

          _ ->
            acc
        end
      end)

    {{:ok, Map.delete(result, :fences)}, state}
  end

  defp apply_settlement_fences(result, state), do: {result, state}

  defp invoke_local(fun, target) do
    Process.put({__MODULE__, :local}, true)
    Process.put({__MODULE__, :target}, target)
    fun.(target)
  rescue
    _ -> {:error, :access_storage_unavailable}
  catch
    :exit, _ -> {:error, :access_storage_unavailable}
  after
    Process.delete({__MODULE__, :local})
    Process.delete({__MODULE__, :target})
  end

  defp validate_inventory(%{"accesses" => rows, "extensions" => extensions} = inventory)
       when is_list(rows) and is_list(extensions) and length(rows) <= 1000 do
    with true <- "memory_access.v1" in extensions,
         true <- byte_size(Jason.encode!(inventory)) <= 524_288,
         true <- Enum.all?(rows, &valid_entry?/1),
         true <- length(Enum.uniq_by(rows, & &1["access_id"])) == length(rows),
         default = inventory["default_access_id"],
         true <- is_nil(default) or Enum.any?(rows, &(&1["access_id"] == default)) do
      {:ok,
       Enum.map(rows, fn row ->
         %{
           access_id: row["access_id"],
           authority_version: row["authority_version"],
           partition: row["partition"],
           status: row["status"],
           capabilities: row["capabilities"],
           offline_read_lease_seconds: row["offline_read_lease_seconds"],
           fence_reason: nil,
           deadline: nil
         }
       end), extensions, default}
    else
      _ -> {:error, :invalid_inventory}
    end
  end

  defp validate_inventory(_), do: {:error, :invalid_inventory}

  defp valid_entry?(row) when is_map(row) do
    caps = row["capabilities"]
    p = row["partition"]

    uuid?(row["access_id"]) and is_integer(row["authority_version"]) and
      row["authority_version"] > 0 and
      row["status"] in ["active", "revoked"] and is_map(p) and
      Enum.sort(Map.keys(p)) == Enum.sort(@partition_keys) and
      uuid?(p["memory_space_id"]) and
      Enum.all?(Map.values(p), &(is_binary(&1) and byte_size(&1) in 1..1024)) and
      is_list(caps) and length(caps) == length(Enum.uniq(caps)) and
      Enum.all?(caps, &(&1 in @caps)) and
      ("deliver" not in caps or "read" in caps) and is_integer(row["offline_read_lease_seconds"]) and
      row["offline_read_lease_seconds"] in 0..300 and
      (row["offline_read_lease_seconds"] == 0 or ("read" in caps and "deliver" in caps))
  end

  defp valid_entry?(_), do: false

  defp uuid?(value),
    do:
      is_binary(value) and
        Regex.match?(
          ~r/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/,
          value
        )

  defp generation(%{id: id, sent_at_ms: sent}, state) when is_integer(id) and is_integer(sent) do
    if sent <= now(state), do: {:ok, id, sent}, else: {:error, :invalid_inventory}
  end

  defp generation(_, _), do: {:error, :invalid_inventory}
  defp generation_id(%{id: id}), do: id
  defp generation_id(id), do: id
  defp inventory_order(%{generation: nil}, _, _), do: :ok

  defp inventory_order(state, id, sent) do
    if id < state.generation or (id == state.generation and sent < state.inventory_sent_at),
      do: {:error, :stale_connection},
      else: :ok
  end

  defp lease_deadline(%{offline_read_lease_seconds: 0}, _), do: nil
  defp lease_deadline(entry, sent), do: sent + entry.offline_read_lease_seconds * 1000
  defp now(state), do: state.now_fun.()
  defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp permanent?(reason),
    do:
      not Backplane.HostAgent.MemoryFacade.transport_error?(reason) and
        error_code(reason) in @permanent

  defp credential_rejection?(%{"code" => "unauthorized", "retryable" => false}), do: true
  defp credential_rejection?(_), do: false
  defp error_code(%{"code" => code}), do: error_code(code)
  defp error_code(%{"reason" => reason}), do: error_code(reason)
  defp error_code(%{reason: reason}), do: error_code(reason)
  defp error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code(reason) when is_binary(reason), do: String.slice(reason, 0, 64)
  defp error_code(_), do: "unauthorized"

  defp clear_recall_cache(cache) do
    if GenServer.whereis(cache), do: RecallCache.clear(cache), else: :ok
  catch
    :exit, _ -> :ok
  end

  defp execute!(conn, sql, params) do
    case Store.execute(conn, sql, params) do
      {:ok, result} -> result
      {:error, _} -> DBConnection.rollback(conn, :access_storage_unavailable)
    end
  end
end
