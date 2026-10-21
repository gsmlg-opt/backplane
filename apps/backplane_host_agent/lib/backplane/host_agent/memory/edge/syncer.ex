defmodule Backplane.HostAgent.Memory.Edge.Syncer do
  @moduledoc "Polls the revisioned edge-memory feed independently of socket reconnects."

  use GenServer

  alias Backplane.HostAgent.Channel
  alias Backplane.HostAgent.Memory.{Access, Mirror}
  alias Backplane.HostAgent.Memory.Mirror.Store, as: MirrorStore
  alias Backplane.HostAgent.Memory.Edge.Telemetry

  @default_poll_interval_ms 60_000
  @default_retry_backoff_ms 1_000
  @max_retry_backoff_ms 60_000
  @diagnostic_errors ~w(timeout unauthorized authority_changed stale_request invalid_protocol
    invalid_delivery invalid_offer partition_mismatch snapshot_required snapshot_restart_required
    storage_unavailable access_storage_unavailable access_owner_unavailable access_capacity
    delivery_conflict integrity_failure payload_too_large protection_unavailable disabled
    snapshot_build_unavailable transaction_conflict partition_not_ready batch_not_found invalid_ack
    revision_gap storage_failure channel_exit unexpected_reply)

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc "Returns only bounded scheduling and classified last-poll metadata."
  def diagnostics(server \\ __MODULE__) do
    GenServer.call(server, :diagnostics, 500)
  catch
    :exit, _ -> %{"status" => "unavailable"}
  end

  @doc "Resolves offline authority from the last authenticated negotiation, never the caller."
  def read_context(args, server \\ __MODULE__) do
    case GenServer.call(server, :status, 500) do
      %{selected: "host_memory.v2", inventory: partitions} = state when is_list(partitions) ->
        keys = ["memory_space_id", "scope", "namespace"]

        partitions =
          if "memory_access.v1" in state.extensions do
            default = Enum.find(partitions, &(&1["access_id"] == state.default_access_id))

            if default,
              do: Enum.filter(partitions, &(&1["memory_space_id"] == default["memory_space_id"])),
              else: []
          else
            partitions
          end

        claims = Map.take(args, keys)

        matches =
          Enum.filter(partitions, fn partition ->
            Enum.all?(claims, fn {key, value} -> partition[key] == value end)
          end)

        case matches do
          [partition] ->
            {:ok,
             %{
               edge_adapter: state.mirror_module,
               edge_partition: Map.take(partition, keys),
               edge_store: Keyword.get(state.mirror_opts, :store),
               edge_config: Keyword.get(state.mirror_opts, :config),
               edge_access:
                 if(partition["access_id"],
                   do: %{
                     access_id: partition["access_id"],
                     authority_version: partition["authority_version"],
                     partition: Map.take(partition, keys),
                     connection_generation: state.generation[:id],
                     local_mode: :private_default
                   }
                 )
             }}

          [] ->
            {:error, :partition_mismatch}

          _ ->
            {:error, :ambiguous_partition}
        end

      _ ->
        {:error, :mirror_unavailable}
    end
  catch
    :exit, _ -> {:error, :mirror_unavailable}
  end

  def set_connection(server \\ __MODULE__, connection),
    do: GenServer.cast(server, {:connection, connection})

  def memory_available(server \\ __MODULE__, hint),
    do: GenServer.cast(server, {:memory_available, hint})

  def memory_access_changed(message, server \\ __MODULE__),
    do: GenServer.cast(server, {:access_changed, message})

  def stop(server \\ __MODULE__), do: GenServer.stop(server, :normal)

  @impl true
  def init(opts) do
    state = %{
      channel: Keyword.get(opts, :channel),
      generation: Keyword.get(opts, :generation),
      extensions: Keyword.get(opts, :extensions, []),
      default_access_id: Keyword.get(opts, :default_access_id),
      access_server: Keyword.get(opts, :access_server, Access),
      channel_module: Keyword.get(opts, :channel_module, Channel),
      mirror_module: Keyword.get(opts, :mirror_module, Mirror),
      mirror_opts: Keyword.get(opts, :mirror_opts, []),
      selected: Keyword.get(opts, :selected),
      poll_interval_ms: Keyword.get(opts, :poll_interval_ms, @default_poll_interval_ms),
      retry_backoff_ms: Keyword.get(opts, :retry_backoff_ms, @default_retry_backoff_ms),
      edge_retry_ref: nil,
      edge_retry_token: nil,
      poll_ref: nil,
      poll_token: nil,
      partition_index: 0,
      inventory: Keyword.get(opts, :partitions),
      last_poll_result: "never",
      last_stage: nil,
      last_error: nil,
      current_retry_backoff_ms: Keyword.get(opts, :retry_backoff_ms, @default_retry_backoff_ms)
    }

    {:ok, schedule_poll(state, 0)}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state, state}

  def handle_call(:diagnostics, _from, state) do
    {:reply,
     %{
       "status" => "available",
       "poll_interval_ms" => state.poll_interval_ms,
       "partition_index" => state.partition_index,
       "partition_count" => if(is_list(state.inventory), do: length(state.inventory)),
       "retry_backoff_ms" => state.current_retry_backoff_ms,
       "poll_scheduled" => timer_pending?(state.poll_ref),
       "retry_scheduled" => timer_pending?(state.edge_retry_ref),
       "last_poll_result" => state.last_poll_result,
       "last_stage" => state.last_stage,
       "last_error" => state.last_error
     }, state}
  end

  @impl true
  def handle_cast(
        {:connection,
         %{channel: channel, memory: %{"selected" => selected} = memory} = connection},
        state
      ) do
    {:noreply,
     %{
       state
       | channel: channel,
         selected: selected,
         inventory: Map.get(memory, "partitions", []),
         extensions: Map.get(memory, "extensions", []),
         default_access_id: memory["default_access_id"],
         generation: connection[:memory_generation]
     }
     |> cancel_retry()
     |> schedule_poll(0)}
  end

  def handle_cast({:connection, %{channel: channel, memory: %{selected: selected}}}, state) do
    {:noreply,
     %{state | channel: channel, selected: selected} |> cancel_retry() |> schedule_poll(0)}
  end

  def handle_cast({:access_changed, %{channel: channel, hint: hint}}, %{channel: channel} = state) do
    id = hint["access_id"]

    current =
      case Access.status(state.access_server) do
        %{accesses: entries} -> Enum.find(entries, &(&1.access_id == id))
        _ -> nil
      end

    # A delayed/duplicate hint can follow the inventory that already installed
    # that version. It must neither fence it again nor refresh its read lease.
    if is_integer(hint["authority_version"]) && hint["authority_version"] > 0 &&
         (is_nil(current) or hint["authority_version"] > current.authority_version) do
      if current do
        _ =
          Access.fence(
            {:access_id, id},
            :authority_changed,
            state.generation,
            state.access_server
          )
      end

      send(self(), {:refresh_access, channel})
    end

    {:noreply, state}
  end

  def handle_cast({:access_changed, _}, state), do: {:noreply, state}

  def handle_cast({:memory_available, _hint}, state),
    do: {:noreply, state |> cancel_retry() |> schedule_poll(0)}

  @impl true
  def handle_info({:refresh_access, channel}, %{channel: channel} = state) do
    generation = %{state.generation | sent_at_ms: System.monotonic_time(:millisecond)}

    with {:ok, inventory} <- push(state, "memory_access_refresh", %{}),
         :ok <-
           Access.install_inventory(
             generation,
             Map.put(inventory, "extensions", state.extensions),
             state.access_server
           ) do
      {:noreply,
       %{
         state
         | inventory: inventory["partitions"],
           default_access_id: inventory["default_access_id"]
       }
       |> cancel_retry()
       |> schedule_poll(0)}
    else
      _ ->
        Process.send_after(self(), {:refresh_access, channel}, state.retry_backoff_ms)
        {:noreply, state}
    end
  end

  def handle_info({:refresh_access, _}, state), do: {:noreply, state}

  def handle_info(
        {:poll, token},
        %{poll_token: token, selected: "host_memory.v2", channel: channel} = state
      )
      when is_pid(channel) do
    # Keep only classified metadata while polling; operation results still reach
    # authority/fencing code unchanged. The first failure identifies its source.
    Process.delete({__MODULE__, :poll_diagnostic})
    result = poll(state)
    {stage, error} = Process.delete({__MODULE__, :poll_diagnostic}) || {nil, nil}

    case result do
      {:ok, state} ->
        {:noreply,
         schedule_poll(
           %{
             state
             | edge_retry_ref: nil,
               edge_retry_token: nil,
               last_poll_result: "ok",
               last_stage: stage,
               last_error: nil,
               current_retry_backoff_ms: state.retry_backoff_ms
           },
           state.poll_interval_ms
         )}

      {:error, reason, state, partition_count} ->
        {:noreply,
         schedule_retry(
           %{
             state
             | last_poll_result: "error",
               last_stage: stage,
               last_error: error || diagnostic_error(reason)
           },
           partition_count
         )}
    end
  end

  def handle_info({:poll, _token}, state), do: {:noreply, state}

  def handle_info({:edge_retry, token}, %{edge_retry_token: token} = state),
    do: {:noreply, %{state | edge_retry_ref: nil, edge_retry_token: nil} |> schedule_poll(0)}

  def handle_info({:edge_retry, _token}, state), do: {:noreply, state}

  defp poll(state) do
    with {:ok, offer} <- observed(state.mirror_module.offer(state.mirror_opts), :offer) do
      case observed(next_request(offer, state), :select_partition) do
        {:idle, state} ->
          {:ok, state}

        {:ok, request, state, partition_count} ->
          case poll_partition(state, request) do
            {:ok, state} -> {:ok, state}
            {:error, reason} -> {:error, reason, state, partition_count}
          end

        {:error, reason} ->
          {:error, reason, state, 0}
      end
    else
      {:error, reason} -> {:error, reason, state, 0}
    end
  end

  defp poll_partition(state, request) do
    with {:ok, delivery} <- next_delivery(state, request) do
      if Map.has_key?(request, "access") do
        shared_delivery(state, request, delivery)
      else
        case delivery do
          %{"status" => "current"} ->
            {:ok, state}

          %{"status" => "batch"} ->
            with {:ok, ack} <-
                   state.mirror_module.apply_delivery(
                     delivery,
                     Keyword.put(state.mirror_opts, :partition, request["partition"])
                   )
                   |> observed(:apply),
                 {:ok, _reply} <- observed(push(state, "memory_ack", ack), :memory_ack) do
              {:ok, state}
            end

          _ ->
            observed({:error, :invalid_delivery}, :delivery)
        end
      end
    end
  end

  defp next_delivery(state, %{"access" => access} = request) do
    with {:ok, _target, ticket} <-
           Access.begin_request({:access_id, access["access_id"]}, :deliver, state.access_server)
           |> observed(:next_admission),
         reply = observed(push(state, "memory_next", request), :memory_next),
         {:ok, target, delivery} <-
           Access.finish_request(ticket, reply, state.access_server) |> observed(:next_authority) do
      {:ok, Map.put(delivery, :access_target, target)}
    end
  end

  defp next_delivery(state, request),
    do: observed(push(state, "memory_next", request), :memory_next)

  defp shared_delivery(state, request, delivery) do
    target = delivery[:access_target]
    delivery = Map.delete(delivery, :access_target)

    case delivery do
      %{"status" => "current"} ->
        with {:ok, _} <-
               Access.run_local(
                 target,
                 :deliver,
                 fn current ->
                   if MirrorStore.complete?(current.edge_store, current),
                     do: {:ok, :current},
                     else: {:error, :snapshot_required}
                 end,
                 state.access_server
               )
               |> observed(:current_mirror),
             do: {:ok, state}

      %{"status" => "batch"} ->
        with {:ok, ack} <-
               Access.run_local(
                 target,
                 :deliver,
                 fn _ ->
                   state.mirror_module.apply_delivery(
                     delivery,
                     Keyword.put(state.mirror_opts, :partition, request["partition"])
                   )
                 end,
                 state.access_server
               )
               |> observed(:apply),
             {:ok, _, ticket} <-
               Access.begin_request({:access_id, target.access_id}, :deliver, state.access_server)
               |> observed(:ack_admission),
             reply = observed(push(state, "memory_ack", ack), :memory_ack),
             reply = observed(validate_ack_reply(reply, ack), :ack_binding),
             {:ok, permitted, _} <-
               Access.finish_request(ticket, reply, state.access_server)
               |> observed(:ack_authority),
             {:ok, _} <-
               Access.run_local(
                 permitted,
                 :deliver,
                 fn _ -> {:ok, :acknowledged} end,
                 state.access_server
               )
               |> observed(:ack_commit) do
          {:ok, state}
        end

      _ ->
        observed({:error, :invalid_delivery}, :delivery)
    end
  end

  defp validate_ack_reply({:ok, reply}, ack) do
    keys = ~w(access partition batch_id snapshot_id chunk_hash integrity_hash)
    bound = Enum.all?(keys, &(reply[&1] == ack[&1]))

    valid =
      case reply["status"] do
        "duplicate" ->
          is_integer(reply["applied_revision"]) and
            reply["applied_revision"] >= ack["applied_revision"]

        "advanced" ->
          ack["status"] == "applied" and
            reply["applied_revision"] == ack["applied_revision"] and
            is_nil(reply["next_chunk_index"])

        "progress" ->
          ack["status"] == "progress" and
            reply["applied_revision"] == ack["applied_revision"] and
            is_integer(reply["next_chunk_index"]) and reply["next_chunk_index"] > 0 and
            reply["next_chunk_index"] == ack["next_chunk_index"]

        _ ->
          false
      end

    if bound and valid, do: {:ok, reply}, else: {:error, :invalid_protocol}
  end

  defp validate_ack_reply(error, _), do: error

  defp observed(result, stage) do
    case Process.get({__MODULE__, :poll_diagnostic}) do
      {_, error} when not is_nil(error) ->
        :ok

      _ ->
        error =
          case result do
            {:error, reason} -> diagnostic_error(reason)
            _ -> nil
          end

        Process.put({__MODULE__, :poll_diagnostic}, {Atom.to_string(stage), error})
    end

    result
  end

  defp diagnostic_error(%{"code" => code}), do: diagnostic_error(code)
  defp diagnostic_error({code, _detail}), do: diagnostic_error(code)
  defp diagnostic_error(code) when is_atom(code), do: diagnostic_error(Atom.to_string(code))
  defp diagnostic_error(code) when code in @diagnostic_errors, do: code
  defp diagnostic_error(_), do: "unknown"

  defp timer_pending?(ref) when is_reference(ref), do: Process.read_timer(ref) != false
  defp timer_pending?(_), do: false

  defp next_request(%{"partitions" => durable} = offer, state) when is_list(durable) do
    partitions = merged_partitions(state.inventory, durable)

    case next_partition(partitions, state.partition_index) do
      nil ->
        {:idle, state}

      partition ->
        request =
          %{
            "protocol" => "host_memory.v2",
            "partition" => Map.take(partition, ["memory_space_id", "scope", "namespace"]),
            "applied_revision" => partition["applied_revision"]
          }
          |> maybe_put_limits(offer)
          |> maybe_put_snapshot(partition["snapshot"])
          |> maybe_put(
            "access",
            if(partition["access_id"],
              do: Map.take(partition, ["access_id", "authority_version"])
            )
          )

        {:ok, request, %{state | partition_index: state.partition_index + 1}, length(partitions)}
    end
  end

  defp next_request(_, _state), do: {:error, :invalid_offer}

  defp merged_partitions(inventory, durable) when is_list(inventory) and is_list(durable) do
    durable_by_partition = Map.new(durable, &{partition_key(&1), &1})

    Enum.map(inventory, fn negotiated ->
      saved = Map.get(durable_by_partition, partition_key(negotiated), %{})

      if negotiated["access_id"] &&
           (saved["access_id"] != negotiated["access_id"] or
              saved["authority_version"] != negotiated["authority_version"]) do
        Map.merge(negotiated, %{"applied_revision" => 0, "snapshot" => nil})
      else
        Map.merge(negotiated, Map.take(saved, ["applied_revision", "status", "snapshot"]))
      end
    end)
  end

  defp merged_partitions(nil, durable), do: durable
  defp merged_partitions(_inventory, durable), do: durable

  defp partition_key(partition),
    do: Map.take(partition, ["memory_space_id", "scope", "namespace"])

  defp next_partition(partitions, index) do
    Enum.at(partitions, rem(index, max(length(partitions), 1)))
  end

  defp maybe_put_limits(request, offer) do
    request
    |> maybe_put("max_changes", offer["max_changes"])
    |> maybe_put("max_frame_bytes", offer["max_frame_bytes"])
  end

  defp maybe_put_snapshot(request, %{"snapshot_id" => snapshot_id, "next_chunk_index" => index})
       when is_binary(snapshot_id) and is_integer(index),
       do: request |> Map.put("snapshot_id", snapshot_id) |> Map.put("next_chunk_index", index)

  defp maybe_put_snapshot(request, _snapshot), do: request
  defp maybe_put(request, _key, nil), do: request
  defp maybe_put(request, key, value), do: Map.put(request, key, value)

  defp push(state, event, payload) do
    case state.channel_module.push(state.channel, event, payload, 5_000) do
      {:ok, reply} when is_map(reply) ->
        {:ok, reply}

      {:error, _reason} = error ->
        Telemetry.failure(:transport)
        error

      other ->
        {:error, {:unexpected_reply, other}}
    end
  catch
    :exit, reason ->
      Telemetry.failure(:transport)
      {:error, {:channel_exit, reason}}
  end

  defp schedule_retry(%{edge_retry_ref: ref} = state, _partition_count) when is_reference(ref),
    do: state

  defp schedule_retry(state, partition_count) do
    backoff = min(state.current_retry_backoff_ms, @max_retry_backoff_ms)
    # A failed partition must not delay other grants beyond the poll cadence.
    # Multiple failing partitions consequently retry more often than full backoff.
    delay = if partition_count > 1, do: min(backoff, state.poll_interval_ms), else: backoff
    token = make_ref()

    %{
      state
      | edge_retry_ref: Process.send_after(self(), {:edge_retry, token}, delay),
        edge_retry_token: token,
        current_retry_backoff_ms: min(backoff * 2, @max_retry_backoff_ms)
    }
  end

  defp schedule_poll(state, delay) do
    cancel_timer(state.poll_ref)
    token = make_ref()
    %{state | poll_ref: Process.send_after(self(), {:poll, token}, delay), poll_token: token}
  end

  defp cancel_retry(state) do
    cancel_timer(state.edge_retry_ref)
    %{state | edge_retry_ref: nil, edge_retry_token: nil}
  end

  defp cancel_timer(ref) when is_reference(ref), do: Process.cancel_timer(ref)
  defp cancel_timer(_ref), do: false
end
