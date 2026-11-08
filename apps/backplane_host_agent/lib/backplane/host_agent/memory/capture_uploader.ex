defmodule Backplane.HostAgent.Memory.CaptureUploader do
  @moduledoc "Drains canonical capture events to the host channel with partial acknowledgements."

  use GenServer

  alias Backplane.HostAgent.{Channel, MemoryProxy, Telemetry}
  alias Backplane.HostAgent.Memory.Spool.Turso, as: Spool

  @protocol "host_events.v1"
  @event "memory_events"
  @default_max_events 100
  @default_max_bytes 512 * 1024

  def child_spec(opts) do
    %{id: Keyword.get(opts, :id, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @impl true
  def init(opts) do
    state = %{
      spool: Keyword.fetch!(opts, :spool),
      spool_module: Keyword.get(opts, :spool_module, Spool),
      channel_provider: Keyword.get(opts, :channel_provider, MemoryProxy),
      channel_module: Keyword.get(opts, :channel_module, Channel),
      host_id: Keyword.fetch!(opts, :host_id),
      max_events: Keyword.get(opts, :max_events, @default_max_events),
      max_bytes: Keyword.get(opts, :max_bytes, @default_max_bytes),
      interval_ms: Keyword.get(opts, :interval_ms, 5_000),
      connection_state: :disconnected,
      upload_latency_ms: nil,
      ack_latency_ms: nil
    }

    {:ok, schedule(state)}
  end

  @impl true
  def handle_info(:drain, state) do
    channel = current_channel(state.channel_provider)
    started_at = System.monotonic_time()

    result =
      drain_once(
        spool: state.spool,
        spool_module: state.spool_module,
        channel: channel,
        channel_module: state.channel_module,
        host_id: state.host_id,
        max_events: state.max_events,
        max_bytes: state.max_bytes
      )

    upload_latency_ms = Telemetry.duration_ms(System.monotonic_time() - started_at)

    state = %{
      state
      | connection_state: if(connected?(channel), do: :connected, else: :disconnected),
        upload_latency_ms: upload_latency_ms,
        ack_latency_ms: ack_latency(result)
    }

    {:noreply, schedule(state)}
  end

  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, Map.take(state, [:connection_state, :upload_latency_ms, :ack_latency_ms]), state}
  end

  @doc "Uploads at most one pending capture batch."
  def drain_once(opts \\ []) do
    opts = normalize_opts(opts)
    connected? = connected?(opts.channel)
    Telemetry.capture_connection(connected?)
    started_at = System.monotonic_time()

    result =
      if connected? do
        drain_connected(opts)
      else
        {:ok, summary("disconnected", nil, 0)}
      end

    Telemetry.capture_upload(result, System.monotonic_time() - started_at)
    result
  end

  defp drain_connected(opts) do
    batch_id = batch_id()
    event_budget = wire_event_budget(opts, batch_id)

    result =
      if event_budget > 0 do
        safe_callback(:spool, fn ->
          opts.spool_module.next_batch(opts.spool, opts.max_events, event_budget)
        end)
      else
        {:error, :batch_wrapper_too_large}
      end

    case result do
      [] ->
        {:ok, summary("empty", nil, 0)}

      events when is_list(events) ->
        upload(events, batch_id, opts)

      {:oversized, event} ->
        reject_oversized(event, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp upload(events, batch_id, opts) do
    payload = wire_payload(batch_id, events, opts.host_id)

    case push(opts.channel_module, opts.channel, payload) do
      {{:ok, reply}, ack_latency_ms} ->
        apply_ack(reply, batch_id, events, opts)
        |> put_ack_latency(ack_latency_ms)

      {{:error, reason}, _ack_latency_ms} ->
        case mark_transport_retry(events, opts) do
          :ok ->
            {:error, reason}

          {:error, spool_reason} ->
            {:error, {:transport_spool_update_failed, reason, spool_reason}}
        end
    end
  end

  defp mark_transport_retry(events, opts) do
    Enum.reduce_while(events, :ok, fn event, :ok ->
      result =
        safe_callback(:spool, fn ->
          opts.spool_module.reject(
            opts.spool,
            event["event_id"],
            "transport_error",
            false
          )
        end)

      case result do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp reject_oversized(%{"event_id" => event_id}, opts) when is_binary(event_id) do
    case safe_callback(:spool, fn ->
           opts.spool_module.reject(opts.spool, event_id, "payload_too_large", true)
         end) do
      :ok ->
        {:ok,
         summary("oversized_dead_lettered", nil, 1)
         |> Map.put("dead_lettered", 1)
         |> Map.put("drained", 1)}

      {:error, reason} ->
        {:error,
         {:spool_update_failed, reason,
          summary("spool_update_failed", nil, 1) |> Map.put("unacknowledged", 1)}}
    end
  end

  defp reject_oversized(_event, _opts), do: {:error, :malformed_oversized_event}

  defp apply_ack(%{"batch_id" => batch_id, "results" => results}, batch_id, events, opts)
       when is_list(results) do
    event_ids = Enum.map(events, & &1["event_id"])
    sent_ids = MapSet.new(event_ids)
    {actions, invalid_ids, errors} = classify_results(results, sent_ids)
    mentioned_ids = actions |> Map.keys() |> MapSet.new() |> MapSet.union(invalid_ids)
    missing_ids = Enum.reject(event_ids, &MapSet.member?(mentioned_ids, &1))
    invalid_count = MapSet.size(invalid_ids)

    with {:ok, counts} <- apply_actions(actions, opts) do
      summary =
        summary("delivered", batch_id, length(events))
        |> Map.merge(counts)
        |> Map.put("unacknowledged", invalid_count + length(missing_ids))
        |> Map.put("drained", counts["acknowledged"] + counts["dead_lettered"])

      case ack_error(errors, missing_ids) do
        nil -> {:ok, summary}
        reason -> {:error, {:invalid_ack, reason, %{summary | "status" => "partial_invalid_ack"}}}
      end
    else
      {:error, reason, counts} ->
        drained = counts["acknowledged"] + counts["dead_lettered"]

        summary =
          summary("spool_update_failed", batch_id, length(events))
          |> Map.merge(counts)
          |> Map.put("unacknowledged", length(events) - drained - counts["retryable"])
          |> Map.put("drained", drained)

        {:error, {:spool_update_failed, reason, summary}}
    end
  end

  defp apply_ack(%{"batch_id" => _other}, batch_id, events, _opts) do
    {:error,
     {:invalid_ack, :batch_id_mismatch,
      summary("invalid_ack", batch_id, length(events))
      |> Map.put("unacknowledged", length(events))}}
  end

  defp apply_ack(_reply, batch_id, events, _opts) do
    {:error,
     {:invalid_ack, :malformed_ack,
      summary("invalid_ack", batch_id, length(events))
      |> Map.put("unacknowledged", length(events))}}
  end

  defp classify_results(results, sent_ids) do
    duplicate_ids =
      results
      |> Enum.flat_map(fn
        %{"event_id" => event_id} when is_binary(event_id) -> [event_id]
        _ -> []
      end)
      |> Enum.frequencies()
      |> Enum.reduce(MapSet.new(), fn
        {event_id, count}, acc when count > 1 -> MapSet.put(acc, event_id)
        _, acc -> acc
      end)

    Enum.reduce(results, {%{}, MapSet.new(), []}, fn result, {actions, invalid_ids, errors} ->
      classify_result(result, sent_ids, duplicate_ids, actions, invalid_ids, errors)
    end)
  end

  defp classify_result(
         %{"event_id" => event_id} = result,
         sent_ids,
         duplicate_ids,
         actions,
         invalid_ids,
         errors
       )
       when is_binary(event_id) do
    cond do
      not MapSet.member?(sent_ids, event_id) ->
        {actions, invalid_ids, [{:unknown_event_id, event_id} | errors]}

      MapSet.member?(duplicate_ids, event_id) ->
        {Map.delete(actions, event_id), MapSet.put(invalid_ids, event_id),
         [{:duplicate_result, event_id} | errors]}

      true ->
        classify_known_result(result, event_id, actions, invalid_ids, errors)
    end
  end

  defp classify_result(_result, _sent_ids, _duplicate_ids, actions, invalid_ids, errors) do
    {actions, invalid_ids, [:malformed_result | errors]}
  end

  defp classify_known_result(
         %{"status" => status},
         event_id,
         actions,
         invalid_ids,
         errors
       )
       when status in ["accepted", "duplicate"] do
    {Map.put(actions, event_id, :acknowledge), invalid_ids, errors}
  end

  defp classify_known_result(
         %{"status" => "rejected", "retryable" => false, "reason" => reason},
         event_id,
         actions,
         invalid_ids,
         errors
       )
       when is_binary(reason) do
    {Map.put(actions, event_id, {:reject, reason, true}), invalid_ids, errors}
  end

  defp classify_known_result(
         %{"status" => "failed", "retryable" => true, "reason" => reason},
         event_id,
         actions,
         invalid_ids,
         errors
       )
       when is_binary(reason) do
    {Map.put(actions, event_id, {:reject, reason, false}), invalid_ids, errors}
  end

  defp classify_known_result(_result, event_id, actions, invalid_ids, errors) do
    {actions, MapSet.put(invalid_ids, event_id), [{:malformed_result, event_id} | errors]}
  end

  defp apply_actions(actions, opts) do
    counts = %{"acknowledged" => 0, "dead_lettered" => 0, "retryable" => 0}
    acknowledged = for {event_id, :acknowledge} <- actions, do: event_id

    result =
      safe_callback(:spool, fn ->
        opts.spool_module.acknowledge(opts.spool, acknowledged)
      end)

    case result do
      :ok ->
        counts = %{counts | "acknowledged" => length(acknowledged)}
        apply_rejections(actions, opts, counts)

      {:error, reason} ->
        {:error, reason, counts}
    end
  end

  defp apply_rejections(actions, opts, counts) do
    Enum.reduce_while(actions, {:ok, counts}, fn
      {_event_id, :acknowledge}, {:ok, counts} ->
        {:cont, {:ok, counts}}

      {event_id, {:reject, reason, permanent?}}, {:ok, counts} ->
        result =
          safe_callback(:spool, fn ->
            opts.spool_module.reject(opts.spool, event_id, reason, permanent?)
          end)

        case result do
          :ok ->
            key = if permanent?, do: "dead_lettered", else: "retryable"
            {:cont, {:ok, Map.update!(counts, key, &(&1 + 1))}}

          {:error, reason} ->
            {:halt, {:error, reason, counts}}
        end
    end)
  end

  defp ack_error([], []), do: nil
  defp ack_error([], missing_ids), do: {:missing_results, missing_ids}
  defp ack_error(errors, missing_ids), do: {:invalid_results, Enum.reverse(errors), missing_ids}

  defp push(channel_module, channel, payload) do
    started_at = System.monotonic_time()
    result = safe_callback(:channel, fn -> channel_module.push(channel, @event, payload) end)
    duration = System.monotonic_time() - started_at
    Telemetry.capture_ack(result, duration)
    {result, Telemetry.duration_ms(duration)}
  end

  defp safe_callback(boundary, callback) do
    callback.()
  rescue
    error -> {:error, callback_error(boundary, :exception, error)}
  catch
    :exit, reason -> {:error, callback_error(boundary, :exit, reason)}
  end

  defp callback_error(:spool, :exception, error), do: {:spool_exception, error}
  defp callback_error(:spool, :exit, reason), do: {:spool_exit, reason}
  defp callback_error(:channel, :exception, error), do: {:channel_exception, error}
  defp callback_error(:channel, :exit, reason), do: {:channel_exit, reason}
  defp callback_error(:provider, :exception, error), do: {:provider_exception, error}
  defp callback_error(:provider, :exit, reason), do: {:provider_exit, reason}

  defp connected?(channel), do: is_pid(channel) and Process.alive?(channel)

  defp wire_event_budget(opts, batch_id) do
    wrapper_bytes = byte_size(Jason.encode!(wire_payload(batch_id, [], opts.host_id)))
    opts.max_bytes - wrapper_bytes
  end

  defp wire_payload(batch_id, events, host_id) do
    %{
      "protocol" => @protocol,
      "batch_id" => batch_id,
      "host_id" => host_id,
      "events" => events
    }
  end

  defp current_channel(provider) do
    case safe_callback(:provider, fn -> provider.channel() end) do
      channel when is_pid(channel) -> channel
      _ -> nil
    end
  end

  defp schedule(%{interval_ms: interval_ms} = state)
       when is_integer(interval_ms) and interval_ms > 0 do
    Process.send_after(self(), :drain, interval_ms)
    state
  end

  defp schedule(state), do: state

  defp put_ack_latency({:ok, summary}, latency_ms),
    do: {:ok, Map.put(summary, "ack_latency_ms", latency_ms)}

  defp put_ack_latency(result, _latency_ms), do: result

  defp ack_latency({:ok, %{"ack_latency_ms" => latency_ms}}), do: latency_ms
  defp ack_latency(_result), do: nil

  defp summary(status, batch_id, selected) do
    %{
      "status" => status,
      "batch_id" => batch_id,
      "selected" => selected,
      "acknowledged" => 0,
      "dead_lettered" => 0,
      "retryable" => 0,
      "unacknowledged" => 0,
      "drained" => 0
    }
  end

  defp batch_id do
    <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4),
      e::binary-size(12)>> = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

    Enum.join([a, b, c, d, e], "-")
  end

  defp normalize_opts(opts) do
    %{
      spool: Keyword.fetch!(opts, :spool),
      spool_module: Keyword.get(opts, :spool_module, Spool),
      channel: Keyword.get(opts, :channel),
      channel_module: Keyword.get(opts, :channel_module, Channel),
      host_id: Keyword.fetch!(opts, :host_id),
      max_events: bounded_positive(opts[:max_events], @default_max_events, @default_max_events),
      max_bytes: bounded_positive(opts[:max_bytes], @default_max_bytes, @default_max_bytes)
    }
  end

  defp bounded_positive(value, _default, maximum) when is_integer(value) and value > 0,
    do: min(value, maximum)

  defp bounded_positive(_value, default, _maximum), do: default
end
