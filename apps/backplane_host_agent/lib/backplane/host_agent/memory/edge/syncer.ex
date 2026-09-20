defmodule Backplane.HostAgent.Memory.Edge.Syncer do
  @moduledoc "Polls the revisioned edge-memory feed independently of socket reconnects."

  use GenServer

  alias Backplane.HostAgent.Channel
  alias Backplane.HostAgent.Memory.Mirror

  @default_poll_interval_ms 60_000
  @default_retry_backoff_ms 1_000
  @max_retry_backoff_ms 60_000

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  def set_connection(server \\ __MODULE__, connection),
    do: GenServer.cast(server, {:connection, connection})

  def memory_available(server \\ __MODULE__, hint),
    do: GenServer.cast(server, {:memory_available, hint})

  @impl true
  def init(opts) do
    state = %{
      channel: Keyword.get(opts, :channel),
      channel_module: Keyword.get(opts, :channel_module, Channel),
      mirror_module: Keyword.get(opts, :mirror_module, Mirror),
      mirror_opts: Keyword.get(opts, :mirror_opts, []),
      selected: Keyword.get(opts, :selected),
      poll_interval_ms: Keyword.get(opts, :poll_interval_ms, @default_poll_interval_ms),
      retry_backoff_ms: Keyword.get(opts, :retry_backoff_ms, @default_retry_backoff_ms),
      edge_retry_ref: nil,
      poll_ref: nil,
      partition_index: 0
    }

    {:ok, schedule_poll(state, 0)}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state, state}

  @impl true
  def handle_cast({:connection, %{channel: channel, memory: %{"selected" => selected}}}, state) do
    {:noreply, %{state | channel: channel, selected: selected} |> schedule_poll(0)}
  end

  def handle_cast({:connection, %{channel: channel, memory: %{selected: selected}}}, state) do
    {:noreply, %{state | channel: channel, selected: selected} |> schedule_poll(0)}
  end

  def handle_cast({:memory_available, _hint}, state), do: {:noreply, schedule_poll(state, 0)}

  @impl true
  def handle_info(:poll, %{selected: "host_memory.v2", channel: channel} = state)
      when is_pid(channel) do
    case poll(state) do
      {:ok, state} ->
        {:noreply, schedule_poll(%{state | edge_retry_ref: nil}, state.poll_interval_ms)}

      {:error, _reason} ->
        {:noreply, schedule_retry(state)}
    end
  end

  def handle_info(:poll, state), do: {:noreply, state}

  def handle_info(:edge_retry, state),
    do: {:noreply, %{state | edge_retry_ref: nil} |> schedule_poll(0)}

  defp poll(state) do
    with {:ok, offer} <- state.mirror_module.offer(state.mirror_opts),
         {:ok, request, state} <- next_request(offer, state),
         {:ok, delivery} <- push(state, "memory_next", request) do
      case delivery do
        %{"status" => "current"} ->
          {:ok, state}

        %{"status" => "batch"} ->
          with {:ok, ack} <- state.mirror_module.apply_delivery(delivery, state.mirror_opts),
               {:ok, _reply} <- push(state, "memory_ack", ack) do
            {:ok, state}
          end

        _ ->
          {:error, :invalid_delivery}
      end
    end
  end

  defp next_request(%{"partitions" => partitions} = offer, state) when is_list(partitions) do
    case next_partition(partitions, state.partition_index) do
      nil ->
        {:error, :no_partitions}

      partition ->
        request =
          %{
            "protocol" => "host_memory.v2",
            "partition" => Map.take(partition, ["memory_space_id", "scope", "namespace"]),
            "applied_revision" => partition["applied_revision"]
          }
          |> maybe_put_limits(offer)
          |> maybe_put_snapshot(partition["snapshot"])

        {:ok, request, %{state | partition_index: state.partition_index + 1}}
    end
  end

  defp next_request(_, _state), do: {:error, :invalid_offer}

  defp next_partition(partitions, index) do
    Enum.find(partitions, fn partition ->
      is_map(partition) and is_map(partition["snapshot"])
    end) ||
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
      {:ok, reply} when is_map(reply) -> {:ok, reply}
      {:error, _reason} = error -> error
      other -> {:error, {:unexpected_reply, other}}
    end
  end

  defp schedule_retry(%{edge_retry_ref: ref} = state) when is_reference(ref), do: state

  defp schedule_retry(state) do
    delay = min(state.retry_backoff_ms, @max_retry_backoff_ms)
    %{state | edge_retry_ref: Process.send_after(self(), :edge_retry, delay)}
  end

  defp schedule_poll(state, delay) do
    cancel_timer(state.poll_ref)
    %{state | poll_ref: Process.send_after(self(), :poll, delay)}
  end

  defp cancel_timer(ref) when is_reference(ref), do: Process.cancel_timer(ref)
  defp cancel_timer(_ref), do: false
end
