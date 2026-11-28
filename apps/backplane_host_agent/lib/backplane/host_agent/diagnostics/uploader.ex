defmodule Backplane.HostAgent.Diagnostics.Uploader do
  @moduledoc "Transfers the frozen Host representation using independently verified remote receipts."

  use GenServer

  alias Backplane.DiagnosticsClient.Receipt
  alias Backplane.HostAgent.{Channel, MemoryProxy}
  alias Backplane.HostAgent.Diagnostics.Spool

  @protocol "host_diagnostics.v1"

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  def status(server \\ __MODULE__), do: GenServer.call(server, :status, 250)

  @impl true
  def init(opts) do
    state = %{
      spool: Keyword.get(opts, :spool, Spool),
      channel_provider: Keyword.get(opts, :channel_provider, &MemoryProxy.channel/0),
      channel_module: Keyword.get(opts, :channel_module, Channel),
      interval: Keyword.get(opts, :interval_ms, 1_000),
      delivery_enabled: Keyword.get(opts, :delivery_enabled, true),
      next_maintenance: System.monotonic_time(:millisecond),
      next_probe: nil,
      caps: nil,
      channel: nil,
      status: :disconnected
    }

    {:ok, schedule(state)}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  @impl true
  def handle_info(:drain, state) do
    now = System.monotonic_time(:millisecond)
    state = maybe_maintain(state, now)
    {:noreply, state |> drain(now) |> schedule()}
  end

  defp schedule(state) do
    Process.send_after(self(), :drain, state.interval)
    state
  end

  defp maybe_maintain(%{next_maintenance: due} = state, now) when due <= now do
    _ = safe_spool(fn -> Spool.maintain(state.spool) end)
    %{state | next_maintenance: now + 30_000}
  end

  defp maybe_maintain(state, _now), do: state

  defp drain(%{delivery_enabled: false} = state, _now), do: %{state | status: :paused}

  defp drain(state, now) do
    channel = state.channel_provider.()

    cond do
      not is_pid(channel) or not Process.alive?(channel) ->
        %{state | channel: nil, caps: nil, next_probe: nil, status: :disconnected}

      state.channel == channel and is_integer(state.next_probe) and now < state.next_probe ->
        state

      true ->
        if state.channel == channel and state.caps do
          drain_ready(state, now)
        else
          state |> probe(channel, now) |> drain_if_supported(now)
        end
    end
  end

  defp probe(state, channel, now) do
    state = %{state | channel: channel, caps: nil}

    case push(state.channel_module, channel, "diagnostics_capabilities", %{}) do
      {:ok, %{"protocol" => @protocol, "max_items" => items, "max_bytes" => bytes}}
      when is_integer(items) and items > 0 and is_integer(bytes) and bytes > 0 ->
        %{
          state
          | caps: {min(items, 100), min(bytes, 524_288)},
            next_probe: nil,
            status: :connected
        }

      result ->
        %{state | next_probe: now + 60_000, status: transport_status(result)}
    end
  end

  defp drain_if_supported(%{caps: nil} = state, _now), do: state
  defp drain_if_supported(state, now), do: drain_ready(state, now)

  defp drain_ready(state, now) do
    case drain_once(state.spool, state.channel_module, state.channel, state.caps) do
      {:ok, status} -> %{state | status: status}
      {:error, reason} -> %{state | status: reason, caps: nil, next_probe: now + 60_000}
    end
  end

  @doc "Attempts one source batch against already negotiated limits."
  def drain_once(spool, channel_module, channel, {max_items, max_bytes}) do
    case safe_spool(fn -> Spool.ready(spool, max_items) end) do
      {:ok, []} ->
        {:ok, :connected}

      {:ok, [%{"source_id" => source_id} | _] = rows} ->
        send_batch(spool, channel_module, channel, source_id, rows, max_bytes)

      {:error, _reason} ->
        {:error, :persistence_unavailable}
    end
  end

  defp send_batch(spool, channel_module, channel, source_id, rows, limit) do
    batch_id = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    {:ok, empty} = Receipt.encode_batch(Receipt.batch(:remote, batch_id, []))

    {chosen, entries} = choose_rows(rows, limit - byte_size(empty))

    case {chosen, rows} do
      {[], [oversized | _]} ->
        disposition = disposition(oversized, {:dead_letter, "negotiated_batch_limit"})
        settle(spool, source_id, [disposition], :connected)

      {_, _} ->
        batch = Receipt.batch(:remote, batch_id, entries)
        result = push(channel_module, channel, "diagnostics_sync", batch)
        settle_batch(spool, source_id, batch_id, chosen, entries, result)
    end
  end

  defp choose_rows(rows, budget) do
    rows
    |> Enum.reduce_while({[], [], budget}, fn row, {chosen, entries, remaining} ->
      entry = Receipt.entry(Formata.JSON.decode!(row["body"]), row["forward_digest"])
      cost = byte_size(Formata.JSON.encode!(entry)) + if(chosen == [], do: 0, else: 1)

      if cost <= remaining do
        {:cont, {[row | chosen], [entry | entries], remaining - cost}}
      else
        {:halt, {chosen, entries, remaining}}
      end
    end)
    |> then(fn {chosen, entries, _remaining} -> {Enum.reverse(chosen), Enum.reverse(entries)} end)
  end

  defp settle_batch(spool, source_id, batch_id, rows, entries, {:ok, reply}) do
    receipts = Receipt.reconcile(reply, :remote, batch_id, entries)
    status = if length(rows) == map_size(receipts), do: :connected, else: :invalid_receipt

    dispositions =
      Enum.map(rows, &disposition(&1, receipt_disposition(&1, receipts[&1["event_id"]])))

    if Enum.any?(receipts, fn {_id, result} -> result["status"] == "unsupported_schema" end) do
      settle(spool, source_id, dispositions, :unsupported_schema)
    else
      settle(spool, source_id, dispositions, status)
    end
  end

  defp settle_batch(spool, source_id, _batch_id, rows, _entries, result) do
    status = transport_status(result)

    case settle(
           spool,
           source_id,
           Enum.map(rows, &disposition(&1, retry(&1, "transport_error"))),
           status
         ) do
      {:ok, reason} when reason in [:unauthorized, :unsupported_capability] -> {:error, reason}
      other -> other
    end
  end

  defp receipt_disposition(_row, %{"status" => status}) when status in ~w(stored duplicate),
    do: {:ack, status}

  defp receipt_disposition(_row, %{"status" => status} = receipt)
       when status in ~w(permanent_rejection identity_conflict),
       do: {:dead_letter, receipt["reason"] || status}

  defp receipt_disposition(row, %{"status" => "unsupported_schema"}),
    do: retry(row, "unsupported_schema", 60_000)

  defp receipt_disposition(row, %{"status" => "retryable_rejection"} = receipt),
    do: retry(row, receipt["reason"] || "retryable_rejection", receipt["retry_after_ms"] || 0)

  defp receipt_disposition(row, _), do: retry(row, "unknown_receipt")

  defp retry(row, reason, hint_ms \\ 0) do
    delay = min(60, Integer.pow(2, min(row["attempts"], 6)))

    delay =
      max(div(hint_ms + 999, 1000), min(60, delay + :rand.uniform(max(1, div(delay, 2))) - 1))

    {:retry, delay, reason}
  end

  defp disposition(row, operation), do: {row["event_id"], row["forward_digest"], operation}

  defp settle(spool, source_id, dispositions, status) do
    case safe_spool(fn -> Spool.settle(spool, source_id, dispositions) end) do
      {:ok, :ok} -> {:ok, status}
      {:error, _reason} -> {:error, :persistence_unavailable}
    end
  end

  defp transport_status({:error, %{"code" => "unauthorized"}}), do: :unauthorized

  defp transport_status({:error, %{"code" => "unsupported_protocol"}}),
    do: :unsupported_capability

  defp transport_status({:ok, _invalid}), do: :unsupported_capability
  defp transport_status(_), do: :transport_unavailable

  defp push(module, channel, event, payload) do
    module.push(channel, event, payload, 5_000)
  catch
    :exit, _ -> {:error, :connection_closed}
  end

  defp safe_spool(fun) do
    fun.()
  catch
    :exit, _ -> {:error, :persistence_unavailable}
  end
end
